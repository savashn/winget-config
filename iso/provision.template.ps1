# Copied by build-iso.ps1 to C:\ProvisioningData\provision.ps1 on the install
# media, with the host name filled in. A RunOnce entry starts it once, at the first
# logon of "User". Runs under Windows PowerShell 5.1.
#
# The window shows one line per finished step and, below it, an animated line
# for the step in progress ("[3/14] Installing AnyDesk"). Everything winget
# prints goes to the log only.

$hostName   = '{{HOST}}'
$dir        = 'C:\ProvisioningData'
$log        = Join-Path $dir "$hostName.log"
$wingetFile = Join-Path $dir "$hostName.winget"
$title      = "Setting up this computer ($hostName)"

# --- screen and log ------------------------------------------------------------

function Write-Log([string] $Message) {
    "[$(Get-Date -Format s)] $Message" | Out-File -FilePath $log -Append -Encoding utf8
}

function Format-Elapsed([datetime] $Since) {
    $t = (Get-Date) - $Since
    if ($t.TotalHours -ge 1) { return '{0}:{1:mm\:ss}' -f [int][Math]::Floor($t.TotalHours), $t }
    return '{0:mm\:ss}' -f $t
}

function Get-LineWidth {
    try { return [Math]::Max(20, [Console]::WindowWidth - 1) } catch { return 79 }
}

# The line for the step in progress: a spinner, $script:StatusText and the time
# since $script:StatusSince, redrawn in place. The moving spinner is what tells
# a slow step from a hung window.
$script:StatusText  = ''
$script:StatusSince = Get-Date
$script:StatusShown = $false
$script:SpinIndex   = 0

function Show-Status {
    $script:SpinIndex = ($script:SpinIndex + 1) % 4
    $spinner = @('|', '/', '-', '\')[$script:SpinIndex]
    $line = "  [  $spinner   ]  $($script:StatusText)  ($(Format-Elapsed $script:StatusSince))"
    $width = Get-LineWidth
    if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
    Write-Host ("`r" + $line.PadRight($width)) -NoNewline -ForegroundColor Yellow
    $script:StatusShown = $true
}

function Set-Status([string] $Text) {
    $script:StatusText  = $Text
    $script:StatusSince = Get-Date
}

function Clear-Status {
    if (-not $script:StatusShown) { return }
    Write-Host ("`r" + (' ' * (Get-LineWidth)) + "`r") -NoNewline
    $script:StatusShown = $false
}

# A finished step: "[  OK  ]  Text  note".
function Write-Step([string] $Mark, [string] $Text, [string] $Note = '', [ConsoleColor] $Color = 'Green') {
    Clear-Status
    Write-Host "  [$Mark]  " -ForegroundColor $Color -NoNewline
    Write-Host $Text -NoNewline
    Write-Host $(if ($Note) { "  $Note" } else { '' }) -ForegroundColor DarkGray
    Write-Log "[$Mark] $Text $Note"
}

# Keeps the status line moving until $Condition is true (checked every
# $PollSeconds) or $TimeoutSeconds have passed (0: no limit).
function Wait-Until([scriptblock] $Condition, [int] $PollSeconds = 5, [int] $TimeoutSeconds = 0) {
    $start = Get-Date
    $next  = $start
    while ($true) {
        if ((Get-Date) -ge $next) {
            if (& $Condition) { return $true }
            if ($TimeoutSeconds -and ((Get-Date) - $start).TotalSeconds -ge $TimeoutSeconds) { return $false }
            $next = (Get-Date).AddSeconds($PollSeconds)
        }
        Show-Status
        Start-Sleep -Milliseconds 250
    }
}

function Wait-Seconds([int] $Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    [void](Wait-Until { (Get-Date) -ge $end } -PollSeconds 1)
}

# --- winget --------------------------------------------------------------------

function Test-Online {
    try { [void][Net.Dns]::GetHostAddresses('cdn.winget.microsoft.com'); return $true } catch { return $false }
}

# Strips the VT escape sequences winget uses for colors and progress.
function Get-PlainText([string] $Line) {
    return ($Line -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '' -replace '\x1B\][^\x07]*\x07', '').TrimEnd()
}

# Runs winget without a console of its own, sending its output to the log
# (progress-bar lines are left out) and to $OnLine, one line at a time. The
# status line keeps moving meanwhile. Returns the exit code.
# No timeout: some steps are slow but not stuck.
function Invoke-Winget([string[]] $Arguments, [scriptblock] $OnLine = $null) {
    Write-Log "> winget $($Arguments -join ' ')"
    $exe = @(Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)[0]
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $(if ($exe) { $exe.Source } else { 'winget.exe' })
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    try { $proc = [Diagnostics.Process]::Start($psi) } catch { Write-Log "Could not start winget: $_"; return -1 }
    # Nothing may wait for an answer: a prompt reads end-of-input and moves on.
    $proc.StandardInput.Close()

    $readers  = @($proc.StandardOutput, $proc.StandardError)
    $pending  = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $lastDraw = [datetime]::MinValue
    $exitedAt = $null
    while ($pending[0] -or $pending[1]) {
        $gotLine = $false
        for ($i = 0; $i -lt 2; $i++) {
            if (-not $pending[$i] -or -not $pending[$i].IsCompleted) { continue }
            $raw = $pending[$i].Result
            if ($null -eq $raw) { $pending[$i] = $null; continue }
            $pending[$i] = $readers[$i].ReadLineAsync()
            $gotLine = $true
            $line = Get-PlainText $raw
            if ($line -match '[A-Za-z]' -and $line -notmatch '[\u2580-\u259F]') {
                $line | Out-File -FilePath $log -Append -Encoding utf8
            }
            if ($OnLine) { & $OnLine $line }
        }
        if (((Get-Date) - $lastDraw).TotalMilliseconds -ge 200) { Show-Status; $lastDraw = Get-Date }

        if ($gotLine) { continue }
        # A program an installer started can inherit the output pipe and keep
        # it open after winget has exited; do not wait for it.
        if ($proc.HasExited) {
            if (-not $exitedAt) { $exitedAt = Get-Date }
            elseif (((Get-Date) - $exitedAt).TotalSeconds -ge 3) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    $proc.WaitForExit()
    return $proc.ExitCode
}

# --- configuration steps -------------------------------------------------------

# id -> @{ Name; Verb } for every unit in the .winget file. Name is the unit's
# description, which is what the window shows.
function Read-Units {
    $units = [ordered]@{}
    $unit  = $null
    foreach ($l in (Get-Content -LiteralPath $wingetFile -Encoding UTF8)) {
        if ($l -match '^    - resource:\s*(\S+)') {
            $unit = @{ Id = $null; Name = $null; Verb = $(if ($Matches[1] -like '*/WinGetPackage') { 'Installing' } else { 'Setting up' }) }
        } elseif ($unit -and -not $unit.Id -and $l -match '^      id:\s*(\S+)') {
            $unit.Id = $Matches[1]
            $units[$unit.Id] = $unit
        } elseif ($unit -and -not $unit.Name -and $l -match '^        description:\s*(.+?)\s*$') {
            $d = $Matches[1]
            if ($d -match "^'(.*)'$") { $d = $Matches[1].Replace("''", "'") }
            elseif ($d -match '^"(.*)"$') { $d = $Matches[1] }
            $unit.Name = $d
        }
    }
    foreach ($u in $units.Values) { if (-not $u.Name) { $u.Name = $u.Id } }
    return $units
}

# Follows the results part of the `winget configure` output as it arrives. That
# part comes after the agreement text; winget prints "<Resource> [<id>]" at
# column 0 when a unit starts, an indented status line when it ends, then (on
# failure) unindented error details up to the next unit:
#   Script [alwaysFails]
#     The configuration unit failed while attempting to apply the desired state.
#   System.InvalidOperationException: The set script threw an error.
$script:ResultsStarted = $false
$script:Results        = [Collections.Generic.List[object]]::new()
$script:Current        = $null

function Complete-Unit([string] $Status) {
    $r = $script:Current
    $r.Status = $Status
    $r.Ok     = $Status -match 'successfully applied|already in the desired state'
    $label    = "[$($r.Index)/$($units.Count)] $($r.Name)"
    if ($Status -match 'already in the desired state') { Write-Step '  OK  ' $label 'already done' }
    elseif ($r.Ok) { Write-Step '  OK  ' $label (Format-Elapsed $r.Since) }
    else { Write-Step ' FAIL ' $label $Status Red }
    Set-Status 'Moving on to the next step'
}

$onApplyLine = {
    param([string] $Line)
    if (-not $script:ResultsStarted) {
        if ($Line -like 'You are responsible for understanding the configuration settings*') { $script:ResultsStarted = $true }
        return
    }
    if ($Line -match '^\S.* \[(?<id>[^\]]+)\]$' -and $units.Contains($Matches['id'])) {
        if ($script:Current -and -not $script:Current.Status) { Complete-Unit 'No result was reported for this step.' }
        $u = $units[$Matches['id']]
        $script:Current = [pscustomobject]@{
            Name = $u.Name; Index = $script:Results.Count + 1; Since = Get-Date
            Status = ''; Ok = $false; Details = [Collections.Generic.List[string]]::new()
        }
        $script:Results.Add($script:Current)
        $text = "[$($script:Current.Index)/$($units.Count)] $($u.Verb) $($u.Name)"
        if ($u.Name -match 'opens a setup window') { $text += ' - finish that window to continue' }
        Set-Status $text
        $Host.UI.RawUI.WindowTitle = "[$($script:Current.Index)/$($units.Count)] $($u.Name) - $title"
        return
    }
    if (-not $script:Current -or -not $Line.Trim()) { return }
    if (-not $script:Current.Status) {
        # Progress bars and spinners come before the status line.
        if ($Line -match '^\s' -and $Line -match '[A-Za-z]{3}' -and $Line -notmatch '[\u2580-\u259F]|\d\s*%\s*$') { Complete-Unit $Line.Trim() }
    }
    elseif ($Line -notmatch '^Some of the configuration was not applied') { $script:Current.Details.Add($Line.Trim()) }
}

# --- summary -------------------------------------------------------------------

function Write-Summary([int] $ExitCode) {
    $failed = @($script:Results | Where-Object { -not $_.Ok })
    $ok     = $script:Results.Count - $failed.Count
    Clear-Status
    if ($script:Results.Count -eq 0) {
        $color = 'Yellow'
        $head  = 'SETUP FINISHED, BUT ITS RESULT IS UNKNOWN'
        $lines = @("winget exited with $ExitCode and reported no steps; read the log.")
    } elseif ($failed.Count -eq 0 -and $ExitCode -eq 0) {
        $color = 'Green'
        $head  = 'SETUP COMPLETE'
        $lines = @("All $($units.Count) steps are done.")
    } else {
        $color = 'Red'
        $head  = 'SETUP FINISHED WITH ERRORS'
        $lines = @("$ok of $($units.Count) steps succeeded.")
        foreach ($r in $failed) {
            $lines += "! FAILED: [$($r.Index)/$($units.Count)] $($r.Name)"
            $lines += "!   $($r.Status)"
            foreach ($d in ($r.Details | Where-Object { $_ -notmatch '^--- End of inner exception|^<See the log file' } | Select-Object -First 3)) { $lines += "!   $d" }
        }
        if ($failed.Count -eq 0) { $lines += "Every step reported success, but winget exited with $ExitCode." }
        $lines += 'Fix the cause and run again (steps already done are skipped):'
        $lines += "  winget configure -f $wingetFile --accept-configuration-agreements"
    }
    $lines += "Full log: $log"

    $rule = '=' * [Math]::Min(70, (Get-LineWidth) - 2)
    Write-Host ''
    Write-Host "  $rule" -ForegroundColor $color
    Write-Host "  $head" -ForegroundColor $color
    Write-Host "  $rule" -ForegroundColor $color
    # Lines starting with "! " are about a failed step.
    foreach ($l in $lines) {
        if ($l.StartsWith('! ')) { Write-Host "  $($l.Substring(2))" -ForegroundColor Red } else { Write-Host "  $l" }
    }
    Write-Host "  $rule" -ForegroundColor $color
    Write-Log "===== $head ====="
    $lines | ForEach-Object { Write-Log ($_ -replace '^! ', '') }
    $Host.UI.RawUI.WindowTitle = "$head - $title"
}

function Stop-WithError([string] $Message) {
    Write-Step ' FAIL ' $Message '' Red
    $Host.UI.RawUI.WindowTitle = "SETUP FAILED - $title"
    try { [Console]::CursorVisible = $true } catch { }
    Read-Host "`n  SETUP FAILED. Details are in $log.`n  Press Enter to close this window"
    exit 1
}

# --- main ----------------------------------------------------------------------

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = $title
Write-Host ''
Write-Host "  $title" -ForegroundColor Cyan
Write-Host '  This takes a while. Do not close this window; it tells you when it is done.' -ForegroundColor Cyan
Write-Host ''

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$elevated  = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "provision.ps1 started as $(whoami), elevated=$elevated"

# RunOnce is deleted before it runs, so there is no second chance: if this
# instance is not elevated, relaunch elevated (one UAC prompt) and stop here.
if (-not $elevated) {
    Write-Host '  Asking for administrator rights; setup continues in a new window.' -ForegroundColor Yellow
    Write-Log 'Relaunching elevated.'
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    exit
}
try { [Console]::CursorVisible = $false } catch { }

# winget (App Installer) is registered asynchronously after the first logon.
Set-Status 'Waiting for winget to become available'
if (-not (Wait-Until { [bool](Get-Command winget -ErrorAction SilentlyContinue) } -PollSeconds 10 -TimeoutSeconds 600)) {
    Stop-WithError 'winget did not appear within 10 minutes.'
}
[void](Invoke-Winget @('--version'))
Write-Step '  OK  ' 'winget is available'

# Every step of the configuration downloads something, and so does the App
# Installer update that `configure --enable` triggers below. No timeout: going
# on without a connection only turns one wait into a screen full of failed
# steps. The poll is short so that plugging in a cable or joining a Wi-Fi
# network gets things moving again within seconds.
if (-not (Test-Online)) {
    Write-Log 'No internet connection; waiting for one.'
    Set-Status 'No internet connection. Connect a cable or Wi-Fi; setup continues on its own'
    [void](Wait-Until { Test-Online } -PollSeconds 5)
}
Write-Step '  OK  ' 'Internet connection'
# A fresh Windows ships with `winget configure` disabled. `--enable` updates App
# Installer through the Store: this early it can sit at 95% for a while, but it
# does finish. It must be the only argument; winget rejects it next to anything
# else, even --disable-interactivity.
# The update replaces the running winget, so --enable often exits non-zero even
# when it worked, and for a short while afterwards winget misreads its own
# command line ("Unrecognized command: '...\winget.exe'"). So judge success by
# `configure validate` instead, and give it time before applying anything.
Set-Status 'Updating winget (this can take a while)'
$preparing = $script:StatusSince
Write-Log "winget configure --enable exit $(Invoke-Winget @('configure', '--enable'))"
$ready = $false
for ($i = 1; $i -le 20; $i++) {
    Wait-Seconds 30
    if ((Invoke-Winget @('configure', 'validate', '-f', $wingetFile, '--disable-interactivity')) -eq 0) { $ready = $true; break }
    Write-Log "winget configure is not ready yet, attempt $i of 20."
    if ($i % 5 -eq 0) { Write-Log "Exit $(Invoke-Winget @('configure', '--enable')) from another --enable." }
}
if (-not $ready) { Stop-WithError 'winget configure never became ready; nothing was installed.' }
Write-Step '  OK  ' 'winget is ready' (Format-Elapsed $preparing)

$units = Read-Units
Write-Log "$($units.Count) steps in $wingetFile"
Write-Host ''
Write-Host "  Applying $($units.Count) steps:" -ForegroundColor Cyan
Set-Status 'Preparing (downloading what the steps need)'
$code = Invoke-Winget @('configure', '-f', $wingetFile, '--accept-configuration-agreements', '--disable-interactivity') $onApplyLine
if ($script:Current -and -not $script:Current.Status) { Complete-Unit 'No result was reported for this step.' }
Write-Log "winget configure finished (exit $code)."

Write-Summary $code
try { [Console]::Beep(880, 250); [Console]::Beep(1175, 350) } catch { }
try { [Console]::CursorVisible = $true } catch { }
Read-Host "`n  Press Enter to close this window"
