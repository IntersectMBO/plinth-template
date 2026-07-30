#!/usr/bin/env bash
#
# Build a GHC+Cabal project end-to-end with the host's ghc+cabal: create the
# project with install.sh --env cabal --crypto-libs local (or take a
# pre-created one as $1), which downloads the crypto C libraries into the
# per-user cache, then run `cabal build all` with the generated env.sh
# sourced (it points PKG_CONFIG_PATH at the libraries), generate the example
# blueprint and assert the produced executable links the crypto libraries
# from the plinth cache.
#
# Requirements: ghc 9.6.x or 9.12.x, cabal >= 3.8, pkg-config, network.
#
# Environment:
#   CABAL_STORE_DIR   Use a dedicated cabal store (passed as --store-dir);
#                     speeds up repeated local runs enormously.
#   PLINTH_CI_KEEP=1  Keep the scratch directory (printed) for inspection.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TREE="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plinth-build-cabal.XXXXXX")"
cleanup() {
  if [ "${PLINTH_CI_KEEP:-0}" = 1 ]; then
    echo "build-ghc-cabal: scratch dir kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

fail() { echo "build-ghc-cabal: FAIL: $*" >&2; exit 1; }
note() { echo "build-ghc-cabal: $*"; }

# --------------------------------------------------------------------------
# Toolchain assertions (same requirements install.sh enforces)
# --------------------------------------------------------------------------

if ! command -v ghc >/dev/null 2>&1; then
  fail "ghc not on PATH"
fi
if ! command -v cabal >/dev/null 2>&1; then
  fail "cabal not on PATH"
fi
if ! command -v pkg-config >/dev/null 2>&1; then
  fail "pkg-config not on PATH"
fi
GHC_VERSION="$(ghc --numeric-version)"
case "$GHC_VERSION" in
  9.6.*|9.12.*) note "ghc $GHC_VERSION ($(command -v ghc))" ;;
  *) fail "unsupported ghc $GHC_VERSION (need 9.6.x or 9.12.x)" ;;
esac
note "cabal $(cabal --numeric-version) ($(command -v cabal))"

# --------------------------------------------------------------------------
# Fresh copy of the branch tree
# --------------------------------------------------------------------------

PROJECT="$WORK/project"
if [ -z "$TREE" ]; then
  if ! sh "$ROOT/install.sh" --yes --env cabal --from "$ROOT" \
         --dir "$PROJECT" --crypto-libs local >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install.sh --env cabal failed"
  fi
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
if [ ! -f "$PROJECT/get-crypto-libs.sh" ]; then
  fail "$PROJECT is not a ghc-cabal project"
fi
cd "$PROJECT"

# install.sh (--crypto-libs local) already ran this; re-running is an
# instant no-op re-link. For a pre-created tree ($1) it does the install.
if ! ./get-crypto-libs.sh; then
  fail "get-crypto-libs.sh failed"
fi

# Source the generated env.sh so pkg-config resolves the libraries (this is
# exactly what the README tells users to do).
if [ ! -f dist-newstyle/crypto-libs/env.sh ]; then
  fail "dist-newstyle/crypto-libs/env.sh was not created by get-crypto-libs.sh"
fi
# shellcheck source=/dev/null
. dist-newstyle/crypto-libs/env.sh
if ! pkg-config --exists libsodium libsecp256k1 libblst; then
  fail "crypto libs not visible to pkg-config after sourcing env.sh"
fi
note "crypto libs: sodium $(pkg-config --modversion libsodium), secp256k1 $(pkg-config --modversion libsecp256k1), blst $(pkg-config --modversion libblst)"

cabal=(cabal)
if [ -n "${CABAL_STORE_DIR:-}" ]; then
  mkdir -p "$CABAL_STORE_DIR"
  cabal+=(--store-dir="$CABAL_STORE_DIR")
  note "using cabal store: $CABAL_STORE_DIR"
fi

# Unconditional: the generated project's cabal.project declares the
# cardano-haskell-packages repository, whose index no machine has unless it
# already built a CHaP project, and cabal never fetches it on its own. Gating
# this on $CI made local runs (run-all-local.sh) die in `cabal build all` with
# "The package list for 'cardano-haskell-packages' does not exist."
note "running cabal update"
"${cabal[@]}" update

note "building (cabal build all)..."
"${cabal[@]}" build all

# --------------------------------------------------------------------------
# Blueprint generation + provenance of the linked crypto libraries
# --------------------------------------------------------------------------

note "generating the example blueprint..."
"${cabal[@]}" run -v0 exe:gen-auction-validator-blueprint -- "$WORK/blueprint.json"
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/blueprint.json"; then
  fail "blueprint output is not valid JSON"
fi
note "blueprint OK: $(wc -c < "$WORK/blueprint.json" | tr -d ' ') bytes"

# The libraries' real location is the per-user cache; PLINTH_CRYPTO_LIBS_HOME
# overrides it (get-crypto-libs.sh defaults to .../plinth-crypto-libs).
CRYPTO_MARKER="${PLINTH_CRYPTO_LIBS_HOME:-plinth-crypto-libs}"

bin="$("${cabal[@]}" list-bin exe:gen-auction-validator-blueprint)"
case "$(uname -s)" in
  Darwin)
    links="$(otool -L "$bin")"
    if ! echo "$links" | grep -qF "$CRYPTO_MARKER"; then
      fail "executable does not link crypto libs from the plinth cache ($CRYPTO_MARKER):
$links"
    fi
    for bad in /nix/store /opt/homebrew "/usr/local/lib"; do
      if echo "$links" | grep -qE "(libsodium|libsecp256k1|libblst).*$bad|$bad.*(libsodium|libsecp256k1|libblst)"; then
        fail "executable links crypto libs from $bad:
$links"
      fi
    done
    note "otool: crypto libs come from the plinth cache only"
    ;;
  Linux)
    links="$(ldd "$bin" 2>/dev/null || true)"
    if echo "$links" | grep -E 'libsodium|libsecp256k1|libblst' | grep -vqF "$CRYPTO_MARKER"; then
      fail "executable resolves crypto libs outside the plinth cache ($CRYPTO_MARKER):
$links"
    fi
    note "ldd: crypto libs come from the plinth cache only (or are absent/static)"
    ;;
esac

echo "build-ghc-cabal: SUCCESS (ghc $GHC_VERSION)"
