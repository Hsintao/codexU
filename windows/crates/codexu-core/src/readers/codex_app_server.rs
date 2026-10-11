use std::{env, path::PathBuf, process::Stdio, time::Duration};

use chrono::{TimeZone, Utc};
use serde_json::Value;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines},
    process::{Child, ChildStdin, ChildStdout, Command},
    time::timeout,
};

#[cfg(windows)]
#[path = "quota_process.rs"]
mod quota_process;

use crate::models::{AccountInfo, RateWindow};

const FIVE_HOUR_DURATION_MINS: i64 = 300;
const SEVEN_DAY_DURATION_MINS: i64 = 10_080;
const MONTHLY_MIN_DURATION_MINS: i64 = 28 * 24 * 60;
const MONTHLY_MAX_DURATION_MINS: i64 = 31 * 24 * 60;
const APP_SERVER_REQUEST_TIMEOUT: Duration = Duration::from_secs(12);
const APP_SERVER_EXIT_TIMEOUT: Duration = Duration::from_secs(2);

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// Official rate-limit data read from the local Codex app-server.
#[derive(Debug, Clone, PartialEq)]
pub struct CodexAppServerQuotaSnapshot {
    pub account: Option<AccountInfo>,
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    pub quota_read_succeeded: bool,
    pub five_hour_quota: Option<RateWindow>,
    pub seven_day_quota: Option<RateWindow>,
    pub monthly_quota: Option<RateWindow>,
}

impl CodexAppServerQuotaSnapshot {
    /// Parses an `account/rateLimits/read` result without treating unknown or
    /// malformed topology as an official zero-limit response.
    pub fn from_rate_limit_response(response: &Value) -> Self {
        let Some(limits) = selected_rate_limits(response) else {
            return Self::unavailable();
        };

        let raw_windows = [limits.get("primary"), limits.get("secondary")];
        let has_window_fields = raw_windows.iter().any(|window| window.is_some());
        let parsed_windows = raw_windows.map(|window| window.and_then(parse_rate_window));
        let has_malformed_window =
            raw_windows
                .iter()
                .zip(parsed_windows.iter())
                .any(|(raw, parsed)| {
                    matches!(raw, Some(value) if !value.is_null()) && parsed.is_none()
                });

        let available = parsed_windows.iter().flatten().cloned().collect::<Vec<_>>();
        let five_hour_matches = available
            .iter()
            .filter(|window| window.window_duration_mins == Some(FIVE_HOUR_DURATION_MINS))
            .cloned()
            .collect::<Vec<_>>();
        let seven_day_matches = available
            .iter()
            .filter(|window| window.window_duration_mins == Some(SEVEN_DAY_DURATION_MINS))
            .cloned()
            .collect::<Vec<_>>();
        let monthly_matches = available
            .iter()
            .filter(|window| is_monthly_duration(window.window_duration_mins))
            .cloned()
            .collect::<Vec<_>>();
        let has_unclassified_window = available.iter().any(|window| {
            !matches!(
                window.window_duration_mins,
                Some(FIVE_HOUR_DURATION_MINS | SEVEN_DAY_DURATION_MINS)
            ) && !is_monthly_duration(window.window_duration_mins)
        });

        let quota_read_succeeded = has_window_fields
            && !has_malformed_window
            && five_hour_matches.len() <= 1
            && seven_day_matches.len() <= 1
            && monthly_matches.len() <= 1
            && !has_unclassified_window;

        if !quota_read_succeeded {
            return Self::unavailable();
        }

        Self {
            account: None,
            limit_id: limits
                .get("limitId")
                .and_then(Value::as_str)
                .map(str::to_owned),
            limit_name: limits
                .get("limitName")
                .and_then(Value::as_str)
                .map(str::to_owned),
            quota_read_succeeded,
            five_hour_quota: single_window(five_hour_matches),
            seven_day_quota: single_window(seven_day_matches),
            monthly_quota: single_window(monthly_matches),
        }
    }

    pub fn unavailable() -> Self {
        Self {
            account: None,
            limit_id: None,
            limit_name: None,
            quota_read_succeeded: false,
            five_hour_quota: None,
            seven_day_quota: None,
            monthly_quota: None,
        }
    }
}

/// Minimal boundary required to exercise the Codex JSON-RPC request sequence
/// without starting a real app-server in parser tests.
#[allow(async_fn_in_trait)]
pub trait AppServerTransport {
    async fn request(&mut self, request: Value) -> anyhow::Result<Value>;
    async fn notify(&mut self, notification: Value) -> anyhow::Result<()>;
}

/// Reads official quota through a private stdio app-server. Plugin startup is
/// disabled for this child only; it must never update the user's marketplaces.
pub async fn read_installed_codex_quota() -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    let mut command = quota_command()?;
    #[cfg(windows)]
    let (mut child, _process_tree) = quota_process::spawn(&mut command)?;
    #[cfg(not(windows))]
    let mut child = command.spawn()?;

    let result = timeout(APP_SERVER_REQUEST_TIMEOUT, async {
        let mut transport = StdioAppServerTransport {
            stdin: child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("Missing quota input"))?,
            stdout: BufReader::new(
                child
                    .stdout
                    .take()
                    .ok_or_else(|| anyhow::anyhow!("Missing quota output"))?,
            )
            .lines(),
        };
        read_quota_from_transport(&mut transport).await
    })
    .await
    .map_err(|_| anyhow::anyhow!("Timed out while reading the local Codex app-server quota"));

    // Dropping the transport closes stdin. EOF lets the single-client server
    // shut down normally; the owned Job also covers timeout/cancellation/exit.
    let exit = stop_child(&mut child).await;
    let quota = result??;
    exit?;
    Ok(quota)
}

struct StdioAppServerTransport {
    stdin: ChildStdin,
    stdout: Lines<BufReader<ChildStdout>>,
}

#[allow(async_fn_in_trait)]
impl AppServerTransport for StdioAppServerTransport {
    async fn request(&mut self, request: Value) -> anyhow::Result<Value> {
        let request_id = request
            .get("id")
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("App-server quota request was missing an id"))?;
        self.notify(request).await?;

        while let Some(payload) = self
            .stdout
            .next_line()
            .await
            .map_err(|_| anyhow::anyhow!("Codex app-server quota connection failed"))?
        {
            let response = serde_json::from_str::<Value>(&payload)
                .map_err(|_| anyhow::anyhow!("Codex app-server returned malformed quota data"))?;
            if response.get("id") == Some(&request_id) {
                return Ok(response);
            }
        }

        anyhow::bail!("Codex app-server ended before responding to the quota request")
    }

    async fn notify(&mut self, notification: Value) -> anyhow::Result<()> {
        self.stdin
            .write_all(format!("{notification}\n").as_bytes())
            .await
            .map_err(|_| anyhow::anyhow!("Failed to send a quota request to Codex app-server"))?;
        self.stdin.flush().await?;
        Ok(())
    }
}

/// Performs the read-only account and rate-limit request sequence after a
/// transport has connected to a local Codex app-server.
pub async fn read_quota_from_transport<T: AppServerTransport>(
    transport: &mut T,
) -> anyhow::Result<CodexAppServerQuotaSnapshot> {
    request_result(
        transport,
        serde_json::json!({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codexu",
                    "title": "codexU",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true,
                    "optOutNotificationMethods": []
                }
            }
        }),
    )
    .await?;
    transport
        .notify(serde_json::json!({ "method": "initialized" }))
        .await?;

    let account_result = request_result(
        transport,
        serde_json::json!({
            "id": 2,
            "method": "account/read",
            "params": { "refreshToken": false }
        }),
    )
    .await?;
    let rate_limits_result = request_result(
        transport,
        serde_json::json!({ "id": 3, "method": "account/rateLimits/read" }),
    )
    .await?;

    let mut quota = CodexAppServerQuotaSnapshot::from_rate_limit_response(&rate_limits_result);
    quota.account = parse_account(&account_result);
    Ok(quota)
}

async fn request_result<T: AppServerTransport>(
    transport: &mut T,
    request: Value,
) -> anyhow::Result<Value> {
    let response = transport.request(request).await?;
    if response.get("error").is_some() {
        anyhow::bail!("Codex app-server rejected a read-only quota request")
    }
    response
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Codex app-server returned no result for a quota request"))
}

fn parse_account(value: &Value) -> Option<AccountInfo> {
    let account = value.get("account")?;
    Some(AccountInfo {
        r#type: account.get("type")?.as_str()?.to_owned(),
        plan_type: account
            .get("planType")
            .and_then(Value::as_str)
            .map(str::to_owned),
        email_present: account.get("email").is_some_and(|email| !email.is_null()),
    })
}

fn selected_rate_limits(response: &Value) -> Option<&Value> {
    response
        .get("rateLimitsByLimitId")
        .and_then(|buckets| buckets.get("codex"))
        .or_else(|| response.get("rateLimits"))
        .filter(|value| value.is_object())
}

fn quota_command() -> anyhow::Result<Command> {
    let executable = resolve_codex_executable()
        .ok_or_else(|| anyhow::anyhow!("Could not locate the installed Codex CLI executable"))?;
    let mut command = Command::new(executable);
    command
        .args(["app-server", "--disable", "plugins", "--listen", "stdio://"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    configure_no_console(&mut command);
    Ok(command)
}

#[cfg(windows)]
fn configure_no_console(command: &mut Command) {
    command.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn configure_no_console(_command: &mut Command) {}

fn resolve_codex_executable() -> Option<PathBuf> {
    let app_data = env::var_os("APPDATA")?;
    let (package, triple) = if cfg!(target_arch = "aarch64") {
        ("codex-win32-arm64", "aarch64-pc-windows-msvc")
    } else {
        ("codex-win32-x64", "x86_64-pc-windows-msvc")
    };
    let candidate = PathBuf::from(app_data)
        .join("npm")
        .join("node_modules")
        .join("@openai")
        .join("codex")
        .join("node_modules")
        .join("@openai")
        .join(package)
        .join("vendor")
        .join(triple)
        .join("bin")
        .join("codex.exe");
    candidate.is_file().then_some(candidate)
}

async fn stop_child(child: &mut Child) -> anyhow::Result<()> {
    let status = timeout(APP_SERVER_EXIT_TIMEOUT, child.wait())
        .await
        .map_err(|_| anyhow::anyhow!("Codex quota process did not exit after closing input"))??;
    anyhow::ensure!(
        status.success(),
        "Codex quota process exited unsuccessfully"
    );
    Ok(())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn app_server_child_creation_disables_a_console() {
        let script = r#"
$signature = @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
'@
Add-Type -MemberDefinition $signature -Name NativeMethods -Namespace CodexU.ConsoleProbe
[CodexU.ConsoleProbe.NativeMethods]::GetConsoleWindow().ToInt64()
"#;
        let mut command = Command::new("powershell.exe");
        command
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                script,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        configure_no_console(&mut command);

        let output = command
            .output()
            .await
            .expect("PowerShell console probe should start");
        assert!(
            output.status.success(),
            "PowerShell console probe failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).trim(),
            "0",
            "CREATE_NO_WINDOW must leave the child without a console"
        );
    }
}

fn parse_rate_window(value: &Value) -> Option<RateWindow> {
    let used_percent = value.get("usedPercent")?.as_f64()?;
    let resets_at = value
        .get("resetsAt")
        .and_then(Value::as_i64)
        .and_then(|seconds| Utc.timestamp_opt(seconds, 0).single());

    Some(RateWindow {
        used_percent,
        window_duration_mins: value.get("windowDurationMins").and_then(Value::as_i64),
        resets_at,
    })
}

fn is_monthly_duration(duration_mins: Option<i64>) -> bool {
    matches!(duration_mins, Some(duration) if (MONTHLY_MIN_DURATION_MINS..=MONTHLY_MAX_DURATION_MINS).contains(&duration))
}

fn single_window(mut matches: Vec<RateWindow>) -> Option<RateWindow> {
    (matches.len() == 1).then(|| matches.remove(0))
}
