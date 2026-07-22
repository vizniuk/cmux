#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
"$XMUX_OPERATIONS_DIR/02_verify_source.sh"
source_commit="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" rev-parse HEAD)"

reload_arguments=(
  --tag "$XMUX_BUILD_TAG"
  --name "$XMUX_APP_NAME"
  --prod-auth
  --no-global-cli-links
)
if [[ "${XMUX_SWIFT_FRONTEND_WORKAROUND:-0}" == "1" ]]; then
  reload_arguments+=(--swift-frontend-workaround)
fi

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command env CMUX_SKIP_ZIG_BUILD=1 \
    "$XMUX_REPO_ROOT/scripts/reload.sh" "${reload_arguments[@]}"
  xmux_note "Dry run source commit: $source_commit"
  exit 0
fi

CMUX_SKIP_ZIG_BUILD=1 "$XMUX_REPO_ROOT/scripts/reload.sh" "${reload_arguments[@]}"
xmux_verify_app_identity "$XMUX_BUILT_APP"

xmux_note "Built app: $XMUX_BUILT_APP"
xmux_note "Bundle identifier: $(xmux_plist_read "$XMUX_BUILT_APP" CFBundleIdentifier)"
xmux_note "Display name: $(xmux_plist_read "$XMUX_BUILT_APP" CFBundleDisplayName)"
xmux_note "Source commit: $source_commit"
xmux_note "Signature: verified"
