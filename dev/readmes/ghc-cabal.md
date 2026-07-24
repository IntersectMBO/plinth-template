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
cabal update
cabal build all
```

## The crypto C libraries

`plutus-core` depends (via `cardano-crypto-class`) on three C libraries —
`libsodium` (VRF-patched), `libsecp256k1` and `libblst` — which cabal locates
with pkg-config. This project routes pkg-config through `scripts/pkg-config`
(see the `program-locations` stanza in `cabal.project`): on first use the
shim downloads the prebuilt libraries published by IOG at
[iohk-nix releases](https://github.com/input-output-hk/iohk-nix/releases)
into a per-user cache (`~/.cache/plinth-crypto-libs`, override with
`PLINTH_CRYPTO_LIBS_HOME`), links them into the project at
`dist-newstyle/crypto-libs/`, and answers cabal's pkg-config queries from
there. Nothing is installed system-wide; the cache is shared by all your
Plinth projects, and it is the cache path (not the project path) that gets
baked into the packages cabal compiles, so the cabal store stays valid if
the project is moved or deleted. Every downloaded artifact is verified
against sha256 digests and an iohk-nix commit hash pinned inside
`scripts/get-crypto-libs.sh`. Only `curl`, `tar` and `shasum`/`sha256sum`
are needed, all of which ship with macOS and Linux.

This behavior is ON by default. To opt out and use crypto libraries
installed system-wide instead, set `PLINTH_USE_SYSTEM_CRYPTO_LIBS=1`: the
shim then delegates to the real pkg-config on your PATH and nothing is
downloaded. To install IOG's prebuilt libraries system-wide in the first
place, run `./scripts/get-crypto-libs.sh --prefix /usr/local` (or any other
prefix; see `--help`).

When cross compiling, set `PLINTH_CRYPTO_LIBS_PLATFORM` to the target
platform (`arm64-macos`, `x86_64-macos` or `debian`) and the shim serves
the target's libraries regardless of the build host.

> NOTE:
> Run cabal from the project root: the `pkg-config-location` path in
> `cabal.project` is resolved relative to the invocation directory.

> NOTE (first build only):
> The very first build on a fresh clone downloads the libraries and writes
> their absolute location into `cabal.project.local` (gitignored) — too late
> for that same run's configure phase, so it stops once with
> *"Cannot find the program 'pkg-config'"*. Simply re-run `cabal build`;
> everything already built is reused, and the interruption never happens
> again (not even after `cabal clean`). To skip it entirely, run
> `./scripts/get-crypto-libs.sh` once before the first build.

> NOTE:
> Only a symlink lives under `dist-newstyle/`, so `cabal clean` costs
> nothing: the next build re-links the cached libraries instantly (no
> re-download). Run `./scripts/get-crypto-libs.sh` yourself at any time.

> NOTE (for Windows users):
> Prebuilt MSYS2 packages (`msys2.*.pkg.tar.zstd`) are published in the same
> release. Install them with `pacman -U` inside GHC's MSYS2 environment
> (`ghcup run mingw-pacman -- -U <pkg>`), or use WSL2 and follow the Linux
> instructions.

## 3. Run the example application

Read [Example: An Auction Smart Contract](https://plutus.cardano.intersectmbo.org/docs/category/example-an-auction-smart-contract)
to get started.
