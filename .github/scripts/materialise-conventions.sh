#!/usr/bin/env bash
#
# Puts the shared conventions catalog where a repo's CLAUDE.md actually imports it, so an
# @claude session on a runner sees the same rules a developer sees.
#
# Every repo's CLAUDE.md imports the catalog by RELATIVE path (`@../conventions/core.md`
# and friends), which resolves only in the workspace layout. claude-code-review.yml gets
# around that by naming `.workspace/conventions/` in its prompt; claude.yml has no prompt —
# the user's @claude comment is the prompt — so the files have to land at the path the
# import already points at. The arithmetic is the same in both environments:
#
#   dev     <workspace>/<repo>/CLAUDE.md          -> ../conventions = <workspace>/conventions
#   runner  /home/runner/work/<r>/<r>/CLAUDE.md   -> ../conventions = /home/runner/work/<r>/conventions
#
# actions/checkout refuses a `path:` outside $GITHUB_WORKSPACE, which is why the caller
# sparse-checks-out to `.workspace` and this copies from there.
#
# Two properties worth keeping:
#
#   * It exits 0 when the catalog is absent. A lapsed WORKSPACE_RO_TOKEN must not fail
#     every @claude invocation — but the degradation is LOUD (a ::warning:: and a step
#     summary), because for a month nobody noticed the same failure in the review workflow
#     (tbc-platform-workspace#153).
#   * It deletes the `.workspace` scratch checkout afterwards. `../conventions` sits
#     outside $GITHUB_WORKSPACE and so can never be committed, but `.workspace/` sits
#     inside it and no repo gitignores it — and this workflow, unlike the review one, can
#     commit and push. A session that ever staged broadly (`git add -A`) would sweep the
#     private catalog into a public repo's history. Removing it closes that class rather
#     than trusting every future session to stage precisely.
#
# Usage: run from $GITHUB_WORKSPACE, after the repo and `.workspace` checkouts.
set -euo pipefail

SRC=".workspace/conventions"
DEST="../conventions"

if [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
	echo "::warning title=Degraded session::Conventions catalog unavailable — @claude is running without the shared rules. Check WORKSPACE_RO_TOKEN (see tbc-platform-workspace#153)."
	{
		echo "### ⚠️ Degraded @claude session"
		echo
		echo "The conventions catalog could not be checked out, so this repo's \`CLAUDE.md\`"
		echo "imports of \`../conventions/*\` resolved to nothing. Claude ran without the shared"
		echo "rules — Conventional Commits, secrets handling, DRY, the testing floor."
		echo
		echo "Most likely \`WORKSPACE_RO_TOKEN\` has expired. See [workspace#153](https://github.com/Two-Bear-Capital/tbc-platform-workspace/issues/153)."
	} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
	exit 0
fi

mkdir -p "$DEST"
cp -R "$SRC"/. "$DEST"/
count=$(find "$DEST" -name '*.md' | wc -l | tr -d ' ')

# The scratch checkout has served its purpose; see the header for why it must not survive
# into a session that can commit.
rm -rf .workspace

echo "Conventions catalog available to @claude ($count files)."
echo "Conventions catalog available to @claude ($count files)." >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
