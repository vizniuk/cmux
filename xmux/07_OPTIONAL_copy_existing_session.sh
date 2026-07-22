#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_note "OPTIONAL migration: copy official session snapshots into xmux."
xmux_note "WARNING: restored sessions may restart represented commands."
xmux_require_both_apps_stopped
xmux_create_backup_directory cmux-pre-session-migration
backup_path="$XMUX_CREATED_BACKUP_PATH"

official_primary="$(xmux_session_primary_path "$XMUX_OFFICIAL_BUNDLE_ID")"
official_previous="$(xmux_session_previous_path "$XMUX_OFFICIAL_BUNDLE_ID")"
xmux_primary="$(xmux_session_primary_path "$XMUX_BUNDLE_ID")"
xmux_previous="$(xmux_session_previous_path "$XMUX_BUNDLE_ID")"

xmux_backup_migration_target "$backup_path" "$xmux_primary"
xmux_backup_migration_target "$backup_path" "$xmux_previous"
xmux_copy_file_if_present "$official_primary" "$xmux_primary"
xmux_copy_file_if_present "$official_previous" "$xmux_previous"

xmux_note "Pre-migration backup: $backup_path"
xmux_note "No source data, credential, or Keychain material was removed or copied."
