use super::*;

#[tauri::command]
pub(crate) async fn start_xiaomi_camera_bridge(
    app: AppHandle,
    did: String,
    model: String,
    local_ip: String,
    client_public: String,
    client_private: String,
    device_public: String,
    sign: String,
    vendor: String,
    uid: Option<String>,
    quality: Option<String>,
) -> Result<String, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let cam_ip: std::net::Ipv4Addr = local_ip
        .trim()
        .parse()
        .map_err(|_| format!("无效的局域网摄像机 IP：{local_ip}"))?;
    if !cam_ip.is_private() && !cam_ip.is_loopback() {
        return Err("仅允许局域网私有 IP 地址直连摄像机".to_string());
    }
    let subtype = xiaomi_camera_subtype(quality.as_deref())?;

    ensure_go2rtc_running(&app).await?;
    let session = current_go2rtc_session()?;

    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let raw_name = format!("cam_raw_{clean_did}");
    let h264_name = format!("cam_h264_{clean_did}");
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");

    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(6))
        .build()
        .map_err(|e| e.to_string())?;

    // A camera keeps exactly one P2P session, and the relay thread dies with its old port.
    // Dropping the previous bridge first is what makes the second open work.
    stop_bridge(&http, Some(&session), &clean_did, &[&raw_name, &h264_name, &mjpeg_name]).await;

    let relay_port = camera_relay_port(&clean_did, cam_ip)?;

    let mut query = format!(
        "client_public={}&client_private={}&device_public={}&sign={}&vendor={}&transport=udp&subtype={}&audio=0&model={}",
        urlencoding_simple(&client_public),
        urlencoding_simple(&client_private),
        urlencoding_simple(&device_public),
        urlencoding_simple(&sign),
        urlencoding_simple(&vendor),
        subtype,
        urlencoding_simple(&model)
    );
    if let Some(u) = uid.as_deref().filter(|s| !s.is_empty()) {
        query.push_str(&format!("&uid={}", urlencoding_simple(u)));
    }
    let xiaomi_url = format!("xiaomi://127.0.0.1:{relay_port}?{query}");

    put_stream(&http, &session, &raw_name, &xiaomi_url)
        .await
        .map_err(|e| format!("注册摄像机原始流失败：{e}"))?;
    // Two transcode targets: WebRTC plays H.264 with real-time pacing (it drops late frames
    // instead of buffering), while MJPEG is the fallback that paints on the first frame.
    put_stream(&http, &session, &h264_name, &format!("ffmpeg:{raw_name}#video=h264"))
        .await
        .map_err(|e| format!("注册摄像机 H.264 转码流失败：{e}"))?;
    put_stream(&http, &session, &mjpeg_name, &format!("ffmpeg:{raw_name}#video=mjpeg"))
        .await
        .map_err(|e| format!("注册摄像机 MJPEG 转码流失败：{e}"))?;

    Ok(format!("{h264_name}|{mjpeg_name}"))
}

#[tauri::command]
pub(crate) async fn bridge_hls_camera_stream(
    app: AppHandle,
    did: String,
    hls_url: String,
) -> Result<String, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let parsed =
        reqwest::Url::parse(hls_url.trim()).map_err(|_| "无效的 HLS 流地址".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("HLS 流地址必须使用 http 或 https 协议".to_string());
    }
    ensure_go2rtc_running(&app).await?;
    let session = current_go2rtc_session()?;
    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(6))
        .build()
        .map_err(|e| e.to_string())?;
    let _ = authed(
        http.delete(api_url(
            &session,
            &format!("/api/streams?src={}", urlencoding_simple(&mjpeg_name)),
        )),
        &session,
    )
    .send()
    .await;
    let path_lower = parsed.path().to_ascii_lowercase();
    let stream_src = if path_lower.contains("/api/camera_proxy")
        || path_lower.ends_with(".mjpeg")
        || path_lower.ends_with(".mjpg")
        || path_lower.ends_with("/stream.mjpeg")
    {
        parsed.as_str().to_string()
    } else {
        format!("ffmpeg:{}#video=mjpeg", parsed.as_str())
    };
    put_stream(&http, &session, &mjpeg_name, &stream_src)
        .await
        .map_err(|e| format!("注册 HLS 转码流失败：{e}"))?;
    Ok(mjpeg_name)
}

#[tauri::command]
pub(crate) async fn stop_xiaomi_camera_bridge(did: String) -> Result<(), String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;
    let raw_name = format!("cam_raw_{clean_did}");
    let h264_name = format!("cam_h264_{clean_did}");
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");
    let session = current_go2rtc_session().ok();
    stop_bridge(
        &http,
        session.as_ref(),
        &clean_did,
        &[&raw_name, &h264_name, &mjpeg_name],
    )
    .await;
    Ok(())
}

pub(crate) async fn put_stream(
    http: &reqwest::Client,
    session: &Go2RtcSession,
    name: &str,
    src: &str,
) -> Result<(), String> {
    let url = api_url(
        session,
        &format!(
            "/api/streams?name={}&src={}",
            urlencoding_simple(name),
            urlencoding_simple(src)
        ),
    );
    let resp = authed(http.put(&url), session)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if let Some(path) = go2rtc_config_path() {
        restrict_secret_file(&path);
    }
    if resp.status().is_success() {
        Ok(())
    } else {
        Err(format!("HTTP {}", resp.status()))
    }
}

pub(crate) async fn stop_bridge(
    http: &reqwest::Client,
    session: Option<&Go2RtcSession>,
    clean_did: &str,
    names: &[&str],
) {
    if let Some(session) = session {
        for name in names {
            let url = api_url(
                session,
                &format!("/api/streams?src={}", urlencoding_simple(name)),
            );
            let _ = authed(http.delete(&url), session).send().await;
        }
        if let Some(path) = go2rtc_config_path() {
            restrict_secret_file(&path);
        }
    }
    let no_active_relays = if let Ok(mut relays) = CAMERA_RELAYS.lock() {
        if let Some(relay) = relays.remove(clean_did) {
            relay.stop.store(true, Ordering::SeqCst);
        }
        relays.is_empty()
    } else {
        false
    };
    if no_active_relays {
        scrub_persisted_streams_from_config();
    }
}

struct CameraRelay {
    port: u16,
    stop: std::sync::Arc<AtomicBool>,
}

static CAMERA_RELAYS: LazyLock<std::sync::Mutex<HashMap<String, CameraRelay>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

/// Tracks the go2rtc child process spawned by this application instance so we never
/// terminate user-started `go2rtc.exe` processes by image name (#97).
static GO2RTC_PROCESS: LazyLock<std::sync::Mutex<Option<std::process::Child>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));
static GO2RTC_SESSION: LazyLock<std::sync::Mutex<Option<Go2RtcOwnerRecord>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

/// Serializes bridge start/stop end to end: two overlapping starts for the same
/// camera otherwise interleave their stop_bridge/register sequences and the
/// newer bridge ends up deleted by the stale one (#97).
static CAMERA_BRIDGE_LOCK: LazyLock<tauri::async_runtime::Mutex<()>> =
    LazyLock::new(|| tauri::async_runtime::Mutex::new(()));

pub(crate) fn scrub_persisted_streams_from_config() {
    let Some(cfg_path) = go2rtc_config_path() else {
        return;
    };
    let Ok(existing) = std::fs::read_to_string(&cfg_path) else {
        return;
    };
    if !existing.contains("streams:") {
        return;
    }
    let cleaned = format!("{}\n", base_go2rtc_config(&existing));
    let _ = write_secret_file(&cfg_path, &cleaned);
}

pub(crate) fn shutdown_camera_daemons() {
    if let Ok(mut relays) = CAMERA_RELAYS.lock() {
        for (_, relay) in relays.drain() {
            relay.stop.store(true, Ordering::SeqCst);
        }
    }
    if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = None;
    }
    scrub_persisted_streams_from_config();
}

/// The app-owned part of go2rtc.yaml, without the `streams:` section go2rtc appends.
pub(crate) fn base_go2rtc_config(yaml: &str) -> String {
    let mut kept = Vec::new();
    let mut in_streams = false;
    for line in yaml.split('\n') {
        let trimmed_cr = line.trim_end_matches('\r');
        let is_top_level = trimmed_cr
            .chars()
            .next()
            .is_some_and(|c| !c.is_whitespace());
        if is_top_level {
            in_streams = trimmed_cr.starts_with("streams:");
        }
        if !in_streams {
            kept.push(trimmed_cr);
        }
    }
    kept.join("\n").trim().to_string()
}

#[derive(Clone)]
pub(crate) struct Go2RtcSession {
    pub(crate) api_listen: String,
    pub(crate) rtsp_listen: String,
    pub(crate) username: String,
    pub(crate) password: String,
    pub(crate) nonce: String,
}

pub(crate) struct Go2RtcOwnerRecord {
    pub(crate) pid: u32,
    pub(crate) session: Go2RtcSession,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Go2RtcAction {
    ReuseOwned,
    RestartOwned,
    SpawnFresh,
}

#[derive(Clone, Copy)]
pub(crate) struct Go2RtcOwnershipProbe {
    pub(crate) pid_alive: bool,
    pub(crate) authenticated: bool,
    pub(crate) nonce_matches: bool,
    pub(crate) config_changed: bool,
}

pub(crate) const FORBIDDEN_GO2RTC_PORTS: [u16; 3] = [1984, 8554, 8555];

pub(crate) fn decide_go2rtc_action(probe: Go2RtcOwnershipProbe) -> Go2RtcAction {
    let owned = probe.pid_alive && probe.authenticated && probe.nonce_matches;
    if !owned {
        Go2RtcAction::SpawnFresh
    } else if probe.config_changed {
        Go2RtcAction::RestartOwned
    } else {
        Go2RtcAction::ReuseOwned
    }
}

/// v1.9.15 skips Basic auth on loopback unless `local_auth` is true.
pub(crate) fn desired_go2rtc_config(session: &Go2RtcSession, ffmpeg_bin: &str) -> String {
    let ffmpeg = yaml_double_quoted(ffmpeg_bin);
    let api = sanitized_listen(&session.api_listen);
    let rtsp = sanitized_listen(&session.rtsp_listen);
    format!(
        "api:\n  listen: {api}\n  username: {user}\n  password: {password}\n  local_auth: true\nrtsp:\n  listen: {rtsp}\nwebrtc:\n  listen: \"\"\nlog:\n  level: info\n  ffmpeg: error\nffmpeg:\n  bin: {ffmpeg}\nexec:\n  allow_paths:\n    - {ffmpeg}\nmenubarmijia:\n  nonce: {nonce}\n",
        user = yaml_double_quoted(&session.username),
        password = yaml_double_quoted(&session.password),
        nonce = yaml_double_quoted(&session.nonce),
    )
}

/// Reuses a live relay so reopening the panel does not renegotiate P2P from scratch.
pub(crate) fn camera_relay_port(clean_did: &str, cam_ip: std::net::Ipv4Addr) -> Result<u16, String> {
    let mut relays = CAMERA_RELAYS.lock().map_err(|_| "中继表不可用".to_string())?;
    if let Some(existing) = relays.get(clean_did) {
        if !existing.stop.load(Ordering::SeqCst) {
            return Ok(existing.port);
        }
    }
    relays.remove(clean_did);
    let (port, stop) = spawn_cs2_udp_relay(cam_ip)?;
    relays.insert(clean_did.to_string(), CameraRelay { port, stop });
    Ok(port)
}

pub(crate) fn urlencoding_simple(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

const GO2RTC_DOWNLOAD_URL: &str =
    "https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_win64.zip";
const GO2RTC_DOWNLOAD_SHA256: &str =
    "5b448fc90f15c925406d8da0984301985e385050222c1c2bbdf0a76fe4b1e9cb";
/// Tauri resource directory subfolder populated by `bundle.resources` (see tauri.conf.json).
pub(crate) const CAMERA_COMPONENT_DIR: &str = "camera-bin";
const CAMERA_MANUAL_BIN_HINT: &str =
    "或手动下载 go2rtc_win64.zip，解压后把 go2rtc.exe 放到 %LOCALAPPDATA%\\MenuBarMijia\\bin\\";

/// go2rtc `subtype` for a Xiaomi MISS stream (#97). `max` is numeric subtype 3, which
/// several 4K models require; `None` keeps the historical `hd` default.
pub(crate) fn xiaomi_camera_subtype(quality: Option<&str>) -> Result<&'static str, String> {
    match quality.unwrap_or("hd") {
        "auto" => Ok("auto"),
        "sd" => Ok("sd"),
        "hd" => Ok("hd"),
        "max" => Ok("3"),
        other => Err(format!("不支持的摄像机画质：{other}")),
    }
}

pub(crate) fn bundled_component_source(
    resource_dir: &std::path::Path,
    name: &str,
) -> Option<std::path::PathBuf> {
    let path = resource_dir.join(CAMERA_COMPONENT_DIR).join(name);
    path.is_file().then_some(path)
}

/// Copies a bundled helper into the writable component directory. MSI installs may keep
/// the install directory read-only, while go2rtc also writes its config and owner record
/// next to the executable, so both binaries and state live under LOCALAPPDATA.
pub(crate) fn copy_bundled_component(src: &std::path::Path, dest: &std::path::Path) -> Result<(), String> {
    if dest.is_file() {
        return Ok(());
    }
    let parent = dest.parent().ok_or_else(|| "组件目录不可用".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| format!("创建组件目录失败：{e}"))?;
    let name = dest
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("component");
    let staging = dest.with_file_name(format!("{name}.staging-{}", std::process::id()));
    let _ = std::fs::remove_file(&staging);
    std::fs::copy(src, &staging)
        .map_err(|e| format!("复制内置组件 {} 失败：{e}", src.display()))?;
    std::fs::rename(&staging, dest)
        .map_err(|e| format!("安装内置组件 {} 失败：{e}", dest.display()))?;
    Ok(())
}

pub(crate) fn ensure_component(
    app: &AppHandle,
    bin_dir: &std::path::Path,
    name: &str,
) -> Result<bool, String> {
    if bin_dir.join(name).is_file() {
        return Ok(true);
    }
    let Ok(resource_dir) = app.path().resource_dir() else {
        return Ok(false);
    };
    let Some(src) = bundled_component_source(&resource_dir, name) else {
        return Ok(false);
    };
    copy_bundled_component(&src, &bin_dir.join(name))?;
    Ok(true)
}

pub(crate) fn resolve_ffmpeg_bin(app: &AppHandle, bin_dir: &std::path::Path) -> Result<String, String> {
    for candidate in ["ffmpeg-silent.exe", "ffmpeg.exe"] {
        if bin_dir.join(candidate).is_file() {
            return Ok(bin_dir.join(candidate).to_string_lossy().replace('\\', "/"));
        }
    }
    for candidate in ["ffmpeg-silent.exe", "ffmpeg.exe"] {
        if ensure_component(app, bin_dir, candidate)? {
            return Ok(bin_dir.join(candidate).to_string_lossy().replace('\\', "/"));
        }
    }
    // A user-installed ffmpeg on PATH is the last resort; the bundled helper is preferred
    // because it is silent and version-pinned.
    Ok("ffmpeg".to_string())
}

pub(crate) async fn download_go2rtc_win64(
    bin_dir: &std::path::Path,
    exe_path: &std::path::Path,
) -> Result<(), String> {
    let mut last_error = String::new();
    for attempt in 1..=3 {
        match download_go2rtc_once(bin_dir, exe_path).await {
            Ok(()) => return Ok(()),
            Err(error) => {
                last_error = error;
                if attempt < 3 {
                    tokio::time::sleep(Duration::from_millis(700 * attempt)).await;
                }
            }
        }
    }
    Err(format!(
        "首次打开摄像机需自动下载流媒体组件 go2rtc，但下载失败（{last_error}）。请检查网络后重试，{CAMERA_MANUAL_BIN_HINT}"
    ))
}

pub(crate) async fn download_go2rtc_once(
    bin_dir: &std::path::Path,
    exe_path: &std::path::Path,
) -> Result<(), String> {
    std::fs::create_dir_all(bin_dir).map_err(|e| format!("创建组件目录失败：{e}"))?;
    // GitHub release assets redirect to release-assets.githubusercontent.com; 45 s was too
    // short for a slow link and surfaced as an opaque body-decode error (#200).
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .get(GO2RTC_DOWNLOAD_URL)
        .send()
        .await
        .map_err(|e| format!("网络连接失败（{e}）"))?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status().as_u16()));
    }
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("读取组件数据失败（{e}）"))?;
    let actual_sha256 = compute_sha256_hex(&bytes);
    if actual_sha256 != GO2RTC_DOWNLOAD_SHA256 {
        return Err("SHA-256 校验未通过，已拒绝加载".to_string());
    }

    let staging_dir = bin_dir.join(format!("staging-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging_dir);
    std::fs::create_dir_all(&staging_dir).map_err(|e| format!("创建解压目录失败：{e}"))?;
    let zip_path = staging_dir.join("go2rtc_win64.zip");
    std::fs::write(&zip_path, &bytes).map_err(|e| format!("写入临时压缩包失败：{e}"))?;

    let status = std::process::Command::new("tar.exe")
        .args([
            "-xf",
            &zip_path.to_string_lossy(),
            "-C",
            &staging_dir.to_string_lossy(),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map_err(|e| format!("解压 go2rtc.exe 失败：{e}"))?;
    let extracted = staging_dir.join("go2rtc.exe");
    if !status.success() || !extracted.exists() {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return Err("解压流媒体组件 go2rtc.exe 失败".to_string());
    }
    let _ = std::fs::remove_file(exe_path);
    std::fs::rename(&extracted, exe_path).map_err(|e| format!("安装 go2rtc.exe 失败：{e}"))?;
    let _ = std::fs::remove_dir_all(&staging_dir);
    Ok(())
}

pub(crate) fn running_child_pid() -> Option<u32> {
    let mut guard = GO2RTC_PROCESS.lock().ok()?;
    let child = guard.as_mut()?;
    match child.try_wait() {
        Ok(None) => Some(child.id()),
        _ => {
            *guard = None;
            None
        }
    }
}

pub(crate) fn current_go2rtc_session() -> Result<Go2RtcSession, String> {
    let guard = GO2RTC_SESSION
        .lock()
        .map_err(|_| "流媒体会话不可用".to_string())?;
    guard
        .as_ref()
        .map(|record| record.session.clone())
        .ok_or_else(|| "本地流媒体服务未启动".to_string())
}

pub(crate) fn store_go2rtc_session(record: Go2RtcOwnerRecord) {
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = Some(record);
    }
}

pub(crate) fn bin_directory() -> Result<std::path::PathBuf, String> {
    let local = std::env::var("LOCALAPPDATA").map_err(|_| "无法读取 LOCALAPPDATA 目录".to_string())?;
    Ok(std::path::PathBuf::from(local).join("MenuBarMijia").join("bin"))
}

pub(crate) fn go2rtc_config_path() -> Option<std::path::PathBuf> {
    bin_directory().ok().map(|dir| dir.join("go2rtc.yaml"))
}

pub(crate) fn go2rtc_owner_path() -> Option<std::path::PathBuf> {
    bin_directory().ok().map(|dir| dir.join("go2rtc.owner"))
}

pub(crate) fn write_secret_file(path: &std::path::Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建组件目录失败：{e}"))?;
    }
    std::fs::write(path, contents).map_err(|e| format!("写入 go2rtc 配置失败：{e}"))?;
    restrict_secret_file(path);
    Ok(())
}

pub(crate) fn restrict_secret_file(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    {
        let Ok(user) = std::env::var("USERNAME") else {
            return;
        };
        if user.is_empty()
            || user
                .bytes()
                .any(|byte| matches!(byte, b'"' | b'&' | b'|' | b'\n' | b'\r' | b'%'))
        {
            return;
        }
        let mut cmd = std::process::Command::new("icacls");
        cmd.arg(path)
            .arg("/inheritance:r")
            .arg("/grant:r")
            .arg(format!("{user}:(F)"))
            .creation_flags(CREATE_NO_WINDOW);
        let _ = cmd.status();
    }
}

pub(crate) fn api_url(session: &Go2RtcSession, path_and_query: &str) -> String {
    format!("http://{}{path_and_query}", session.api_listen)
}

pub(crate) fn authed(builder: reqwest::RequestBuilder, session: &Go2RtcSession) -> reqwest::RequestBuilder {
    builder.basic_auth(&session.username, Some(&session.password))
}

pub(crate) fn basic_authorization_value(username: &str, password: &str) -> String {
    format!(
        "Basic {}",
        base64_encode(format!("{username}:{password}").as_bytes())
    )
}

pub(crate) fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut index = 0;
    while index + 3 <= data.len() {
        let value = ((data[index] as u32) << 16)
            | ((data[index + 1] as u32) << 8)
            | (data[index + 2] as u32);
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        out.push(TABLE[((value >> 6) & 63) as usize] as char);
        out.push(TABLE[(value & 63) as usize] as char);
        index += 3;
    }
    if index < data.len() {
        let remain = data.len() - index;
        let mut value = (data[index] as u32) << 16;
        if remain == 2 {
            value |= (data[index + 1] as u32) << 8;
        }
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        if remain == 2 {
            out.push(TABLE[((value >> 6) & 63) as usize] as char);
            out.push('=');
        } else {
            out.push('=');
            out.push('=');
        }
    }
    out
}

pub(crate) fn yaml_double_quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' | '\r' => {}
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

pub(crate) fn is_credential_token(value: &str) -> bool {
    (8..=128).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

pub(crate) fn is_acceptable_go2rtc_listen(value: &str) -> bool {
    let Some(port_text) = value.strip_prefix("127.0.0.1:") else {
        return false;
    };
    let Ok(port) = port_text.parse::<u16>() else {
        return false;
    };
    port > 0 && !FORBIDDEN_GO2RTC_PORTS.contains(&port) && value == format!("127.0.0.1:{port}")
}

pub(crate) fn sanitized_listen(value: &str) -> String {
    if is_acceptable_go2rtc_listen(value) {
        value.to_string()
    } else {
        "127.0.0.1:9".to_string()
    }
}

pub(crate) fn random_credential_token() -> Result<String, String> {
    let rng = SystemRandom::new();
    let mut bytes = [0u8; 16];
    rng.fill(&mut bytes)
        .map_err(|_| "无法生成流媒体凭据".to_string())?;
    let mut out = String::from("m");
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    Ok(out)
}

pub(crate) fn make_ephemeral_go2rtc_session() -> Result<Go2RtcSession, String> {
    let ports = reserve_loopback_ports(2)?;
    Ok(Go2RtcSession {
        api_listen: format!("127.0.0.1:{}", ports[0]),
        rtsp_listen: format!("127.0.0.1:{}", ports[1]),
        username: random_credential_token()?,
        password: random_credential_token()?,
        nonce: random_credential_token()?,
    })
}

pub(crate) fn reserve_loopback_ports(count: usize) -> Result<Vec<u16>, String> {
    let mut listeners = Vec::new();
    let mut ports = Vec::new();
    for _ in 0..64 {
        if ports.len() == count {
            break;
        }
        let Ok(listener) = std::net::TcpListener::bind("127.0.0.1:0") else {
            continue;
        };
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        if FORBIDDEN_GO2RTC_PORTS.contains(&port) || ports.contains(&port) {
            drop(listener);
            continue;
        }
        ports.push(port);
        listeners.push(listener);
    }
    drop(listeners);
    if ports.len() != count {
        return Err("无法分配本地流媒体端口".to_string());
    }
    Ok(ports)
}

pub(crate) fn serialize_owner(record: &Go2RtcOwnerRecord) -> String {
    format!(
        "pid={}\nnonce={}\napi_listen={}\nrtsp_listen={}\nusername={}\npassword={}\n",
        record.pid,
        record.session.nonce,
        record.session.api_listen,
        record.session.rtsp_listen,
        record.session.username,
        record.session.password
    )
}

pub(crate) fn parse_owner(text: &str) -> Option<Go2RtcOwnerRecord> {
    let mut fields = std::collections::HashMap::<String, String>::new();
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !key.is_empty() && !value.is_empty() {
            fields.insert(key.to_string(), value.to_string());
        }
    }
    let pid = fields.get("pid")?.parse::<u32>().ok()?;
    let nonce = fields.get("nonce")?.clone();
    let api_listen = fields.get("api_listen")?.clone();
    let rtsp_listen = fields.get("rtsp_listen")?.clone();
    let username = fields.get("username")?.clone();
    let password = fields.get("password")?.clone();
    if !is_credential_token(&nonce)
        || !is_credential_token(&username)
        || !is_credential_token(&password)
        || !is_acceptable_go2rtc_listen(&api_listen)
        || !is_acceptable_go2rtc_listen(&rtsp_listen)
    {
        return None;
    }
    Some(Go2RtcOwnerRecord {
        pid,
        session: Go2RtcSession {
            api_listen,
            rtsp_listen,
            username,
            password,
            nonce,
        },
    })
}

pub(crate) fn read_owner() -> Option<Go2RtcOwnerRecord> {
    let path = go2rtc_owner_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    parse_owner(&text)
}

pub(crate) fn process_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(windows)]
    {
        extern "system" {
            fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut core::ffi::c_void;
            fn GetExitCodeProcess(handle: *mut core::ffi::c_void, code: *mut u32) -> i32;
            fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
        }
        const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
        const STILL_ACTIVE: u32 = 259;
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            ok != 0 && code == STILL_ACTIVE
        }
    }
    #[cfg(not(windows))]
    {
        let _ = pid;
        false
    }
}

pub(crate) fn terminate_pid(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(windows)]
    {
        extern "system" {
            fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut core::ffi::c_void;
            fn TerminateProcess(handle: *mut core::ffi::c_void, code: u32) -> i32;
            fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
        }
        const PROCESS_TERMINATE: u32 = 0x0001;
        unsafe {
            let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !handle.is_null() {
                TerminateProcess(handle, 1);
                CloseHandle(handle);
            }
        }
    }
}

pub(crate) struct OwnedApiProbe {
    reachable: bool,
    authenticated: bool,
    nonce_matches: bool,
}

pub(crate) async fn probe_owned(http: &reqwest::Client, session: &Go2RtcSession) -> OwnedApiProbe {
    let missed = OwnedApiProbe {
        reachable: false,
        authenticated: false,
        nonce_matches: false,
    };
    let Ok(response) = authed(http.get(api_url(session, "/api")), session).send().await else {
        return missed;
    };
    if !response.status().is_success() {
        return OwnedApiProbe {
            reachable: true,
            authenticated: false,
            nonce_matches: false,
        };
    }
    let Ok(config) = authed(http.get(api_url(session, "/api/config")), session)
        .send()
        .await
    else {
        return missed;
    };
    if !config.status().is_success() {
        return missed;
    }
    let Ok(body) = config.text().await else {
        return missed;
    };
    let needle = format!("nonce: {}", yaml_double_quoted(&session.nonce));
    OwnedApiProbe {
        reachable: true,
        authenticated: true,
        nonce_matches: body.contains(&needle),
    }
}

pub(crate) fn existing_owned_record() -> Option<Go2RtcOwnerRecord> {
    if let Some(pid) = running_child_pid() {
        if let Ok(guard) = GO2RTC_SESSION.lock() {
            if let Some(record) = guard.as_ref() {
                return Some(Go2RtcOwnerRecord {
                    pid,
                    session: record.session.clone(),
                });
            }
        }
    }
    if let Ok(guard) = GO2RTC_SESSION.lock() {
        if let Some(record) = guard.as_ref() {
            if process_is_alive(record.pid) {
                return Some(Go2RtcOwnerRecord {
                    pid: record.pid,
                    session: record.session.clone(),
                });
            }
        }
    }
    let saved = read_owner()?;
    if process_is_alive(saved.pid) {
        Some(saved)
    } else {
        None
    }
}

pub(crate) async fn request_owned_exit(http: &reqwest::Client, session: &Go2RtcSession) {
    let _ = authed(http.post(api_url(session, "/api/exit?code=0")), session)
        .send()
        .await;
}

pub(crate) async fn stop_owned_process(http: &reqwest::Client, record: &Go2RtcOwnerRecord) {
    request_owned_exit(http, &record.session).await;
    let child_pid = running_child_pid();
    if child_pid == Some(record.pid) {
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            if let Some(mut child) = guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
    for _ in 0..20 {
        if !process_is_alive(record.pid) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    if process_is_alive(record.pid) {
        terminate_pid(record.pid);
    }
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = None;
    }
}

pub(crate) async fn wait_for_owned_api(http: &reqwest::Client, session: &Go2RtcSession) -> bool {
    for _ in 0..25 {
        std::thread::sleep(Duration::from_millis(120));
        let probe = probe_owned(http, session).await;
        if probe.authenticated && probe.nonce_matches {
            return true;
        }
        if probe.reachable && !probe.authenticated {
            return false;
        }
        if probe.authenticated && !probe.nonce_matches {
            return false;
        }
    }
    false
}

pub(crate) async fn spawn_fresh_go2rtc(
    app: &AppHandle,
    http: &reqwest::Client,
    bin_dir: &std::path::Path,
    ffmpeg_bin: &str,
) -> Result<(), String> {
    let exe_path = bin_dir.join("go2rtc.exe");
    if !ensure_component(app, bin_dir, "go2rtc.exe")? {
        download_go2rtc_win64(bin_dir, &exe_path).await?;
    }
    let cfg_path = bin_dir.join("go2rtc.yaml");
    let owner_path = bin_dir.join("go2rtc.owner");
    for _ in 0..4 {
        let session = make_ephemeral_go2rtc_session()?;
        let desired = desired_go2rtc_config(&session, ffmpeg_bin);
        write_secret_file(&cfg_path, &desired)?;
        let mut command = std::process::Command::new(&exe_path);
        command.arg("-c").arg(&cfg_path).current_dir(bin_dir);
        #[cfg(windows)]
        {
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let child = command.spawn().map_err(|e| format!("启动 go2rtc 失败：{e}"))?;
        let pid = child.id();
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            *guard = Some(child);
        }
        let record = Go2RtcOwnerRecord { pid, session: session.clone() };
        write_secret_file(&owner_path, &serialize_owner(&record))?;
        store_go2rtc_session(record);
        if wait_for_owned_api(http, &session).await {
            return Ok(());
        }
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            if let Some(mut child) = guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        if let Ok(mut guard) = GO2RTC_SESSION.lock() {
            *guard = None;
        }
    }
    Err("本地流媒体服务启动超时".to_string())
}

pub(crate) async fn ensure_go2rtc_running(app: &AppHandle) -> Result<(), String> {
    let bin_dir = bin_directory()?;
    std::fs::create_dir_all(&bin_dir).map_err(|e| format!("创建组件目录失败：{e}"))?;
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(800))
        .build()
        .map_err(|e| e.to_string())?;
    let ffmpeg_bin = resolve_ffmpeg_bin(app, &bin_dir)?;

    if let Some(record) = existing_owned_record() {
        let probe = probe_owned(&http, &record.session).await;
        let desired = desired_go2rtc_config(&record.session, &ffmpeg_bin);
        let existing = go2rtc_config_path()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .unwrap_or_default();
        let changed = base_go2rtc_config(&existing) != base_go2rtc_config(&desired);
        let action = decide_go2rtc_action(Go2RtcOwnershipProbe {
            pid_alive: true,
            authenticated: probe.authenticated,
            nonce_matches: probe.nonce_matches,
            config_changed: changed,
        });
        match action {
            Go2RtcAction::ReuseOwned => {
                store_go2rtc_session(record);
                return Ok(());
            }
            Go2RtcAction::RestartOwned => {
                stop_owned_process(&http, &record).await;
            }
            Go2RtcAction::SpawnFresh => {
                if running_child_pid() == Some(record.pid) {
                    if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
                        if let Some(mut child) = guard.take() {
                            let _ = child.kill();
                            let _ = child.wait();
                        }
                    }
                    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
                        *guard = None;
                    }
                }
            }
        }
    }

    spawn_fresh_go2rtc(app, &http, &bin_dir, &ffmpeg_bin).await
}

#[derive(Serialize)]
pub(crate) struct Go2RtcEndpoint {
    origin: String,
    authorization: String,
}

#[tauri::command]
pub(crate) async fn go2rtc_endpoint(app: AppHandle) -> Result<Go2RtcEndpoint, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    ensure_go2rtc_running(&app).await?;
    let session = current_go2rtc_session()?;
    let origin = format!("http://{}", session.api_listen);
    if !origin.starts_with("http://127.0.0.1:") || !is_acceptable_go2rtc_listen(&session.api_listen) {
        return Err("本地流媒体地址无效".to_string());
    }
    Ok(Go2RtcEndpoint {
        origin,
        authorization: basic_authorization_value(&session.username, &session.password),
    })
}

pub(crate) fn is_go2rtc_stream_name(src: &str) -> bool {
    !src.is_empty()
        && src.len() <= 128
        && src
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

pub(crate) fn go2rtc_jpeg_frame_url(session: &Go2RtcSession, src: &str) -> Result<String, String> {
    if !is_go2rtc_stream_name(src) {
        return Err("无效的摄像机流名称".to_string());
    }
    if !is_acceptable_go2rtc_listen(&session.api_listen) {
        return Err("本地流媒体地址无效".to_string());
    }
    Ok(api_url(
        session,
        &format!("/api/frame.jpeg?src={}", urlencoding_simple(src)),
    ))
}

#[tauri::command]
pub(crate) async fn go2rtc_jpeg_frame(src: String) -> Result<String, String> {
    let session = current_go2rtc_session()?;
    let url = go2rtc_jpeg_frame_url(&session, &src)?;
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())?;
    let response = authed(http.get(&url), &session)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!(
            "读取摄像机画面失败 (HTTP {})",
            response.status()
        ));
    }
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("摄像机画面过大".to_string());
    }
    Ok(base64_encode(&bytes))
}

pub(crate) fn spawn_cs2_udp_relay(
    cam_ip: std::net::Ipv4Addr,
) -> Result<(u16, std::sync::Arc<AtomicBool>), String> {
    use std::net::{SocketAddrV4, UdpSocket};
    use std::sync::Arc;

    // Discover the local IPv4 interface that routes to cam_ip
    let probe = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    probe
        .connect(SocketAddrV4::new(cam_ip, 32108))
        .map_err(|e| e.to_string())?;
    let local_ip = match probe.local_addr().map_err(|e| e.to_string())?.ip() {
        std::net::IpAddr::V4(v4) => v4,
        _ => std::net::Ipv4Addr::UNSPECIFIED,
    };
    drop(probe);

    let octets = cam_ip.octets();
    let broadcast_ip = std::net::Ipv4Addr::new(octets[0], octets[1], octets[2], 255);

    let local_relay = UdpSocket::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let relay_port = local_relay.local_addr().map_err(|e| e.to_string())?.port();
    local_relay
        .set_read_timeout(Some(Duration::from_millis(25)))
        .map_err(|e| e.to_string())?;

    let lan_sock = UdpSocket::bind(SocketAddrV4::new(local_ip, 0)).map_err(|e| e.to_string())?;
    lan_sock.set_broadcast(true).map_err(|e| e.to_string())?;
    lan_sock
        .set_read_timeout(Some(Duration::from_millis(25)))
        .map_err(|e| e.to_string())?;

    let stop = Arc::new(AtomicBool::new(false));
    let stop_for_thread = Arc::clone(&stop);
    std::thread::spawn(move || {
        let mut go2rtc_addr: Option<std::net::SocketAddr> = None;
        let mut cam_dynamic_port: u16 = 32108;
        let mut buf = [0u8; 2048];

        while !stop_for_thread.load(Ordering::SeqCst) {
            if let Ok((n, src)) = local_relay.recv_from(&mut buf) {
                go2rtc_addr = Some(src);
                if n >= 2 && buf[0] == 0xf1 && buf[1] == 0x30 {
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(broadcast_ip, 32108));
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(cam_ip, 32108));
                } else {
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(cam_ip, cam_dynamic_port));
                }
            }

            while let Ok((n, src)) = lan_sock.recv_from(&mut buf) {
                if src.ip() == std::net::IpAddr::V4(cam_ip) {
                    cam_dynamic_port = src.port();
                    if let Some(client_addr) = go2rtc_addr {
                        let _ = local_relay.send_to(&buf[..n], client_addr);
                    }
                }
            }
        }
    });

    Ok((relay_port, stop))
}
