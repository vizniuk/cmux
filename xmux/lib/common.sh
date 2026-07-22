#!/usr/bin/env bash
set -euo pipefail

XMUX_REPO_ROOT="${XMUX_REPO_ROOT:-/Users/xaero/Projects/cmux}"
XMUX_OFFICIAL_APP="${XMUX_OFFICIAL_APP:-/Applications/cmux.app}"
XMUX_INSTALLED_APP="${XMUX_INSTALLED_APP:-/Applications/xmux.app}"
XMUX_BUILD_TAG="${XMUX_BUILD_TAG:-xmux-main}"
XMUX_APP_NAME="${XMUX_APP_NAME:-xmux}"
XMUX_BUNDLE_ID="${XMUX_BUNDLE_ID:-com.cmuxterm.app.debug.xmux-main}"
XMUX_OFFICIAL_BUNDLE_ID="${XMUX_OFFICIAL_BUNDLE_ID:-com.cmuxterm.app}"
XMUX_DERIVED_DATA="${XMUX_DERIVED_DATA:-/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main}"
XMUX_BUILT_APP="${XMUX_BUILT_APP:-/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main/Build/Products/Debug/xmux.app}"
XMUX_CLI_PATH="${XMUX_CLI_PATH:-/Users/xaero/.local/bin/xmux}"
XMUX_SOCKET_PATH="${XMUX_SOCKET_PATH:-/tmp/cmux-debug-xmux-main.sock}"
XMUX_DAEMON_SOCKET="${XMUX_DAEMON_SOCKET:-/Users/xaero/Library/Application Support/cmux/cmuxd-dev-xmux-main.sock}"
XMUX_SHARED_CMUX_SETTINGS="${XMUX_SHARED_CMUX_SETTINGS:-/Users/xaero/.config/cmux/cmux.json}"
XMUX_SHARED_GHOSTTY_SETTINGS="${XMUX_SHARED_GHOSTTY_SETTINGS:-/Users/xaero/.config/ghostty/config}"
XMUX_CMUX_CONFIG_DIR="${XMUX_CMUX_CONFIG_DIR:-/Users/xaero/.config/cmux}"
XMUX_GHOSTTY_CONFIG_DIR="${XMUX_GHOSTTY_CONFIG_DIR:-/Users/xaero/.config/ghostty}"
XMUX_APPLICATION_SUPPORT="${XMUX_APPLICATION_SUPPORT:-/Users/xaero/Library/Application Support/cmux}"
XMUX_BACKUP_ROOT="${XMUX_BACKUP_ROOT:-/Users/xaero/Desktop}"
XMUX_ZSHRC="${XMUX_ZSHRC:-/Users/xaero/.zshrc}"
XMUX_MINIMUM_BASELINE_SHA="${XMUX_MINIMUM_BASELINE_SHA:-303d4d842006ebedfe2a16d424c6082d1b708902}"
XMUX_EXPECTED_ORIGIN="${XMUX_EXPECTED_ORIGIN:-https://github.com/vizniuk/cmux.git}"
XMUX_OPERATIONS_DIR="${XMUX_OPERATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

XMUX_GIT_BIN="${XMUX_GIT_BIN:-git}"
XMUX_CODESIGN_BIN="${XMUX_CODESIGN_BIN:-/usr/bin/codesign}"
XMUX_PLUTIL_BIN="${XMUX_PLUTIL_BIN:-/usr/bin/plutil}"
XMUX_DEFAULTS_BIN="${XMUX_DEFAULTS_BIN:-/usr/bin/defaults}"
XMUX_DITTO_BIN="${XMUX_DITTO_BIN:-/usr/bin/ditto}"
XMUX_RSYNC_BIN="${XMUX_RSYNC_BIN:-/usr/bin/rsync}"
XMUX_XATTR_BIN="${XMUX_XATTR_BIN:-/usr/bin/xattr}"
XMUX_OPEN_BIN="${XMUX_OPEN_BIN:-/usr/bin/open}"
XMUX_OSASCRIPT_BIN="${XMUX_OSASCRIPT_BIN:-/usr/bin/osascript}"
XMUX_SUDO_BIN="${XMUX_SUDO_BIN:-/usr/bin/sudo}"
XMUX_SLEEP_BIN="${XMUX_SLEEP_BIN:-/bin/sleep}"

XMUX_DRY_RUN=0
XMUX_CREATED_BACKUP_PATH=""

xmux_die() {
  printf 'xmux: %s\n' "$*" >&2
  exit 1
}

xmux_note() {
  printf '%s\n' "$*"
}

xmux_parse_dry_run() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  if [[ "$#" -eq 1 && "$1" == "--dry-run" ]]; then
    XMUX_DRY_RUN=1
    return 0
  fi
  xmux_die "usage: $(basename "$0") [--dry-run]"
}

xmux_print_command() {
  local argument
  printf 'DRY RUN:'
  for argument in "$@"; do
    printf ' %q' "$argument"
  done
  printf '\n'
}

xmux_run() {
  if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
    xmux_print_command "$@"
    return 0
  fi
  "$@"
}

xmux_run_as_admin() {
  if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
    xmux_print_command "$XMUX_SUDO_BIN" "$@"
    return 0
  fi
  "$XMUX_SUDO_BIN" "$@"
}

xmux_timestamp() {
  if [[ -n "${XMUX_TIMESTAMP:-}" ]]; then
    printf '%s\n' "$XMUX_TIMESTAMP"
  else
    date '+%Y%m%d-%H%M%S'
  fi
}

xmux_require_repo() {
  [[ -d "$XMUX_REPO_ROOT" ]] || xmux_die "repository directory not found: $XMUX_REPO_ROOT"
  local resolved_root
  resolved_root="$(cd "$XMUX_REPO_ROOT" && pwd -P)"
  local git_root
  git_root="$("$XMUX_GIT_BIN" -C "$resolved_root" rev-parse --show-toplevel 2>/dev/null)" \
    || xmux_die "not a Git repository: $resolved_root"
  [[ "$git_root" == "$resolved_root" ]] \
    || xmux_die "repository root mismatch: expected $resolved_root, Git reports $git_root"
  XMUX_REPO_ROOT="$resolved_root"
}

xmux_require_not_official_target() {
  local target="$1"
  [[ "$target" != "$XMUX_OFFICIAL_APP" ]] \
    || xmux_die "refusing to target official cmux: $target"
}

xmux_plist_read() {
  local app_path="$1"
  local key="$2"
  "$XMUX_PLUTIL_BIN" -extract "$key" raw -o - "$app_path/Contents/Info.plist" 2>/dev/null
}

xmux_verify_signature() {
  local app_path="$1"
  "$XMUX_CODESIGN_BIN" --verify --deep --strict "$app_path" >/dev/null 2>&1
}

xmux_verify_app_identity() {
  local app_path="$1"
  [[ -d "$app_path" ]] || xmux_die "application not found: $app_path"
  [[ -f "$app_path/Contents/Info.plist" ]] || xmux_die "Info.plist not found: $app_path"
  local bundle_id
  local display_name
  bundle_id="$(xmux_plist_read "$app_path" CFBundleIdentifier)" \
    || xmux_die "cannot read bundle identifier: $app_path"
  display_name="$(xmux_plist_read "$app_path" CFBundleDisplayName)" \
    || xmux_die "cannot read display name: $app_path"
  [[ "$bundle_id" == "$XMUX_BUNDLE_ID" ]] \
    || xmux_die "unexpected bundle identifier in $app_path: $bundle_id"
  [[ "$display_name" == "$XMUX_APP_NAME" ]] \
    || xmux_die "unexpected display name in $app_path: $display_name"
  xmux_verify_signature "$app_path" \
    || xmux_die "code signature verification failed: $app_path"
}

xmux_verify_installed_resource_paths() {
  local app_path="$1"
  local cli_path
  local integration_path
  cli_path="$(xmux_plist_read "$app_path" LSEnvironment.CMUX_BUNDLED_CLI_PATH)" \
    || xmux_die "installed CLI resource path is missing: $app_path"
  integration_path="$(xmux_plist_read "$app_path" LSEnvironment.CMUX_SHELL_INTEGRATION_DIR)" \
    || xmux_die "installed shell integration path is missing: $app_path"
  [[ "$cli_path" == "$XMUX_INSTALLED_APP/Contents/Resources/bin/cmux" ]] \
    || xmux_die "installed CLI resource path is incorrect: $cli_path"
  [[ "$integration_path" == "$XMUX_INSTALLED_APP/Contents/Resources/shell-integration" ]] \
    || xmux_die "installed shell integration path is incorrect: $integration_path"
}

xmux_bundle_pids() {
  local bundle_id="$1"
  "$XMUX_OSASCRIPT_BIN" \
    -e 'tell application "System Events"' \
    -e "set matchingProcesses to every application process whose bundle identifier is \"${bundle_id}\"" \
    -e 'set processIds to {}' \
    -e 'repeat with matchingProcess in matchingProcesses' \
    -e 'set end of processIds to unix id of matchingProcess' \
    -e 'end repeat' \
    -e 'return processIds' \
    -e 'end tell' 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

xmux_require_bundle_stopped() {
  local bundle_id="$1"
  local label="$2"
  local pids
  pids="$(xmux_bundle_pids "$bundle_id" || true)"
  [[ -z "$pids" ]] || xmux_die "$label must be fully stopped (bundle $bundle_id, pid ${pids//$'\n'/,})"
}

xmux_require_both_apps_stopped() {
  xmux_require_bundle_stopped "$XMUX_OFFICIAL_BUNDLE_ID" "official cmux"
  xmux_require_bundle_stopped "$XMUX_BUNDLE_ID" "xmux"
}

xmux_stop_xmux() {
  local pids
  pids="$(xmux_bundle_pids "$XMUX_BUNDLE_ID" || true)"
  [[ -n "$pids" ]] || return 0
  xmux_note "Stopping xmux only (bundle $XMUX_BUNDLE_ID)."
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    xmux_run /bin/kill -TERM "$pid"
  done <<< "$pids"
  if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local attempt=0
  while [[ "$attempt" -lt 20 ]]; do
    [[ -z "$(xmux_bundle_pids "$XMUX_BUNDLE_ID" || true)" ]] && return 0
    "$XMUX_SLEEP_BIN" 0.25
    attempt=$((attempt + 1))
  done
  xmux_die "xmux did not stop within five seconds"
}

xmux_safe_bundle_component() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

xmux_session_primary_path() {
  printf '%s/session-%s.json\n' "$XMUX_APPLICATION_SUPPORT" "$(xmux_safe_bundle_component "$1")"
}

xmux_session_previous_path() {
  printf '%s/session-%s-previous.json\n' "$XMUX_APPLICATION_SUPPORT" "$(xmux_safe_bundle_component "$1")"
}

xmux_notification_history_path() {
  printf '%s/notification-feed-history-%s.json\n' "$XMUX_APPLICATION_SUPPORT" "$(xmux_safe_bundle_component "$1")"
}

xmux_copy_file_if_present() {
  local source_path="$1"
  local target_path="$2"
  xmux_note "Source: $source_path"
  xmux_note "Target: $target_path"
  if [[ ! -e "$source_path" ]]; then
    xmux_note "Source absent; nothing copied."
    return 0
  fi
  xmux_run /bin/mkdir -p "$(dirname "$target_path")"
  xmux_run "$XMUX_DITTO_BIN" "$source_path" "$target_path"
}

xmux_create_backup_directory() {
  local prefix="$1"
  local backup_path="$XMUX_BACKUP_ROOT/${prefix}-$(xmux_timestamp)"
  [[ ! -e "$backup_path" ]] || xmux_die "refusing to overwrite backup: $backup_path"
  xmux_run /bin/mkdir -p "$backup_path"
  XMUX_CREATED_BACKUP_PATH="$backup_path"
}

xmux_backup_migration_target() {
  local backup_path="$1"
  local target_path="$2"
  if [[ -e "$target_path" ]]; then
    xmux_run "$XMUX_DITTO_BIN" "$target_path" "$backup_path/$(basename "$target_path")"
  fi
}

xmux_read_installed_identity() {
  if [[ ! -d "$XMUX_INSTALLED_APP" ]]; then
    printf 'not installed\n'
    return 0
  fi
  local bundle_id
  local display_name
  bundle_id="$(xmux_plist_read "$XMUX_INSTALLED_APP" CFBundleIdentifier 2>/dev/null || printf 'unreadable')"
  display_name="$(xmux_plist_read "$XMUX_INSTALLED_APP" CFBundleDisplayName 2>/dev/null || printf 'unreadable')"
  printf '%s (%s)\n' "$display_name" "$bundle_id"
}
