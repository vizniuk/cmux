#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
XMUX_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xmux-script-tests.XXXXXX")"
PASS_COUNT=0

cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

assert_file_exists() {
  [[ -e "$1" ]] || fail "expected path: $1"
}

assert_file_absent() {
  [[ ! -e "$1" ]] || fail "unexpected path: $1"
}

assert_contains() {
  /usr/bin/grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_equals() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

make_app() {
  local app_path="$1"
  local bundle_id="$2"
  local display_name="$3"
  /bin/mkdir -p "$app_path/Contents/Resources/bin" "$app_path/Contents/Resources/shell-integration"
  /usr/bin/plutil -create xml1 "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$display_name" "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment.CMUX_BUNDLED_CLI_PATH -string "/build/cmux" "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string "/build/shell-integration" "$app_path/Contents/Info.plist"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$app_path/Contents/Resources/bin/cmux"
  /bin/chmod 0755 "$app_path/Contents/Resources/bin/cmux"
}

make_stub() {
  local path="$1"
  shift
  /bin/mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '%s\n' "$@"
  } > "$path"
  /bin/chmod 0755 "$path"
}

shell_count=0
while IFS= read -r shell_file; do
  /bin/bash -n "$shell_file" || fail "bash -n failed: $shell_file"
  shell_count=$((shell_count + 1))
done < <(find "$XMUX_DIR" -type f -name '*.sh' -print | sort)
[[ "$shell_count" -ge 13 ]] || fail "unexpected shell inventory count: $shell_count"
pass "every xmux shell file passes bash -n ($shell_count files)"

optional_names="$(find "$XMUX_DIR" -maxdepth 1 -type f -name '*OPTIONAL*.sh' -exec basename {} \; | sort)"
expected_optional_names="$(printf '%s\n' \
  '07_OPTIONAL_copy_existing_session.sh' \
  '08_OPTIONAL_copy_notification_history.sh' \
  '09_OPTIONAL_copy_macos_preferences.sh' \
  '11_OPTIONAL_uninstall_xmux.sh')"
assert_equals "$optional_names" "$expected_optional_names"
pass "optional script filenames contain _OPTIONAL_ exactly"

default_values="$({
  while IFS='=' read -r variable_name _; do
    if [[ "$variable_name" == XMUX_* ]]; then
      unset "$variable_name"
    fi
  done < <(env)
  # shellcheck source=xmux/lib/common.sh
  source "$XMUX_DIR/lib/common.sh"
  printf '%s\n' \
    "$XMUX_REPO_ROOT" "$XMUX_OFFICIAL_APP" "$XMUX_INSTALLED_APP" "$XMUX_BUILD_TAG" \
    "$XMUX_APP_NAME" "$XMUX_BUNDLE_ID" "$XMUX_DERIVED_DATA" "$XMUX_BUILT_APP" \
    "$XMUX_CLI_PATH" "$XMUX_SOCKET_PATH" "$XMUX_DAEMON_SOCKET" \
    "$XMUX_SHARED_CMUX_SETTINGS" "$XMUX_SHARED_GHOSTTY_SETTINGS" \
    "$XMUX_APPLICATION_SUPPORT" "$XMUX_BACKUP_ROOT"
})"
expected_defaults="$(printf '%s\n' \
  '/Users/xaero/Projects/cmux' \
  '/Applications/cmux.app' \
  '/Applications/xmux.app' \
  'xmux-main' \
  'xmux' \
  'com.cmuxterm.app.debug.xmux-main' \
  '/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main' \
  '/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main/Build/Products/Debug/xmux.app' \
  '/Users/xaero/.local/bin/xmux' \
  '/tmp/cmux-debug-xmux-main.sock' \
  '/Users/xaero/Library/Application Support/cmux/cmuxd-dev-xmux-main.sock' \
  '/Users/xaero/.config/cmux/cmux.json' \
  '/Users/xaero/.config/ghostty/config' \
  '/Users/xaero/Library/Application Support/cmux' \
  '/Users/xaero/Desktop')"
assert_equals "$default_values" "$expected_defaults"
pass "default constants exactly match Xaero paths and identity"

FIXTURE_REPO="$TEST_ROOT/repository with spaces"
/bin/mkdir -p "$FIXTURE_REPO/scripts"
"$(command -v git)" -C "$FIXTURE_REPO" init -q
"$(command -v git)" -C "$FIXTURE_REPO" config user.name 'xmux tests'
"$(command -v git)" -C "$FIXTURE_REPO" config user.email 'xmux-tests@example.invalid'
"$(command -v git)" -C "$FIXTURE_REPO" remote add origin 'https://github.com/vizniuk/cmux.git'
printf '%s\n' 'baseline' > "$FIXTURE_REPO/tracked.txt"
make_stub "$FIXTURE_REPO/scripts/reload.sh" \
  ': "${XMUX_TEST_RELOAD_LOG:?}"' \
  ': "${XMUX_BUILT_APP:?}"' \
  'printf "CMUX_SKIP_ZIG_BUILD=%s\n" "${CMUX_SKIP_ZIG_BUILD:-}" > "$XMUX_TEST_RELOAD_LOG"' \
  'for argument in "$@"; do printf "ARG=%s\n" "$argument" >> "$XMUX_TEST_RELOAD_LOG"; done' \
  'mkdir -p "$XMUX_BUILT_APP/Contents/Resources/bin" "$XMUX_BUILT_APP/Contents/Resources/shell-integration"' \
  'plutil -create xml1 "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'plutil -insert CFBundleIdentifier -string "${XMUX_BUNDLE_ID:?}" "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'plutil -insert CFBundleDisplayName -string "${XMUX_APP_NAME:?}" "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'plutil -insert LSEnvironment -xml "<dict/>" "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'plutil -insert LSEnvironment.CMUX_BUNDLED_CLI_PATH -string /build/cmux "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'plutil -insert LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string /build/shell "$XMUX_BUILT_APP/Contents/Info.plist"' \
  'printf "#!/usr/bin/env bash\nexit 0\n" > "$XMUX_BUILT_APP/Contents/Resources/bin/cmux"' \
  'chmod 0755 "$XMUX_BUILT_APP/Contents/Resources/bin/cmux"'
"$(command -v git)" -C "$FIXTURE_REPO" add tracked.txt scripts/reload.sh
"$(command -v git)" -C "$FIXTURE_REPO" commit -qm 'baseline'
BASELINE_SHA="$("$(command -v git)" -C "$FIXTURE_REPO" rev-parse HEAD)"
printf '%s\n' 'descendant' >> "$FIXTURE_REPO/tracked.txt"
"$(command -v git)" -C "$FIXTURE_REPO" add tracked.txt
"$(command -v git)" -C "$FIXTURE_REPO" commit -qm 'descendant'
DESCENDANT_SHA="$("$(command -v git)" -C "$FIXTURE_REPO" rev-parse HEAD)"

(
  XMUX_REPO_ROOT="$FIXTURE_REPO"
  # shellcheck source=xmux/lib/common.sh
  source "$XMUX_DIR/lib/common.sh"
  xmux_require_repo
  expected_repo_root="$(cd "$FIXTURE_REPO" && pwd -P)"
  [[ "$XMUX_REPO_ROOT" == "$expected_repo_root" ]]
) || fail "common library did not resolve repository path with spaces"
pass "common library resolves an overridden repository path safely"

VERIFY_ENV=(
  XMUX_REPO_ROOT="$FIXTURE_REPO"
  XMUX_MINIMUM_BASELINE_SHA="$BASELINE_SHA"
  XMUX_EXPECTED_ORIGIN='https://github.com/vizniuk/cmux.git'
)
env "${VERIFY_ENV[@]}" "$XMUX_DIR/02_verify_source.sh" > "$TEST_ROOT/verify-clean.log"
assert_contains "$TEST_ROOT/verify-clean.log" "Source HEAD: $DESCENDANT_SHA"
pass "verify accepts a descendant of the minimum baseline"

printf '%s\n' 'dirty' >> "$FIXTURE_REPO/tracked.txt"
if env "${VERIFY_ENV[@]}" "$XMUX_DIR/02_verify_source.sh" > /dev/null 2>&1; then
  fail "verify accepted dirty tracked state"
fi
"$(command -v git)" -C "$FIXTURE_REPO" restore tracked.txt
pass "verify rejects dirty tracked state"

/bin/mkdir -p "$FIXTURE_REPO/.idea"
printf '%s\n' 'allowed' > "$FIXTURE_REPO/.idea/test.xml"
printf '%s\n' 'allowed' > "$FIXTURE_REPO/cmux.iml"
env "${VERIFY_ENV[@]}" "$XMUX_DIR/02_verify_source.sh" > /dev/null
printf '%s\n' 'blocked' > "$FIXTURE_REPO/not-allowed.txt"
if env "${VERIFY_ENV[@]}" "$XMUX_DIR/02_verify_source.sh" > /dev/null 2>&1; then
  fail "verify accepted unauthorized untracked state"
fi
/bin/rm -f "$FIXTURE_REPO/not-allowed.txt"
pass "verify permits only .idea and cmux.iml as untracked content"

STUB_DIR="$TEST_ROOT/stubs"
make_stub "$STUB_DIR/codesign-ok" 'exit 0'
BUILT_APP="$TEST_ROOT/build products/xmux.app"
RELOAD_LOG="$TEST_ROOT/reload-arguments.log"
env "${VERIFY_ENV[@]}" \
  XMUX_BUILT_APP="$BUILT_APP" \
  XMUX_BUNDLE_ID='com.cmuxterm.app.debug.xmux-main' \
  XMUX_APP_NAME='xmux' \
  XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" \
  XMUX_TEST_RELOAD_LOG="$RELOAD_LOG" \
  "$XMUX_DIR/03_build_xmux.sh" > "$TEST_ROOT/build.log"
expected_reload="$(printf '%s\n' \
  'CMUX_SKIP_ZIG_BUILD=1' \
  'ARG=--tag' 'ARG=xmux-main' \
  'ARG=--name' 'ARG=xmux' \
  'ARG=--prod-auth' \
  'ARG=--no-global-cli-links')"
assert_equals "$(<"$RELOAD_LOG")" "$expected_reload"
pass "build uses the exact supported reload argument vector"

BACKUP_ROOT="$TEST_ROOT/backups"
CONFIG_ROOT="$TEST_ROOT/source config"
APP_SUPPORT="$TEST_ROOT/source support/cmux"
/bin/mkdir -p "$CONFIG_ROOT/cmux" "$CONFIG_ROOT/ghostty" "$APP_SUPPORT/state"
printf '%s\n' 'cmux config' > "$CONFIG_ROOT/cmux/cmux.json"
printf '%s\n' 'ghostty config' > "$CONFIG_ROOT/ghostty/config"
printf '%s\n' 'session fixture' > "$APP_SUPPORT/state/session.json"
printf '%s\n' 'must not copy' > "$APP_SUPPORT/state/credentials.json"
make_stub "$STUB_DIR/defaults" \
  'if [[ "${1:-}" == export ]]; then mkdir -p "$(dirname "$3")"; printf "plist\n" > "$3"; fi' \
  'exit 0'
env XMUX_BACKUP_ROOT="$BACKUP_ROOT" \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" \
  XMUX_GHOSTTY_CONFIG_DIR="$CONFIG_ROOT/ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" \
  XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  XMUX_TIMESTAMP='20260722-120000' \
  "$XMUX_DIR/01_backup_existing_cmux.sh" > "$TEST_ROOT/backup.log"
BACKUP_PATH="$BACKUP_ROOT/cmux-backup-20260722-120000"
assert_file_exists "$BACKUP_PATH/config/cmux/cmux.json"
assert_file_exists "$BACKUP_PATH/config/ghostty/config"
assert_file_exists "$BACKUP_PATH/Application Support/cmux/state/session.json"
assert_file_absent "$BACKUP_PATH/Application Support/cmux/state/credentials.json"
assert_file_exists "$BACKUP_PATH/com.cmuxterm.app.plist"
pass "backup creates the expected tree without credentials"

make_stub "$STUB_DIR/sudo" \
  'if [[ -n "${XMUX_TEST_SUDO_LOG:-}" ]]; then printf "%s\n" "$*" >> "$XMUX_TEST_SUDO_LOG"; fi' \
  'exec "$@"'
make_stub "$STUB_DIR/osascript-stopped" 'exit 0'
make_stub "$STUB_DIR/xattr" 'exit 0'
make_stub "$STUB_DIR/codesign-fail-staging" \
  ': "${XMUX_TEST_CODESIGN_COUNT:?}"' \
  'count=0; [[ -f "$XMUX_TEST_CODESIGN_COUNT" ]] && count="$(<"$XMUX_TEST_CODESIGN_COUNT")"' \
  'count=$((count + 1)); printf "%s\n" "$count" > "$XMUX_TEST_CODESIGN_COUNT"' \
  'if [[ "$count" -eq 3 ]]; then exit 1; fi' \
  'exit 0'

APPLICATIONS_DIR="$TEST_ROOT/Applications"
INSTALLED_APP="$APPLICATIONS_DIR/xmux.app"
OFFICIAL_APP="$APPLICATIONS_DIR/cmux.app"
/bin/mkdir -p "$INSTALLED_APP" "$OFFICIAL_APP"
printf '%s\n' 'previous app' > "$INSTALLED_APP/previous-marker"
SUDO_LOG="$TEST_ROOT/sudo.log"
if env XMUX_BUILT_APP="$BUILT_APP" XMUX_INSTALLED_APP="$INSTALLED_APP" XMUX_OFFICIAL_APP="$OFFICIAL_APP" \
  XMUX_CODESIGN_BIN="$STUB_DIR/codesign-fail-staging" XMUX_TEST_CODESIGN_COUNT="$TEST_ROOT/codesign-count" \
  XMUX_SUDO_BIN="$STUB_DIR/sudo" XMUX_TEST_SUDO_LOG="$SUDO_LOG" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" XMUX_XATTR_BIN="$STUB_DIR/xattr" \
  "$XMUX_DIR/04_install_xmux.sh" > /dev/null 2>&1; then
  fail "install accepted failed staging verification"
fi
assert_file_exists "$INSTALLED_APP/previous-marker"
assert_contains "$SUDO_LOG" '.xmux.app.staging.'
pass "install stages replacement and preserves the previous app on failed verification"

env XMUX_BUILT_APP="$BUILT_APP" XMUX_INSTALLED_APP="$INSTALLED_APP" XMUX_OFFICIAL_APP="$OFFICIAL_APP" \
  XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" XMUX_SUDO_BIN="$STUB_DIR/sudo" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" XMUX_XATTR_BIN="$STUB_DIR/xattr" \
  "$XMUX_DIR/04_install_xmux.sh" > "$TEST_ROOT/install.log"
assert_file_absent "$INSTALLED_APP/previous-marker"
assert_file_exists "$INSTALLED_APP/Contents/Resources/bin/cmux"
assert_file_exists "$OFFICIAL_APP"
pass "install transaction replaces only xmux after complete verification"

if env XMUX_BUILT_APP="$BUILT_APP" XMUX_INSTALLED_APP="$OFFICIAL_APP" XMUX_OFFICIAL_APP="$OFFICIAL_APP" \
  XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" "$XMUX_DIR/04_install_xmux.sh" --dry-run > /dev/null 2>&1; then
  fail "install accepted official cmux as its target"
fi
pass "install never targets official cmux"

TEST_HOME="$TEST_ROOT/home"
CLI_PATH="$TEST_HOME/.local/bin/xmux"
ZSHRC="$TEST_HOME/.zshrc"
env XMUX_INSTALLED_APP="$INSTALLED_APP" XMUX_CLI_PATH="$CLI_PATH" XMUX_ZSHRC="$ZSHRC" \
  XMUX_SOCKET_PATH="$TEST_ROOT/xmux.sock" "$XMUX_DIR/05_install_xmux_cli.sh" > /dev/null
env XMUX_INSTALLED_APP="$INSTALLED_APP" XMUX_CLI_PATH="$CLI_PATH" XMUX_ZSHRC="$ZSHRC" \
  XMUX_SOCKET_PATH="$TEST_ROOT/xmux.sock" "$XMUX_DIR/05_install_xmux_cli.sh" > /dev/null
assert_contains "$CLI_PATH" "exec $INSTALLED_APP/Contents/Resources/bin/cmux --socket $TEST_ROOT/xmux.sock \"\$@\""
path_line_count="$(/usr/bin/grep -Fc '# xmux operations kit' "$ZSHRC")"
assert_equals "$path_line_count" '1'
pass "CLI wrapper uses the exact app/socket and does not duplicate the .zshrc PATH line"

DRY_CLI="$TEST_ROOT/dry-home/bin/xmux"
DRY_ZSHRC="$TEST_ROOT/dry-home/.zshrc"
env XMUX_INSTALLED_APP="$INSTALLED_APP" XMUX_CLI_PATH="$DRY_CLI" XMUX_ZSHRC="$DRY_ZSHRC" \
  "$XMUX_DIR/05_install_xmux_cli.sh" --dry-run > /dev/null
assert_file_absent "$DRY_CLI"
assert_file_absent "$DRY_ZSHRC"
pass "CLI --dry-run causes no mutation"

make_stub "$STUB_DIR/osascript-active" 'printf "%s\n" 4242'
for optional_script in \
  07_OPTIONAL_copy_existing_session.sh \
  08_OPTIONAL_copy_notification_history.sh \
  09_OPTIONAL_copy_macos_preferences.sh; do
  if env XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-active" XMUX_BACKUP_ROOT="$TEST_ROOT/active-backups" \
    "$XMUX_DIR/$optional_script" > /dev/null 2>&1; then
    fail "$optional_script continued while applications were active"
  fi
done
assert_file_absent "$TEST_ROOT/active-backups"
pass "all optional migrations refuse while either relevant application is active"

FAKE_OPERATIONS="$TEST_ROOT/fake operations"
/bin/mkdir -p "$FAKE_OPERATIONS"
ORDER_LOG="$TEST_ROOT/update-order.log"
make_stub "$FAKE_OPERATIONS/02_verify_source.sh" 'printf "%s\n" verify >> "${XMUX_TEST_ORDER_LOG:?}"'
make_stub "$FAKE_OPERATIONS/03_build_xmux.sh" 'printf "%s\n" build >> "${XMUX_TEST_ORDER_LOG:?}"'
make_stub "$FAKE_OPERATIONS/04_install_xmux.sh" 'printf "%s\n" install >> "${XMUX_TEST_ORDER_LOG:?}"'
env XMUX_OPERATIONS_DIR="$FAKE_OPERATIONS" XMUX_TEST_ORDER_LOG="$ORDER_LOG" \
  XMUX_REPO_ROOT="$FIXTURE_REPO" XMUX_INSTALLED_APP="$TEST_ROOT/not-installed.app" \
  "$XMUX_DIR/10_update_xmux.sh" --dry-run > /dev/null
assert_equals "$(<"$ORDER_LOG")" "$(printf '%s\n' verify build install)"
pass "update invokes verify, build, and install in order without Git mutation"

UNINSTALL_ROOT="$TEST_ROOT/uninstall"
UNINSTALL_APP="$UNINSTALL_ROOT/Applications/xmux.app"
UNINSTALL_OFFICIAL="$UNINSTALL_ROOT/Applications/cmux.app"
UNINSTALL_CLI="$UNINSTALL_ROOT/home/.local/bin/xmux"
UNINSTALL_DERIVED="$UNINSTALL_ROOT/DerivedData/cmux-xmux-main"
UNINSTALL_SUPPORT="$UNINSTALL_ROOT/Application Support/cmux"
UNINSTALL_SOCKET="$UNINSTALL_ROOT/xmux.sock"
UNINSTALL_DAEMON="$UNINSTALL_ROOT/cmuxd.sock"
UNINSTALL_SHARED_CMUX="$UNINSTALL_ROOT/home/.config/cmux/cmux.json"
UNINSTALL_SHARED_GHOSTTY="$UNINSTALL_ROOT/home/.config/ghostty/config"
/bin/mkdir -p "$UNINSTALL_APP" "$UNINSTALL_OFFICIAL" "$(dirname "$UNINSTALL_CLI")" "$UNINSTALL_DERIVED" \
  "$UNINSTALL_SUPPORT" "$(dirname "$UNINSTALL_SHARED_CMUX")" "$(dirname "$UNINSTALL_SHARED_GHOSTTY")"
printf '%s\n' keep > "$UNINSTALL_OFFICIAL/marker"
printf '%s\n' remove > "$UNINSTALL_APP/marker"
printf '%s\n' remove > "$UNINSTALL_CLI"
printf '%s\n' remove > "$UNINSTALL_SOCKET"
printf '%s\n' remove > "$UNINSTALL_DAEMON"
printf '%s\n' keep > "$UNINSTALL_SHARED_CMUX"
printf '%s\n' keep > "$UNINSTALL_SHARED_GHOSTTY"
printf '%s\n' remove > "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.debug.xmux-main.json"
printf '%s\n' remove > "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.debug.xmux-main-previous.json"
printf '%s\n' remove > "$UNINSTALL_SUPPORT/notification-feed-history-com.cmuxterm.app.debug.xmux-main.json"
printf '%s\n' keep > "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.json"

UNINSTALL_ENV=(
  XMUX_INSTALLED_APP="$UNINSTALL_APP"
  XMUX_OFFICIAL_APP="$UNINSTALL_OFFICIAL"
  XMUX_CLI_PATH="$UNINSTALL_CLI"
  XMUX_DERIVED_DATA="$UNINSTALL_DERIVED"
  XMUX_APPLICATION_SUPPORT="$UNINSTALL_SUPPORT"
  XMUX_SOCKET_PATH="$UNINSTALL_SOCKET"
  XMUX_DAEMON_SOCKET="$UNINSTALL_DAEMON"
  XMUX_SHARED_CMUX_SETTINGS="$UNINSTALL_SHARED_CMUX"
  XMUX_SHARED_GHOSTTY_SETTINGS="$UNINSTALL_SHARED_GHOSTTY"
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped"
  XMUX_SUDO_BIN="$STUB_DIR/sudo"
  XMUX_DEFAULTS_BIN="$STUB_DIR/defaults"
)
env "${UNINSTALL_ENV[@]}" "$XMUX_DIR/11_OPTIONAL_uninstall_xmux.sh" \
  --confirm-remove-xmux --dry-run > /dev/null
assert_file_exists "$UNINSTALL_APP/marker"
assert_file_exists "$UNINSTALL_CLI"
pass "uninstall --dry-run causes no mutation"

env "${UNINSTALL_ENV[@]}" "$XMUX_DIR/11_OPTIONAL_uninstall_xmux.sh" \
  --confirm-remove-xmux > /dev/null
assert_file_absent "$UNINSTALL_APP"
assert_file_absent "$UNINSTALL_CLI"
assert_file_absent "$UNINSTALL_DERIVED"
assert_file_absent "$UNINSTALL_SOCKET"
assert_file_absent "$UNINSTALL_DAEMON"
assert_file_absent "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.debug.xmux-main.json"
assert_file_absent "$UNINSTALL_SUPPORT/notification-feed-history-com.cmuxterm.app.debug.xmux-main.json"
assert_file_exists "$UNINSTALL_OFFICIAL/marker"
assert_file_exists "$UNINSTALL_SHARED_CMUX"
assert_file_exists "$UNINSTALL_SHARED_GHOSTTY"
assert_file_exists "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.json"
pass "uninstall removes only xmux bundle-specific state and preserves official/shared paths"

DRY_BACKUP_ROOT="$TEST_ROOT/dry-backup"
env XMUX_BACKUP_ROOT="$DRY_BACKUP_ROOT" XMUX_TIMESTAMP='20260722-130000' \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" XMUX_GHOSTTY_CONFIG_DIR="$CONFIG_ROOT/ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  "$XMUX_DIR/01_backup_existing_cmux.sh" --dry-run > /dev/null
assert_file_absent "$DRY_BACKUP_ROOT"
pass "backup --dry-run causes no mutation"

for required_path in \
  '/Users/xaero/Projects/cmux' \
  '/Applications/cmux.app' \
  '/Applications/xmux.app' \
  '/Users/xaero/Library/Developer/Xcode/DerivedData/cmux-xmux-main' \
  '/Users/xaero/.local/bin/xmux' \
  '/tmp/cmux-debug-xmux-main.sock' \
  '/Users/xaero/Library/Application Support/cmux' \
  '/Users/xaero/Desktop'; do
  assert_contains "$XMUX_DIR/README.md" "$required_path"
done
for command_path in \
  './xmux/01_backup_existing_cmux.sh' \
  './xmux/02_verify_source.sh' \
  './xmux/03_build_xmux.sh' \
  './xmux/04_install_xmux.sh' \
  './xmux/05_install_xmux_cli.sh' \
  './xmux/06_launch_and_verify_xmux.sh' \
  './xmux/10_update_xmux.sh' \
  './xmux/11_OPTIONAL_uninstall_xmux.sh'; do
  assert_contains "$XMUX_DIR/README.md" "$command_path"
done
pass "README paths and committed command sequence are consistent"

if /usr/bin/grep -REn --include='*.sh' \
  'git[[:space:]].*(fetch|pull|rebase|reset|checkout|switch)[[:space:]]' "$XMUX_DIR" >/dev/null; then
  fail "a shell script contains a prohibited Git mutation"
fi
if /usr/bin/grep -REn --include='*.sh' --exclude='test_xmux_scripts.sh' \
  'curl|wget|security[[:space:]]' "$XMUX_DIR" >/dev/null; then
  fail "a shell script contains network download or Keychain access"
fi
pass "scripts contain no Git update, network download, or Keychain operation"

printf 'PASS %d xmux script assertions\n' "$PASS_COUNT"
