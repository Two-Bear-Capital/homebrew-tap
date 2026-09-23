# Contributing — homebrew-tap

This tap holds only the Homebrew cask (`Casks/tbc.rb`). It is updated
automatically by the CLI's release process; prefer that over hand-editing (the
file carries a "DO NOT EDIT" banner).

If you must edit by hand, keep the change minimal and mechanical (version, URL,
sha256), and verify with:

```sh
brew audit --cask --tap two-bear-capital/tap
```

Use Conventional Commits. Branch off `main` and open a PR.
