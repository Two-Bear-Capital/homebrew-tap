#!/usr/bin/env bash
#
# Builds the read-only context bundle the sweep reads INSTEAD of running git or gh itself.
#
# Why the model has no shell at all: an allowlisted `git log` / `git show` / `git diff` is not
# read-only. Each accepts `--output=<path>`, and `--format=format:<anything>` chooses the
# content, so `git log --format=format:X --output=P` writes attacker-chosen bytes to any path
# — including `.git/config`, where a `core.fsmonitor` line runs on the next git operation.
# The sweep reads untrusted repo content, so a prompt-injected run would have that primitive
# (verified against a scratch repo in PR #173). A deny-list of flags is a guard keyed on the
# shape of a command line; removing the shell removes the class. The model gets Read, Grep and
# Glob, and the deterministic facts it needs are computed here, by code, and handed over as
# files.
#
# Nothing here writes outside OUT_DIR, and nothing here is model-driven.
#
# Usage (env-driven; run from the repo root, after checkout with full history):
#   REPO=owner/name ./build-sweep-context.sh
#     OUT_DIR         default .sweep/context
#     WINDOW_DAYS     default 35 — longer than the monthly interval between runs, so
#                     consecutive runs overlap deliberately (dedupe is downstream) and a run
#                     that slipped a few days still covers everything since the last one
#     SLICE_KEY       default months since year 0 — picks the rotating slice; override for tests
#     DIFF_CAP_BYTES  default 400000 — history-diff.txt is truncated (and says so) past this
#     LENS_FILE       optional — when the lens declares `requires-window: true` and the window
#                     holds no commits and no merged PRs, `skip=true` is written to
#                     $GITHUB_OUTPUT so the caller can skip the model steps entirely
set -euo pipefail

: "${REPO:?REPO is required (owner/name)}"
OUT_DIR="${OUT_DIR:-.sweep/context}"
WINDOW_DAYS="${WINDOW_DAYS:-35}"
SLICE_KEY="${SLICE_KEY:-$((10#$(date -u +%Y) * 12 + 10#$(date -u +%m)))}"
DIFF_CAP_BYTES="${DIFF_CAP_BYTES:-400000}"

for tool in git gh jq; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "✗ $tool not found" >&2
		exit 1
	}
done

mkdir -p "$OUT_DIR"
since="${WINDOW_DAYS} days ago"

# --no-ext-diff / --no-textconv: never run a configured diff driver over untrusted content.
git log --first-parent --since="$since" --date=short \
	--format='%h%x09%ad%x09%an%x09%s' HEAD >"$OUT_DIR/history.tsv"

# Lockfiles and generated output carry almost no reviewable signal: a dependency bump's subject
# already says which package and which versions. Measured on a Dependabot-heavy repo
# (tbc-mcp-server): they were about 19% of the 14-day diff (418KB -> 339KB), which is modest —
# most of the diff is real code, tests and the synced .github files, and those stay in on purpose.
# What the exclusion buys is the monthly window: unfiltered, a 35-day diff is 494KB and would be
# truncated at the 400KB cap; filtered it is 366KB and is read whole. history.tsv is NOT
# filtered, so every commit is still listed; history-diff.txt omits a commit that touches only
# these paths.
#
# This deliberately mirrors the `paths-ignore` in claude-code-review.yml, kept in step by hand: a
# path type missing here costs tokens, never correctness.
noise=(
	':(exclude)*.lock' ':(exclude)*.lock.hcl' ':(exclude)package-lock.json' ':(exclude)*/package-lock.json'
	':(exclude)pnpm-lock.yaml' ':(exclude)*/pnpm-lock.yaml' ':(exclude)go.sum' ':(exclude)*/go.sum'
	':(exclude)*.gen.go' ':(exclude)generated/*' ':(exclude)*/generated/*'
)

full_diff="$OUT_DIR/.history-diff.full"
git log --first-parent --since="$since" -p --no-ext-diff --no-textconv \
	--format='=== %h %s' HEAD -- . "${noise[@]}" >"$full_diff"
full_bytes=$(wc -c <"$full_diff" | tr -d ' ')
head -c "$DIFF_CAP_BYTES" "$full_diff" >"$OUT_DIR/history-diff.txt"
if ((full_bytes > DIFF_CAP_BYTES)); then
	printf '\n=== TRUNCATED: %s of %s bytes shown. Read history.tsv for the full commit list.\n' \
		"$DIFF_CAP_BYTES" "$full_bytes" >>"$OUT_DIR/history-diff.txt"
fi
rm -f "$full_diff"

# The PR records come from the COMMITS, not from a PR list. This is the third shape this took, and
# the first two each failed by asking "does this list look complete?":
#   1. `gh pr list --json ...,reviews,commits` over 100 PRs asks GitHub for commits x authors and
#      is refused ("requesting up to 1,000,000 possible nodes which exceeds the maximum limit of
#      500,000").
#   2. A light list capped by --limit, filtered to the window afterwards, drops in-window PRs
#      silently on a busy repo — and a commit whose PR record is absent reads as "merged with no PR".
#   3. The check that detected that truncation reasoned about the oldest mergedAt in the capped
#      list, which assumes an ordering the API does not give: `gh pr list` sorts by CREATED date,
#      not merge date (checked against a live repo: the merge order is inverted in 47 places over 275
#      PRs), so a long-lived PR merged inside the window can sit outside the fetched set.
# (A list of merged PRs also includes PRs merged into other branches — a stacked PR on
# tbc-mcp-server was in it — whose commits never reached the default branch, so the two files the
# model reads would have disagreed.)
# The first-parent commits on the default branch are the ground truth for what merged. On the
# squash-merge-only repos this workspace enforces, GitHub appends `(#N)` to the subject of every PR's
# commit, so the PR numbers are read straight out of history.tsv and each is fetched by number: no
# list, no cap, no ordering, no search index to lag. A commit with no trailing `(#N)` is a direct
# push, which is exactly the fact the blind-spots lens wants and which has no PR record because it
# had no PR.
#
# Only the LAST `(#N)` of a subject counts ("docs: explain (#99) refs (#5)" is PR 5). Numbers are
# fetched in ascending order so a failure is reproducible.
#
# Trimmed to what the blind-spot question needs — who reviewed which commit, and what landed
# after — because review bodies are large and the model has no use for them here. None of the `gh`
# calls below has an error redirect or a `|| true`: a failed `gh` aborts the run rather than
# yielding a bundle that reads as "nothing merged", and nothing is written to merged-prs.json until
# every PR has been fetched.
details="$OUT_DIR/.merged-prs.details.jsonl"
: >"$details"
while IFS= read -r number; do
	gh pr view "$number" --repo "$REPO" \
		--json number,title,author,mergedAt,mergeCommit,headRefOid,reviews,commits |
		jq -c '{ number, title, author: .author.login, mergedAt,
		         mergeCommit: .mergeCommit.oid, headRefOid,
		         reviews: [ .reviews[] | { by: .author.login, state, submittedAt, commit: .commit.oid } ],
		         commits: [ .commits[] | { oid, committedDate } ] }' >>"$details"
done < <(sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p' "$OUT_DIR/history.tsv" | sort -un)

jq -s '.' "$details" >"$OUT_DIR/merged-prs.json"
rm -f "$details"

window_commits=$(wc -l <"$OUT_DIR/history.tsv" | tr -d ' ')
window_prs=$(jq 'length' "$OUT_DIR/merged-prs.json")

# Skip a lens that has nothing to examine. A lens that works only on what changed in the window
# says so with `requires-window: true` in its file; over an empty window it would spend a full
# model run to report nothing. The decision is made here, from counts, not by the model.
#
# A missing lens file is an error rather than "don't skip": a typo'd path must not silently turn
# the saving off. And skipping is not a verdict — the caller must leave any open issue alone,
# because "nothing changed" is not "nothing is wrong".
skip=false
if [[ -n "${LENS_FILE:-}" ]]; then
	[[ -f "$LENS_FILE" ]] || {
		echo "✗ LENS_FILE $LENS_FILE not found" >&2
		exit 1
	}
	if grep -qx 'requires-window: true' "$LENS_FILE" && ((window_commits == 0 && window_prs == 0)); then
		skip=true
	fi
fi

# One extra directory is read in full each run so the whole repo is eventually covered. The
# choice is made here, deterministically, rather than by the model: `10#` keeps a zero-padded
# key like "08" from being read as invalid octal.
#
# Dot-directories are not candidates. The first live run's slice was `.pycharm` — a month of
# "read this in full" spent on IDE config. The ones that matter (.github) are read explicitly by
# the lenses that care about them, and the rest are tooling.
dirs=$(git ls-tree -d --name-only HEAD | { grep -v '^\.' || true; } | sort)
count=$(printf '%s' "$dirs" | grep -c . || true)
slice="(none — no top-level directories)"
if ((count > 0)); then
	slice=$(printf '%s\n' "$dirs" | sed -n "$((10#$SLICE_KEY % count + 1))p")
fi

{
	echo "repo=$REPO"
	echo "head_sha=$(git rev-parse HEAD)"
	echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "window_days=$WINDOW_DAYS"
	echo "window_commits=$window_commits"
	echo "window_merged_prs=$window_prs"
	echo "slice_key=$SLICE_KEY"
	echo "rotating_slice=$slice"
} >"$OUT_DIR/meta.txt"

cat >"$OUT_DIR/README.txt" <<EOF
Read-only facts about $REPO, computed by build-sweep-context.sh before the sweep started. You
have no shell, so this is all the git/gh history there is. Window: the last $WINDOW_DAYS days.

meta.txt         key=value: head sha, the window and its counts, and rotating_slice — the
                 top-level directory to read in full this run, in addition to the recent changes.
history.tsv      first-parent commits on the default branch: sha, date, author, subject.
history-diff.txt the same commits with their diffs, truncated at $DIFF_CAP_BYTES bytes (it says so
                 at the end if it was). Lockfile and generated-file diffs are left out, and a
                 commit touching only those does not appear here — history.tsv still lists it.
merged-prs.json  one record for every PR named by a trailing "(#N)" on a commit in history.tsv, so
                 it is complete for the window: number, title, author, mergedAt, mergeCommit,
                 headRefOid, reviews (by, state, submittedAt, commit reviewed) and commits (oid,
                 committedDate). A commit in history.tsv with no "(#N)" was pushed directly and has
                 no PR record because it had no PR.
EOF

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "skip=$skip" >>"$GITHUB_OUTPUT"
fi
if [[ "$skip" == "true" ]]; then
	echo "⏭️ Skipping: the lens works only on the window, and it holds no commits and no merged PRs for $REPO in the last $WINDOW_DAYS days. No model call was made; any open issue is left as it is." |
		tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

echo "Sweep context for $REPO built in $OUT_DIR ($window_commits commits and $window_prs merged PRs in the window; slice: $slice; skip: $skip)."
