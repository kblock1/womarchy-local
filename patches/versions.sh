# Upstream versions the patch series apply to (sourced by tools/setup-src.sh and refresh-patches.sh).
# When moving to a new upstream version: update here, rebase the forks in src/, re-export, rebuild.
AQUAMARINE_REPO=https://github.com/hyprwm/aquamarine
AQUAMARINE_TAG=v0.15.1
HYPRLAND_REPO=https://github.com/hyprwm/Hyprland
HYPRLAND_TAG=v0.56.2
MESA_VERSION=26.2.3   # patches/mesa apply to the release tarball (Arch's mesa PKGBUILD in linux/packages/ref)
