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
XMUX_SOCKET_ROOT="${XMUX_SOCKET_ROOT:-/tmp}"
XMUX_MINIMUM_BASELINE_SHA="${XMUX_MINIMUM_BASELINE_SHA:-303d4d842006ebedfe2a16d424c6082d1b708902}"
XMUX_EXPECTED_ORIGIN="${XMUX_EXPECTED_ORIGIN:-https://github.com/vizniuk/cmux.git}"
XMUX_OPERATIONS_DIR="${XMUX_OPERATIONS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
XMUX_FALLBACK_EXECUTABLE_NAME="${XMUX_FALLBACK_EXECUTABLE_NAME:-cmux DEV}"
XMUX_SYSTEM_OFFICIAL_APP="/Applications/cmux.app"
readonly XMUX_SYSTEM_OFFICIAL_APP

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
XMUX_PERL_BIN="${XMUX_PERL_BIN:-/usr/bin/perl}"
XMUX_STAT_BIN="${XMUX_STAT_BIN:-/usr/bin/stat}"
XMUX_LSOF_BIN="${XMUX_LSOF_BIN:-/usr/sbin/lsof}"
XMUX_PS_BIN="${XMUX_PS_BIN:-/bin/ps}"
XMUX_KILL_BIN="${XMUX_KILL_BIN:-/bin/kill}"
XMUX_RM_BIN="${XMUX_RM_BIN:-/bin/rm}"

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

xmux_canonical_path() {
  local input_path="$1"
  [[ -n "$input_path" ]] || return 1
  "$XMUX_PERL_BIN" -MCwd=abs_path,getcwd -MFile::Basename=dirname -MFile::Spec -e '
    use strict;
    use warnings;
    my $input = shift @ARGV;
    die "empty path\n" unless defined($input) && length($input);
    my $absolute = File::Spec->file_name_is_absolute($input)
      ? $input
      : File::Spec->catfile(getcwd(), $input);
    my $resolved = "/";
    for my $component (split m{/+}, $absolute) {
      next if $component eq "" || $component eq ".";
      if ($component eq "..") {
        $resolved = dirname($resolved) unless $resolved eq "/";
        next;
      }
      my $candidate = $resolved eq "/" ? "/$component" : "$resolved/$component";
      if (-e $candidate || -l $candidate) {
        my $real = abs_path($candidate);
        die "cannot resolve $candidate\n" unless defined($real);
        $resolved = $real;
      } else {
        $resolved = $candidate;
      }
    }
    print "$resolved\n";
  ' "$input_path" 2>/dev/null
}

xmux_path_identity() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  "$XMUX_STAT_BIN" -f '%d:%i' "$path" 2>/dev/null
}

xmux_paths_refer_to_same_object() {
  local first="$1"
  local second="$2"
  local first_canonical
  local second_canonical
  first_canonical="$(xmux_canonical_path "$first")" || return 2
  second_canonical="$(xmux_canonical_path "$second")" || return 2
  [[ "$first_canonical" == "$second_canonical" ]] && return 0
  if [[ -e "$first" && -e "$second" ]]; then
    local first_identity
    local second_identity
    first_identity="$(xmux_path_identity "$first")" || return 2
    second_identity="$(xmux_path_identity "$second")" || return 2
    [[ "$first_identity" == "$second_identity" ]] && return 0
  fi
  return 1
}

xmux_paths_overlap() {
  local first="$1"
  local second="$2"
  [[ "$first" == "$second" ]] && return 0
  [[ "$first" == "/" || "$second" == "/" ]] && return 0
  [[ "$first" == "$second/"* || "$second" == "$first/"* ]]
}

## Fails closed unless a target is provably separate from every official cmux path.
xmux_require_safe_destructive_target() {
  local target="$1"
  local target_canonical
  target_canonical="$(xmux_canonical_path "$target")" \
    || xmux_die "cannot canonicalize destructive target: $target"
  [[ -n "$target_canonical" ]] || xmux_die "canonical destructive target is empty: $target"

  local protected_path
  for protected_path in "$XMUX_SYSTEM_OFFICIAL_APP" "$XMUX_OFFICIAL_APP"; do
    local protected_canonical
    protected_canonical="$(xmux_canonical_path "$protected_path")" \
      || xmux_die "cannot canonicalize protected official cmux path: $protected_path"
    [[ -n "$protected_canonical" ]] \
      || xmux_die "canonical protected official cmux path is empty: $protected_path"
    if xmux_paths_overlap "$target_canonical" "$protected_canonical"; then
      xmux_die "refusing destructive target overlapping official cmux: $target -> $target_canonical"
    fi
    local same_object_status=0
    xmux_paths_refer_to_same_object "$target" "$protected_path" || same_object_status=$?
    case "$same_object_status" in
      0) xmux_die "refusing destructive target sharing official cmux identity: $target" ;;
      1) ;;
      *) xmux_die "cannot establish destructive target identity: $target" ;;
    esac
  done
}

xmux_require_safe_socket_target() {
  local target="$1"
  xmux_require_safe_destructive_target "$target"
  [[ ! -L "$target" ]] || xmux_die "refusing symlinked xmux socket path: $target"

  local target_canonical
  local root_canonical
  target_canonical="$(xmux_canonical_path "$target")" \
    || xmux_die "cannot canonicalize xmux socket path: $target"
  root_canonical="$(xmux_canonical_path "$XMUX_SOCKET_ROOT")" \
    || xmux_die "cannot canonicalize xmux socket root: $XMUX_SOCKET_ROOT"
  [[ -n "$target_canonical" && -n "$root_canonical" ]] \
    || xmux_die "canonical xmux socket path or root is empty"
  [[ "$(dirname "$target_canonical")" == "$root_canonical" ]] \
    || xmux_die "xmux socket must be a direct child of $root_canonical: $target_canonical"
  [[ "$(basename "$target_canonical")" == "cmux-debug-${XMUX_BUILD_TAG}.sock" ]] \
    || xmux_die "unexpected xmux socket filename: $target_canonical"
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

xmux_expected_executable_path() {
  local executable_name="$XMUX_FALLBACK_EXECUTABLE_NAME"
  if [[ -f "$XMUX_INSTALLED_APP/Contents/Info.plist" ]]; then
    local plist_executable
    plist_executable="$(xmux_plist_read "$XMUX_INSTALLED_APP" CFBundleExecutable 2>/dev/null || true)"
    [[ -z "$plist_executable" ]] || executable_name="$plist_executable"
  fi
  printf '%s/Contents/MacOS/%s\n' "$XMUX_INSTALLED_APP" "$executable_name"
}

xmux_pid_executable_path() {
  local pid="$1"
  local lsof_output
  lsof_output="$("$XMUX_LSOF_BIN" -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
  printf '%s\n' "$lsof_output" | sed -n 's/^n//p' | sed -n '1p'
}

xmux_pid_matches_expected_executable() {
  local pid="$1"
  local actual_path
  actual_path="$(xmux_pid_executable_path "$pid")" || return 1
  [[ -n "$actual_path" ]] || return 1
  local expected_path
  expected_path="$(xmux_expected_executable_path)" || return 2
  local comparison_status=0
  xmux_paths_refer_to_same_object "$actual_path" "$expected_path" || comparison_status=$?
  [[ "$comparison_status" -eq 0 ]]
}

xmux_exact_app_pids() {
  local bundle_pids
  bundle_pids="$(xmux_bundle_pids "$XMUX_BUNDLE_ID")" || return 2
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    if xmux_pid_matches_expected_executable "$pid"; then
      printf '%s\n' "$pid"
      continue
    fi
    if "$XMUX_PS_BIN" -p "$pid" >/dev/null 2>&1; then
      local observed_path
      observed_path="$(xmux_pid_executable_path "$pid" 2>/dev/null || true)"
      [[ -n "$observed_path" ]] || return 2
    fi
  done <<< "$bundle_pids"
}

xmux_require_exact_process_query() {
  local exact_pids
  exact_pids="$(xmux_exact_app_pids)" \
    || xmux_die "cannot establish exact xmux process identity"
  printf '%s\n' "$exact_pids"
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
  pids="$(xmux_require_exact_process_query)"
  [[ -n "$pids" ]] || {
    xmux_note "Exact xmux process is not running."
    return 0
  }
  local quit_timeout="${XMUX_QUIT_TIMEOUT_SECONDS:-5}"
  case "$quit_timeout" in
    ''|*[!0-9]*) xmux_die "XMUX_QUIT_TIMEOUT_SECONDS must be a positive integer" ;;
  esac
  [[ "$quit_timeout" -gt 0 ]] || xmux_die "XMUX_QUIT_TIMEOUT_SECONDS must be a positive integer"
  if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
    xmux_note "DRY RUN: exact xmux process check found pid(s): ${pids//$'\n'/,}"
    xmux_note "DRY RUN: would request exact xmux to quit and require exit before removal."
    return 0
  fi

  xmux_note "Requesting exact xmux process to quit (bundle $XMUX_BUNDLE_ID)."
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    xmux_pid_matches_expected_executable "$pid" \
      || xmux_die "xmux process identity changed before quit request: $pid"
    "$XMUX_KILL_BIN" -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
  local attempt=0
  while [[ "$attempt" -lt "$quit_timeout" ]]; do
    local remaining
    remaining="$(xmux_require_exact_process_query)"
    if [[ -z "$remaining" ]]; then
      xmux_note "Exact xmux process exited."
      return 0
    fi
    "$XMUX_SLEEP_BIN" 1
    attempt=$((attempt + 1))
  done
  local remaining
  remaining="$(xmux_require_exact_process_query)"
  [[ -z "$remaining" ]] || xmux_die "xmux remained active after ${quit_timeout}s; nothing was removed"
}

xmux_socket_owner_pids() {
  local socket_path="$1"
  "$XMUX_LSOF_BIN" -t -- "$socket_path" 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u
}

xmux_socket_state() {
  local socket_path="$1"
  if [[ -L "$socket_path" ]]; then
    printf 'unsafe-symlink\n'
    return 0
  fi
  if [[ ! -e "$socket_path" ]]; then
    printf 'absent\n'
    return 0
  fi
  if [[ ! -S "$socket_path" ]]; then
    printf 'non-socket\n'
    return 0
  fi
  local owners
  owners="$(xmux_socket_owner_pids "$socket_path" || true)"
  if [[ -z "$owners" ]]; then
    printf 'stale\n'
    return 0
  fi
  local exact_pids
  exact_pids="$(xmux_exact_app_pids)" || return 2
  [[ -n "$exact_pids" ]] || {
    printf 'foreign\n'
    return 0
  }
  local owner
  while IFS= read -r owner; do
    [[ -n "$owner" ]] || continue
    if ! printf '%s\n' "$exact_pids" | /usr/bin/grep -Fqx -- "$owner"; then
      printf 'foreign\n'
      return 0
    fi
  done <<< "$owners"
  printf 'exact\n'
}

xmux_ping_socket() {
  local ping_timeout="${XMUX_PING_TIMEOUT_SECONDS:-2}"
  case "$ping_timeout" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [[ "$ping_timeout" -gt 0 ]] || return 1
  local response
  response="$("$XMUX_PERL_BIN" -e '
    my $seconds = shift @ARGV;
    $SIG{ALRM} = sub { exit 124 };
    alarm $seconds;
    exec @ARGV;
    exit 127;
  ' "$ping_timeout" "$XMUX_CLI_PATH" ping 2>/dev/null)" || return 1
  [[ "$response" == "PONG" ]]
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
