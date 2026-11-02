#!/bin/bash
# Runs inside an archlinux:base-devel container (see .github/workflows/build.yml).
# Builds every pinned package in packages/ at its pinned AUR commit into a pacman
# repo named "aur". The repo is seeded from the current "repo" release, so
# packages whose version hasn't changed are not rebuilt.
set -euo pipefail

REPO_DIR=/srv/aur
DB="$REPO_DIR/aur.db.tar.zst"
WORK=/home/builder/src
TAG=repo

pacman -Syu --noconfirm --needed git github-cli pacman-contrib
sed -i 's/^\(OPTIONS=.*\)\bdebug\b/\1!debug/' /etc/makepkg.conf   # no -debug packages
useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder
# Let makepkg fetch PGP keys for sources that are signed.
sudo -u builder mkdir -p -m 700 /home/builder/.gnupg
printf 'keyserver hkps://keyserver.ubuntu.com\nkeyserver-options auto-key-retrieve\n' \
  | sudo -u builder tee /home/builder/.gnupg/gpg.conf >/dev/null

# --- seed the local repo from the published release ---
install -d -o builder -g builder -m 755 "$REPO_DIR"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release download "$TAG" -D "$REPO_DIR" --clobber
  rm -f "$REPO_DIR"/aur.db "$REPO_DIR"/aur.files
  chown -R builder: "$REPO_DIR"
fi
[[ -f $DB ]] || sudo -u builder bsdtar -c --zstd -f "$DB" -T /dev/null
sudo -u builder ln -sf aur.db.tar.zst "$REPO_DIR/aur.db"
printf '\n[aur]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$REPO_DIR" >> /etc/pacman.conf
pacman -Sy --noconfirm

# --- check out every pinned package at its reviewed commit ---
declare -A commit owner keep   # commit[aur repo]; owner[pkgname or provides] = aur repo
for f in packages/*; do
  name=${f#packages/}
  [[ $name == README.md ]] && continue
  rev=$(tr -d '[:space:]' < "$f")
  if [[ -z $rev ]]; then
    echo "::warning::$name is not pinned yet, skipping it (merge its PR from the update check)"
    keep[$name]=1   # leave any already-published build alone until it's pinned
    continue
  fi
  commit[$name]=$rev
done

sudo -u builder mkdir -p "$WORK"
for name in "${!commit[@]}"; do
  d=$WORK/$name
  sudo -u builder git clone -q "https://aur.archlinux.org/$name.git" "$d"
  sudo -u builder git -C "$d" -c advice.detachedHead=false checkout -q "${commit[$name]}"
  while read -r k _ v; do
    [[ $k == pkgname || $k == provides* ]] && owner[${v%%[<>=]*}]=$name
  done < "$d/.SRCINFO"
done

# --- dependency order, and make sure every AUR dependency is pinned too ---
edges=$(mktemp); errors=()
for name in "${!commit[@]}"; do
  echo "$name $name" >> "$edges"
  while read -r k _ v; do
    case $k in depends|depends_x86_64|makedepends|makedepends_x86_64|checkdepends) ;; *) continue ;; esac
    dep=${v%%[<>=]*}
    if [[ -n ${owner[$dep]:-} ]]; then
      [[ ${owner[$dep]} != "$name" ]] && echo "${owner[$dep]} $name" >> "$edges"
    else
      r=$(pacman -Sp --print-format '%r' "$dep" 2>/dev/null | tail -1 || true)
      [[ -n $r && $r != aur ]] || errors+=("$dep (needed by $name) is not in the official repos and not pinned in packages/")
    fi
  done < "$WORK/$name/.SRCINFO"
done
if (( ${#errors[@]} )); then
  printf '::error::%s\n' "${errors[@]}"
  exit 1
fi

# --- build anything whose pinned version isn't in the repo yet ---
srcinfo_ver() {  # .SRCINFO text on stdin -> [epoch:]pkgver-pkgrel
  awk -F' = ' '$1=="\tepoch"&&!e{e=$2":"} $1=="\tpkgver"&&!v{v=$2} $1=="\tpkgrel"&&!r{r=$2} END{print e v "-" r}'
}
for name in $(tsort "$edges"); do
  d=$WORK/$name
  ver=$(srcinfo_ver < "$d/.SRCINFO")
  # VCS packages (-git etc.) work out their real version in pkgver() from the
  # upstream checkout; .SRCINFO only has whatever the AUR maintainer last saw.
  # Fetch the sources and run pkgver() so the check below compares the version
  # that would actually be built. Otherwise they'd be rebuilt on every run, and
  # a rebuild of an unchanged version reuses the file name, which publish.sh
  # doesn't re-upload while the db gets the new checksum.
  if grep -Eq '^[[:space:]]*pkgver[[:space:]]*\(\)' "$d/PKGBUILD"; then
    (cd "$d" && sudo -u builder makepkg --nobuild --noprepare --nodeps --noconfirm)
    ver=$(cd "$d" && sudo -u builder makepkg --printsrcinfo | srcinfo_ver)
  fi
  first=$(awk -F' = ' '$1=="pkgname"{print $2; exit}' "$d/.SRCINFO")
  have=$(pacman -Si "aur/$first" 2>/dev/null | awk -F' *: ' '$1=="Version"{print $2}' || true)
  if [[ $have == "$ver" ]]; then
    echo "$name $ver: already built"
    continue
  fi
  echo "::group::Build $name $ver (pinned ${commit[$name]})"
  (cd "$d" && sudo -u builder makepkg --syncdeps --noconfirm)
  for pkg in "$d"/*.pkg.tar.zst; do
    # Packages with an epoch have a ':' in the file name, which GitHub renames
    # on upload, so the db would point at a file that doesn't exist. pacman
    # only needs the name to match the db, so store it without the ':'.
    file=${pkg##*/}; file=${file//:/.}
    sudo -u builder cp "$pkg" "$REPO_DIR/$file"
    sudo -u builder repo-add -q -R "$DB" "$REPO_DIR/$file"
  done
  pacman -Sy --noconfirm
  echo "::endgroup::"
done

# --- drop packages that are no longer pinned ---
while read -r _ pkg _; do
  [[ -n ${owner[$pkg]:-} || -n ${keep[$pkg]:-} ]] && continue
  file=$(pacman -Sp --print-format '%f' "aur/$pkg")
  echo "removing $pkg (no longer in packages/)"
  sudo -u builder repo-remove -q "$DB" "$pkg"
  rm -f "$REPO_DIR/$file"
done < <(pacman -Sl aur)

# Keep only the newest version of each package, and drop the db symlinks
# (artifacts can't hold symlinks; publish.sh uploads real copies instead).
paccache -rk1 -c "$REPO_DIR" >/dev/null 2>&1 || true
rm -f "$REPO_DIR"/aur.db "$REPO_DIR"/aur.files
