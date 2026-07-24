#!/usr/bin/env bash
#
# Test that `cabal run gen-auction-validator-blueprint` produces byte-identical
# output:
#
#   * across compilers:    GHC 9.6.7 and GHC 9.12.2
#   * across environments: ghcup toolchain vs `nix develop` shells
#
# Four scenarios are built and compared:
#
#   1. ghcup cabal + ghcup ghc-9.6.7   + prebuilt IOG crypto libs (flag ON)
#   2. ghcup cabal + ghcup ghc-9.12.2  + prebuilt IOG crypto libs (flag ON)
#   3. nix develop .#ghc96  (ghc 9.6.7,  crypto libs from nix, flag OFF)
#   4. nix develop .#ghc912 (ghc 9.12.2, crypto libs from nix, flag OFF)
#
# The script asserts aggressively that every toolchain component and the
# crypto C libraries come from the expected source in each scenario:
#
#   * ghcup scenarios: ghc/cabal resolve to $HOME/.ghcup/bin, and cabal reaches
#     the crypto libraries exclusively through the scripts/pkg-config shim
#     declared in cabal.project (which downloads them on first use — no manual
#     bootstrap step is performed by this test — and restricts the real
#     pkg-config to them with PKG_CONFIG_LIBDIR); the produced executable links
#     crypto dylibs from dist-newstyle/crypto-libs/ and nowhere else.
#   * nix scenarios: ghc/cabal resolve to /nix/store, the prebuilt-libs flag
#     is OFF (PLINTH_USE_SYSTEM_CRYPTO_LIBS=1, and we assert the script
#     no-ops), and the produced executable links crypto dylibs from /nix/store
#     and in particular NOT from dist-newstyle/crypto-libs/.
#
# Usage:
#   dev/ci/test-blueprint-parity.sh                # run all four scenarios
#   dev/ci/test-blueprint-parity.sh ghcup-ghc967   # run a single scenario
#     (scenarios: ghcup-ghc967 ghcup-ghc9122 nix-ghc96 nix-ghc912 compare)
#
# Environment:
#   PARITY_FRESH=1                Wipe the downloaded crypto libs, the test
#                                 cabal store and the test builddirs first, so
#                                 the ghcup scenarios prove the whole
#                                 cold-start flow (solver bootstrap included).
#   PARITY_ALLOW_GHC_DIVERGENCE=1 Downgrade the cross-GHC comparison to a
#                                 warning (see compare_outputs).

# shellcheck disable=SC2015 # A && B || C used deliberately in assertions
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# The pkg-config-location in cabal.project is relative to the invocation dir.
cd "$ROOT"
TESTDIR="$ROOT/dist-newstyle/test"
STORE_DIR="$TESTDIR/store"
BLUEPRINTS="$TESTDIR/blueprints"
GHCUP_BIN="$HOME/.ghcup/bin"

GHC96_VERSION="9.6.7"
GHC912_VERSION="9.12.2"

mkdir -p "$BLUEPRINTS"

# --------------------------------------------------------------------------
# Assertion helpers
# --------------------------------------------------------------------------

fail() {
  echo "ASSERTION FAILED: $*" >&2
  exit 1
}

note() { echo "  [ok] $*"; }
banner() { echo; echo "=== $* ==="; }

assert_eq() {
  # assert_eq <what> <expected> <actual>
  [ "$2" = "$3" ] || fail "$1: expected '$2', got '$3'"
  note "$1 = $2"
}

assert_prefix() {
  # assert_prefix <what> <expected-prefix> <actual>
  case "$3" in
    "$2"*) note "$1 = $3 (under $2)" ;;
    *) fail "$1: expected something under '$2', got '$3'" ;;
  esac
}

assert_contains() {
  # assert_contains <what> <needle> <haystack-text>
  case "$3" in
    *"$2"*) note "$1 contains '$2'" ;;
    *) fail "$1: does not contain '$2'. Full text:
$3" ;;
  esac
}

assert_not_contains() {
  # assert_not_contains <what> <needle> <haystack-text>
  case "$3" in
    *"$2"*) fail "$1: unexpectedly contains '$2'. Full text:
$3" ;;
    *) note "$1 does not contain '$2'" ;;
  esac
}

linked_libs() {
  # Print the dynamic libraries an executable links against.
  case "$(uname -s)" in
    Darwin) /usr/bin/otool -L "$1" | tail -n +2 | awk '{print $1}' ;;
    Linux)  ldd "$1" | awk '{print $3}' ;;
  esac
}

plan_field() {
  # plan_field <builddir> <python-expr over plan dict `p`>
  python3 - "$1/cache/plan.json" "$2" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
EOF
}

# --------------------------------------------------------------------------
# ghcup scenarios (prebuilt crypto libs flag ON — the default)
# --------------------------------------------------------------------------

run_ghcup_scenario() {
  # run_ghcup_scenario <ghc-version>
  local ghc_version="$1"
  local scenario="ghcup-ghc${ghc_version//./}"
  local builddir="$TESTDIR/$scenario"
  local out="$BLUEPRINTS/$scenario.json"

  banner "Scenario $scenario: ghcup cabal + ghcup ghc-$ghc_version + prebuilt IOG crypto libs (via scripts/pkg-config shim)"

  # Hermetic PATH: ghcup, the OS, and the directory of the real pkg-config
  # (the shim's backend). The crypto libs can still only be reached through
  # the scripts/pkg-config shim that cabal.project points cabal at: the shim
  # restricts the real pkg-config to the downloaded libraries with
  # PKG_CONFIG_LIBDIR, masking every system search directory.
  command -v pkg-config >/dev/null 2>&1 \
    || fail "pkg-config not found; install it (e.g. brew install pkgconf / apt install pkg-config)"
  local pkgconfig_dir
  pkgconfig_dir="$(dirname "$(command -v pkg-config)")"
  local path="$GHCUP_BIN:$pkgconfig_dir:/usr/bin:/bin:/usr/sbin:/sbin"

  local platform
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  platform="arm64-macos" ;;
    Darwin-x86_64) platform="x86_64-macos" ;;
    Linux-*)       platform="debian" ;;
    *) fail "unsupported platform for the ghcup scenario" ;;
  esac
  local prefix="$ROOT/dist-newstyle/crypto-libs/$platform"
  local pcdir="$prefix/lib/pkgconfig"

  # 1. Assert the toolchain comes from ghcup.
  local ghc_path cabal_path
  ghc_path="$(env -i PATH="$path" sh -c "command -v ghc-$ghc_version")" \
    || fail "ghc-$ghc_version not found in $GHCUP_BIN (install with: ghcup install ghc $ghc_version)"
  cabal_path="$(env -i PATH="$path" sh -c 'command -v cabal')" || fail "cabal not found in $GHCUP_BIN"
  assert_prefix "$scenario: ghc" "$GHCUP_BIN/" "$ghc_path"
  assert_prefix "$scenario: cabal" "$GHCUP_BIN/" "$cabal_path"
  assert_eq "$scenario: ghc version" "$ghc_version" \
    "$(env -i PATH="$path" sh -c "ghc-$ghc_version --numeric-version")"

  # 2. Build and run — NO manual bootstrap: cabal's solver invokes the shim,
  #    and the shim downloads and installs the crypto libs on first use. A
  #    dedicated builddir is used because cabal caches install plans and would
  #    not re-solve after environment changes; a dedicated store keeps
  #    artifacts built against other library sources out of reach.
  local cabal=(env -i HOME="$HOME" PATH="$path"
               cabal --store-dir="$STORE_DIR")
  local flags=(-w "ghc-$ghc_version" --builddir="$builddir")

  # On a cold start (no cabal.project.local yet) the first build bootstraps
  # the libs and writes cabal.project.local mid-run, too late for its own
  # configure phase — it stops once, and the re-run picks the file up. Any
  # other failure must fail twice and therefore still fails the test.
  if ! "${cabal[@]}" build "${flags[@]}" exe:gen-auction-validator-blueprint; then
    [ -f "$ROOT/cabal.project.local" ] \
      || fail "$scenario: cabal build failed without writing cabal.project.local"
    note "cold-start build stopped once as documented; re-running with cabal.project.local in place"
    "${cabal[@]}" build "${flags[@]}" exe:gen-auction-validator-blueprint
  fi
  rm -f "$out"
  "${cabal[@]}" run -v0 "${flags[@]}" exe:gen-auction-validator-blueprint -- "$out"
  [ -s "$out" ] || fail "$scenario: blueprint file was not produced"

  # 3. The build itself must have bootstrapped the libs via the shim, and the
  #    shim must resolve them exclusively from the local install.
  [ -f "$pcdir/libsodium.pc" ] && [ -f "$pcdir/libsecp256k1.pc" ] && [ -f "$pcdir/libblst.pc" ] \
    || fail "$scenario: cabal did not bootstrap the crypto libs via the shim"
  [ -L "$prefix" ] \
    || fail "$scenario: $prefix should be a symlink into the per-user cache"
  # The real install lives in the per-user cache; the project path is a
  # symlink to it, and all recorded paths (pc prefix, install names) use the
  # resolved cache location.
  local real_prefix
  real_prefix="$(cd "$prefix" && pwd -P)"
  note "cabal bootstrapped the crypto libs: $prefix -> $real_prefix"
  grep -qF "pkg-config-location: $ROOT/scripts/pkg-config" "$ROOT/cabal.project.local" \
    || fail "$scenario: cabal.project.local does not carry the shim stanza"
  note "cabal.project.local carries the absolute shim location for package configure"
  assert_eq "$scenario: shim libsodium prefix" "$real_prefix" \
    "$(env -i PATH="$path" "$ROOT/scripts/pkg-config" --variable=prefix libsodium)"
  env -i PATH="$path" "$ROOT/scripts/pkg-config" --exists libblst libsecp256k1 \
    || fail "$scenario: shim cannot resolve libblst/libsecp256k1"
  note "shim resolves libsodium/libsecp256k1/libblst exclusively from the local install"

  # 4. Assert the plan used the expected compiler.
  assert_eq "$scenario: plan compiler-id" "ghc-$ghc_version" \
    "$(plan_field "$builddir" "p['compiler-id']")"

  # 5. Assert the built executable links the crypto libs from the per-user
  #    cache (through which the shim serves them) and nowhere else.
  local bin libs
  bin="$("${cabal[@]}" list-bin "${flags[@]}" exe:gen-auction-validator-blueprint)"
  libs="$(linked_libs "$bin")"
  assert_contains "$scenario: linked libsodium" "$real_prefix/lib/libsodium" "$libs"
  assert_contains "$scenario: linked libsecp256k1" "$real_prefix/lib/libsecp256k1" "$libs"
  assert_not_contains "$scenario: linked libs" "/nix/store" "$libs"
  assert_not_contains "$scenario: linked libs" "/opt/homebrew" "$libs"
  assert_not_contains "$scenario: linked libs" "/usr/local" "$libs"

  echo "Scenario $scenario OK -> $out"
}

# --------------------------------------------------------------------------
# nix scenarios (prebuilt crypto libs flag OFF — libs must come from nix)
# --------------------------------------------------------------------------

run_nix_scenario() {
  # run_nix_scenario <shell-name> <ghc-version>
  local shell="$1" ghc_version="$2"
  local scenario="nix-$shell"

  banner "Scenario $scenario: nix develop .#$shell (ghc $ghc_version, crypto libs from nix)"

  command -v nix >/dev/null 2>&1 || fail "nix not found"

  # PLINTH_USE_SYSTEM_CRYPTO_LIBS=1 turns the prebuilt-libs feature OFF;
  # inside the nix shell the libs are provided by the iohk-nix overlays.
  PLINTH_USE_SYSTEM_CRYPTO_LIBS=1 \
    nix develop "$ROOT#$shell" --command bash "$ROOT/dev/ci/test-blueprint-parity.sh" \
      --inner-nix "$scenario" "$ghc_version"

  echo "Scenario $scenario OK -> $BLUEPRINTS/$scenario.json"
}

inner_nix() {
  # Runs INSIDE the nix shell.
  local scenario="$1" ghc_version="$2"
  local builddir="$TESTDIR/$scenario"
  local out="$BLUEPRINTS/$scenario.json"

  # 1. Assert the flag is OFF and the get-crypto-libs script is a no-op.
  assert_eq "$scenario: PLINTH_USE_SYSTEM_CRYPTO_LIBS" "1" "${PLINTH_USE_SYSTEM_CRYPTO_LIBS:-}"
  local msg
  msg="$("$ROOT/scripts/get-crypto-libs.sh")"
  assert_contains "$scenario: get-crypto-libs.sh" "skipping download" "$msg"
  [ -z "${PKG_CONFIG_LIBDIR:-}" ] || fail "$scenario: PKG_CONFIG_LIBDIR leaked into the nix shell"

  # 2. Assert the toolchain comes from the nix store.
  local ghc_path cabal_path
  ghc_path="$(command -v ghc)" || fail "no ghc in the nix shell"
  cabal_path="$(command -v cabal)" || fail "no cabal in the nix shell"
  assert_prefix "$scenario: ghc" "/nix/store/" "$ghc_path"
  assert_prefix "$scenario: cabal" "/nix/store/" "$cabal_path"
  assert_eq "$scenario: ghc version" "$ghc_version" "$(ghc --numeric-version)"

  # 3. Build and run.
  rm -f "$out"
  cabal build --builddir="$builddir" exe:gen-auction-validator-blueprint
  cabal run -v0 --builddir="$builddir" exe:gen-auction-validator-blueprint -- "$out"
  [ -s "$out" ] || fail "$scenario: blueprint file was not produced"

  # 4. Assert the plan used the expected compiler.
  assert_eq "$scenario: plan compiler-id" "ghc-$ghc_version" \
    "$(plan_field "$builddir" "p['compiler-id']")"

  # 5. Assert the executable links crypto libs from the nix store only.
  #    (Depending on the iohk-nix overlay they may be linked statically, in
  #    which case they don't show up at all — what must NEVER show up is a
  #    crypto lib from outside the nix store.)
  local bin libs crypto_libs
  bin="$(cabal list-bin --builddir="$builddir" exe:gen-auction-validator-blueprint)"
  libs="$(linked_libs "$bin")"
  crypto_libs="$(echo "$libs" | grep -iE 'sodium|secp256k1|blst' || true)"
  if [ -n "$crypto_libs" ]; then
    while IFS= read -r lib; do
      assert_prefix "$scenario: linked crypto lib" "/nix/store/" "$lib"
    done <<< "$crypto_libs"
  else
    note "crypto libs are statically linked (not in the dynamic link table)"
  fi
  assert_not_contains "$scenario: linked libs" "dist-newstyle/crypto-libs" "$libs"
  assert_not_contains "$scenario: linked libs" "plinth-crypto-libs" "$libs"
  assert_not_contains "$scenario: linked libs" "/opt/homebrew" "$libs"
  assert_not_contains "$scenario: linked libs" "/usr/local" "$libs"
}

# --------------------------------------------------------------------------
# Final comparison
# --------------------------------------------------------------------------

compare_pair() {
  # compare_pair <dimension> <scenario-a> <scenario-b>
  local a="$BLUEPRINTS/$2.json" b="$BLUEPRINTS/$3.json"
  if cmp -s "$a" "$b"; then
    note "$1: $2 == $3 (byte-identical)"
  else
    fail "$1: $2 and $3 produced different blueprints ($a vs $b)"
  fi
}

compare_outputs() {
  banner "Comparing blueprints"
  local f
  local all="ghcup-ghc${GHC96_VERSION//./} ghcup-ghc${GHC912_VERSION//./} nix-ghc96 nix-ghc912"
  for name in $all; do
    f="$BLUEPRINTS/$name.json"
    [ -s "$f" ] || fail "missing blueprint for scenario $name ($f). Run that scenario first."
    echo "  $(shasum -a 256 "$f" 2>/dev/null || sha256sum "$f")"
  done
  echo
  # Environment parity: the same compiler must produce the same output
  # whether it comes from ghcup (with the downloaded crypto libs) or from
  # nix (with the nix-provided crypto libs).
  compare_pair "environment parity (ghc $GHC96_VERSION)" "ghcup-ghc${GHC96_VERSION//./}" "nix-ghc96"
  compare_pair "environment parity (ghc $GHC912_VERSION)" "ghcup-ghc${GHC912_VERSION//./}" "nix-ghc912"
  # Compiler parity: different GHC versions should produce the same output.
  #
  # KNOWN LIMITATION: plutus-tx-plugin compiles GHC Core, and GHC 9.6 and
  # 9.12 produce different Core for the same source, so the compiledCode
  # (and therefore the validator hash) differs across compilers even though
  # everything else in the blueprint is identical. This is upstream
  # plutus-tx-plugin behavior, independent of ghcup/nix or the crypto libs.
  # Set PARITY_ALLOW_GHC_DIVERGENCE=1 to downgrade this to a warning.
  if [ "${PARITY_ALLOW_GHC_DIVERGENCE:-0}" = 1 ]; then
    if cmp -s "$BLUEPRINTS/ghcup-ghc${GHC96_VERSION//./}.json" "$BLUEPRINTS/ghcup-ghc${GHC912_VERSION//./}.json"; then
      note "compiler parity: ghc $GHC96_VERSION == ghc $GHC912_VERSION (byte-identical)"
    else
      echo "  [warn] compiler parity: ghc $GHC96_VERSION and ghc $GHC912_VERSION produce different compiledCode (known plutus-tx-plugin behavior)"
    fi
  else
    compare_pair "compiler parity (ghcup)" "ghcup-ghc${GHC96_VERSION//./}" "ghcup-ghc${GHC912_VERSION//./}"
    compare_pair "compiler parity (nix)" "nix-ghc96" "nix-ghc912"
  fi
  echo
  echo "SUCCESS: blueprints are byte-identical across environments (ghcup with downloaded crypto libs vs nix)."
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

if [ "${1:-}" = "--inner-nix" ]; then
  shift
  inner_nix "$@"
  exit 0
fi

if [ "${PARITY_FRESH:-0}" = 1 ]; then
  banner "PARITY_FRESH=1: wiping the crypto libs cache, cabal.project.local, test store and test builddirs (fresh-clone simulation)"
  CRYPTO_CACHE="${PLINTH_CRYPTO_LIBS_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/plinth-crypto-libs}"
  chmod -R u+w "$ROOT/dist-newstyle/crypto-libs" "$CRYPTO_CACHE" 2>/dev/null || true
  rm -rf "$ROOT/dist-newstyle/crypto-libs" "$CRYPTO_CACHE" "$STORE_DIR" \
         "$TESTDIR/ghcup-ghc${GHC96_VERSION//./}" "$TESTDIR/ghcup-ghc${GHC912_VERSION//./}"
  rm -f "$ROOT/cabal.project.local"
fi

case "${1:-all}" in
  all)
    run_ghcup_scenario "$GHC96_VERSION"
    run_ghcup_scenario "$GHC912_VERSION"
    run_nix_scenario ghc96 "$GHC96_VERSION"
    run_nix_scenario ghc912 "$GHC912_VERSION"
    compare_outputs
    ;;
  ghcup-ghc967)  run_ghcup_scenario "$GHC96_VERSION" ;;
  ghcup-ghc9122) run_ghcup_scenario "$GHC912_VERSION" ;;
  nix-ghc96)     run_nix_scenario ghc96 "$GHC96_VERSION" ;;
  nix-ghc912)    run_nix_scenario ghc912 "$GHC912_VERSION" ;;
  compare)       compare_outputs ;;
  *) echo "unknown scenario: $1" >&2; exit 2 ;;
esac
