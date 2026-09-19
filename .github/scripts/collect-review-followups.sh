#!/usr/bin/env bash
#
# Turns the review findings a merged PR left behind into one tracked issue, so that
# "advisory" means queued rather than discarded.
#
# The blocking/advisory split only works if the advisory half survives the merge. The
# 30-day record says which mechanism survives and which does not, unambiguously:
#
#   survived — every one became a tracked artifact: tbc-doc-pipeline#98 -> issue #101 and
#              PR #104; #107's four open findings -> PR #110; fsmc#136 -> #137;
#              fivetran-dbt#202 -> #203; tbc-agents#283 -> #284
#   lost     — replied-to, or posted late, then died with the PR: tbc-platform#441 (five
#              real design-security findings, five minutes after merge, never addressed),
#              tbc-mcp-server#296 (cache poisoning, 64 seconds late), tbc-doc-pipeline#108
#              (a runtime banner contradicting the PR's own fix, never fixed)
#
# A finding survives if and only if it becomes an issue. A resolved thread is a deleted
# finding. So this does not ask the author to remember at merge time — which is exactly
# when the PR is green and they are done.
#
# What it collects from a merged PR:
#   * unresolved threads whose root comment is a bot finding tagged ADVISORY:
#   * EVERY unresolved bot thread created after mergedAt, whatever its tag — a finding
#     that arrives after the merge had no chance to gate it, and blocking ones posted
#     late are the most valuable thing in this whole set (17 findings across 9 PRs in
#     the 30 days before this existed)
#
# Idempotent: one issue per PR, looked up by title and updated rather than duplicated.
# Safe to re-run, and safe for the daily sweep to revisit the same PR.
#
# Usage (env-driven; the workflow passes GitHub values through env:, never by
# interpolating them into the command line — see conventions/make-hub.md):
#   REPO=owner/name PR_NUMBER=123 ./collect-review-followups.sh
set -euo pipefail

: "${REPO:?REPO is required (owner/name)}"
: "${PR_NUMBER:?PR_NUMBER is required}"

command -v gh >/dev/null 2>&1 || {
	echo "✗ gh CLI not found" >&2
	exit 1
}

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"
LABEL="review-advisory"
TITLE="review follow-ups from #${PR_NUMBER}"

# Paginated, not first:100. The script promises to carry EVERY unresolved finding, and a
# fixed first page quietly breaks that promise on exactly the PRs that need it most — the
# long, heavily-reviewed ones. Threads beyond the page would be dropped with no signal,
# which is the same silent-degradation shape as the credential in workspace#153.
cursor=""
threads="[]"
while :; do
	# shellcheck disable=SC2016  # $owner/$name/$number/$after are GraphQL variables, bound below
	page=$(gh api graphql -f owner="$OWNER" -f name="$NAME" -F number="$PR_NUMBER" \
		-f after="$cursor" -f query='
	query($owner:String!,$name:String!,$number:Int!,$after:String){
	  repository(owner:$owner,name:$name){
	    pullRequest(number:$number){
	      mergedAt url
	      author{login}
	      reviewThreads(first:100, after:$after){
	        pageInfo{ hasNextPage endCursor }
	        nodes{
	          isResolved path line
	          comments(first:1){ nodes{ author{login} createdAt body url } }
	        }
	      }
	    }
	  }
	}' --jq '.data.repository.pullRequest')

	[[ -n "$page" && "$page" != "null" ]] || {
		echo "✗ could not read $REPO#$PR_NUMBER" >&2
		exit 1
	}

	threads=$(jq -s '.[0] + .[1]' <(printf '%s' "$threads") \
		<(jq '.reviewThreads.nodes' <<<"$page"))

	[[ "$(jq -r '.reviewThreads.pageInfo.hasNextPage' <<<"$page")" == "true" ]] || break
	cursor=$(jq -r '.reviewThreads.pageInfo.endCursor' <<<"$page")
done

# The scalar fields are identical on every page; keep the last page's and attach the full
# thread list so the jq below reads one object exactly as before.
pr=$(jq --argjson t "$threads" '{mergedAt, url, author} + {reviewThreads: {nodes: $t}}' <<<"$page")

merged_at=$(jq -r '.mergedAt // empty' <<<"$pr")
[[ -n "$merged_at" ]] || {
	echo "$REPO#$PR_NUMBER is not merged — nothing to collect."
	exit 0
}
pr_author=$(jq -r '.author.login // empty' <<<"$pr")

# Select the threads worth carrying forward. `late` is computed against mergedAt so a
# finding that landed after the gate is kept whatever its tier.
#
# Admission is by author OR by the surfaced marker, and the second clause is load-bearing:
# surface-suppressed-findings.sh posts its threads with the workflow's GITHUB_TOKEN, so they
# are authored by `github-actions[bot]` — a login the author test never matches. Selecting on
# the author alone silently dropped exactly the findings that pair of scripts exists to
# preserve, which is the whole point of them. Identity is the wrong key here; provenance is
# the right one, and the marker carries it.
findings=$(jq -r --arg merged "$merged_at" '
  [ .reviewThreads.nodes[]
    | select(.isResolved == false)
    | select((.comments.nodes | length) > 0)
    | . as $t
    | $t.comments.nodes[0] as $c
    | select(
        ($c.author.login | test("copilot|claude"; "i"))
        or ($c.body | test("<!-- surfaced-suppressed:"))
      )
    | {
        path: ($t.path // "—"),
        line: ($t.line // 0),
        url: $c.url,
        body: $c.body,
        late: ($c.createdAt > $merged),
        advisory: ($c.body | test("ADVISORY:"))
      }
    | select(.advisory or .late)
  ]' <<<"$pr")

count=$(jq 'length' <<<"$findings")
if [[ "$count" == "0" ]]; then
	echo "$REPO#$PR_NUMBER: no unresolved advisory or post-merge findings."
	exit 0
fi

late_count=$(jq '[.[] | select(.late)] | length' <<<"$findings")

# The label may not exist in this repo yet. `--force` makes creation idempotent, and
# creating it here keeps the workflow self-contained rather than depending on a separate
# `make labels` pass having reached every repo first.
gh label create "$LABEL" --repo "$REPO" \
	--color "fbca04" \
	--description "Non-blocking review findings carried over from a merged PR" \
	--force >/dev/null 2>&1 || true

# Built with explicit \n rather than heredocs: $(cat <<EOF) strips trailing newlines, so
# the sections would run together and the markdown would lose its paragraph breaks.
body="Review findings from $(jq -r '.url' <<<"$pr") that were still unresolved when it merged."
body+=$'\n\n'
body+="They did not block the merge, by design — but an unresolved thread on a merged PR is a"
body+=$'\n'
body+="deleted finding, so they are tracked here instead. Close this issue when they are handled"
body+=$'\n'
body+="or deliberately declined; if one turns out to matter more than its tag suggested, fix it"
body+=$'\n'
body+="and say so."
body+=$'\n\n'

if [[ "$late_count" != "0" ]]; then
	body+="⚠️ **$late_count of these were posted after the merge**, so nothing could have gated them."
	body+=$'\n'
	body+="Read those first — findings arriving late are how real defects have escaped here before."
	body+=$'\n\n'
fi

body+=$'---\n\n'
body+=$(jq -r '.[] | "### `\(.path):\(.line)`\(if .late then "  — *posted after merge*" else "" end)\n\n\(.body)\n\n[thread](\(.url))\n"' <<<"$findings")

# Exact-title match over the label-filtered list, NOT `--search`. GitHub's search index is
# eventually consistent, so an issue this script just filed can be missing from a search a
# minute later — and the daily sweep revisits the same PRs, which would then duplicate it.
# A plain issue list is read straight from the API and is strongly consistent.
existing=$(gh issue list --repo "$REPO" --state open --label "$LABEL" --limit 200 \
	--json number,title \
	--jq ".[] | select(.title == \"$TITLE\") | .number" 2>/dev/null | head -1)

if [[ -n "$existing" ]]; then
	gh issue edit "$existing" --repo "$REPO" --body "$body" >/dev/null
	echo "Updated $REPO#$existing with $count finding(s) ($late_count post-merge)."
	exit 0
fi

# --assignee can fail on its own (an author outside the org, a bot author). That must not
# cost us the issue, which is the whole point — so create first, then try to assign.
number=$(gh issue create --repo "$REPO" --title "$TITLE" --body "$body" --label "$LABEL" \
	| sed -E 's#.*/issues/##')
echo "Filed $REPO#$number with $count finding(s) ($late_count post-merge)."

if [[ -n "$pr_author" ]]; then
	gh issue edit "$number" --repo "$REPO" --add-assignee "$pr_author" >/dev/null 2>&1 \
		|| echo "  (could not assign $pr_author — left unassigned)"
fi
