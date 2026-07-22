#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_note "OPTIONAL migration: copy only official bundle-specific notification history into xmux."
xmux_require_both_apps_stopped
xmux_create_backup_directory cmux-pre-notification-migration
backup_path="$XMUX_CREATED_BACKUP_PATH"

official_history="$(xmux_notification_history_path "$XMUX_OFFICIAL_BUNDLE_ID")"
xmux_history="$(xmux_notification_history_path "$XMUX_BUNDLE_ID")"
xmux_backup_migration_target "$backup_path" "$xmux_history"
xmux_copy_file_if_present "$official_history" "$xmux_history"

xmux_note "Pre-migration backup: $backup_path"
xmux_note "Active notification state was not modified."
xmux_note "No credential or Keychain material was copied."
