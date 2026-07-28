#!/usr/bin/env bash
#
# Run the full test suite locally — the same scripts the GitHub workflows
# run, without the Actions layer.
#
#   .github/ci/run-all-local.sh              # everything
#   PLINTH_SKIP_HEAVY=1 .github/ci/run-all-local.sh   # fast checks only
#
# The heavy steps compile the project; to speed up repeated ghc-cabal runs,
# point CABAL_STORE_DIR at a persistent directory.
#
# (build-windows.sh is not run here: it only works on a Windows machine
# inside an MSYS2 MINGW64 shell.)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if ! cd "$ROOT"; then
  exit 1
fi

PASS=()
FAIL=()
SKIP=()

run_step() {
  name="$1"; shift
  echo ""
  echo "==================================================================="
  echo "=== $name"
  echo "==================================================================="
  if "$@"; then
    PASS+=("$name")
  else
    FAIL+=("$name")
  fi
}

skip_step() {
  SKIP+=("$1 — $2")
  echo ""
  echo "=== $1: SKIPPED ($2)"
}

run_step "lint"         .github/ci/lint.sh
run_step "test-install" .github/ci/test-install.sh

if [ "${PLINTH_SKIP_HEAVY:-0}" = 1 ]; then
  skip_step "build-ghc-cabal" "PLINTH_SKIP_HEAVY=1"
  skip_step "build-nix"       "PLINTH_SKIP_HEAVY=1"
  skip_step "build-docker"    "PLINTH_SKIP_HEAVY=1"
else
  if command -v ghc >/dev/null 2>&1 && command -v cabal >/dev/null 2>&1; then
    run_step "build-ghc-cabal" .github/ci/build-ghc-cabal.sh
  else
    skip_step "build-ghc-cabal" "no ghc/cabal on PATH"
  fi
  if command -v nix >/dev/null 2>&1; then
    run_step "build-nix" .github/ci/build-nix.sh
  else
    skip_step "build-nix" "no nix on PATH"
  fi
  # build-docker.sh skips by itself when docker is unavailable
  run_step "build-docker" .github/ci/build-docker.sh
fi

echo ""
echo "==================================================================="
echo "Summary"
echo "==================================================================="
for s in ${PASS+"${PASS[@]}"}; do echo "  PASS  $s"; done
for s in ${SKIP+"${SKIP[@]}"}; do echo "  SKIP  $s"; done
for s in ${FAIL+"${FAIL[@]}"}; do echo "  FAIL  $s"; done

if [ "${#FAIL[@]}" -gt 0 ]; then
  echo ""
  echo "run-all-local: ${#FAIL[@]} step(s) failed" >&2
  exit 1
fi
echo ""
echo "run-all-local: all steps passed"
