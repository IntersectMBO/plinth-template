#!/usr/bin/env bash
#
# End-to-end test of install.sh. The repository's template/ directory
# carries the union of every environment's project files; the installer
# copies the relevant ones into a fresh project directory. This test builds
# a local fixture copy of the repository (no network) and, passing every
# question's flag explicitly (the installer prompts on /dev/tty otherwise),
# checks for every environment:
#
#   * the produced project contains EXACTLY the expected files (manifest)
#   * only the right files were copied (crypto-libs script only in
#     GHC+Cabal projects, nix files only in Nix/Demeter projects, ...)
#   * the project has the right README and no git history
#   * the final instructions tell the user to run `cabal build all`
#
# plus the failure modes (missing nix, unsupported GHC, old cabal, missing
# pkg-config, existing target, no terminal to prompt on, missing curl,
# unsupported CPU architecture, invalid --repo) and the real crypto-libs
# download (skipped when PLINTH_TEST_OFFLINE=1).
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
# Fixture 1: a local copy of the repository's working tree
# --------------------------------------------------------------------------

echo "== building local template fixture =="
SRC="$WORK/fixture-repo"
mkdir -p "$SRC"
git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
  if [ ! -f "$f" ]; then
    continue
  fi
  case "$f" in */*) mkdir -p "$SRC/${f%/*}" ;; esac
  cp -p "$f" "$SRC/$f"
done
# build junk inside template/ that must never reach a project created with
# --from (the installer copies an explicit file list, nothing else)
mkdir -p "$SRC/template/dist-newstyle"
echo junk > "$SRC/template/dist-newstyle/junk"
echo junk > "$SRC/template/cabal.project.local"
pass "fixture built from the working tree (with build junk seeded)"

# --------------------------------------------------------------------------
# Fixture 2: stub toolchains and a minimal PATH
#
# The failure tests must not depend on what the host has installed, so they
# run with PATH = <stubs> + <farm>, where the farm contains symlinks to just
# the external tools install.sh legitimately needs.
# --------------------------------------------------------------------------

# make_farm DIR TOOL...: populate DIR with symlinks to the host's tools.
make_farm() {
  farm_dir="$1"; shift
  mkdir -p "$farm_dir"
  for t in "$@"; do
    if ! p="$(command -v "$t" 2>/dev/null)"; then
      continue
    fi
    ln -s "$p" "$farm_dir/$t"
  done
}

# sh must be in the farm: `env PATH=... sh install.sh` resolves sh via the
# new PATH. NOCURL_FARM differs from FARM only by curl's absence, for the
# tests proving which crypto modes actually require it.
FARM_TOOLS=(sh bash uname grep sed tr dirname basename mktemp tar rm mkdir
            cat find chmod cp mv ln awk)
FARM="$WORK/farm"
make_farm "$FARM" "${FARM_TOOLS[@]}" curl
NOCURL_FARM="$WORK/farm-nocurl"
make_farm "$NOCURL_FARM" "${FARM_TOOLS[@]}"

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
  env "${envs[@]}" sh "$ROOT/install.sh" --from "$SRC" "$@" \
    >"$log" 2>&1 </dev/null
}

expect_no_git() {
  if [ -e "$1/.git" ]; then
    fail "$1 should not contain .git (the installer does not init a repository)"
  else
    pass "no git history created"
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
LICENSE.md
NOTICE.md
README.md
app/GenAuctionValidatorBlueprint.hs
app/GenMintingPolicyBlueprint.hs
cabal.project
plinth-template.cabal
src/AuctionMintingPolicy.hs
src/AuctionValidator.hs"

NIX_FILES=".hlint.yaml
.stylish-haskell.yaml
flake.lock
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
     --env cabal --dir "$WORK/out-cabal" --crypto-libs skip; then
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
  # validator.uplc distinguishes template/.gitignore from the repo root's
  contains "$WORK/out-cabal/.gitignore" "validator.uplc"
  contains "$WORK/out-cabal/LICENSE.md" "Apache License"
  expect_no_git "$WORK/out-cabal"
  expect_in_log "$WORK/log-cabal" "cabal build all"
  expect_in_log "$WORK/log-cabal" "libsodium"
else
  fail "--env cabal exited non-zero"; sed 's/^/    /' "$WORK/log-cabal" | tail -30
fi

echo ""
echo "== --env docker =="
if run_install "$WORK/log-docker" PATH="$GOOD:$FARM" -- \
     --env docker --docker-mode codespaces --dir "$WORK/out-docker"; then
  expect_manifest "$WORK/out-docker" <<EOF
$COMMON
.devcontainer/devcontainer.json
EOF
  contains "$WORK/out-docker/README.md" "Docker edition"
  expect_no_git "$WORK/out-docker"
  expect_in_log "$WORK/log-docker" "cabal build all"
else
  fail "--env docker exited non-zero"; sed 's/^/    /' "$WORK/log-docker" | tail -30
fi

echo ""
echo "== --env demeter =="
if run_install "$WORK/log-demeter" PATH="$GOOD:$FARM" -- \
     --env demeter --dir "$WORK/out-demeter"; then
  expect_manifest "$WORK/out-demeter" <<EOF
$COMMON
$NIX_FILES
EOF
  contains "$WORK/out-demeter/nix/project.nix" "src = lib.cleanSource ../.;"
  contains "$WORK/out-demeter/README.md" "demeter.run"
  expect_no_git "$WORK/out-demeter"
  expect_in_log "$WORK/log-demeter" "cabal build all"
else
  fail "--env demeter exited non-zero"; sed 's/^/    /' "$WORK/log-demeter" | tail -30
fi

echo ""
echo "== --env nix =="
if command -v nix >/dev/null 2>&1; then
  NIXDIR="$(dirname "$(command -v nix)")"
  if run_install "$WORK/log-nix" PATH="$GOOD:$NIXDIR:$FARM" -- \
       --env nix --dir "$WORK/out-nix"; then
    expect_manifest "$WORK/out-nix" <<EOF
$COMMON
$NIX_FILES
EOF
    contains "$WORK/out-nix/nix/project.nix" "src = lib.cleanSource ../.;"
    contains "$WORK/out-nix/README.md" "Nix edition"
    expect_no_git "$WORK/out-nix"
    expect_in_log "$WORK/log-nix" "cabal build all"
    expect_in_log "$WORK/log-nix" "nix develop"
  else
    fail "--env nix exited non-zero"; sed 's/^/    /' "$WORK/log-nix" | tail -30
  fi
else
  echo "  skip: nix not installed on this host; happy path not tested"
fi

# --------------------------------------------------------------------------
# --from mode: relative target dir, no repository machinery, no build junk
# --------------------------------------------------------------------------

echo ""
echo "== --from local directory =="
mkdir -p "$WORK/fromtest"
if ( cd "$WORK/fromtest" && \
     env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --env docker \
       --docker-mode codespaces --from "$SRC" --dir my-plinth-project \
       >"$WORK/log-from" 2>&1 </dev/null ); then
  if [ -f "$WORK/fromtest/my-plinth-project/.devcontainer/devcontainer.json" ]; then
    pass "--from created ./my-plinth-project"
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
  # --from a checkout that was built in must not carry build junk (the
  # fixture is seeded with some)
  if [ -e "$WORK/fromtest/my-plinth-project/dist-newstyle" ] \
     || [ -e "$WORK/fromtest/my-plinth-project/cabal.project.local" ]; then
    fail "--from leaked build junk into the project"
  else
    pass "--from copies only the explicit file list (seeded junk not copied)"
  fi
  expect_no_git "$WORK/fromtest/my-plinth-project"
else
  fail "--from run exited non-zero"; sed 's/^/    /' "$WORK/log-from" | tail -30
fi

echo ""
echo "== --from a git WORKTREE (.git is a pointer file) =="
# Regression: the worktree's .git FILE must never end up in a project — a
# project carrying it would point at (and could corrupt) the SOURCE repository.
mkdir -p "$WORK/fromwt"
if ( cd "$WORK/fromwt" && \
     env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --env docker \
       --docker-mode codespaces --from "$ROOT" --dir wt-project \
       >"$WORK/log-fromwt" 2>&1 </dev/null ); then
  expect_no_git "$WORK/fromwt/wt-project"
else
  fail "--from worktree run exited non-zero"; sed 's/^/    /' "$WORK/log-fromwt" | tail -30
fi

# --------------------------------------------------------------------------
# Failure modes
# --------------------------------------------------------------------------

echo ""
echo "== failure: --env nix without nix on PATH =="
if run_install "$WORK/log-nonix" PATH="$GOOD:$FARM" -- \
     --env nix --dir "$WORK/out-nonix"; then
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
     --env cabal --dir "$WORK/out-oldghc" --crypto-libs skip; then
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
     --env cabal --dir "$WORK/out-oldcabal" --crypto-libs skip; then
  fail "--env cabal succeeded with cabal 3.6.2.0"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-oldcabal" "too old"
fi

echo ""
echo "== failure: pkg-config missing =="
if run_install "$WORK/log-nopc" PATH="$NOPKGCONF:$FARM" -- \
     --env cabal --dir "$WORK/out-nopc" --crypto-libs skip; then
  fail "--env cabal succeeded without pkg-config"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-nopc" "pkg-config not found"
fi

echo ""
echo "== failure: target directory already exists =="
mkdir -p "$WORK/out-exists"
if run_install "$WORK/log-exists" PATH="$GOOD:$FARM" -- \
     --env cabal --dir "$WORK/out-exists" --crypto-libs skip; then
  fail "succeeded although the target directory exists"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-exists" "already exists"
fi

# --------------------------------------------------------------------------
# No terminal: every unanswered question must die pointing at the flags
# (not with the shell's raw "cannot open /dev/tty"), and nothing may be
# created. Locally a controlling terminal may be present, so the runs are
# detached with setsid where available (macOS ships none by default: skip).
# --------------------------------------------------------------------------

echo ""
echo "== no terminal: prompts fail with a pointer to the flags =="
HAVE_SETSID=0
if command -v setsid >/dev/null 2>&1; then
  HAVE_SETSID=1
fi
# no_tty_install LOG [install.sh flags...]
no_tty_install() {
  log="$1"; shift
  if [ "$HAVE_SETSID" = 1 ]; then
    # setsid first: it is not in the farm, so it must resolve before the
    # PATH override takes effect. -w propagates the exit status.
    setsid -w env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --from "$SRC" "$@" \
      >"$log" 2>&1 </dev/null
  else
    env PATH="$GOOD:$FARM" sh "$ROOT/install.sh" --from "$SRC" "$@" \
      >"$log" 2>&1 </dev/null
  fi
}
if [ "$HAVE_SETSID" = 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  echo "  skip: controlling terminal present and no setsid to shed it (brew install util-linux)"
else
  # (1) missing --env: the very first question
  if no_tty_install "$WORK/log-notty1" --dir "$WORK/out-notty1"; then
    fail "succeeded without a terminal and without --env"
  else
    pass "missing --env exits non-zero"
    expect_in_log "$WORK/log-notty1" "Every question has a flag"
    if [ ! -e "$WORK/out-notty1" ]; then
      pass "nothing created"
    else
      fail "created despite the unanswered question"
    fi
  fi
  # (2) the system-prefix question — regression test: it used to fire AFTER
  # create_project, stranding a half-configured project on failure
  if no_tty_install "$WORK/log-notty2" --env cabal --crypto-libs system \
       --dir "$WORK/out-notty2"; then
    fail "succeeded without a terminal and without --prefix"
  else
    pass "missing --prefix exits non-zero"
    expect_in_log "$WORK/log-notty2" "Every question has a flag"
    if [ ! -e "$WORK/out-notty2" ]; then
      pass "nothing created before the prefix question"
    else
      fail "created before the prefix question was answered"
    fi
  fi
fi

# --------------------------------------------------------------------------
# --repo: parsed and validated (the fetch itself is covered by --from)
# --------------------------------------------------------------------------

echo ""
echo "== --repo: URL form accepted, garbage rejected =="
if run_install "$WORK/log-repo-ok" PATH="$GOOD:$FARM" -- \
     --repo https://github.com/IntersectMBO/plinth-template.git \
     --env docker --docker-mode codespaces --dir "$WORK/out-repo-ok"; then
  pass "--repo URL form accepted (alongside --from)"
else
  fail "--repo URL form broke a --from install"
  sed 's/^/    /' "$WORK/log-repo-ok" | tail -5
fi
if run_install "$WORK/log-repo-bad" PATH="$GOOD:$FARM" -- \
     --repo https://github.com/bogus \
     --env docker --docker-mode codespaces --dir "$WORK/out-repo-bad"; then
  fail "--repo without an OWNER/REPO shape was accepted"
else
  pass "exits non-zero"
  # 'bogus' without the URL prefix proves the stripping ran before validation
  expect_in_log "$WORK/log-repo-bad" "invalid --repo 'bogus'"
  if [ ! -e "$WORK/out-repo-bad" ]; then
    pass "nothing created"
  else
    fail "created despite the invalid --repo"
  fi
fi

# --------------------------------------------------------------------------
# curl is only required when something will actually be downloaded
# --------------------------------------------------------------------------

echo ""
echo "== --crypto-libs skip works without curl =="
if run_install "$WORK/log-nocurl-skip" PATH="$GOOD:$NOCURL_FARM" -- \
     --env cabal --dir "$WORK/out-nocurl-skip" --crypto-libs skip; then
  pass "succeeds without curl in skip mode"
  expect_in_log "$WORK/log-nocurl-skip" "cabal build all"
else
  fail "--crypto-libs skip demanded curl"
  sed 's/^/    /' "$WORK/log-nocurl-skip" | tail -10
fi

echo ""
echo "== --crypto-libs local still requires curl =="
if run_install "$WORK/log-nocurl-local" PATH="$GOOD:$NOCURL_FARM" -- \
     --env cabal --dir "$WORK/out-nocurl-local" --crypto-libs local; then
  fail "--crypto-libs local succeeded without curl"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-nocurl-local" "curl is required (to download the crypto C libraries)"
  if [ ! -e "$WORK/out-nocurl-local" ]; then
    pass "nothing created"
  else
    fail "created despite missing curl"
  fi
fi

# --------------------------------------------------------------------------
# aarch64 Linux: no prebuilt crypto libraries exist for it — the scripts
# must say so up front instead of installing x86_64 binaries that fail at
# link time an hour later (uname is stubbed; nothing touches the network)
# --------------------------------------------------------------------------

ARMSTUB="$WORK/stubs-uname-arm"
mkdir -p "$ARMSTUB"
cat > "$ARMSTUB/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -m) echo aarch64 ;;
  *)  echo Linux ;;
esac
EOF
chmod +x "$ARMSTUB/uname"

echo ""
echo "== get-crypto-libs.sh on (faked) aarch64 Linux dies before downloading =="
mkdir -p "$WORK/arm-scratch"
if ( cd "$WORK/arm-scratch" && \
     env PATH="$ARMSTUB:$FARM" PLINTH_CRYPTO_LIBS_PLATFORM= \
       bash "$SRC/get-crypto-libs.sh" >"$WORK/log-gcl-arm" 2>&1 </dev/null ); then
  fail "get-crypto-libs.sh succeeded on aarch64 Linux"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-gcl-arm" "no prebuilt libraries exist for aarch64 Linux"
fi

echo ""
echo "== install.sh --env cabal on (faked) aarch64 Linux =="
if run_install "$WORK/log-arm-local" PATH="$ARMSTUB:$GOOD:$FARM" \
     PLINTH_CRYPTO_LIBS_PLATFORM= -- \
     --env cabal --crypto-libs local --dir "$WORK/out-arm-local"; then
  fail "--crypto-libs local succeeded on aarch64 Linux"
else
  pass "exits non-zero"
  expect_in_log "$WORK/log-arm-local" "no prebuilt crypto C libraries exist for aarch64 Linux"
  if [ ! -e "$WORK/out-arm-local" ]; then
    pass "nothing created"
  else
    fail "created despite the unsupported architecture"
  fi
fi
if run_install "$WORK/log-arm-skip" PATH="$ARMSTUB:$GOOD:$FARM" \
     PLINTH_CRYPTO_LIBS_PLATFORM= -- \
     --env cabal --crypto-libs skip --dir "$WORK/out-arm-skip"; then
  pass "--crypto-libs skip still works on aarch64 Linux"
else
  fail "--crypto-libs skip refused on aarch64 Linux"
  sed 's/^/    /' "$WORK/log-arm-skip" | tail -10
fi

# --------------------------------------------------------------------------
# --prefix with a literal '~': install.sh must expand it before the
# writability probe, before invoking get-crypto-libs.sh and in the printed
# exports — and must NOT create a literal './~' directory in the cwd.
# get-crypto-libs.sh is stubbed: this tests install.sh's plumbing, not the
# download.
# --------------------------------------------------------------------------

echo ""
echo "== --crypto-libs system: '~' in --prefix expands before anything runs =="
STUBSRC="$WORK/fixture-stub"
cp -R "$SRC" "$STUBSRC"
cat > "$STUBSRC/get-crypto-libs.sh" <<'EOF'
#!/bin/sh
echo "stub-get-crypto-libs: $*"
EOF
chmod +x "$STUBSRC/get-crypto-libs.sh"
mkdir -p "$WORK/tildetest" "$WORK/fakehome"
# shellcheck disable=SC2088 # passing a LITERAL, unexpanded ~ is the point
if ( cd "$WORK/tildetest" && \
     env PATH="$GOOD:$FARM" HOME="$WORK/fakehome" sh "$ROOT/install.sh" \
       --env cabal --crypto-libs system --prefix '~/cryptoprefix' \
       --from "$STUBSRC" --dir out-tilde \
       >"$WORK/log-tilde" 2>&1 </dev/null ); then
  if [ -d "$WORK/fakehome/cryptoprefix/lib" ]; then
    pass "prefix expanded to \$HOME before the writability probe"
  else
    fail "expanded prefix not created under the fake HOME"
  fi
  if [ -e "$WORK/tildetest/~" ]; then
    fail "a literal '~' directory was created in the cwd"
  else
    pass "no literal '~' directory in the cwd"
  fi
  expect_in_log "$WORK/log-tilde" "stub-get-crypto-libs: --prefix $WORK/fakehome/cryptoprefix"
  expect_in_log "$WORK/log-tilde" "$WORK/fakehome/cryptoprefix/lib/pkgconfig"
else
  fail "tilde-prefix run exited non-zero"
  sed 's/^/    /' "$WORK/log-tilde" | tail -20
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
       --env cabal --dir "$WORK/out-crypto" --crypto-libs local; then
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
