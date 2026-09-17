# Shared SetScript body of every Win11Debloat variant (full.yaml, light.yaml).
# build.ps1 embeds it into each variant's SetScript. The variant defines
# $json (the config's contents) and $hash (its SHA256) before this runs.

# --- download the latest release ---
$dir     = Join-Path $env:ProgramFiles 'winget-config\Win11Debloat'
$zip     = Join-Path $env:TEMP 'winget-config-win11debloat.zip'
$extract = Join-Path $env:TEMP 'winget-config-win11debloat'
$release = Invoke-RestMethod 'https://api.github.com/repos/Raphire/Win11Debloat/releases/latest'
Invoke-WebRequest $release.zipball_url -OutFile $zip -UseBasicParsing
Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $extract -Force
$archive = @(Get-ChildItem $extract -Directory)
if ($archive.Count -ne 1 -or -not (Test-Path (Join-Path $archive[0].FullName 'Win11Debloat.ps1'))) { throw "Unexpected Win11Debloat archive layout ($($release.tag_name))" }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Get-ChildItem $dir -Exclude 'Logs', 'Backups' | Remove-Item -Recurse -Force
Copy-Item (Join-Path $archive[0].FullName '*') $dir -Recurse -Force
Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
$config = Join-Path $dir 'winget-config.json'
[IO.File]::WriteAllText($config, $json, [Text.UTF8Encoding]::new($false))

# --- run it ---
# Win11Debloat needs Windows PowerShell 5.1, and winget's PowerShell 7
# module paths make 5.1 fail to load modules, so they are stripped for
# the duration of the call.
$modulePath = $env:PSModulePath
try {
  $env:PSModulePath = ($env:PSModulePath -split ';' | Where-Object { $_ -like '*WindowsPowerShell*' }) -join ';'
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Win11Debloat.ps1') -Config $config -Silent 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
} finally {
  $env:PSModulePath = $modulePath
}
if ($exitCode -ne 0) { throw "Win11Debloat $($release.tag_name) failed with exit code ${exitCode}:`n$output" }

$key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\winget-config\Win11Debloat')
$key.SetValue('Applied', $hash)
$key.SetValue('Version', [string]$release.tag_name)
$key.Dispose()
