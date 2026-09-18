#Requires -Version 7
<#
    Generates out\<host>.winget files from the hosts\*.txt lists.

    Each line in a host file names a part (parts/...); blank lines and lines
    starting with # are skipped. Comment lines at the top of a host file are
    copied into the header of the generated file. A line naming a .ps1 or .cmd
    file, optionally followed by arguments, becomes a generated step that runs
    that script once (see New-ScriptPart).

    Before anything is written these are checked: missing part, the same part
    added twice, duplicate id, dependsOn pointing at an id that is
    not in the list. Then the GetScript/TestScript blocks of PSDscResources/
    Script steps are run on this machine under Set-StrictMode -Version Latest,
    the way winget runs them (those scripts only read; some fetch version
    information over the network). Finally every output is passed through
    winget configure validate.

    .\build.ps1                    # every host
    .\build.ps1 officehost         # only the named ones
    .\build.ps1 -SkipScriptTest    # without running the scripts (e.g. offline)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Name,

    [switch] $SkipScriptTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$outDir  = Join-Path $root 'out'
$utf8    = [Text.UTF8Encoding]::new($false)
$errors  = [Collections.Generic.List[string]]::new()

function Read-List([string] $Path) {
    Get-Content -LiteralPath $Path -Encoding utf8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

# Resolves the embed tokens in a part's text, so that the generated .winget
# file needs no other file from the repo:
#   ${embed:<path>}      must be alone on its line; the file's content is
#                        written there at that line's indentation (meant to go
#                        inside a PowerShell here-string).
#   ${embedhash:<path>}  may appear anywhere on a line; the file's SHA256 is
#                        written in its place (useful for idempotency).
# Paths are relative to the repo root; content is read with LF line endings.
$embedCache = @{}

function Get-EmbedText([string] $Relative, [string] $Entry) {
    if (-not $embedCache.ContainsKey($Relative)) {
        $file = Join-Path $root $Relative
        $embedCache[$Relative] = $(if (Test-Path -LiteralPath $file -PathType Leaf) {
            ((Get-Content -LiteralPath $file -Raw -Encoding utf8) -replace "`r`n", "`n").TrimEnd()
        } else { $null })
        if ($null -eq $embedCache[$Relative]) { $errors.Add("${Entry}: file to embed not found: $Relative") }
    }
    return $embedCache[$Relative]
}

function Get-EmbedHash([string] $Text) {
    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($Text))
    return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
}

function Expand-Embed([string] $Text, [string] $Entry) {
    $out = [Collections.Generic.List[string]]::new()
    foreach ($line in $Text -split "`n") {
        # Comment lines are left alone (they may mention the tokens).
        if ($line -match '^\s*#') { $out.Add($line); continue }
        if ($line -match '^(?<indent> *)\$\{embed:(?<path>[^}]+)\}\s*$') {
            $indent  = $Matches['indent']
            $file    = $Matches['path'].Trim()
            $content = Get-EmbedText $file $Entry
            if ($null -eq $content) { continue }
            foreach ($contentLine in ($content -split "`n")) {
                # Once YAML strips the indentation, a line starting with '@ or
                # "@ would close the here-string it is embedded in early.
                if ($contentLine -match "^['`"]@") { $errors.Add("${Entry}: $file has a line that closes the here-string") }
                $out.Add($(if ($contentLine -eq '') { '' } else { $indent + $contentLine }))
            }
            continue
        }
        while ($line -match '\$\{embedhash:(?<path>[^}]+)\}') {
            $token   = $Matches[0]
            $content = Get-EmbedText $Matches['path'].Trim() $Entry
            if ($null -eq $content) { break }
            $line = $line.Replace($token, (Get-EmbedHash $content))
        }
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Read-Part([string] $Entry) {
    $path = Join-Path $root "$Entry.yaml"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = ((Get-Content -LiteralPath $path -Raw -Encoding utf8) -replace "`r`n", "`n").TrimEnd()
    $text = Expand-Embed $text $Entry
    [pscustomobject]@{
        Entry     = $Entry
        Text      = $text
        Ids       = @([regex]::Matches($text, '(?m)^  id:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
        DependsOn = @([regex]::Matches($text, '(?m)^  dependsOn:\n((?:    - .+\n?)+)') |
                      ForEach-Object { [regex]::Matches($_.Groups[1].Value, '(?m)^    - (\S+)') } |
                      ForEach-Object { $_.Groups[1].Value })
    }
}

# A host line naming a .ps1 or .cmd file (with optional arguments) becomes a
# generated Script step: the file is embedded, written to %TEMP% and run
# elevated in its own process; a non-zero exit code fails the step. It runs
# once per machine, and again only when the file or the arguments change: the
# SHA256 of the file plus the arguments is recorded under
# HKLM\SOFTWARE\winget-config\Scripts. The arguments are PowerShell syntax.
function New-ScriptPart([string] $Line) {
    if ($Line -notmatch '^(?<path>\S+\.(?<ext>ps1|cmd))(?:\s+(?<args>.+))?$') { return $null }
    $path = $Matches['path']
    $ext  = $Matches['ext'].ToLowerInvariant()
    $argv = if ($Matches['args']) { $Matches['args'].Trim() } else { '' }
    $file = Join-Path $root $path
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $errors.Add("${Line}: script not found: $path"); return $null }
    $name = Split-Path $path -Leaf

    # map-drives.cmd -> mapDrives
    $words = @(([IO.Path]::GetFileNameWithoutExtension($name) -split '[^A-Za-z0-9]+') | Where-Object { $_ })
    if (-not $words) { $errors.Add("${Line}: cannot derive an id from $name"); return $null }
    $id = $words[0].Substring(0, 1).ToLowerInvariant() + $words[0].Substring(1) +
          (($words | Select-Object -Skip 1 | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '')

    if ($ext -eq 'cmd' -and (Get-EmbedText $path $Line) -match '[^\x00-\x7F]') {
        $errors.Add("${Line}: $path has non-ASCII characters; it is written as ASCII for cmd.exe")
    }

    $label   = "$name $argv".Trim()
    $applied = "`${embedhash:$path}|$argv".Replace("'", "''")
    $temp    = "winget-config-$id.$ext"
    $write   = if ($ext -eq 'ps1') {
        # Windows PowerShell 5.1 reads a BOM-less file as ANSI.
        '[IO.File]::WriteAllText($file, ($text -replace "`r?`n", "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))'
    } else {
        # cmd.exe misreads a BOM, and LF-only endings can break goto/call :label.
        '[IO.File]::WriteAllText($file, ($text -replace "`r?`n", "`r`n") + "`r`n", [Text.Encoding]::ASCII)'
    }
    $run = if ($ext -eq 'ps1') { "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$file $argv".TrimEnd() }
           else { "& `$file $argv".TrimEnd() }

    $text = @"
# Generated by build.ps1 from the host line: $Line
- resource: PSDscResources/Script
  id: $id
  directives:
    description: '$($label.Replace("'", "''"))'
    allowPrerelease: true
    securityContext: elevated
  settings:
    GetScript: |
      `$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\winget-config\Scripts')
      `$applied = if (`$key) { `$key.GetValue('$id') } else { `$null }
      return @{ Result = `$(if (`$applied) { "applied `$applied" } else { 'not applied' }) }
    TestScript: |
      `$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\winget-config\Scripts')
      return [bool](`$key -and `$key.GetValue('$id') -eq '$applied')
    SetScript: |
      `$file = Join-Path `$env:TEMP '$temp'
      # --- embedded script (source: $($path.Replace('/', '\'))) ---
      `$text = @'
      `${embed:$path}
      '@
      $write
      try {
        `$output = $run 2>&1 | Out-String
        if (`$LASTEXITCODE -ne 0) { throw "$name failed with exit code `${LASTEXITCODE}:``n`$output" }
      } finally {
        Remove-Item -LiteralPath `$file -Force -ErrorAction SilentlyContinue
      }
      `$key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\winget-config\Scripts')
      `$key.SetValue('$id', '$applied')
      `$key.Close()
"@
    $text = Expand-Embed (($text -replace "`r`n", "`n").TrimEnd()) $Line
    [pscustomobject]@{ Entry = $Line; Text = $text; Ids = @($id); DependsOn = @() }
}

# Returns the body of the "    Key: |" block in a part's text (6-space indent).
function Get-ScriptBlockText([string[]] $Lines, [int] $From, [string] $Key) {
    for ($i = $From; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^- resource:' -and $i -gt $From) { return $null }
        if ($Lines[$i] -ne "    ${Key}: |") { continue }
        $body = [Collections.Generic.List[string]]::new()
        for ($j = $i + 1; $j -lt $Lines.Count -and ($Lines[$j] -eq '' -or $Lines[$j].StartsWith('      ')); $j++) {
            $body.Add($(if ($Lines[$j] -eq '') { '' } else { $Lines[$j].Substring(6) }))
        }
        return ($body -join "`n").TrimEnd()
    }
    return $null
}

# --- resolve hosts ------------------------------------------------------------
$hostFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'hosts') -Filter '*.txt' | Sort-Object Name)
if (-not $hostFiles) { throw 'No .txt files under hosts\.' }
# Both "a,b" (a single string when invoked with pwsh -File) and "a b" work.
$Name = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Name) {
    $known = @($hostFiles | ForEach-Object BaseName)
    $missing = @($Name | Where-Object { $_ -notin $known })
    if ($missing) { throw "Not found under hosts\: $($missing -join ', ')" }
    $hostFiles = @($hostFiles | Where-Object BaseName -in $Name)
}

$partCache = @{}
$builds = foreach ($file in $hostFiles) {
    $hostName = $file.BaseName
    $entries  = [Collections.Generic.List[string]]::new()

    foreach ($line in Read-List $file.FullName) {
        if ($line -like 'parts/*') { $entries.Add($line) }
        else { $errors.Add("${hostName}: line must start with parts/: $line") }
    }

    $parts = [Collections.Generic.List[object]]::new()
    $seen  = [Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $entries) {
        if (-not $seen.Add($entry)) { $errors.Add("${hostName}: $entry added twice"); continue }
        $isScript = $entry -match '^\S+\.(ps1|cmd)(\s|$)'
        if (-not $partCache.ContainsKey($entry)) {
            $partCache[$entry] = if ($isScript) { New-ScriptPart $entry } else { Read-Part $entry }
        }
        if (-not $partCache[$entry]) {
            # New-ScriptPart has already reported why.
            if (-not $isScript) { $errors.Add("${hostName}: part not found: $entry.yaml") }
            continue
        }
        if (-not $partCache[$entry].Ids) { $errors.Add("${entry}: no '- resource:' / id found"); continue }
        $parts.Add($partCache[$entry])
    }

    $ids = @($parts | ForEach-Object Ids)
    foreach ($dup in @($ids | Group-Object | Where-Object Count -gt 1)) {
        $owners = ($parts | Where-Object { $_.Ids -contains $dup.Name } | ForEach-Object Entry) -join ', '
        $errors.Add("${hostName}: id '$($dup.Name)' appears more than once ($owners)")
    }
    foreach ($part in $parts) {
        foreach ($dep in $part.DependsOn) {
            if ($dep -notin $ids) { $errors.Add("${hostName}: $($part.Entry) depends on step '$dep', which this host does not have") }
        }
    }

    $comments = @(Get-Content -LiteralPath $file.FullName -Encoding utf8 |
                  ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('#') })

    [pscustomobject]@{ Name = $hostName; Parts = $parts; Comments = $comments; StepCount = $ids.Count }
}

# --- script test -------------------------------------------------------------
# MSFT_ScriptResource runs these under Set-StrictMode -Version Latest; the last
# output of TestScript must be a [bool], and GetScript's a hashtable with Result.
$usedParts = @($builds | ForEach-Object Parts | Sort-Object Entry -Unique)
if (-not $SkipScriptTest -and -not $errors.Count) {
    $tested = 0
    foreach ($part in $usedParts) {
        $lines = $part.Text -split "`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -ne '- resource: PSDscResources/Script') { continue }
            $id = [regex]::Match(($lines[$i..([Math]::Min($i + 3, $lines.Count - 1))] -join "`n"), '(?m)^  id:\s*(\S+)').Groups[1].Value

            $set = Get-ScriptBlockText $lines $i 'SetScript'
            if (-not $set) {
                $errors.Add("$($part.Entry) [$id] has no SetScript")
            } else {
                $parseErrors = $null
                [void][Management.Automation.Language.Parser]::ParseInput($set, [ref]$null, [ref]$parseErrors)
                if ($parseErrors) { $errors.Add("$($part.Entry) [$id] SetScript syntax: $($parseErrors[0].Message)") }
            }

            foreach ($key in 'GetScript', 'TestScript') {
                $text = Get-ScriptBlockText $lines $i $key
                if (-not $text) { $errors.Add("$($part.Entry) [$id] has no $key"); continue }
                try {
                    $output = @(& ([scriptblock]::Create($text)))
                    $last = if ($output.Count) { $output[$output.Count - 1] } else { $null }
                    if ($key -eq 'TestScript' -and $last -isnot [bool]) {
                        $errors.Add("$($part.Entry) [$id] TestScript did not return a [bool]")
                    }
                    if ($key -eq 'GetScript' -and -not ($last -is [hashtable] -and $last.ContainsKey('Result'))) {
                        $errors.Add("$($part.Entry) [$id] GetScript did not return @{ Result = ... }")
                    }
                } catch {
                    $errors.Add("$($part.Entry) [$id] $key failed under StrictMode: $($_.Exception.Message)")
                }
            }
            $tested++
        }
    }
    Write-Host "Script test: ran $tested Script step(s) under StrictMode."
}

if ($errors.Count) {
    Write-Host ''
    Write-Host "Errors ($($errors.Count)); nothing was written:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

# --- write the files -----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$failed = $false

foreach ($build in $builds) {
    $sb = [Text.StringBuilder]::new()
    $relative = "out\$($build.Name).winget"
    [void]$sb.Append("# yaml-language-server: `$schema=https://aka.ms/configuration-dsc-schema/0.2`n")
    [void]$sb.Append("#`n# GENERATED BY build.ps1 -- DO NOT EDIT BY HAND.`n")
    [void]$sb.Append("# Source: hosts\$($build.Name).txt`n#`n")
    foreach ($c in $build.Comments) { [void]$sb.Append("$c`n") }
    if ($build.Comments) { [void]$sb.Append("#`n") }
    [void]$sb.Append("# Usage:`n#   winget configure -f $relative --accept-configuration-agreements`n#`n")
    [void]$sb.Append("properties:`n  configurationVersion: 0.2.0`n  resources:`n")

    $first = $true
    foreach ($part in $build.Parts) {
        if (-not $first) { [void]$sb.Append("`n") }
        $first = $false
        [void]$sb.Append("    # --- $($part.Entry) ---`n")
        foreach ($line in $part.Text -split "`n") {
            [void]$sb.Append($(if ($line -eq '') { "`n" } else { "    $line`n" }))
        }
    }

    $path = Join-Path $root $relative
    $new = $sb.ToString()
    $status = if (-not (Test-Path -LiteralPath $path)) { 'new' }
              elseif ([IO.File]::ReadAllText($path, $utf8) -ceq $new) { 'unchanged' }
              else { 'updated' }
    if ($status -ne 'unchanged') { [IO.File]::WriteAllText($path, $new, $utf8) }

    $validation = & winget configure validate -f $path --disable-interactivity 2>&1 | Out-String
    $valid = $LASTEXITCODE -eq 0
    Write-Host ('{0,-16} {1,3} parts {2,3} steps  {3,-9} {4}' -f $build.Name, $build.Parts.Count, $build.StepCount, $status,
                $(if ($valid) { 'winget validate: ok' } else { 'winget validate: FAILED' })) `
               -ForegroundColor $(if ($valid) { 'Gray' } else { 'Red' })
    if (-not $valid) { Write-Host $validation -ForegroundColor Red; $failed = $true }
}

# Outputs whose host file is gone (only when generating every host).
if (-not $Name) {
    $known = @($builds | ForEach-Object Name)
    Get-ChildItem -LiteralPath $outDir -Filter '*.winget' | Where-Object { $_.BaseName -notin $known } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName
        Write-Host "deleted: out\$($_.Name) (no hosts\$($_.BaseName).txt)" -ForegroundColor Yellow
    }
}

if ($failed) { exit 1 }
