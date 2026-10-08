# Portable AI drive

> **Protect the drive: if Windows offers to format any partition, click Cancel.**
> **If macOS says the disk is “not readable”, click Ignore.** Do not initialize,
> erase or format it through that prompt; doing so can destroy AI-MAC or AI-LINUX.
> A filesystem unsupported by the current host is not necessarily damaged.


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

The helper assigns explicit GPT type GUIDs:

| Partition | GPT type GUID | Attribute bits set by helper |
| --- | --- | --- |
| 1 AI-SHARED | `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` (Microsoft basic data) | None |
| 2 AI-WIN | `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` (Microsoft basic data) | None |
| 3 AI-MAC | `7C3457EF-0000-11AA-AA11-00306543ECAC` (Apple APFS) | 63 |
| 4 AI-LINUX | `0FC63DAF-8483-4772-8E79-3D69D8477DE4` (Linux filesystem data) | 63 |

Bit 63 is the no-default-drive-letter flag (`0x8000000000000000`). APFS/ext4
are never marked Microsoft basic data. AI-SHARED and AI-WIN remain eligible for
normal Windows drive letters. No hidden or read-only bits are set.
[Microsoft documents](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-partition_information_gpt)
the basic-data type and no-drive-letter behavior for newly seen/moved disks;
this is not a cross-platform promise to suppress all dialogs, nor a way to
remove previously remembered drive-letter assignments. Correct type GUIDs are
the primary distinction for foreign filesystems. Continue to Cancel/Ignore
unexpected prompts; bit 63 is not a macOS prompt-suppression mechanism.

The Linux helper needs Python 3.12+, util-linux, sgdisk, exfatprogs, ntfs-3g,
parted and e2fsprogs. Inspect devices yourself with `lsblk -o PATH,MODEL,SERIAL,SIZE,MOUNTPOINTS`.
Preview using `sh provision/partition-linux.sh --device /dev/sdX --dry-run`.
To erase a deliberately selected, unmounted, non-system disk, run the same
command explicitly as root without `--dry-run`. It requires a terminal and an
exact typed `MODEL / SERIAL`. Missing, null or whitespace-only model/serial
values are refused cleanly; there is no identity bypass. It refuses mounted disks, swap and unprovable system
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

**After the Mac APFS step, verify the partition map again before using Windows.**
The [Apple-authored diskutil manual (Xcode man-page mirror)](https://keith.github.io/xcode-man-pages/diskutil.8.html)
says `eraseVolume` keeps an existing partition while formatting it, and that
`format` controls its partition type. It does **not** promise to preserve GPT
attribute bit 63. Whether a particular macOS version resets that bit has not
been verified here; do not assume preservation or claim a guaranteed reset.

Return to the Linux prep machine, match the physical disk by model/serial,
unmount its volumes, and inspect `sgdisk --print /dev/sdX` and the four entries:

```sh
sgdisk --info=1 --info=2 --info=3 --info=4 /dev/sdX
```

Only if the same four-partition layout is intact (3 is the APFS physical store,
4 is ext4), explicitly as root reapply the types and flag without formatting:

```sh
sgdisk --typecode=3:7C3457EF-0000-11AA-AA11-00306543ECAC \
  --typecode=4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 \
  --attributes=3:set:63 --attributes=4:set:63 /dev/sdX
sgdisk --info=1 --info=2 --info=3 --info=4 /dev/sdX
```

Substitute the verified whole disk, not a partition or APFS synthesized device.
Stop if partition numbering/layout changed. Expect the GUIDs above, bit 63 set
on 3/4 (normally flags `8000000000000000`) and unset on 1/2 (normally zero).
Investigate unexpected hidden/read-only or other flags; do not blindly clear
them. These metadata commands leave filesystem contents intact when applied to
the correct entries. **Do not rerun the partitioning helper after formatting:
it erases the drive.** The [sgdisk author's manual](https://www.rodsbooks.com/gdisk/sgdisk.html)
confirms full GUIDs for `--typecode`, per-bit `--attributes=N:set:63`, and
`--info` inspection. Check again after later repartitioning/formatting tools.
Physical Mac-to-Linux-to-Windows round trips remain a manual verification item.

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

## Hardware notes

A SATA-to-USB 3.0 adapter/enclosure has a **5 Gbps USB link**, not guaranteed
5 Gbps file throughput; the drive, host port and cable may be slower.
[USB-IF documents the USB 3.0 rate](https://usb.org/document-library/inter-chip-supplement-usb-revision-30-specification-revision-102).
Prefer UASP plus explicitly TRIM-capable bridge chipsets/firmware for an SSD;
UASP alone does not prove TRIM pass-through. Confirm support for your enclosure
and host OS, as [adapter vendors note it is product/OS dependent](https://www.startech.com/en-ca/hdd/s2510bpu33).
Use a protective enclosure for a bare 2.5-inch SATA drive. Check whether it is
actually an SSD or HDD using Windows **Defragment and Optimize Drives** (Media
type), or the model/media information in
[CrystalDiskInfo](https://crystalmark.info/en/software/CrystalDiskInfo/).
Some USB bridges limit drive identification; confirm against the drive's label
or manufacturer model specification if the reported type is unavailable.

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

### WSL2 Mode (Linux in Windows Subsystem for Linux)

When running inside WSL2 (e.g. Ubuntu on Windows), execute the Linux launcher directly:

```sh
/mnt/d/launch/linux.sh          # replace 'd' with your AI-SHARED drive letter
```

The launcher automatically detects the WSL2 environment:
- **Official Linux CLIs**: Uses the official Linux `claude` and `codex` CLIs installed in your WSL environment (e.g. via `npm install -g @anthropic-ai/claude-code`). Discovery works with non-interactive `wsl --exec` launches: it checks PATH, then the original distro home's `~/.local/bin`, `~/.npm-global/bin`, `~/.claude/local`, `~/.bun/bin`, active/default nvm bins (preferring `~/.nvm/alias/default`), remaining nvm versions newest first, `/usr/local/bin` and `/usr/bin`. With nvm's default set to `system`, system directories take priority. Each CLI child prepends its matched install directory to PATH so an `env node` shebang uses that installation's Node, even without a login profile. No startup files are sourced. Windows executables (`.exe` / `.cmd` / `.bat`, `/mnt/*`, DrvFS/9p/virtiofs and PE shims) are rejected after symlink resolution.
- **Drive-resident ext4 state**: Runtime state, caches, temp files, and Codex SQLite databases are stored in `AI-SHARED/state/wsl-state.ext4`. First run creates and formats a temporary image inside the session lock directory, owned by your Linux UID/GID, then renames it into place. Formatting requires e2fsprogs >= 1.42 for `root_owner`. The default is 4 GiB; set `PORTABLE_AI_WSL_IMAGE_SIZE=2G` (integer `M` or `G`, minimum `64M`) before first run to change it. Existing images are not resized. **exFAT allocates the full size; this is not sparse storage.** Free space is checked first. FAT32 cannot hold the default 4 GiB file: use exFAT or a smaller size. The FAT32 pre-check applies only to directly visible filesystems; DrvFS reports v9fs/virtiofs instead, so allocation errors are handled and the partial file removed.
- **Shared authoritative credentials**: `claude-oauth-token` and `codex-auth.json` on `AI-SHARED/credentials/` remain authoritative and synchronized across Windows, native Linux, macOS, and WSL2.
- **Clean teardown**: Every exit runs cleanup: sync, unmount, then detach the loop device. A failure returns a non-zero status and warns **do NOT unplug the drive**; the image lock remains for recovery. A sudo mount uses an owned, private temporary directory under `$XDG_RUNTIME_DIR` (or `/tmp`) with `nosuid,nodev`. It is removed after successful cleanup; a crash or failed unmount can leave this empty host directory behind. Sudo/udisks may also write host logs and sudo timestamps; this mode does not promise zero host files.
- **Dashboard**: The Node dashboard is scoped to native Windows (`launch/windows.cmd`); inside WSL2, use the CLI options (Claude Code / Codex / Login / Audit).

WSL1 is refused; convert the distro to WSL2 first. Set `PORTABLE_AI_WSL=0`
to disable detection (for example in a container inheriting WSL variables).
If `AI-LINUX` is already mounted, the launcher uses that native partition.
Otherwise it tries `udisksctl` loop setup; this requires a working udisks service
and authorization policy, which many WSL2 installations lack. If setup is
unavailable, the launcher asks on `/dev/tty` before using sudo to attach/mount
the image. Without a controlling terminal it fails clearly; piped CLI input is
never consumed as consent. It never falls back to host runtime state.

The sudo invocation attaches the loop, then starts a root-owned, detached
watchdog with that exact device before mounting. Privileged rollback handles
signals during attachment. On normal exit the launcher refreshes its sudo ticket (`sudo -v`)
and tears down itself. On HUP/TERM it uses `sudo -n` only. If authentication has
expired or the terminal has closed, the watchdog waits for acquisition and the
launcher to exit, then syncs, unmounts, detaches and verifies no attachment remains.
Teardown follows the acquired device, even if the owner token changes or becomes
unreadable; the token is checked only before releasing the lock. A mismatch leaves
the lock untouched, warns and returns non-zero after teardown. Both paths unmount
by loop device and are idempotent. The watchdog polls process identity once per
second without reading the drive lock each tick. It retries failed teardown up to
12 times, with 2, 4, 8, 16, then 30-second delays (240 seconds of total backoff).
It never lazily unmounts a busy image. After exhausted retries or an ownership
mismatch, it writes recovery instructions to
`state/wsl-state.ext4.recovery.<session-token>.log` on the drive and exits,
leaving the lock for manual recovery. The launcher still returns non-zero when
its own teardown fails; watchdog recovery happens after the launcher exits. Keep the drive
connected until the lock disappears; a closed terminal cannot display warnings.
An empty mountpoint removal failure only warns and does not retain the drive lock.
The watchdog cannot survive WSL shutdown, power loss or forced termination of the
root process; those still require manual recovery.

Older images or images made by a different UID may have a non-writable root.
The launcher prints the exact `sudo chown "UID:GID" "<mount>"` repair command.
Apply it while the image is mounted, then relaunch.

An atomic `AI-SHARED/state/wsl-state.lock/` directory records host, distro and
PID plus a per-session token and excludes other sessions across distros. An existing loop attachment
also blocks launch. Stale-lock recovery is manual by design. Locks are never automatically stolen: a PID missing in
one distro does not prove that another distro has stopped. After a crash,
stop all drive sessions on every host/distro, inspect `losetup -j
"/mnt/d/state/wsl-state.ext4"` in each distro, and unmount/detach any attachment
before recovery. After an unclean eject, run `e2fsck -f
"/mnt/d/state/wsl-state.ext4"` **only while the image is unmounted and detached**.
Once recovery succeeds, remove any `image.partial` inside the stale lock, its
`owner` file and the lock directory, old `wsl-state.partial.*` files, and any
leftover empty temporary mountpoint.
Never unplug following a cleanup warning. Real WSL2 testing is still needed
for udisks availability and loop-image flush behavior over DrvFS/9p.

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
macOS Library, Windows APPDATA/LOCALAPPDATA/TEMP, and system temp. The audit is a
heuristic, not proof of zero host writes.
The Windows audit canonicalizes roots and uses extended-length paths for
local/UNC enumeration, then records readable `path|length|ticks` rows. If a legacy
.NET runtime rejects extended paths, it retries normal paths and warns once that
long paths may be missed. Device paths (`\\.\...`) are excluded and counted as
unreadable. Unreadable paths are counted and reported with a warning; a failed
directory read counts once for its entire unscanned subtree. Missing roots and
non-admin access to `%SystemRoot%\Temp` can cause expected unreadable warnings.
Nested directory junctions/symlinks are not followed, unlike Windows PowerShell
5.1's `Get-ChildItem -Recurse`; root junctions/symlinks are followed.
The script writes only the requested snapshot, with no scratch files. PowerShell
itself may update caches under LOCALAPPDATA, which can appear in snapshot diffs.
Real Windows validation on PowerShell 5.1 and 7, including hosts with long-path
support disabled, is still required; a clean report does not prove full coverage.
Filenames containing newlines can make the text report ambiguous. On Unix,
root symlinks (including macOS /tmp) are followed, but nested directory symlinks
are not. Snapshot scratch and sort spills stay in a private directory beside the
drive output and are removed on success, failure or a handled signal. Optional
`ROOT ...` arguments after the snapshot output restrict the paths scanned.

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

Run `npm test` (all `tests/*.test.mjs`, including mocked drive tests and seven Python
provisioner test functions), then `npm run check`. Python 3.12+ is needed by the
provisioner tests. Run `rg --files -g '*.sh' -g '*.command' -0 | xargs -0 shellcheck -x`
for every shell entry/helper, including upstream scripts. When PowerShell is
available, `pwsh -NoProfile -Command '& ./tests/drive-windows.ps1'` parses all
PowerShell scripts and checks environment construction, volume discovery and C#
supervisor compilation. The npm wrapper skips this gate when pwsh is absent.
On Windows, additionally smoke-test Job Object cleanup and both architectures.
All automated partition tests use fake devices and `--dry-run`; tests download
no release binaries and perform no real login or partition operation.
