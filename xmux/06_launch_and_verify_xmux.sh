#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$#" -eq 0 ]] || xmux_die "usage: $(basename "$0")"
xmux_require_safe_destructive_target "$XMUX_INSTALLED_APP"
xmux_require_safe_socket_target "$XMUX_SOCKET_PATH"
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

exact_pids="$(xmux_require_exact_process_query)"
prelaunch_socket_state="$(xmux_socket_state "$XMUX_SOCKET_PATH")" \
  || xmux_die "cannot establish pre-launch socket ownership: $XMUX_SOCKET_PATH"
prelaunch_socket_identity=""
if [[ -S "$XMUX_SOCKET_PATH" ]]; then
  prelaunch_socket_identity="$(xmux_path_identity "$XMUX_SOCKET_PATH")" \
    || xmux_die "cannot read pre-launch socket identity: $XMUX_SOCKET_PATH"
fi

launch_result="launched and verified"
if [[ -n "$exact_pids" ]]; then
  [[ "$prelaunch_socket_state" == "exact" ]] \
    || xmux_die "exact xmux is running but socket state is $prelaunch_socket_state: $XMUX_SOCKET_PATH"
  xmux_ping_socket \
    || xmux_die "exact xmux socket owner did not answer PONG: $XMUX_SOCKET_PATH"
  launch_result="existing exact xmux verified; no new launch"
else
  case "$prelaunch_socket_state" in
    absent) ;;
    stale)
      "$XMUX_RM_BIN" -f "$XMUX_SOCKET_PATH"
      [[ ! -e "$XMUX_SOCKET_PATH" && ! -L "$XMUX_SOCKET_PATH" ]] \
        || xmux_die "stale xmux socket could not be removed safely: $XMUX_SOCKET_PATH"
      xmux_note "Removed unowned stale xmux socket: $XMUX_SOCKET_PATH"
      ;;
    non-socket)
      xmux_die "refusing non-socket object at xmux socket path: $XMUX_SOCKET_PATH"
      ;;
    foreign|unsafe-symlink|exact)
      xmux_die "refusing pre-launch xmux socket state '$prelaunch_socket_state': $XMUX_SOCKET_PATH"
      ;;
    *) xmux_die "unknown pre-launch xmux socket state: $prelaunch_socket_state" ;;
  esac

  "$XMUX_OPEN_BIN" "$XMUX_INSTALLED_APP"
  elapsed=0
  ready=0
  last_socket_state="absent"
  while [[ "$elapsed" -lt "$launch_timeout" ]]; do
    running_pids="$(xmux_require_exact_process_query)"
    last_socket_state="$(xmux_socket_state "$XMUX_SOCKET_PATH")" \
      || xmux_die "cannot establish xmux socket ownership during launch"
    case "$last_socket_state" in
      foreign|non-socket|unsafe-symlink)
        xmux_die "unsafe xmux socket state during launch: $last_socket_state"
        ;;
    esac
    if [[ -n "$running_pids" && "$last_socket_state" == "exact" ]]; then
      current_socket_identity="$(xmux_path_identity "$XMUX_SOCKET_PATH")" \
        || xmux_die "cannot read launched socket identity"
      if [[ -n "$prelaunch_socket_identity" && "$current_socket_identity" == "$prelaunch_socket_identity" ]]; then
        xmux_die "pre-launch socket inode survived without replacement"
      fi
      if xmux_ping_socket; then
        ready=1
        break
      fi
    fi
    "$XMUX_SLEEP_BIN" 1
    elapsed=$((elapsed + 1))
  done
  [[ "$ready" -eq 1 ]] \
    || xmux_die "xmux readiness timed out after ${launch_timeout}s (socket state: $last_socket_state)"
fi

source_metadata="$(xmux_plist_read "$XMUX_INSTALLED_APP" LSEnvironment.CMUX_COMMIT 2>/dev/null || true)"
[[ -n "$source_metadata" ]] || source_metadata="unavailable"

xmux_note "Bundle ID: $(xmux_plist_read "$XMUX_INSTALLED_APP" CFBundleIdentifier)"
xmux_note "Application path: $XMUX_INSTALLED_APP"
xmux_note "Source build metadata: $source_metadata"
xmux_note "Socket path: $XMUX_SOCKET_PATH"
xmux_note "CLI path: $XMUX_CLI_PATH"
xmux_note "Launch result: $launch_result"
xmux_note "Readiness: exact process, exact socket owner, and PONG verified."
