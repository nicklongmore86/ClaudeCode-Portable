# Portable AI Drive — Shared Partitioned-Drive Spec (v1)

Shared contract for portable AI drive:
- `nicklongmore86/ClaudeCode-Portable` (production build)

## Goals
1. Zero installation on the host: no installers, no global npm/pip, no admin
   rights required for normal use, no services/daemons registered.
2. Use the user's own subscriptions via the **official, unmodified CLIs**:
   - Claude Pro/Max → official Claude Code native binary.
   - ChatGPT Plus/Pro → official OpenAI Codex native package.
   (No third-party code may perform Claude subscription OAuth — Anthropic only
   permits subscription login in the unmodified Claude Code binary.)
3. Full filesystem access on the host, bounded by the host user's permissions.
4. All app state, credentials, caches and temp files on the drive; host writes
   minimized and auditable.

## Partition layout (GPT)

| # | Label        | FS    | Size (suggested) | Purpose |
|---|--------------|-------|------------------|---------|
| 1 | `AI-SHARED`  | exFAT | 8–16 GB          | Front door. Launchers for every OS, README/START-HERE, `credentials/`, checksums, shared notes. Readable+writable by Windows, macOS, Linux without drivers. |
| 2 | `AI-WIN`     | NTFS  | 30%+ of rest     | Windows binaries (x64 + arm64), Portable Git, Windows state/tmp. |
| 3 | `AI-MAC`     | APFS  | 30%+ of rest     | macOS binaries (arm64 + x64), macOS state/tmp. |
| 4 | `AI-LINUX`   | ext4  | 30%+ of rest     | Linux binaries (x64 + arm64, musl where available), Linux state/tmp. |

Rationale: exFAT is the only FS every OS reads/writes natively, but it lacks
symlinks/POSIX perms (Codex `CODEX_HOME` breaks on it). Each OS therefore runs
binaries and keeps runtime state on its native FS; only plain files cross OSes
via `AI-SHARED`.

Partition 1 is first so it is the volume every OS mounts/shows by default.

### Per-partition directory layout
```
AI-SHARED/
  START-HERE.md
  launch/
    windows.cmd        # double-click entry -> windows.ps1 (ExecutionPolicy Bypass, process scope)
    windows.ps1
    macos.command      # double-clickable on macOS
    linux.sh
    lib/               # shared launcher helpers (pure sh / ps1; no runtime deps)
  credentials/
    claude-oauth-token       # from `claude setup-token`; mode 600 where supported
    codex-auth.json          # SINGLE authoritative Codex auth cache
  checksums/                 # SHA256SUMS for every binary on every partition
  tools/
    audit/                   # host-write audit tool (see below)
  logs/

AI-WIN/  AI-MAC/  AI-LINUX/   (same shape on each)
  bin/<os>-<arch>/           # claude, codex package (bin/, codex-path/rg, codex-resources/...), goose etc.
  tools/                     # e.g. AI-WIN/tools/portable-git/
  state/
    claude/                  # CLAUDE_CONFIG_DIR
    codex/                   # CODEX_HOME (must NOT be under tmp/)
    xdg/{config,cache,data,state}/
    <tool>/                  # e.g. goose/ -> GOOSE_PATH_ROOT
  tmp/                       # TMPDIR / TEMP / TMP, CLAUDE_CODE_TMPDIR
```

## Launcher contract (all OSes)
1. Locate `AI-SHARED` from the launcher's own path — never hardcode drive
   letters or mount points.
2. Locate the native partition by **volume label**:
   - Windows: `Get-Volume -FileSystemLabel AI-WIN` (no admin needed).
   - macOS: `/Volumes/AI-MAC` (fallback: `diskutil info` by label).
   - Linux: `/dev/disk/by-label/AI-LINUX`; if not mounted, try
     `udisksctl mount -b` (no root on desktops); otherwise print exact
     instructions and exit non-zero. Never call `sudo` implicitly.
3. Detect OS + arch, pick `bin/<os>-<arch>/`; fail loudly if missing.
4. Set env **for the child process only** (never persist to host profile,
   registry, shell rc, or PATH):
   - `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_TMPDIR`, `CLAUDE_CODE_OAUTH_TOKEN`
     (read from `AI-SHARED/credentials/claude-oauth-token`; never echoed/logged)
   - `DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1`, `DISABLE_TELEMETRY=1`,
     `DISABLE_ERROR_REPORTING=1`
   - Windows: `CLAUDE_CODE_GIT_BASH_PATH` → `AI-WIN/tools/portable-git/bin/bash.exe`
   - `CODEX_HOME`, `CODEX_SQLITE_HOME`; Codex `config.toml` contains
     `cli_auth_credentials_store = "file"`, `check_for_update_on_startup = false`,
     `[analytics] enabled = false`, `[feedback] enabled = false`.
     Codex is launched with `--no-daemon`.
   - `TMPDIR`/`TEMP`/`TMP`, `XDG_*_HOME` → native partition.
   - Unset conflicting inherited creds: `ANTHROPIC_API_KEY`,
     `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`.
   - Prepend drive `bin/` dirs to the child PATH.
5. Codex auth sync: before launch copy `AI-SHARED/credentials/codex-auth.json`
   → `$CODEX_HOME/auth.json`; after the child exits, copy back if newer.
   Use a lock file on `AI-SHARED` to prevent two concurrent sessions.
6. Preserve the host working directory (the user's project), and pass through
   extra CLI args.
7. Offer a menu: Claude Code / Codex / (build-specific: dashboard or Goose) /
   login setup / audit / exit.
8. On exit: ensure no child processes remain so the drive can be ejected.

## WSL2 Mode (Linux launcher inside WSL)
When `launch/linux.sh` is executed inside WSL2 (auto-detected via `/proc/version` or `WSL_DISTRO_NAME`):
1. **Host CLIs**: Uses the official Linux `claude` and `codex` CLIs installed inside the WSL2 Linux environment (rejecting any Windows `.exe` / `.cmd` / `/mnt/*` shims).
2. **Drive-resident state**: Rather than writing state to the host WSL rootfs, the launcher maintains all runtime state, caches, temp files, and Codex SQLite databases inside a drive-resident ext4 image (`AI-SHARED/state/wsl-state.ext4`).
3. **Mounting**: Prefer an already-mounted `AI-LINUX` partition. Otherwise hold an atomic drive-resident `state/wsl-state.lock` (host/distro/PID and per-session token owner) and reject any `losetup -j` attachment before mounting the image. Reset all inherited `DRIVE_WSL_*` state before installing traps. Defer lock-acquisition signals until the owner token is recorded. Teardown uses in-memory acquisition state independently of token readability; only lock/partial removal requires a matching token. Use `udisksctl` when available, or ask via `/dev/tty` (never stdin) before sudo loop setup and an ext4 `nosuid,nodev` mount. Discovery keeps state in the calling shell; cleanup traps are installed before acquisition. Every exit syncs, unmounts and detaches; failures return non-zero, warn not to unplug, and retain the lock. Stale-lock recovery is manual by design and requires verification across all distros/hosts; never infer safety from a local PID alone.
4. **Authoritative credentials**: Authoritative credentials (`claude-oauth-token` and `codex-auth.json`) and cross-platform session locks remain on `AI-SHARED/credentials/`, shared across Windows, macOS, native Linux, and WSL2.
5. **Host remnants**: Runtime state stays on the drive, but sudo/udisks logs and sudo timestamps may remain on the host. Sudo uses an owned, non-symlink `mktemp -d` mountpoint under `$XDG_RUNTIME_DIR` or `/tmp`; successful cleanup removes it. Crashes or cleanup failures may leave the directory behind. Failure to remove an empty directory warns but releases the lock after verified detach.
6. **Image creation**: Format a temporary file inside the token-owned drive lock directory with `mkfs.ext4 -E root_owner=UID:GID` (e2fsprogs >= 1.42), then atomically rename it. Failures remove the partial file. `PORTABLE_AI_WSL_IMAGE_SIZE` accepts integer `M`/`G` sizes (default `4G`, minimum `64M`) for new images. Check free space; reject FAT32 files of 4 GiB or larger only on directly visible filesystems. DrvFS reports v9fs/virtiofs, so its file-size limits are handled as allocation errors. exFAT allocates the full size, not sparse storage. Existing images are not resized.
7. **Recovery and compatibility**: WSL1 is refused; `PORTABLE_AI_WSL=0` disables detection. Resolve Linux CLIs once before redirecting HOME, searching PATH plus the original HOME’s `.local/bin`, `.npm-global/bin`, `.claude/local`, `.bun/bin`, active/default nvm bins and remaining nvm versions, then `/usr/local/bin` and `/usr/bin`. Prefer nvm’s default alias (`system` prioritizes system bins); never source startup scripts. Preserve each CLI’s original search directory separately from its resolved symlink target, and prepend it to that CLI child’s PATH so `env node` uses the matching runtime. Reject resolved Windows shims, `v9fs|9p|virtiofs|drvfs` binaries and PE executables. Print a `sudo chown UID:GID <mount>` repair command for old/different-UID images with non-writable roots. After an unclean eject, stop all sessions, unmount/detach the image in every distro, then run `e2fsck -f` on the image before removing stale locks/partials. See START-HERE's WSL2 section for recovery. Udisks authorization/service availability and loop-over-DrvFS flush behavior require validation on real WSL2 hardware.

8. **Privileged recovery**: The sudo invocation attaches a loop, then starts a detached root watchdog with the exact device before mounting; privileged rollback covers signals during loop setup. Normal launcher cleanup refreshes authentication with `sudo -v`; HUP/TERM cleanup uses only `sudo -n`. If unavailable, the watchdog waits for acquisition and launcher exit using PID/start-time checks at 1-second intervals, without reading the drive lock each tick. Teardown always syncs, unmounts by loop device, detaches and verifies no attachment remains, regardless of token changes/read failures. Token mismatch after teardown leaves the lock untouched and reports failure. The watchdog retries up to 12 times with 2, 4, 8, 16, then 30-second delays (240 seconds total backoff); it never uses lazy unmount. On exhaustion or token mismatch it writes `state/wsl-state.ext4.recovery.<token>.log` with recovery instructions, retains the lock and exits. Successful normal cleanup or recovery leaves no watchdog behind. Empty mountpoint removal errors only warn. The tiny signal-ignore window during watchdog fork/exec intentionally drops signals; the watchdog still covers launcher death. This covers tty closure/expired tickets, not WSL shutdown or power loss. Keep the drive connected until verified teardown and lock recovery.

## First-time login (on any machine)
- Claude: launcher option runs `claude setup-token`, user pastes the printed
  token, launcher writes it to `credentials/claude-oauth-token`.
- Codex: launcher runs `codex login --device-auth` (fallback: normal browser
  login) with `CODEX_HOME` on the drive, then copies `auth.json` to
  `credentials/codex-auth.json`.

## Provisioning (prep machine, never the target host)
- `provision/` scripts download pinned release assets, verify SHA256 (and
  signatures where published), and lay them out per the tree above.
- Partitioning helper (Linux, `sgdisk` + `mkfs.exfat`/`mkfs.ntfs`/`mkfs.ext4`)
  MUST require an explicit `--device /dev/sdX` and an interactive typed
  confirmation of the device's model/serial; refuses system disks; supports
  `--dry-run`. APFS cannot be created from Linux: script leaves partition 3
  as a placeholder and the doc gives the one `diskutil eraseVolume APFS AI-MAC`
  step to run on a Mac.
- ext4 ownership: after provisioning, the Linux state dirs get permissions so
  a different UID on another Linux host can still use them (documented
  trade-off), or the launcher detects UID mismatch and explains.

## Host-write audit tool
`tools/audit/` — snapshot (path, size, mtime) of likely host-write locations
(home dir dotfiles, `~/.claude*`, `~/.codex`, `~/.config`, `~/.cache`,
`~/.local`, `%APPDATA%`, `%LOCALAPPDATA%`, `%TEMP%`, `~/Library/...`, system
temp) before and after a session; print a diff report. Pure sh / PowerShell.
The Windows script canonicalizes roots, enumerates extended-length local and UNC
paths, and stores normal paths as `path|length|ticks`. Legacy runtimes that reject
extended paths retry normal paths with a warning that long paths may be missed.
Device paths are excluded and counted as unreadable. Unreadable paths are counted
and warned about (an unreadable directory counts once for its subtree). Missing
roots and non-admin access to `%SystemRoot%\Temp` can cause expected warnings.
Nested directory junctions/symlinks are not followed, unlike Windows PowerShell
5.1's recursive provider; root junctions/symlinks are followed. The script writes
only the requested snapshot, but PowerShell's own LOCALAPPDATA cache writes may
appear in diffs. Real Windows PowerShell 5.1 / 7 validation, including hosts with
long-path support disabled, is still required.

## Known, documented limits
- Gatekeeper / SmartScreen prompts on first run; managed hosts may block.
- Linux `noexec` automounts block execution (document `udisksctl` / remount).
- Browser used for login and the OS itself may leave traces.
- An untrusted host can read credentials while the drive is attached.
