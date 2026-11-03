use super::*;

pub(crate) fn validated_release_url(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "更新页面地址无效".to_string())?;
    if url.scheme() != "https" {
        return Err("更新页面只允许 https 地址".to_string());
    }
    let host = url
        .host_str()
        .map(normalize_host)
        .unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝打开非 GitHub 地址：{host}"));
    }
    if !url.path().starts_with("/jryang1997/MenuBarMijia/releases") {
        return Err("拒绝打开非 MenuBarMijia 发布页".to_string());
    }
    Ok(url.to_string())
}

#[cfg(windows)]
#[link(name = "shell32")]
extern "system" {
    fn ShellExecuteW(
        hwnd: *mut core::ffi::c_void,
        operation: *const u16,
        file: *const u16,
        parameters: *const u16,
        directory: *const u16,
        show_cmd: i32,
    ) -> isize;
}

#[cfg(windows)]
pub(crate) fn open_url_in_browser(url: &str) {
    use std::os::windows::ffi::OsStrExt;

    let wide = |value: &str| -> Vec<u16> {
        std::ffi::OsStr::new(value)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    };
    let operation = wide("open");
    let file = wide(url);
    // ShellExecuteW returns a value > 32 on success; a failure has no useful recovery here.
    unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            operation.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        );
    }
}

#[cfg(not(windows))]
pub(crate) fn open_url_in_browser(_url: &str) {}

#[tauri::command]
pub(crate) fn open_release_page(url: String) -> Result<(), String> {
    let target = validated_release_url(&url)?;
    open_url_in_browser(&target);
    Ok(())
}

/// Every key a release manifest may be signed with; `key_id` selects one.
pub(crate) fn update_signing_public_keys() -> Vec<&'static str> {
    [
        UPDATE_SIGNING_PUBLIC_KEY_BASE64,
        UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64,
    ]
    .into_iter()
    .filter(|key| !key.is_empty())
    .collect()
}

const STAGED_INSTALLER_PREFIX: &str = "MenuBarMijia-update-";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct InstallerAssetPayload {
    pub(crate) name: String,
    pub(crate) download_url: String,
    #[allow(dead_code)]
    #[serde(default)]
    pub(crate) size_bytes: u64,
    pub(crate) manifest_url: String,
}

pub(crate) fn validated_release_asset_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim()).map_err(|_| "更新包下载地址无效".to_string())?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("更新包地址必须是无附加参数的 https://github.com 地址".to_string());
    }
    let host = url.host_str().map(normalize_host).unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝从非 GitHub 地址下载更新包：{host}"));
    }
    if !url
        .path()
        .starts_with("/jryang1997/MenuBarMijia/releases/download/")
    {
        return Err("拒绝下载非 MenuBarMijia 官方发布附件".to_string());
    }
    Ok(url)
}

pub(crate) fn release_asset_redirect_allowed(next: &reqwest::Url) -> bool {
    if next.scheme() != "https"
        || next.port_or_known_default() != Some(443)
        || !next.username().is_empty()
        || next.password().is_some()
    {
        return false;
    }
    let host = next.host_str().map(normalize_host).unwrap_or_default();
    host == "github.com"
        || host == "githubusercontent.com"
        || host.ends_with(".githubusercontent.com")
}

pub(crate) fn parse_sha256_hex(raw: &str) -> Option<String> {
    let token = raw.split_whitespace().next()?;
    let candidate = token
        .strip_prefix("sha256:")
        .or_else(|| token.strip_prefix("SHA256:"))
        .unwrap_or(token)
        .to_ascii_lowercase();
    if candidate.len() == 64 && candidate.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(candidate)
    } else {
        None
    }
}

pub(crate) fn sanitize_installer_filename(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains(':')
        || trimmed.contains("..")
        || trimmed.chars().any(|c| c.is_control())
    {
        return Err("更新安装包文件名无效".to_string());
    }
    let lower = trimmed.to_ascii_lowercase();
    if !lower.ends_with(".exe") && !lower.ends_with(".msi") {
        return Err("仅支持 .exe 或 .msi 安装包".to_string());
    }
    Ok(trimmed.to_string())
}

pub(crate) fn compute_sha256_hex(bytes: &[u8]) -> String {
    let sum = digest(&SHA256, bytes);
    let mut out = String::with_capacity(64);
    for byte in sum.as_ref() {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

/// Decodes standard RFC 4648 base64 (ignoring surrounding whitespace).
pub(crate) fn decode_base64_strict(raw: &str) -> Option<Vec<u8>> {
    let cleaned: Vec<u8> = raw
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    if cleaned.is_empty() || cleaned.len() % 4 != 0 {
        return None;
    }
    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity((cleaned.len() / 4) * 3);
    for (idx, chunk) in cleaned.chunks_exact(4).enumerate() {
        let is_last = idx + 1 == cleaned.len() / 4;
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        match (chunk[2], chunk[3]) {
            (b'=', b'=') if is_last => {
                if (b & 0x0f) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
            }
            (c_byte, b'=') if is_last => {
                let c = val(c_byte)?;
                if (c & 0x03) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
            }
            (b'=', _) | (_, b'=') => return None,
            (c_byte, d_byte) => {
                let c = val(c_byte)?;
                let d = val(d_byte)?;
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

/// Verifies a detached Ed25519 signature over `data` against `public_key_base64` (ADR-0005).
pub(crate) fn verify_ed25519_signature(
    signature_base64: &str,
    public_key_base64: &str,
    data: &[u8],
) -> Result<(), String> {
    let trimmed_sig = signature_base64.trim();
    if trimmed_sig.is_empty() {
        return Err("更新包缺少 Ed25519 数字签名（.ed25519.sig），已中止安装".to_string());
    }
    let key_bytes = decode_base64_strict(public_key_base64)
        .filter(|bytes| bytes.len() == 32)
        .ok_or_else(|| "内置 Ed25519 更新公钥无效".to_string())?;
    let sig_bytes = decode_base64_strict(trimmed_sig)
        .filter(|bytes| bytes.len() == 64)
        .ok_or_else(|| "更新包 Ed25519 数字签名格式无效，已中止安装".to_string())?;
    let public_key = UnparsedPublicKey::new(&ED25519, key_bytes);
    public_key
        .verify(data, &sig_bytes)
        .map_err(|_| "更新包 Ed25519 数字签名校验失败：签名与安装包内容不匹配，已中止安装".to_string())
}

pub(crate) fn sweep_stale_update_installers() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name
            .to_str()
            .is_some_and(|s| s.starts_with(STAGED_INSTALLER_PREFIX))
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

pub(crate) fn elevated_launch_powershell_command(is_msi: bool) -> &'static str {
    if is_msi {
        "Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $env:MIJIA_INSTALLER_PATH) -Verb RunAs -ErrorAction Stop"
    } else {
        "Start-Process -FilePath $env:MIJIA_INSTALLER_PATH -Verb RunAs -ErrorAction Stop"
    }
}

pub(crate) fn launch_installer(installer_path: &std::path::Path) -> Result<(), String> {
    let is_msi = installer_path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("msi"));
    let mut cmd = if is_msi {
        let mut c = std::process::Command::new("msiexec");
        c.arg("/i").arg(installer_path);
        c
    } else {
        std::process::Command::new(installer_path)
    };
    match cmd.spawn() {
        Ok(mut child) => {
            std::thread::sleep(Duration::from_millis(250));
            if let Ok(Some(status)) = child.try_wait() {
                if !status.success() {
                    return Err(format!("安装程序未能正常启动（退出码 {:?}）", status.code()));
                }
            }
            Ok(())
        }
        Err(err) if err.raw_os_error() == Some(740) => {
            // ERROR_ELEVATION_REQUIRED (740): invoke ShellExecute with -Verb RunAs so UAC prompts
            // and wait for Start-Process to finish spawning the elevated installer (or fail if declined).
            let status = std::process::Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-WindowStyle",
                    "Hidden",
                    "-Command",
                    elevated_launch_powershell_command(is_msi),
                ])
                .env("MIJIA_INSTALLER_PATH", installer_path)
                .status()
                .map_err(|e| format!("启动安装程序失败：{e}"))?;
            if !status.success() {
                return Err(format!(
                    "启动安装程序失败（未获管理员授权或启动被取消，退出码 {:?}）",
                    status.code()
                ));
            }
            Ok(())
        }
        Err(err) => Err(format!("启动安装程序失败：{err}")),
    }
}

#[tauri::command]
pub(crate) async fn install_update(app: AppHandle, asset: InstallerAssetPayload) -> Result<(), String> {
    let pair = update_manifest::release_pair(&asset.name, &asset.download_url, &asset.manifest_url)?;
    let running_version = app.package_info().version.to_string();

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            if release_asset_redirect_allowed(attempt.url()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .timeout(Duration::from_secs(120))
        .user_agent("MenuBarMijia-Windows")
        .build()
        .map_err(|err| format!("无法初始化下载客户端：{err}"))?;

    let manifest_resp = client
        .get(pair.manifest_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载更新清单失败：{err}"))?;
    if !manifest_resp.status().is_success() {
        return Err(format!(
            "下载更新清单失败（HTTP {}）",
            manifest_resp.status().as_u16()
        ));
    }
    let manifest_bytes = manifest_resp
        .bytes()
        .await
        .map_err(|err| format!("读取更新清单失败：{err}"))?;

    let sig_resp = client
        .get(pair.signature_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载 Ed25519 更新签名失败：{err}"))?;
    if sig_resp.status().as_u16() == 404 {
        return Err("更新包缺少 Ed25519 数字签名（.update.json.ed25519.sig），已中止安装".to_string());
    }
    if !sig_resp.status().is_success() {
        return Err(format!(
            "下载 Ed25519 更新签名失败（HTTP {}）",
            sig_resp.status().as_u16()
        ));
    }
    let sig_text = sig_resp
        .text()
        .await
        .map_err(|err| format!("读取 Ed25519 更新签名失败：{err}"))?;

    let response = client
        .get(pair.installer_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载更新安装包失败：{err}"))?;
    if !response.status().is_success() {
        return Err(format!("下载更新安装包失败（HTTP {}）", response.status().as_u16()));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|err| format!("读取更新安装包数据失败：{err}"))?;

    let trusted_public_keys = update_signing_public_keys();
    update_manifest::accept_update_manifest(
        &manifest_bytes,
        &sig_text,
        &trusted_public_keys,
        &pair.version,
        &running_version,
        &asset.name,
        &bytes,
    )
    .map_err(update_manifest::accept_failure_message)?;

    sweep_stale_update_installers();
    let installer_path = std::env::temp_dir().join(format!(
        "{STAGED_INSTALLER_PREFIX}{}-{}",
        std::process::id(),
        asset.name
    ));
    std::fs::write(&installer_path, &bytes)
        .map_err(|err| format!("写入临时安装程序失败：{err}"))?;

    if let Err(err) = launch_installer(&installer_path) {
        let _ = std::fs::remove_file(&installer_path);
        return Err(err);
    }

    let app_for_exit = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        app_for_exit.exit(0);
    });
    Ok(())
}

#[tauri::command]
pub(crate) fn set_update_available(app: AppHandle, version: Option<String>) -> Result<(), String> {
    let shortcut_label = {
        let mut guard = TRAY_AND_HOTKEY_STATE
            .write()
            .map_err(|_| "托盘状态不可用".to_string())?;
        guard.update_version = version.clone();
        guard.shortcut_label.clone()
    };
    let tray = app
        .tray_by_id("main-tray")
        .ok_or_else(|| "托盘尚未就绪".to_string())?;
    let menu = build_tray_menu(&app, shortcut_label.as_deref(), version.as_deref())
        .map_err(|error| error.to_string())?;
    tray.set_menu(Some(menu)).map_err(|error| error.to_string())
}

