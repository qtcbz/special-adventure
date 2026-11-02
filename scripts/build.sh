#!/bin/bash
# Runs inside an archlinux:base-devel container (see .github/workflows/build.yml).
# Builds everything in packages.txt (plus AUR dependencies) with aurutils into a
# pacman repo named "aur", seeded from the current "repo" release so unchanged
# packages are not rebuilt.
set -euo pipefail

REPO_DIR=/srv/aur
DB="$REPO_DIR/aur.db.tar.zst"
TAG=repo

pacman -Syu --noconfirm --needed git github-cli pacman-contrib
useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
# Let makepkg fetch PGP keys for sources that are signed.
sudo -u builder mkdir -p -m 700 /home/builder/.gnupg
printf 'keyserver hkps://keyserver.ubuntu.com\nkeyserver-options auto-key-retrieve\n' \
  | sudo -u builder tee /home/builder/.gnupg/gpg.conf >/dev/null

# Seed the local repo from the published release.
install -d -o builder -g builder -m 755 "$REPO_DIR"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release download "$TAG" -D "$REPO_DIR" --clobber
  rm -f "$REPO_DIR"/aur.db "$REPO_DIR"/aur.files
  chown -R builder: "$REPO_DIR"
fi
if [[ ! -f $DB ]]; then
  sudo -u builder bsdtar -c --zstd -f "$DB" -T /dev/null
fi
sudo -u builder ln -sf aur.db.tar.zst "$REPO_DIR/aur.db"
printf '\n[aur]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$REPO_DIR" >> /etc/pacman.conf
pacman -Sy --noconfirm

# Bootstrap aurutils (it lives in the AUR itself).
if ! pacman -Si aur/aurutils >/dev/null 2>&1; then
  sudo -u builder git clone --depth 1 https://aur.archlinux.org/aurutils.git /home/builder/aurutils
  (cd /home/builder/aurutils && sudo -u builder makepkg -s --noconfirm)
  sudo -u builder repo-add "$DB" /home/builder/aurutils/*.pkg.tar.zst
  sudo -u builder cp /home/builder/aurutils/*.pkg.tar.zst "$REPO_DIR/"
  pacman -Sy --noconfirm
fi
pacman -S --noconfirm --needed aur/aurutils

mapfile -t pkgs < <(grep -Ev '^[[:space:]]*(#|$)' packages.txt || true)
# -u also rebuilds anything already in the repo that has a newer AUR version.
sudo -u builder env GNUPGHOME=/home/builder/.gnupg \
  aur sync --database aur --noconfirm --noview --upgrades "${pkgs[@]}"
