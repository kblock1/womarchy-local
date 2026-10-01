# Contributing

Thanks for helping! Contributions here happen through **issues**: bug reports, test results from other
GPUs and machines, ideas, and proposed fixes.

## We don't accept pull requests directly

Please [open an issue](https://github.com/sytelus/womarchy/issues/new/choose) instead, even if you've
already written the code. Describe the problem and your change, and paste a patch or link your branch.
The issue forms have a field for it. If the change goes in, we make it ourselves and credit you.
Pull requests opened anyway may be closed with a pointer to this page.

## Reporting a problem

[Open an issue](https://github.com/sytelus/womarchy/issues/new/choose). The bug form asks for the
output of `omarchy status` and the session logs; [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) says
where they are. Remove anything private before posting. Security problems: see [SECURITY.md](SECURITY.md).

Reports from hardware we haven't tested are especially useful: so far only one NVIDIA machine has
been tested. Tell us what worked too, not only what broke.

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
