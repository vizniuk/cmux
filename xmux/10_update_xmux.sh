#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
old_identity="$(xmux_read_installed_identity)"
"$XMUX_OPERATIONS_DIR/02_verify_source.sh"
source_commit="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" rev-parse HEAD)"

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  "$XMUX_OPERATIONS_DIR/03_build_xmux.sh" --dry-run
  "$XMUX_OPERATIONS_DIR/04_install_xmux.sh" --dry-run
else
  "$XMUX_OPERATIONS_DIR/03_build_xmux.sh"
  "$XMUX_OPERATIONS_DIR/04_install_xmux.sh"
fi

xmux_note "xmux update receipt"
xmux_note "Previous installed identity: $old_identity"
xmux_note "New source commit: $source_commit"
xmux_note "Installed path: $XMUX_INSTALLED_APP"
xmux_note "Shared settings, defaults, sessions, notification history, and official cmux were preserved."
xmux_note "xmux was not launched. Git was not updated."
