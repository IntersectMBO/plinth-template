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

| Environment  | What you need locally                       | Project contains               |
| ------------ | ------------------------------------------- | ------------------------------ |
| Nix          | nix (crypto libs provided by the shell)     | sources + nix files            |
| Docker       | docker or a browser (Codespaces)            | sources + .devcontainer        |
| Demeter      | just a browser (hosted; nix inside)         | sources + nix files            |
| GHC + Cabal  | ghcup with GHC 9.6/9.12, cabal, pkg-config  | sources + get-crypto-libs.sh   |

Each project comes with a README covering just that setup. You can also skip
the installer entirely: every project is a subset of the
[template/](template) directory, so copying it (plus
[get-crypto-libs.sh](get-crypto-libs.sh) for the GHC+Cabal setup) works too.

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
into a per-user cache (`~/.cache/plinth-crypto-libs`), linked into the
project at `dist-newstyle/crypto-libs/` — nothing is installed system-wide;
see [get-crypto-libs.sh](get-crypto-libs.sh) (`--prefix` installs them
system-wide instead) and the GHC+Cabal README
([template/readmes/ghc-cabal.md](template/readmes/ghc-cabal.md)).

## Repository layout — for maintainers

- [template/](template) — the project files. The union of every
  environment's files; `install.sh` copies the relevant subset when
  creating a project (see `create_project`). One of
  [template/readmes/](template/readmes) becomes the project's `README.md`.
- [install.sh](install.sh) — the installer served over curl. `--from DIR`
  installs from a local checkout (offline/CI); passing every question's
  flag (`--env ...`) runs it non-interactively.
- [get-crypto-libs.sh](get-crypto-libs.sh) — the crypto-libs bootstrap,
  copied into GHC+Cabal projects next to their `cabal.project`.
- [.github/ci/](.github/ci) — the test suite. Every GitHub workflow is a
  thin wrapper around one of these scripts, so everything can be run
  locally:

  ```
  .github/ci/run-all-local.sh                     # everything
  PLINTH_SKIP_HEAVY=1 .github/ci/run-all-local.sh # fast checks only
  ```

  | Script                     | Checks                                             | Workflow                 |
  | -------------------------- | -------------------------------------------------- | ------------------------ |
  | `lint.sh`                  | shellcheck + syntax over all shell scripts         | `ci.yaml`                |
  | `test-install.sh`          | install.sh end-to-end: exact per-env manifests,    | `ci.yaml`                |
  |                            | failure modes, real crypto download                |                          |
  | `build-ghc-cabal.sh`       | full build of an installed GHC+Cabal project       | `ci.yaml`                |
  | `build-nix.sh`             | full build of an installed Nix project (= Demeter) | `ci.yaml`                |
  | `build-docker.sh`          | full build inside the devx devcontainer image      | `ci.yaml`                |
  | `bump-plutus-version.sh`   | bumps plutus + index-states in template/           | `bump-plutus-version.yml`|
  | `test-blueprint-parity.sh` | blueprint byte-parity between ghcup and nix        | (manual)                 |
  | `megatest.sh`              | the full build matrix (nix + ghcup × GHC 9.6/9.12  | (manual)                 |
  |                            | × local/system crypto libs) run locally, with      |                          |
  |                            | every artifact sandboxed in `__megatest__/`        |                          |

  [ci.yaml](.github/workflows/ci.yaml) runs all of its jobs in parallel on
  every pull request — no path filters, everything is rebuilt and retested.
  There is deliberately no native-Windows job: `plutus-tx-plugin` declares
  `buildable: False` on Windows, so Plinth projects only work there through
  WSL2 (covered by the Linux jobs).
