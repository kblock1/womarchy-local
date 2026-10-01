# Contributing

Thanks for helping! Issues, pull requests, test reports from other GPUs and machines, and docs fixes
are all welcome.

## Reporting a problem

[Open an issue](https://github.com/sytelus/womarchy/issues/new/choose). The bug form asks for the
output of `omarchy status` and the session logs; [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) says
where they are. Remove anything private before posting. Security problems: see [SECURITY.md](SECURITY.md).

Reports from hardware we haven't tested are especially useful: so far only one NVIDIA machine has
been tested. Tell us what worked too, not only what broke.

## Changing code

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers building, testing and the layout of the repo; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
explains how the pieces fit.

- **One logical change per pull request**, with a description of what and why.
- **Match the surrounding code:** naming, comment density and idiom. Comments explain *why*.
- **Checks run automatically** on every pull request (`cargo test`/`clippy`, shellcheck, docs links, a
  secret scan). You can run most of them locally:
  ```
  cd windows/omarchy && cargo test --release && cargo clippy --release --all-targets -- -D warnings
  python3 tools/check-links.py && python3 tools/check-secrets.py
  ```
- **Patches to aquamarine, Hyprland or Mesa** go through the fork workflow in [patches/README.md](patches/README.md)
  (commit in `src/`, then export the series).
- **The display protocol** ([protocol/wdp.h](protocol/wdp.h)) is shared by the compositor and the viewer: change
  both sides together.
- **Be careful on your own machine:** WSL distros share one VM. Read
  [the rules for working on a shared machine](docs/DEVELOPMENT.md#rules-for-working-on-a-shared-machine)
  before testing anything below the desktop.
- **AI-assisted contributions are fine** here. Say so in the pull request, and make sure you understand
  and have tested what you submit. Upstream projects have their own rules (see
  [docs/UPSTREAMING.md](docs/UPSTREAMING.md)).

## Licensing

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE), or, for
changes to an upstream project's patch series, under that project's license.
