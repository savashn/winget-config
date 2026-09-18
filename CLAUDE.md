# CLAUDE.md

WinGet Configuration files for provisioning Windows machines. `build.ps1` composes
`hosts/*.txt` lists out of `parts/**/*.yaml` and writes `out/<host>.winget`.

Read `README.md` for what the project does. This file is about how to work in it.

## The one hard rule: `out/*.winget` must be standalone

A generated file has to work when it is the only thing copied to the target
machine. Nothing may be looked for next to it.

- **Text a step needs** -> embed it at build time with `${embed:}` / `${embedhash:}`.
- **Binaries a step needs** -> download at apply time, and verify what you
  downloaded (Authenticode signature, or a pinned SHA256 for a self-hosted file).
- **Never use `${WinGetConfigRoot}`.** It resolves to the folder holding the
  `.winget` file and is exactly how portability gets broken. There are currently
  zero occurrences in the repo; keep it that way.

`installers/` is vestigial. No step reads it, and nothing should start.

## Embed tokens

Implemented in `build.ps1` (`Get-EmbedText`, `Get-EmbedHash`, `Expand-Embed`),
expanded inside `Read-Part`, so everything downstream sees expanded text.

- `${embed:<repo-relative path>}` must be alone on its line; the file's content is
  written at that line's indentation. It usually sits inside a PowerShell
  here-string (`@'` ... `'@`) in a `SetScript`; it may also stand directly in the
  script body to share code between parts (`parts/tools/win11debloat/apply.ps1`).
- `${embedhash:<repo-relative path>}` may appear anywhere on a line and is
  replaced by the file's SHA256. Prefer this over hashing at runtime: it keeps
  `TestScript` to one line and avoids embedding the same file twice.
- Content is read with LF endings and `TrimEnd()`. **Changing that changes the
  hash**, which makes already-provisioned machines re-run the step once.
- Tokens inside comment lines are left alone, so comments may mention them.
- The build fails if an embedded file has a line starting with `'@` or `"@`.

Keep the data file as its own file in `parts/` (for example
`parts/tools/win11debloat/vm.json`): it stays editable, round-trips through the
vendor's own import/export UI, and diffs readably. The build is what folds it in.

When hosts need different data for the same step, make a folder named after the
step with one variant part per data file (`parts/tools/win11debloat/vm.yaml` +
`vm.json`, `client.yaml` + `client.json`). Only the embed/embedhash paths and the
`description` differ between the variant parts; anything longer belongs in a
shared file the variants embed (`apply.ps1`). Name variants by profile, not by
host, so hosts can share one. Variants keep the same `id`, so the build rejects a
host that lists two. Data files do not belong in `hosts/`, which only holds lists.

## Script lines in host files

A host line naming a `.ps1` or `.cmd` under `parts/`, optionally followed by
arguments, is not a part: `New-ScriptPart` in `build.ps1` generates a
`PSDscResources/Script` step for it. Keep the script in the `parts/` category
folder it belongs to, like any part.

- The step runs the script once. The recorded value in
  `HKLM\SOFTWARE\winget-config\Scripts\<id>` is `<SHA256>|<arguments>`, so
  editing the file or the arguments runs it once more. It never checks the
  state the script produced; anything that has to stay in place needs a real
  part with its own `TestScript` (`parts/tools/ydk.yaml`).
- The arguments are pasted into the `SetScript` as PowerShell syntax, so the
  build's syntax check catches bad quoting.
- It runs in its own process, not winget's DSC host: `.ps1` through
  `powershell.exe -File` (5.1; `param()` and `exit` work, and so do the DISM
  cmdlets, which fail in-process), `.cmd` through PowerShell's call operator.
  The exit code decides success.
- The file is written as UTF-8 with BOM (`.ps1`, because 5.1 reads BOM-less
  files as ANSI) or ASCII (`.cmd`, because cmd.exe misreads a BOM), both with
  CRLF (LF-only endings can break `goto`/`call :label`). The build rejects a
  non-ASCII `.cmd`.
- The id comes from the file name, so the same script cannot be listed twice
  on one host; the duplicate-id check catches it.
- No `dependsOn`, and always `securityContext: elevated`. If a script needs
  either, write a part instead.

## Part file conventions

A part file is a fragment of the `.winget` `resources:` list, written at zero
indentation; `build.ps1` indents it by four spaces and pastes it in.

**Indentation is load-bearing.** `build.ps1` parses parts with regexes, not a YAML
parser, and expects exactly: `^- resource:`, `^  id:`, `^  dependsOn:` with
`^    - ` items, and `^    <Key>: |` with the body at six spaces. A part that is
valid YAML but formatted differently goes silently unchecked - duplicate ids are
not caught, script tests do not run. Copy an existing part rather than writing the
skeleton from memory.

- `id` is camelCase and must be unique across every part on a host.
- winget packages: `Microsoft.WinGet.DSC/WinGetPackage` with
  `securityContext: elevated`. Omit it for per-user installs (MSIX and portable
  packages: teams, zen-browser, vscode, claude-code, rustup).
- `PSDscResources/Script` is the escape hatch when no DSC resource exists. You
  write idempotency yourself: `TestScript` must end with a `[bool]`, `GetScript`
  with `@{ Result = ... }`.
- Verify a package id before adding it: `winget show --id <Id> --exact`.

## Directory taxonomy

`apps/`, `dev/`, `drivers/`, `office/`, `tools/`, `windows/` classify **what a
thing is**, not how it is installed. `tools/` holds system-utility/maintenance
programs regardless of install mechanism - plain winget packages (ventoy, rufus,
cpu-z, hdsentinel, pc-manager, java-8) sit next to script-driven downloads
(win11debloat, ydk). `apps/` is for end-user applications instead (browsers,
communication, remote access, document/image viewers, archivers) - the axis is
"utility tool" vs. "application", not the resource type. Other script-driven
steps live outside `tools/` when what they install belongs to a more specific
category (`drivers/virtio`, `office/microsoft-365`, `office/forticlient-vpn`).
Two renames have been considered and rejected:

- `parts/` -> `modules/`: "module" already means a DSC module here, and every
  `resource:` line names one.
- `tools/` -> `scripts/`: switches the classification axis; would be neither
  complete nor exclusive.

## Win11Debloat configs (`parts/tools/win11debloat/`)

Each variant's JSON is Win11Debloat's own config format, so it can be edited in
its UI ("Import/Export config"). What the upstream project accepts is in its
[`Config/`](https://github.com/Raphire/Win11Debloat/tree/master/Config) folder:
`Features.json` for `Tweaks`, `Apps.json` for `Apps`.

- A `Tweaks` name is a `FeatureId` from `Features.json`, not the name of the
  `.reg` file it applies (`ExplorerToThisPC` -> `Launch_File_Explorer_To_This_PC.reg`).
- **A name Win11Debloat does not know is skipped without a word**
  (`Import-ConfigToParams.ps1`), so a typo silently does nothing. So is a feature
  outside its `MinVersion`/`MaxVersion` - `HideChat` (<= 22621), `Hide3dObjects`
  and `HideMusic` (Windows 10 only) do nothing on Windows 11 - and
  `DisableModernStandbyNetworking` on hardware without modern standby, which
  includes most VMs. Setting `Value` to `false` is the same as leaving it out.
- Some tweaks are alternatives of one setting and only one may be `true`:
  `ExplorerTo*`, `CombineTaskbar*`/`CombineMMTaskbar*`, `MMTaskbarMode*`,
  `StartAllApps*`, the taskbar search ones, `Show*DriveLetters*`/`HideDriveLetters`,
  the alt-tab ones, and `Enable`/`DisableDesktopSpotlight`.
- `Apps` takes `AppId`s from `Apps.json`; anything else is reported as
  unsupported and skipped. Listing an app that is not installed does nothing, so
  a long list costs nothing. Most consumer promo apps (Spotify, TikTok, Disney+,
  ...) are not really preinstalled: they are Start menu placeholders Windows
  installs later. What stops that is the `DisableSuggestions` tweak
  (`SilentInstalledAppsEnabled=0`), not the `Apps` list.
- The step is idempotent on the config's SHA256 in
  `HKLM\SOFTWARE\winget-config\Win11Debloat`. Pointing a host at another variant
  runs Win11Debloat once more with the new config; it does not bring back apps
  the previous one removed.

## Language

Everything in the repo is English - comments, error messages, console output,
`README.md`. Two spots are easy to miss:

- `description:` in a part's `directives` is shown by `winget configure` while it
  runs.
- Comments at the top of `hosts/*.txt` are copied into the generated file's header.

## Verifying changes

Run `.\build.ps1` after touching any part, host file, or embedded data file. It
checks more than `winget configure validate` does: missing parts, a part added
twice, duplicate `id`, `dependsOn` on a step the host lacks -
and it actually executes every `GetScript`/`TestScript` under
`Set-StrictMode -Version Latest`, the way winget will.

`-SkipScriptTest` skips only that execution (use it offline).

A part no host uses is not validated at all. To check one, create a throwaway
`hosts/_verify.txt` listing it, run `.\build.ps1 _verify`, then delete both the
host file and `out/_verify.winget`. The same goes for a script line; the build
only runs its `GetScript`/`TestScript`, never the script itself.

Never hand-edit `out/`.

## Install ISOs (`iso/`)

`iso/build-iso.ps1` consumes `out/<host>.winget` as-is; it does not relax the
standalone rule above. It never builds the `.winget` files itself - run
`build.ps1` first.

- **`RunSynchronousCommand/Path` in `autounattend.xml` is capped at 259
  characters.** Over the limit, Setup fails in the specialize pass with "The
  computer restarted unexpectedly..." and loops on every reboot. That is why the
  RunOnce entry only calls `C:\ProvisioningData\provision.ps1` (written by the
  build into `$OEM$`) instead of carrying an `-EncodedCommand`. Keep logic in that
  script, not on the command line; the build throws if the line gets too long.
- That script is `iso/provision.template.ps1`. It runs under Windows PowerShell
  5.1, so keep it 5.1-compatible and ASCII. A fresh Windows image ships an old
  winget with `winget configure` disabled ("Configuration is not enabled").
  The script runs `winget configure --enable` first. It must be the only
  argument (winget rejects it next to anything else, even
  `--disable-interactivity`). It updates App Installer through the Store and at
  the first logon sits at 95% for a long time - slow, not stuck; it does finish.
  Never put a timeout on winget steps. Because the update replaces the running
  winget, `--enable` may exit non-zero although it worked, and for a short while
  afterwards winget misreads its own command line ("Unrecognized command:
  '...\winget.exe'"). The script therefore polls `winget configure validate`
  until it exits 0 before applying.
- `winget configure` keeps going when a step fails and then exits
  `0x8A15C005` (SET_APPLY_FAILED). `Write-ApplySummary` in the script lists the
  failed steps by parsing winget's English results output (`<Resource> [<id>]`,
  then an indented status line). If winget changes that format the summary says
  it found no results instead of guessing; re-check against a throwaway config
  with a `Script` step whose `SetScript` throws.
- The script window is visible on purpose: a hidden one made a working run look
  like it had failed. RunOnce deletes its entry before running, so a failed run
  is not retried - log enough to diagnose it.
- An unattended `LocalAccount` needs a `<Password>` element even for an empty
  password; without it Windows forces a password change at the first logon.
- `iso/work/` (~25 GB) and the `.iso` files are build output and stay out of git.
- Changes here can only be verified by installing: build one host and install it
  in QEMU on a fresh disk.

## Known dead ends

- **FortiClient VPN online installer cannot run unattended.** It ignores the
  command line completely - `/quiet`, `/silent`, `/S`, `/q`, `/qn`, `-s` and
  `--silent` were all tested and every one opens the wizard (its log says
  `DoManuallyDrivenInstallation_UsingMSIGui`). Do not re-test this. The step
  deliberately opens a setup window and waits; it is the only step needing a human.
  The route to a silent install is hosting the MSI, which the online installer
  extracts to `%TEMP%\FCT_{...}\FortiClientVPN.msi` on its first run.
- Fortinet publishes no guessable direct URL for the full installer; every
  versioned `filestore.fortinet.com` path tried returned 404.
