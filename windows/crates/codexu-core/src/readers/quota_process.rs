//! One quota invocation owns a Windows Job, including every descendant.
//! Start suspended so no child can escape before assignment to the Job.
use std::{
    io, mem,
    os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle},
};

use tokio::process::{Child, Command};
use windows_sys::Win32::{
    Foundation::INVALID_HANDLE_VALUE,
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD, THREADENTRY32,
        },
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
        Threading::{
            OpenThread, ResumeThread, CREATE_NO_WINDOW, CREATE_SUSPENDED, THREAD_SUSPEND_RESUME,
        },
    },
};

pub(super) fn spawn(command: &mut Command) -> anyhow::Result<(Child, OwnedHandle)> {
    // The handle is private and non-inheritable. Closing the last handle,
    // including OS cleanup on host termination, kills only this process tree.
    let raw_job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
    anyhow::ensure!(
        !raw_job.is_null(),
        "Could not create quota process Job: {}",
        io::Error::last_os_error()
    );
    let job = unsafe { OwnedHandle::from_raw_handle(raw_job) };
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { mem::zeroed() };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    let configured = unsafe {
        SetInformationJobObject(
            raw_job,
            JobObjectExtendedLimitInformation,
            &limits as *const _ as _,
            mem::size_of_val(&limits) as u32,
        )
    };
    anyhow::ensure!(
        configured != 0,
        "Could not configure quota process Job: {}",
        io::Error::last_os_error()
    );

    command
        .creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED)
        .kill_on_drop(true);
    let child = command.spawn()?;
    let process = child
        .raw_handle()
        .ok_or_else(|| anyhow::anyhow!("Missing quota process handle"))?;
    let assigned = unsafe { AssignProcessToJobObject(raw_job, process) };
    anyhow::ensure!(
        assigned != 0,
        "Could not assign quota process Job: {}",
        io::Error::last_os_error()
    );
    resume_primary_thread(
        child
            .id()
            .ok_or_else(|| anyhow::anyhow!("Missing quota process id"))?,
    )?;
    Ok((child, job))
}

fn resume_primary_thread(pid: u32) -> anyhow::Result<()> {
    // std/Tokio exposes the process handle but closes the primary thread handle.
    // A suspended new process has exactly one thread; locate it by owned PID.
    let raw_snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    anyhow::ensure!(
        raw_snapshot != INVALID_HANDLE_VALUE,
        "Could not inspect quota thread: {}",
        io::Error::last_os_error()
    );
    let snapshot = unsafe { OwnedHandle::from_raw_handle(raw_snapshot) };
    let mut entry: THREADENTRY32 = unsafe { mem::zeroed() };
    entry.dwSize = mem::size_of_val(&entry) as u32;
    let mut found = unsafe { Thread32First(snapshot.as_raw_handle(), &mut entry) };
    while found != 0 {
        if entry.th32OwnerProcessID == pid {
            let raw_thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
            anyhow::ensure!(
                !raw_thread.is_null(),
                "Could not open quota thread: {}",
                io::Error::last_os_error()
            );
            let thread = unsafe { OwnedHandle::from_raw_handle(raw_thread) };
            let resumed = unsafe { ResumeThread(thread.as_raw_handle()) };
            anyhow::ensure!(
                resumed != u32::MAX,
                "Could not resume quota process: {}",
                io::Error::last_os_error()
            );
            return Ok(());
        }
        found = unsafe { Thread32Next(snapshot.as_raw_handle(), &mut entry) };
    }
    anyhow::bail!("Could not locate the suspended quota process thread")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Stdio;
    use tokio::io::{AsyncBufReadExt, BufReader};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE,
    };

    async fn process_tree() -> (Child, OwnedHandle, OwnedHandle) {
        let mut command = Command::new("powershell.exe");
        command.args(["-NoProfile", "-NonInteractive", "-Command",
            "$p = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60' -PassThru; [Console]::WriteLine($p.Id); [Console]::Out.Flush(); Start-Sleep -Seconds 60"])
            .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        let (mut child, job) = spawn(&mut command).unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap()).lines();
        let pid: u32 = tokio::time::timeout(std::time::Duration::from_secs(10), output.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let handle = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, pid) };
        assert!(!handle.is_null());
        (child, job, unsafe { OwnedHandle::from_raw_handle(handle) })
    }

    #[tokio::test]
    async fn dropping_job_kills_descendants_without_touching_other_processes() {
        let mut unrelated = Command::new("powershell.exe");
        unrelated
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 60",
            ])
            .kill_on_drop(true)
            .creation_flags(CREATE_NO_WINDOW);
        let mut unrelated = unrelated.spawn().unwrap();
        let (mut child, job, descendant) = process_tree().await;
        drop(job);
        assert_eq!(
            unsafe { WaitForSingleObject(descendant.as_raw_handle(), 5000) },
            0
        );
        child.wait().await.unwrap();
        assert!(unrelated.try_wait().unwrap().is_none());
        unrelated.kill().await.unwrap();
    }

    #[tokio::test]
    async fn aborting_quota_task_releases_the_entire_job() {
        let (child, job, descendant) = process_tree().await;
        let task = tokio::spawn(async move {
            let _owned = (child, job);
            std::future::pending::<()>().await;
        });
        tokio::task::yield_now().await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(
            unsafe { WaitForSingleObject(descendant.as_raw_handle(), 5000) },
            0
        );
    }

    #[tokio::test]
    async fn stdin_eof_allows_normal_exit() {
        let mut command = Command::new("powershell.exe");
        command
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::In.ReadToEnd() | Out-Null",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let (mut child, _job) = spawn(&mut command).unwrap();
        drop(child.stdin.take());
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
    }
}
