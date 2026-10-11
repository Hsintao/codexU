#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Version)

# Real installation is restricted to an ephemeral hosted runner, never a user's PC.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Installer acceptance requires an ephemeral GitHub Windows runner.'
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected a stable semantic version.' }
$Repo = Split-Path -Parent $PSScriptRoot
$Packages = Join-Path $Repo 'dist\windows'
$Evidence = Join-Path $Repo '.local-artifacts\installer-acceptance'
$Owned = Join-Path $env:RUNNER_TEMP ('codexu-install-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Owned -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
$ExpectedExe = Join-Path $Repo 'windows\target\release\codexu-tauri.exe'
if (-not (Test-Path -LiteralPath $ExpectedExe)) { throw 'The packaged executable is missing.' }
$ExpectedHash = (Get-FileHash -LiteralPath $ExpectedExe -Algorithm SHA256).Hash
$Records = [System.Collections.Generic.List[object]]::new()
$RegistryRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Get-CodexURegistration {
    foreach ($Root in $RegistryRoots) {
        if (Test-Path -LiteralPath $Root) {
            Get-ChildItem -LiteralPath $Root | ForEach-Object {
                $Entry = Get-ItemProperty -LiteralPath $_.PSPath
                if ($null -ne $Entry -and $null -ne $Entry.PSObject.Properties['DisplayName'] -and $Entry.DisplayName -eq 'codexU') {
                    $Entry
                }
            }
        }
    }
}
if (@(Get-CodexURegistration).Count -ne 0 -or @(Get-Process codexu-tauri -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'Runner already contains codexU; refusing to touch an existing installation.'
}
function Invoke-Installer([string]$File, [string[]]$Arguments, [string]$Label) {
    $Process = Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $Process.WaitForExit(180000)) { throw "$Label exceeded the three-minute installation timeout." }
    if ($Process.ExitCode -notin @(0, 3010)) { throw "$Label failed with exit code $($Process.ExitCode)." }
    $Records.Add([ordered]@{ step = $Label; exit_code = $Process.ExitCode })
}
function Assert-Installed([string]$Directory, [string]$ExpectedVersion, [bool]$CheckPayload) {
    $Exe = Join-Path $Directory 'codexu-tauri.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw "Installed executable missing: $Directory" }
    $Entries = @(Get-CodexURegistration)
    if ($Entries.Count -ne 1 -or $Entries[0].DisplayVersion -ne $ExpectedVersion) {
        throw "Expected exactly one $ExpectedVersion installation registration."
    }
    $Hash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
    if ($CheckPayload -and $Hash -ne $ExpectedHash) { throw 'Installed executable differs from the packaged executable.' }
    $Records.Add([ordered]@{ step = 'installed-identity'; version = $ExpectedVersion; payload_matches = $CheckPayload; sha256 = $Hash.ToLowerInvariant() })
    return $Entries[0]
}
function Assert-Uninstalled([string]$Directory) {
    if (Test-Path -LiteralPath (Join-Path $Directory 'codexu-tauri.exe')) { throw 'Uninstaller left the application executable.' }
    if (@(Get-CodexURegistration).Count -ne 0) { throw 'Uninstaller left codexU registration.' }
    $Records.Add([ordered]@{ step = 'uninstalled'; executable_absent = $true; registration_absent = $true })
}
function Get-Baseline([string]$Name, [string]$Hash) {
    $Path = Join-Path $Owned $Name
    Invoke-WebRequest -Uri "https://github.com/shanggqm/codexU/releases/download/windows-v1.3.3/$Name" -OutFile $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) { throw 'Baseline installer checksum mismatch.' }
    return $Path
}
$Receipt = [ordered]@{ version = $Version; source_sha = $env:GITHUB_SHA; runner = $env:RUNNER_OS; baseline = '1.3.3'; result = 'running'; steps = $Records }
try {
    $Nsis = Join-Path $Packages "codexU-$Version-windows-x86_64-setup.exe"
    $Msi = Join-Path $Packages "codexU-$Version-windows-x86_64.msi"
    foreach ($Package in @($Nsis, $Msi)) {
        $Checksum = ((Get-Content -Raw -Encoding UTF8 -LiteralPath "$Package.sha256").Trim() -split '\s+')[0]
        if ((Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Checksum) { throw 'Candidate checksum mismatch.' }
    }
    # NSIS: clean installation, uninstall, then a real 1.3.3 -> candidate upgrade.
    $NsisDirectory = Join-Path $Owned 'nsis'
    Invoke-Installer $Nsis @('/S', "/D=$NsisDirectory") 'nsis-clean-install'
    $null = Assert-Installed $NsisDirectory $Version $true
    Invoke-Installer (Join-Path $NsisDirectory 'uninstall.exe') @('/S') 'nsis-clean-uninstall'
    Assert-Uninstalled $NsisDirectory
    $OldNsis = Get-Baseline 'codexU-1.3.3-windows-x86_64-setup.exe' 'c4fdd845ea6bbbda3c622f8c727a36d7555790aa9441631e6918e31cded8e399'
    Invoke-Installer $OldNsis @('/S', "/D=$NsisDirectory") 'nsis-baseline-install'
    $null = Assert-Installed $NsisDirectory '1.3.3' $false
    $Data = Join-Path $env:APPDATA 'com.codexU.app'
    New-Item -ItemType Directory -Path $Data -Force | Out-Null
    $Marker = Join-Path $Data 'installer-test-preserve.txt'
    [IO.File]::WriteAllText($Marker, 'owned runner fixture', [Text.UTF8Encoding]::new($false))
    Invoke-Installer $Nsis @('/S', "/D=$NsisDirectory") 'nsis-upgrade'
    $null = Assert-Installed $NsisDirectory $Version $true
    if ((Get-Content -Raw -Encoding UTF8 -LiteralPath $Marker) -ne 'owned runner fixture') { throw 'Upgrade removed application data.' }
    $Records.Add([ordered]@{ step = 'nsis-upgrade-data'; preserved = $true })
    Invoke-Installer (Join-Path $NsisDirectory 'uninstall.exe') @('/S') 'nsis-upgrade-uninstall'
    Assert-Uninstalled $NsisDirectory
    # MSI: both clean installation and same UpgradeCode upgrade of the old package.
    $MsiDirectory = Join-Path $Owned 'msi'
    Invoke-Installer 'msiexec.exe' @('/i', "`"$Msi`"", '/qn', '/norestart', "INSTALLDIR=`"$MsiDirectory`"", '/L*v', "`"$(Join-Path $Evidence 'msi-clean.log')`"") 'msi-clean-install'
    $Entry = Assert-Installed $MsiDirectory $Version $true
    Invoke-Installer 'msiexec.exe' @('/x', $Entry.PSChildName, '/qn', '/norestart') 'msi-clean-uninstall'
    Assert-Uninstalled $MsiDirectory
    $OldMsi = Get-Baseline 'codexU-1.3.3-windows-x86_64.msi' 'e59e9df4e8d9f5adbd487daf20906176ef99dc1262a98a447eb74a30fe6440de'
    Invoke-Installer 'msiexec.exe' @('/i', "`"$OldMsi`"", '/qn', '/norestart', "INSTALLDIR=`"$MsiDirectory`"") 'msi-baseline-install'
    $OldEntry = Assert-Installed $MsiDirectory '1.3.3' $false
    Invoke-Installer 'msiexec.exe' @('/i', "`"$Msi`"", '/qn', '/norestart', "INSTALLDIR=`"$MsiDirectory`"", '/L*v', "`"$(Join-Path $Evidence 'msi-upgrade.log')`"") 'msi-upgrade'
    $Entry = Assert-Installed $MsiDirectory $Version $true
    if ($OldEntry.PSChildName -eq $Entry.PSChildName) { throw 'MSI upgrade did not replace the old ProductCode.' }
    if ((Get-Content -Raw -Encoding UTF8 -LiteralPath $Marker) -ne 'owned runner fixture') { throw 'MSI upgrade removed application data.' }
    $Records.Add([ordered]@{ step = 'msi-upgrade-data'; preserved = $true; old_product_removed = $true })
    Invoke-Installer 'msiexec.exe' @('/x', $Entry.PSChildName, '/qn', '/norestart') 'msi-upgrade-uninstall'
    Assert-Uninstalled $MsiDirectory
    $Receipt.result = 'PASS'
} catch {
    $Receipt.result = 'FAIL'
    $Receipt.error = $_.Exception.Message
    throw
} finally {
    [IO.File]::WriteAllText((Join-Path $Evidence 'receipt.json'), ($Receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    # Runner disposal owns cleanup, including failed partial installations. This
    # script never tries broader deletion or touches a user's local installation.
}
Write-Output "Real MSI/NSIS clean install, 1.3.3 upgrade, data preservation and uninstall passed for $Version."
