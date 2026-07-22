#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

confirmed=0
for argument in "$@"; do
  case "$argument" in
    --confirm-remove-xmux) confirmed=1 ;;
    --dry-run) XMUX_DRY_RUN=1 ;;
    *) xmux_die "usage: $(basename "$0") --confirm-remove-xmux [--dry-run]" ;;
  esac
done
[[ "$confirmed" -eq 1 ]] \
  || xmux_die "explicit confirmation required: --confirm-remove-xmux"

xmux_note "OPTIONAL uninstall: remove only the xmux edition and its bundle-specific state."
xmux_require_not_official_target "$XMUX_INSTALLED_APP"
[[ "$XMUX_BUNDLE_ID" != "$XMUX_OFFICIAL_BUNDLE_ID" ]] \
  || xmux_die "xmux and official bundle identifiers must differ"
xmux_stop_xmux

xmux_session_primary="$(xmux_session_primary_path "$XMUX_BUNDLE_ID")"
xmux_session_previous="$(xmux_session_previous_path "$XMUX_BUNDLE_ID")"
xmux_notification_history="$(xmux_notification_history_path "$XMUX_BUNDLE_ID")"

xmux_run_as_admin /bin/rm -rf "$XMUX_INSTALLED_APP"
xmux_run /bin/rm -f "$XMUX_CLI_PATH"
xmux_run /bin/rm -rf "$XMUX_DERIVED_DATA"
xmux_run /bin/rm -f "$XMUX_SOCKET_PATH" "$XMUX_DAEMON_SOCKET"
xmux_run /bin/rm -f "$xmux_session_primary" "$xmux_session_previous" "$xmux_notification_history"
if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command "$XMUX_DEFAULTS_BIN" delete "$XMUX_BUNDLE_ID"
else
  "$XMUX_DEFAULTS_BIN" delete "$XMUX_BUNDLE_ID" >/dev/null 2>&1 || true
fi

xmux_note "Preserved official app: $XMUX_OFFICIAL_APP"
xmux_note "Preserved shared cmux settings: $XMUX_SHARED_CMUX_SETTINGS"
xmux_note "Preserved shared Ghostty settings: $XMUX_SHARED_GHOSTTY_SETTINGS"
xmux_note "Preserved official session: $(xmux_session_primary_path "$XMUX_OFFICIAL_BUNDLE_ID")"
xmux_note "Preserved official notification history: $(xmux_notification_history_path "$XMUX_OFFICIAL_BUNDLE_ID")"
