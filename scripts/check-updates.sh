#!/bin/bash
# Opens one PR per AUR package that needs review: packages whose AUR repo has
# moved past the pinned commit, and new (empty) entries in packages/. Each PR
# shows the diff (or, for new packages, the full PKGBUILD) and also pins any
# AUR dependencies that aren't pinned yet.
# This never runs AUR code: it only reads git history and .SRCINFO text.
set -euo pipefail

BASE=${BASE:-main}
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
MAX_DIFF=55000
WORK=$(mktemp -d)
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

clone() {  # name -> prints dir; full clone so old pinned commits can be diffed
  local d=$WORK/$1
  [[ -d $d ]] || git clone -q "https://aur.archlinux.org/$1.git" "$d"
  echo "$d"
}

aur_deps() {  # dir: AUR dependency names in that checkout's .SRCINFO
  local q
  q=$(awk -F' = ' '$1 ~ /^\t(make|check)?depends(_x86_64)?$/ {sub(/[<>=].*/, "", $2); print $2}' "$1/.SRCINFO" \
      | sort -u | jq -Rr @uri | sed 's/^/\&arg[]=/' | tr -d '\n')
  [[ -n $q ]] || return 0
  curl -fsS "https://aur.archlinux.org/rpc/v5/info?v=5${q}" | jq -r '.results[].Name'
}

srcinfo_ver() {
  awk -F' = ' '$1=="\tepoch"&&!e{e=$2":"} $1=="\tpkgver"&&!v{v=$2} $1=="\tpkgrel"&&!r{r=$2} END{print e v "-" r}' "$1/.SRCINFO"
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
    echo "https://aur.archlinux.org/cgit/aur.git/tree/?h=$name&id=$new"
  else
    echo "### \`$name\` → $(srcinfo_ver "$d")"
    echo "https://aur.archlinux.org/cgit/aur.git/diff/?h=$name&id=$new&id2=$old"
  fi
  echo; echo '````diff'; echo "$diff"; echo '````'; echo
}

for f in packages/*; do
  name=${f#packages/}
  [[ $name == README.md ]] && continue
  old=$(tr -d '[:space:]' < "$f")
  new=$(git ls-remote "https://aur.archlinux.org/$name.git" HEAD | cut -f1)
  if [[ -z $new ]]; then echo "::warning::$name was not found in the AUR"; continue; fi
  [[ $new == "$old" ]] && continue

  branch="aur-update/$name"
  if git fetch -q origin "$branch" 2>/dev/null \
     && [[ $(git show "FETCH_HEAD:packages/$name" | tr -d '[:space:]') == "$new" ]]; then
    echo "$name: PR branch already at $new"
    continue
  fi
  echo "$name: ${old:-unpinned} -> $new"

  git checkout -q -B "$branch" "origin/$BASE"
  echo "$new" > "packages/$name"
  body=$(section "$name" "$old" "$new")

  # Pin AUR dependencies that aren't pinned yet (recursively), in the same PR.
  queue=("$name"); added=()
  while (( ${#queue[@]} )); do
    cur=${queue[0]}; queue=("${queue[@]:1}")
    d=$(clone "$cur")
    for dep in $(aur_deps "$d"); do
      [[ -e packages/$dep ]] && continue
      dep_head=$(git ls-remote "https://aur.archlinux.org/$dep.git" HEAD | cut -f1)
      echo "$dep_head" > "packages/$dep"
      added+=("$dep"); queue+=("$dep")
      body+=$'\n'"$(section "$dep" "" "$dep_head")"
    done
  done

  if [[ -z $old ]]; then title="Add $name $(srcinfo_ver "$WORK/$name")"
  else title="Update $name to $(srcinfo_ver "$WORK/$name")"; fi
  intro="Review the changes below before merging. Merging builds this and publishes it to every machine using the homelab repo."
  (( ${#added[@]} )) && intro+=$'\n\n'"This also pins new AUR dependencies: ${added[*]}."
  body="$intro"$'\n\n'"$body"

  git add packages
  git commit -q -m "$title"
  git push -q -f origin "$branch"
  if [[ -n $(gh pr list --head "$branch" --state open --json number --jq '.[].number') ]]; then
    gh pr edit "$branch" --title "$title" --body "$body"
  else
    gh pr create --base "$BASE" --head "$branch" --title "$title" --body "$body"
  fi
  git checkout -q "origin/$BASE"
done
