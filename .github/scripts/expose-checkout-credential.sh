#!/usr/bin/env bash
#
# Re-links the credential actions/checkout persisted so claude-code-action can find and strip it.
# A workaround for anthropics/claude-code-action#1721; delete this step when that is fixed.
#
# checkout v6+ writes its read-only GITHUB_TOKEN header to a file under RUNNER_TEMP and pulls it in
# with `includeIf.gitdir:<gitdir>.path` entries. The action's cleanup (replaceCheckoutCredentials)
# only clears the header from `include.path` files, so it finds nothing, the header survives, and
# git sends it instead of the action's app token: every @claude push failed with "Write access to
# repository not granted" (tbc-platform#738, 2026-10-29).
#
# Rewriting each entry as a plain `include.path` keeps the header working for the action's first
# `git fetch`, which still needs it, and puts it where the action's cleanup then removes it.
# Entries naming a file that isn't on this host (checkout also writes container paths) are dropped.
#
# Usage: run from $GITHUB_WORKSPACE, after the repo checkout and before claude-code-action.
set -euo pipefail

seen=()
while read -r key path; do
	git config --local --unset-all "$key"
	[[ -f "$path" ]] || continue
	[[ " ${seen[*]-} " == *" $path "* ]] && continue
	seen+=("$path")
	git config --local --add include.path "$path"
done < <(git config --local --get-regexp '^includeif\.gitdir:.*\.path$' || true)

echo "Re-linked ${#seen[@]} checkout credential file(s) as include.path"
