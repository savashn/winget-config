#Requires -Version 7
<#
    Builds a Windows 11 install ISO per host. Each ISO carries:
      - autounattend.xml at the media root (Turkish locale, disk 0 wiped, local
        "User" account with no password, privacy settings; see
        autounattend.template.xml)
      - out\<host>.winget, copied via $OEM$ to C:\ProvisioningData\<host>.winget
      - C:\ProvisioningData\provision.ps1 (from provision.template.ps1), started
        by a RunOnce entry the first time "User" logs on; it enables
        `winget configure` and applies that file, logging to
        C:\ProvisioningData\<host>.log

    Requires the Windows ADK "Deployment Tools" (oscdimg.exe) and the official
    Windows 11 ISO. Run ..\build.ps1 first so out\<host>.winget is current.

    .\iso\build-iso.ps1 -SourceIso D:\Win11.iso                 # every host
    .\iso\build-iso.ps1 -SourceIso D:\Win11.iso -Hosts dev,office

    The ISO is extracted once into iso\work\extracted and reused on later runs.
    Delete iso\work to force a fresh extraction or to reclaim the space.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceIso,
    [string[]]$Hosts,
    [string]$OscdimgPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$outDir  = Join-Path $root 'out'
$workDir = Join-Path $PSScriptRoot 'work'

if (-not (Test-Path -LiteralPath $SourceIso)) { throw "ISO not found: $SourceIso" }
if (-not (Test-Path -LiteralPath $OscdimgPath)) {
    throw "oscdimg.exe not found at:`n  $OscdimgPath`nInstall the Windows ADK 'Deployment Tools' component, or pass -OscdimgPath."
}

# Hosts come from hosts\*.txt, same as build.ps1. Names starting with '_' are
# throwaway verification hosts and are skipped unless named explicitly.
if (-not $Hosts) {
    $Hosts = @(Get-ChildItem -LiteralPath (Join-Path $root 'hosts') -Filter '*.txt' |
        Where-Object { -not $_.BaseName.StartsWith('_') } |
        Sort-Object Name | ForEach-Object BaseName)
    if (-not $Hosts) { throw 'No .txt files under hosts\.' }
}
$Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

foreach ($h in $Hosts) {
    $wingetFile = Join-Path $outDir "$h.winget"
    if (-not (Test-Path -LiteralPath $wingetFile)) {
        throw "out\$h.winget not found. Run '.\build.ps1 $h' first."
    }
}

# RunSynchronousCommand/Path is capped at 259 characters; anything longer makes
# Setup fail in the specialize pass ("The computer restarted unexpectedly...").
# So the actual work lives in a script on disk and RunOnce only points at it.
function New-RunOnceLine([string]$ScriptPath) {
    $line = "reg add `"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`" /v Provisioning /t REG_SZ /d `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath`" /f"
    if ($line.Length -gt 259) { throw "RunOnce command is $($line.Length) chars; Setup allows at most 259." }
    return $line
}

$templatePath = Join-Path $PSScriptRoot 'autounattend.template.xml'
$placeholder  = '<Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v Provisioning /t REG_SZ /d "{{PROVISIONING_RUNONCE_COMMAND}}" /f</Path>'
$xmlTemplate  = Get-Content -LiteralPath $templatePath -Raw
if (-not $xmlTemplate.Contains($placeholder)) { throw "Placeholder line not found in autounattend.template.xml." }
$provisionTemplate = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provision.template.ps1') -Raw
if (-not $provisionTemplate.Contains('{{HOST}}')) { throw "{{HOST}} not found in provision.template.ps1." }

$extracted = Join-Path $workDir 'extracted'
if (-not (Test-Path -LiteralPath $extracted)) {
    Write-Host "Mounting $SourceIso ..."
    $mount = Mount-DiskImage -ImagePath $SourceIso -PassThru
    try {
        $driveLetter = ($mount | Get-Volume).DriveLetter
        Write-Host "Extracting to iso\work\extracted (copies the whole ISO once, ~6 GB) ..."
        New-Item -ItemType Directory -Force -Path $extracted | Out-Null
        robocopy "${driveLetter}:\" $extracted /MIR /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed extracting the ISO (exit $LASTEXITCODE)." }
    } finally {
        Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    }
} else {
    Write-Host "Reusing already-extracted ISO at iso\work\extracted"
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

foreach ($h in $Hosts) {
    Write-Host "`n=== $h ==="

    $build = Join-Path $workDir "build-$h"
    if (Test-Path -LiteralPath $build) { Remove-Item -LiteralPath $build -Recurse -Force }
    Write-Host "Copying base media -> iso\work\build-$h"
    robocopy $extracted $build /MIR /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying base media for $h (exit $LASTEXITCODE)." }

    # $OEM$\$1 lands at the root of the Windows drive on the installed system.
    $oemDir = Join-Path $build 'sources\$OEM$\$1\ProvisioningData'
    New-Item -ItemType Directory -Force -Path $oemDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $outDir "$h.winget") -Destination (Join-Path $oemDir "$h.winget") -Force

    $provisionScript = $provisionTemplate.Replace('{{HOST}}', $h)
    Set-Content -LiteralPath (Join-Path $oemDir 'provision.ps1') -Value $provisionScript -Encoding UTF8

    $xml = $xmlTemplate.Replace($placeholder, "<Path>$(New-RunOnceLine 'C:\ProvisioningData\provision.ps1')</Path>")
    Set-Content -LiteralPath (Join-Path $build 'autounattend.xml') -Value $xml -Encoding UTF8

    $isoPath  = Join-Path $outDir "win-$h.iso"
    $label    = "WIN11_$($h.ToUpperInvariant())"
    $bootData = "2#p0,e,b$build\boot\etfsboot.com#pEF,e,b$build\efi\microsoft\boot\efisys.bin"
    Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
    Write-Host "Building out\win-$h.iso ..."
    & $OscdimgPath -m -o -u2 -udfver102 "-bootdata:$bootData" "-l$label" $build $isoPath
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed for $h (exit $LASTEXITCODE)." }
    Write-Host "OK -> out\win-$h.iso" -ForegroundColor Green
}

Write-Host "`nDone. Delete iso\work to reclaim disk space (the next run extracts the ISO again)." -ForegroundColor Cyan
