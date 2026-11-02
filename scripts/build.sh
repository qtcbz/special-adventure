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

# Build for the machines that install these packages, not for whatever CPU the
# GitHub runner has: x86-64-v3 runs on both the Zen 4 box and the i7-7700K
# (no AVX-512 there), tuned for Zen 4.
MARCH=x86-64-v3 MTUNE=znver4 ZIGCPU=x86_64_v3
install -d /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/march.conf <<EOF
CFLAGS="\${CFLAGS/-march=x86-64 -mtune=generic/-march=$MARCH -mtune=$MTUNE}"
CXXFLAGS="\${CXXFLAGS/-march=x86-64 -mtune=generic/-march=$MARCH -mtune=$MTUNE}"
RUSTFLAGS="\$RUSTFLAGS -C target-cpu=$MARCH"
EOF
# Some builds hard-code -march=native (or, for zig, default to the host CPU),
# which ignores the flags above. Wrappers earlier in PATH swap in $MARCH.
for c in cc gcc c++ g++ clang clang++; do
  cat > "/usr/local/bin/$c" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
  case \$a in
    -march=native) a=-march=$MARCH; echo "$c wrapper: -march=native -> $MARCH" >&2 ;;
    -mtune=native) a=-mtune=$MTUNE ;;
  esac
  args+=("\$a")
done
exec /usr/bin/$c "\${args[@]}"
EOF
done
cat > /usr/local/bin/zig <<EOF
#!/bin/bash
# zig build targets the host CPU unless -Dcpu is given (needs standardTargetOptions).
if [[ \${1:-} == build && " \$* " != *" -Dcpu="* ]] && grep -qs standardTargetOptions build.zig; then
  echo "zig wrapper: adding -Dcpu=$ZIGCPU" >&2
  set -- "\$@" -Dcpu=$ZIGCPU
fi
exec /usr/bin/zig "\$@"
EOF
chmod 755 /usr/local/bin/{cc,gcc,c++,g++,clang,clang++,zig}
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

# git sources that follow a branch instead of a fixed commit or tag (VCS packages)
vcs_specs() {  # .SRCINFO path -> one "git+url[#branch=x]" per line
  awk -F' = ' '$1 ~ /^\tsource(_x86_64)?$/ {print $2}' "$1" | sed -E 's/^[^/]*:://' \
    | grep '^git+' | grep -Ev '#(commit|tag)=' | sort -u || true
}

# --- check out every pinned package at its reviewed commit ---
# packages/<name>: line 1 is the AUR commit; for VCS packages each further line
# is "<git source> <upstream commit>", the reviewed upstream commit to build.
declare -A commit owner keep pins   # commit[aur repo]; owner[pkgname or provides] = aur repo
for f in packages/*; do
  name=${f#packages/}
  [[ $name == README.md ]] && continue
  rev=$(head -n1 "$f" | tr -d '[:space:]')
  pins[$name]=$(tail -n +2 "$f" | awk 'NF==2')
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

# --- build VCS sources at their pinned upstream commit, never at branch HEAD ---
errors=()
for name in "${!commit[@]}"; do
  d=$WORK/$name
  for spec in $(vcs_specs "$d/.SRCINFO"); do
    pin=$(awk -v s="$spec" '$1==s {print $2}' <<<"${pins[$name]}")
    if [[ -z $pin ]]; then
      errors+=("$name: upstream source $spec has no pinned commit in packages/$name (merge its PR from the update check)")
      continue
    fi
    # Appended to the PKGBUILD so it runs after source=() is set: rewrite that
    # source to "#commit=<pin>". makepkg then checks out exactly that commit.
    printf '_sa_pin %q %q\n' "$spec" "$pin" >> "$WORK/$name.pins"
  done
  if [[ -f $WORK/$name.pins ]]; then
    { cat <<'PIN'

# --- added by special-adventure: build pinned upstream commits ---
_sa_pin() {
  local a i s n
  for a in source source_x86_64; do
    local -n _arr=$a
    for i in "${!_arr[@]}"; do
      s=${_arr[$i]}; n=
      if [[ $s == *::* ]]; then n=${s%%::*}::; s=${s#*::}; fi
      if [[ $s == "$1" ]]; then _arr[$i]="$n${1%%#*}#commit=$2"; fi
    done
    unset -n _arr
  done
}
PIN
      cat "$WORK/$name.pins"; } | sudo -u builder tee -a "$d/PKGBUILD" >/dev/null
  fi
done

# --- dependency order, and make sure every AUR dependency is pinned too ---
edges=$(mktemp)
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
