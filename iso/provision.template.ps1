# Copied by build-iso.ps1 to C:\ProvisioningData\provision.ps1 on the install
# media, with the host name filled in. A RunOnce entry starts it once, at the first
# logon of "User". Runs under Windows PowerShell 5.1.

$hostName = '{{HOST}}'
$dir      = 'C:\ProvisioningData'
$log      = Join-Path $dir "$hostName.log"

function Write-Log([string] $Message, [ConsoleColor] $Color = 'Cyan') {
    $line = "[$(Get-Date -Format s)] $Message"
    Write-Host $line -ForegroundColor $Color
    $line | Out-File -FilePath $log -Append -Encoding utf8
}

# Runs winget, showing its output in the window and appending it to the log
# (progress-bar lines are left out of the log). Returns the exit code; the
# logged lines are kept in $script:WingetOutput for Write-ApplySummary.
# No timeout: some steps are slow but not stuck.
function Invoke-Winget([string[]] $Arguments) {
    Write-Log "> winget $($Arguments -join ' ')"
    $script:WingetOutput = [Collections.Generic.List[string]]::new()
    & winget @Arguments 2>&1 | ForEach-Object {
        $text = "$_"
        Write-Host $text
        if ($text -match '[A-Za-z]') {
            $script:WingetOutput.Add($text)
            $text | Out-File -FilePath $log -Append -Encoding utf8
        }
    }
    return $LASTEXITCODE
}

# Lists the units that did not apply, from the results part of the
# `winget configure` output. That part comes after the agreement text; each unit
# is a "<Resource> [<id>]" line at column 0, then its indented status, then
# (on failure) unindented error details up to the next unit:
#   Script [alwaysFails]
#     The configuration unit failed while attempting to apply the desired state.
#   System.InvalidOperationException: The set script threw an error.
function Write-ApplySummary([int] $ExitCode) {
    $lines = @($script:WingetOutput)
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like 'You are responsible for understanding the configuration settings*') { $start = $i + 1 }
    }
    $units = [Collections.Generic.List[object]]::new()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S.* \[[^\]]+\]$') {
            $units.Add([pscustomobject]@{ Name = $lines[$i]; Status = ''; Details = [Collections.Generic.List[string]]::new() })
        } elseif ($units.Count -gt 0) {
            $unit = $units[$units.Count - 1]
            if (-not $unit.Status) { $unit.Status = $lines[$i].Trim() }
            elseif ($lines[$i] -notmatch '^Some of the configuration was not applied') { $unit.Details.Add($lines[$i].Trim()) }
        }
    }
    $failed = @($units | Where-Object { $_.Status -notmatch 'successfully applied|already in the desired state' })

    Write-Log '===== Summary ====='
    if ($units.Count -eq 0) {
        Write-Log "Could not find per-step results in the winget output (exit $ExitCode); read the output above."
        return
    }
    Write-Log "$($units.Count - $failed.Count) of $($units.Count) steps succeeded." $(if ($failed.Count) { 'Yellow' } else { 'Green' })
    foreach ($unit in $failed) {
        Write-Log "FAILED: $($unit.Name)" Red
        Write-Log "  $($unit.Status)" Red
        foreach ($d in ($unit.Details | Where-Object { $_ -notmatch '^--- End of inner exception|^<See the log file' } | Select-Object -First 3)) { Write-Log "  $d" Red }
    }
    if ($failed.Count -eq 0 -and $ExitCode -ne 0) {
        Write-Log "Every step reported success, but winget exited with $ExitCode; read the output above."
    }
    if ($failed.Count -gt 0) {
        Write-Log "Fix the cause and run again (steps already done are skipped):"
        Write-Log "  winget configure -f $wingetFile --accept-configuration-agreements"
    }
}

# winget writes UTF-8 (its progress bars are block characters); without this
# Windows PowerShell decodes it with the OEM code page and prints garbage.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Setting up this computer ($hostName)"
Write-Host "Installing the $hostName configuration. This takes a while; do not close this window." -ForegroundColor Yellow
Write-Host "Log: $log`n" -ForegroundColor Yellow

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "provision.ps1 started as $(whoami), elevated=$elevated"

# RunOnce is deleted before it runs, so there is no second chance: if this
# instance is not elevated, relaunch elevated (one UAC prompt) and stop here.
if (-not $elevated) {
    Write-Log 'Relaunching elevated.'
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}

# winget (App Installer) is registered asynchronously after the first logon.
for ($i = 0; $i -lt 60 -and -not (Get-Command winget -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 10 }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Log 'winget did not appear within 10 minutes; giving up.'; exit 1 }
[void](Invoke-Winget @('--version'))

# Every step of the configuration downloads something.
for ($i = 0; $i -lt 60; $i++) {
    try { [void][Net.Dns]::GetHostAddresses('cdn.winget.microsoft.com'); break } catch { Start-Sleep -Seconds 10 }
}

$wingetFile = Join-Path $dir "$hostName.winget"

# A fresh Windows ships with `winget configure` disabled. `--enable` updates App
# Installer through the Store: this early it can sit at 95% for a while, but it
# does finish. It must be the only argument; winget rejects it next to anything
# else, even --disable-interactivity.
# The update replaces the running winget, so --enable often exits non-zero even
# when it worked, and for a short while afterwards winget misreads its own
# command line ("Unrecognized command: '...\winget.exe'"). So judge success by
# `configure validate` instead, and give it time before applying anything.
$code = Invoke-Winget @('configure', '--enable')
Write-Log "winget configure --enable exit $code"
$ready = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 30
    if ((Invoke-Winget @('configure', 'validate', '-f', $wingetFile, '--disable-interactivity')) -eq 0) { $ready = $true; break }
    Write-Log "winget configure is not ready yet, attempt $i of 20."
    if ($i % 5 -eq 0) { Write-Log "Exit $(Invoke-Winget @('configure', '--enable')) from another --enable." }
}
if (-not $ready) {
    Write-Log 'winget configure never became ready; not applying the configuration.'
    Read-Host "`nFailed. See the output above (or $log), then press Enter to close this window"
    exit 1
}

$code = Invoke-Winget @('configure', '-f', $wingetFile, '--accept-configuration-agreements', '--disable-interactivity')
Write-Log "winget configure finished (exit $code)."
Write-ApplySummary $code
Read-Host "`nDone. Check the summary above (full output in $log), then press Enter to close this window"
