#!/usr/bin/env bash
#
# Turns one lens's verified sweep findings into ONE tracking issue, rewritten in place each
# run. This is the only step in scheduled-review.yml that can write; the model steps before
# it are read-only, and everything they produced reaches here as a JSON file that is
# treated as DATA (validated, sanitised, never executed).
#
# Why one issue per lens rather than one per finding: the sweep runs on a schedule across every
# repo, and per-finding issues are how a report-only tool becomes a backlog nobody opens.
# A single issue that is rewritten each run, marks what is NEW, and closes itself on a
# clean run gives the same "close-when-fixed" for the cost of one notification.
#
# Fail-closed, deliberately. Every way a run can be BROKEN — an invalid findings file, a
# verdicts document that does not cover every finding exactly once, a failed `gh` lookup —
# exits non-zero WITHOUT touching any issue. A broken run must never read as "clean" and close
# a real issue, nor as "no issue exists" and file a duplicate. Same shape as the
# review-followups rule: nothing may decide what to keep by a path that can silently fail
# (collect-review-followups.sh). A verifier that ran and said "unverifiable" is a verdict;
# a verifier that returned nothing for a finding is a failure.
#
# Identity: a finding is (lens, rule, path). Line numbers are excluded so a finding
# survives unrelated edits; the model's free text is excluded so rewording does not churn.
#
# Declining a finding: close the issue as "not planned". Fingerprints in the 200 most recently
# closed sweep issues (all lenses) are suppressed next run, so a declined finding does not come
# back on every run.
#
# Usage (env-driven; values reach the shell through env:, never interpolated):
#   REPO=owner/name LENS=blind-spots FINDINGS_FILE=f.json VERDICTS_FILE=v.json \
#   DRY_RUN=false RUN_URL=... ./file-sweep-findings.sh
#     DRY_RUN       default true — render to the step summary, touch no issue
#     MAX_FINDINGS  default 15  — findings beyond this are counted, not listed
#     VERDICTS_FILE required whenever the findings file is non-empty
set -euo pipefail

: "${REPO:?REPO is required (owner/name)}"
: "${LENS:?LENS is required}"
: "${FINDINGS_FILE:?FINDINGS_FILE is required}"
DRY_RUN="${DRY_RUN:-true}"
MAX_FINDINGS="${MAX_FINDINGS:-15}"
VERDICTS_FILE="${VERDICTS_FILE:-}"
RUN_URL="${RUN_URL:-}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

LABEL="scheduled-review"
TITLE="scheduled review: ${LENS}"

command -v gh >/dev/null 2>&1 || {
	echo "✗ gh CLI not found" >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	echo "✗ jq not found" >&2
	exit 1
}
# shellcheck source-path=SCRIPTDIR source=issue-upsert.sh
source "$(dirname "${BASH_SOURCE[0]}")/issue-upsert.sh"

jq -e '(.findings | type == "array") and (.coverage | type == "string")' "$FINDINGS_FILE" >/dev/null 2>&1 || {
	echo "✗ $FINDINGS_FILE is missing or is not a findings document — refusing to touch any issue." >&2
	exit 1
}

# The blind-spots lens exists to name which part of the PR review flow admitted the defect, so a
# finding with no `slipped_past` is not a weaker finding — it is the lens's entire point missing,
# and it reads downstream as an ordinary finding because the renderer omits the field when empty.
# The shared findings schema cannot say "required for this lens only", and lenses/blind-spots.md
# states the requirement in prose, which is a claim that can go stale; this is the gate that
# actually holds it. Refusing the whole document rather than dropping the one finding matches the
# verdict check above: a malformed document from the model is a broken run, not a partial result.
if [[ "$LENS" == "blind-spots" ]]; then
	gapless=$(jq -r '[ .findings
		| to_entries[]
		| select((.value.slipped_past | if type == "string" then gsub("^\\s+|\\s+$"; "") else "" end) == "")
		| .key ] | join(", ")' "$FINDINGS_FILE")
	if [[ -n "$gapless" ]]; then
		echo "✗ every blind-spots finding must name the review gap it came through in slipped_past; finding(s) at index $gapless do not — refusing to touch any issue." >&2
		exit 1
	fi
fi

total=$(jq '.findings | length' "$FINDINGS_FILE")
coverage=$(jq -r '.coverage' "$FINDINGS_FILE")

# Exactly one verdict per finding index, each a known verdict. Anything less is a broken
# verifier, not a clean result: if a missing verdict counted as "dropped", an empty verdicts
# document would confirm nothing and the clean-run branch would close a real open issue.
if ((total > 0)); then
	if [[ -z "$VERDICTS_FILE" ]] || ! jq -e --argjson n "$total" '
		(.verdicts | type == "array")
		and ([.verdicts[].index] | sort) == [range(0; $n)]
		and all(.verdicts[]; .verdict | IN("confirmed", "refuted", "unverifiable"))' \
		"$VERDICTS_FILE" >/dev/null 2>&1; then
		echo "✗ $total finding(s) but VERDICTS_FILE is missing or does not carry exactly one valid verdict per finding — refusing to touch any issue." >&2
		exit 1
	fi
	verdicts=$(jq -c '.verdicts' "$VERDICTS_FILE")
else
	verdicts="[]"
fi

verdict_count() { # verdict_count <verdict>
	jq -n --argjson f "$(jq -c '.findings' "$FINDINGS_FILE")" --argjson v "$verdicts" --arg want "$1" '
		[ range(0; $f | length) as $i
		  | ([$v[] | select(.index == $i)][0].verdict)
		  | select(. == $want) ] | length'
}
refuted=$(verdict_count refuted)
unverifiable=$(verdict_count unverifiable)

sha12() {
	if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -c1-12
}

# Confirmed findings, each stamped with its fingerprint; first wins on a repeated identity
# (the class-level rule: one finding per class, so a second is the same class again).
confirmed="[]"
seen=" "
while IFS= read -r finding; do
	[[ -n "$finding" ]] || continue
	fp=$(jq -r --arg lens "$LENS" '"\($lens)|\(.rule)|\(.path)"' <<<"$finding" | tr -d '\n' | sha12)
	[[ "$seen" == *" $fp "* ]] && continue
	seen+="$fp "
	confirmed=$(jq -c --argjson f "$finding" --arg fp "$fp" '. + [$f + {fp: $fp}]' <<<"$confirmed")
done < <(jq -nc --argjson f "$(jq -c '.findings' "$FINDINGS_FILE")" --argjson v "$verdicts" '
	range(0; $f | length) as $i
	| select(([$v[] | select(.index == $i)][0].verdict) == "confirmed")
	| $f[$i]')

# Prior state. issue_find fails closed, so a failed lookup cannot read as "no open issue" and
# file a duplicate. The same holds for the closed-issue lookup below: no `|| true` and no
# stderr redirect. `gh` already returns an empty list for a label that does not exist.
issue_find "$REPO" "$TITLE" "$LABEL"
open_issue="$ISSUE_JSON"
existing="$ISSUE_NUMBER"

# Bodies on stdin -> JSON array of the fingerprints they carry. The grep is grouped so "no
# match" (exit 1) cannot become the pipeline's status under pipefail; an empty stream slurps
# to [] on its own.
#
# Matches the WHOLE marker, not a bare "fp:<hex>". Model text is escaped so it can never open
# an HTML comment, but a bare-token match would still read a forged "fp:..." out of a claim's
# prose — and a fingerprint read back as "declined" silently suppresses a real finding.
fps_in() {
	{ grep -oE '<!-- fp:[0-9a-f]{12} -->' || true; } | sed -E 's/^<!-- fp:([0-9a-f]{12}) -->$/\1/' | jq -R . | jq -sc .
}
prior_fps=$(printf '%s' "${open_issue:-null}" | jq -r '.body // ""' | fps_in)

# The label is shared by every lens, so this window is repo-wide: --limit is applied BEFORE the
# title filter. A deliberate window, unlike the paginated open lookup: 200 keeps an old decline
# from being pushed out by other lenses' closes without reading the repo's whole history.
declined_fps=$(gh issue list --repo "$REPO" --state closed --label "$LABEL" --limit 200 \
	--json title,body,stateReason |
	jq -r --arg t "$TITLE" '.[] | select(.title == $t and .stateReason == "NOT_PLANNED") | .body' |
	fps_in)

kept=$(jq -c --argjson d "$declined_fps" '[.[] | select(.fp as $fp | $d | index($fp) | not)]' <<<"$confirmed")
declined=$(($(jq 'length' <<<"$confirmed") - $(jq 'length' <<<"$kept")))
n_kept=$(jq 'length' <<<"$kept")
overflow=0
if ((n_kept > MAX_FINDINGS)); then
	overflow=$((n_kept - MAX_FINDINGS))
	kept=$(jq -c --argjson m "$MAX_FINDINGS" '.[:$m]' <<<"$kept")
fi
listed=$(jq 'length' <<<"$kept")
new_count=$(jq --argjson p "$prior_fps" '[.[] | select(.fp as $fp | $p | index($fp) | not)] | length' <<<"$kept")

# Model text is untrusted: neutralise @mentions (would notify real people) and HTML
# comments (could forge a fingerprint marker and hide or suppress a finding).
# Defined once and concatenated into each program below, rather than written inline: a copy
# in two places drifts, and bash 3.2 (macOS /bin/bash) cannot parse a single-quoted jq program
# containing parentheses inside "$(...)" \u2014 so it is also assigned to a variable first.
SANITISE='def s: tostring | gsub("@(?<c>[A-Za-z0-9_-])"; "@\u200b\(.c)") | gsub("<!--"; "&lt;!--");'

body_findings=$(jq -r --argjson p "$prior_fps" "$SANITISE"'
	.[] | . as $f |
	"### \(if ($p | index($f.fp)) then "" else "🆕 " end)`\(.path | s):\(.line)` — \(.rule | s)\n\n"
	+ "**Claim.** \(.claim | s)\n\n"
	+ "**Evidence.** \(.evidence | s)\n\n"
	+ (if ((.sites // []) | length) > 0 then "**Also at.** \((.sites | map(s | "`\(.)`") | join(", ")))\n\n" else "" end)
	+ (if (.slipped_past // "") != "" then "**Slipped past PR review via.** \(.slipped_past | s)\n\n" else "" end)
	+ "**Fix.** \(.fix | s)\n\n<!-- fp:\(.fp) -->\n"' <<<"$kept")

header="Scheduled \`${LENS}\` sweep"
[[ -n "$RUN_URL" ]] && header+=" — [run]($RUN_URL)"
header+=$'\n\n'
header+="**${listed} finding(s)** (${new_count} new). Verifier: ${refuted} refuted, ${unverifiable} unverifiable (both dropped)"
((declined > 0)) && header+="; ${declined} previously declined (suppressed)"
((overflow > 0)) && header+="; **${overflow} more not listed** (cap ${MAX_FINDINGS}) — fix these and re-run"
header+=$'.\n\n'
coverage_safe=$(jq -rn --arg c "$coverage" "$SANITISE"'$c | s')
header+="*Coverage:* ${coverage_safe}"
header+=$'\n\n'
header+="This issue is rewritten in place each run and closes itself on a clean run. To decline a"
header+=$'\n'
header+="finding, close the issue as **not planned**; its fingerprint is then suppressed."
header+=$'\n\n---\n\n'

if [[ "$DRY_RUN" != "false" ]]; then
	{
		echo "## 🧪 DRY RUN — \`${LENS}\` — no issue was created or changed"
		echo
		echo "${header}${body_findings}"
	} >>"$SUMMARY_FILE"
	echo "Dry run: ${listed} finding(s) rendered to the step summary for ${LENS}."
	exit 0
fi

if ((listed == 0)); then
	{
		echo "## ✅ \`${LENS}\` — clean"
		echo
		echo "Coverage: ${coverage}"
	} >>"$SUMMARY_FILE"
	if [[ -n "$existing" ]]; then
		gh issue comment "$existing" --repo "$REPO" \
			--body "Clean run${RUN_URL:+ ([run]($RUN_URL))} — no confirmed findings. Closing." >/dev/null
		gh issue close "$existing" --repo "$REPO" >/dev/null
		echo "Closed $REPO#$existing — clean run."
	else
		echo "Clean run for ${LENS}; no open issue to close."
	fi
	exit 0
fi

gh label create "$LABEL" --repo "$REPO" \
	--color "5319e7" \
	--description "Findings from the scheduled convention sweep" \
	--force >/dev/null 2>&1 || true

body="${header}${body_findings}"
{
	echo "## \`${LENS}\` — ${listed} finding(s)"
	echo
	echo "${body}"
} >>"$SUMMARY_FILE"

issue_write "$REPO" "$existing" "$TITLE" "$body" "$LABEL"
if [[ "$ISSUE_CREATED" == true ]]; then
	echo "Filed $REPO#$ISSUE_NUMBER with ${listed} finding(s)."
else
	echo "Updated $REPO#$ISSUE_NUMBER with ${listed} finding(s) (${new_count} new)."
fi
