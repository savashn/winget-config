# winget-config

WinGet Configuration files for setting up Windows with a single command. Each machine's file is generated from shared parts by `build.ps1`.

> [!NOTE]
> This is developed for my VMs and office computers that I'm responsible for.
> So it doesn't provide all the packages in winget out of the box.
> You might need to add packages you want manually.

## Requirements

- Windows 11 or 10
- WinGet
- An internet connection
- An administrator account (one UAC prompt at the start of the run)
- To generate the files (`build.ps1` only): PowerShell 7

## Installing

The files under `out\` run on their own; copying just the relevant `.winget` file to the machine is enough (on hosts with FortiClient the step opens a setup window, see the note below):

```powershell
winget configure -f out\office.winget --accept-configuration-agreements
```

To see what would change first, without touching the system:

```powershell
winget configure test -f out\office.winget --accept-configuration-agreements
```

The command is repeatable; steps that are already installed or already set are skipped. One failing step does not stop the others, so check the output when it finishes.

## Layout

```
parts/    Steps. Each .yaml file is one or more winget steps (in today's .winget format, unindented).
          Data files next to them (e.g. win11debloat.json) are embedded into the step at build time.
groups/   Lists of parts shared by several hosts (client-base, debloat, dev-base).
hosts/    One list per machine: each line names a parts/... or groups/... entry.
out/      The .winget files build.ps1 generates. Do not edit by hand.
build.ps1 Generates and validates out/ files from the hosts/ lists.
```

## Generating the files

Whenever a part, group or host file changes:

```powershell
.\build.ps1                    # every host
.\build.ps1 office             # only the named ones (several, separated by spaces or commas)
.\build.ps1 -SkipScriptTest    # without running the scripts (e.g. offline)
```

```
Script test: ran 6 Script step(s) under StrictMode.
client            10 parts  10 steps  unchanged winget validate: ok
dev               14 parts  29 steps  updated   winget validate: ok
office            11 parts  11 steps  updated   winget validate: ok
```

Before writing anything, `build.ps1` checks for: a missing part or group, the same part added twice, a duplicate `id`, a `dependsOn` on a step the host does not have. It then runs the `GetScript` and `TestScript` blocks of `PSDscResources/Script` steps on this machine under `Set-StrictMode -Version Latest`, the way winget runs them (those scripts only read; some fetch version information over the network), and parses the `SetScript` blocks for syntax errors. Finally it passes every output through `winget configure validate`. Files under `out/` whose host file is gone are deleted.

## Useful commands

| Command | What it does |
|---|---|
| `winget configure validate -f out\dev.winget` | Validates the file without installing anything (`build.ps1` already does this) |
| `winget configure test -f out\dev.winget` | Checks whether the machine still matches the config (changes nothing, may prompt for UAC) |
| `winget configure list` | Shows the history of configs applied to this machine |
| `winget upgrade --all` | Upgrades installed packages |
| `code --list-extensions` | Lists VS Code extension IDs to add to the config |

## Things worth knowing

- **FortiClient VPN** is removed from winget in 2026. So this config downloads and runs the public Fortinet online installer by itself. Therefore it is the only package that opens a setup wizard and requires a human to click next.
