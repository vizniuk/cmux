#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

xmux_parse_dry_run "$@"
xmux_require_safe_destructive_target "$XMUX_INSTALLED_APP"

installed_cli="$XMUX_INSTALLED_APP/Contents/Resources/bin/cmux"
[[ -x "$installed_cli" ]] || xmux_die "installed xmux CLI is missing: $installed_cli"

cli_directory="$(dirname "$XMUX_CLI_PATH")"
temporary_wrapper="$cli_directory/.xmux-wrapper.$$"
path_line="export PATH=\"${cli_directory}:\$PATH\" # xmux operations kit"
xmux_require_safe_destructive_target "$XMUX_CLI_PATH"
xmux_require_safe_destructive_target "$temporary_wrapper"
xmux_require_safe_destructive_target "$XMUX_ZSHRC"

if [[ "$XMUX_DRY_RUN" -eq 1 ]]; then
  xmux_print_command /bin/mkdir -p "$cli_directory"
  xmux_note "DRY RUN: write wrapper $XMUX_CLI_PATH"
  xmux_note "DRY RUN: wrapper exec $installed_cli --socket $XMUX_SOCKET_PATH"
  xmux_note "DRY RUN: ensure PATH line in $XMUX_ZSHRC"
  exit 0
fi

/bin/mkdir -p "$cli_directory"
(
  umask 022
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'exec %q --socket %q "$@"\n' "$installed_cli" "$XMUX_SOCKET_PATH"
  } > "$temporary_wrapper"
)
/bin/chmod 0755 "$temporary_wrapper"
/bin/mv "$temporary_wrapper" "$XMUX_CLI_PATH"

/bin/mkdir -p "$(dirname "$XMUX_ZSHRC")"
/usr/bin/touch "$XMUX_ZSHRC"
if ! /usr/bin/grep -Fqx "$path_line" "$XMUX_ZSHRC"; then
  printf '\n%s\n' "$path_line" >> "$XMUX_ZSHRC"
fi

PATH="$cli_directory:$PATH"
export PATH
hash -r
resolved_cli="$(command -v xmux || true)"
[[ "$resolved_cli" == "$XMUX_CLI_PATH" ]] \
  || xmux_die "command -v xmux resolved to '$resolved_cli', expected '$XMUX_CLI_PATH'"

xmux_note "Installed xmux CLI wrapper: $XMUX_CLI_PATH"
xmux_note "Wrapper socket: $XMUX_SOCKET_PATH"
xmux_note "Official cmux command was not modified."
