use super::*;

const CREDENTIAL_SERVICE: &str = "com.jryang.menubarmijia";
const CREDENTIAL_NAMES: &[&str] = &["mi_session", "ha_token", "assistant_api_key"];

/// Fixed credential names only: this must not become a generic key/value store (#28).
pub(crate) fn allowed_credential_name(name: &str) -> Result<&str, String> {
    if CREDENTIAL_NAMES.contains(&name) {
        return Ok(name);
    }
    if let Some(suffix) = name.strip_prefix("assistant_api_key_") {
        if !suffix.is_empty()
            && suffix.len() <= 48
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    Err(format!("不允许的凭据名称：{name}"))
}

pub(crate) fn credential_entry(name: &str) -> Result<keyring::Entry, String> {
    let name = allowed_credential_name(name)?;
    keyring::Entry::new(CREDENTIAL_SERVICE, name)
        .map_err(|error| format!("无法打开 Windows 凭据管理器：{error}"))
}


#[tauri::command]
pub(crate) fn secure_store_get(name: String) -> Result<Option<String>, String> {
    let entry = credential_entry(&name)?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("读取 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
pub(crate) fn secure_store_set(name: String, value: String) -> Result<(), String> {
    if value.is_empty() {
        return secure_store_delete(name);
    }
    let entry = credential_entry(&name)?;
    entry
        .set_password(&value)
        .map_err(|error| format!("写入 Windows 凭据失败：{error}"))
}

#[tauri::command]
pub(crate) fn secure_store_delete(name: String) -> Result<(), String> {
    let entry = credential_entry(&name)?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("删除 Windows 凭据失败：{error}")),
    }
}
