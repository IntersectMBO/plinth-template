#!/usr/bin/env bash
#
# Lint all shell scripts in the repository: syntax check plus shellcheck.
# Runs locally (falls back to `nix run nixpkgs#shellcheck` when shellcheck is
# not installed) and in CI (ubuntu runners ship shellcheck).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SCRIPTS=(
  install.sh
  get-crypto-libs.sh
  .github/ci/lint.sh
  .github/ci/test-install.sh
  .github/ci/build-ghc-cabal.sh
  .github/ci/build-nix.sh
  .github/ci/build-docker.sh
  .github/ci/bump-plutus-version.sh
  .github/ci/run-all-local.sh
  .github/ci/test-blueprint-parity.sh
)

for f in "${SCRIPTS[@]}"; do
  if [ ! -f "$f" ]; then
    echo "lint: missing $f" >&2
    exit 1
  fi
  case "$(head -1 "$f")" in
    '#!/bin/sh'*) sh -n "$f" ;;
    *) bash -n "$f" ;;
  esac
  echo "lint: syntax ok: $f"
done

if command -v shellcheck >/dev/null 2>&1; then
  SHELLCHECK=(shellcheck)
elif command -v nix >/dev/null 2>&1; then
  echo "lint: shellcheck not installed; using 'nix run nixpkgs#shellcheck'"
  SHELLCHECK=(nix run nixpkgs#shellcheck --)
else
  echo "lint: ERROR: shellcheck not found (and no nix to run it with)" >&2
  exit 1
fi

# SC1091: sourced files aren't followed; SC2016: single-quoted $ is often
# intentional in messages that tell the user what to run.
"${SHELLCHECK[@]}" --exclude=SC1091 "${SCRIPTS[@]}"
echo "lint: shellcheck ok (${#SCRIPTS[@]} files)"
