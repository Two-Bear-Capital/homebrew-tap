# Two Bear Capital — automated code review guidance

Canonical file, maintained in `tbc-platform-workspace` at
`scripts/copilot/copilot-instructions.md` and synced with `make copilot`. Do not hand-edit a
repo's copy.

## Spend the review where the risk is

Review effort should land on **code that can behave wrongly**, in roughly this order:

1. **Correctness and security in the executable code** — wrong results, unhandled failure
   paths, injection, a secret or PII reaching a wider trust domain, a guard that cannot fire.
   Where that code lives is repo-dependent: `src/` in most, but `scripts/` in the workspace
   meta-repo, `models/` in the dbt repo, `terraform/` in the infra repo. Judge by what runs,
   not by the directory name.
2. **Missing or weak tests for changed logic** — a change to behaviour without a test is a
   finding. So is a test whose name claims more than its assertions check.
3. **DRY violations** — new duplication of logic that has a single home.
4. **Prose accuracy**, under the limits below.

## Comments and documentation

These repos comment heavily on purpose, so prose is often most of a diff. Two rules keep review
of it proportionate:

- **Flag a comment or doc only when the code contradicts it** — a stale reference, or a claim
  about behaviour that the diff itself or the code it describes makes false. That is a real
  defect and worth reporting.
- **Do not flag wording, tone, length or phrasing preference.** If the statement is true, leave
  it.

⚠️ **Report drift once, structurally.** When the same fact is restated in several places and
one has gone stale, the finding is *"this fact is stated in N places; consolidate to one and
link"* — filed once. Do not file one finding per restatement site across successive rounds: it
turns a single structural problem into many rounds of the same conversation, and the fix for
the instance does not prevent the next one.

## Do not

- Re-review a **canonical-file sync PR** (byte-identical copies of files reviewed once at their
  source in `tbc-platform-workspace`).
- Restate unchanged code, or nitpick formatting the formatter owns.
- Invent findings when a PR is clean. Say it is clean.
