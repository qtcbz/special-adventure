#!/bin/bash
# Uploads the local "aur" repo to the rolling "repo" release and deletes
# assets for package versions that are no longer in the repo.
# Runs in a separate job from the build, so no AUR code ever runs with write access.
set -euo pipefail
REPO_DIR=${REPO_DIR:-/srv/aur}
TAG=repo

gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --title "AUR builds" \
  --notes "Rolling pacman repo. Server = https://github.com/$GH_REPO/releases/download/$TAG"

cd "$REPO_DIR"
# GitHub assets cannot be symlinks; upload real copies under the names pacman requests.
for db in aur.db aur.files; do
  [[ -e $db.tar.zst ]] && { rm -f "$db"; cp "$db.tar.zst" "$db"; }
done
mapfile -t local_files < <(ls -1 -- *.pkg.tar.zst aur.db aur.db.tar.zst aur.files aur.files.tar.zst 2>/dev/null)

mapfile -t remote < <(gh release view "$TAG" --json assets --jq '.assets[].name')
# Order matters for anyone syncing [aur] mid-publish: new packages first, then
# the db that references them, and only then remove packages the db dropped.
for name in "${local_files[@]}"; do
  [[ $name == aur.* ]] && continue
  printf '%s\n' "${remote[@]}" | grep -qxF "$name" || gh release upload "$TAG" "$name" --clobber
done
for name in "${local_files[@]}"; do
  [[ $name == aur.* ]] && gh release upload "$TAG" "$name" --clobber
done
for name in "${remote[@]}"; do
  printf '%s\n' "${local_files[@]}" | grep -qxF "$name" || gh release delete-asset "$TAG" "$name" -y
done
