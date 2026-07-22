#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_note "OPTIONAL migration: export official macOS defaults and import them into the xmux bundle domain."
xmux_note "Shared cmux.json is not copied because both applications already share it."
xmux_require_both_apps_stopped
xmux_create_backup_directory cmux-pre-defaults-migration
backup_path="$XMUX_CREATED_BACKUP_PATH"
official_export="$backup_path/$XMUX_OFFICIAL_BUNDLE_ID.plist"
xmux_export="$backup_path/$XMUX_BUNDLE_ID-before.plist"

xmux_note "Source defaults domain: $XMUX_OFFICIAL_BUNDLE_ID"
xmux_note "Target defaults domain: $XMUX_BUNDLE_ID"
if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$official_export"
  xmux_print_command "$XMUX_DEFAULTS_BIN" export "$XMUX_BUNDLE_ID" "$xmux_export"
  xmux_print_command "$XMUX_DEFAULTS_BIN" import "$XMUX_BUNDLE_ID" "$official_export"
  xmux_note "Pre-migration backup: $backup_path"
  exit 0
fi

if ! "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$official_export" >/dev/null 2>&1; then
  xmux_note "Official defaults are absent; nothing imported."
  xmux_note "Pre-migration backup: $backup_path"
  exit 0
fi
"$XMUX_DEFAULTS_BIN" export "$XMUX_BUNDLE_ID" "$xmux_export" >/dev/null 2>&1 || true
"$XMUX_DEFAULTS_BIN" import "$XMUX_BUNDLE_ID" "$official_export" >/dev/null

xmux_note "Pre-migration backup: $backup_path"
xmux_note "No shared settings, credential, or Keychain material was copied."
