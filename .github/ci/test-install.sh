#!/usr/bin/env bash
#
# End-to-end test of install.sh. The repository's template/ directory
# carries the union of every environment's project files; the installer
# selects the relevant ones into a fresh project directory. This test builds
# a local git fixture of the repository (no network cloning) and checks, for
# every environment:
#
#   * the produced project contains EXACTLY the expected files (manifest)
#   * only the right files were selected (crypto-libs script only in
#     GHC+Cabal projects, nix files only in Nix/Demeter projects, ...)
#   * the project has the right README and a fresh git history
#   * the final instructions tell the user to run `cabal build all`
#
# plus the --from (local directory) mode, the default project name, scripted
# interactive runs (answers via PLINTH_INSTALL_TTY), the failure modes
# (missing nix, unsupported GHC, old cabal, missing pkg-config, no terminal,
# existing target), and the real crypto-libs download (skipped when
# PLINTH_TEST_OFFLINE=1).
#
# The toolchain checks are exercised hermetically with stub ghc/cabal
# executables, so this test does not require a Haskell toolchain.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/plinth-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok: $*"; }

# --------------------------------------------------------------------------
# Fixture 1: a local git repository with the union tree on a single branch
# --------------------------------------------------------------------------

echo "== building local template repository =="
SRC="$WORK/fixture-repo"
git init -q "$SRC"
git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
  if [ ! -f "$f" ]; then
    continue
  fi
  case "$f" in */*) mkdir -p "$SRC/${f%/*}" ;; esac
  cp -p "$f" "$SRC/$f"
done
git -C "$SRC" add -A
git -C "$SRC" -c user.name=ci -c user.email=ci@example.invalid \
  commit -qm "plinth-template"
# gitignored junk (a local build inside template/) that must never reach a
# project created with --from
mkdir -p "$SRC/template/dist-newstyle"
echo junk > "$SRC/template/dist-newstyle/junk"
echo junk > "$SRC/template/cabal.project.local"
pass "fixture repo built from the working tree (with gitignored junk seeded)"

# --------------------------------------------------------------------------
# Fixture 2: stub toolchains and a minimal PATH
#
# The failure tests must not depend on what the host has installed, so they
# run with PATH = <stubs> + <farm>, where the farm contains symlinks to just
# the external tools install.sh legitimately needs.
# --------------------------------------------------------------------------

FARM="$WORK/farm"
mkdir -p "$FARM"
# sh must be in the farm: `env PATH=... sh install.sh` resolves sh via the
# new PATH.
for t in sh bash uname grep sed tr dirname basename mktemp git curl tar rm mkdir \
         cat find chmod cp mv ln awk; do
  if ! p="$(command -v "$t" 2>/dev/null)"; then
    continue
  fi
  ln -s "$p" "$FARM/$t"
done

make_stub() { # make_stub DIR NAME VERSION
  mkdir -p "$1"
  cat > "$1/$2" <<EOF
#!/bin/sh
case "\$1" in
  --numeric-version) echo "$3" ;;
  --version) echo "${4:-$2 version $3}" ;;
  *) echo "$2 stub: unexpected args: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$1/$2"
}

GOOD="$WORK/stubs-good"
make_stub "$GOOD" ghc 9.6.7
make_stub "$GOOD" cabal 3.12.1.0
make_stub "$GOOD" pkg-config 2.1.0 "2.1.0"

OLDGHC="$WORK/stubs-oldghc"
make_stub "$OLDGHC" ghc 9.4.8
make_stub "$OLDGHC" cabal 3.12.1.0
make_stub "$OLDGHC" pkg-config 2.1.0 "2.1.0"

OLDCABAL="$WORK/stubs-oldcabal"
make_stub "$OLDCABAL" ghc 9.6.7
make_stub "$OLDCABAL" cabal 3.6.2.0
make_stub "$OLDCABAL" pkg-config 2.1.0 "2.1.0"

NOPKGCONF="$WORK/stubs-nopkgconf"
make_stub "$NOPKGCONF" ghc 9.12.2
make_stub "$NOPKGCONF" cabal 3.12.1.0

# ghc+cabal stubs only, no pkg-config stub: for tests that need the REAL
# pkg-config from the host (the crypto-libs download sanity check).
TCONLY="$WORK/stubs-toolchain-only"
make_stub "$TCONLY" ghc 9.6.7
make_stub "$TCONLY" cabal 3.12.1.0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# run_install LOGFILE [env-overrides...] -- [install.sh flags...]
run_install() {
  log="$1"; shift
  envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" sh "$ROOT/install.sh" --repo "file://$SRC" "$@" \
    >"$log" 2>&1 </dev/null
}

expect_fresh_git() {
  if [ -d "$1/.git" ] && ! git -C "$1" rev-parse HEAD >/dev/null 2>&1; then
    pass "fresh git history (no commits)"
  else
    fail "$1 should have an initialized repo with zero commits"
  fi
}

expect_in_log() {
  if grep -qF "$2" "$1"; then pass "log mentions '$2'"; else fail "log lacks '$2' ($1)"; fi
}

contains() {
  if grep -qF "$2" "$1"; then
    pass "${1#"$WORK"/} contains '$2'"
  else
    fail "${1#"$WORK"/} does not contain '$2'"
  fi
}

# expect_manifest DIR  (expected file list on stdin; .git is ignored)
expect_manifest() {
  expected="$(sort)"
  actual="$(cd "$1" && find . -type f ! -path './.git/*' | sed 's|^\./||' | sort)"
  if [ "$expected" = "$actual" ]; then
    pass "manifest matches ($(printf '%s\n' "$actual" | grep -c .) files)"
  else
    fail "manifest mismatch in $1 (< expected, > actual):"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/    /' >&2 || true
  fi
}

COMMON=".gitignore
.hlint.yaml
.stylish-haskell.yaml
LICENSE.md
NOTICE.md
README.md
app/GenAuctionValidatorBlueprint.hs
app/GenMintingPolicyBlueprint.hs
cabal.project
plinth-template.cabal
src/AuctionMintingPolicy.hs
src/AuctionValidator.hs"

NIX_FILES="flake.lock
flake.nix
nix/outputs.nix
nix/pkgs.nix
nix/project.nix
nix/shell.nix
nix/utils.nix"

# --------------------------------------------------------------------------
# Non-interactive happy paths, one per environment
# --------------------------------------------------------------------------

echo ""
echo "== --env cabal (stub toolchain) =="
if run_install "$WORK/log-cabal" PATH="$GOOD:$FARM" -- \
     --yes --env cabal --dir "$WORK/out-cabal" --crypto-libs skip; then
  expect_manifest "$WORK/out-cabal" <<EOF
$COMMON
get-crypto-libs.sh
EOF
  if [ -x "$WORK/out-cabal/get-crypto-libs.sh" ]; then
    pass "get-crypto-libs.sh is executable"
  else
    fail "get-crypto-libs.sh lost its executable bit"
  fi
  contains "$WORK/out-cabal/README.md" "GHC + Cabal edition"
  expect_fresh_git "$WORK/out-cabal"
  expect_in_log "$WORK/log-cabal" "cabal build all"
  expect_in_log "$WORK/log-cabal" "libsodium"
else
  fail "--env cabal exited non-zero"; sed 's/^/    /' "$WORK/log-cabal" | tail -30
fi

echo ""
echo "== --env docker =="
if run_install "$WORK/log-docker" PATH="$GOOD:$FARM" -- \
     --yes --env docker --docker-mode codespaces --dir "$WORK/out-docker"; then
  expect_manifest "$WORK/out-docker" <<EOF
$COMMON
.devcontainer/devcontainer.json
EOF
  contains "$WORK/out-docker/README.md" "Docker edition"
  expect_fresh_git "$WORK/out-docker"
  expect_in_log "$WORK/log-docker" "cabal build all"
else
  fail "--env docker exited non-zero"; sed 's/^/    /' "$WORK/log-docker" | tail -30
fi

echo ""
echo "== --env demeter =="
if run_install "$WORK/log-demeter" PATH="$GOOD:$FARM" -- \
     --yes --env demeter --dir "$WORK/out-demeter"; then
  expect_manifest "$WORK/out-demeter" <<EOF
$COMMON
$NIX_FILES
EOF
  contains "$WORK/out-demeter/nix/project.nix" "src = lib.cleanSource ../.;"
  contains "$WORK/out-demeter/README.md" "demeter.run"
  expect_fresh_git "$WORK/out-demeter"
  expect_in_log "$WORK/log-demeter" "cabal build all"
else
  fail "--env demeter exited non-zero"; sed 's/^/    /' "$WORK/log-demeter" | tail -30
fi

echo ""
echo "== --env nix =="
if command -v nix >/dev/null 2>&1; then
  NIXDIR="$(dirname "$(command -v nix)")"
  if run_install "$WORK/log-nix" PATH="$GOOD:$NIXDIR:$FARM" -- \
       --yes --env nix --dir "$WORK/out-nix"; then
    expect_manifest "$WORK/out-nix" <<EOF
$COMMON
$NIX_FILES
EOF
    contains "$WORK/out-nix/nix/project.nix" "src = lib.cleanSource ../.;"
    contains "$WORK/out-nix/README.md" "Nix edition"
    expect_fresh_git "$WORK/out-nix"
    expect_in_log "$WORK/log-nix" "cabal build all"
    expect_in_log "$WORK/log-nix" "nix develop"
  else
    fail "--env nix exited non-zero"; sed 's/^/    /' "$WORK/log-nix" | tail -30
  fi
else
  echo "  skip: nix not installed on this host; happy path not tested"
fi

# --------------------------------------------------------------------------
# --from mode (local directory, no fetch) and the default project name
# --------------------------------------------------------------------------

echo ""
echo "== --from local directory + default project name =="
mkdir -p "$WORK/fromtest"
if ( cd "$WORK/fromtest" && \
     env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --yes --env docker \
       --docker-mode codespaces --from "$SRC" >"$WORK/log-from" 2>&1 </dev/null ); then
  if [ -f "$WORK/fromtest/my-plinth-project/.devcontainer/devcontainer.json" ]; then
    pass "--from created ./my-plinth-project (default name)"
  else
    fail "--from did not create my-plinth-project"
  fi
  if [ -e "$WORK/fromtest/my-plinth-project/install.sh" ] \
     || [ -e "$WORK/fromtest/my-plinth-project/template" ] \
     || [ -e "$WORK/fromtest/my-plinth-project/.github" ]; then
    fail "repository machinery leaked into the project"
  else
    pass "no repository machinery (install.sh, template/, .github/) in the project"
  fi
  # --from a working checkout must respect .gitignore (the fixture is seeded
  # with gitignored junk) and never copy git metadata
  if [ -e "$WORK/fromtest/my-plinth-project/dist-newstyle" ] \
     || [ -e "$WORK/fromtest/my-plinth-project/cabal.project.local" ]; then
    fail "--from leaked gitignored files into the project"
  else
    pass "--from respects .gitignore (seeded junk not copied)"
  fi
  expect_fresh_git "$WORK/fromtest/my-plinth-project"
else
  fail "--from run exited non-zero"; sed 's/^/    /' "$WORK/log-from" | tail -30
fi

echo ""
echo "== --from a git WORKTREE (.git is a pointer file) =="
# Regression: the worktree's .git FILE must never be copied — a project
# carrying it would make `git init` reinitialize the SOURCE repository.
mkdir -p "$WORK/fromwt"
if ( cd "$WORK/fromwt" && \
     env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --yes --env docker \
       --docker-mode codespaces --from "$ROOT" --dir wt-project \
       >"$WORK/log-fromwt" 2>&1 </dev/null ); then
  if [ -f "$WORK/fromwt/wt-project/.git" ]; then
    fail "--from copied the source worktree's .git pointer file"
  elif [ -d "$WORK/fromwt/wt-project/.git" ]; then
    pass ".git is a fresh repository, not a copied pointer file"
  else
    pass "no .git copied (git init may have been skipped)"
  fi
else
  fail "--from worktree run exited non-zero"; sed 's/^/    /' "$WORK/log-fromwt" | tail -30
fi

# --------------------------------------------------------------------------
# Scripted interactive run: answers fed through PLINTH_INSTALL_TTY
# (menu: 4 = GHC+Cabal, crypto menu: 3 = skip, project dir name)
# --------------------------------------------------------------------------

echo ""
echo "== interactive (scripted): choose GHC+Cabal, skip crypto libs =="
printf '4\n3\nmy-scripted-project\n' > "$WORK/answers"
if ( cd "$WORK" && run_install "$WORK/log-interactive" \
       PATH="$GOOD:$FARM" PLINTH_INSTALL_TTY="$WORK/answers" -- ); then
  if [ -f "$WORK/my-scripted-project/get-crypto-libs.sh" ]; then
    pass "interactive run created the ghc-cabal project"
  else
    fail "interactive run did not create the expected project"
  fi
  expect_in_log "$WORK/log-interactive" "cabal build all"
else
  fail "interactive run exited non-zero"; sed 's/^/    /' "$WORK/log-interactive" | tail -30
fi

# --------------------------------------------------------------------------
# Failure modes
# --------------------------------------------------------------------------

echo ""
echo "== failure: --env nix without nix on PATH =="
if run_install "$WORK/log-nonix" PATH="$GOOD:$FARM" -- \
     --yes --env nix --dir "$WORK/out-nonix"; then
  fail "--env nix succeeded although nix is not on PATH"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-nonix" "nix is not installed"
  if [ ! -e "$WORK/out-nonix" ]; then
    pass "nothing created"
  else
    fail "created despite failed checks"
  fi
fi

echo ""
echo "== failure: unsupported GHC version (9.4.8) =="
if run_install "$WORK/log-oldghc" PATH="$OLDGHC:$FARM" -- \
     --yes --env cabal --dir "$WORK/out-oldghc" --crypto-libs skip; then
  fail "--env cabal succeeded with GHC 9.4.8"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-oldghc" "unsupported GHC version 9.4.8"
  if [ ! -e "$WORK/out-oldghc" ]; then
    pass "nothing created"
  else
    fail "created despite failed checks"
  fi
fi

echo ""
echo "== failure: cabal too old (3.6.2.0) =="
if run_install "$WORK/log-oldcabal" PATH="$OLDCABAL:$FARM" -- \
     --yes --env cabal --dir "$WORK/out-oldcabal" --crypto-libs skip; then
  fail "--env cabal succeeded with cabal 3.6.2.0"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-oldcabal" "too old"
fi

echo ""
echo "== failure: pkg-config missing =="
if run_install "$WORK/log-nopc" PATH="$NOPKGCONF:$FARM" -- \
     --yes --env cabal --dir "$WORK/out-nopc" --crypto-libs skip; then
  fail "--env cabal succeeded without pkg-config"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-nopc" "pkg-config not found"
fi

echo ""
echo "== failure: no terminal, no --env, no --yes =="
if run_install "$WORK/log-notty" PATH="$GOOD:$FARM" PLINTH_INSTALL_NO_TTY=1 -- \
     --dir "$WORK/out-notty"; then
  fail "succeeded with no terminal and no flags"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-notty" "no terminal available"
fi

echo ""
echo "== failure: target directory already exists =="
mkdir -p "$WORK/out-exists"
if run_install "$WORK/log-exists" PATH="$GOOD:$FARM" -- \
     --yes --env cabal --dir "$WORK/out-exists" --crypto-libs skip; then
  fail "succeeded although the target directory exists"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-exists" "already exists"
fi

# --------------------------------------------------------------------------
# Real crypto-libs download (network) — the one non-hermetic test
# --------------------------------------------------------------------------

echo ""
if [ "${PLINTH_TEST_OFFLINE:-0}" = 1 ]; then
  echo "== crypto-libs local download: skipped (PLINTH_TEST_OFFLINE=1) =="
elif ! command -v pkg-config >/dev/null 2>&1; then
  # (CI runners always have pkg-config; this only skips on bare dev machines)
  echo "== crypto-libs local download: SKIPPED — no pkg-config on this host =="
  echo "   install one (brew install pkgconf / apt install pkg-config) to run it"
else
  echo "== --crypto-libs local: real download (hermetic cache) =="
  # Real pkg-config required for the installer's sanity check of the
  # downloaded libraries, so keep the host PATH and prepend ghc/cabal stubs
  # only (no pkg-config stub). The per-user cache is redirected into the
  # work dir so the test leaves no trace outside it.
  if run_install "$WORK/log-crypto" PATH="$TCONLY:$PATH" \
       PLINTH_CRYPTO_LIBS_HOME="$WORK/crypto-cache" -- \
       --yes --env cabal --dir "$WORK/out-crypto" --crypto-libs local; then
    found=""
    for pc in "$WORK/out-crypto"/dist-newstyle/crypto-libs/*/lib/pkgconfig/libsodium.pc; do
      if [ -f "$pc" ]; then
        found="$pc"
      fi
    done
    if [ -n "$found" ]; then
      pass "libsodium.pc reachable in the project: ${found#"$WORK"/}"
    else
      fail "no libsodium.pc under out-crypto/dist-newstyle/crypto-libs"
      sed 's/^/    /' "$WORK/log-crypto" | tail -30
    fi
    if find "$WORK/out-crypto/dist-newstyle/crypto-libs" -maxdepth 1 -type l | grep -q .; then
      pass "dist-newstyle/crypto-libs/<platform> is a symlink into the cache"
    else
      fail "expected a symlink under dist-newstyle/crypto-libs"
    fi
    if find "$WORK/crypto-cache" -name libsodium.pc | grep -q .; then
      pass "real files live in the (redirected) per-user cache"
    else
      fail "no libsodium.pc in the redirected cache $WORK/crypto-cache"
    fi
  else
    fail "--crypto-libs local exited non-zero"
    sed 's/^/    /' "$WORK/log-crypto" | tail -30
  fi
fi

# --------------------------------------------------------------------------

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "test-install: $FAILURES failure(s)" >&2
  exit 1
fi
echo "test-install: all tests passed"
