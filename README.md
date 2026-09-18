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

## Usage

### Generating `winget` Files

Whenever a part or host file changes:

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

Before writing anything, `build.ps1` checks for: a missing part, the same part added twice, a duplicate `id`, a `dependsOn` on a step the host does not have. It then runs the `GetScript` and `TestScript` blocks of `PSDscResources/Script` steps on this machine under `Set-StrictMode -Version Latest`, the way winget runs them (those scripts only read; some fetch version information over the network), and parses the `SetScript` blocks for syntax errors. Finally it passes every output through `winget configure validate`. Files under `out/` whose host file is gone are deleted.

### Running Your Own Script

A host file can name a `.ps1` or `.cmd` file under `parts/` directly, followed by its arguments:

```
parts/tools/cleanup.ps1 -Mode Full -Target 'C:\My Data'
parts/tools/map-drives.cmd Z: "\\nas\share"
```

`build.ps1` embeds the script into a generated step (id from the file name: `map-drives.cmd` -> `mapDrives`). On the machine the step writes it to `%TEMP%` and runs it elevated in its own process: `.ps1` with Windows PowerShell 5.1, `.cmd` with cmd.exe. A non-zero exit code fails the step, with the script's output in the error. The step runs once per machine, and once more whenever the script or its arguments change.

- The arguments are PowerShell syntax: quote values with spaces, and use single quotes where `$` must stay literal.
- The script must not wait for input (`Read-Host`, `pause`, `set /p`); nobody is there to answer.
- End a `.cmd` with an explicit `exit /b`; keep it ASCII.
- For something that has to be kept in place rather than run once, or that needs `dependsOn`, write a part with its own `TestScript` instead (see `parts/tools/ydk.yaml`).

### Running The Generated `winget` File

The files under `out\` run on their own; copying just the relevant `.winget` file to the machine is enough.

If you didn't enable winget yet, enable it:

```powershell
winget configure --enable
```

To see what would change first, without touching the system:

```powershell
winget configure test -f out\office.winget --accept-configuration-agreements
```

To apply the winget config:

```powershell
winget configure -f out\office.winget --accept-configuration-agreements
```

The command is repeatable; steps that are already installed or already set are skipped. One failing step does not stop the others, so check the output when it finishes.

### Building A Bootable ISO Per Host

`iso\build-iso.ps1` turns the official Windows 11 ISO into one unattended install ISO per host (`out\win-<host>.iso`). Booting it installs Windows without asking anything and, on the first logon, applies that host's `.winget` file in the background.

> [!WARNING]
> The ISO wipes disk 0 without asking. It also creates a local administrator named `User` with **no password**, sets the Turkish (`tr-TR`) locale and the Turkey time zone. Edit `iso\autounattend.template.xml` if that is not what you want.

Extra requirements:

- The official Windows 11 x64 ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11) (browser download only)
- `oscdimg.exe` from the Windows ADK "Deployment Tools" component (the `dev` host installs the ADK through `parts/tools/windows-adk.yaml`)
- About 45 GB free: `iso\work\` holds one extracted copy plus one copy per host, and each ISO is ~6.5 GB

```powershell
.\build.ps1                                                      # make sure out\*.winget is current
.\iso\build-iso.ps1 -SourceIso C:\Users\User\Downloads\Win11.iso # every host in hosts\
.\iso\build-iso.ps1 -SourceIso C:\Users\User\Downloads\Win11.iso -Hosts office
```

The source ISO is extracted into `iso\work\extracted` once and reused on later runs. Delete `iso\work\` afterwards to reclaim the space.

What ends up on the installed machine:

| Path | What it is |
|---|---|
| `C:\ProvisioningData\<host>.winget` | The host's config, copied from `out\` |
| `C:\ProvisioningData\provision.ps1` | Started once by a `RunOnce` entry at the first logon (from `iso\provision.template.ps1`); waits for winget and the network, runs `winget configure --enable`, then applies the `.winget` file |
| `C:\ProvisioningData\<host>.log` | Output of that run |

Setup and the first logon need no input. After the desktop appears, a PowerShell window titled "Setting up this computer" shows the progress; it can take a long time, so leave it open until it asks you to press Enter. Its output is also in the log. If the `Provisioning` value is still under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce`, the script never started.

#### Testing in QEMU before using real hardware

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e
qemu-img create -f qcow2 test-disk.qcow2 64G
qemu-system-x86_64 `
  -m 8G -smp 4 -machine q35 -accel whpx `
  -drive if=pflash,format=raw,readonly=on,file="OVMF_CODE.fd" `
  -drive if=pflash,format=raw,file="OVMF_VARS.fd" `
  -drive file=out\win-office.iso,media=cdrom `
  -drive file=test-disk.qcow2,if=virtio
```

The OVMF files ship with QEMU (look under `share\`, e.g. `edk2-x86_64-code.fd`). `-accel whpx` needs Hyper-V; `-accel tcg` works without it, only much slower. Start every attempt from a fresh disk: a failed install leaves a half-installed system that keeps failing.

#### Writing it to USB

With Rufus, pick GPT / UEFI (non CSM) and **leave every box in the "Windows User Experience" dialog unticked**; otherwise Rufus writes its own `autounattend.xml` over this one. With Ventoy, just copy the `.iso` files onto the stick.

#### Troubleshooting

- **Setup loops on "The computer restarted unexpectedly or encountered an unexpected error"**: a command in the specialize pass of `autounattend.xml` is invalid. The usual cause is a `RunSynchronousCommand/Path` longer than 259 characters. Put longer logic into a script under `$OEM$` and call that instead; `build-iso.ps1` refuses to build a line over the limit.
- **Setup still asks for language or account**: `autounattend.xml` is not at the media root. Check `iso\work\build-<host>\autounattend.xml`.
- **The wrong edition gets installed**: list the editions with `dism /Get-WimInfo /WimFile:D:\sources\install.wim` and change `/IMAGE/INDEX` in `iso\autounattend.template.xml`.

## Layout

```
parts/    Steps. Each .yaml file is one or more winget steps (in today's .winget format, unindented).
          Data files next to them (e.g. win11debloat/vm.json) are embedded into the step at build time.
hosts/    One list per machine: each line names a parts/... entry, or a parts/....ps1/.cmd script with its arguments.
out/      The .winget files build.ps1 generates (and the ISOs iso\build-iso.ps1 builds). Do not edit by hand.
build.ps1 Generates and validates out/ files from the hosts/ lists.
iso/      build-iso.ps1 and the autounattend.xml template for unattended install ISOs. work/ is its scratch space.
```

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
