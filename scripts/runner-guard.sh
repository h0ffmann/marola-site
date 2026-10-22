#!/usr/bin/env bash
# runner-guard — the self-hosted runner's job-started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED): the
# runner refuses any job that is not site.yml, started by hand (workflow_dispatch) by an owner
# (admin on the repo). It runs on the machine, before any step, from a copy outside the
# workspace, so a workflow added by a pull request cannot change or skip it; a nonzero exit fails
# the job. org members' PRs run without approval, so a check inside a workflow is not enough.
#
#   scripts/runner-guard.sh                      the hook (reads the job's GITHUB_* variables)
#   scripts/runner-guard.sh --install RUNNER_DIR copy it into the runner and point .env at it
#   scripts/runner-guard.sh --self-test
set -euo pipefail

repo="${RUNNER_GUARD_REPO:-marola-dev/marola-site}"
workflow=".github/workflows/site.yml"

# The permission of $1 on $repo, as the machine's own gh login sees it (never the job's token).
permission() { gh api "repos/$repo/collaborators/$1/permission" --jq .permission 2>/dev/null || echo none; }

guard() {
  local wf="${GITHUB_WORKFLOW_REF:-}" ev="${GITHUB_EVENT_NAME:-}" who="${GITHUB_TRIGGERING_ACTOR:-}" perm
  if [ "${wf%%@*}" != "$repo/$workflow" ]; then
    echo "runner-guard: refused: $wf is not $repo/$workflow" >&2
    return 1
  fi
  if [ "$ev" != workflow_dispatch ]; then
    echo "runner-guard: refused: event $ev, only workflow_dispatch" >&2
    return 1
  fi
  perm="$(permission "$who")"
  if [ "$perm" != admin ]; then
    echo "runner-guard: refused: $who has '$perm' on $repo, only an owner (admin)" >&2
    return 1
  fi
  echo "runner-guard: $who (owner) runs $wf"
}

install() {
  local dir="${1:?--install needs the runner directory}"
  [ -x "$dir/config.sh" ] || { echo "runner-guard: $dir is not a runner directory" >&2; return 1; }
  cp "${BASH_SOURCE[0]}" "$dir/runner-guard.sh"
  chmod 0755 "$dir/runner-guard.sh"
  touch "$dir/.env"
  sed -i '/^ACTIONS_RUNNER_HOOK_JOB_STARTED=/d' "$dir/.env"
  echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$dir/runner-guard.sh" >>"$dir/.env"
  echo "runner-guard: installed in $dir; restart the runner (just runners --status shows it) to load it"
}

self_test() {
  local fails=0
  check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 — got [$2], want [$3]"; fails=$((fails + 1)); fi; }
  permission() { case "$1" in boss) echo admin ;; reader) echo read ;; *) echo none ;; esac; }
  run() { GITHUB_WORKFLOW_REF="$1" GITHUB_EVENT_NAME="$2" GITHUB_TRIGGERING_ACTOR="$3" guard >/dev/null 2>&1 && echo pass || echo refused; }
  local site="$repo/$workflow@refs/heads/main"
  check "an owner's manual site.yml runs" "$(run "$site" workflow_dispatch boss)" pass
  check "on a branch too (an owner testing a PR)" "$(run "$repo/$workflow@refs/heads/fix/x" workflow_dispatch boss)" pass
  check "a reader's manual run is refused" "$(run "$site" workflow_dispatch reader)" refused
  check "an unknown actor is refused" "$(run "$site" workflow_dispatch "")" refused
  check "a pull_request run of site.yml is refused" "$(run "$site" pull_request boss)" refused
  check "another workflow is refused, even an owner's" "$(run "$repo/.github/workflows/evil.yml@refs/pull/9/merge" workflow_dispatch boss)" refused
  check "another repo's site.yml is refused" "$(run "someone/fork/$workflow@refs/heads/main" workflow_dispatch boss)" refused
  check "nothing set is refused" "$(run "" "" "")" refused
  local t; t="$(mktemp -d)"; trap 'rm -rf "$t"' RETURN
  touch "$t/config.sh"; chmod +x "$t/config.sh"; echo "LANG=C" >"$t/.env"
  install "$t" >/dev/null; install "$t" >/dev/null
  check "install points .env at the copy, once, keeping the rest" "$(grep -c '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$t/.env")/$(grep -c '^LANG=C$' "$t/.env")" "1/1"
  check "and the copy is executable" "$([ -x "$t/runner-guard.sh" ] && echo yes)" yes
  if [ "$fails" -eq 0 ]; then echo "runner-guard self-test: ok"; else
    echo "runner-guard self-test: $fails failure(s)" >&2
    return 1
  fi
}

case "${1:-}" in
  "") guard ;;
  --install) install "${2:-}" ;;
  --self-test) self_test ;;
  *) echo "usage: scripts/runner-guard.sh [--install RUNNER_DIR | --self-test]" >&2; exit 2 ;;
esac
