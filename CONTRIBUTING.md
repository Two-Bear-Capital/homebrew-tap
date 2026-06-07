# Contributing — homebrew-tap

This tap holds only Homebrew formula/cask definitions — there is no build or test
stack.

## How formulae are updated

Formula version + asset URL + sha256 bumps are **published automatically** by
[`tbc-platform`](https://github.com/Two-Bear-Capital/tbc-platform)'s release
process (GoReleaser). **Prefer that flow over hand-editing** the files here.

If you must edit by hand, keep changes minimal and mechanical (version, URL,
sha256), and verify with:

```sh
brew install --build-from-source ./Formula/<name>.rb   # or: brew audit --tap two-bear-capital/tap
```

## Conventions

Follow the platform [`conventions/`](https://github.com/Two-Bear-Capital/tbc-platform-workspace/tree/main/conventions)
catalog where applicable (Conventional Commits). Branch off `main` and open a PR.
