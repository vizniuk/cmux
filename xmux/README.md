# xmux Operations Kit — Xaero Edition

This directory is the permanent, repository-local operating guide for Xaero's isolated `xmux` build of cmux. xmux uses cmux source and shared terminal settings, but it has an explicit build identity, application bundle, CLI wrapper, sockets, macOS defaults, sessions, and notification history. The scripts do not download source, update Git, mutate branches, launch an app except in the explicitly named launch script, or alter the official cmux application.

## Identity

| Property | Official cmux | Xaero xmux |
| --- | --- | --- |
| Application | `/Applications/cmux.app` | `/Applications/xmux.app` |
| Display name | `cmux` | `xmux` |
| Bundle identifier | `com.cmuxterm.app` | `com.cmuxterm.app.debug.xmux-main` |
| CLI | existing `cmux` command | `/Users/xaero/.local/bin/xmux` |
| Control socket | official cmux-managed socket | `/tmp/cmux-debug-xmux-main.sock` |
| Daemon socket | official cmux-managed socket | `/Users/xaero/Library/Application Support/cmux/cmuxd-dev-xmux-main.sock` |

The production xmux build tag is `xmux-main`. Production code recognizes an xmux edition only from a bundle identifier beginning with `com.cmuxterm.app.debug.xmux-`; the display name and application path are not identity sources.

## Exact default paths

| Purpose | Default |
| --- | --- |
| Repository | `/Users/xaero/Projects/cmux` |
| Official application | `/Applications/cmux.app` |
| Custom application | `/Applications/xmux.app` |
| Build tag | `xmux-main` |
| Display name | `xmux` |
| Bundle identifier | `com.cmuxterm.app.debug.xmux-main` |
| DerivedData | `/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main` |
| Built application | `/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main/Build/Products/Debug/xmux.app` |
| CLI wrapper | `/Users/xaero/.local/bin/xmux` |
| Control socket | `/tmp/cmux-debug-xmux-main.sock` |
| Daemon socket | `/Users/xaero/Library/Application Support/cmux/cmuxd-dev-xmux-main.sock` |
| Shared cmux settings | `/Users/xaero/.config/cmux/cmux.json` |
| Shared Ghostty settings | `/Users/xaero/.config/ghostty/config` |
| Application Support | `/Users/xaero/Library/Application Support/cmux` |
| Backup root | `/Users/xaero/Desktop` |

The scripts accept bounded `XMUX_*` overrides for isolated validation. With no overrides, the values above are both the documented and runtime defaults.

## Prerequisites

- This checkout must be the `vizniuk/cmux` repository and include baseline commit `303d4d842006ebedfe2a16d424c6082d1b708902`.
- Run the repository's normal setup before building so submodules and `GhosttyKit.xcframework` are ready.
- The tracked worktree and staging area must be clean. Only `.idea/` and `cmux.iml` may be untracked.
- Xcode, Zig, Rust, and the repository-supported build prerequisites must already be installed.
- The installing account must be allowed to use `sudo` for transactional writes under `/Applications`.
- `/Users/xaero/.local/bin` should be usable from the shell; the CLI installer adds one idempotent `.zshrc` PATH line.

## Initial installation

Run the committed scripts from the repository root, in order:

1. Back up existing state without stopping either application:

   ```bash
   ./xmux/01_backup_existing_cmux.sh
   ```

2. Verify the checkout without changing Git:

   ```bash
   ./xmux/02_verify_source.sh
   ```

3. Build xmux without launching it or changing global cmux CLI links:

   ```bash
   ./xmux/03_build_xmux.sh
   ```

4. Transactionally install xmux without launching it:

   ```bash
   ./xmux/04_install_xmux.sh
   ```

5. Install the dedicated `xmux` CLI wrapper:

   ```bash
   ./xmux/05_install_xmux_cli.sh
   ```

6. Explicitly launch and verify only xmux:

   ```bash
   ./xmux/06_launch_and_verify_xmux.sh
   ```

The backup excludes credential files and never copies Keychain material. If the official macOS defaults domain does not exist, the backup records it as absent/skipped and still succeeds with every available source. If the domain exists, a failed or empty export is a hard error and is never reported as a successful plist. The build uses `scripts/reload.sh` with `CMUX_SKIP_ZIG_BUILD=1`, `--tag xmux-main`, `--name xmux`, `--prod-auth`, and `--no-global-cli-links`; it does not pass `--launch`. Set `XMUX_SWIFT_FRONTEND_WORKAROUND=1` only when the documented Swift frontend workaround is needed.

## Shared and bundle-specific state

The following settings are deliberately shared by both applications:

- `/Users/xaero/.config/cmux/cmux.json`
- `/Users/xaero/.config/ghostty/config`

Do not edit Settings simultaneously in cmux and xmux. Both processes can write the shared configuration, so the last writer wins.

The following state is bundle-specific:

- macOS defaults domain `com.cmuxterm.app.debug.xmux-main`;
- session snapshots named for the xmux bundle identifier under Application Support;
- notification history named for the xmux bundle identifier under Application Support;
- the custom control and daemon sockets;
- the xmux application and CLI wrapper.

The scripts never copy Keychain entries. Authentication remains independently managed by the application's existing secure mechanisms.

## Optional migrations

Every migration is opt-in and has `_OPTIONAL_` in its filename. Each fails closed before creating a backup or changing a target unless it can establish that both official cmux and xmux are fully stopped. Each preserves source data and is safe when its source is absent.

- `./xmux/07_OPTIONAL_copy_existing_session.sh` copies the official primary and previous session snapshots to xmux-specific filenames. Its final receipt reports exact copied, skipped, and backed-up counts and identifies each source and target separately. **Restoring those sessions may restart represented commands. Never copy sessions while either application is running.**
- `./xmux/08_OPTIONAL_copy_notification_history.sh` copies only the bundle-specific notification history file and does not touch active notification state.
- `./xmux/09_OPTIONAL_copy_macos_preferences.sh` distinguishes an absent official defaults domain from probe or export failure. Before importing, it requires a validated nonempty source export and, when xmux defaults already exist, a validated recoverable xmux defaults backup. A failed import leaves that backup in place and reports its recovery path. It does not copy `cmux.json`, which is already shared.

No optional migration runs during build, install, update, launch, or CLI setup.

## Updating xmux

Check for Updates is not the xmux update mechanism. After the operator has updated the checkout separately and left it clean, update xmux with:

```bash
./xmux/10_update_xmux.sh
```

The update script verifies the existing checkout, builds, and transactionally installs. It never fetches, pulls, merges, rebases, checks out, resets, or otherwise updates Git, and it does not launch xmux. It preserves shared settings, xmux defaults, xmux sessions, notification history, and official cmux.

Use `./xmux/10_update_xmux.sh --dry-run` to inspect the workflow without mutation. A dry run still validates the available source and build artifacts.

## Optional uninstall

Review the preserved paths printed by the script, then invoke the explicit confirmation form:

```bash
./xmux/11_OPTIONAL_uninstall_xmux.sh --confirm-remove-xmux
```

Preview it with:

```bash
./xmux/11_OPTIONAL_uninstall_xmux.sh --confirm-remove-xmux --dry-run
```

Official cmux may remain running during uninstall and is never queried for termination or stopped. If exact xmux is active, uninstall requests only the process whose bundle identifier and executable path match `/Applications/xmux.app`, waits for it to exit within a bounded timeout, and aborts before every deletion if it remains active. Similar-name or wrong-executable processes are not killed. After that gate, uninstall removes only `/Applications/xmux.app`, the xmux CLI wrapper, xmux DerivedData, xmux sockets, bundle-specific session files, bundle-specific notification history, and the xmux defaults domain. It preserves `/Applications/cmux.app`, both shared configuration directories, official sessions, and official notification history.

## Recovery

After a real successful backup, `01_backup_existing_cmux.sh` prints a directory such as `/Users/xaero/Desktop/cmux-backup-YYYYMMDD-HHMMSS`. Its dry run creates nothing and reports only planned export and backup paths. Keep both applications stopped before restoring mutable state.

- Restore shared cmux or Ghostty configuration by copying the corresponding directory from `config/` in the backup to its exact default path.
- Restore Application Support data by copying only the needed state file back to `/Users/xaero/Library/Application Support/cmux`; do not restore credential files or Keychain material.
- Restore official macOS defaults by importing `com.cmuxterm.app.plist` from the backup into the official domain.
- If an install fails before replacement, the transactional installer leaves the previous `/Applications/xmux.app` intact. If a post-swap verification fails, it rolls the previous application back.

## Troubleshooting

### GhosttyKit missing

Run the repository's committed setup script, then rerun source verification and the xmux build:

```bash
./scripts/setup.sh
./xmux/02_verify_source.sh
./xmux/03_build_xmux.sh
```

### Swift frontend stall

Opt in to the repository-supported workaround for one build:

```bash
XMUX_SWIFT_FRONTEND_WORKAROUND=1 ./xmux/03_build_xmux.sh
```

### App signature failure

Do not bypass verification. Rerun the build, verify that the built app exists at the exact default path, then rerun the transactional installer. Both scripts require `codesign --verify` success.

### Socket unavailable

Make sure only the explicit launch script is being used, then rerun it. Before launch it verifies the CLI wrapper against the same canonical, shell-escaped content used by the installer, including paths containing spaces, and separately requires a live `PONG`. It distinguishes an exact live xmux socket from an unowned stale socket, a foreign-owned socket, and a non-socket path. It removes only an unowned stale socket at the guarded custom location. Success requires the exact installed xmux process, a newly established socket when a launch was needed, an owner matching that executable, and a content-free `ping` response of `PONG`, all within a bounded wait. An already-running exact xmux is verified without claiming a new launch. Any wrapper mismatch, foreign owner, failed ping, or timeout returns nonzero without claiming success.

```bash
./xmux/06_launch_and_verify_xmux.sh
```

### CLI targets the wrong app

Rerun the committed CLI installer. The wrapper is a small executable script, not a symlink, and always supplies the xmux socket while preserving user arguments.

```bash
./xmux/05_install_xmux_cli.sh
```

### macOS first-open warning

Verify the installed identity and signature with the launch-and-verify script. If macOS still requires first-open consent for this locally signed application, approve the exact `/Applications/xmux.app` instance in the normal macOS security UI; do not remove quarantine or security policy from the official cmux application.

All operational commands in this guide invoke committed repository scripts. There are no one-off installation commands to preserve from chat history.
