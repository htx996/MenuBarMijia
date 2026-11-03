#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod home_assistant;
mod camera;
mod credentials;
mod network;
mod placement;
mod update;
mod window;
mod update_manifest;
use camera::*;
use credentials::*;
use home_assistant::{ha_execute, ha_snapshot};
use network::*;
use placement::{
    drag_settle_finished, fit_panel_height, key_state_is_down, move_is_user_driven,
    move_suppression_deadline, place, primary_button_virtual_key, resized_top, taskbar_edge,
    PanelAnchor, PanelPlacement, PlacementInput, Rect, DRAG_SETTLE_MS,
};
use update::*;
use window::*;

#[cfg(test)]
static ORIGIN_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use ring::digest::{digest, SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{
    menu::{Menu, MenuBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow, WindowEvent,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

/// Keeps spawned helper processes (go2rtc, ffmpeg) from flashing a console window.
#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

struct TrayAndHotkeyState {
    active_shortcut: Option<Shortcut>,
    shortcut_label: Option<String>,
    update_version: Option<String>,
}

static TRAY_AND_HOTKEY_STATE: LazyLock<RwLock<TrayAndHotkeyState>> = LazyLock::new(|| {
    RwLock::new(TrayAndHotkeyState {
        active_shortcut: None,
        shortcut_label: Some("Alt+M".to_string()),
        update_version: None,
    })
});

fn is_standalone_function_key(code: Code) -> bool {
    matches!(
        code,
        Code::F1
            | Code::F2
            | Code::F3
            | Code::F4
            | Code::F5
            | Code::F6
            | Code::F7
            | Code::F8
            | Code::F9
            | Code::F10
            | Code::F11
            | Code::F12
            | Code::F13
            | Code::F14
            | Code::F15
            | Code::F16
            | Code::F17
            | Code::F18
            | Code::F19
            | Code::F20
    )
}

/// Validates and parses a global shortcut string (#43).
/// Requires at least one modifier (`Ctrl`/`Alt`/`Shift`/`Super`) or a standalone `F1`–`F20` key.
fn parse_global_shortcut(raw: &str) -> Result<(Shortcut, String), String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("快捷键不能为空".to_string());
    }
    let shortcut = Shortcut::from_str(trimmed)
        .map_err(|_| format!("快捷键格式无效：{trimmed}"))?;
    if shortcut.mods.is_empty() && !is_standalone_function_key(shortcut.key) {
        return Err("快捷键需要包含 Ctrl / Alt / Shift / Win 修饰键，或使用 F1–F20".to_string());
    }
    Ok((shortcut, trimmed.to_string()))
}

/// Windows release page opened from the tray/update row (#39).
const RELEASE_PAGE_URL: &str = "https://github.com/jryang1997/MenuBarMijia/releases/latest";

/// Offline Ed25519 public key (32-byte raw, base64) shared with `UpdateChecker.updateSigningPublicKeyBase64` (ADR-0005).
const UPDATE_SIGNING_PUBLIC_KEY_BASE64: &str = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo=";

/// Optional second key trusted during a rotation; empty when unused.
/// See `docs/security/update-signing-key-rotation.md`.
const UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64: &str = "";


fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn tray_labels_for_shortcut(shortcut_label: Option<&str>) -> (String, String) {
    match shortcut_label.map(str::trim).filter(|s| !s.is_empty()) {
        Some(label) => (
            format!("打开/隐藏控制中心 ({label})"),
            format!("MenuBarMijia · 菜单栏米家 ({label})"),
        ),
        None => (
            "打开/隐藏控制中心".to_string(),
            "MenuBarMijia · 菜单栏米家".to_string(),
        ),
    }
}

/// Rebuilds the tray menu, adding the "有新版本" entry only when a release is known (#39)
/// and showing the active global shortcut when enabled (#43).
fn build_tray_menu(
    app: &AppHandle,
    shortcut_label: Option<&str>,
    update_version: Option<&str>,
) -> tauri::Result<Menu<tauri::Wry>> {
    let (toggle_text, _) = tray_labels_for_shortcut(shortcut_label);
    let mut builder = MenuBuilder::new(app).text("toggle", toggle_text);
    if let Some(version) = update_version {
        builder = builder.text("update", format!("有新版本 v{version}，点击查看"));
    }
    builder.text("quit", "退出 MenuBarMijia").build()
}

fn refresh_tray_chrome(app: &AppHandle, shortcut_label: Option<&str>, update_version: Option<&str>) {
    let Some(tray) = app.tray_by_id("main-tray") else {
        return;
    };
    let (_, tooltip) = tray_labels_for_shortcut(shortcut_label);
    let _ = tray.set_tooltip(Some(tooltip));
    if let Ok(menu) = build_tray_menu(app, shortcut_label, update_version) {
        let _ = tray.set_menu(Some(menu));
    }
}

/// Applies the user's global shortcut preference (#43), adhering to Coding Standard #3:
/// disabling immediately unregisters the system-wide hotkey; enabling or changing unregisters
/// any previous hotkey before registering the new one and surfaces conflicts as `Err`.
#[tauri::command]
fn set_global_shortcut(app: AppHandle, enabled: bool, shortcut: String) -> Result<(), String> {
    let (old_shortcut, update_version) = {
        let guard = TRAY_AND_HOTKEY_STATE
            .read()
            .map_err(|_| "快捷键状态不可用".to_string())?;
        (guard.active_shortcut, guard.update_version.clone())
    };

    if !enabled {
        if let Some(old) = old_shortcut {
            let _ = app.global_shortcut().unregister(old);
        }
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Ok(());
    }

    let (parsed, label) = parse_global_shortcut(&shortcut)?;
    if old_shortcut == Some(parsed) && app.global_shortcut().is_registered(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.shortcut_label = Some(label.clone());
        }
        refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
        return Ok(());
    }

    if let Some(old) = old_shortcut {
        let _ = app.global_shortcut().unregister(old);
    }

    if let Err(err) = app.global_shortcut().register(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Err(format!("这个组合已被其他应用占用或无法注册（{err}），换一个再试。"));
    }

    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(parsed);
        guard.shortcut_label = Some(label.clone());
    }
    refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
    Ok(())
}

fn main() {
    let default_shortcut = Shortcut::new(Some(Modifiers::ALT), Code::KeyM);
    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(default_shortcut);
        guard.shortcut_label = Some("Alt+M".to_string());
    }

    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let matches = TRAY_AND_HOTKEY_STATE
                        .read()
                        .ok()
                        .and_then(|guard| guard.active_shortcut)
                        .is_some_and(|active| &active == shortcut);
                    if matches {
                        toggle_main_window(app, None, false);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            ha_snapshot,
            ha_execute,
            native_http,
            set_allowed_origins,
            set_service_endpoints,
            secure_store_get,
            secure_store_set,
            secure_store_delete,
            hide_panel,
            quit_app,
            set_panel_height,
            set_pin_popover,
            panel_placement,
            set_panel_placement,
            start_panel_drag,
            set_update_available,
            set_global_shortcut,
            open_release_page,
            install_update,
            start_xiaomi_camera_bridge,
            bridge_hls_camera_stream,
            stop_xiaomi_camera_bridge,
            go2rtc_endpoint,
            go2rtc_jpeg_frame
        ])
        .setup(move |app| {
            sweep_stale_update_installers();
            if let Some(path) = authorization_store_path() {
                if let Ok(mut guard) = EXTRA_ALLOWED_ORIGINS.write() {
                    *guard = read_origin_store(&path);
                }
            }
            let _ = app.global_shortcut().register(default_shortcut);
            load_panel_placement();
            if let Some(main_win) = app.get_webview_window("main") {
                position_popover(&main_win, None);
                let win_for_event = main_win.clone();
                let app_for_events = app.handle().clone();
                main_win.on_window_event(move |event| match event {
                    WindowEvent::Focused(false) => {
                        if !PIN_POPOVER.load(Ordering::SeqCst) {
                            LAST_FOCUS_LOSS_MS.store(now_epoch_ms(), Ordering::SeqCst);
                            let _ = win_for_event.hide();
                        }
                    }
                    // Drag-to-move: a header press hands over to the OS move loop, and the resulting
                    // moves snap to the nearest work-area corner once the drag settles (#204).
                    WindowEvent::Moved(_) => note_user_move(&app_for_events),
                    _ => {}
                });
            }

            let menu = build_tray_menu(app.handle(), Some("Alt+M"), None)?;

            let mut tray_builder = TrayIconBuilder::with_id("main-tray")
                .tooltip("MenuBarMijia · 菜单栏米家 (Alt+M)")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_main_window(app, None, false),
                    "update" => {
                        if let Some(window) = app.get_webview_window("main") {
                            PIN_POPOVER.store(true, Ordering::SeqCst);
                            position_popover(&window, None);
                            let _ = window.show();
                            let _ = window.set_focus();
                            let _ = window.eval(
                                "window.dispatchEvent(new CustomEvent('menumijia:open-update'))",
                            );
                        } else if let Ok(url) = validated_release_url(RELEASE_PAGE_URL) {
                            open_url_in_browser(&url);
                        }
                    }
                    "quit" => {
                        shutdown_camera_daemons();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        position,
                        ..
                    } = event
                    {
                        toggle_main_window(tray.app_handle(), Some(position), true);
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }

            let _tray = tray_builder.build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running MenuBarMijia Windows application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_reserves_the_complete_expanded_footprint_at_each_scale() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            assert!(panel_sidecar_on_left(1178.0 * scale, 246.0 * scale, scale));
            assert!(!panel_sidecar_on_left(1178.0 * scale, 252.0 * scale, scale));
            assert!(panel_sidecar_on_left(244.0 * scale, 251.0 * scale, scale));
        }
    }



    fn extra(origins: &[&str]) -> HashSet<String> {
        origins
            .iter()
            .filter_map(|origin| normalize_extra_origin(origin))
            .collect()
    }

    fn allows(url: &str, origins: &[&str]) -> bool {
        let parsed = reqwest::Url::parse(url).expect("test URL");
        check_url_allowed(&parsed, &extra(origins)).is_ok()
    }

    #[test]
    fn native_http_invoke_rejects_an_unconfigured_host() {
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: "http://tauri.localhost".parse().expect("local app origin"),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://not-configured.invalid/private",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let error = response.expect_err("unconfigured hosts must fail before networking");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(message.contains("not-configured.invalid"), "unexpected IPC error: {message}");
        assert!(message.contains("拒绝访问未授权来源"), "request reached transport: {message}");
    }

    #[test]
    fn allows_only_xiaomi_api_and_configured_origins() {
        assert!(allows("https://api.io.mi.com/app/home/device_list", &[]));
        assert!(allows("https://de.api.io.mi.com/app/home/device_list", &[]));
        assert!(allows(
            "https://account.xiaomi.com/longPolling/loginUrl",
            &[]
        ));
        assert!(allows("https://lp.account.xiaomi.com/lp/s?d=x", &[]));
        assert!(allows("https://miot-spec.org/miot-spec-v2/instance", &[]));
        assert!(allows(
            "https://api.deepseek.com/v1/chat/completions",
            &["https://api.deepseek.com"]
        ));
        assert!(allows("http://192.168.1.8:8123/api/", &["http://192.168.1.8:8123"]));

        assert!(!allows("https://evil.example/steal", &[]));
        assert!(!allows("https://api.io.mi.com.evil.example/app", &[]));
        assert!(!allows(
            "https://api.deepseek.com.evil.example/v1",
            &["https://api.deepseek.com"]
        ));
        assert!(!allows("file:///C:/Windows/win.ini", &[]));
    }

    #[test]
    fn built_in_services_reject_plaintext_and_alternate_ports() {
        assert!(!allows("http://api.io.mi.com/app/private", &[]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &[]));
        assert!(!allows("http://account.xiaomi.com/pass/serviceLogin", &[]));
        assert!(!allows("http://api.io.mi.com/app/private", &["http://api.io.mi.com"]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &["https://api.io.mi.com:8443"]));
    }

    #[test]
    fn configured_origins_keep_scheme_and_effective_port() {
        assert!(allows("https://api.deepseek.com/v1", &["https://api.deepseek.com:443"]));
        assert!(!allows("http://api.deepseek.com/v1", &["https://api.deepseek.com"]));
        assert!(!allows("https://api.deepseek.com:8443/v1", &["https://api.deepseek.com"]));
        assert!(allows("http://localhost:11434/api", &["http://localhost:11434"]));
        assert!(!allows("http://localhost:8123/api", &["http://localhost:11434"]));
        assert!(allows("http://[::1]:11434/api", &["http://[::1]:11434"]));
        assert!(!allows("https://user@api.io.mi.com/app", &[]));
    }

    #[test]
    fn normalizes_configured_origins_and_rejects_non_origins() {
        assert_eq!(normalize_extra_origin(" HTTPS://API.DeepSeek.com.:443/ "), Some("https://api.deepseek.com:443".to_string()));
        assert_eq!(normalize_extra_origin("http://[::1]:11434"), Some("http://[::1]:11434".to_string()));
        for invalid in ["api.deepseek.com", "https://evil.example/path", "https://evil.example?key=value", "https://evil.example#fragment", "https://user@evil.example", "file:///tmp/config", ""] {
            assert_eq!(normalize_extra_origin(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn redirects_cannot_change_origin_even_to_another_allowed_origin() {
        let origins = extra(&["https://configured.example", "http://configured.example", "https://configured.example:8443"]);
        let original = reqwest::Url::parse("https://configured.example/start").unwrap();
        let original_origin = url_origin(&original).unwrap();
        assert!(redirect_allowed(&original_origin, &reqwest::Url::parse("https://configured.example:443/next").unwrap(), &origins));
        for target in ["http://configured.example/next", "https://configured.example:8443/next", "https://api.io.mi.com/app"] {
            assert!(!redirect_allowed(&original_origin, &reqwest::Url::parse(target).unwrap(), &origins), "{target}");
        }
    }

    #[test]
    fn credential_names_are_limited_to_known_entries() {
        assert_eq!(
            allowed_credential_name("mi_session").ok(),
            Some("mi_session")
        );
        assert_eq!(allowed_credential_name("ha_token").ok(), Some("ha_token"));
        assert_eq!(
            allowed_credential_name("assistant_api_key").ok(),
            Some("assistant_api_key")
        );
        assert_eq!(
            allowed_credential_name("assistant_api_key_openrouter").ok(),
            Some("assistant_api_key_openrouter")
        );
        assert!(allowed_credential_name("arbitrary_key").is_err());
        assert!(allowed_credential_name("assistant_api_key_").is_err());
        assert!(allowed_credential_name("assistant_api_key_a/b").is_err());
    }

    #[test]
    fn allows_the_public_github_release_api_only() {
        assert!(allows(
            "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest",
            &[]
        ));
        // The browser-facing host is opened through the OS, never proxied by native_http.
        assert!(!allows("https://github.com/jryang1997/MenuBarMijia/releases", &[]));
        assert!(!allows("https://api.github.com.evil.example/latest", &[]));
    }

    #[test]
    fn installer_asset_payload_matches_the_windows_frontend_contract() {
        let raw = include_str!("../../tests/fixtures/windows-installer-asset.json");
        let payload: InstallerAssetPayload =
            serde_json::from_str(raw).expect("the Windows frontend installer payload must deserialize");
        assert_eq!(payload.name, "MenuBarMijia-9.9.9-windows-x64-setup.exe");
        assert_eq!(
            payload.download_url,
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v9.9.9/MenuBarMijia-9.9.9-windows-x64-setup.exe"
        );
        assert_eq!(payload.size_bytes, 3_145_728);
        assert_eq!(
            payload.manifest_url,
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v9.9.9/MenuBarMijia-9.9.9.update.json"
        );
    }

    #[test]
    fn only_opens_menu_barmijia_release_pages() {
        assert!(validated_release_url(RELEASE_PAGE_URL).is_ok());
        assert!(validated_release_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.0.7"
        )
        .is_ok());

        assert!(validated_release_url("http://github.com/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://evil.example/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://github.com/other/repo/releases").is_err());
        assert!(validated_release_url("https://github.com/jryang1997/MenuBarMijia").is_err());
        assert!(validated_release_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn frontend_cannot_grant_an_arbitrary_origin_and_then_request_it() {
        let _guard = ORIGIN_TEST_LOCK.lock().unwrap();
        {
            let mut guard = EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock");
            guard.clear();
        }
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http, set_allowed_origins, set_service_endpoints])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let invoke_url: reqwest::Url = "http://tauri.localhost".parse().expect("local app origin");
        let _grant = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_allowed_origins".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "origins": ["https://evil.example"]
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let _service = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_service_endpoints".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "assistantUrl": "https://evil.example",
                    "haUrl": ""
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url,
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://evil.example/steal",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock").clear();
        let error = response.expect_err("a frontend grant must not make native_http reach evil.example");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(
            message.contains("拒绝访问未授权来源"),
            "frontend grant reached transport: {message}"
        );
        assert!(message.contains("evil.example"), "unexpected IPC error: {message}");
    }

    #[test]
    fn confirmation_authorizes_only_the_configured_service_origins() {
        let empty = HashSet::new();
        let granted = decide_service_origins(
            &empty,
            "HTTPS://API.DeepSeek.com:8443/v1",
            "http://[::1]:8123/api",
            |_| true,
        )
        .expect("confirmed endpoints authorize");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1/chat/completions").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://api.deepseek.com:8443/v1").unwrap(),
            &granted
        )
        .is_err());

        let denied = decide_service_origins(&granted, "https://evil.example", "http://[::1]:8123/api", |_| false);
        assert!(denied.is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());

        let shrunk = decide_service_origins(&granted, "", "http://[::1]:8123/api", |_| false)
            .expect("dropping an endpoint does not need a new grant");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1").unwrap(),
            &shrunk
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &shrunk
        )
        .is_ok());
    }

    #[test]
    fn authorized_origin_store_roundtrips_exact_origins() {
        let dir = std::env::temp_dir().join(format!("menubarmijia-origins-{}", std::process::id()));
        let path = dir.join("authorized-http-origins.json");
        let mut origins = HashSet::new();
        origins.insert("https://api.deepseek.com:8443".to_string());
        origins.insert("http://[::1]:8123".to_string());
        write_origin_store(&path, &origins).expect("write store");
        assert_eq!(read_origin_store(&path), origins);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn panel_placement_roundtrips_and_falls_back_to_auto() {
        let dir = std::env::temp_dir().join(format!("menubarmijia-placement-{}", std::process::id()));
        let path = dir.join("panel-placement.json");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::Auto);
        write_panel_placement(&path, PanelPlacement { anchor: PanelAnchor::TopRight }).expect("write placement");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::TopRight);
        std::fs::write(&path, "{not json").expect("corrupt placement");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::Auto);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn global_shortcut_parser_accepts_modified_keys_and_function_keys_only() {
        let (alt_m, label) = parse_global_shortcut("Alt+M").expect("Alt+M is valid");
        assert_eq!(label, "Alt+M");
        assert_eq!(alt_m, Shortcut::new(Some(Modifiers::ALT), Code::KeyM));

        let (ctrl_shift_k, _) = parse_global_shortcut("Ctrl+Shift+K").expect("Ctrl+Shift+K is valid");
        assert_eq!(
            ctrl_shift_k,
            Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::KeyK)
        );

        let (f8, _) = parse_global_shortcut("F8").expect("standalone F8 is valid");
        assert_eq!(f8, Shortcut::new(None, Code::F8));

        let (ctrl_numpad1, _) = parse_global_shortcut("Ctrl+Numpad1").expect("Ctrl+Numpad1 is valid");
        assert_eq!(ctrl_numpad1, Shortcut::new(Some(Modifiers::CONTROL), Code::Numpad1));

        for invalid in ["", "   ", "M", "1", "Space", "Ctrl+", "NotAKey"] {
            assert!(
                parse_global_shortcut(invalid).is_err(),
                "expected {invalid:?} to be rejected"
            );
        }
    }

    #[test]
    fn tray_labels_include_shortcut_only_when_enabled() {
        assert_eq!(
            tray_labels_for_shortcut(Some("Ctrl+Alt+M")),
            (
                "打开/隐藏控制中心 (Ctrl+Alt+M)".to_string(),
                "MenuBarMijia · 菜单栏米家 (Ctrl+Alt+M)".to_string()
            )
        );
        assert_eq!(
            tray_labels_for_shortcut(None),
            (
                "打开/隐藏控制中心".to_string(),
                "MenuBarMijia · 菜单栏米家".to_string()
            )
        );
    }

    #[test]
    fn validates_release_asset_urls_filenames_and_sha256() {
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe"
        )
        .is_ok());
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe.sha256"
        )
        .is_ok());

        for bad in [
            "http://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://evil.example/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://github.com/other/repo/releases/download/v1.1.4/setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.4",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe?foo=1",
        ] {
            assert!(validated_release_asset_url(bad).is_err(), "{bad}");
        }

        assert!(release_asset_redirect_allowed(
            &reqwest::Url::parse("https://objects.githubusercontent.com/github-production-release-asset/123").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("https://evil.example/setup.exe").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("http://objects.githubusercontent.com/setup.exe").unwrap()
        ));

        assert_eq!(
            sanitize_installer_filename("MenuBarMijia-1.1.4-windows-x64-setup.exe").ok(),
            Some("MenuBarMijia-1.1.4-windows-x64-setup.exe".to_string())
        );
        for bad_name in [
            "../setup.exe",
            "dir/setup.exe",
            "dir\\setup.exe",
            "C:setup.exe",
            "payload.bat",
            "",
        ] {
            assert!(sanitize_installer_filename(bad_name).is_err(), "{bad_name}");
        }

        let hex = compute_sha256_hex(b"verified-windows-installer");
        assert_eq!(parse_sha256_hex(&format!("sha256:{}", hex.to_uppercase())), Some(hex.clone()));
        assert_eq!(parse_sha256_hex(&format!("{hex}  MenuBarMijia-1.1.4-windows-x64-setup.exe\n")), Some(hex));
        assert_eq!(parse_sha256_hex("sha256:1234"), None);

        // Built-in Ed25519 public key decodes to 32 bytes (ADR-0005).
        assert_eq!(
            decode_base64_strict(UPDATE_SIGNING_PUBLIC_KEY_BASE64).map(|b| b.len()),
            Some(32)
        );
        assert_eq!(
            update_signing_public_keys().first().copied(),
            Some(UPDATE_SIGNING_PUBLIC_KEY_BASE64)
        );
        assert!(update_signing_public_keys().iter().all(|key| !key.is_empty()));
        // Cross-platform CryptoKit Ed25519 signature over `b"verified-windows-installer"`.
        let test_pub_b64 = "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=";
        let test_sig_b64 =
            "KtT4QT0xAahlehckpgTkX9/sMX/HypxQGInJ5/dR9Nl78X8bKzLcRNNLEzDGH6y+W3CRzkGiuf1qgIs6DCQDAQ==";
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"verified-windows-installer"
        )
        .is_ok());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"tampered-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            UPDATE_SIGNING_PUBLIC_KEY_BASE64,
            b"verified-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature("", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());
        assert!(verify_ed25519_signature("not-base64!", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());

        assert!(elevated_launch_powershell_command(false).contains("-Verb RunAs"));
        assert!(elevated_launch_powershell_command(false).contains("-ErrorAction Stop"));
        assert!(elevated_launch_powershell_command(true).contains("msiexec.exe"));
        assert!(elevated_launch_powershell_command(true).contains("-Verb RunAs"));
    }

    #[test]
    fn go2rtc_config_requires_local_auth_and_ignores_appended_streams() {
        let session = Go2RtcSession {
            api_listen: "127.0.0.1:43123".to_string(),
            rtsp_listen: "127.0.0.1:43124".to_string(),
            username: "muser0001".to_string(),
            password: "mpass0001".to_string(),
            nonce: "mnonce0001".to_string(),
        };
        let ffmpeg = "C:/Users/test/AppData/Local/MenuBarMijia/bin/ffmpeg-silent.exe";
        let written = desired_go2rtc_config(&session, ffmpeg);
        assert!(
            !written.contains("origin:"),
            "go2rtc config must not expose wildcard CORS to arbitrary web pages: {written}"
        );
        assert!(!written.contains('*'));
        assert!(!written.contains("1984"));
        assert!(!written.contains("8554"));
        assert!(written.contains("listen: 127.0.0.1:43123"));
        assert!(written.contains("listen: 127.0.0.1:43124"));
        assert!(written.contains("local_auth: true"));
        assert!(written.contains("username: \"muser0001\""));
        assert!(written.contains("password: \"mpass0001\""));
        assert!(written.contains("nonce: \"mnonce0001\""));
        assert!(written.contains("allow_paths:"));
        assert!(written.contains(&yaml_double_quoted(ffmpeg)));
        assert!(written.contains("webrtc:\n  listen: \"\""));
        assert_eq!(
            basic_authorization_value("muser", "mpass"),
            "Basic bXVzZXI6bXBhc3M="
        );
        assert!(parse_owner(
            "pid=1\napi_listen=127.0.0.1:1984\nrtsp_listen=127.0.0.1:43124\nusername=muser0001\npassword=mpass0001\nnonce=mnonce0001\n"
        )
        .is_none());

        let rewritten_by_go2rtc = format!(
            "{written}\nstreams:\n  cam_raw_1105610385:\n    - xiaomi://127.0.0.1:5000?client_private=secret\n"
        );
        assert_eq!(
            base_go2rtc_config(&rewritten_by_go2rtc),
            base_go2rtc_config(&written)
        );
        assert_ne!(
            base_go2rtc_config(&written.replace("43123", "43125")),
            base_go2rtc_config(&written)
        );
    }

    #[test]
    fn go2rtc_reuses_only_an_authenticated_owned_instance() {
        let owned = Go2RtcOwnershipProbe {
            pid_alive: true,
            authenticated: true,
            nonce_matches: true,
            config_changed: false,
        };
        assert_eq!(decide_go2rtc_action(owned), Go2RtcAction::ReuseOwned);
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                config_changed: true,
                ..owned
            }),
            Go2RtcAction::RestartOwned
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: true,
                authenticated: false,
                nonce_matches: false,
                config_changed: true,
            }),
            Go2RtcAction::SpawnFresh
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: true,
                authenticated: true,
                nonce_matches: false,
                config_changed: false,
            }),
            Go2RtcAction::SpawnFresh
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: false,
                authenticated: true,
                nonce_matches: true,
                config_changed: false,
            }),
            Go2RtcAction::SpawnFresh
        );
        let session = Go2RtcSession {
            api_listen: "127.0.0.1:43123".to_string(),
            rtsp_listen: "127.0.0.1:43124".to_string(),
            username: "muser0001".to_string(),
            password: "mpass0001".to_string(),
            nonce: "mnonce0001".to_string(),
        };
        assert_eq!(
            go2rtc_jpeg_frame_url(&session, "cam_mjpeg_dev_cam").expect("frame url"),
            "http://127.0.0.1:43123/api/frame.jpeg?src=cam_mjpeg_dev_cam"
        );
        assert!(go2rtc_jpeg_frame_url(&session, "http://127.0.0.1:1984/api/config").is_err());
        assert!(go2rtc_jpeg_frame_url(&session, "../api/config").is_err());
        let stranger = Go2RtcSession {
            api_listen: "127.0.0.1:1984".to_string(),
            ..session
        };
        assert!(go2rtc_jpeg_frame_url(&stranger, "cam_mjpeg_dev_cam").is_err());

        let ports = reserve_loopback_ports(2).expect("loopback ports");
        assert_eq!(ports.len(), 2);
        assert_ne!(ports[0], ports[1]);
        for port in ports {
            assert!(!FORBIDDEN_GO2RTC_PORTS.contains(&port));
        }
    }

    #[test]
    fn xiaomi_quality_maps_to_go2rtc_subtype() {
        assert_eq!(xiaomi_camera_subtype(None), Ok("hd"));
        assert_eq!(xiaomi_camera_subtype(Some("auto")), Ok("auto"));
        assert_eq!(xiaomi_camera_subtype(Some("sd")), Ok("sd"));
        assert_eq!(xiaomi_camera_subtype(Some("hd")), Ok("hd"));
        assert_eq!(xiaomi_camera_subtype(Some("max")), Ok("3"));
        assert!(xiaomi_camera_subtype(Some("4k")).is_err());
    }

    #[test]
    fn bundled_component_copy_fills_a_missing_file_and_keeps_an_existing_one() {
        let root = std::env::temp_dir().join(format!("mbm-camera-bin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let bin = root.join("bin");
        std::fs::create_dir_all(&root).expect("temp dir");
        let src = root.join("go2rtc.exe");
        std::fs::write(&src, b"bundled").expect("write source");
        let dest = bin.join("go2rtc.exe");

        copy_bundled_component(&src, &dest).expect("copy missing component");
        assert_eq!(std::fs::read(&dest).expect("read copied file"), b"bundled");

        std::fs::write(&dest, b"updated").expect("write destination");
        copy_bundled_component(&src, &dest).expect("keep existing component");
        assert_eq!(std::fs::read(&dest).expect("read existing file"), b"updated");

        let leftovers = std::fs::read_dir(&bin)
            .expect("read bin dir")
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().contains(".staging-"))
            .count();
        assert_eq!(leftovers, 0, "staging files must not survive a copy");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn bundled_component_lookup_uses_the_camera_bin_resource_folder() {
        let root = std::env::temp_dir().join(format!("mbm-resource-dir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let camera_bin = root.join(CAMERA_COMPONENT_DIR);
        std::fs::create_dir_all(&camera_bin).expect("resource dir");
        let component = camera_bin.join("go2rtc.exe");
        std::fs::write(&component, b"exe").expect("write component");

        assert_eq!(
            bundled_component_source(&root, "go2rtc.exe"),
            Some(component)
        );
        assert_eq!(bundled_component_source(&root, "missing.exe"), None);
        std::fs::create_dir(camera_bin.join("ffmpeg-silent.exe")).expect("directory placeholder");
        assert_eq!(
            bundled_component_source(&root, "ffmpeg-silent.exe"),
            None,
            "a directory must not be copied as a helper binary"
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
