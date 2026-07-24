#!/usr/bin/env bash
#
# Build a Nix project end-to-end: create it with install.sh --env nix (or
# take a pre-created one as $1), enter its `nix develop` shell and run
# `cabal build all` plus the example blueprint.
#
#   dev/ci/build-nix.sh [TREE] [--shell ghc96|ghc912|default]
#
# Demeter projects have identical nix content, so this also covers demeter.
#
# Requirements: nix with flakes. Configure IOG's binary caches (see the
# nix-setup-guide) or the first run will build GHC from source.
#
# Environment:
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

command -v nix >/dev/null 2>&1 || fail "nix not on PATH"

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
  sh "$ROOT/install.sh" --yes --env nix --from "$ROOT" --dir "$PROJECT" \
    >"$WORK/install.log" 2>&1 \
    || { cat "$WORK/install.log" >&2; fail "install.sh --env nix failed"; }
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
[ -f "$PROJECT/flake.nix" ] || fail "$PROJECT is not a nix project"

# cd matters: `nix develop --command` runs in the calling directory, and the
# in-shell cabal must build the branch copy, not whatever cwd we came from.
cd "$PROJECT"

note "entering nix develop path:$PROJECT#$SHELL_NAME (first run may take a while)..."
# shellcheck disable=SC2016 # the inner script must expand inside the shell
nix develop "path:$PROJECT#$SHELL_NAME" --accept-flake-config --command bash -c '
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
  pkg-config --exists libsodium libsecp256k1 libblst \
    || { echo "build-nix(shell): FAIL: crypto libs not visible to pkg-config" >&2; exit 1; }
  note "crypto libs provided by the shell: sodium $(pkg-config --modversion libsodium), secp256k1 $(pkg-config --modversion libsecp256k1), blst $(pkg-config --modversion libblst)"

  if [ -n "${CI:-}" ]; then
    note "CI: running cabal update"
    cabal update
  fi

  note "building (cabal build all)..."
  cabal build all
  cabal run -v0 exe:gen-auction-validator-blueprint -- blueprint.json
  [ -s blueprint.json ] || { echo "build-nix(shell): FAIL: empty blueprint" >&2; exit 1; }
  note "blueprint OK: $(wc -c < blueprint.json | tr -d " ") bytes"
' || fail "nix shell build failed"

echo "build-nix: SUCCESS (shell: $SHELL_NAME)"
