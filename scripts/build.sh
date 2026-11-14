#!/bin/bash
# Runs inside an archlinux:base-devel container (see .github/workflows/build.yml).
# Builds every pinned package in packages/ at its pinned AUR commit into a pacman
# repo named "aur", for one CPU target (TARGET):
#   x86-64-v3  -> release "repo"            (baseline; the Pi serves it as [homelab])
#   x86-64-v4  -> release "repo-x86-64-v4"  ([homelab-v4])
#   znver4     -> release "repo-znver4"     ([homelab-znver4])
# The repo is seeded from the target's current release, so packages whose
# version hasn't changed are not rebuilt.
#
# The v4 and znver4 repos only hold packages that actually compile something.
# Packages that are arch=any or have no build() step (prebuilt -bin packages,
# DKMS sources) would come out identical, so they are skipped there and machines
# get them from the baseline repo. BASE_DIR points at the baseline build
# (the x86-64-v3 job's output), so those packages can still be build deps.
set -euo pipefail

TARGET=${TARGET:-x86-64-v3}
REPO_DIR=/srv/aur
DB="$REPO_DIR/aur.db.tar.zst"
WORK=/home/builder/src
BASE_DIR=${BASE_DIR:-}

# Build for the machines that install these packages, not for whatever CPU the
# GitHub runner has.
case $TARGET in
  x86-64-v3) TAG=repo           MARCH=x86-64-v3 MTUNE=generic RUSTCPU=x86-64-v3 ZIGCPU=x86_64_v3 ;;
  x86-64-v4) TAG=repo-x86-64-v4 MARCH=x86-64-v4 MTUNE=generic RUSTCPU=x86-64-v4 ZIGCPU=x86_64_v4 ;;
  znver4)    TAG=repo-znver4    MARCH=znver4    MTUNE=znver4  RUSTCPU=znver4    ZIGCPU=znver4 ;;
  *) echo "::error::unknown TARGET $TARGET"; exit 1 ;;
esac
BASELINE=0; [[ $TARGET == x86-64-v3 ]] && BASELINE=1
echo "Target $TARGET: -march=$MARCH -mtune=$MTUNE, publishes to release $TAG"

pacman -Syu --noconfirm --needed git github-cli pacman-contrib
sed -i 's/^\(OPTIONS=.*\)\bdebug\b/\1!debug/' /etc/makepkg.conf   # no -debug packages

install -d /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/march.conf <<EOF
CFLAGS="\${CFLAGS/-march=x86-64 -mtune=generic/-march=$MARCH -mtune=$MTUNE}"
CXXFLAGS="\${CXXFLAGS/-march=x86-64 -mtune=generic/-march=$MARCH -mtune=$MTUNE}"
RUSTFLAGS="\$RUSTFLAGS -C target-cpu=$RUSTCPU"
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
if (( ! BASELINE )); then
  [[ -f $BASE_DIR/aur.db.tar.zst ]] || { echo "::error::BASE_DIR has no baseline build"; exit 1; }
  ln -sf aur.db.tar.zst "$BASE_DIR/aur-base.db"
  printf '\n[aur-base]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$BASE_DIR" >> /etc/pacman.conf
fi
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
      [[ -n $r && $r != aur && $r != aur-base ]] || errors+=("$dep (needed by $name) is not in the official repos and not pinned in packages/")
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
same_on_every_cpu() {  # dir: nothing gets compiled, so the baseline build is enough
  awk -F' = ' '$1=="\tarch" && $2!="any" {f=1} END {exit f}' "$1/.SRCINFO" && return 0
  ! grep -Eq '^[[:space:]]*(function[[:space:]]+)?build[[:space:]]*\(\)' "$1/PKGBUILD"
}
declare -A skip
for name in $(tsort "$edges"); do
  d=$WORK/$name
  if (( ! BASELINE )) && same_on_every_cpu "$d"; then
    echo "$name: nothing to compile, $TARGET machines use the baseline build"
    skip[$name]=1
    continue
  fi
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
  o=${owner[$pkg]:-}
  [[ ( -n $o && -z ${skip[$o]:-} ) || -n ${keep[$pkg]:-} ]] && continue
  file=$(pacman -Sp --print-format '%f' "aur/$pkg")
  # A skipped package must not linger here either: machines list this repo
  # first, so an old copy would hide the baseline's newer one.
  echo "removing $pkg (no longer in packages/, or the baseline build is used for it)"
  sudo -u builder repo-remove -q "$DB" "$pkg"
  rm -f "$REPO_DIR/$file"
done < <(pacman -Sl aur)

# Keep only the newest version of each package, and drop the db symlinks
# (artifacts can't hold symlinks; publish.sh uploads real copies instead).
paccache -rk1 -c "$REPO_DIR" >/dev/null 2>&1 || true
rm -f "$REPO_DIR"/aur.db "$REPO_DIR"/aur.files
