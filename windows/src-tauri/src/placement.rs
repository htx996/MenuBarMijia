//! Screen placement for the tray panel (#204).
//!
//! Windows lets the taskbar dock to any monitor edge, so the panel is placed inside the monitor
//! *work area* (`GetMonitorInfoW` → `rcWork`, surfaced by Tauri as `Monitor::work_area`) instead of
//! inside the full monitor bounds minus a hard-coded taskbar height. Everything here is pure integer
//! arithmetic in physical pixels, so every edge case is unit-tested without a display.

use serde::{Deserialize, Serialize};

/// A screen rectangle in physical pixels, anchored to the virtual desktop's top-left corner.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub const fn right(&self) -> i32 {
        self.x + self.width
    }

    pub const fn bottom(&self) -> i32 {
        self.y + self.height
    }
}

/// The monitor edge the taskbar is docked to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskbarEdge {
    Top,
    Bottom,
    Left,
    Right,
    /// No reserved strip: an auto-hidden, floating, or missing taskbar.
    None,
}

/// Reads the taskbar edge off the gap between a monitor and its work area. The widest gap wins so a
/// taskbar plus a docked toolbar (or a rounded work area) still resolves to one edge.
pub fn taskbar_edge(monitor: Rect, work: Rect) -> TaskbarEdge {
    let gaps = [
        (TaskbarEdge::Top, work.y - monitor.y),
        (TaskbarEdge::Bottom, monitor.bottom() - work.bottom()),
        (TaskbarEdge::Left, work.x - monitor.x),
        (TaskbarEdge::Right, monitor.right() - work.right()),
    ];
    gaps.iter()
        .copied()
        .filter(|(_, gap)| *gap > 0)
        .max_by_key(|(_, gap)| *gap)
        .map(|(edge, _)| edge)
        .unwrap_or(TaskbarEdge::None)
}

/// A corner of the work area the panel is pinned to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Corner {
    pub left: bool,
    pub top: bool,
}

/// Where the tray lives for a given taskbar edge; an unanchored panel opens there.
pub fn tray_corner(edge: TaskbarEdge) -> Corner {
    match edge {
        TaskbarEdge::Top => Corner {
            left: false,
            top: true,
        },
        TaskbarEdge::Left => Corner {
            left: true,
            top: false,
        },
        TaskbarEdge::Bottom | TaskbarEdge::Right | TaskbarEdge::None => Corner {
            left: false,
            top: false,
        },
    }
}

/// Persisted placement preference, serialised as camelCase for the frontend.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PanelAnchor {
    /// Follow the taskbar and the clicked tray icon.
    Auto,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

impl Default for PanelAnchor {
    fn default() -> Self {
        Self::Auto
    }
}

impl PanelAnchor {
    pub fn corner(self, edge: TaskbarEdge) -> Corner {
        match self {
            PanelAnchor::Auto => tray_corner(edge),
            PanelAnchor::TopLeft => Corner {
                left: true,
                top: true,
            },
            PanelAnchor::TopRight => Corner {
                left: false,
                top: true,
            },
            PanelAnchor::BottomLeft => Corner {
                left: true,
                top: false,
            },
            PanelAnchor::BottomRight => Corner {
                left: false,
                top: false,
            },
        }
    }

    /// The corner whose work-area quadrant contains `center`; a dropped panel snaps there.
    pub fn nearest(work: Rect, center: (i32, i32)) -> Self {
        let left = center.0 < work.x + work.width / 2;
        let top = center.1 < work.y + work.height / 2;
        match (left, top) {
            (true, true) => PanelAnchor::TopLeft,
            (false, true) => PanelAnchor::TopRight,
            (true, false) => PanelAnchor::BottomLeft,
            (false, false) => PanelAnchor::BottomRight,
        }
    }
}

/// The on-disk placement preference.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanelPlacement {
    #[serde(default)]
    pub anchor: PanelAnchor,
}

/// One placement pass, all values in physical pixels.
#[derive(Clone, Copy, Debug)]
pub struct PlacementInput {
    /// Full monitor bounds (`rcMonitor`); only the taskbar edge is derived from it.
    pub monitor: Rect,
    /// Monitor work area (`rcWork`), the box the panel must stay inside.
    pub work: Rect,
    /// Panel width and height.
    pub window: (i32, i32),
    /// Gap kept between the panel and the work-area edges.
    pub margin: i32,
    /// Tray icon position for a tray-triggered open; `None` for the hotkey and menu paths.
    pub anchor: Option<(i32, i32)>,
    pub preference: PanelAnchor,
    /// Where the main card column starts inside the window (the sidecar sits to its left).
    pub main_inset: i32,
    pub main_width: i32,
}

/// Top-left corner of the panel inside the work area.
pub fn place(input: &PlacementInput) -> (i32, i32) {
    let (win_w, win_h) = input.window;
    let min_x = input.work.x + input.margin;
    let min_y = input.work.y + input.margin;
    // A panel larger than the work area still starts at the top-left margin instead of going negative.
    let max_x = (input.work.right() - win_w - input.margin).max(min_x);
    let max_y = (input.work.bottom() - win_h - input.margin).max(min_y);

    let edge = taskbar_edge(input.monitor, input.work);
    let corner = input.preference.corner(edge);
    let mut x = if corner.left { min_x } else { max_x };
    let mut y = if corner.top { min_y } else { max_y };

    if input.preference == PanelAnchor::Auto {
        if let Some((icon_x, icon_y)) = input.anchor {
            match edge {
                TaskbarEdge::Left | TaskbarEdge::Right => {
                    // Beside the taskbar, vertically level with the tray icon.
                    let beside = if edge == TaskbarEdge::Left {
                        icon_x + input.margin
                    } else {
                        icon_x - win_w - input.margin
                    };
                    x = beside.clamp(min_x, max_x);
                    y = (icon_y - win_h / 2).clamp(min_y, max_y);
                }
                _ => {
                    x = (icon_x - input.main_inset - input.main_width / 2).clamp(min_x, max_x);
                    y = beside_icon_vertically(icon_y, win_h, input.margin, min_y, max_y);
                }
            }
        }
    }
    (x, y)
}

/// Opens above the tray icon when that side has room, otherwise below it (a top taskbar), so the
/// icon never pushes the panel off the work area.
fn beside_icon_vertically(icon_y: i32, win_h: i32, margin: i32, min_y: i32, max_y: i32) -> i32 {
    let above = icon_y - win_h - margin;
    if above >= min_y {
        above.min(max_y)
    } else {
        (icon_y + margin).clamp(min_y, max_y)
    }
}

/// Height that fits the panel inside the monitor work area with `margin` above and below. A tall panel
/// dragged from a larger display has to shrink before it is placed: `place()` keeps its top inside the
/// work area, but without this the bottom would hang off the shorter screen (#204 review).
pub fn fit_panel_height(work: Rect, margin: i32, height: i32) -> i32 {
    let available = (work.height - margin * 2).max(1);
    height.min(available).max(1)
}

/// Keeps the anchored vertical edge fixed while the panel changes height.
pub fn resized_top(
    work: Rect,
    margin: i32,
    old_top: i32,
    old_height: i32,
    new_height: i32,
    corner: Corner,
) -> i32 {
    let min_y = work.y + margin;
    let max_y = (work.bottom() - new_height - margin).max(min_y);
    let top = if corner.top {
        old_top
    } else {
        old_top + old_height - new_height
    };
    top.clamp(min_y, max_y)
}

/// How long our own `set_position` calls may still deliver `Moved` events (IPC plus event-loop hops).
pub const MOVE_SUPPRESS_MS: u64 = 600;

/// Quiet time after the last drag move before the panel snaps, so the snap never fights the pointer.
pub const DRAG_SETTLE_MS: u64 = 350;

/// Deadline for ignoring our own moves, or `None` while a native drag owns the window. A placement
/// call must never arm the window mid-drag, or the movement the user is producing would be discarded.
pub fn move_suppression_deadline(drag_active: bool, now_ms: u64) -> Option<u64> {
    if drag_active {
        None
    } else {
        Some(now_ms + MOVE_SUPPRESS_MS)
    }
}

/// Whether a `Moved` event belongs to the user. A live drag session always wins; otherwise the move
/// has to fall outside the window armed by our own placement calls.
pub fn move_is_user_driven(drag_active: bool, now_ms: u64, suppressed_until_ms: u64) -> bool {
    drag_active || now_ms >= suppressed_until_ms
}

/// Whether a drag-settle watcher may finish: the quiet window has passed and the native drag is no
/// longer holding the pointer. Movement inactivity alone does not establish that the user dropped the
/// panel — a paused-but-pressed drag keeps waiting (#204 review).
pub fn drag_settle_finished(now_ms: u64, quiet_until_ms: u64, drag_held: bool) -> bool {
    now_ms >= quiet_until_ms && !drag_held
}

/// `VK_LBUTTON`: the physical button that acts as primary on a normal mouse.
pub const PRIMARY_BUTTON_KEY: i32 = 0x01;

/// `VK_RBUTTON`: the physical button that acts as primary after "swap primary and secondary buttons".
pub const SWAPPED_PRIMARY_BUTTON_KEY: i32 = 0x02;

/// Physical button to watch for the logical-primary press the header receives. Windows swaps the two
/// buttons when `SM_SWAPBUTTON` is set, so the release then arrives on the right button (#204 review).
pub fn primary_button_virtual_key(swapped: bool) -> i32 {
    if swapped {
        SWAPPED_PRIMARY_BUTTON_KEY
    } else {
        PRIMARY_BUTTON_KEY
    }
}

/// Decodes the high-order "currently down" bit of `GetAsyncKeyState`.
pub fn key_state_is_down(state: i16) -> bool {
    (state as u16 & 0x8000) != 0
}

#[cfg(test)]
mod tests {
    use super::*;

    const TASKBAR: i32 = 48;
    const MARGIN: i32 = 12;
    const WINDOW: (i32, i32) = (480, 620);

    fn monitor() -> Rect {
        Rect::new(0, 0, 1920, 1080)
    }

    fn work_with(edge: TaskbarEdge) -> Rect {
        match edge {
            TaskbarEdge::Top => Rect::new(0, TASKBAR, 1920, 1080 - TASKBAR),
            TaskbarEdge::Bottom => Rect::new(0, 0, 1920, 1080 - TASKBAR),
            TaskbarEdge::Left => Rect::new(TASKBAR, 0, 1920 - TASKBAR, 1080),
            TaskbarEdge::Right => Rect::new(0, 0, 1920 - TASKBAR, 1080),
            TaskbarEdge::None => monitor(),
        }
    }

    fn input(edge: TaskbarEdge, anchor: Option<(i32, i32)>) -> PlacementInput {
        PlacementInput {
            monitor: monitor(),
            work: work_with(edge),
            window: WINDOW,
            margin: MARGIN,
            anchor,
            preference: PanelAnchor::Auto,
            main_inset: 0,
            main_width: 472,
        }
    }

    #[test]
    fn derives_the_taskbar_edge_from_the_work_area_gap() {
        for edge in [
            TaskbarEdge::Top,
            TaskbarEdge::Bottom,
            TaskbarEdge::Left,
            TaskbarEdge::Right,
        ] {
            assert_eq!(taskbar_edge(monitor(), work_with(edge)), edge);
        }
        assert_eq!(taskbar_edge(monitor(), monitor()), TaskbarEdge::None);
        // An auto-hidden taskbar reserves no strip.
        let auto_hidden = Rect::new(0, 0, 1920, 1080);
        assert_eq!(taskbar_edge(monitor(), auto_hidden), TaskbarEdge::None);
    }

    #[test]
    fn a_bottom_taskbar_keeps_the_panel_inside_the_work_area() {
        let (x, y) = place(&input(TaskbarEdge::Bottom, None));
        assert_eq!((x, y), (1920 - 480 - MARGIN, 1080 - TASKBAR - 620 - MARGIN));
    }

    #[test]
    fn a_top_taskbar_anchors_the_panel_to_the_top() {
        let (x, y) = place(&input(TaskbarEdge::Top, None));
        assert_eq!((x, y), (1920 - 480 - MARGIN, TASKBAR + MARGIN));

        // A tray click inside the top taskbar has no room above it, so the panel opens below.
        let (x, y) = place(&input(TaskbarEdge::Top, Some((1700, 24))));
        assert_eq!(y, TASKBAR + MARGIN);
        assert_eq!(x, 1920 - 480 - MARGIN);
    }

    #[test]
    fn a_tray_click_never_leaves_the_phantom_bottom_gap() {
        // Regression for #204: this used to subtract 54 logical px *and* the real taskbar.
        let (_, y) = place(&input(TaskbarEdge::Bottom, Some((1700, 1070))));
        assert_eq!(y, work_with(TaskbarEdge::Bottom).bottom() - 620 - MARGIN);
        assert!(y + 620 <= work_with(TaskbarEdge::Bottom).bottom() - MARGIN);
    }

    #[test]
    fn a_left_taskbar_puts_the_panel_beside_it() {
        let (x, y) = place(&input(TaskbarEdge::Left, Some((24, 1040))));
        assert_eq!(x, TASKBAR + MARGIN);
        assert_eq!(y, 1080 - 620 - MARGIN);
    }

    #[test]
    fn a_right_taskbar_puts_the_panel_left_of_it() {
        let (x, y) = place(&input(TaskbarEdge::Right, Some((1896, 1040))));
        assert_eq!(x, 1872 - 480 - MARGIN);
        assert_eq!(y, 1080 - 620 - MARGIN);
    }

    #[test]
    fn an_explicit_corner_ignores_the_tray_anchor() {
        for (preference, expected) in [
            (PanelAnchor::TopLeft, (MARGIN, MARGIN)),
            (PanelAnchor::TopRight, (1920 - 480 - MARGIN, MARGIN)),
            (
                PanelAnchor::BottomLeft,
                (MARGIN, 1032 - 620 - MARGIN),
            ),
            (
                PanelAnchor::BottomRight,
                (1920 - 480 - MARGIN, 1032 - 620 - MARGIN),
            ),
        ] {
            let mut request = input(TaskbarEdge::Bottom, Some((1700, 1070)));
            request.preference = preference;
            assert_eq!(place(&request), expected, "{preference:?}");
        }
    }

    #[test]
    fn a_panel_larger_than_the_work_area_starts_at_the_margin() {
        let mut request = input(TaskbarEdge::Bottom, None);
        request.window = (3000, 2000);
        assert_eq!(place(&request), (MARGIN, MARGIN));
    }

    #[test]
    fn a_tall_panel_shrinks_to_the_destination_work_area() {
        let short = Rect::new(0, 0, 1366, 728);
        // A 1008 px panel sized on a 1080p monitor does not fit this 728 px work area…
        assert_eq!(fit_panel_height(short, 12, 1008), 704);
        // …while a panel that already fits is left alone: the clamp never grows it.
        assert_eq!(fit_panel_height(short, 12, 620), 620);
        // A degenerate work area still yields a positive height.
        assert_eq!(fit_panel_height(Rect::new(0, 0, 100, 20), 12, 620), 1);
    }

    #[test]
    fn resizing_keeps_the_anchored_vertical_edge_fixed() {
        let work = work_with(TaskbarEdge::Top);
        let top = Corner {
            left: false,
            top: true,
        };
        let bottom = Corner {
            left: false,
            top: false,
        };
        // Grows downward from its top edge when anchored to the top...
        assert_eq!(resized_top(work, MARGIN, TASKBAR + MARGIN, 520, 620, top), TASKBAR + MARGIN);
        // ...and upward from its bottom edge when anchored to the bottom.
        assert_eq!(
            resized_top(work, MARGIN, 900, 520, 620, bottom),
            1080 - 620 - MARGIN
        );
    }

    #[test]
    fn a_dropped_panel_snaps_to_the_nearest_corner() {
        let work = work_with(TaskbarEdge::Bottom);
        assert_eq!(PanelAnchor::nearest(work, (200, 100)), PanelAnchor::TopLeft);
        assert_eq!(PanelAnchor::nearest(work, (1700, 100)), PanelAnchor::TopRight);
        assert_eq!(PanelAnchor::nearest(work, (200, 900)), PanelAnchor::BottomLeft);
        assert_eq!(PanelAnchor::nearest(work, (1700, 900)), PanelAnchor::BottomRight);
    }

    #[test]
    fn a_live_drag_suppresses_nothing_and_keeps_user_movement() {
        // A placement call may not arm the window while a native drag owns the window…
        assert_eq!(move_suppression_deadline(true, 1_000), None);
        // …and a move that lands inside a window armed before the press is still the user's.
        assert!(move_is_user_driven(true, 1_050, 1_600));

        // Outside a drag the window is armed, and moves inside it are our own.
        assert_eq!(move_suppression_deadline(false, 1_000), Some(1_600));
        assert!(!move_is_user_driven(false, 1_050, 1_600));
        // Once the window lapses, the next move is user movement again.
        assert!(move_is_user_driven(false, 1_600, 1_600));
        assert!(move_is_user_driven(false, 1_601, 0));
    }

    #[test]
    fn a_held_pointer_keeps_the_drag_alive_past_the_quiet_window() {
        // Quiet but still holding the button: the drag has not ended, so nothing may snap yet.
        assert!(!drag_settle_finished(1_400, 1_350, true));
        // Released and quiet: the panel can snap to the corner the drop chose.
        assert!(drag_settle_finished(1_400, 1_350, false));
        // Released but still moving: wait for the quiet window to pass.
        assert!(!drag_settle_finished(1_300, 1_350, false));
        // Pressed mid-move is never finished either.
        assert!(!drag_settle_finished(1_300, 1_350, true));
    }

    #[test]
    fn a_swapped_mouse_watches_the_right_button_for_the_drag_release() {
        // Normal mouse: the logical-primary press the header receives is the left button.
        assert_eq!(primary_button_virtual_key(false), 0x01);
        // "Swap primary and secondary buttons" makes the same press arrive as the right button.
        assert_eq!(primary_button_virtual_key(true), 0x02);
        // Only the high bit of GetAsyncKeyState means "currently down"; the low bit is "pressed since".
        assert!(key_state_is_down(0x8000u16 as i16));
        assert!(key_state_is_down(0x8001u16 as i16));
        assert!(!key_state_is_down(0));
        assert!(!key_state_is_down(0x0001));
    }

    #[test]
    fn placement_roundtrips_through_camel_case_json() {
        let saved = PanelPlacement {
            anchor: PanelAnchor::TopLeft,
        };
        assert_eq!(serde_json::to_string(&saved).unwrap(), r#"{"anchor":"topLeft"}"#);
        assert_eq!(
            serde_json::from_str::<PanelPlacement>(r#"{"anchor":"bottomRight"}"#).unwrap().anchor,
            PanelAnchor::BottomRight
        );
        // Unknown or missing values fall back to following the taskbar rather than failing to start.
        assert_eq!(
            serde_json::from_str::<PanelPlacement>(r#"{}"#).unwrap().anchor,
            PanelAnchor::Auto
        );
        assert!(serde_json::from_str::<PanelPlacement>(r#"{"anchor":"middle"}"#).is_err());
    }
}
