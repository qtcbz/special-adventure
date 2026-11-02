# Pinned AUR packages

One file per AUR package, named after the package (its AUR git repo name).
The file's first line is the AUR git commit that was reviewed and is allowed to be built.

- **Add a package:** create an empty file `packages/<name>` and push. The update
  check opens a PR pinning it (and any AUR dependencies it needs) to the
  current AUR commit, with the full PKGBUILD in the PR for review.
- **Updates:** the daily update check opens one PR per package whose AUR repo
  has moved, showing the diff. Merging it builds and publishes the update.
- **Remove a package:** delete its file. The next build drops it from the repo.

Empty (unpinned) files are never built.

**VCS packages (`-git` etc.)** are pinned upstream too. Their file has one more
line per git source that follows a branch: `<git source> <upstream commit>`.
The build checks out exactly that commit, and the daily check opens a PR with
the upstream log and diff when the branch moves. The first pin of a new package
links to the upstream code instead of showing it.
