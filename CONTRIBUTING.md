# Contributing

This is a copy of [sytelus/womarchy](https://github.com/sytelus/womarchy) that you build yourself ([LOCAL-BUILD.md](LOCAL-BUILD.md)).

## Where to report what

- **Problems with this copy** (the local build tooling, or the fixes listed in LOCAL-BUILD.md):
  [open an issue here](https://github.com/kblock1/womarchy-local/issues/new/choose). The bug form asks for the output of `omarchy status`
  and the session logs; [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) says where they are. Remove
  anything private before posting.
- **Problems in womarchy itself** (they also happen with upstream's build): report them
  [upstream](https://github.com/sytelus/womarchy/issues/new/choose). Upstream takes issues, not pull requests: describe the problem
  and the fix, and link a branch if you have one.
- **Security problems:** see [SECURITY.md](SECURITY.md).

## Working on the code

You're welcome to fork it, experiment, and share what you find in an issue.
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers building, testing and the layout of the repo;
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit, and
[docs/JOURNEY.md](docs/JOURNEY.md) tells how they came to be.

- **Match the surrounding code:** naming, comment density and idiom. Comments explain *why*.
- **The checks CI runs** (`cargo test`/`clippy`, shellcheck, docs links, a secret scan) also run locally:
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
- **AI-assisted work is fine** here. Say so in the issue, and make sure you understand and have tested
  what you propose. Upstream projects have their own rules (see [docs/UPSTREAMING.md](docs/UPSTREAMING.md)).

## Licensing

By proposing code in an issue you agree that it is licensed under the [MIT license](LICENSE), or, for
changes to an upstream project's patch series, under that project's license.
