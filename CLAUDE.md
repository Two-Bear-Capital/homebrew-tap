# CLAUDE.md

**Part of the Two Bear Capital platform.** Homebrew tap that distributes the
`tbc` CLI built in tbc-platform. The cross-repo service map lives in the
`tbc-platform-workspace` meta-repo's root `CLAUDE.md` (it loads automatically
when you run Claude from inside the workspace).

> **Governing source of truth → the workspace [`docs/`](https://github.com/Two-Bear-Capital/tbc-platform-workspace/blob/main/docs/README.md).** How this tap
> fits the platform is [`docs/system-overview.md`](https://github.com/Two-Bear-Capital/tbc-platform-workspace/blob/main/docs/system-overview.md); the release
> flow that populates it is [`docs/runbooks/release-and-deploy.md`](https://github.com/Two-Bear-Capital/tbc-platform-workspace/blob/main/docs/runbooks/release-and-deploy.md)
> (tbc-platform's GoReleaser, on a `v*` tag). This file covers only what's
> specific to `homebrew-tap`.

## What this is

A Homebrew tap — a Git repo of cask definitions (`Casks/*.rb`) that lets
users `brew install` the `tbc` CLI. There is no application code here; the tap
just points Homebrew at released CLI artifacts produced by tbc-platform.

## Conventions

Platform-wide conventions live once in the workspace `conventions/` catalog (the
single source of truth). A tap has no build/test stack, so this repo imports only
the universal core:

@../conventions/core.md

### Deviations
- Cask bumps (version + asset URLs + sha256) are driven by tbc-platform's
  release process — `Casks/tbc.rb` is GoReleaser-generated ("DO NOT EDIT"), so
  prefer that flow over hand-editing the cask.
- Keep changes minimal and mechanical; this repo carries no build/test stack of
  its own.
