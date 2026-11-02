#!/bin/bash
# Opens one PR per AUR package that needs review: packages whose AUR repo has
# moved past the pinned commit, VCS (-git) packages whose upstream branch has
# moved past the pinned upstream commit, and new (empty) entries in packages/.
# Each PR shows the diffs (or, for new packages, the full PKGBUILD) and also
# pins any AUR dependencies that aren't pinned yet.
# This never runs AUR code: it only reads git history and .SRCINFO text.
#
# packages/<name>: line 1 is the AUR commit. VCS packages add one line per git
# source that follows a branch: "<git source> <upstream commit>".
set -euo pipefail

BASE=${BASE:-main}
AUR=${AUR:-https://aur.archlinux.org}
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
MAX_DIFF=55000
MAX_BODY=60000
WORK=$(mktemp -d)
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

clone() {  # name -> prints dir; full clone so old pinned commits can be diffed
  local d=$WORK/$1
  [[ -d $d ]] || git clone -q "$AUR/$1.git" "$d"
  echo "$d"
}

aur_deps() {  # dir: AUR dependency names in that checkout's .SRCINFO
  local q
  q=$(awk -F' = ' '$1 ~ /^\t(make|check)?depends(_x86_64)?$/ {sub(/[<>=].*/, "", $2); print $2}' "$1/.SRCINFO" \
      | sort -u | jq -Rr @uri | sed 's/^/\&arg[]=/' | tr -d '\n')
  [[ -n $q ]] || return 0
  curl -fsS "$AUR/rpc/v5/info?v=5${q}" | jq -r '.results[].Name'
}

srcinfo_ver() {
  awk -F' = ' '$1=="\tepoch"&&!e{e=$2":"} $1=="\tpkgver"&&!v{v=$2} $1=="\tpkgrel"&&!r{r=$2} END{print e v "-" r}' "$1/.SRCINFO"
}

vcs_specs() {  # dir: git sources that follow a branch, as "git+url[#branch=x]"
  awk -F' = ' '$1 ~ /^\tsource(_x86_64)?$/ {print $2}' "$1/.SRCINFO" | sed -E 's/^[^/]*:://' \
    | grep '^git+' | grep -Ev '#(commit|tag)=' | sort -u || true
}

spec_url() { local u=${1#git+}; u=${u%%#*}; echo "${u%%\?*}"; }

upstream_head() {  # spec -> current commit of the branch it follows
  local ref=HEAD
  [[ $1 == *'#branch='* ]] && ref=refs/heads/${1##*#branch=}
  git ls-remote "$(spec_url "$1")" "$ref" | head -1 | cut -f1
}

pin_lines() {  # dir -> "spec commit" for each VCS source, at upstream HEAD now
  local spec h
  for spec in $(vcs_specs "$1"); do
    h=$(upstream_head "$spec")
    [[ -n $h ]] || { echo "::warning::could not resolve upstream $spec" >&2; return 1; }
    echo "$spec $h"
  done
}

upstream_section() {  # spec old new -> markdown for one upstream change
  local spec=$1 old=$2 new=$3 url gh= d log diff
  url=$(spec_url "$spec")
  if [[ $url == https://github.com/* ]]; then gh=${url#https://github.com/}; gh=${gh%/}; gh=${gh%.git}; fi
  if [[ -z $old ]]; then
    echo "#### upstream \`$url\` pinned at \`$new\` (new)"
    [[ -n $gh ]] && echo "https://github.com/$gh/tree/$new"
    echo; echo "This is the upstream code that gets built. It isn't shown here; review it at the link."; echo
    return
  fi
  echo "#### upstream \`$url\` \`${old:0:12}\` → \`${new:0:12}\`"
  [[ -n $gh ]] && echo "https://github.com/$gh/compare/$old...$new"
  d=$WORK/upstream-$(sha1sum <<<"$url" | cut -c1-12)
  [[ -d $d ]] || git clone -q --bare --filter=blob:none "$url" "$d"
  if ! git -C "$d" cat-file -e "$old^{commit}" 2>/dev/null; then
    echo; echo "**The previous pin is no longer in upstream history (force-push?). Review the new commit in full.**"; echo
    return
  fi
  log=$(git -C "$d" log --oneline --no-decorate "$old..$new" | head -200)
  diff=$(git -C "$d" diff "$old" "$new")
  if (( ${#diff} > MAX_DIFF )); then diff="${diff:0:$MAX_DIFF}"$'\n... (truncated, see the compare link)'; fi
  echo; echo '````'; echo "$log"; echo '````'
  echo; echo '````diff'; echo "$diff"; echo '````'; echo
}

section() {  # name old new -> markdown for one package
  local name=$1 old=$2 new=$3 d diff from
  d=$(clone "$name")
  git -C "$d" -c advice.detachedHead=false checkout -q "$new"
  from=$EMPTY_TREE
  if [[ -n $old ]] && git -C "$d" cat-file -e "$old^{commit}" 2>/dev/null; then from=$old; fi
  diff=$(git -C "$d" diff "$from" "$new" -- . ':(exclude).SRCINFO')
  if (( ${#diff} > MAX_DIFF )); then diff="${diff:0:$MAX_DIFF}"$'\n... (truncated, see the AUR link)'; fi
  if [[ $from == "$EMPTY_TREE" ]]; then
    echo "### \`$name\` $(srcinfo_ver "$d") (new, full contents)"
    echo "$AUR/cgit/aur.git/tree/?h=$name&id=$new"
  else
    echo "### \`$name\` → $(srcinfo_ver "$d")"
    echo "$AUR/cgit/aur.git/diff/?h=$name&id=$new&id2=$old"
  fi
  echo; echo '````diff'; echo "$diff"; echo '````'; echo
}

for f in packages/*; do
  name=${f#packages/}
  [[ $name == README.md ]] && continue
  old=$(head -n1 "$f" | tr -d '[:space:]')
  oldpins=$(tail -n +2 "$f" | awk 'NF==2')
  new=$(git ls-remote "$AUR/$name.git" HEAD | head -1 | cut -f1)
  if [[ -z $new ]]; then echo "::warning::$name was not found in the AUR"; continue; fi
  [[ $new == "$old" && -z $oldpins ]] && continue   # not a VCS package, nothing new

  # Work out the upstream pins this PR would carry: same sources as before if
  # the AUR side hasn't moved, otherwise the sources in the new .SRCINFO.
  if [[ $new == "$old" ]]; then
    newpins=""
    while read -r spec _; do
      h=$(upstream_head "$spec")
      [[ -n $h ]] || { echo "::warning::could not resolve upstream $spec"; continue 2; }
      newpins+="$spec $h"$'\n'
    done <<<"$oldpins"
    newpins=${newpins%$'\n'}
    [[ $newpins == "$oldpins" ]] && continue
  else
    d=$(clone "$name")
    git -C "$d" -c advice.detachedHead=false checkout -q "$new"
    newpins=$(pin_lines "$d") || continue
  fi
  content=$new; [[ -n $newpins ]] && content+=$'\n'"$newpins"

  branch="aur-update/$name"
  # Skip only when an open PR already carries exactly these pins. Checking the
  # branch alone would skip forever if the push succeeded but the PR failed.
  if git fetch -q origin "$branch" 2>/dev/null \
     && [[ $(git show "FETCH_HEAD:packages/$name") == "$content" ]] \
     && [[ -n $(gh pr list --head "$branch" --state open --json number --jq '.[].number') ]]; then
    echo "$name: open PR already has these pins"
    continue
  fi
  echo "$name: ${old:-unpinned} -> $new${newpins:+ (upstream: $(awk '{printf "%s ", substr($2,1,12)}' <<<"$newpins"))}"

  git checkout -q -B "$branch" "origin/$BASE"
  printf '%s\n' "$content" > "packages/$name"
  body=""
  [[ $new != "$old" ]] && body=$(section "$name" "$old" "$new")
  while read -r spec h; do
    [[ -n $spec ]] || continue
    was=$(awk -v s="$spec" '$1==s {print $2}' <<<"$oldpins")
    [[ $was == "$h" ]] && continue
    body+=$'\n'"$(upstream_section "$spec" "$was" "$h")"
  done <<<"$newpins"

  # Pin AUR dependencies that aren't pinned yet (recursively), in the same PR.
  queue=("$name"); added=()
  while (( ${#queue[@]} )); do
    cur=${queue[0]}; queue=("${queue[@]:1}")
    d=$(clone "$cur")
    for dep in $(aur_deps "$d"); do
      [[ -e packages/$dep ]] && continue
      dep_head=$(git ls-remote "$AUR/$dep.git" HEAD | head -1 | cut -f1)
      dd=$(clone "$dep")
      git -C "$dd" -c advice.detachedHead=false checkout -q "$dep_head"
      if ! dep_pins=$(pin_lines "$dd"); then
        echo "::warning::skipping $name: upstream of $dep unresolved"
        git checkout -q -f "origin/$BASE"; git clean -fdq packages
        continue 3
      fi
      { echo "$dep_head"; [[ -z $dep_pins ]] || echo "$dep_pins"; } > "packages/$dep"
      added+=("$dep"); queue+=("$dep")
      body+=$'\n'"$(section "$dep" "" "$dep_head")"
      while read -r spec h; do
        [[ -n $spec ]] && body+=$'\n'"$(upstream_section "$spec" "" "$h")"
      done <<<"$dep_pins"
    done
  done

  if [[ -z $old ]]; then title="Add $name $(srcinfo_ver "$WORK/$name")"
  elif [[ $new != "$old" ]]; then title="Update $name to $(srcinfo_ver "$WORK/$name")"
  else title="Update $name upstream to $(awk '{printf "%s%s", s, substr($2,1,12); s=", "}' <<<"$newpins")"; fi
  intro="Review the changes below before merging. Merging builds this and publishes it to every machine using the homelab repo."
  (( ${#added[@]} )) && intro+=$'\n\n'"This also pins new AUR dependencies: ${added[*]}."
  body="$intro"$'\n\n'"$body"
  # GitHub rejects bodies over 65536 characters; a new package with new
  # dependencies can exceed that. Cut it and close any fence left open.
  if (( ${#body} > MAX_BODY )); then
    body="${body:0:$MAX_BODY}"
    (( $(grep -c '^````' <<<"$body") % 2 )) && body+=$'\n````'
    body+=$'\n\n... (truncated: the PR body hit GitHub'"'"'s size limit; review the rest at the AUR links above)'
  fi

  git add packages
  git commit -q -m "$title"
  git push -q -f origin "$branch"
  if [[ -n $(gh pr list --head "$branch" --state open --json number --jq '.[].number') ]]; then
    gh pr edit "$branch" --title "$title" --body "$body"
  else
    gh pr create --base "$BASE" --head "$branch" --title "$title" --body "$body"
  fi
  # Pushes made with GITHUB_TOKEN never trigger build.yml, so start a test build
  # of the branch by hand (publishing is skipped off main). It shows in Actions.
  gh workflow run build.yml --ref "$branch" \
    || echo "::warning::could not start a test build for $branch"
  git checkout -q "origin/$BASE"
done
