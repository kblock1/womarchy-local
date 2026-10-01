# Security

## Reporting a vulnerability

Please report security problems **privately**:
[open a private security advisory](https://github.com/sytelus/womarchy/security/advisories/new). Don't use
public issues for them. You'll get an answer as soon as a maintainer can look at it. This is a small
volunteer project.

## Supported versions

Only the latest release gets fixes. Installed systems receive fixed packages through `omarchy update`
from the [`[womarchy]` package repository](https://github.com/sytelus/womarchy/releases/tag/repo).

## What protects an installation

- **The package repository is signed.** `[womarchy]`'s database and packages are signed with the key
  `EB71 0326 17BB A1C4 C8EE  77C3 047A 25C1 135F 969D` (also in
  [linux/packages/womarchy-keyring](linux/packages/womarchy-keyring)). Installed systems refuse a database
  without a valid signature. The private key exists only as a GitHub Actions secret, usable only by the
  publishing job after a maintainer approves it.
- **Downloads are checked.** `install.ps1` and `omarchy install` check `omarchy.exe` and the image against
  the SHA-256 sums published with each release.
- **The connection between Windows and Linux is local and authenticated.** It runs over Hyper-V sockets,
  which only connect this PC to its own WSL VM. Both ends prove a per-session secret before any input or
  clipboard data is exchanged (see [protocol/wdp.h](protocol/wdp.h)).
- **Nothing runs elevated on Windows.** There are no services, drivers or kernel modules. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security-model).

## Known limitations

- **The distro's disk is not encrypted.** A regular Omarchy install encrypts the disk; under WSL the
  distro's virtual disk is a file on your Windows drive, protected only if that drive uses BitLocker.
- **The firewall is off by default.** The firewall inside the distro (ufw) is off, because WSL's network
  translation and the Windows firewall already filter incoming connections.
