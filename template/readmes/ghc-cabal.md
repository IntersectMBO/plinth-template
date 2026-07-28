# Plinth Template (GHC + Cabal edition)

A template for your Plinth smart contract project, built with your own
**GHC and Cabal** — no nix, no docker, and no system-wide C libraries.

## 1. Prerequisites

- [ghcup](https://www.haskell.org/ghcup/) with **GHC 9.6.x or 9.12.x**
  (e.g. `ghcup install ghc 9.6.7 && ghcup set ghc 9.6.7`)
- **Cabal 3.8+** (`ghcup install cabal latest`)
- a **pkg-config** executable
  (macOS: `brew install pkgconf`, Debian/Ubuntu: `apt install pkg-config`)

## 2. Build

From the project root:

```
./get-crypto-libs.sh                       # first time only; see below
source dist-newstyle/crypto-libs/env.sh    # points pkg-config at the libraries
cabal update
cabal build all
```

(If you created this project with `install.sh`, the installer already ran
`./get-crypto-libs.sh` for you.)

## The crypto C libraries

`plutus-core` depends (via `cardano-crypto-class`) on three C libraries —
`libsodium` (VRF-patched), `libsecp256k1` and `libblst` — which cabal locates
with pkg-config. `./get-crypto-libs.sh` downloads the prebuilt libraries
published by IOG at
[iohk-nix releases](https://github.com/input-output-hk/iohk-nix/releases)
into a per-user cache (`~/.cache/plinth-crypto-libs`, override with
`PLINTH_CRYPTO_LIBS_HOME`), links them into the project at
`dist-newstyle/crypto-libs/`, and writes
`dist-newstyle/crypto-libs/env.sh`, which puts them on pkg-config's search
path (`PKG_CONFIG_PATH`) — source it in every shell you build from (or add
the export to your shell profile).

Nothing is installed system-wide; the cache is shared by all your Plinth
projects, and it is the cache path (not the project path) that gets baked
into the packages cabal compiles, so the cabal store stays valid if the
project is moved or deleted. Every downloaded artifact is verified against
sha256 digests and an iohk-nix commit hash pinned inside
`get-crypto-libs.sh`. Only `curl`, `tar` and `shasum`/`sha256sum` are
needed, all of which ship with macOS and Linux.

To install IOG's prebuilt libraries system-wide instead, run
`./get-crypto-libs.sh --prefix /usr/local` (or any other prefix; see
`--help`) and put `<prefix>/lib/pkgconfig` on `PKG_CONFIG_PATH`. If you
already have the three libraries installed some other way, skip the script
entirely and make sure pkg-config can find them.

When cross compiling, set `PLINTH_CRYPTO_LIBS_PLATFORM` to the target
platform (`arm64-macos`, `x86_64-macos` or `debian`) and the script installs
the target's libraries regardless of the build host.

> NOTE:
> Only a symlink (and `env.sh`) lives under `dist-newstyle/`, so
> `cabal clean` costs nothing: re-running `./get-crypto-libs.sh` restores
> both instantly from the cache (no re-download).

> NOTE (for Windows users):
> Plinth does not work on native Windows: `plutus-tx-plugin` declares
> `buildable: False` there. Use
> [WSL2](https://learn.microsoft.com/windows/wsl/install) and follow the
> Linux instructions.

## 3. Run the example application

Read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract)
to get started.
