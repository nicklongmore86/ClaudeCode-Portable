# Portable AI drive

This fork of [techjarves/ClaudeCode-Portable](https://github.com/techjarves/ClaudeCode-Portable)
uses official, unmodified Claude Code and OpenAI Codex releases. The upstream
MIT license and attribution are retained in LICENSE. The acceptance contract
is [docs/DRIVE-SPEC.md](docs/DRIVE-SPEC.md).

## Prepare the drive (prep machine only)

Back up the device. Use a GPT drive with these labels, in this order:

| Label | Format | Suggested capacity | Contents |
| --- | --- | --- | --- |
| AI-SHARED | exFAT | 8–16 GB | Launchers, credentials, notes, checksums, audit logs |
| AI-WIN | NTFS | A third of the remainder | Windows x64/arm64 binaries and state |
| AI-MAC | APFS | A third of the remainder | macOS arm64/x64 binaries and state |
| AI-LINUX | ext4 | The remaining space | Linux x64/arm64 binaries and state |

The Linux helper needs Python 3.12+, util-linux, sgdisk, exfatprogs, ntfs-3g,
parted and e2fsprogs. Inspect devices yourself with `lsblk -o PATH,MODEL,SERIAL,SIZE,MOUNTPOINTS`.
Preview using `sh provision/partition-linux.sh --device /dev/sdX --dry-run`.
To erase a deliberately selected, unmounted, non-system disk, run the same
command explicitly as root without `--dry-run`. It requires a terminal and an
exact typed `MODEL / SERIAL`, refuses mounted disks, swap and unprovable system
disk topology, and rechecks before writing. It never invokes sudo. **Never use a
real device for tests.** Device hot-swapping during partitioning is unsafe.

Partition 3 remains an unformatted APFS placeholder. On a Mac, inspect
`diskutil list` to identify that drive's third partition, then run exactly:

```sh
diskutil eraseVolume APFS AI-MAC /dev/diskNs3
```

Replace `diskNs3` only after matching the physical device and partition. Mount
the volumes on a prep machine that can write their native filesystem; do not
attempt to write APFS from Linux. Normal launch requires no admin rights.

From this repository, provision each OS/architecture on suitable prep hosts:

```sh
python3 provision/download.py --shared /path/to/AI-SHARED \
  --native /path/to/AI-LINUX --target linux-x64 \
  --node-keyring /path/to/trusted-node-release-keys.gpg
```

Repeat for `linux-arm64`, `darwin-x64`, `darwin-arm64`, `win32-x64`, and
`win32-arm64`, using the corresponding native partition. Python accepts Windows
paths too. Prep dependencies: Python 3.12+, GnuPG (`gpg`, `gpgv`), npm,
`cosign` for the published Linux Codex signatures, and `7z` for Portable Git.
Use a trusted Node release keyring prepared following
[Node's release-key instructions](https://github.com/nodejs/release-keys).
Export trusted imported keys using `gpg --export > trusted-node-release-keys.gpg`.
The downloader requires this keyring and fails closed if signature checking fails.

Pins and HTTPS asset URLs are in `provision/assets.json`: Claude 2.1.247,
Codex 0.161.0, Node 24.21.0, Portable Git 2.56.0.2. Claude archives must match
both pinned SHA256 values and the signed official SHASUMS256.txt. The vendored
Claude key is checked against the official fingerprint. Linux Codex archives
also require their published Sigstore bundle, GitHub workflow identity and OIDC
issuer. Node uses its signed checksum manifest. Codex and Git SHA256 pins come
from the official GitHub release asset digests. Full Codex packages retain
`bin/`, `codex-path/`, `codex-resources/`, symlinks and companion executables.
The Linux CLI builds use musl; the optional dashboard's Node requires glibc.
Portable Git x64 is shared by Windows targets (Windows ARM64 x64 emulation is
required for Git). No vendor executable is patched or installed globally.

On a Windows prep host, also compile the small process supervisor once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File provision/windows-supervisor.ps1 -Native W:\
```

`W:\` means the actual AI-WIN drive. It creates `tools/DriveChild.dll` so target
hosts need no compiler or compiler temp files. Then rerun the downloader with
`--checksums-only` for **both** Windows targets to record the DLL. Checksums under
AI-SHARED cover installed files relative to their native partition, and retain
the Claude release checksum manifest and signature. Reprovisioning an existing
architecture requires closing sessions and moving its `bin/<os>-<arch>` aside;
the downloader refuses to overwrite a live installation.

Linux ext4 permissions stay private to the provisioning UID. Before moving to a
host with a different UID, explicitly transfer ownership of `state/` and `tmp/`
on the prep machine (`chown -R TARGET_UID:TARGET_GID /mount/AI-LINUX/state /mount/AI-LINUX/tmp`).
The launcher reports a write/ownership failure instead of silently using host
storage. Avoid world-writable credential directories. exFAT cannot enforce mode
600; shared credentials are readable to anyone who can access the volume.

## Run and sign in

Open `AI-SHARED/launch/windows.cmd`, `macos.command` or `linux.sh`. Terminal
invocation preserves the current project directory; double-clicking uses the
working directory selected by the OS. For explicit projects, invoke from that
project's terminal, for example `/mount/AI-SHARED/launch/linux.sh claude`.
Extra arguments are passed through, e.g. `linux.sh codex exec 'explain this repo'`.
The launcher finds AI-SHARED relative to itself and the native partition by label.
Do not attach drives with duplicate labels. Environment overrides apply only to
children, never shell profiles or the registry. Host API keys/base URLs are
removed. HOME, XDG, temp, Claude state and Codex state point to the native volume.
CODEX_HOME and CODEX_SQLITE_HOME are under `state/codex`, never shared exFAT or tmp.

Choose **Login setup → Claude subscription**. The official `claude setup-token`
performs OAuth and prints a token. Paste it at the hidden prompt; the launcher
stores `AI-SHARED/credentials/claude-oauth-token` and passes it as
CLAUDE_CODE_OAUTH_TOKEN on future launches. The launcher never prints or logs
this token. The official setup command itself displays it; avoid terminal
recording during login. No third-party subscription OAuth is implemented.

Choose **Login setup → Codex device login** for `codex --no-daemon login --device-auth`.
If device login is unavailable, explicitly choose Codex browser login. File
credentials live in `AI-SHARED/credentials/codex-auth.json`. Before each session,
that authoritative file replaces native `auth.json`; a missing shared file clears
stale native auth. On exit, newer local auth is copied back using a staged rename.
An atomic shared `credentials/codex-auth.lock/` directory serializes sessions,
including logins, across hosts/OSes. Never delete a live lock. After a crash,
verify all sessions are stopped before recovering auth or removing the lock.
Auth copy-back failures retain the lock. Eject only after all launchers exit.

Codex's launcher-owned config.toml sets file credentials, update checks off,
analytics off and feedback off; it is rewritten at each session. Use project
config for other preferences. Codex always receives `--no-daemon`. Claude
updates, telemetry and error reporting are disabled. These are defaults, not a
sandbox: CLI arguments and actions can intentionally change behavior. Normal
filesystem access remains bounded by the host user's rights and CLI permissions.

The **Dashboard** retains Node solely for its HTTP server, UI dependencies,
provider adapters and Agent SDK. Native CLI launch does not need Node/npm.
Dashboard subscription login remains terminal-only: use the native Claude menu
for your subscription; configure an API provider separately for the dashboard.
Its printed localhost URL can be opened manually. Browser state remains on the
host. Runtime repair belongs on the prep machine, not the target host.

## Audit and limits

Take metadata snapshots around a session, writing output to AI-SHARED/logs:

```sh
sh /mount/AI-SHARED/tools/audit/audit.sh snapshot /mount/AI-SHARED/logs/before.txt
# Run a session, then:
sh /mount/AI-SHARED/tools/audit/audit.sh snapshot /mount/AI-SHARED/logs/after.txt
sh /mount/AI-SHARED/tools/audit/audit.sh diff /mount/AI-SHARED/logs/before.txt /mount/AI-SHARED/logs/after.txt
```

On Windows use `tools\audit\audit.ps1 snapshot S:\logs\before.txt` and
`audit.ps1 diff S:\logs\before.txt S:\logs\after.txt` (actual shared drive letter).
The menu's `audit` action also passes these arguments through. Snapshots record
path, size and modification time for home dotfiles, app config/cache/data,
macOS Library, Windows APPDATA/LOCALAPPDATA/TEMP, and system temp. Unreadable
paths are skipped; the audit is a heuristic, not proof of zero host writes.
Filenames containing newlines can make the text report ambiguous.

- Gatekeeper/SmartScreen can prompt; managed hosts may block execution entirely.
- Linux `noexec` mounts block binaries. Try `udisksctl mount -b /dev/disk/by-label/AI-LINUX`.
  If already mounted noexec, ask the host owner to remount that volume with exec;
  the launcher never elevates or changes mount policy itself.
- Login browsers, OS services, shell history, security software and project tools
  may leave host traces. Full host access means intentional project writes occur.
- An untrusted host can read all attached credentials. Protect the physical drive,
  revoke lost tokens, and avoid untrusted machines.
- Unix supervision terminates the session process group; programs deliberately
  escaping it (for example by calling setsid) cannot be contained by a portable
  shell. Do not launch detached services from a session. Windows uses a
  kill-on-close Job Object; hosts forbidding nested jobs will fail the launch.
- Force removal/power loss can interrupt auth sync. Keep backups, stop sessions,
  and use the OS eject action. Upstream CLIs and platform behavior still require
  manual smoke tests on each OS/architecture.

Official references: [Claude release integrity](https://code.claude.com/docs/en/setup#binary-integrity-and-code-signing),
[Claude assets](https://github.com/anthropics/claude-code/releases/tag/v2.1.247),
[Codex packages](https://github.com/openai/codex/releases/tag/rust-v0.161.0),
[Codex configuration](https://learn.chatgpt.com/docs/config-file/config-reference).

## Development checks

Run `npm test` (all `tests/*.test.mjs`, including mocked drive tests and six Python
provisioner test functions), then `npm run check`. Python 3.12+ is needed by the
provisioner tests. Run `rg --files -g '*.sh' -g '*.command' -0 | xargs -0 shellcheck -x`
for every shell entry/helper, including upstream scripts. When PowerShell is
available, `pwsh -NoProfile -Command '& ./tests/drive-windows.ps1'` parses all
PowerShell scripts and checks environment construction, volume discovery and C#
supervisor compilation. The npm wrapper skips this gate when pwsh is absent.
On Windows, additionally smoke-test Job Object cleanup and both architectures.
All automated partition tests use fake devices and `--dry-run`; tests download
no release binaries and perform no real login or partition operation.
