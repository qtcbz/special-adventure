# Pinned AUR packages

One file per AUR package, named after the package (its AUR git repo name).
The file holds the AUR git commit that was reviewed and is allowed to be built.

- **Add a package:** create an empty file `packages/<name>` and push. The update
  check opens a PR pinning it (and any AUR dependencies it needs) to the
  current AUR commit, with the full PKGBUILD in the PR for review.
- **Updates:** the daily update check opens one PR per package whose AUR repo
  has moved, showing the diff. Merging it builds and publishes the update.
- **Remove a package:** delete its file. The next build drops it from the repo.

Empty (unpinned) files are never built.
