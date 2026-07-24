#!/usr/bin/env bash
#
# Build a GHC+Cabal project end-to-end with the host's ghc+cabal: create the
# project with install.sh --env cabal (or take a pre-created one as $1), run
# `cabal build all` there — proving the pkg-config shim bootstraps the crypto
# libraries with no manual step — then generate the example blueprint and
# assert the produced executable links the crypto libraries from the plinth
# cache.
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

command -v ghc >/dev/null 2>&1 || fail "ghc not on PATH"
command -v cabal >/dev/null 2>&1 || fail "cabal not on PATH"
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config not on PATH"
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
  sh "$ROOT/install.sh" --yes --env cabal --from "$ROOT" \
    --dir "$PROJECT" --crypto-libs skip >"$WORK/install.log" 2>&1 \
    || { cat "$WORK/install.log" >&2; fail "install.sh --env cabal failed"; }
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
[ -f "$PROJECT/scripts/get-crypto-libs.sh" ] || fail "$PROJECT is not a ghc-cabal project"
cd "$PROJECT"

cabal=(cabal)
if [ -n "${CABAL_STORE_DIR:-}" ]; then
  mkdir -p "$CABAL_STORE_DIR"
  cabal+=(--store-dir="$CABAL_STORE_DIR")
  note "using cabal store: $CABAL_STORE_DIR"
fi

if [ -n "${CI:-}" ]; then
  note "CI: running cabal update"
  "${cabal[@]}" update
fi

# --------------------------------------------------------------------------
# Build. The very first cold build on a fresh clone stops once, after the
# shim has written cabal.project.local (documented in the branch README);
# a plain re-run completes.
# --------------------------------------------------------------------------

note "building (cabal build all)..."
if ! "${cabal[@]}" build all; then
  [ -f cabal.project.local ] \
    || fail "build failed without writing cabal.project.local (not the documented cold-start stop)"
  note "documented cold-start stop; re-running cabal build all"
  "${cabal[@]}" build all
fi

# (regex, not the exact $PROJECT prefix: macOS mktemp paths appear both as
# /var/... and /private/var/... depending on how they were resolved)
[ -f cabal.project.local ] || fail "cabal.project.local was not created by the shim"
grep -q "pkg-config-location: .*/scripts/pkg-config" cabal.project.local \
  || fail "cabal.project.local does not point at the pkg-config shim"

# --------------------------------------------------------------------------
# Blueprint generation + provenance of the linked crypto libraries
# --------------------------------------------------------------------------

note "generating the example blueprint..."
"${cabal[@]}" run -v0 exe:gen-auction-validator-blueprint -- "$WORK/blueprint.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/blueprint.json" \
  || fail "blueprint output is not valid JSON"
note "blueprint OK: $(wc -c < "$WORK/blueprint.json" | tr -d ' ') bytes"

# The libraries' real location is the per-user cache; PLINTH_CRYPTO_LIBS_HOME
# overrides it (get-crypto-libs.sh defaults to .../plinth-crypto-libs).
CRYPTO_MARKER="${PLINTH_CRYPTO_LIBS_HOME:-plinth-crypto-libs}"

bin="$("${cabal[@]}" list-bin exe:gen-auction-validator-blueprint)"
case "$(uname -s)" in
  Darwin)
    links="$(otool -L "$bin")"
    echo "$links" | grep -qF "$CRYPTO_MARKER" \
      || fail "executable does not link crypto libs from the plinth cache ($CRYPTO_MARKER):
$links"
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
