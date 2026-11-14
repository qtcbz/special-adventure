# AUR builds for the homelab repo

Builds the AUR packages that my projects depend on, once per CPU target, and
publishes each build as a pacman repo named `aur` on its own rolling release:

| Target | `-march` / `-mtune` | Release | Served by the Pi as |
| --- | --- | --- | --- |
| x86-64-v3 (baseline) | `x86-64-v3` / `generic` | [`repo`](../../releases/tag/repo) | `[homelab]` |
| x86-64-v4 | `x86-64-v4` / `generic` | [`repo-x86-64-v4`](../../releases/tag/repo-x86-64-v4) | `[homelab-v4]` |
| Zen 4 | `znver4` / `znver4` | [`repo-znver4`](../../releases/tag/repo-znver4) | `[homelab-znver4]` |

The v4 and znver4 repos only hold packages that compile something. Packages
that are `arch=any` or have no `build()` step (prebuilt `-bin` packages, DKMS
sources) would come out the same, so machines get those from the baseline.
That works because a machine lists its optimized repo right before
`[homelab]`, and pacman takes a package from the first repo that has it.

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
  packages from the releases, signs them, and serves them in the `[homelab]`,
  `[homelab-v4]` and `[homelab-znver4]` repos. Each machine's setup script
  picks the right one for its CPU.

Builds run in a fresh `archlinux:base-devel` container with a read-only token;
a separate job with write access publishes the result and never runs AUR code.
It publishes only when all three targets built, so the repos stay in step.
Projects' CI keeps using the baseline `repo` release, since GitHub's runners
don't always support AVX-512 or Zen 4 code.
Pushes to other branches build without publishing, and the update check starts
a test build for each review PR (see the Actions tab).
