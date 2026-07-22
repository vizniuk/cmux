#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$#" -eq 0 ]] || xmux_die "usage: $(basename "$0")"
xmux_require_not_official_target "$XMUX_INSTALLED_APP"
xmux_verify_app_identity "$XMUX_INSTALLED_APP"
xmux_verify_installed_resource_paths "$XMUX_INSTALLED_APP"

[[ -x "$XMUX_CLI_PATH" ]] || xmux_die "xmux CLI wrapper is missing: $XMUX_CLI_PATH"
/usr/bin/grep -Fq "$XMUX_INSTALLED_APP/Contents/Resources/bin/cmux" "$XMUX_CLI_PATH" \
  || xmux_die "xmux CLI wrapper targets the wrong executable"
/usr/bin/grep -Fq -- "--socket $XMUX_SOCKET_PATH" "$XMUX_CLI_PATH" \
  || xmux_die "xmux CLI wrapper targets the wrong socket"

launch_timeout="${XMUX_LAUNCH_TIMEOUT_SECONDS:-20}"
case "$launch_timeout" in
  ''|*[!0-9]*) xmux_die "XMUX_LAUNCH_TIMEOUT_SECONDS must be a positive integer" ;;
esac
[[ "$launch_timeout" -gt 0 ]] || xmux_die "XMUX_LAUNCH_TIMEOUT_SECONDS must be a positive integer"

"$XMUX_OPEN_BIN" "$XMUX_INSTALLED_APP"
elapsed=0
while [[ "$elapsed" -lt "$launch_timeout" ]]; do
  [[ -S "$XMUX_SOCKET_PATH" ]] && break
  "$XMUX_SLEEP_BIN" 1
  elapsed=$((elapsed + 1))
done
[[ -S "$XMUX_SOCKET_PATH" ]] \
  || xmux_die "xmux socket unavailable after ${launch_timeout}s: $XMUX_SOCKET_PATH"

source_metadata="$(xmux_plist_read "$XMUX_INSTALLED_APP" LSEnvironment.CMUX_COMMIT 2>/dev/null || true)"
[[ -n "$source_metadata" ]] || source_metadata="unavailable"

xmux_note "Bundle ID: $(xmux_plist_read "$XMUX_INSTALLED_APP" CFBundleIdentifier)"
xmux_note "Application path: $XMUX_INSTALLED_APP"
xmux_note "Source build metadata: $source_metadata"
xmux_note "Socket path: $XMUX_SOCKET_PATH"
xmux_note "CLI path: $XMUX_CLI_PATH"
