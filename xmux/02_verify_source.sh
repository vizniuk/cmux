#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=xmux/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[[ "$#" -eq 0 ]] || xmux_die "usage: $(basename "$0")"
xmux_require_repo

origin_url="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" remote get-url origin 2>/dev/null)" \
  || xmux_die "origin remote is missing"
[[ "$origin_url" == "$XMUX_EXPECTED_ORIGIN" ]] \
  || xmux_die "unexpected origin: $origin_url"

"$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" diff --quiet \
  || xmux_die "tracked worktree is dirty"
"$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" diff --cached --quiet \
  || xmux_die "staging is not empty"

for operation_path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-apply rebase-merge; do
  resolved_operation_path="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" rev-parse --git-path "$operation_path")"
  [[ ! -e "$resolved_operation_path" ]] || xmux_die "active Git operation detected: $operation_path"
done

while IFS= read -r status_line; do
  [[ -n "$status_line" ]] || continue
  status_code="${status_line:0:2}"
  status_path="${status_line:3}"
  [[ "$status_code" == "??" ]] || xmux_die "unexpected tracked status: $status_line"
  case "$status_path" in
    .idea|.idea/*|cmux.iml) ;;
    *) xmux_die "unauthorized untracked path: $status_path" ;;
  esac
done < <("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" -c core.quotePath=false status --porcelain --untracked-files=all)

submodule_status="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" submodule status --recursive)"
if printf '%s\n' "$submodule_status" | /usr/bin/grep -Eq '^[+-U]'; then
  xmux_die "submodules are uninitialized or at unexpected commits"
fi
"$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" submodule foreach --quiet --recursive \
  'git diff --quiet && git diff --cached --quiet && test -z "$(git status --porcelain --untracked-files=all)"' \
  || xmux_die "a submodule is dirty"

head_sha="$("$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" rev-parse HEAD)"
"$XMUX_GIT_BIN" -C "$XMUX_REPO_ROOT" merge-base --is-ancestor "$XMUX_MINIMUM_BASELINE_SHA" "$head_sha" \
  || xmux_die "HEAD does not include minimum xmux baseline $XMUX_MINIMUM_BASELINE_SHA"
if [[ -n "${XMUX_EXPECTED_SHA:-}" && "$head_sha" != "$XMUX_EXPECTED_SHA" ]]; then
  xmux_die "HEAD $head_sha does not equal XMUX_EXPECTED_SHA $XMUX_EXPECTED_SHA"
fi

[[ -x "$XMUX_REPO_ROOT/scripts/reload.sh" ]] \
  || xmux_die "scripts/reload.sh is missing or not executable"

xmux_note "Verified xmux source repository: $XMUX_REPO_ROOT"
xmux_note "Source HEAD: $head_sha"
