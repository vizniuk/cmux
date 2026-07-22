#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_note "OPTIONAL migration: export official macOS defaults and import them into the xmux bundle domain."
xmux_note "Shared cmux.json is not copied because both applications already share it."
xmux_require_both_apps_stopped

xmux_note "Source defaults domain: $XMUX_OFFICIAL_BUNDLE_ID"
xmux_note "Target defaults domain: $XMUX_BUNDLE_ID"

source_domain_state="$(xmux_defaults_domain_state "$XMUX_OFFICIAL_BUNDLE_ID")" || {
  xmux_note "Source domain: failed."
  xmux_note "Target domain: not checked."
  xmux_note "Import: skipped."
  xmux_die "cannot establish source defaults domain state: $XMUX_OFFICIAL_BUNDLE_ID"
}

target_domain_state="$(xmux_defaults_domain_state "$XMUX_BUNDLE_ID")" || {
  xmux_note "Source domain: $source_domain_state; export not started."
  xmux_note "Target domain: failed."
  xmux_note "Import: skipped."
  xmux_die "cannot establish target defaults domain state: $XMUX_BUNDLE_ID"
}

if [[ "$source_domain_state" == "absent" ]]; then
  xmux_note "Source domain: absent."
  if [[ "$target_domain_state" == "absent" ]]; then
    xmux_note "Target domain: absent; no target backup was required."
  else
    xmux_note "Target domain: present; no target backup was required because import was skipped."
  fi
  xmux_note "Import: skipped."
  xmux_note "Official defaults are absent; nothing imported."
  exit 0
fi

xmux_create_backup_directory cmux-pre-defaults-migration
backup_path="$XMUX_CREATED_BACKUP_PATH"
official_export="$backup_path/$XMUX_OFFICIAL_BUNDLE_ID.plist"
xmux_export="$backup_path/$XMUX_BUNDLE_ID-before.plist"

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_note "Source domain: present; export planned."
  xmux_note "Planned source export path: $official_export"
  xmux_print_command "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$official_export"
  if [[ "$target_domain_state" == "present" ]]; then
    xmux_note "Target domain: present; backup planned."
    xmux_note "Planned target backup path: $xmux_export"
    xmux_print_command "$XMUX_DEFAULTS_BIN" export "$XMUX_BUNDLE_ID" "$xmux_export"
  else
    xmux_note "Target domain: absent; no target backup was required."
  fi
  xmux_print_command "$XMUX_DEFAULTS_BIN" import "$XMUX_BUNDLE_ID" "$official_export"
  xmux_note "Import: planned."
  xmux_note "Planned migration backup directory: $backup_path"
  xmux_note "Dry run only; no defaults were exported, imported, or backed up."
  exit 0
fi

temporary_official_export="$official_export.exporting.$$"
if ! "$XMUX_DEFAULTS_BIN" export "$XMUX_OFFICIAL_BUNDLE_ID" "$temporary_official_export" >/dev/null 2>&1; then
  "$XMUX_RM_BIN" -f "$temporary_official_export"
  xmux_note "Source domain: failed."
  xmux_note "Target domain: $target_domain_state; backup not started."
  xmux_note "Import: skipped."
  xmux_note "Migration backup directory: $backup_path"
  xmux_die "source defaults export failed: $XMUX_OFFICIAL_BUNDLE_ID"
fi
if [[ ! -s "$temporary_official_export" ]]; then
  "$XMUX_RM_BIN" -f "$temporary_official_export"
  xmux_note "Source domain: failed."
  xmux_note "Target domain: $target_domain_state; backup not started."
  xmux_note "Import: skipped."
  xmux_note "Migration backup directory: $backup_path"
  xmux_die "source defaults export did not create a nonempty plist: $XMUX_OFFICIAL_BUNDLE_ID"
fi
if ! /bin/mv "$temporary_official_export" "$official_export"; then
  "$XMUX_RM_BIN" -f "$temporary_official_export"
  xmux_note "Source domain: failed."
  xmux_note "Target domain: $target_domain_state; backup not started."
  xmux_note "Import: skipped."
  xmux_note "Migration backup directory: $backup_path"
  xmux_die "source defaults export could not be published: $official_export"
fi

target_receipt="Target domain: absent; no target backup was required."
if [[ "$target_domain_state" == "present" ]]; then
  temporary_xmux_export="$xmux_export.exporting.$$"
  if ! "$XMUX_DEFAULTS_BIN" export "$XMUX_BUNDLE_ID" "$temporary_xmux_export" >/dev/null 2>&1; then
    "$XMUX_RM_BIN" -f "$temporary_xmux_export"
    xmux_note "Source domain: exported."
    xmux_note "Source export path: $official_export"
    xmux_note "Target domain: failed."
    xmux_note "Import: skipped."
    xmux_note "Migration backup directory: $backup_path"
    xmux_die "target defaults recovery export failed: $XMUX_BUNDLE_ID"
  fi
  if [[ ! -s "$temporary_xmux_export" ]]; then
    "$XMUX_RM_BIN" -f "$temporary_xmux_export"
    xmux_note "Source domain: exported."
    xmux_note "Source export path: $official_export"
    xmux_note "Target domain: failed."
    xmux_note "Import: skipped."
    xmux_note "Migration backup directory: $backup_path"
    xmux_die "target defaults recovery export did not create a nonempty plist: $XMUX_BUNDLE_ID"
  fi
  if ! /bin/mv "$temporary_xmux_export" "$xmux_export"; then
    "$XMUX_RM_BIN" -f "$temporary_xmux_export"
    xmux_note "Source domain: exported."
    xmux_note "Source export path: $official_export"
    xmux_note "Target domain: failed."
    xmux_note "Import: skipped."
    xmux_note "Migration backup directory: $backup_path"
    xmux_die "target defaults recovery export could not be published: $xmux_export"
  fi
  target_receipt="Target domain: backed up."
fi

if ! "$XMUX_DEFAULTS_BIN" import "$XMUX_BUNDLE_ID" "$official_export" >/dev/null 2>&1; then
  xmux_note "Source domain: exported."
  xmux_note "Source export path: $official_export"
  xmux_note "$target_receipt"
  if [[ "$target_domain_state" == "present" ]]; then
    xmux_note "Target backup path: $xmux_export"
  fi
  xmux_note "Import: failed."
  xmux_note "Migration backup directory: $backup_path"
  if [[ "$target_domain_state" == "present" ]]; then
    xmux_die "defaults import failed; recover xmux preferences from: $xmux_export"
  fi
  xmux_die "defaults import failed; target domain was absent before import"
fi

xmux_note "Source domain: exported."
xmux_note "Source export path: $official_export"
xmux_note "$target_receipt"
if [[ "$target_domain_state" == "present" ]]; then
  xmux_note "Target backup path: $xmux_export"
fi
xmux_note "Import: succeeded."
xmux_note "Migration backup directory: $backup_path"
xmux_note "No shared settings, credential, or Keychain material was copied."
