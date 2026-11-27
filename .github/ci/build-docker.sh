#!/usr/bin/env bash
#
# Build a Docker project end-to-end: create it with install.sh --env docker
# (or take a pre-created one as $1) and build it inside the devx devcontainer
# image — the same image devcontainers, Codespaces and the standalone
# `docker run` flow use.
#
# The image is x86_64-linux; on other architectures docker's emulation is
# used automatically (slow but correct).
#
# When docker is unavailable the script SKIPS (exit 0) with a loud notice,
# unless PLINTH_REQUIRE_DOCKER=1 (set in CI) makes that a failure.
#
# Environment:
#   PLINTH_REQUIRE_DOCKER=1  Fail instead of skipping when docker is missing.
#   PLINTH_CI_KEEP=1         Keep the scratch directory (printed).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

IMAGE="ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog"
TREE="${1:-}"

fail() { echo "build-docker: FAIL: $*" >&2; exit 1; }
note() { echo "build-docker: $*"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "${PLINTH_REQUIRE_DOCKER:-0}" = 1 ]; then
    fail "docker is not available (PLINTH_REQUIRE_DOCKER=1)"
  fi
  echo "build-docker: SKIPPED — docker is not installed or its daemon is not running." >&2
  echo "build-docker: start docker and re-run, or rely on CI for this branch." >&2
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plinth-build-docker.XXXXXX")"

# The container builds as root, so dist-newstyle/ ends up owned by root on
# the host and a plain rm cannot remove it. Hand the files back through a
# throwaway container before removing them, and never let a cleanup problem
# fail an otherwise successful build.
cleanup() {
  if [ "${PLINTH_CI_KEEP:-0}" = 1 ]; then
    echo "build-docker: scratch dir kept: $WORK"
    return 0
  fi
  if rm -rf "$WORK" 2>/dev/null; then
    return 0
  fi
  docker run --rm -v "$WORK:/scratch" "$IMAGE" \
    chown -R "$(id -u):$(id -g)" /scratch >/dev/null 2>&1 || true
  if ! rm -rf "$WORK"; then
    echo "build-docker: warning: could not remove the scratch dir $WORK" >&2
  fi
}
trap cleanup EXIT

PROJECT="$WORK/project"
if [ -z "$TREE" ]; then
  if ! sh "$ROOT/install.sh" --env docker --docker-mode standalone --from "$ROOT" \
         --dir "$PROJECT" >"$WORK/install.log" 2>&1; then
    cat "$WORK/install.log" >&2
    fail "install.sh --env docker failed"
  fi
else
  mkdir -p "$PROJECT"
  cp -R "$TREE/." "$PROJECT/"
fi
if [ ! -f "$PROJECT/.devcontainer/devcontainer.json" ]; then
  fail "$PROJECT is not a docker project"
fi

# `bash -ic` is required: the devx image loads the nix toolchain environment
# from ~/.bashrc, which only interactive shells source.
note "building inside $IMAGE ..."
if ! docker run --rm \
       -v "$PROJECT:/workspaces/plinth-template" \
       -w /workspaces/plinth-template \
       -i "$IMAGE" \
       bash -ic '
         set -euo pipefail
         echo "build-docker(container): ghc $(ghc --numeric-version) at $(command -v ghc)"
         if ! pkg-config --exists libsodium libsecp256k1 libblst; then
           echo "build-docker(container): FAIL: crypto libs not provided by the image" >&2
           exit 1
         fi
         echo "build-docker(container): crypto libs provided by the image (via nix)"
         cabal update
         cabal build all
         cabal run -v0 exe:gen-auction-validator-blueprint -- blueprint.json
         if [ ! -s blueprint.json ]; then
           echo "build-docker(container): FAIL: empty blueprint" >&2
           exit 1
         fi
         echo "build-docker(container): blueprint OK"
         # Loading plutus-tx-plugin into a live GHC session is a separate
         # failure mode from batch compilation, and it is the path HLS uses.
         # The deleted build-devcontainer.yml workflow checked it on every PR;
         # keep that coverage here, in the same image.
         echo ":q" | cabal repl lib:plinth-validators
         echo "build-docker(container): cabal repl loads the plugin OK"
       '; then
  fail "container build failed"
fi

echo "build-docker: SUCCESS"
