#!/usr/bin/env bash
#
# Bump the plutus version across the template — the logic behind the
# bump-plutus-version workflow, runnable (and testable) locally:
#
#   .github/ci/bump-plutus-version.sh 1.66.0.0
#
# Inside template/ it updates:
#   * flake.lock            — refreshes the CHaP and hackage inputs
#   * cabal.project         — index-states derived from the refreshed pins
#   * plinth-template.cabal — plutus-* bounds set to ^>=VERSION
#
# Requirements: nix (with flakes), curl, python3.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() { echo "bump-plutus-version: ERROR: $*" >&2; exit 1; }
note() { echo "bump-plutus-version: $*"; }

PLUTUS_VERSION="${1:-}"
if [ -z "$PLUTUS_VERSION" ]; then
  fail "usage: bump-plutus-version.sh PLUTUS-VERSION (e.g. 1.66.0.0)"
fi
case "$PLUTUS_VERSION" in
  *[!0-9.]*|*..*|.*|*.) fail "'$PLUTUS_VERSION' does not look like a plutus release version" ;;
esac

if ! command -v nix >/dev/null 2>&1; then
  fail "nix is required"
fi
if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required"
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required"
fi

cd "$ROOT/template"

note "updating flake inputs CHaP and hackage..."
nix flake update CHaP hackage --accept-flake-config

# Derive the hackage index-state from the flake-pinned hackage commit,
# subtracting 2 hours as safety margin (commit timestamp > latest index
# entry).
HACKAGE_DATE="$(python3 -c '
import json, datetime
epoch = json.load(open("flake.lock"))["nodes"]["hackage"]["locked"]["lastModified"] - 7200
print(datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
      .strftime("%Y-%m-%dT%H:%M:%SZ"))
')"

# For CHaP, read the index that ships inside the flake-pinned repository:
# the mtimes of the entries in 01-index.tar.gz ARE the index-states, so the
# newest one is the exact latest index-state of the pinned CHaP —
# independent of CHaP's git commit timestamp, which can be arbitrarily
# newer (e.g. ghost automation re-runs with 0 file changes).
CHAP_REV="$(python3 -c '
import json
print(json.load(open("flake.lock"))["nodes"]["CHaP"]["locked"]["rev"])
')"
CHAP_DATE="$(curl -fsSL \
  "https://raw.githubusercontent.com/IntersectMBO/cardano-haskell-packages/${CHAP_REV}/01-index.tar.gz" \
  | python3 -c '
import sys, tarfile, datetime
tf = tarfile.open(fileobj=sys.stdin.buffer, mode="r:gz")
print(datetime.datetime.fromtimestamp(max(m.mtime for m in tf),
                                      datetime.timezone.utc)
      .strftime("%Y-%m-%dT%H:%M:%SZ"))
')"
if [ -z "$CHAP_DATE" ]; then
  fail "failed to determine the CHaP index-state"
fi

note "hackage index-state: $HACKAGE_DATE"
note "CHaP index-state:    $CHAP_DATE"

# sed -i is not portable (GNU vs BSD); write to a temp file and move.
sed_i() {
  sed "$1" "$2" > "$2.tmp"
  mv "$2.tmp" "$2"
}

sed_i "s/\(hackage.haskell.org \).*$/\1$HACKAGE_DATE/" cabal.project
sed_i "s/\(cardano-haskell-packages \).*$/\1$CHAP_DATE/" cabal.project
if ! grep -qF "hackage.haskell.org $HACKAGE_DATE" cabal.project; then
  fail "failed to update the hackage index-state in cabal.project"
fi
if ! grep -qF "cardano-haskell-packages $CHAP_DATE" cabal.project; then
  fail "failed to update the CHaP index-state in cabal.project"
fi

for pkg in plutus-core plutus-ledger-api plutus-tx plutus-tx-plugin; do
  sed_i "s/\($pkg \).*$/\1\^>=$PLUTUS_VERSION/" plinth-template.cabal
  if ! grep -qE "$pkg +\^>=$PLUTUS_VERSION" plinth-template.cabal; then
    fail "failed to update the $pkg bound in plinth-template.cabal"
  fi
done

note "done — changed files:"
git -C "$ROOT" --no-pager diff --stat -- template/
