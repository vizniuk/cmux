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

copied_count=0
skipped_count=0
backed_up_count=0
planned_copy_count=0
planned_backup_count=0

copy_session_snapshot() {
  local label="$1"
  local source_path="$2"
  local target_path="$3"
  xmux_note "$label source: $source_path"
  xmux_note "$label target: $target_path"
  if [[ -e "$target_path" ]]; then
    xmux_backup_migration_target "$backup_path" "$target_path"
    if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
      planned_backup_count=$((planned_backup_count + 1))
      xmux_note "$label target backup planned by dry run: $target_path"
    else
      backed_up_count=$((backed_up_count + 1))
      xmux_note "$label target backed up: $target_path"
    fi
  else
    xmux_note "$label target backup skipped: target absent."
  fi
  if [[ ! -e "$source_path" ]]; then
    skipped_count=$((skipped_count + 1))
    xmux_note "$label source absent; skipped."
    return 0
  fi
  xmux_run /bin/mkdir -p "$(dirname "$target_path")"
  xmux_run "$XMUX_DITTO_BIN" "$source_path" "$target_path"
  if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
    planned_copy_count=$((planned_copy_count + 1))
    xmux_note "$label copy planned by dry run."
  else
    copied_count=$((copied_count + 1))
    xmux_note "$label copied: $source_path -> $target_path"
  fi
}

copy_session_snapshot "Primary snapshot" "$official_primary" "$xmux_primary"
copy_session_snapshot "Previous snapshot" "$official_previous" "$xmux_previous"

xmux_note "Pre-migration backup: $backup_path"
if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_note "Session migration dry-run receipt: planned_copies=$planned_copy_count skipped=$skipped_count planned_backups=$planned_backup_count."
else
  xmux_note "Session migration receipt: copied=$copied_count skipped=$skipped_count targets_backed_up=$backed_up_count."
  if [[ "$copied_count" -eq 0 ]]; then
    xmux_note "No session snapshots were migrated."
  fi
fi
xmux_note "No source data was removed. No credential or Keychain material was copied."
