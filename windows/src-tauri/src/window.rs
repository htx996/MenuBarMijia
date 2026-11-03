use super::*;
use crate::placement::*;

pub(crate) static LAST_FOCUS_LOSS_MS: AtomicU64 = AtomicU64::new(0);
pub(crate) static PIN_POPOVER: AtomicBool = AtomicBool::new(false);


#[tauri::command]
pub(crate) fn hide_panel(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

#[tauri::command]
pub(crate) fn quit_app(app: AppHandle) {
    shutdown_camera_daemons();
    app.exit(0);
}

#[tauri::command]
pub(crate) fn set_pin_popover(pin: bool) {
    PIN_POPOVER.store(pin, Ordering::SeqCst);
}

/// The persisted placement the settings sheet shows and every open honours (#204).
#[tauri::command]
pub(crate) fn panel_placement() -> PanelPlacement {
    current_panel_placement()
}

#[tauri::command]
pub(crate) fn set_panel_placement(app: AppHandle, anchor: PanelAnchor) -> Result<(), String> {
    let saved = store_panel_placement(PanelPlacement { anchor });
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            position_popover(&window, None);
        }
    }
    saved
}

/// The panel has no title bar, so a press on the header hands over to the OS move loop (#204).
#[tauri::command]
pub(crate) fn start_panel_drag(app: AppHandle, window: WebviewWindow) {
    // A header press is user movement from here on: stop ignoring `Moved` events even if the panel was
    // placed moments ago, and let the settle watcher end the session once the pointer rests.
    USER_DRAG_ACTIVE.store(true, Ordering::SeqCst);
    USER_MOVES_SEEN.store(false, Ordering::SeqCst);
    PROGRAMMATIC_MOVE_UNTIL_MS.store(0, Ordering::SeqCst);
    schedule_drag_settle(app);
    let _ = window.start_dragging();
}

static GROK_SIDE_LEFT: AtomicBool = AtomicBool::new(false);

pub(crate) fn panel_sidecar_on_left(room_left: f64, room_right: f64, scale: f64) -> bool {
    if room_right >= (232.0 + 20.0) * scale {
        false
    } else if room_left >= (232.0 + 12.0) * scale {
        true
    } else {
        room_left > room_right
    }
}

/// Panel placement preference (auto or a fixed work-area corner). It lives beside the window rather
/// than in the webview's local storage because a drag has to save it from the window event loop (#204).
static PANEL_PLACEMENT: LazyLock<RwLock<PanelPlacement>> =
    LazyLock::new(|| RwLock::new(PanelPlacement::default()));

/// Until this timestamp, `Moved` events come from our own placement calls, not from a drag.
static PROGRAMMATIC_MOVE_UNTIL_MS: AtomicU64 = AtomicU64::new(0);
/// Set from a header press until the drag settles; while it is set, placement calls must not swallow
/// the movement the user is producing (#204 review).
static USER_DRAG_ACTIVE: AtomicBool = AtomicBool::new(false);
/// Whether the current drag session actually moved the window, so a plain click never snaps it.
static USER_MOVES_SEEN: AtomicBool = AtomicBool::new(false);
/// Last user-driven move; the drag is over once the window stops moving for a moment.
static MOVE_SNAP_DEADLINE_MS: AtomicU64 = AtomicU64::new(0);
static MOVE_SNAP_SCHEDULED: AtomicBool = AtomicBool::new(false);

pub(crate) fn current_panel_placement() -> PanelPlacement {
    PANEL_PLACEMENT.read().map(|guard| *guard).unwrap_or_default()
}

pub(crate) fn remember_panel_placement(placement: PanelPlacement) {
    if let Ok(mut guard) = PANEL_PLACEMENT.write() {
        *guard = placement;
    }
}

pub(crate) fn store_panel_placement(placement: PanelPlacement) -> Result<(), String> {
    remember_panel_placement(placement);
    match panel_placement_path() {
        Some(path) => write_panel_placement(&path, placement),
        None => Ok(()),
    }
}

pub(crate) fn read_panel_placement(path: &std::path::Path) -> PanelPlacement {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub(crate) fn write_panel_placement(path: &std::path::Path, placement: PanelPlacement) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存面板位置：{error}"))?;
    }
    let body = serde_json::to_string(&placement).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存面板位置：{error}"))
}

#[cfg(test)]
pub(crate) fn panel_placement_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
pub(crate) fn panel_placement_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("panel-placement.json"))
}

pub(crate) fn load_panel_placement() {
    if let Some(path) = panel_placement_path() {
        remember_panel_placement(read_panel_placement(&path));
    }
}

/// Full monitor bounds plus the work area that excludes docked taskbars. A runtime that cannot report
/// a work area falls back to the full bounds, which behaves like a taskbar-free monitor.
pub(crate) fn monitor_rects(monitor: &Monitor) -> (Rect, Rect) {
    let position = monitor.position();
    let size = monitor.size();
    let full = Rect::new(position.x, position.y, size.width as i32, size.height as i32);
    let area = monitor.work_area();
    let work = Rect::new(
        area.position.x,
        area.position.y,
        area.size.width as i32,
        area.size.height as i32,
    );
    if work.width <= 0 || work.height <= 0 {
        (full, full)
    } else {
        (full, work)
    }
}

/// Left inset of the main card column inside the panel; the sidecar widens the window to its left.
pub(crate) fn main_column_inset(window_width: i32, scale: f64) -> i32 {
    if GROK_SIDE_LEFT.load(Ordering::SeqCst) {
        (window_width - (472.0 * scale).round() as i32 - (8.0 * scale).round() as i32).max(0)
    } else {
        0
    }
}

/// Keep the main card column fixed while reserving space for the side-mounted assistant.
#[tauri::command]
pub(crate) fn set_panel_height(
    app: AppHandle,
    height: f64,
    expanded: bool,
    side_left: bool,
    grok_enabled: Option<bool>,
) -> bool {
    let Some(window) = app.get_webview_window("main") else { return side_left };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let margin = (12.0 * scale).round() as i32;
    // The work area already excludes the taskbar, whichever edge it is docked to (#204).
    let max_h = (work.height as f64 / scale - 24.0).max(480.0);
    let target_h = if height <= 0.0 { max_h } else { height.min(max_h) };
    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let main_width = 472.0 * scale;
    let main_x = old_pos.x as f64 + if side_left { (old_size.width as f64 - main_width - 8.0 * scale).max(0.0) } else { 0.0 };
    let left = work.x as f64 + margin as f64;
    let right = work.right() as f64 - margin as f64;
    let room_right = right - main_x - main_width;
    let room_left = main_x - left;
    let enabled = grok_enabled.unwrap_or(true);
    let on_left = if enabled { panel_sidecar_on_left(room_left, room_right, scale) } else { false };
    let rail_width: f64 = if !enabled { 0.0 } else if expanded { 232.0 } else { 84.0 };
    let target_w = (472.0 + if enabled { rail_width + 20.0 } else { 8.0 }).min((right - left) / scale);
    let desired_x = main_x - if on_left { (rail_width + 12.0) * scale } else { 0.0 };
    let x = desired_x.clamp(left, (right - target_w * scale).max(left));
    let new_h = (target_h * scale).round() as i32;
    let corner = current_panel_placement().anchor.corner(taskbar_edge(full, work));
    let y = resized_top(work, margin, old_pos.y, old_size.height as i32, new_h, corner);
    suppress_move_snaps();
    let _ = window.set_size(tauri::LogicalSize::new(target_w, target_h));
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y));
    GROK_SIDE_LEFT.store(on_left, Ordering::SeqCst);
    on_left
}
pub(crate) fn position_popover(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) {
    let win_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let win_w = win_size.width as i32;
    let win_h = win_size.height as i32;

    // A tray click knows which display hosts the icon; the other paths follow the window's monitor.
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        if let Some(pos) = anchor {
            let x = (pos.x as i32 - win_w / 2).max(16);
            let y = (pos.y as i32 - win_h - 16).max(16);
            suppress_move_snaps();
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
        return;
    };

    let (full, work) = monitor_rects(&monitor);
    let scale = monitor.scale_factor();
    let margin = (12.0 * scale).round() as i32;
    // A panel sized for a larger display has to fit this monitor before it is placed (#204 review).
    let fitted_h = fit_panel_height(work, margin, win_h);
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, fitted_h),
        margin,
        anchor: anchor.map(|pos| (pos.x.round() as i32, pos.y.round() as i32)),
        preference: current_panel_placement().anchor,
        main_inset: main_column_inset(win_w, scale),
        main_width: (472.0 * scale).round() as i32,
    });
    suppress_move_snaps();
    if fitted_h != win_h {
        let _ = window.set_size(PhysicalSize::new(win_size.width, fitted_h as u32));
    }
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// Whether the primary mouse button is still held. A drag that pauses without emitting `Moved` events
/// is not finished, so the settle watcher must wait for the release (#204 review).
#[cfg(all(windows, not(test)))]
pub(crate) fn primary_button_down() -> bool {
    #[link(name = "user32")]
    extern "system" {
        fn GetAsyncKeyState(vkey: i32) -> i16;
        fn GetSystemMetrics(index: i32) -> i32;
    }
    // "Swap primary and secondary buttons" makes the header's logical-primary press arrive on the right
    // button, so ask which physical button is primary before sampling it.
    const SM_SWAPBUTTON: i32 = 23;
    let swapped = unsafe { GetSystemMetrics(SM_SWAPBUTTON) != 0 };
    key_state_is_down(unsafe { GetAsyncKeyState(primary_button_virtual_key(swapped)) })
}

#[cfg(any(not(windows), test))]
pub(crate) fn primary_button_down() -> bool {
    false
}

/// Ignore `Moved` events caused by our own placement calls; the window covers the IPC round trips.
/// A running drag keeps the window: arming here would swallow the movement the user is producing.
pub(crate) fn suppress_move_snaps() {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    if let Some(deadline) = move_suppression_deadline(drag_active, now_epoch_ms()) {
        PROGRAMMATIC_MOVE_UNTIL_MS.store(deadline, Ordering::SeqCst);
    }
}

/// Watches one native drag until the window is still **and** the pointer has been released, then ends
/// the session. Only a drag that actually moved the window snaps, so a plain header click changes
/// nothing.
pub(crate) fn schedule_drag_settle(app: AppHandle) {
    MOVE_SNAP_DEADLINE_MS.store(now_epoch_ms() + DRAG_SETTLE_MS, Ordering::SeqCst);
    if MOVE_SNAP_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        loop {
            let now = now_epoch_ms();
            let quiet_until = MOVE_SNAP_DEADLINE_MS.load(Ordering::SeqCst);
            // Only a released pointer finishes the drag; a pause while the button is still down is not
            // a drop, so keep the quiet window rolling instead of snapping an intermediate corner.
            let held = USER_DRAG_ACTIVE.load(Ordering::SeqCst) && primary_button_down();
            if drag_settle_finished(now, quiet_until, held) {
                break;
            }
            if now >= quiet_until {
                MOVE_SNAP_DEADLINE_MS.store(now + DRAG_SETTLE_MS, Ordering::SeqCst);
            }
            std::thread::sleep(Duration::from_millis(60));
        }
        let moved = USER_MOVES_SEEN.swap(false, Ordering::SeqCst);
        USER_DRAG_ACTIVE.store(false, Ordering::SeqCst);
        MOVE_SNAP_SCHEDULED.store(false, Ordering::SeqCst);
        if !moved {
            return;
        }
        if let Some(window) = app.get_webview_window("main") {
            snap_panel_to_work_area(&window);
        }
    });
}

/// A drag emits `Moved` on every mouse step; keep the session alive until the pointer is released.
pub(crate) fn note_user_move(app: &AppHandle) {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    let suppressed_until = PROGRAMMATIC_MOVE_UNTIL_MS.load(Ordering::SeqCst);
    if !move_is_user_driven(drag_active, now_epoch_ms(), suppressed_until) {
        return;
    }
    USER_MOVES_SEEN.store(true, Ordering::SeqCst);
    schedule_drag_settle(app.clone());
}

/// Drag-to-move lands on the nearest work-area corner, and that corner becomes the preference.
pub(crate) fn snap_panel_to_work_area(window: &WebviewWindow) {
    let Ok(position) = window.outer_position() else { return };
    let size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let win_w = size.width as i32;
    let win_h = size.height as i32;
    let center = (position.x + win_w / 2, position.y + win_h / 2);
    let Some(monitor) = window
        .monitor_from_point(center.0 as f64, center.1 as f64)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
    else {
        return;
    };
    let (full, work) = monitor_rects(&monitor);
    let scale = monitor.scale_factor();
    let margin = (12.0 * scale).round() as i32;
    // Fit the destination work area before placing: an over-tall panel would otherwise pin its top and
    // leave its bottom offscreen (#204 review).
    let fitted_h = fit_panel_height(work, margin, win_h);
    // Judge the drop by where the fitted panel lands, not by the oversized source rect.
    let dropped_center = (position.x + win_w / 2, position.y + fitted_h / 2);
    let anchor = PanelAnchor::nearest(work, dropped_center);
    // A drop inside the current quadrant still snaps the window back to its corner; only a different
    // corner needs a write, so an unchanged preference never rewrites the file (#204 review).
    if anchor != current_panel_placement().anchor {
        let _ = store_panel_placement(PanelPlacement { anchor });
    }
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, fitted_h),
        margin,
        anchor: None,
        preference: anchor,
        main_inset: main_column_inset(win_w, scale),
        main_width: (472.0 * scale).round() as i32,
    });
    suppress_move_snaps();
    if fitted_h != win_h {
        let _ = window.set_size(PhysicalSize::new(size.width, fitted_h as u32));
    }
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

pub(crate) fn toggle_main_window(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>, from_tray_click: bool) {
    if let Some(window) = app.get_webview_window("main") {
        let is_visible = window.is_visible().unwrap_or(false);
        if is_visible {
            let _ = window.hide();
        } else {
            if from_tray_click {
                let elapsed = now_epoch_ms().saturating_sub(LAST_FOCUS_LOSS_MS.load(Ordering::SeqCst));
                if elapsed < 280 {
                    return;
                }
            }
            position_popover(&window, anchor);
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}
