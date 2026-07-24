# Plinth Template

Start a new [Plinth](https://plutus.cardano.intersectmbo.org/docs/) smart
contract project with one command:

```
curl -fsSL https://raw.githubusercontent.com/IntersectMBO/plinth-template/main/install.sh | sh
```

The installer asks which development environment you want, checks that the
required tools are installed, explains what is needed (in particular the
Cardano crypto C libraries), and creates a fresh project folder — named after
your project (default: `my-plinth-project`) — containing just the files that
environment needs:

| Environment  | What you need locally                       | Project contains              |
| ------------ | ------------------------------------------- | ----------------------------- |
| Nix          | nix (crypto libs provided by the shell)     | sources + nix files           |
| Docker       | docker or a browser (Codespaces)            | sources + .devcontainer       |
| Demeter      | just a browser (hosted; nix inside)         | sources + nix files           |
| GHC + Cabal  | ghcup with GHC 9.6/9.12, cabal, pkg-config  | sources + crypto-libs scripts |

Each project comes with a README covering just that setup. You can also skip
the installer entirely and clone this repository directly — it carries the
union of all environments, and every setup works from it as-is.

Whatever you pick, the first thing to run inside the project (and its
environment) is `cabal build all`, which compiles the example auction
validator.

## About the crypto C libraries

Plinth projects depend — via `plutus-core` and `cardano-crypto-class` — on
three C libraries: `libsodium` (VRF-patched), `libsecp256k1` and `libblst`.
The Nix shell, the Docker image and Demeter workspaces provide them (via
nix). GHC+Cabal projects instead download IOG's prebuilt, checksum- and
commit-pinned binaries from
[iohk-nix releases](https://github.com/input-output-hk/iohk-nix/releases)
on first build into a per-user cache (`~/.cache/plinth-crypto-libs`), linked
into the project at `dist-newstyle/crypto-libs/` — nothing is installed
system-wide; see [scripts/get-crypto-libs.sh](scripts/get-crypto-libs.sh)
(`--prefix` installs them system-wide instead) and the GHC+Cabal README
([dev/readmes/ghc-cabal.md](dev/readmes/ghc-cabal.md)).

## Repository layout — for maintainers

This single branch carries the union of every environment's files plus the
machinery around it; `install.sh` selects the relevant subset when creating a
project (see `include_file` and the marked blocks in `cabal.project` and
`nix/project.nix` it transforms):

- [install.sh](install.sh) — the installer served over curl. `--from DIR`
  installs from a local checkout (offline/CI); `--yes --env ...` runs it
  non-interactively.
- [scripts/](scripts) — the crypto-libs bootstrap that ships with GHC+Cabal
  projects ([get-crypto-libs.sh](scripts/get-crypto-libs.sh) and the
  [pkg-config shim](scripts/pkg-config)).
- [dev/readmes/](dev/readmes) — the per-environment READMEs the installer
  places into new projects.
- [dev/ci/](dev/ci) — the test suite. Every GitHub workflow is a thin
  wrapper around one of these scripts, so everything can be run locally:

  ```
  dev/ci/run-all-local.sh                     # everything
  PLINTH_SKIP_HEAVY=1 dev/ci/run-all-local.sh # fast checks only
  ```

  | Script                     | Checks                                              | Workflow               |
  | -------------------------- | --------------------------------------------------- | ---------------------- |
  | `lint.sh`                  | shellcheck + syntax over all shell scripts          | `ci.yml`               |
  | `test-install.sh`          | install.sh end-to-end: exact per-env manifests,     | `ci.yml`               |
  |                            | transforms, failure modes, real crypto download     |                        |
  | `build-ghc-cabal.sh`       | full build of an installed GHC+Cabal project        | `build-ghc-cabal.yml` |
  | `build-nix.sh`             | full build of an installed Nix project (= Demeter)  | `build-nix.yml`       |
  | `build-docker.sh`          | full build inside the devx devcontainer image       | `build-docker.yml`    |
  | `test-blueprint-parity.sh` | blueprint byte-parity between ghcup and nix         | (manual)               |
