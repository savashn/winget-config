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

# Changes the text without restarting the clock (a download counting up inside
# one step).
function Set-StatusText([string] $Text) {
    $script:StatusText = $Text
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

# The App Installer package provides winget through an app execution alias. The
# alias is in PATH, but PowerShell caches a failed lookup, so also look at the
# path itself after the package has been installed.
function Get-WinGetPath {
    $cmd = @(Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)[0]
    if ($cmd) { return $cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return $null
}

# The alias file exists even when the package behind it is broken or still
# being registered, so ask winget itself. An alias whose package is missing can
# hang instead of failing (Windows opens a Store page for it), hence the
# timeout: a probe that does not answer counts as "not ready".
function Test-WinGetReady {
    $path = Get-WinGetPath
    if (-not $path) { Write-Log 'winget.exe not found yet.'; return $false }
    $code = Invoke-Winget @('--version') -TimeoutSeconds 45
    Write-Log "Probed $path : exit $code"
    return $code -eq 0
}

# Strips the VT escape sequences winget uses for colors and progress.
function Get-PlainText([string] $Line) {
    return ($Line -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '' -replace '\x1B\][^\x07]*\x07', '').TrimEnd()
}

# Runs winget without a console of its own, sending its output to the log
# (progress-bar lines are left out) and to $OnLine, one line at a time. The
# status line keeps moving meanwhile. Returns the exit code, or -2 if
# $TimeoutSeconds passed and winget had to be killed.
# Applying the configuration passes no timeout: those steps are slow, not stuck.
# The readiness probes do, so that a winget that never answers cannot stall the
# whole run behind a status line that looks like ordinary waiting.
function Invoke-Winget([string[]] $Arguments, [scriptblock] $OnLine = $null, [int] $TimeoutSeconds = 0) {
    Write-Log "> winget $($Arguments -join ' ')"
    $exe = Get-WinGetPath
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $(if ($exe) { $exe } else { 'winget.exe' })
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
    $started  = Get-Date
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
        if ($TimeoutSeconds -and -not $proc.HasExited -and ((Get-Date) - $started).TotalSeconds -ge $TimeoutSeconds) {
            Write-Log "winget $($Arguments -join ' ') did not answer within $TimeoutSeconds s; killing it."
            # Kill the children too: winget starts a package process of its own.
            & taskkill.exe /PID $proc.Id /T /F 2>&1 | ForEach-Object { Write-Log $_ }
            [void]$proc.WaitForExit(5000)
            return -2
        }
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

# --- installing winget itself ---------------------------------------------------
# Windows 11 media brings winget along; Windows 10 media ships an App Installer
# without it (or none at all), and the Store replaces that only much later. So
# install it here from the winget-cli release on GitHub: the msixbundle plus the
# dependency pack for this architecture. Each file's Authenticode signature is
# checked before it is installed - and MSIX deployment refuses a package that is
# not signed by a trusted publisher anyway.

# Downloads in chunks instead of with Invoke-WebRequest, which would block for
# minutes with the spinner frozen - the one thing that must never happen, since
# a still window is how a hung run looks. The status line counts the megabytes.
function Save-File([string] $Url, [string] $Path, [string] $What) {
    Write-Log "Downloading $Url"
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'winget-config-provision'
    $response = $request.GetResponse()
    $total = $response.ContentLength
    $stream = $response.GetResponseStream()
    $output = [IO.File]::Create($Path)
    try {
        $buffer = New-Object byte[] (256 * 1024)
        $done = 0
        $lastDraw = [datetime]::MinValue
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $done += $read
            if (((Get-Date) - $lastDraw).TotalMilliseconds -lt 200) { continue }
            $lastDraw = Get-Date
            $mb = [int]($done / 1MB)
            Set-StatusText $(if ($total -gt 0) { "$What - $mb of $([int]($total / 1MB)) MB" } else { "$What - $mb MB" })
            Show-Status
        }
    } finally {
        $output.Dispose()
        $stream.Dispose()
        $response.Dispose()
    }
    Write-Log "Downloaded $([int]((Get-Item -LiteralPath $Path).Length / 1MB)) MB to $Path"
}

function Get-SignedFile([string] $Url, [string] $Path, [string] $What) {
    Save-File $Url $Path $What
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { throw "$(Split-Path $Path -Leaf): signature is $($sig.Status)." }
    if ($sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "$(Split-Path $Path -Leaf) is signed by $($sig.SignerCertificate.Subject), not by Microsoft."
    }
    return $Path
}

function Install-WinGet {
    # Cheapest case first: the package is on the machine but not registered for
    # this user.
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Write-Log 'Registered the App Installer package that was already on the machine.'
        if (Test-WinGetReady) { return $true }
    } catch { Write-Log "No App Installer package to register: $($_.Exception.Message)" }

    $arch = @{ 'AMD64' = 'x64'; 'ARM64' = 'arm64'; 'X86' = 'x86' }[$env:PROCESSOR_ARCHITECTURE]
    if (-not $arch) { Write-Log "Unknown architecture $env:PROCESSOR_ARCHITECTURE."; return $false }
    $work = Join-Path $dir 'winget-setup'
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing
        Write-Log "Latest winget release: $($release.tag_name)"
        $bundleUrl = @($release.assets | Where-Object name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle')[0].browser_download_url
        $depsUrl   = @($release.assets | Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip')[0].browser_download_url
    } catch {
        Write-Log "Could not read the release list from GitHub: $($_.Exception.Message)"
        $bundleUrl = 'https://aka.ms/getwinget'
        $depsUrl   = $null
    }
    if (-not $bundleUrl) { $bundleUrl = 'https://aka.ms/getwinget' }

    # Dependencies first; winget will not register without them.
    if ($depsUrl) {
        try {
            # The .zip has no Authenticode signature of its own; the .appx files
            # inside it are signed, and those are what gets installed.
            $zip = Join-Path $work 'dependencies.zip'
            Save-File $depsUrl $zip 'Downloading what winget needs'
            $unzipped = Join-Path $work 'dependencies'
            if (Test-Path -LiteralPath $unzipped) { Remove-Item -LiteralPath $unzipped -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $unzipped -Force
            foreach ($appx in @(Get-ChildItem -LiteralPath (Join-Path $unzipped $arch) -Filter *.appx -ErrorAction SilentlyContinue)) {
                $sig = Get-AuthenticodeSignature -LiteralPath $appx.FullName
                if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                    Write-Log "Skipping $($appx.Name): signature is $($sig.Status)."
                    continue
                }
                try {
                    Set-StatusText "Installing what winget needs ($($appx.Name))"
                    Show-Status
                    Add-AppxPackage -Path $appx.FullName -ErrorAction Stop
                    Write-Log "Installed dependency $($appx.Name)."
                } catch {
                    # A newer version of the same dependency is already there.
                    Write-Log "Dependency $($appx.Name): $($_.Exception.Message)"
                }
            }
        } catch { Write-Log "Dependencies failed: $($_.Exception.Message)" }
    }

    try {
        $bundle = Get-SignedFile $bundleUrl (Join-Path $work 'AppInstaller.msixbundle') 'Downloading winget'
        Set-StatusText 'Installing winget'
        Show-Status
        Add-AppxPackage -Path $bundle -ErrorAction Stop
        Write-Log 'Installed the App Installer package.'
    } catch {
        Write-Log "Installing App Installer failed: $($_.Exception.Message)"
        return $false
    }
    return $true
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

# --- desktop shortcuts ---------------------------------------------------------
# Silent installs rarely put a shortcut on the desktop. Whatever appears in the
# Start menu while the configuration runs gets one: a copy of its Start menu
# shortcut, or, for Store/MSIX apps (which have no .lnk file), a shortcut to its
# shell:AppsFolder entry. Portable winget packages get no Start menu entry, only
# a link in winget's Links folder; those get a shortcut if the program is a GUI
# (not a console) executable. Skipped: anything already on a desktop (many
# installers put their own on the public desktop), uninstall/help/readme/website
# entries and vendor "...Tools" folders (Microsoft Office Tools).

$startMenus  = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
                 (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
$wingetLinks = @((Join-Path $env:ProgramFiles 'WinGet\Links'),
                 (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'))
$skipName    = "(?i)(^|\W)(uninstall|readme|read me|help|manual|documentation|release notes|license|licence|website|web site|homepage|faq|changelog|what's new)(\W|$)"
$skipTarget  = '(?i)(\.(txt|pdf|chm|hlp|htm|html|url|rtf|md|log|ini|xml)$|\\unins[^\\]*\.exe$)'

function Get-StartMenuState {
    [pscustomobject]@{
        Lnk   = @($startMenus | Where-Object { Test-Path -LiteralPath $_ } |
                  ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.lnk -Recurse -ErrorAction SilentlyContinue } |
                  ForEach-Object FullName)
        Apps  = @(try { Get-StartApps | Where-Object { $_.AppID -like '*!*' } } catch { })
        Links = @($wingetLinks | Where-Object { Test-Path -LiteralPath $_ } |
                  ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.exe -ErrorAction SilentlyContinue } |
                  ForEach-Object FullName)
    }
}

# True for a PE file whose subsystem is Windows GUI (2), false for console ones.
function Test-GuiExe([string] $Path) {
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $br = New-Object IO.BinaryReader $fs
            $fs.Position = 0x3C
            $pe = $br.ReadInt32()
            $fs.Position = $pe
            if ($br.ReadUInt32() -ne 0x4550) { return $false }
            $fs.Position = $pe + 24 + 68
            return $br.ReadUInt16() -eq 2
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# Returns the names of the shortcuts it created.
function New-DesktopShortcuts($Before) {
    $after   = Get-StartMenuState
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell   = New-Object -ComObject WScript.Shell
    $created = [Collections.Generic.List[string]]::new()
    $names   = @{}
    $targets = @{}

    function Get-TargetKey([string] $LnkPath) {
        try { $l = $shell.CreateShortcut($LnkPath) } catch { return $null }
        if (-not $l.TargetPath) { return $null }
        return "$($l.TargetPath)|$($l.Arguments)".ToLowerInvariant()
    }
    function Add-Shortcut([string] $Name, [string] $Key, [scriptblock] $Create) {
        $Name = ($Name -replace '[\\/:*?"<>|]', '').Trim()
        if (-not $Name -or $names.ContainsKey($Name) -or ($Key -and $targets.ContainsKey($Key))) { return }
        $file = Join-Path $desktop "$Name.lnk"
        try {
            & $Create $file
            $names[$Name] = $true
            if ($Key) { $targets[$Key] = $true }
            $created.Add($Name)
        } catch { Write-Log "Could not create desktop shortcut '$Name': $_" }
    }

    foreach ($f in @(Get-ChildItem -LiteralPath $desktop, ([Environment]::GetFolderPath('CommonDesktopDirectory')) -Filter *.lnk -ErrorAction SilentlyContinue)) {
        $names[$f.BaseName] = $true
        $key = Get-TargetKey $f.FullName
        if ($key) { $targets[$key] = $true }
    }

    foreach ($p in @($after.Lnk | Where-Object { $_ -notin $Before.Lnk } | Sort-Object)) {
        $name = [IO.Path]::GetFileNameWithoutExtension($p)
        if ($name -match $skipName -or (Split-Path (Split-Path $p -Parent) -Leaf) -match 'Tools$') { continue }
        $l = $shell.CreateShortcut($p)
        if ($l.TargetPath -match $skipTarget) { continue }
        Add-Shortcut $name (Get-TargetKey $p) { param($file) Copy-Item -LiteralPath $p -Destination $file }
    }

    $knownApps = @($Before.Apps | ForEach-Object AppID)
    foreach ($a in @($after.Apps | Where-Object { $_.AppID -notin $knownApps })) {
        if ($a.Name -match $skipName) { continue }
        $target = "shell:AppsFolder\$($a.AppID)"
        Add-Shortcut $a.Name $target.ToLowerInvariant() {
            param($file)
            $s = $shell.CreateShortcut($file)
            $s.TargetPath = $target
            $s.Save()
        }
    }

    foreach ($p in @($after.Links | Where-Object { $_ -notin $Before.Links } | Sort-Object)) {
        $target = $p
        try {
            $t = @((Get-Item -LiteralPath $p).Target)[0]
            if ($t) { $target = $(if ([IO.Path]::IsPathRooted($t)) { $t } else { Join-Path (Split-Path $p -Parent) $t }) }
        } catch { }
        if (-not (Test-GuiExe $target)) { continue }
        $name = (Get-Item -LiteralPath $target).VersionInfo.FileDescription
        if (-not $name -or -not $name.Trim()) { $name = [IO.Path]::GetFileNameWithoutExtension($p) }
        Add-Shortcut $name "$target|".ToLowerInvariant() {
            param($file)
            $s = $shell.CreateShortcut($file)
            $s.TargetPath = $target
            $s.WorkingDirectory = Split-Path $target -Parent
            $s.Save()
        }
    }
    return $created
}

# --- summary -------------------------------------------------------------------

function Write-Summary([int] $ExitCode, [string[]] $Shortcuts) {
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
    if ($Shortcuts) { $lines += "Desktop shortcuts created: $($Shortcuts -join ', ')" }
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
# Windows PowerShell 5.1 on an old Windows 10 image still negotiates TLS 1.0,
# which github.com and aka.ms refuse. Its download progress bar would also draw
# over the status line, and it makes Invoke-WebRequest many times slower.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
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

# The connection comes first: every step downloads something, winget itself may
# have to be downloaded below, and without a connection there is nothing to wait
# for. No timeout: going on offline only turns one wait into a screen full of
# failed steps. The poll is short so that plugging in a cable or joining a Wi-Fi
# network gets things moving again within seconds - and it must say so, because
# only the user can fix it.
Set-Status 'Checking the internet connection'
if (-not (Test-Online)) {
    Write-Step ' WAIT ' 'No internet connection' 'connect a cable or Wi-Fi' Yellow
    Write-Log 'No internet connection; waiting for one.'
    Set-Status 'Waiting for an internet connection - setup continues on its own once it is there'
    [void](Wait-Until { Test-Online } -PollSeconds 5)
}
Write-Step '  OK  ' 'Internet connection'

# On Windows 11 winget is on the machine already, only registered a little after
# the first logon. On Windows 10 it usually is not there at all, and no amount
# of waiting brings it, so install it.
Set-Status 'Waiting for winget - if it does not turn up, it gets installed'
$ready = Wait-Until { Test-WinGetReady } -PollSeconds 10 -TimeoutSeconds 120
if (-not $ready) {
    Write-Step ' WAIT ' 'winget is not on this machine' 'installing it' Yellow
    Set-Status 'Downloading and installing winget (App Installer)'
    $installed = Install-WinGet
    Write-Log "Install-WinGet returned $installed"
    $ready = Wait-Until { Test-WinGetReady } -PollSeconds 5 -TimeoutSeconds 120
}
if (-not $ready) { Stop-WithError 'winget could not be installed on this machine.' }
Write-Step '  OK  ' 'winget is available'

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
$startMenuBefore = Get-StartMenuState
Set-Status 'Preparing (downloading what the steps need)'
$code = Invoke-Winget @('configure', '-f', $wingetFile, '--accept-configuration-agreements', '--disable-interactivity') $onApplyLine
if ($script:Current -and -not $script:Current.Status) { Complete-Unit 'No result was reported for this step.' }
Write-Log "winget configure finished (exit $code)."

Set-Status 'Creating desktop shortcuts'
Show-Status
$shortcuts = @(New-DesktopShortcuts $startMenuBefore)
Write-Log "Desktop shortcuts created: $($shortcuts -join ', ')"

Write-Summary $code $shortcuts
try { [Console]::Beep(880, 250); [Console]::Beep(1175, 350) } catch { }
try { [Console]::CursorVisible = $true } catch { }
Read-Host "`n  Press Enter to close this window"
