# AUR builds for the homelab repo

Builds the AUR packages that my projects depend on and publishes them as a
pacman repo named `aur` on the rolling [`repo` release](../../releases/tag/repo).

- **Add a package:** create an empty file `packages/<aur-name>` and push. A PR
  opens that pins it (and any AUR dependencies) to the current AUR commit, with
  the full PKGBUILD to review. Merging it builds and publishes the package.
- **Updates are reviewed, never automatic:** a daily check opens one PR per
  package whose AUR repo has changed, showing the diff. Nothing new is built
  until you merge. See [packages/README.md](packages/README.md).
- **Use in a project's CI** (already in the standard release workflow):

  ```ini
  [aur]
  SigLevel = Optional TrustAll
  Server = https://github.com/qtcbz/special-adventure/releases/download/repo
  ```

- **On my machines** this isn't used directly: a Raspberry Pi pulls the
  packages from the release, signs them, and serves them in the `[homelab]` repo.

Builds run in a fresh `archlinux:base-devel` container with a read-only token;
a separate job with write access publishes the result and never runs AUR code.
Pushes to other branches build without publishing.
