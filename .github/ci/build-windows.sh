#!/usr/bin/env bash
#
# Build the template on native Windows: GHC + Cabal with the Cardano crypto
# C libraries installed as MSYS2 (MINGW64) pacman packages from IOG's pinned
# iohk-nix releases — the same releases get-crypto-libs.sh downloads from on
# macOS and Linux.
#
# CI runs this inside the runner's MSYS2 bash (see ci.yaml); locally, run it
# from an "MSYS2 MINGW64" shell on a Windows machine with ghc 9.6.x/9.12.x
# and cabal (>= 3.8) on PATH:
#
#   bash .github/ci/build-windows.sh
#
# The libraries are installed into /mingw64/opt/cardano (that is,
# C:\msys64\mingw64\opt\cardano) — pacman-managed, confined to the MSYS2
# prefix (a throwaway on CI runners).
#
# NOTE: install.sh does not support native Windows (it points users to
# WSL2); this script instead proves the template itself builds with a native
# Windows toolchain, which is what a user gets by copying template/ by hand
# and installing the msys2.* packages as described in the GHC+Cabal README.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "build-windows: FAIL: $*" >&2; exit 1; }
note() { echo "build-windows: $*"; }

# When bash.exe is invoked directly (as CI does) no login profile runs, so
# MSYSTEM is never processed and MSYS2's own /usr/bin — pacman, cygpath,
# sha256sum — is not on PATH; only the inherited Windows PATH is. Prepend it
# explicitly. (In a regular "MSYS2 MINGW64" shell this is a no-op.)
export PATH="/usr/bin:$PATH"

case "$(uname -s)" in
  MINGW64_NT*|MSYS_NT*) ;;
  *) fail "this script must run inside an MSYS2 (MINGW64) environment on Windows" ;;
esac
if ! command -v pacman >/dev/null 2>&1; then
  fail "pacman not found — run this from an MSYS2 shell (C:\\msys64), not Git Bash"
fi
if ! command -v ghc >/dev/null 2>&1; then
  fail "ghc not on PATH"
fi
if ! command -v cabal >/dev/null 2>&1; then
  fail "cabal not on PATH"
fi
GHC_VERSION="$(ghc --numeric-version)"
case "$GHC_VERSION" in
  9.6.*|9.12.*) note "ghc $GHC_VERSION ($(command -v ghc))" ;;
  *) fail "unsupported ghc $GHC_VERSION (need 9.6.x or 9.12.x)" ;;
esac
note "cabal $(cabal --numeric-version) ($(command -v cabal))"

# --------------------------------------------------------------------------
# Crypto C libraries, as sha256-pinned MSYS2 pacman packages from iohk-nix
# releases.
#
# libblst deliberately comes from the older v2.2 release: the newer build
# trips GHC's runtime linker on Windows ("duplicate definition for symbol
# __blst_platform_cap") — see input-output-hk/actions/base, which carries
# the same workaround.
# --------------------------------------------------------------------------

RELEASES="https://github.com/input-output-hk/iohk-nix/releases/download"
ASSETS="
v3.1/msys2.libsodium.pkg.tar.zstd c9ed5b531309369f92d67e6f7c1e003d3c0c96d777f66c9d8a8c1aeca6d8ef4d
v3.1/msys2.libsecp256k1.pkg.tar.zstd b1cf83dce1a38241491209ac0ff75c92b06a05012eecb81d713373bc0d861a40
v2.2/msys2.libblst.pkg.tar.zstd f03037ff3384fed4af70ecaabe890ddbd7ff766e871f76d0e9a48e42d818282c
"

# cabal locates the libraries with pkg-config; the mingw-w64 pkg-config
# build is the one variant that copes with Windows-style PKG_CONFIG_PATH
# values (see input-output-hk/actions/base for the sad full story).
note "installing mingw-w64-x86_64-pkg-config (pacman)..."
pacman -S --noconfirm --needed mingw-w64-x86_64-pkg-config

DOWNLOADS="$(mktemp -d)"
trap 'rm -rf "$DOWNLOADS"' EXIT
while read -r asset sha; do
  if [ -z "$asset" ]; then
    continue
  fi
  file="$DOWNLOADS/${asset##*/}"
  note "downloading $asset ..."
  curl -fsSL --retry 3 -o "$file" "$RELEASES/$asset"
  if ! echo "$sha  $file" | sha256sum -c - >/dev/null; then
    fail "sha256 mismatch for $asset"
  fi
  note "verified $asset (sha256 OK)"
done <<EOF
$ASSETS
EOF

note "installing the crypto libraries into /mingw64/opt/cardano (pacman -U)..."
pacman -U --noconfirm "$DOWNLOADS"/*.pkg.tar.zstd

# Native tools (cabal, its pkg-config, the produced executable loading the
# DLLs at run time) need:
#   * pkg-config and the DLL directory on PATH — bash converts PATH for
#     native child processes automatically;
#   * PKG_CONFIG_PATH in Windows form — MSYS2 does NOT convert arbitrary
#     environment variables, and pkg-config here is a native binary.
export PATH="/mingw64/opt/cardano/bin:/mingw64/bin:$PATH"
PKG_CONFIG_PATH="$(cygpath -m /mingw64/opt/cardano/lib/pkgconfig)"
export PKG_CONFIG_PATH
# mingw-w64-x86_64-pkg-config strips /mingw64 system directories from its
# answers unless told otherwise.
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1 PKG_CONFIG_ALLOW_SYSTEM_LIBS=1

if ! pkg-config --exists libsodium libsecp256k1 libblst; then
  fail "crypto libs not visible to pkg-config"
fi
note "crypto libs: sodium $(pkg-config --modversion libsodium), secp256k1 $(pkg-config --modversion libsecp256k1), blst $(pkg-config --modversion libblst)"

cd "$ROOT/template"

if [ -n "${CI:-}" ]; then
  note "CI: running cabal update"
  cabal update
fi

note "building (cabal build all)..."
cabal build all

note "generating the example blueprint..."
cabal run -v0 exe:gen-auction-validator-blueprint -- blueprint.json
if [ ! -s blueprint.json ]; then
  fail "empty blueprint"
fi
note "blueprint OK: $(wc -c < blueprint.json | tr -d ' ') bytes"

echo "build-windows: SUCCESS (ghc $GHC_VERSION)"
