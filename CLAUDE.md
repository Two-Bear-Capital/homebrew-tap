# CLAUDE.md

**Part of the Two Bear Capital platform.** Homebrew tap that distributes the
`tbc` CLI built in tbc-platform. The cross-repo service map lives in the
`tbc-platform-workspace` meta-repo's root `CLAUDE.md` (it loads automatically
when you run Claude from inside the workspace).

## What this is

A Homebrew tap — a Git repo of formula definitions (`Formula/*.rb`) that lets
users `brew install` the `tbc` CLI. There is no application code here; the tap
just points Homebrew at released CLI artifacts produced by tbc-platform.

## Conventions

Platform-wide conventions live once in the workspace `conventions/` catalog (the
single source of truth). A tap has no build/test stack, so this repo imports only
the universal core:

@../conventions/core.md

### Deviations
- Formula bumps (version + bottle/asset URLs + sha256) are driven by
  tbc-platform's release process — prefer that flow over hand-editing formulae.
- Keep changes minimal and mechanical; this repo carries no build/test stack of
  its own.
