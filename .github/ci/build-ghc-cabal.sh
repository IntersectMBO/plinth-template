#!/usr/bin/env bash
#
# Build a GHC+Cabal project end-to-end with the host's ghc+cabal: create the
# project with install.sh --env cabal (or take a pre-created one as the
# positional argument), install the crypto C libraries, then run
# `cabal build all` with pkg-config pointed at them, generate the example
# blueprint and assert the produced executable links the crypto libraries
# from where they were installed and nowhere else.
#
# Both crypto-libs modes install.sh offers are testable:
#
#   --crypto-libs local   (default) libraries go into the per-user cache and
#                         are linked into the project; the generated
#                         dist-newstyle/crypto-libs/env.sh sets the paths.
#   --crypto-libs system  libraries go into a --prefix under $HOME (no sudo,
#                         nothing system-wide touched); PKG_CONFIG_PATH and
#                         LD_LIBRARY_PATH are set from that prefix, which is
#                         what the installer tells such users to do. Override
#                         it with PLINTH_SYSTEM_PREFIX.
#
# Usage: build-ghc-cabal.sh [--crypto-libs local|system] [PRE_CREATED_TREE]
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

CRYPTO_MODE="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --crypto-libs) shift; CRYPTO_MODE="${1:?--crypto-libs needs an argument}" ;;
    --crypto-libs=*) CRYPTO_MODE="${1#--crypto-libs=}" ;;
    *) break ;;
  esac
  shift
done
case "$CRYPTO_MODE" in
  local|system) ;;
  *) echo "build-ghc-cabal: FAIL: --crypto-libs must be 'local' or 'system'" >&2; exit 1 ;;
esac

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

# The system-mode prefix. It must be STABLE across runs — not a path under
# $WORK — for the reason get-crypto-libs.sh documents for its own cache: cabal
# bakes the crypto libraries' absolute paths into the packages it compiles
# into the store, and CI caches that store between runs. With a fresh mktemp
# prefix each run, a restored store points at a directory that no longer
# exists and the build dies with `ld: cannot find -lsodium`. Every run
# re-installs into this path, so a fresh runner (cached store, prefix not
# there yet) works too. Still no sudo and still nothing system-wide.
SYSTEM_PREFIX="${PLINTH_SYSTEM_PREFIX:-$HOME/.cache/plinth-ci-crypto-prefix}"

note "crypto-libs mode: $CRYPTO_MODE"

PROJECT="$WORK/project"
if [ -z "$TREE" ]; then
  install_args=(--env cabal --from "$ROOT" --dir "$PROJECT" --crypto-libs "$CRYPTO_MODE")
  if [ "$CRYPTO_MODE" = system ]; then
    install_args+=(--prefix "$SYSTEM_PREFIX")
  fi
  if ! sh "$ROOT/install.sh" "${install_args[@]}" >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install.sh --env cabal --crypto-libs $CRYPTO_MODE failed"
  fi
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
if [ ! -f "$PROJECT/get-crypto-libs.sh" ]; then
  fail "$PROJECT is not a ghc-cabal project"
fi
cd "$PROJECT"

# For a pre-created tree ($TREE) the libraries were never installed, so do
# it here. When install.sh created the project it already ran this; re-run
# it in local mode only, where it is an instant re-link and proves the
# advertised idempotence (a system re-run would re-download everything into
# a fresh staging dir).
if [ -n "$TREE" ] && [ "$CRYPTO_MODE" = system ]; then
  if ! ./get-crypto-libs.sh --prefix "$SYSTEM_PREFIX"; then
    fail "get-crypto-libs.sh --prefix failed"
  fi
fi
if [ "$CRYPTO_MODE" = local ]; then
  if ! ./get-crypto-libs.sh; then
    fail "get-crypto-libs.sh failed"
  fi
fi

# Point pkg-config (and, on Linux, the loader) at the libraries the same way
# the installer's closing instructions tell the user to.
if [ "$CRYPTO_MODE" = system ]; then
  export PKG_CONFIG_PATH="$SYSTEM_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$SYSTEM_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  if [ ! -f "$SYSTEM_PREFIX/lib/pkgconfig/libsodium.pc" ]; then
    fail "$SYSTEM_PREFIX/lib/pkgconfig/libsodium.pc missing after a system install"
  fi
  if [ -e dist-newstyle/crypto-libs ]; then
    fail "system mode must not create dist-newstyle/crypto-libs in the project"
  fi
else
  # Source the generated env.sh (exactly what the README tells users to do).
  if [ ! -f dist-newstyle/crypto-libs/env.sh ]; then
    fail "dist-newstyle/crypto-libs/env.sh was not created by get-crypto-libs.sh"
  fi
  # shellcheck source=/dev/null
  . dist-newstyle/crypto-libs/env.sh
fi
if ! pkg-config --exists libsodium libsecp256k1 libblst; then
  fail "crypto libs not visible to pkg-config ($CRYPTO_MODE mode)"
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

# Where the libraries the executable links must come from: the --prefix in
# system mode, otherwise the per-user cache (PLINTH_CRYPTO_LIBS_HOME
# overrides it; get-crypto-libs.sh defaults to .../plinth-crypto-libs).
if [ "$CRYPTO_MODE" = system ]; then
  CRYPTO_MARKER="$SYSTEM_PREFIX"
else
  CRYPTO_MARKER="${PLINTH_CRYPTO_LIBS_HOME:-plinth-crypto-libs}"
fi

bin="$("${cabal[@]}" list-bin exe:gen-auction-validator-blueprint)"
case "$(uname -s)" in
  Darwin)
    links="$(otool -L "$bin")"
    if ! echo "$links" | grep -qF "$CRYPTO_MARKER"; then
      fail "executable does not link crypto libs from $CRYPTO_MARKER:
$links"
    fi
    for bad in /nix/store /opt/homebrew "/usr/local/lib"; do
      if echo "$links" | grep -qE "(libsodium|libsecp256k1|libblst).*$bad|$bad.*(libsodium|libsecp256k1|libblst)"; then
        fail "executable links crypto libs from $bad:
$links"
      fi
    done
    note "otool: crypto libs come from $CRYPTO_MARKER only"
    ;;
  Linux)
    links="$(ldd "$bin" 2>/dev/null || true)"
    if echo "$links" | grep -E 'libsodium|libsecp256k1|libblst' | grep -vqF "$CRYPTO_MARKER"; then
      fail "executable resolves crypto libs outside $CRYPTO_MARKER:
$links"
    fi
    note "ldd: crypto libs come from $CRYPTO_MARKER only (or are absent/static)"
    ;;
esac

echo "build-ghc-cabal: SUCCESS (ghc $GHC_VERSION, $CRYPTO_MODE crypto libs)"
