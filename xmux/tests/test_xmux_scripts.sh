#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
XMUX_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
TEST_ROOT="$(mktemp -d /tmp/xmux-script-tests.XXXXXX)"
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

assert_not_contains() {
  if /usr/bin/grep -Fq -- "$2" "$1"; then
    fail "$1 unexpectedly contains: $2"
  fi
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
  /usr/bin/plutil -insert CFBundleExecutable -string 'xmux-test-executable' "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment -xml '<dict/>' "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment.CMUX_BUNDLED_CLI_PATH -string "/build/cmux" "$app_path/Contents/Info.plist"
  /usr/bin/plutil -insert LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string "/build/shell-integration" "$app_path/Contents/Info.plist"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$app_path/Contents/Resources/bin/cmux"
  /bin/chmod 0755 "$app_path/Contents/Resources/bin/cmux"
  /bin/mkdir -p "$app_path/Contents/MacOS"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$app_path/Contents/MacOS/xmux-test-executable"
  /bin/chmod 0755 "$app_path/Contents/MacOS/xmux-test-executable"
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

render_wrapper() {
  local output_path="$1"
  local installed_cli="$2"
  local socket_path="$3"
  (
    # shellcheck source=xmux/lib/common.sh
    source "$XMUX_DIR/lib/common.sh"
    xmux_render_cli_wrapper "$installed_cli" "$socket_path"
  ) > "$output_path"
  /bin/chmod 0755 "$output_path"
}

make_socket_path() {
  local socket_path="$1"
  /usr/bin/perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '
    my $path = shift @ARGV;
    my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $path, Listen => 1)
      or die "socket $path: $!\n";
    close $socket;
  ' "$socket_path"
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

ALIAS_ROOT="$TEST_ROOT/alias safety"
ALIAS_REAL_PARENT="$ALIAS_ROOT/real Applications"
ALIAS_OFFICIAL_APP="$ALIAS_REAL_PARENT/cmux.app"
ALIAS_MUTATION_MARKER="$ALIAS_ROOT/mutation-marker"
/bin/mkdir -p "$ALIAS_OFFICIAL_APP/Contents" "$ALIAS_ROOT/relative-work"
/bin/ln -s "$ALIAS_REAL_PARENT" "$ALIAS_ROOT/symlinked Applications"
/bin/ln -s "$ALIAS_OFFICIAL_APP" "$ALIAS_ROOT/final-link.app"
printf '%s\n' official > "$ALIAS_ROOT/official-object"
/bin/ln "$ALIAS_ROOT/official-object" "$ALIAS_ROOT/hardlink-object"

ALIAS_TEST_COUNT=0
assert_alias_rejected() {
  local label="$1"
  local target="$2"
  local protected_path="$3"
  local working_directory="${4:-$TEST_ROOT}"
  if (
    cd "$working_directory"
    XMUX_OFFICIAL_APP="$protected_path"
    # shellcheck source=xmux/lib/common.sh
    source "$XMUX_DIR/lib/common.sh"
    xmux_require_safe_destructive_target "$target"
    printf '%s\n' "$label" > "$ALIAS_MUTATION_MARKER"
  ) > /dev/null 2>&1; then
    fail "accepted official-app alias: $label ($target)"
  fi
  assert_file_absent "$ALIAS_MUTATION_MARKER"
  ALIAS_TEST_COUNT=$((ALIAS_TEST_COUNT + 1))
}

assert_alias_rejected "literal" "$ALIAS_OFFICIAL_APP" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "dot" "$ALIAS_REAL_PARENT/./cmux.app" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "dotdot" "$ALIAS_REAL_PARENT/missing/../cmux.app" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "repeated separators" "$ALIAS_REAL_PARENT////cmux.app" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "symlinked parent" "$ALIAS_ROOT/symlinked Applications/cmux.app" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "final symlink" "$ALIAS_ROOT/final-link.app" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "same filesystem object" "$ALIAS_ROOT/hardlink-object" "$ALIAS_ROOT/official-object"
assert_alias_rejected "inside official app" "$ALIAS_OFFICIAL_APP/Contents/Resources" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "target contains official child" "$ALIAS_REAL_PARENT" "$ALIAS_OFFICIAL_APP"
assert_alias_rejected "relative alias" "../real Applications/cmux.app" "$ALIAS_OFFICIAL_APP" "$ALIAS_ROOT/relative-work"
assert_alias_rejected "configured official redefined" '/Applications/cmux.app' "$ALIAS_ROOT/not-official.app"
assert_equals "$ALIAS_TEST_COUNT" '11'
pass "canonical destructive-target guard rejects all 11 official-app alias classes without mutation"

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
  'mode="${XMUX_TEST_DEFAULTS_MODE:-present-success}"' \
  'case "${1:-}" in' \
  '  read) [[ "$mode" != absent ]] ;;' \
  '  export)' \
  '    mkdir -p "$(dirname "$3")"' \
  '    printf "plist\n" > "$3"' \
  '    [[ "$mode" != present-export-failure ]]' \
  '    ;;' \
  '  *) exit 0 ;;' \
  'esac'
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
assert_contains "$TEST_ROOT/backup.log" 'Official defaults: present; exported.'
assert_contains "$TEST_ROOT/backup.log" "Backup path: $BACKUP_PATH"
pass "real successful backup reserves exported and actual-path wording for published artifacts"

ABSENT_BACKUP_ROOT="$TEST_ROOT/backup defaults absent"
env XMUX_BACKUP_ROOT="$ABSENT_BACKUP_ROOT" \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" \
  XMUX_GHOSTTY_CONFIG_DIR="$TEST_ROOT/missing ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" \
  XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  XMUX_TEST_DEFAULTS_MODE=absent \
  XMUX_TIMESTAMP='20260722-120001' \
  "$XMUX_DIR/01_backup_existing_cmux.sh" > "$TEST_ROOT/backup-absent.log"
ABSENT_BACKUP_PATH="$ABSENT_BACKUP_ROOT/cmux-backup-20260722-120001"
assert_file_exists "$ABSENT_BACKUP_PATH/config/cmux/cmux.json"
assert_file_exists "$ABSENT_BACKUP_PATH/Application Support/cmux/state/session.json"
assert_file_absent "$ABSENT_BACKUP_PATH/com.cmuxterm.app.plist"
assert_contains "$TEST_ROOT/backup-absent.log" 'Official defaults domain is absent; skipped: com.cmuxterm.app'
assert_contains "$TEST_ROOT/backup-absent.log" "Backup path: $ABSENT_BACKUP_PATH"
pass "backup treats an absent defaults domain as a nonfatal skipped source"

FAILED_BACKUP_ROOT="$TEST_ROOT/backup defaults failure"
if env XMUX_BACKUP_ROOT="$FAILED_BACKUP_ROOT" \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" \
  XMUX_GHOSTTY_CONFIG_DIR="$TEST_ROOT/missing ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" \
  XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  XMUX_TEST_DEFAULTS_MODE=present-export-failure \
  XMUX_TIMESTAMP='20260722-120002' \
  "$XMUX_DIR/01_backup_existing_cmux.sh" > "$TEST_ROOT/backup-failure.log" 2>&1; then
  fail "backup accepted a genuine defaults export failure"
fi
FAILED_BACKUP_PATH="$FAILED_BACKUP_ROOT/cmux-backup-20260722-120002"
assert_file_exists "$FAILED_BACKUP_PATH/config/cmux/cmux.json"
assert_file_exists "$FAILED_BACKUP_PATH/Application Support/cmux/state/session.json"
assert_file_absent "$FAILED_BACKUP_PATH/com.cmuxterm.app.plist"
assert_not_contains "$TEST_ROOT/backup-failure.log" 'Backup path:'
assert_contains "$TEST_ROOT/backup-failure.log" 'official defaults exist but export failed'
pass "backup fails a real export error without publishing an empty or successful plist receipt"
assert_not_contains "$TEST_ROOT/backup-failure.log" 'Official defaults: present; exported.'
assert_not_contains "$TEST_ROOT/backup-failure.log" 'Dry run only; no backup was created.'
pass "real backup export failure remains fatal without any success receipt"

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

/bin/ln -s "$APPLICATIONS_DIR" "$TEST_ROOT/Applications alias"
ALIAS_INSTALL_LOG="$TEST_ROOT/alias-install-sudo.log"
if env XMUX_BUILT_APP="$BUILT_APP" \
  XMUX_INSTALLED_APP="$TEST_ROOT/Applications alias/cmux.app" \
  XMUX_OFFICIAL_APP="$OFFICIAL_APP" \
  XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" \
  XMUX_SUDO_BIN="$STUB_DIR/sudo" \
  XMUX_TEST_SUDO_LOG="$ALIAS_INSTALL_LOG" \
  "$XMUX_DIR/04_install_xmux.sh" --dry-run > /dev/null 2>&1; then
  fail "install dry-run accepted a symlink-parent alias to official cmux"
fi
assert_file_absent "$ALIAS_INSTALL_LOG"
assert_file_exists "$OFFICIAL_APP"
pass "install dry-run validates aliased target, staging, and rollback paths before mutation"

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

WRAPPER_CASE_ROOT="$TEST_ROOT/wrapper renderer"
/bin/mkdir -p "$WRAPPER_CASE_ROOT"
DEFAULT_WRAPPER="$WRAPPER_CASE_ROOT/default-wrapper"
render_wrapper "$DEFAULT_WRAPPER" \
  '/Applications/xmux.app/Contents/Resources/bin/cmux' \
  '/tmp/cmux-debug-xmux-main.sock'
expected_default_wrapper="$(printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec /Applications/xmux.app/Contents/Resources/bin/cmux --socket /tmp/cmux-debug-xmux-main.sock "$@"')"
assert_equals "$(<"$DEFAULT_WRAPPER")" "$expected_default_wrapper"
pass "canonical CLI wrapper renderer emits the exact default executable and socket"

WRAPPER_SYNTAX_COUNT=0
WRAPPER_ARGUMENT_COUNT=0
exercise_rendered_wrapper() {
  local case_name="$1"
  local target_path="$2"
  local socket_path="$3"
  local wrapper_path="$WRAPPER_CASE_ROOT/$case_name-wrapper"
  local argument_log="$WRAPPER_CASE_ROOT/$case_name-arguments.log"
  make_stub "$target_path" \
    ': "${XMUX_TEST_WRAPPER_ARGUMENT_LOG:?}"' \
    'printf "argc=%s\n" "$#" > "$XMUX_TEST_WRAPPER_ARGUMENT_LOG"' \
    'for argument in "$@"; do printf "arg=[%s]\n" "$argument" >> "$XMUX_TEST_WRAPPER_ARGUMENT_LOG"; done'
  render_wrapper "$wrapper_path" "$target_path" "$socket_path"
  /bin/bash -n "$wrapper_path"
  WRAPPER_SYNTAX_COUNT=$((WRAPPER_SYNTAX_COUNT + 1))
  XMUX_TEST_WRAPPER_ARGUMENT_LOG="$argument_log" \
    "$wrapper_path" 'first argument' '*' 'last argument'
  expected_arguments="$(printf '%s\n' \
    'argc=5' \
    'arg=[--socket]' \
    "arg=[$socket_path]" \
    'arg=[first argument]' \
    'arg=[*]' \
    'arg=[last argument]')"
  assert_equals "$(<"$argument_log")" "$expected_arguments"
  WRAPPER_ARGUMENT_COUNT=$((WRAPPER_ARGUMENT_COUNT + 1))
}

exercise_rendered_wrapper app-space \
  "$WRAPPER_CASE_ROOT/Application With Space/bin/cmux" \
  "$WRAPPER_CASE_ROOT/socket.sock"
pass "canonical wrapper safely executes an application path containing spaces"
exercise_rendered_wrapper socket-space \
  "$WRAPPER_CASE_ROOT/application/bin/cmux" \
  "$WRAPPER_CASE_ROOT/Socket Root/cmux.sock"
pass "canonical wrapper safely preserves a socket path containing spaces"
exercise_rendered_wrapper both-spaces \
  "$WRAPPER_CASE_ROOT/Another Application/bin/cmux" \
  "$WRAPPER_CASE_ROOT/Another Socket Root/cmux.sock"
pass "canonical wrapper safely executes when both configured paths contain spaces"
exercise_rendered_wrapper metacharacters \
  "$WRAPPER_CASE_ROOT/app;literal-dollar-\$-bracket[1]/bin/cmux" \
  "$WRAPPER_CASE_ROOT/socket;literal-dollar-\$-bracket[2]/cmux.sock"
pass "canonical wrapper shell-escapes metacharacters without evaluating them"
assert_equals "$WRAPPER_SYNTAX_COUNT" '4'
pass "every generated special-path wrapper passes bash -n"
assert_equals "$WRAPPER_ARGUMENT_COUNT" '4'
pass "generated wrappers preserve every user argument boundary"

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

PROCESS_QUERY_STUB="$STUB_DIR/osascript-process-query"
make_stub "$PROCESS_QUERY_STUB" \
  ': "${XMUX_TEST_PROCESS_MODE:?}"' \
  'query="$*"' \
  'case "$query" in' \
  '  *com.cmuxterm.app.debug.xmux-main*) bundle=xmux ;;' \
  '  *com.cmuxterm.app*) bundle=official ;;' \
  '  *) exit 70 ;;' \
  'esac' \
  '[[ -z "${XMUX_TEST_PROCESS_QUERY_LOG:-}" ]] || printf "%s\n" "$bundle" >> "$XMUX_TEST_PROCESS_QUERY_LOG"' \
  'case "$XMUX_TEST_PROCESS_MODE:$bundle" in' \
  '  both-stopped:*) exit 0 ;;' \
  '  official-fails:official) exit 71 ;;' \
  '  official-fails:xmux) exit 0 ;;' \
  '  xmux-fails:official) exit 0 ;;' \
  '  xmux-fails:xmux) exit 72 ;;' \
  '  official-active:official) printf "%s\n" 6101 ;;' \
  '  official-active:xmux) exit 0 ;;' \
  '  xmux-active:official) exit 0 ;;' \
  '  xmux-active:xmux) printf "%s\n" 6202 ;;' \
  '  *) exit 73 ;;' \
  'esac'

run_process_gate() {
  local mode="$1"
  local query_log="$2"
  env XMUX_OSASCRIPT_BIN="$PROCESS_QUERY_STUB" \
    XMUX_TEST_PROCESS_MODE="$mode" \
    XMUX_TEST_PROCESS_QUERY_LOG="$query_log" \
    /bin/bash -c 'source "$1"; xmux_require_both_apps_stopped' \
    xmux-process-gate "$XMUX_DIR/lib/common.sh"
}

PROCESS_GATE_ROOT="$TEST_ROOT/process query gates"
/bin/mkdir -p "$PROCESS_GATE_ROOT"
run_process_gate both-stopped "$PROCESS_GATE_ROOT/both-stopped.queries" \
  > "$PROCESS_GATE_ROOT/both-stopped.log"
assert_equals "$(<"$PROCESS_GATE_ROOT/both-stopped.queries")" "$(printf '%s\n' official xmux)"
pass "process gate accepts only two successful stopped-application queries"

if run_process_gate official-fails "$PROCESS_GATE_ROOT/official-fails.queries" \
  > "$PROCESS_GATE_ROOT/official-fails.log" 2>&1; then
  fail "process gate treated a failed official cmux query as stopped"
fi
assert_contains "$PROCESS_GATE_ROOT/official-fails.log" \
  'cannot establish whether official cmux is stopped (bundle com.cmuxterm.app): process query failed'
pass "process gate fails closed when official cmux state cannot be established"

if run_process_gate xmux-fails "$PROCESS_GATE_ROOT/xmux-fails.queries" \
  > "$PROCESS_GATE_ROOT/xmux-fails.log" 2>&1; then
  fail "process gate treated a failed xmux query as stopped"
fi
assert_contains "$PROCESS_GATE_ROOT/xmux-fails.log" \
  'cannot establish whether xmux is stopped (bundle com.cmuxterm.app.debug.xmux-main): process query failed'
pass "process gate fails closed when xmux state cannot be established"

if run_process_gate official-active "$PROCESS_GATE_ROOT/official-active.queries" \
  > "$PROCESS_GATE_ROOT/official-active.log" 2>&1; then
  fail "process gate accepted active official cmux"
fi
assert_contains "$PROCESS_GATE_ROOT/official-active.log" 'official cmux must be fully stopped'
pass "process gate rejects an active official cmux process"

if run_process_gate xmux-active "$PROCESS_GATE_ROOT/xmux-active.queries" \
  > "$PROCESS_GATE_ROOT/xmux-active.log" 2>&1; then
  fail "process gate accepted active xmux"
fi
assert_contains "$PROCESS_GATE_ROOT/xmux-active.log" 'xmux must be fully stopped'
pass "process gate rejects an active xmux process"

make_stub "$STUB_DIR/defaults-must-not-run" \
  ': "${XMUX_TEST_UNEXPECTED_DEFAULTS_LOG:?}"' \
  'printf "%s\n" "$*" >> "$XMUX_TEST_UNEXPECTED_DEFAULTS_LOG"' \
  'exit 97'

PROCESS_MIGRATION_ROOT="$TEST_ROOT/process failure migrations"
for process_mode in official-fails xmux-fails; do
  for optional_script in \
    07_OPTIONAL_copy_existing_session.sh \
    08_OPTIONAL_copy_notification_history.sh \
    09_OPTIONAL_copy_macos_preferences.sh; do
    case_root="$PROCESS_MIGRATION_ROOT/$process_mode-$optional_script"
    support_root="$case_root/support"
    backup_root="$case_root/backups"
    defaults_log="$case_root/defaults.log"
    /bin/mkdir -p "$support_root"
    printf '%s\n' official-session > "$support_root/session-com.cmuxterm.app.json"
    printf '%s\n' old-session > "$support_root/session-com.cmuxterm.app.debug.xmux-main.json"
    printf '%s\n' official-history > "$support_root/notification-feed-history-com.cmuxterm.app.json"
    printf '%s\n' old-history > "$support_root/notification-feed-history-com.cmuxterm.app.debug.xmux-main.json"
    if env XMUX_OSASCRIPT_BIN="$PROCESS_QUERY_STUB" \
      XMUX_TEST_PROCESS_MODE="$process_mode" \
      XMUX_APPLICATION_SUPPORT="$support_root" \
      XMUX_BACKUP_ROOT="$backup_root" \
      XMUX_DEFAULTS_BIN="$STUB_DIR/defaults-must-not-run" \
      XMUX_TEST_UNEXPECTED_DEFAULTS_LOG="$defaults_log" \
      "$XMUX_DIR/$optional_script" > "$case_root/result.log" 2>&1; then
      fail "$optional_script accepted $process_mode"
    fi
    assert_file_absent "$backup_root"
    assert_file_absent "$defaults_log"
    assert_equals "$(<"$support_root/session-com.cmuxterm.app.debug.xmux-main.json")" 'old-session'
    assert_equals "$(<"$support_root/notification-feed-history-com.cmuxterm.app.debug.xmux-main.json")" 'old-history'
    if [[ "$process_mode" == official-fails ]]; then
      assert_contains "$case_root/result.log" 'bundle com.cmuxterm.app): process query failed'
    else
      assert_contains "$case_root/result.log" 'bundle com.cmuxterm.app.debug.xmux-main): process query failed'
    fi
    pass "$optional_script refuses $process_mode before backup or target mutation"
  done
done

PROCESS_DRY_ROOT="$PROCESS_MIGRATION_ROOT/dry-run-query-failure"
/bin/mkdir -p "$PROCESS_DRY_ROOT/support"
printf '%s\n' old-session > \
  "$PROCESS_DRY_ROOT/support/session-com.cmuxterm.app.debug.xmux-main.json"
if env XMUX_OSASCRIPT_BIN="$PROCESS_QUERY_STUB" \
  XMUX_TEST_PROCESS_MODE=official-fails \
  XMUX_APPLICATION_SUPPORT="$PROCESS_DRY_ROOT/support" \
  XMUX_BACKUP_ROOT="$PROCESS_DRY_ROOT/backups" \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" --dry-run \
  > "$PROCESS_DRY_ROOT/result.log" 2>&1; then
  fail "optional migration dry-run treated a failed process query as stopped"
fi
assert_file_absent "$PROCESS_DRY_ROOT/backups"
assert_equals "$(<"$PROCESS_DRY_ROOT/support/session-com.cmuxterm.app.debug.xmux-main.json")" 'old-session'
pass "optional migration dry-run fails closed before planned backup on query failure"

SESSION_CASE_ROOT="$TEST_ROOT/session receipt cases"
SESSION_OFFICIAL_PRIMARY_NAME='session-com.cmuxterm.app.json'
SESSION_OFFICIAL_PREVIOUS_NAME='session-com.cmuxterm.app-previous.json'
SESSION_XMUX_PRIMARY_NAME='session-com.cmuxterm.app.debug.xmux-main.json'
SESSION_XMUX_PREVIOUS_NAME='session-com.cmuxterm.app.debug.xmux-main-previous.json'

SESSION_NONE_SUPPORT="$SESSION_CASE_ROOT/none/support"
env XMUX_APPLICATION_SUPPORT="$SESSION_NONE_SUPPORT" \
  XMUX_BACKUP_ROOT="$SESSION_CASE_ROOT/none/backups" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
  XMUX_TIMESTAMP='20260722-140000' \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" > "$SESSION_CASE_ROOT-none.log"
assert_contains "$SESSION_CASE_ROOT-none.log" 'Primary snapshot source absent; skipped.'
assert_contains "$SESSION_CASE_ROOT-none.log" 'Previous snapshot source absent; skipped.'
assert_contains "$SESSION_CASE_ROOT-none.log" 'Session migration receipt: copied=0 skipped=2 targets_backed_up=0.'
assert_contains "$SESSION_CASE_ROOT-none.log" 'No session snapshots were migrated.'
assert_file_absent "$SESSION_NONE_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_file_absent "$SESSION_NONE_SUPPORT/$SESSION_XMUX_PREVIOUS_NAME"
pass "session migration reports neither source as skipped without implying migration"

SESSION_PRIMARY_SUPPORT="$SESSION_CASE_ROOT/primary/support"
/bin/mkdir -p "$SESSION_PRIMARY_SUPPORT"
printf '%s\n' primary > "$SESSION_PRIMARY_SUPPORT/$SESSION_OFFICIAL_PRIMARY_NAME"
env XMUX_APPLICATION_SUPPORT="$SESSION_PRIMARY_SUPPORT" \
  XMUX_BACKUP_ROOT="$SESSION_CASE_ROOT/primary/backups" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
  XMUX_TIMESTAMP='20260722-140001' \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" > "$SESSION_CASE_ROOT-primary.log"
assert_file_exists "$SESSION_PRIMARY_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_file_absent "$SESSION_PRIMARY_SUPPORT/$SESSION_XMUX_PREVIOUS_NAME"
assert_contains "$SESSION_CASE_ROOT-primary.log" "Primary snapshot copied: $SESSION_PRIMARY_SUPPORT/$SESSION_OFFICIAL_PRIMARY_NAME -> $SESSION_PRIMARY_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_contains "$SESSION_CASE_ROOT-primary.log" 'Session migration receipt: copied=1 skipped=1 targets_backed_up=0.'
pass "session migration receipt distinguishes primary-only copy"

SESSION_PREVIOUS_SUPPORT="$SESSION_CASE_ROOT/previous/support"
/bin/mkdir -p "$SESSION_PREVIOUS_SUPPORT"
printf '%s\n' previous > "$SESSION_PREVIOUS_SUPPORT/$SESSION_OFFICIAL_PREVIOUS_NAME"
env XMUX_APPLICATION_SUPPORT="$SESSION_PREVIOUS_SUPPORT" \
  XMUX_BACKUP_ROOT="$SESSION_CASE_ROOT/previous/backups" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
  XMUX_TIMESTAMP='20260722-140002' \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" > "$SESSION_CASE_ROOT-previous.log"
assert_file_absent "$SESSION_PREVIOUS_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_file_exists "$SESSION_PREVIOUS_SUPPORT/$SESSION_XMUX_PREVIOUS_NAME"
assert_contains "$SESSION_CASE_ROOT-previous.log" 'Session migration receipt: copied=1 skipped=1 targets_backed_up=0.'
pass "session migration receipt distinguishes previous-only copy"

SESSION_BOTH_SUPPORT="$SESSION_CASE_ROOT/both/support"
/bin/mkdir -p "$SESSION_BOTH_SUPPORT"
printf '%s\n' primary > "$SESSION_BOTH_SUPPORT/$SESSION_OFFICIAL_PRIMARY_NAME"
printf '%s\n' previous > "$SESSION_BOTH_SUPPORT/$SESSION_OFFICIAL_PREVIOUS_NAME"
printf '%s\n' old-target > "$SESSION_BOTH_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
env XMUX_APPLICATION_SUPPORT="$SESSION_BOTH_SUPPORT" \
  XMUX_BACKUP_ROOT="$SESSION_CASE_ROOT/both/backups" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
  XMUX_TIMESTAMP='20260722-140003' \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" > "$SESSION_CASE_ROOT-both.log"
assert_contains "$SESSION_CASE_ROOT-both.log" "Primary snapshot target backed up: $SESSION_BOTH_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_contains "$SESSION_CASE_ROOT-both.log" 'Session migration receipt: copied=2 skipped=0 targets_backed_up=1.'
assert_file_exists "$SESSION_CASE_ROOT/both/backups/cmux-pre-session-migration-20260722-140003/$SESSION_XMUX_PRIMARY_NAME"
pass "session migration receipt reports both copies and exact target-backup count"

make_stub "$STUB_DIR/ditto-fail-session" 'exit 47'
SESSION_FAILURE_SUPPORT="$SESSION_CASE_ROOT/failure/support"
/bin/mkdir -p "$SESSION_FAILURE_SUPPORT"
printf '%s\n' primary > "$SESSION_FAILURE_SUPPORT/$SESSION_OFFICIAL_PRIMARY_NAME"
if env XMUX_APPLICATION_SUPPORT="$SESSION_FAILURE_SUPPORT" \
  XMUX_BACKUP_ROOT="$SESSION_CASE_ROOT/failure/backups" \
  XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
  XMUX_DITTO_BIN="$STUB_DIR/ditto-fail-session" \
  XMUX_TIMESTAMP='20260722-140004' \
  "$XMUX_DIR/07_OPTIONAL_copy_existing_session.sh" > "$SESSION_CASE_ROOT-failure.log" 2>&1; then
  fail "session migration accepted a failed copy"
fi
assert_file_absent "$SESSION_FAILURE_SUPPORT/$SESSION_XMUX_PRIMARY_NAME"
assert_not_contains "$SESSION_CASE_ROOT-failure.log" 'Primary snapshot copied:'
assert_not_contains "$SESSION_CASE_ROOT-failure.log" 'Session migration receipt:'
pass "session migration reports a snapshot copied only after successful copy"

DEFAULTS_MIGRATION_STUB="$STUB_DIR/defaults-migration"
make_stub "$DEFAULTS_MIGRATION_STUB" \
  ': "${XMUX_TEST_DEFAULTS_LOG:?}"' \
  ': "${XMUX_TEST_SOURCE_STATE:?}" "${XMUX_TEST_TARGET_STATE:?}"' \
  ': "${XMUX_TEST_SOURCE_EXPORT_MODE:?}" "${XMUX_TEST_TARGET_EXPORT_MODE:?}"' \
  ': "${XMUX_TEST_IMPORT_MODE:?}"' \
  'command_name="${1:-}"' \
  'printf "%s" "$command_name" >> "$XMUX_TEST_DEFAULTS_LOG"' \
  'if [[ "$#" -gt 0 ]]; then shift; fi' \
  'for argument in "$@"; do printf " [%s]" "$argument" >> "$XMUX_TEST_DEFAULTS_LOG"; done' \
  'printf "\n" >> "$XMUX_TEST_DEFAULTS_LOG"' \
  'case "$command_name" in' \
  '  read)' \
  '    case "$1" in' \
  '      com.cmuxterm.app) state="$XMUX_TEST_SOURCE_STATE" ;;' \
  '      com.cmuxterm.app.debug.xmux-main) state="$XMUX_TEST_TARGET_STATE" ;;' \
  '      *) exit 74 ;;' \
  '    esac' \
  '    [[ "$state" == present ]] && exit 0' \
  '    exit 1' \
  '    ;;' \
  '  domains)' \
  '    domains=""' \
  '    if [[ "$XMUX_TEST_SOURCE_STATE" != absent ]]; then domains="com.cmuxterm.app"; fi' \
  '    if [[ "$XMUX_TEST_TARGET_STATE" != absent ]]; then' \
  '      if [[ -n "$domains" ]]; then domains="$domains, "; fi' \
  '      domains="${domains}com.cmuxterm.app.debug.xmux-main"' \
  '    fi' \
  '    printf "%s\n" "$domains"' \
  '    ;;' \
  '  export)' \
  '    case "$1" in' \
  '      com.cmuxterm.app) export_mode="$XMUX_TEST_SOURCE_EXPORT_MODE" ;;' \
  '      com.cmuxterm.app.debug.xmux-main) export_mode="$XMUX_TEST_TARGET_EXPORT_MODE" ;;' \
  '      *) exit 75 ;;' \
  '    esac' \
  '    case "$export_mode" in' \
  '      success) mkdir -p "$(dirname "$2")"; printf "plist for %s\n" "$1" > "$2" ;;' \
  '      nonzero) exit 76 ;;' \
  '      no-file) exit 0 ;;' \
  '      empty) mkdir -p "$(dirname "$2")"; : > "$2" ;;' \
  '      *) exit 77 ;;' \
  '    esac' \
  '    ;;' \
  '  import)' \
  '    [[ "$XMUX_TEST_IMPORT_MODE" == success ]] || exit 78' \
  '    ;;' \
  '  *) exit 79 ;;' \
  'esac'

prepare_preferences_case() {
  PREF_CASE_ROOT="$1"
  PREF_BACKUP_ROOT="$PREF_CASE_ROOT/backups"
  PREF_DEFAULTS_LOG="$PREF_CASE_ROOT/defaults.log"
  PREF_RESULT_LOG="$PREF_CASE_ROOT/result.log"
  PREF_TARGET_SENTINEL="$PREF_CASE_ROOT/xmux-target-sentinel"
  PREF_BACKUP_PATH="$PREF_BACKUP_ROOT/cmux-pre-defaults-migration-20260722-150000"
  PREF_SOURCE_EXPORT="$PREF_BACKUP_PATH/com.cmuxterm.app.plist"
  PREF_TARGET_EXPORT="$PREF_BACKUP_PATH/com.cmuxterm.app.debug.xmux-main-before.plist"
  /bin/mkdir -p "$PREF_CASE_ROOT"
  printf '%s\n' unchanged > "$PREF_TARGET_SENTINEL"
}

run_preferences_case() {
  local source_state="$1"
  local target_state="$2"
  local source_export_mode="$3"
  local target_export_mode="$4"
  local import_mode="$5"
  shift 5
  env XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-stopped" \
    XMUX_DEFAULTS_BIN="$DEFAULTS_MIGRATION_STUB" \
    XMUX_TEST_DEFAULTS_LOG="$PREF_DEFAULTS_LOG" \
    XMUX_TEST_SOURCE_STATE="$source_state" \
    XMUX_TEST_TARGET_STATE="$target_state" \
    XMUX_TEST_SOURCE_EXPORT_MODE="$source_export_mode" \
    XMUX_TEST_TARGET_EXPORT_MODE="$target_export_mode" \
    XMUX_TEST_IMPORT_MODE="$import_mode" \
    XMUX_BACKUP_ROOT="$PREF_BACKUP_ROOT" \
    XMUX_TIMESTAMP='20260722-150000' \
    "$XMUX_DIR/09_OPTIONAL_copy_macos_preferences.sh" "$@"
}

assert_preferences_target_unchanged() {
  assert_equals "$(<"$PREF_TARGET_SENTINEL")" unchanged
}

assert_preferences_not_imported() {
  if [[ -e "$PREF_DEFAULTS_LOG" ]] && /usr/bin/grep -q '^import ' "$PREF_DEFAULTS_LOG"; then
    fail "preferences import ran before verified source and recovery state: $PREF_CASE_ROOT"
  fi
  assert_preferences_target_unchanged
}

PREF_FAILURE_LOGS=()
PREF_EXPORT_FAILURE_DEFAULTS_LOGS=()

prepare_preferences_case "$TEST_ROOT/preferences source absent"
run_preferences_case absent absent success success success > "$PREF_RESULT_LOG"
assert_file_absent "$PREF_BACKUP_ROOT"
assert_preferences_not_imported
assert_contains "$PREF_RESULT_LOG" 'Source domain: absent.'
assert_contains "$PREF_RESULT_LOG" 'Target domain: absent; no target backup was required.'
assert_contains "$PREF_RESULT_LOG" 'Import: skipped.'
assert_not_contains "$PREF_RESULT_LOG" 'Migration backup directory:'
pass "preferences migration distinguishes an absent source and skips without a backup or import"

prepare_preferences_case "$TEST_ROOT/preferences source present target absent"
run_preferences_case present absent success success success > "$PREF_RESULT_LOG"
assert_file_exists "$PREF_SOURCE_EXPORT"
assert_file_absent "$PREF_TARGET_EXPORT"
assert_contains "$PREF_RESULT_LOG" 'Source domain: exported.'
assert_contains "$PREF_RESULT_LOG" "Source export path: $PREF_SOURCE_EXPORT"
assert_contains "$PREF_RESULT_LOG" 'Target domain: absent; no target backup was required.'
assert_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
assert_contains "$PREF_DEFAULTS_LOG" "import [com.cmuxterm.app.debug.xmux-main] [$PREF_SOURCE_EXPORT]"
assert_preferences_target_unchanged
pass "preferences migration imports a validated source when the target domain is absent"

prepare_preferences_case "$TEST_ROOT/preferences both present"
run_preferences_case present present success success success > "$PREF_RESULT_LOG"
assert_file_exists "$PREF_SOURCE_EXPORT"
assert_file_exists "$PREF_TARGET_EXPORT"
assert_contains "$PREF_RESULT_LOG" 'Target domain: backed up.'
assert_contains "$PREF_RESULT_LOG" "Target backup path: $PREF_TARGET_EXPORT"
assert_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
assert_preferences_target_unchanged
pass "preferences migration publishes a recoverable target backup before successful import"

prepare_preferences_case "$TEST_ROOT/preferences source probe failure"
if run_preferences_case probe-fail absent success success success > "$PREF_RESULT_LOG" 2>&1; then
  fail "preferences migration treated a failed source presence probe as absent"
fi
assert_file_absent "$PREF_BACKUP_ROOT"
assert_preferences_not_imported
assert_contains "$PREF_RESULT_LOG" 'Source domain: failed.'
assert_not_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
PREF_FAILURE_LOGS+=("$PREF_RESULT_LOG")
pass "preferences migration fails closed on source-domain presence probe failure"

for source_export_mode in nonzero no-file empty; do
  prepare_preferences_case "$TEST_ROOT/preferences source export $source_export_mode"
  if run_preferences_case present absent "$source_export_mode" success success \
    > "$PREF_RESULT_LOG" 2>&1; then
    fail "preferences migration accepted source export mode $source_export_mode"
  fi
  assert_file_absent "$PREF_SOURCE_EXPORT"
  assert_preferences_not_imported
  assert_contains "$PREF_RESULT_LOG" 'Source domain: failed.'
  assert_contains "$PREF_RESULT_LOG" 'Import: skipped.'
  assert_not_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
  PREF_FAILURE_LOGS+=("$PREF_RESULT_LOG")
  PREF_EXPORT_FAILURE_DEFAULTS_LOGS+=("$PREF_DEFAULTS_LOG")
  case "$source_export_mode" in
    nonzero) pass "preferences migration rejects a nonzero source export" ;;
    no-file) pass "preferences migration rejects a zero-status source export with no plist" ;;
    empty) pass "preferences migration rejects an empty source export plist" ;;
  esac
done

prepare_preferences_case "$TEST_ROOT/preferences target probe failure"
if run_preferences_case present probe-fail success success success > "$PREF_RESULT_LOG" 2>&1; then
  fail "preferences migration accepted failed target presence probe"
fi
assert_file_absent "$PREF_BACKUP_ROOT"
assert_preferences_not_imported
assert_contains "$PREF_RESULT_LOG" 'Target domain: failed.'
assert_not_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
PREF_FAILURE_LOGS+=("$PREF_RESULT_LOG")
pass "preferences migration fails closed on target-domain presence probe failure"

for target_export_mode in nonzero no-file empty; do
  prepare_preferences_case "$TEST_ROOT/preferences target export $target_export_mode"
  if run_preferences_case present present success "$target_export_mode" success \
    > "$PREF_RESULT_LOG" 2>&1; then
    fail "preferences migration accepted target backup mode $target_export_mode"
  fi
  assert_file_exists "$PREF_SOURCE_EXPORT"
  assert_file_absent "$PREF_TARGET_EXPORT"
  assert_preferences_not_imported
  assert_contains "$PREF_RESULT_LOG" 'Source domain: exported.'
  assert_contains "$PREF_RESULT_LOG" 'Target domain: failed.'
  assert_contains "$PREF_RESULT_LOG" 'Import: skipped.'
  assert_not_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
  PREF_FAILURE_LOGS+=("$PREF_RESULT_LOG")
  PREF_EXPORT_FAILURE_DEFAULTS_LOGS+=("$PREF_DEFAULTS_LOG")
  case "$target_export_mode" in
    nonzero) pass "preferences migration rejects a nonzero target recovery export" ;;
    no-file) pass "preferences migration rejects a zero-status target export with no recovery plist" ;;
    empty) pass "preferences migration rejects an empty target recovery plist" ;;
  esac
done

prepare_preferences_case "$TEST_ROOT/preferences import failure"
if run_preferences_case present present success success failure > "$PREF_RESULT_LOG" 2>&1; then
  fail "preferences migration accepted a failed import"
fi
assert_file_exists "$PREF_SOURCE_EXPORT"
assert_file_exists "$PREF_TARGET_EXPORT"
assert_preferences_target_unchanged
assert_contains "$PREF_RESULT_LOG" 'Import: failed.'
assert_contains "$PREF_RESULT_LOG" "recover xmux preferences from: $PREF_TARGET_EXPORT"
assert_contains "$PREF_RESULT_LOG" "Target backup path: $PREF_TARGET_EXPORT"
assert_not_contains "$PREF_RESULT_LOG" 'Import: succeeded.'
PREF_FAILURE_LOGS+=("$PREF_RESULT_LOG")
pass "preferences import failure preserves and reports the exact recovery backup"

for defaults_log in "${PREF_EXPORT_FAILURE_DEFAULTS_LOGS[@]}"; do
  if /usr/bin/grep -q '^import ' "$defaults_log"; then
    fail "preferences import ran after required export failure: $defaults_log"
  fi
done
pass "preferences import is never called after any required source or target export failure"

for failure_log in "${PREF_FAILURE_LOGS[@]}"; do
  assert_not_contains "$failure_log" 'Import: succeeded.'
  assert_not_contains "$failure_log" 'No shared settings, credential, or Keychain material was copied.'
done
pass "preferences failure receipts never print migration success"

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

make_stub "$STUB_DIR/osascript-uninstall" \
  ': "${XMUX_TEST_PROCESS_STATE:?}"' \
  '[[ -z "${XMUX_TEST_PROCESS_QUERY_LOG:-}" ]] || printf "%s\n" "$*" >> "$XMUX_TEST_PROCESS_QUERY_LOG"' \
  'state="$(<"$XMUX_TEST_PROCESS_STATE")"' \
  'case "$state" in' \
  '  exact-dry|exact-exits|exact-refuses) printf "%s\n" 4242 ;;' \
  '  foreign) printf "%s\n" 4343 ;;' \
  '  stale) printf "%s\n" 999999 ;;' \
  '  stopped) exit 0 ;;' \
  '  *) exit 91 ;;' \
  'esac'
make_stub "$STUB_DIR/lsof-uninstall" \
  'pid=""' \
  'while [[ "$#" -gt 0 ]]; do if [[ "$1" == -p ]]; then pid="$2"; break; fi; shift; done' \
  'case "$pid" in' \
  '  4242) printf "p4242\nftxt\nn%s\n" "${XMUX_TEST_EXPECTED_EXECUTABLE:?}" ;;' \
  '  4343) printf "p4343\nftxt\nn%s\n" "${XMUX_TEST_FOREIGN_EXECUTABLE:?}" ;;' \
  '  *) exit 1 ;;' \
  'esac'
make_stub "$STUB_DIR/ps-uninstall" \
  '[[ "$*" != *999999* ]]'
make_stub "$STUB_DIR/kill-uninstall" \
  ': "${XMUX_TEST_PROCESS_STATE:?}"' \
  '[[ -z "${XMUX_TEST_KILL_LOG:-}" ]] || printf "%s\n" "$*" >> "$XMUX_TEST_KILL_LOG"' \
  'state="$(<"$XMUX_TEST_PROCESS_STATE")"' \
  'if [[ "$state" == exact-exits ]]; then printf "%s\n" stopped > "$XMUX_TEST_PROCESS_STATE"; fi' \
  'exit 0'

prepare_uninstall_fixture() {
  UNINSTALL_ROOT="$1"
  UNINSTALL_APP="$UNINSTALL_ROOT/Applications/xmux.app"
  UNINSTALL_OFFICIAL="$UNINSTALL_ROOT/Applications/cmux.app"
  UNINSTALL_CLI="$UNINSTALL_ROOT/home/.local/bin/xmux"
  UNINSTALL_DERIVED="$UNINSTALL_ROOT/DerivedData/cmux-xmux-main"
  UNINSTALL_SUPPORT="$UNINSTALL_ROOT/Application Support/cmux"
  UNINSTALL_SOCKET="$UNINSTALL_ROOT/cmux-debug-xmux-main.sock"
  UNINSTALL_DAEMON="$UNINSTALL_ROOT/cmuxd.sock"
  UNINSTALL_SHARED_CMUX="$UNINSTALL_ROOT/home/.config/cmux/cmux.json"
  UNINSTALL_SHARED_GHOSTTY="$UNINSTALL_ROOT/home/.config/ghostty/config"
  UNINSTALL_PROCESS_STATE="$UNINSTALL_ROOT/process-state"
  UNINSTALL_QUERY_LOG="$UNINSTALL_ROOT/process-query.log"
  UNINSTALL_KILL_LOG="$UNINSTALL_ROOT/kill.log"
  make_app "$UNINSTALL_APP" 'com.cmuxterm.app.debug.xmux-main' 'xmux'
  /usr/bin/plutil -replace LSEnvironment.CMUX_BUNDLED_CLI_PATH -string \
    "$UNINSTALL_APP/Contents/Resources/bin/cmux" "$UNINSTALL_APP/Contents/Info.plist"
  /usr/bin/plutil -replace LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string \
    "$UNINSTALL_APP/Contents/Resources/shell-integration" "$UNINSTALL_APP/Contents/Info.plist"
  /bin/mkdir -p "$UNINSTALL_OFFICIAL" "$(dirname "$UNINSTALL_CLI")" "$UNINSTALL_DERIVED" \
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
}

run_uninstall_fixture() {
  env \
    XMUX_INSTALLED_APP="$UNINSTALL_APP" \
    XMUX_OFFICIAL_APP="$UNINSTALL_OFFICIAL" \
    XMUX_CLI_PATH="$UNINSTALL_CLI" \
    XMUX_DERIVED_DATA="$UNINSTALL_DERIVED" \
    XMUX_APPLICATION_SUPPORT="$UNINSTALL_SUPPORT" \
    XMUX_SOCKET_ROOT="$UNINSTALL_ROOT" \
    XMUX_SOCKET_PATH="$UNINSTALL_SOCKET" \
    XMUX_DAEMON_SOCKET="$UNINSTALL_DAEMON" \
    XMUX_SHARED_CMUX_SETTINGS="$UNINSTALL_SHARED_CMUX" \
    XMUX_SHARED_GHOSTTY_SETTINGS="$UNINSTALL_SHARED_GHOSTTY" \
    XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-uninstall" \
    XMUX_LSOF_BIN="$STUB_DIR/lsof-uninstall" \
    XMUX_PS_BIN="$STUB_DIR/ps-uninstall" \
    XMUX_KILL_BIN="$STUB_DIR/kill-uninstall" \
    XMUX_SLEEP_BIN=/usr/bin/true \
    XMUX_QUIT_TIMEOUT_SECONDS=2 \
    XMUX_SUDO_BIN="$STUB_DIR/sudo" \
    XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
    XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" \
    XMUX_TEST_PROCESS_STATE="$UNINSTALL_PROCESS_STATE" \
    XMUX_TEST_PROCESS_QUERY_LOG="$UNINSTALL_QUERY_LOG" \
    XMUX_TEST_KILL_LOG="$UNINSTALL_KILL_LOG" \
    XMUX_TEST_EXPECTED_EXECUTABLE="$UNINSTALL_APP/Contents/MacOS/xmux-test-executable" \
    XMUX_TEST_FOREIGN_EXECUTABLE="$UNINSTALL_ROOT/Other.app/Contents/MacOS/xmux" \
    "$XMUX_DIR/11_OPTIONAL_uninstall_xmux.sh" "$@"
}

prepare_uninstall_fixture "$TEST_ROOT/uninstall dry active"
printf '%s\n' exact-dry > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux --dry-run > "$UNINSTALL_ROOT/dry-run.log"
assert_file_exists "$UNINSTALL_APP/marker"
assert_file_exists "$UNINSTALL_CLI"
assert_file_exists "$UNINSTALL_DERIVED"
assert_file_absent "$UNINSTALL_KILL_LOG"
assert_contains "$UNINSTALL_ROOT/dry-run.log" 'DRY RUN: exact xmux process check found pid(s): 4242'
pass "uninstall dry-run validates exact active xmux without process or filesystem mutation"

prepare_uninstall_fixture "$TEST_ROOT/uninstall stopped"
printf '%s\n' stopped > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux > /dev/null
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
assert_file_absent "$UNINSTALL_KILL_LOG"
pass "uninstall removes scoped state when exact xmux is not running"

prepare_uninstall_fixture "$TEST_ROOT/uninstall exits"
printf '%s\n' exact-exits > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux > "$UNINSTALL_ROOT/uninstall.log"
assert_contains "$UNINSTALL_KILL_LOG" '-TERM 4242'
assert_contains "$UNINSTALL_ROOT/uninstall.log" 'Exact xmux process exited.'
assert_file_absent "$UNINSTALL_APP"
assert_file_exists "$UNINSTALL_OFFICIAL/marker"
pass "uninstall requests only exact xmux to quit and removes files after verified exit"

prepare_uninstall_fixture "$TEST_ROOT/uninstall refuses"
printf '%s\n' exact-refuses > "$UNINSTALL_PROCESS_STATE"
if run_uninstall_fixture --confirm-remove-xmux > "$UNINSTALL_ROOT/refuses.log" 2>&1; then
  fail "uninstall continued while exact xmux refused to exit"
fi
assert_contains "$UNINSTALL_KILL_LOG" '-TERM 4242'
assert_contains "$UNINSTALL_ROOT/refuses.log" 'nothing was removed'
assert_file_exists "$UNINSTALL_APP/marker"
assert_file_exists "$UNINSTALL_CLI"
assert_file_exists "$UNINSTALL_DERIVED"
assert_file_exists "$UNINSTALL_SOCKET"
assert_file_exists "$UNINSTALL_DAEMON"
assert_file_exists "$UNINSTALL_SUPPORT/session-com.cmuxterm.app.debug.xmux-main.json"
pass "uninstall aborts with zero deletion when exact xmux remains active"

prepare_uninstall_fixture "$TEST_ROOT/uninstall official running"
printf '%s\n' stopped > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux > /dev/null
assert_file_exists "$UNINSTALL_OFFICIAL/marker"
assert_file_absent "$UNINSTALL_KILL_LOG"
assert_not_contains "$UNINSTALL_QUERY_LOG" 'bundle identifier is \"com.cmuxterm.app\"'
pass "uninstall permits running official cmux without querying or stopping it"

prepare_uninstall_fixture "$TEST_ROOT/uninstall foreign process"
printf '%s\n' foreign > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux > /dev/null
assert_file_absent "$UNINSTALL_APP"
assert_file_absent "$UNINSTALL_KILL_LOG"
pass "uninstall ignores a same-bundle PID whose executable is not installed xmux"

prepare_uninstall_fixture "$TEST_ROOT/uninstall stale pid"
printf '%s\n' stale > "$UNINSTALL_PROCESS_STATE"
run_uninstall_fixture --confirm-remove-xmux > /dev/null
assert_file_absent "$UNINSTALL_APP"
assert_file_absent "$UNINSTALL_KILL_LOG"
pass "uninstall does not treat a stale PID as exact xmux"

make_stub "$STUB_DIR/make-socket" \
  '/bin/rm -f "$1"' \
  '/usr/bin/perl -MIO::Socket::UNIX -MSocket=SOCK_STREAM -e '\''my $path = shift @ARGV; my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $path, Listen => 1) or die "socket: $!\n"; close $socket;'\'' "$1"'
make_stub "$STUB_DIR/osascript-launch" \
  ': "${XMUX_TEST_PROCESS_STATE:?}"' \
  'state="$(<"$XMUX_TEST_PROCESS_STATE")"' \
  '[[ "$state" == exact ]] && printf "%s\n" 5252' \
  'exit 0'
make_stub "$STUB_DIR/lsof-launch" \
  'if [[ "${1:-}" == -t ]]; then' \
  '  owner="$(<"${XMUX_TEST_SOCKET_OWNER_STATE:?}")"' \
  '  case "$owner" in exact) printf "%s\n" 5252 ;; foreign) printf "%s\n" 5353 ;; none) exit 1 ;; *) exit 92 ;; esac' \
  '  exit 0' \
  'fi' \
  'pid=""' \
  'while [[ "$#" -gt 0 ]]; do if [[ "$1" == -p ]]; then pid="$2"; break; fi; shift; done' \
  'case "$pid" in' \
  '  5252) printf "p5252\nftxt\nn%s\n" "${XMUX_TEST_EXPECTED_EXECUTABLE:?}" ;;' \
  '  5353) printf "p5353\nftxt\nn%s\n" "${XMUX_TEST_FOREIGN_EXECUTABLE:?}" ;;' \
  '  *) exit 1 ;;' \
  'esac'
make_stub "$STUB_DIR/ps-launch" 'exit 0'
make_stub "$STUB_DIR/open-launch" \
  ': "${XMUX_TEST_LAUNCH_MODE:?}"' \
  '[[ -z "${XMUX_TEST_OPEN_LOG:-}" ]] || printf "%s\n" "$*" >> "$XMUX_TEST_OPEN_LOG"' \
  'case "$XMUX_TEST_LAUNCH_MODE" in' \
  '  healthy|failed-ping)' \
  '    printf "%s\n" exact > "${XMUX_TEST_PROCESS_STATE:?}"' \
  '    "${XMUX_TEST_MAKE_SOCKET:?}" "${XMUX_SOCKET_PATH:?}"' \
  '    printf "%s\n" exact > "${XMUX_TEST_SOCKET_OWNER_STATE:?}"' \
  '    if [[ "$XMUX_TEST_LAUNCH_MODE" == healthy ]]; then printf "%s\n" healthy > "${XMUX_TEST_PING_STATE:?}"; else printf "%s\n" failed > "${XMUX_TEST_PING_STATE:?}"; fi' \
  '    ;;' \
  '  process-only) printf "%s\n" exact > "${XMUX_TEST_PROCESS_STATE:?}" ;;' \
  '  timeout) ;;' \
  '  *) exit 93 ;;' \
  'esac'

prepare_launch_fixture() {
  LAUNCH_ROOT="$1"
  LAUNCH_APP="$LAUNCH_ROOT/Applications/xmux.app"
  LAUNCH_OFFICIAL="$LAUNCH_ROOT/Applications/cmux.app"
  LAUNCH_SOCKET="$LAUNCH_ROOT/cmux-debug-xmux-main.sock"
  LAUNCH_CLI="$LAUNCH_ROOT/bin/xmux"
  LAUNCH_PROCESS_STATE="$LAUNCH_ROOT/process-state"
  LAUNCH_SOCKET_OWNER_STATE="$LAUNCH_ROOT/socket-owner-state"
  LAUNCH_PING_STATE="$LAUNCH_ROOT/ping-state"
  LAUNCH_OPEN_LOG="$LAUNCH_ROOT/open.log"
  LAUNCH_PING_LOG="$LAUNCH_ROOT/ping.log"
  LAUNCH_ZSHRC="$LAUNCH_ROOT/home/.zshrc"
  make_app "$LAUNCH_APP" 'com.cmuxterm.app.debug.xmux-main' 'xmux'
  /bin/mkdir -p "$LAUNCH_OFFICIAL" "$(dirname "$LAUNCH_CLI")"
  /usr/bin/plutil -replace LSEnvironment.CMUX_BUNDLED_CLI_PATH -string \
    "$LAUNCH_APP/Contents/Resources/bin/cmux" "$LAUNCH_APP/Contents/Info.plist"
  /usr/bin/plutil -replace LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string \
    "$LAUNCH_APP/Contents/Resources/shell-integration" "$LAUNCH_APP/Contents/Info.plist"
  make_stub "$LAUNCH_APP/Contents/Resources/bin/cmux" \
    '[[ "${1:-}" == --socket ]] || exit 80' \
    '[[ "${2:-}" == "${XMUX_SOCKET_PATH:?}" ]] || exit 81' \
    'shift 2' \
    '[[ -z "${XMUX_TEST_PING_LOG:-}" ]] || printf "%s\n" "$*" >> "$XMUX_TEST_PING_LOG"' \
    '[[ "$(<"${XMUX_TEST_PING_STATE:?}")" == healthy ]] || exit 1' \
    'printf "%s\n" PONG'
  env XMUX_INSTALLED_APP="$LAUNCH_APP" \
    XMUX_OFFICIAL_APP="$LAUNCH_OFFICIAL" \
    XMUX_CLI_PATH="$LAUNCH_CLI" \
    XMUX_ZSHRC="$LAUNCH_ZSHRC" \
    XMUX_SOCKET_PATH="$LAUNCH_SOCKET" \
    "$XMUX_DIR/05_install_xmux_cli.sh" > /dev/null
  printf '%s\n' stopped > "$LAUNCH_PROCESS_STATE"
  printf '%s\n' none > "$LAUNCH_SOCKET_OWNER_STATE"
  printf '%s\n' failed > "$LAUNCH_PING_STATE"
}

run_launch_fixture() {
  env \
    XMUX_INSTALLED_APP="$LAUNCH_APP" \
    XMUX_OFFICIAL_APP="$LAUNCH_OFFICIAL" \
    XMUX_SOCKET_ROOT="$LAUNCH_ROOT" \
    XMUX_SOCKET_PATH="$LAUNCH_SOCKET" \
    XMUX_CLI_PATH="$LAUNCH_CLI" \
    XMUX_CODESIGN_BIN="$STUB_DIR/codesign-ok" \
    XMUX_OSASCRIPT_BIN="$STUB_DIR/osascript-launch" \
    XMUX_LSOF_BIN="$STUB_DIR/lsof-launch" \
    XMUX_PS_BIN="$STUB_DIR/ps-launch" \
    XMUX_OPEN_BIN="$STUB_DIR/open-launch" \
    XMUX_SLEEP_BIN=/usr/bin/true \
    XMUX_RM_BIN="${XMUX_TEST_LAUNCH_RM_BIN:-/bin/rm}" \
    XMUX_LAUNCH_TIMEOUT_SECONDS=2 \
    XMUX_PING_TIMEOUT_SECONDS=1 \
    XMUX_TEST_PROCESS_STATE="$LAUNCH_PROCESS_STATE" \
    XMUX_TEST_SOCKET_OWNER_STATE="$LAUNCH_SOCKET_OWNER_STATE" \
    XMUX_TEST_PING_STATE="$LAUNCH_PING_STATE" \
    XMUX_TEST_OPEN_LOG="$LAUNCH_OPEN_LOG" \
    XMUX_TEST_PING_LOG="$LAUNCH_PING_LOG" \
    XMUX_TEST_MAKE_SOCKET="$STUB_DIR/make-socket" \
    XMUX_TEST_EXPECTED_EXECUTABLE="$LAUNCH_APP/Contents/MacOS/xmux-test-executable" \
    XMUX_TEST_FOREIGN_EXECUTABLE="$LAUNCH_ROOT/Other.app/Contents/MacOS/xmux" \
    XMUX_TEST_LAUNCH_MODE="${XMUX_TEST_LAUNCH_MODE:-timeout}" \
    "$XMUX_DIR/06_launch_and_verify_xmux.sh"
}

prepare_launch_fixture "$TEST_ROOT/launch stale socket"
make_socket_path "$LAUNCH_SOCKET"
stale_identity="$(/usr/bin/stat -f '%d:%i' "$LAUNCH_SOCKET")"
XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log"
new_identity="$(/usr/bin/stat -f '%d:%i' "$LAUNCH_SOCKET")"
[[ "$stale_identity" != "$new_identity" ]] || fail "stale socket inode was not replaced"
assert_contains "$LAUNCH_ROOT/result.log" 'Removed unowned stale xmux socket:'
assert_contains "$LAUNCH_ROOT/result.log" 'Readiness: exact process, exact socket owner, and PONG verified.'
assert_equals "$(<"$LAUNCH_PING_LOG")" 'ping'
pass "launch removes only an unowned stale socket and requires a new owned PONG-ready socket"

prepare_launch_fixture "$TEST_ROOT/launch non socket"
printf '%s\n' keep > "$LAUNCH_SOCKET"
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted a non-socket object"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_SOCKET" keep
pass "launch rejects a non-socket object before opening xmux"

prepare_launch_fixture "$TEST_ROOT/launch foreign socket"
make_socket_path "$LAUNCH_SOCKET"
printf '%s\n' foreign > "$LAUNCH_SOCKET_OWNER_STATE"
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted a foreign-owned socket"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" "refusing pre-launch xmux socket state 'foreign'"
pass "launch rejects a socket owned by an unrelated process"

prepare_launch_fixture "$TEST_ROOT/launch existing healthy"
make_socket_path "$LAUNCH_SOCKET"
printf '%s\n' exact > "$LAUNCH_PROCESS_STATE"
printf '%s\n' exact > "$LAUNCH_SOCKET_OWNER_STATE"
printf '%s\n' healthy > "$LAUNCH_PING_STATE"
XMUX_TEST_LAUNCH_MODE=timeout run_launch_fixture > "$LAUNCH_ROOT/result.log"
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'Launch result: existing exact xmux verified; no new launch'
assert_equals "$(<"$LAUNCH_PING_LOG")" 'ping'
pass "launch verifies an already-running exact xmux without claiming a new launch"

prepare_launch_fixture "$TEST_ROOT/launch new healthy"
[[ "$LAUNCH_APP" == *' '* && "$LAUNCH_SOCKET" == *' '* ]] \
  || fail "launch integration fixture did not include spaces in both paths"
expected_launch_wrapper="$(
  # shellcheck source=xmux/lib/common.sh
  source "$XMUX_DIR/lib/common.sh"
  xmux_render_cli_wrapper "$LAUNCH_APP/Contents/Resources/bin/cmux" "$LAUNCH_SOCKET"
)"
assert_equals "$(<"$LAUNCH_CLI")" "$expected_launch_wrapper"
XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log"
assert_file_exists "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'Launch result: launched and verified'
assert_equals "$(<"$LAUNCH_PING_LOG")" 'ping'
pass "launch verifies a newly started exact xmux with a live owned socket and PONG"
pass "real 05 to 06 integration accepts canonical app and socket paths containing spaces"

prepare_launch_fixture "$TEST_ROOT/launch wrong wrapper executable"
render_wrapper "$LAUNCH_CLI" "$LAUNCH_ROOT/Wrong.app/Contents/Resources/bin/cmux" "$LAUNCH_SOCKET"
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted a wrapper with a modified executable path"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux CLI wrapper content is not canonical'
pass "launch validation rejects a modified wrapper executable path"

prepare_launch_fixture "$TEST_ROOT/launch wrong wrapper socket"
render_wrapper "$LAUNCH_CLI" "$LAUNCH_APP/Contents/Resources/bin/cmux" "$LAUNCH_ROOT/wrong.sock"
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted a wrapper with a modified socket path"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux CLI wrapper content is not canonical'
pass "launch validation rejects a modified wrapper socket path"

prepare_launch_fixture "$TEST_ROOT/launch malformed wrapper"
make_stub "$LAUNCH_CLI" 'this is not a canonical wrapper'
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted a malformed wrapper"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux CLI wrapper content is not canonical'
pass "launch validation rejects a malformed wrapper"

prepare_launch_fixture "$TEST_ROOT/launch raw path comments"
make_stub "$LAUNCH_CLI" \
  "# $LAUNCH_APP/Contents/Resources/bin/cmux" \
  "# --socket $LAUNCH_SOCKET" \
  'printf "%s\n" PONG'
if XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1; then
  fail "launch accepted raw-path comments instead of the canonical wrapper"
fi
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux CLI wrapper content is not canonical'
pass "raw-path comments and unrelated lines cannot satisfy wrapper validation"

prepare_launch_fixture "$TEST_ROOT/launch failed ping"
XMUX_TEST_LAUNCH_MODE=failed-ping run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1 && \
  fail "launch accepted a newly owned socket whose ping failed"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux readiness timed out'
assert_not_contains "$LAUNCH_ROOT/result.log" 'Launch result:'
pass "launch fails when a newly created exact-owned socket does not answer PONG"

prepare_launch_fixture "$TEST_ROOT/launch old socket survives"
make_socket_path "$LAUNCH_SOCKET"
XMUX_TEST_LAUNCH_RM_BIN=/usr/bin/true XMUX_TEST_LAUNCH_MODE=healthy \
  run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1 && \
  fail "launch accepted an old stale socket path that survived removal"
assert_file_absent "$LAUNCH_OPEN_LOG"
assert_contains "$LAUNCH_ROOT/result.log" 'stale xmux socket could not be removed safely'
pass "launch rejects an old socket pathname that survives without replacement"

prepare_launch_fixture "$TEST_ROOT/launch timeout"
XMUX_TEST_LAUNCH_MODE=timeout run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1 && \
  fail "launch accepted a readiness timeout"
assert_contains "$LAUNCH_ROOT/result.log" 'xmux readiness timed out after 2s'
assert_not_contains "$LAUNCH_ROOT/result.log" 'Launch result:'
pass "launch returns nonzero with content-free diagnostics on bounded timeout"

prepare_launch_fixture "$TEST_ROOT/launch outside socket root"
/bin/mkdir -p "$TEST_ROOT/outside socket root"
LAUNCH_SOCKET="$TEST_ROOT/outside socket root/cmux-debug-xmux-main.sock"
printf '%s\n' keep > "$LAUNCH_SOCKET"
XMUX_TEST_LAUNCH_MODE=healthy run_launch_fixture > "$LAUNCH_ROOT/result.log" 2>&1 && \
  fail "launch accepted a socket override outside its guarded root"
assert_contains "$LAUNCH_SOCKET" keep
assert_file_absent "$LAUNCH_OPEN_LOG"
pass "launch never removes an arbitrary socket override outside the guarded custom root"

DRY_BACKUP_ROOT="$TEST_ROOT/dry-backup"
DRY_BACKUP_PATH="$DRY_BACKUP_ROOT/cmux-backup-20260722-130000"
env XMUX_BACKUP_ROOT="$DRY_BACKUP_ROOT" XMUX_TIMESTAMP='20260722-130000' \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" XMUX_GHOSTTY_CONFIG_DIR="$CONFIG_ROOT/ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  "$XMUX_DIR/01_backup_existing_cmux.sh" --dry-run > "$TEST_ROOT/dry-backup.log"
assert_contains "$TEST_ROOT/dry-backup.log" 'Official defaults: present; export planned.'
assert_contains "$TEST_ROOT/dry-backup.log" "Planned backup path: $DRY_BACKUP_PATH"
assert_contains "$TEST_ROOT/dry-backup.log" 'Dry run only; no backup was created.'
pass "backup dry-run with present defaults uses explicit planned wording"
assert_file_absent "$DRY_BACKUP_ROOT"
pass "backup --dry-run causes no mutation"
assert_file_absent "$DRY_BACKUP_PATH/com.cmuxterm.app.plist"
pass "backup dry-run never publishes a defaults plist"
assert_not_contains "$TEST_ROOT/dry-backup.log" 'Official defaults: present; exported.'
assert_not_contains "$TEST_ROOT/dry-backup.log" "Backup path: $DRY_BACKUP_PATH"
assert_not_contains "$TEST_ROOT/dry-backup.log" 'backup created'
assert_not_contains "$TEST_ROOT/dry-backup.log" 'backup available'
pass "backup dry-run emits no actual-backup success wording"

DRY_ABSENT_BACKUP_ROOT="$TEST_ROOT/dry-backup-absent"
DRY_ABSENT_BACKUP_PATH="$DRY_ABSENT_BACKUP_ROOT/cmux-backup-20260722-130001"
env XMUX_BACKUP_ROOT="$DRY_ABSENT_BACKUP_ROOT" XMUX_TIMESTAMP='20260722-130001' \
  XMUX_CMUX_CONFIG_DIR="$CONFIG_ROOT/cmux" XMUX_GHOSTTY_CONFIG_DIR="$CONFIG_ROOT/ghostty" \
  XMUX_APPLICATION_SUPPORT="$APP_SUPPORT" XMUX_DEFAULTS_BIN="$STUB_DIR/defaults" \
  XMUX_TEST_DEFAULTS_MODE=absent \
  "$XMUX_DIR/01_backup_existing_cmux.sh" --dry-run > "$TEST_ROOT/dry-backup-absent.log"
assert_file_absent "$DRY_ABSENT_BACKUP_ROOT"
assert_contains "$TEST_ROOT/dry-backup-absent.log" 'Official defaults: absent; would skip.'
assert_contains "$TEST_ROOT/dry-backup-absent.log" "Planned backup path: $DRY_ABSENT_BACKUP_PATH"
assert_contains "$TEST_ROOT/dry-backup-absent.log" 'Dry run only; no backup was created.'
assert_not_contains "$TEST_ROOT/dry-backup-absent.log" 'Official defaults: present; exported.'
pass "backup dry-run with absent defaults reports would-skip and creates nothing"

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
