# Security

This is a copy of [sytelus/womarchy](https://github.com/sytelus/womarchy) that you build yourself, signed with your own key (see
[LOCAL-BUILD.md](LOCAL-BUILD.md)).

## Reporting a vulnerability

Please report security problems **privately**, never in public issues:

- **In this copy's changes** (the local build tooling and the fixes listed in LOCAL-BUILD.md):
  [open a private security advisory here](https://github.com/kblock1/womarchy-local/security/advisories/new).
- **In womarchy itself** (the problem is also in upstream's code): report it to upstream through
  [their private advisory form](https://github.com/sytelus/womarchy/security/advisories/new).

Not sure which? Report it here.

## Supported versions

Only the latest commit on `main`. Your installed system gets fixed packages when you rebuild
(`tools\local-build.ps1`) and then run `omarchy update`, which reads them from your checkout's `out\repo`.

## What protects an installation

- **The package repository is signed with your own key.** `tools\local-setup.ps1` creates it inside the
  `womarchy-build` distro and pins its fingerprint in
  [linux/image/omarchy-key.env](linux/image/omarchy-key.env). Installed systems refuse a database
  without a valid signature. The private key has no passphrase (signing runs unattended), so the build
  distro and any copy of it are as sensitive as the key: see
  [Your signing key](LOCAL-BUILD.md#your-signing-key).
- **Nothing comes from upstream's releases.** `install.ps1` and `omarchy install` only use the
  `omarchy.exe` and image you built. The build checks the Arch Linux WSL image against the SHA-256 that
  two Arch mirrors publish, pins Omarchy's package signing key, and the PKGBUILDs pin every source
  tarball by SHA-256.
- **The connection between Windows and Linux is local and authenticated.** It runs over Hyper-V sockets,
  which only connect this PC to its own WSL VM. Both ends prove a per-session secret before any input or
  clipboard data is exchanged (see [protocol/wdp.h](protocol/wdp.h)).
- **Nothing runs elevated on Windows.** There are no services, drivers or kernel modules. See
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#security-model).

## Known limitations

- **The signing key has no passphrase.** Anyone with a copy of the `womarchy-build` distro can sign
  packages your installed system trusts. Keep that distro, its exports and its backups private.
- **The distro's disk is not encrypted.** A regular Omarchy install encrypts the disk; under WSL the
  distro's virtual disk is a file on your Windows drive, protected only if that drive uses BitLocker.
  The same goes for the build distro's disk, which holds the signing key.
- **The firewall is off by default.** The firewall inside the distro (ufw) is off, because WSL's network
  translation and the Windows firewall already filter incoming connections.
