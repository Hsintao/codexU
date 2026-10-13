use std::path::Path;
use tokio::io::AsyncWriteExt;

/// A failed read is never an empty or complete history. Messages deliberately
/// omit source paths, raw lines and low-level operating-system diagnostics.
#[derive(Debug, thiserror::Error)]
pub enum HistoryReadError {
    #[error("Local history is temporarily unreadable. Refresh to retry.")]
    Unavailable,
    #[error("Local history contains an invalid record. Refresh to retry.")]
    InvalidRecord,
    #[error("Local history changed while being read. Refresh to retry.")]
    SourceChanged,
    #[error("Local history index is in use. Refresh to retry.")]
    IndexBusy,
    #[error("Local history cache has reached its space budget. Refresh to retry.")]
    CacheFull,
    #[error("Local history processing exceeded its resource budget. Refresh to retry.")]
    ResourceLimited,
    #[error("Local history index could not be written. Refresh to retry.")]
    CacheUnavailable,
}

pub const RETAINED_HISTORY_MESSAGE: &str =
    "Local history could not be read completely; showing the last complete history. Refresh to retry.";

/// Only an EOF-truncated JSON tail may wait for the next append. A malformed
/// complete line remains an error, including when its syntax error is at EOF.
pub(super) fn read_json_record(
    line: &[u8],
    terminated: bool,
) -> Result<Option<serde_json::Value>, HistoryReadError> {
    if line.iter().all(u8::is_ascii_whitespace) {
        return Ok(None);
    }
    match serde_json::from_slice::<serde_json::Value>(line) {
        Ok(value) if value.is_object() => Ok(Some(value)),
        Err(error) if error.is_eof() && !terminated => Ok(None),
        _ => Err(HistoryReadError::InvalidRecord),
    }
}

/// A failed cache write must not truncate a previously complete cache.
pub async fn write_cache_atomically(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    tokio::fs::create_dir_all(parent).await?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(std::io::Error::other)?
        .as_nanos();
    let temporary = parent.join(format!(".cache-{}-{nonce}.tmp", std::process::id()));
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .await?;
    let result = async {
        file.write_all(data).await?;
        file.flush().await?;
        drop(file);
        tokio::fs::rename(&temporary, path).await
    }
    .await;
    if result.is_err() {
        let _ = tokio::fs::remove_file(&temporary).await;
    }
    result
}
