# AUR builds for the homelab repo

Builds the AUR packages that my projects depend on and publishes them as a
pacman repo named `aur` on the rolling [`repo` release](../../releases/tag/repo).

- **Add a package:** put its AUR name on a new line in `packages.txt` and push.
  Its AUR dependencies are resolved and built automatically.
- **Updates:** a daily scheduled run rebuilds anything with a newer AUR version.
- **Use in a project's CI** (already in the standard release workflow):

  ```ini
  [aur]
  SigLevel = Optional TrustAll
  Server = https://github.com/qtcbz/special-adventure/releases/download/repo
  ```

- **On my machines** this isn't used directly: a Raspberry Pi pulls the
  packages from the release, signs them, and serves them in the `[homelab]` repo.

Builds run in a fresh `archlinux:base-devel` container with
[aurutils](https://github.com/aurutils/aurutils). Pushes to other branches build
without publishing, which is useful for testing a new package.
