#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"

xmux_create_backup_directory cmux-backup
backup_path="$XMUX_CREATED_BACKUP_PATH"

if [[ -d "$XMUX_CMUX_CONFIG_DIR" ]]; then
  xmux_run "$XMUX_DITTO_BIN" "$XMUX_CMUX_CONFIG_DIR" "$backup_path/config/cmux"
fi
if [[ -d "$XMUX_GHOSTTY_CONFIG_DIR" ]]; then
  xmux_run "$XMUX_DITTO_BIN" "$XMUX_GHOSTTY_CONFIG_DIR" "$backup_path/config/ghostty"
fi
if [[ -d "$XMUX_APPLICATION_SUPPORT" ]]; then
  xmux_run /bin/mkdir -p "$backup_path/Application Support/cmux"
  xmux_run "$XMUX_RSYNC_BIN" -a --exclude 'credentials.json' \
    "$XMUX_APPLICATION_SUPPORT/" "$backup_path/Application Support/cmux/"
fi

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$backup_path/com.cmuxterm.app.plist"
else
  "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$backup_path/com.cmuxterm.app.plist" >/dev/null
fi

xmux_note "Credential files and Keychain material were not copied."
xmux_note "Backup path: $backup_path"
