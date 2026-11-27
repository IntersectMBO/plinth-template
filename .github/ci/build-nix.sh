#!/usr/bin/env bash
#
# Build a Nix project end-to-end: create it with install.sh --env nix (or
# take a pre-created one as $1), enter its `nix develop` shell and run
# `cabal build all` plus the example blueprint.
#
#   .github/ci/build-nix.sh [TREE] [--shell ghc96|ghc912|default]
#
# Demeter projects have identical nix content, so this also covers demeter.
#
# Requirements: nix with flakes. Configure IOG's binary caches (see the
# nix-setup-guide) or the first run will build GHC from source.
#
# Environment:
#   CABAL_STORE_DIR   Use a dedicated cabal store for the in-shell build
#                     (passed as --store-dir); lets CI and repeated local
#                     runs reuse compiled dependencies.
#   PLINTH_CI_KEEP=1  Keep the scratch directory (printed) for inspection.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TREE=""
SHELL_NAME="default"
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) shift; SHELL_NAME="${1:?--shell needs an argument}" ;;
    --shell=*) SHELL_NAME="${1#--shell=}" ;;
    *) TREE="$1" ;;
  esac
  shift
done

fail() { echo "build-nix: FAIL: $*" >&2; exit 1; }
note() { echo "build-nix: $*"; }

if ! command -v nix >/dev/null 2>&1; then
  fail "nix not on PATH"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plinth-build-nix.XXXXXX")"
# nix's path: fetcher rejects paths with symlinked ancestors (macOS /var);
# use the physical path.
WORK="$(cd "$WORK" && pwd -P)"
cleanup() {
  if [ "${PLINTH_CI_KEEP:-0}" = 1 ]; then
    echo "build-nix: scratch dir kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

PROJECT="$WORK/project"
if [ -z "$TREE" ]; then
  if ! sh "$ROOT/install.sh" --env nix --from "$ROOT" --dir "$PROJECT" \
         >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install.sh --env nix failed"
  fi
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
if [ ! -f "$PROJECT/flake.nix" ]; then
  fail "$PROJECT is not a nix project"
fi

# cd matters: `nix develop --command` runs in the calling directory, and the
# in-shell cabal must build the branch copy, not whatever cwd we came from.
cd "$PROJECT"

note "entering nix develop path:$PROJECT#$SHELL_NAME (first run may take a while)..."
# shellcheck disable=SC2016 # the inner script must expand inside the shell
if ! nix develop "path:$PROJECT#$SHELL_NAME" --accept-flake-config --command bash -c '
       set -euo pipefail
       note() { echo "build-nix(shell): $*"; }

       case "$(command -v ghc)" in
         /nix/store/*) note "ghc $(ghc --numeric-version) from /nix/store" ;;
         *) echo "build-nix(shell): FAIL: ghc not from /nix/store: $(command -v ghc)" >&2; exit 1 ;;
       esac
       case "$(command -v cabal)" in
         /nix/store/*) note "cabal $(cabal --numeric-version) from /nix/store" ;;
         *) echo "build-nix(shell): FAIL: cabal not from /nix/store: $(command -v cabal)" >&2; exit 1 ;;
       esac
       if ! pkg-config --exists libsodium libsecp256k1 libblst; then
         echo "build-nix(shell): FAIL: crypto libs not visible to pkg-config" >&2
         exit 1
       fi
       note "crypto libs provided by the shell: sodium $(pkg-config --modversion libsodium), secp256k1 $(pkg-config --modversion libsecp256k1), blst $(pkg-config --modversion libblst)"

       cabal=(cabal)
       if [ -n "${CABAL_STORE_DIR:-}" ]; then
         mkdir -p "$CABAL_STORE_DIR"
         cabal+=(--store-dir="$CABAL_STORE_DIR")
         note "using cabal store: $CABAL_STORE_DIR"
       fi

       # Unconditional: the shell ships a stock cabal with no package index, and
       # cabal.project pins index-states for hackage and CHaP that must be
       # fetched first. Gating this on $CI made local runs fail in cabal build.
       note "running cabal update"
       "${cabal[@]}" update

       note "building (cabal build all)..."
       "${cabal[@]}" build all
       "${cabal[@]}" run -v0 exe:gen-auction-validator-blueprint -- blueprint.json
       if [ ! -s blueprint.json ]; then
         echo "build-nix(shell): FAIL: empty blueprint" >&2
         exit 1
       fi
       note "blueprint OK: $(wc -c < blueprint.json | tr -d " ") bytes"
     '; then
  fail "nix shell build failed"
fi

echo "build-nix: SUCCESS (shell: $SHELL_NAME)"
