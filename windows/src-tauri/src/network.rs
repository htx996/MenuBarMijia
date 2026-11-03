use super::*;

/// Configured origins retain the protocol and port, so permission for one service
/// cannot authorize another service on the same host (#29).
pub(crate) static EXTRA_ALLOWED_ORIGINS: LazyLock<RwLock<HashSet<String>>> =
    LazyLock::new(|| RwLock::new(HashSet::new()));

const BUILT_IN_HOST_SUFFIXES: &[&str] = &[
    "account.xiaomi.com",
    "api.io.mi.com",
    "miot-spec.org",
    // Public release metadata for the update check (#39); no credentials are sent.
    "api.github.com",
];

pub(crate) fn normalize_host(raw: &str) -> String {
    raw.trim()
        .trim_end_matches('.')
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase()
}

pub(crate) fn url_origin(url: &reqwest::Url) -> Option<String> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let host = normalize_host(url.host_str()?);
    if host.is_empty() {
        return None;
    }
    let authority = if host.contains(':') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!(
        "{}://{}:{}", url.scheme(), authority, url.port_or_known_default()?
    ))
}

pub(crate) fn normalize_extra_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
        return None;
    }
    url_origin(&url)
}

pub(crate) fn check_url_allowed(url: &reqwest::Url, extra: &HashSet<String>) -> Result<(), String> {
    let origin = url_origin(url)
        .ok_or_else(|| "native_http 地址必须是无用户凭据的 http/https 地址".to_string())?;
    let host = normalize_host(url.host_str().unwrap_or_default());
    let built_in_host = BUILT_IN_HOST_SUFFIXES
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")));
    let allowed = if built_in_host {
        url.scheme() == "https" && url.port_or_known_default() == Some(443)
    } else {
        extra.contains(&origin)
    };
    if allowed {
        Ok(())
    } else {
        Err(format!("native_http 拒绝访问未授权来源：{origin}"))
    }
}

pub(crate) fn redirect_allowed(original_origin: &str, next: &reqwest::Url, extra: &HashSet<String>) -> bool {
    url_origin(next).as_deref() == Some(original_origin) && check_url_allowed(next, extra).is_ok()
}

pub(crate) fn allowed_origins_snapshot() -> Result<HashSet<String>, String> {
    EXTRA_ALLOWED_ORIGINS
        .read()
        .map(|origins| origins.clone())
        .map_err(|_| "origin allowlist unavailable".to_string())
}


#[derive(Serialize)]
pub(crate) struct NativeHttpResponse {
    pub(crate) status: u16,
    pub(crate) headers: HashMap<String, String>,
    pub(crate) body: String,
}

#[tauri::command]
pub(crate) async fn native_http(
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    follow_redirects: Option<bool>,
    timeout_ms: Option<u64>,
) -> Result<NativeHttpResponse, String> {
    let allowed_origins = allowed_origins_snapshot()?;
    let parsed_url = reqwest::Url::parse(&url).map_err(|e| format!("native_http 地址无效：{e}"))?;
    check_url_allowed(&parsed_url, &allowed_origins)?;

    let follow = follow_redirects.unwrap_or(true);
    let policy = if follow {
        let redirect_origins = allowed_origins.clone();
        let original_origin = url_origin(&parsed_url).expect("validated request origin");
        reqwest::redirect::Policy::custom(move |attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            // Even another configured origin must not receive this request's headers or body.
            if redirect_allowed(&original_origin, attempt.url(), &redirect_origins) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        })
    } else {
        reqwest::redirect::Policy::none()
    };

    let client = reqwest::Client::builder()
        .redirect(policy)
        .timeout(Duration::from_millis(timeout_ms.unwrap_or(15_000)))
        .build()
        .map_err(|e| e.to_string())?;

    let verb = method.unwrap_or_else(|| "GET".to_string()).to_uppercase();
    let mut req = match verb.as_str() {
        "GET" => client.get(&url),
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "PATCH" => client.patch(&url),
        "DELETE" => client.delete(&url),
        other => return Err(format!("native_http 不支持的方法：{other}")),
    };

    if let Some(hdrs) = headers {
        let mut map = HeaderMap::new();
        for (k, v) in hdrs {
            // Request framing is owned by reqwest; letting the frontend set these
            // could smuggle a second request past the URL allowlist.
            if matches!(
                k.to_ascii_lowercase().as_str(),
                "host" | "content-length" | "transfer-encoding" | "connection" | "upgrade"
            ) {
                continue;
            }
            if let (Ok(name), Ok(val)) = (HeaderName::from_str(&k), HeaderValue::from_str(&v)) {
                map.insert(name, val);
            }
        }
        req = req.headers(map);
    }

    if let Some(b) = body {
        req = req.body(b);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    // A stopped redirect comes back as a 3xx here; surfacing it as an error is
    // clearer than handing the frontend a response from a host it may not use.
    if follow && resp.status().is_redirection() && status != 304 {
        return Err("native_http 拒绝跨来源或未授权重定向".to_string());
    }

    let mut out_headers: HashMap<String, String> = HashMap::new();
    for (name, val) in resp.headers().iter() {
        if let Ok(v_str) = val.to_str() {
            let key = name.as_str().to_lowercase();
            out_headers
                .entry(key)
                .and_modify(|existing| {
                    existing.push_str("; ");
                    existing.push_str(v_str);
                })
                .or_insert_with(|| v_str.to_string());
        }
    }

    let text = resp.text().await.map_err(|e| e.to_string())?;
    Ok(NativeHttpResponse {
        status,
        headers: out_headers,
        body: text,
    })
}

#[tauri::command]
pub(crate) fn set_allowed_origins(_origins: Vec<String>) -> Result<(), String> {
    Err("前端不能自行授权网络来源".into())
}

pub(crate) fn origin_from_endpoint(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let url = reqwest::Url::parse(&with_scheme).ok()?;
    url_origin(&url)
}

pub(crate) fn requested_service_origins(assistant_url: &str, ha_url: &str) -> Result<HashSet<String>, String> {
    let mut origins = HashSet::new();
    for raw in [assistant_url, ha_url] {
        if raw.trim().is_empty() {
            continue;
        }
        let origin = origin_from_endpoint(raw)
            .ok_or_else(|| format!("invalid configured endpoint: {raw}"))?;
        origins.insert(origin);
    }
    Ok(origins)
}

pub(crate) fn read_origin_store(path: &std::path::Path) -> HashSet<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashSet::new();
    };
    let Ok(values) = serde_json::from_str::<Vec<String>>(&text) else {
        return HashSet::new();
    };
    values
        .into_iter()
        .filter_map(|value| normalize_extra_origin(&value))
        .collect()
}

pub(crate) fn write_origin_store(path: &std::path::Path, origins: &HashSet<String>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存已授权来源：{error}"))?;
    }
    let mut values: Vec<&String> = origins.iter().collect();
    values.sort();
    let body = serde_json::to_string(&values).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存已授权来源：{error}"))
}

/// `%APPDATA%\MenuBarMijia`, the folder for the Windows-only state files.
#[cfg(not(test))]
pub(crate) fn app_state_dir() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(std::path::PathBuf::from(base).join("MenuBarMijia"))
}

#[cfg(test)]
pub(crate) fn authorization_store_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
pub(crate) fn authorization_store_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("authorized-http-origins.json"))
}

pub(crate) fn store_authorized(origins: &HashSet<String>) -> Result<(), String> {
    if let Some(path) = authorization_store_path() {
        write_origin_store(&path, origins)?;
    }
    let mut guard = EXTRA_ALLOWED_ORIGINS
        .write()
        .map_err(|_| "origin allowlist unavailable".to_string())?;
    *guard = origins.clone();
    Ok(())
}

pub(crate) fn decide_service_origins(
    current: &HashSet<String>,
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<HashSet<String>, String> {
    let requested = requested_service_origins(assistant_url, ha_url)?;
    let mut novel: Vec<String> = requested.difference(current).cloned().collect();
    novel.sort();
    for origin in &novel {
        if !confirm(origin) {
            return Err(format!("未授权的网络来源：{origin}"));
        }
    }
    Ok(requested)
}

pub(crate) fn authorize_service_endpoints(
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<(), String> {
    let current = allowed_origins_snapshot()?;
    let next = decide_service_origins(&current, assistant_url, ha_url, confirm)?;
    store_authorized(&next)
}

#[cfg(test)]
pub(crate) fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[cfg(all(windows, not(test)))]
pub(crate) fn user_confirms_origin(origin: &str) -> bool {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    let text = format!(
        "允许 MenuBarMijia 连接这个地址吗？\n\n{origin}\n\n只有你在设置里填写的 Home Assistant 或 AI 服务地址才应该出现在这里。"
    );
    let text_wide: Vec<u16> = OsStr::new(&text).encode_wide().chain(std::iter::once(0)).collect();
    let title_wide: Vec<u16> = OsStr::new("MenuBarMijia").encode_wide().chain(std::iter::once(0)).collect();
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONWARNING: u32 = 0x0000_0030;
    const MB_DEFBUTTON2: u32 = 0x0000_0100;
    const IDYES: i32 = 6;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text_wide.as_ptr(),
            title_wide.as_ptr(),
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
        ) == IDYES
    }
}

#[cfg(all(not(windows), not(test)))]
pub(crate) fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[tauri::command]
pub(crate) fn set_service_endpoints(assistant_url: String, ha_url: String) -> Result<(), String> {
    authorize_service_endpoints(&assistant_url, &ha_url, user_confirms_origin)
}
