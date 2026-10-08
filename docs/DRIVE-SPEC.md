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
      drive.sh
      session.sh
      omnigent-host.sh
  credentials/
    claude-oauth-token       # from `claude setup-token`; mode 600 where supported
    codex-auth.json          # SINGLE authoritative Codex auth cache
    omnigent-server-url      # stored remote server URL; mode 600
    omnigent-hosts.json      # per-machine host identity map; mode 600
  checksums/                 # SHA256SUMS for every binary on every partition
  tools/
    audit/                   # host-write audit tool (see below)
    omnigent-host            # portable Omnigent host agent relative wrapper
  logs/

AI-WIN/  AI-MAC/  AI-LINUX/   (same shape on each)
  bin/<os>-<arch>/           # claude, codex package, python standalone runtime
  tools/                     # e.g. tools/portable-git/, tools/omnigent-runtime/
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
3. **Mounting**: Automatically mounted via unprivileged `udisksctl` or loop mount (`mount -o loop`) during the session, and cleanly unmounted on exit.
4. **Authoritative credentials**: Authoritative credentials (`claude-oauth-token` and `codex-auth.json`) and cross-platform session locks remain on `AI-SHARED/credentials/`, shared across Windows, macOS, native Linux, and WSL2.
5. **Zero host footprint**: When the session ends and the image is unmounted, zero files remain on the host WSL system.

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

## Omnigent Host Add-on (Linux & macOS)
Self-contained, relocatable Omnigent Host agent (`tools/omnigent-host`) connecting back to a remote Omnigent server:
1. **Standalone Python Runtime**: Uses Astral's standalone Python 3.12 (`bin/<os>-<arch>/python`) with bundled terminfo (`share/terminfo`).
2. **Binary-Only Runtime Dependencies**: Pre-installed binary wheels in `tools/omnigent-runtime` with zero target compilation.
3. **Interactive Server URL Prompt**: Prompts for server URL on first launch if not configured; saves securely to `AI-SHARED/credentials/omnigent-server-url`.
4. **Per-Machine Host Identity**: Mints and tracks distinct UUIDs per physical machine in `AI-SHARED/credentials/omnigent-hosts.json`, preventing cross-machine session resumption.
5. **Zero Host Footprint**: All runtime state, logs, and temp files are confined to drive partitions (`state/`, `tmp/`).

## Known, documented limits
- Gatekeeper / SmartScreen prompts on first run; managed hosts may block.
- Linux `noexec` automounts block execution (document `udisksctl` / remount).
- Browser used for login and the OS itself may leave traces.
- An untrusted host can read credentials while the drive is attached.

