#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_require_not_official_target "$XMUX_INSTALLED_APP"
xmux_verify_app_identity "$XMUX_BUILT_APP"

install_parent="$(dirname "$XMUX_INSTALLED_APP")"
staging_app="$install_parent/.xmux.app.staging.$$"
previous_app="$install_parent/.xmux.app.previous.$$"
replacement_started=0
replacement_complete=0

cleanup_install() {
  local status=$?
  trap - EXIT
  if [[ "$XMUX_DRY_RUN" -eq 0 ]]; then
    if [[ "$replacement_started" -eq 1 && "$replacement_complete" -eq 0 && -d "$previous_app" ]]; then
      "$XMUX_SUDO_BIN" /bin/rm -rf "$XMUX_INSTALLED_APP" >/dev/null 2>&1 || true
      "$XMUX_SUDO_BIN" /bin/mv "$previous_app" "$XMUX_INSTALLED_APP" >/dev/null 2>&1 || true
    fi
    "$XMUX_SUDO_BIN" /bin/rm -rf "$staging_app" >/dev/null 2>&1 || true
    if [[ "$replacement_complete" -eq 1 ]]; then
      "$XMUX_SUDO_BIN" /bin/rm -rf "$previous_app" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup_install EXIT

xmux_stop_xmux
xmux_run_as_admin /bin/mkdir -p "$install_parent"
xmux_run_as_admin /bin/rm -rf "$staging_app"
xmux_run_as_admin "$XMUX_DITTO_BIN" "$XMUX_BUILT_APP" "$staging_app"

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command "$XMUX_PLUTIL_BIN" -replace LSEnvironment.CMUX_BUNDLED_CLI_PATH -string \
    "$XMUX_INSTALLED_APP/Contents/Resources/bin/cmux" "$staging_app/Contents/Info.plist"
  xmux_print_command "$XMUX_PLUTIL_BIN" -replace LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string \
    "$XMUX_INSTALLED_APP/Contents/Resources/shell-integration" "$staging_app/Contents/Info.plist"
  xmux_print_command "$XMUX_XATTR_BIN" -cr "$staging_app"
  xmux_print_command "$XMUX_CODESIGN_BIN" --force --deep --sign - --timestamp=none \
    --generate-entitlement-der "$staging_app"
  xmux_print_command "$XMUX_SUDO_BIN" /bin/mv "$staging_app" "$XMUX_INSTALLED_APP"
  xmux_note "Dry run complete; no application was installed."
  replacement_complete=1
  exit 0
fi

"$XMUX_SUDO_BIN" "$XMUX_PLUTIL_BIN" -replace LSEnvironment.CMUX_BUNDLED_CLI_PATH -string \
  "$XMUX_INSTALLED_APP/Contents/Resources/bin/cmux" "$staging_app/Contents/Info.plist"
"$XMUX_SUDO_BIN" "$XMUX_PLUTIL_BIN" -replace LSEnvironment.CMUX_SHELL_INTEGRATION_DIR -string \
  "$XMUX_INSTALLED_APP/Contents/Resources/shell-integration" "$staging_app/Contents/Info.plist"
"$XMUX_SUDO_BIN" "$XMUX_XATTR_BIN" -cr "$staging_app"
"$XMUX_SUDO_BIN" "$XMUX_CODESIGN_BIN" --force --deep --sign - --timestamp=none \
  --generate-entitlement-der "$staging_app"
xmux_verify_app_identity "$staging_app"
xmux_verify_installed_resource_paths "$staging_app"

"$XMUX_SUDO_BIN" /bin/rm -rf "$previous_app"
if [[ -d "$XMUX_INSTALLED_APP" ]]; then
  "$XMUX_SUDO_BIN" /bin/mv "$XMUX_INSTALLED_APP" "$previous_app"
fi
replacement_started=1
"$XMUX_SUDO_BIN" /bin/mv "$staging_app" "$XMUX_INSTALLED_APP"
xmux_verify_app_identity "$XMUX_INSTALLED_APP"
xmux_verify_installed_resource_paths "$XMUX_INSTALLED_APP"
replacement_complete=1

xmux_note "Installed xmux: $XMUX_INSTALLED_APP"
xmux_note "Official cmux preserved: $XMUX_OFFICIAL_APP"
