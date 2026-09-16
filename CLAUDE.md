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
  written at that line's indentation. It is meant to sit inside a PowerShell
  here-string (`@'` ... `'@`) in a `SetScript`.
- `${embedhash:<repo-relative path>}` may appear anywhere on a line and is
  replaced by the file's SHA256. Prefer this over hashing at runtime: it keeps
  `TestScript` to one line and avoids embedding the same file twice.
- Content is read with LF endings and `TrimEnd()`. **Changing that changes the
  hash**, which makes already-provisioned machines re-run the step once.
- Tokens inside comment lines are left alone, so comments may mention them.
- The build fails if an embedded file has a line starting with `'@` or `"@`.

Keep the data file as its own file in `parts/` (for example
`parts/tools/win11debloat.json`): it stays editable, round-trips through the
vendor's own import/export UI, and diffs readably. The build is what folds it in.

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

## Language

Everything in the repo is English - comments, error messages, console output,
`README.md`. Two spots are easy to miss:

- `description:` in a part's `directives` is shown by `winget configure` while it
  runs.
- Comments at the top of `hosts/*.txt` are copied into the generated file's header.

## Verifying changes

Run `.\build.ps1` after touching any part, group, host file, or embedded data
file. It checks more than `winget configure validate` does: missing parts and
groups, a part added twice, duplicate `id`, `dependsOn` on a step the host lacks -
and it actually executes every `GetScript`/`TestScript` under
`Set-StrictMode -Version Latest`, the way winget will.

`-SkipScriptTest` skips only that execution (use it offline).

A part no host uses is not validated at all. To check one, create a throwaway
`hosts/_verify.txt` listing it, run `.\build.ps1 _verify`, then delete both the
host file and `out/_verify.winget`.

Never hand-edit `out/`.

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
