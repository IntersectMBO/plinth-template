#!/usr/bin/env bash
#
# Download the prebuilt Cardano crypto C libraries (libsodium, libsecp256k1,
# libblst) published by IOG at https://github.com/input-output-hk/iohk-nix/releases
# so that cardano-crypto-class (a transitive dependency of plutus-core) can
# satisfy its pkgconfig-depends without nix and without installing anything
# system-wide. The files are stored once per user in
# ~/.cache/plinth-crypto-libs/ (override with PLINTH_CRYPTO_LIBS_HOME) and
# linked into the project at dist-newstyle/crypto-libs/<platform>: the cache
# path is what cabal bakes into compiled packages, so the user-wide cabal
# store stays valid across projects and survives `cabal clean` — which only
# removes the link; the next run relinks instantly, nothing is re-downloaded.
#
# After running this script, point pkg-config at the local install, e.g.:
#
#   source dist-newstyle/crypto-libs/env.sh
#   cabal build all
#
# or, fully hermetic (ONLY the downloaded libs are visible to pkg-config):
#
#   export PKG_CONFIG_LIBDIR="$(pwd)/dist-newstyle/crypto-libs/<platform>/lib/pkgconfig"
#
# Every downloaded artifact is verified against a sha256 pinned in this file,
# and the release's COMMIT_SHA asset is required to match the pinned iohk-nix
# commit below.
#
# Required tools: curl, tar (the system one), and shasum or sha256sum.
# All of these ship by default on macOS and on typical Linux distributions.
# On Windows, use the msys2.* release assets with pacman inside GHC's MSYS2
# environment (see README).

set -euo pipefail

# --------------------------------------------------------------------------
# Pinned release
# --------------------------------------------------------------------------

RELEASE_TAG="v3.1"
# The iohk-nix commit the release was built from. The release publishes this
# in its COMMIT_SHA asset, which we download and check.
IOHK_NIX_COMMIT="bfdd1c3c12829d26a0e9a44f474d2adba45bf6c0"
COMMIT_SHA_ASSET_SHA256="a82bb754e8566a8c0e7814a429200d064420bed3de3a6a6a1458366a1402e2f6"

BASE_URL="https://github.com/input-output-hk/iohk-nix/releases/download/${RELEASE_TAG}"

# Per-platform assets and their pinned sha256 digests (from the GitHub release).
# Format: "<asset-name> <sha256>"
ASSETS_arm64_macos="
arm64-macos.libsodium.pkg b122d53cdc65ac1bf7f0c68ec093bbc49ffd9ab4a6472f45d043691fe1461c9d
arm64-macos.libsecp256k1.pkg 9cb674391baac56d45b7da6c4509f85037601d51eeae56db6b196f866a1db1dd
arm64-macos.libblst.pkg 71b0146d6b0310f2b6a7cb554444e98b0c9a5d6b9aeac025aeb351238593c45e
"
ASSETS_x86_64_macos="
x86_64-macos.libsodium.pkg e7a54367f652314ddaeb929a49dd59ae64061196f9df109841c21bb5d4c8eddd
x86_64-macos.libsecp256k1.pkg 2b3587189149d7a84caa7d1c90459f9d4ee155f95d83f7245b868cd948946138
x86_64-macos.libblst.pkg 118dd9078e894b98192643b5405463e85bb8fef50db84581c453e4ad2bce4491
"
ASSETS_debian="
debian.libsodium.deb 48d36a4a2c683325b12c801a55b2efc0104e31695e99850bc9bfa7e40513d935
debian.libsecp256k1.deb 4ff5b3d834478da36a5f4ec90bf592ac8b2445afed55d326f05b73aba5bae317
debian.libblst.deb ad6bbf94d98d7ded1947beea21e8accb0407086729f1b33b898980a9b684e797
"

# --------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $0 [--force] [--quiet] [--platform PLATFORM] [--prefix DIR]

Downloads IOG's prebuilt crypto C libraries (libsodium, libsecp256k1, libblst)
from the iohk-nix ${RELEASE_TAG} GitHub release into a per-user cache
(~/.cache/plinth-crypto-libs) linked into the project at
dist-newstyle/crypto-libs/ (the default), or into an arbitrary prefix
with --prefix.

Options:
  --force               Reinstall even if already installed.
  --quiet               Less output.
  --platform PLATFORM   Install the libraries for PLATFORM instead of the
                        detected host platform (for cross compilation).
                        One of: arm64-macos, x86_64-macos, debian.
  --prefix DIR          Install into DIR (e.g. /usr/local or ~/.local) instead
                        of dist-newstyle/crypto-libs/. Only lib/ and include/
                        entries for the three libraries are written; nothing
                        else in DIR is touched. DIR must be writable (rerun
                        with sudo if needed). In this mode the project files
                        (dist-newstyle/crypto-libs, env.sh) are NOT touched:
                        make sure DIR/lib/pkgconfig is on pkg-config's search
                        path when building.

Environment:
  PLINTH_CRYPTO_LIBS_PLATFORM       Same as --platform.
  PLINTH_CRYPTO_LIBS_HOME           Cache location (default:
                                    \$XDG_CACHE_HOME/plinth-crypto-libs or
                                    ~/.cache/plinth-crypto-libs).
EOF
}

FORCE=0
QUIET=0
PLATFORM="${PLINTH_CRYPTO_LIBS_PLATFORM:-}"
SYSTEM_PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    --platform) shift; PLATFORM="${1:?--platform needs an argument}" ;;
    --platform=*) PLATFORM="${1#--platform=}" ;;
    --prefix) shift; SYSTEM_PREFIX="${1:?--prefix needs an argument}" ;;
    --prefix=*) SYSTEM_PREFIX="${1#--prefix=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say() { if [ "$QUIET" != 1 ]; then echo "$@"; fi; }
die() { echo "get-crypto-libs: ERROR: $*" >&2; exit 1; }

# The script lives at the project root, next to cabal.project.
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Project-side helpers (local mode). They run both after a fresh install and
# on the fast already-installed path, so a wiped dist-newstyle heals on the
# next run — without re-downloading.
# ---------------------------------------------------------------------------

write_env_file() {
  mkdir -p "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# Generated by get-crypto-libs.sh. Source this file, then run cabal.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
EOF
}

link_into_project() {
  mkdir -p "$LINK_DIR"
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    # a real directory left behind by an older version of this script
    chmod -R u+w "$LINK" 2>/dev/null || true
    rm -rf "$LINK"
  fi
  rm -f "$LINK"
  ln -s "$PREFIX" "$LINK"
}

# --------------------------------------------------------------------------
# Platform selection: explicit (--platform / PLINTH_CRYPTO_LIBS_PLATFORM,
# e.g. when cross compiling) or detected from the host.
# --------------------------------------------------------------------------

if [ -z "$PLATFORM" ]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PLATFORM="arm64-macos" ;;
    Darwin-x86_64) PLATFORM="x86_64-macos" ;;
    Linux-*)       PLATFORM="debian" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "on Windows, install the msys2.* assets from ${BASE_URL} with pacman inside GHC's MSYS2 environment (see README)" ;;
    *) die "cannot detect platform from '$(uname -s)-$(uname -m)'; pass --platform" ;;
  esac
fi

case "$PLATFORM" in
  arm64-macos)  ASSETS="$ASSETS_arm64_macos" ;;
  x86_64-macos) ASSETS="$ASSETS_x86_64_macos" ;;
  debian)       ASSETS="$ASSETS_debian" ;;
  *) die "unsupported platform '$PLATFORM' (valid: arm64-macos, x86_64-macos, debian)" ;;
esac

# bsdtar understands the xar container of macOS .pkg files, the gzipped-cpio
# Payload inside it, and the ar container of .deb files. On macOS /usr/bin/tar
# is always bsdtar (a GNU tar earlier in \$PATH, e.g. from nix, would not
# work); elsewhere fall back to a bsdtar in PATH.
if [ -x /usr/bin/tar ] && /usr/bin/tar --version 2>/dev/null | grep -q bsdtar; then
  BSDTAR=/usr/bin/tar
elif command -v bsdtar >/dev/null 2>&1; then
  BSDTAR="$(command -v bsdtar)"
else
  BSDTAR=""
fi

# Two install modes:
#  - local (default): extract straight into dist-newstyle/crypto-libs/<platform>,
#    which is entirely owned by this script (safe to wipe and rebuild).
#  - system (--prefix DIR): extract into a throwaway staging directory, fix the
#    files up for DIR, and only then copy them over. DIR is never wiped; only
#    the three libraries' own lib/ and include/ entries are (over)written.
if [ -n "$SYSTEM_PREFIX" ]; then
  # A quoted "~" is not expanded by the caller's shell; do it here, then
  # absolutize (relative prefixes would silently depend on the cwd).
  # shellcheck disable=SC2088 # matching a LITERAL ~ the shell didn't expand
  case "$SYSTEM_PREFIX" in
    "~") SYSTEM_PREFIX="$HOME" ;;
    "~/"*) SYSTEM_PREFIX="$HOME/${SYSTEM_PREFIX#"~"/}" ;;
  esac
  case "$SYSTEM_PREFIX" in
    /*) : ;;
    *) SYSTEM_PREFIX="$(pwd)/$SYSTEM_PREFIX" ;;
  esac
  if ! mkdir -p "$SYSTEM_PREFIX/lib" "$SYSTEM_PREFIX/include" 2>/dev/null \
     || [ ! -w "$SYSTEM_PREFIX/lib" ]; then
    die "cannot write to $SYSTEM_PREFIX; rerun with sudo (or pick a writable --prefix)"
  fi
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/plinth-crypto-libs.XXXXXX")"
  trap 'chmod -R u+w "$STAGE" 2>/dev/null || true; rm -rf "$STAGE"' EXIT
  PREFIX="$STAGE/root"
  DOWNLOADS="$STAGE/downloads"
  FINAL_PREFIX="$SYSTEM_PREFIX"
else
  # Local (default) mode: the real files live in a stable per-user cache and
  # dist-newstyle/crypto-libs/<platform> is a symlink to them. cabal bakes
  # the libraries' absolute paths (dylib install names / runpaths) into the
  # packages it compiles into the user-wide store; a path under one
  # project's dist-newstyle would break every other project's builds as soon
  # as this project moved or disappeared. The cache path is stable, keyed by
  # release tag, shared by all Plinth projects, and nothing else on the
  # system is touched.
  CACHE_HOME="${PLINTH_CRYPTO_LIBS_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/plinth-crypto-libs}"
  PREFIX="$CACHE_HOME/$RELEASE_TAG/$PLATFORM"
  DOWNLOADS="$CACHE_HOME/downloads"
  LINK_DIR="$REPO_ROOT/dist-newstyle/crypto-libs"
  LINK="$LINK_DIR/$PLATFORM"
  ENV_FILE="$LINK_DIR/env.sh"
  STAMP="$PREFIX/.installed-$RELEASE_TAG-$IOHK_NIX_COMMIT"
  FINAL_PREFIX="$PREFIX"

  if [ -f "$STAMP" ] && [ "$FORCE" != 1 ]; then
    link_into_project
    write_env_file
    say "Crypto libs already installed in $PREFIX"
    say "(release $RELEASE_TAG, iohk-nix commit $IOHK_NIX_COMMIT; linked from $LINK)."
    say "Use --force to reinstall. To use them:  source $ENV_FILE"
    exit 0
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl is required"
fi

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "need shasum or sha256sum to verify downloads"
  fi
}

download() {
  # download <asset-name> <expected-sha256>
  local asset="$1" expected="$2" out="$DOWNLOADS/$1" actual
  if [ ! -f "$out" ] || [ "$(sha256_of "$out")" != "$expected" ]; then
    say "Downloading $asset ..."
    if ! curl --fail --silent --show-error --location --retry 3 \
           --output "$out.tmp" "$BASE_URL/$asset"; then
      die "failed to download $BASE_URL/$asset"
    fi
    mv "$out.tmp" "$out"
  fi
  actual="$(sha256_of "$out")"
  if [ "$actual" != "$expected" ]; then
    die "sha256 mismatch for $asset: expected $expected, got $actual"
  fi
  say "Verified $asset (sha256 OK)"
}

if [ -d "$PREFIX" ]; then
  chmod -R u+w "$PREFIX"
fi
rm -rf "$PREFIX"
mkdir -p "$PREFIX" "$DOWNLOADS"

# --------------------------------------------------------------------------
# Check the release's COMMIT_SHA against the pinned iohk-nix commit
# --------------------------------------------------------------------------

download "COMMIT_SHA" "$COMMIT_SHA_ASSET_SHA256"
RELEASE_COMMIT="$(cat "$DOWNLOADS/COMMIT_SHA")"
if [ "$RELEASE_COMMIT" != "$IOHK_NIX_COMMIT" ]; then
  die "release COMMIT_SHA ($RELEASE_COMMIT) does not match pinned iohk-nix commit ($IOHK_NIX_COMMIT)"
fi
say "Release $RELEASE_TAG was built from pinned iohk-nix commit $IOHK_NIX_COMMIT (verified)"

# --------------------------------------------------------------------------
# Download, verify and extract each library
# --------------------------------------------------------------------------

extract_into_prefix() {
  # extract_into_prefix <downloaded-file>
  local file="$1"
  case "$file" in
    *.pkg)
      # macOS flat installer package: a xar archive whose Payload member is a
      # gzipped cpio with the files rooted at the install prefix.
      if [ -z "$BSDTAR" ]; then
        die "extracting $file requires bsdtar (libarchive)"
      fi
      local tmp
      tmp="$(mktemp -d "$DOWNLOADS/expand.XXXXXX")"
      "$BSDTAR" -xf "$file" -C "$tmp" Payload
      "$BSDTAR" -xf "$tmp/Payload" -C "$PREFIX"
      rm -rf "$tmp"
      ;;
    *.deb)
      # Debian package: payload in data.tar.gz under ./usr/local/opt/cardano/.
      local tmp
      tmp="$(mktemp -d "$DOWNLOADS/expand.XXXXXX")"
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$file" "$tmp"
      elif [ -n "$BSDTAR" ]; then
        "$BSDTAR" -xOf "$file" data.tar.gz | tar -xzf - -C "$tmp"
      elif command -v ar >/dev/null 2>&1; then
        ar p "$file" data.tar.gz | tar -xzf - -C "$tmp"
      else
        die "need dpkg-deb, bsdtar or ar to extract $file"
      fi
      cp -a "$tmp/usr/local/opt/cardano/." "$PREFIX/"
      chmod -R u+w "$tmp"
      rm -rf "$tmp"
      ;;
    *)
      die "don't know how to extract $file"
      ;;
  esac
}

for entry in $(echo "$ASSETS" | awk 'NF {print $1 "@" $2}'); do
  asset="${entry%@*}"
  sha="${entry#*@}"
  download "$asset" "$sha"
  extract_into_prefix "$DOWNLOADS/$asset"
  # The payloads were built in the nix store and carry read-only permission
  # bits; make everything user-writable so subsequent extractions and
  # reinstalls into the same prefix work.
  chmod -R u+w "$PREFIX"
done

# --------------------------------------------------------------------------
# Fix up the local install:
#  - rewrite the .pc files' prefix to the local install dir
#  - create the unversioned .dylib/.so symlinks the linker needs
#  - (macOS) rewrite dylib install names to their real local path, so that
#    executables linked against them work without DYLD_LIBRARY_PATH
#  - drop libtool .la files (they carry stale paths and are not needed)
# --------------------------------------------------------------------------

if [ ! -d "$PREFIX/lib/pkgconfig" ]; then
  die "extraction failed: $PREFIX/lib/pkgconfig missing"
fi

# (not sed: an install path containing '&', '|' or '\' would corrupt the
# replacement. prefix= must stay first — later variables reference it.)
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
  { echo "prefix=$FINAL_PREFIX"; grep -v '^prefix=' "$pc"; } > "$pc.tmp"
  mv "$pc.tmp" "$pc"
done

rm -f "$PREFIX"/lib/*.la

case "$PLATFORM" in
  *macos)
    if command -v install_name_tool >/dev/null 2>&1; then
      for dylib in "$PREFIX"/lib/*.dylib; do
        if [ -L "$dylib" ]; then
          continue
        fi
        install_name_tool -id "$FINAL_PREFIX/lib/$(basename "$dylib")" "$dylib" 2>/dev/null
      done
    elif [ "$(uname -s)" = Darwin ]; then
      die "install_name_tool not found (install the Xcode command line tools: xcode-select --install)"
    else
      say "NOTE: install_name_tool unavailable on this host; dylib install names keep their original (nix store) paths."
    fi
    # Unversioned symlinks (the .pkg payloads only ship versioned dylibs;
    # libblst.dylib is shipped unversioned already).
    (
      cd "$PREFIX/lib"
      if [ ! -e libsodium.dylib ]; then
        ln -s libsodium.*.dylib libsodium.dylib
      fi
      if [ ! -e libsecp256k1.dylib ]; then
        ln -s libsecp256k1.*.dylib libsecp256k1.dylib
      fi
    )
    ;;
  debian)
    (
      cd "$PREFIX/lib"
      for base in libsodium libsecp256k1 libblst; do
        if [ ! -e "$base.so" ]; then
          for versioned in "$base".so.*; do
            if [ -e "$versioned" ]; then ln -s "$versioned" "$base.so"; break; fi
          done
        fi
      done
    )
    ;;
esac

# --------------------------------------------------------------------------
# System mode: merge-copy the staged, fixed-up files into the final prefix.
# Only lib/ and include/ contents coming from the three payloads are written;
# nothing already in the prefix is removed.
# --------------------------------------------------------------------------

if [ -n "$SYSTEM_PREFIX" ]; then
  chmod -R u+w "$PREFIX"
  cp -R "$PREFIX/lib/." "$SYSTEM_PREFIX/lib/"
  if [ -d "$PREFIX/include" ]; then
    cp -R "$PREFIX/include/." "$SYSTEM_PREFIX/include/"
  fi
fi

# --------------------------------------------------------------------------
# Sanity-check with pkg-config if available, write env file and stamp
# --------------------------------------------------------------------------

if command -v pkg-config >/dev/null 2>&1; then
  for lib in libsodium libsecp256k1 libblst; do
    if ! v="$(PKG_CONFIG_LIBDIR="$FINAL_PREFIX/lib/pkgconfig" pkg-config --modversion "$lib")"; then
      die "pkg-config cannot resolve $lib from $FINAL_PREFIX/lib/pkgconfig"
    fi
    p="$(PKG_CONFIG_LIBDIR="$FINAL_PREFIX/lib/pkgconfig" pkg-config --variable=prefix "$lib")"
    if [ "$p" != "$FINAL_PREFIX" ]; then
      die "$lib resolves to unexpected prefix: $p"
    fi
    say "$lib $v -> $FINAL_PREFIX (pkg-config OK)"
  done
else
  say "NOTE: pkg-config not found. cabal needs a pkg-config executable to use these libs."
fi

if [ -n "$SYSTEM_PREFIX" ]; then
  say ""
  say "Installed libsodium, libsecp256k1 and libblst into: $SYSTEM_PREFIX"
  say ""
  say "To build against them, make sure pkg-config can see them:"
  say ""
  say "  export PKG_CONFIG_PATH=\"$SYSTEM_PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}\""
  say "  cabal build all"
  exit 0
fi

touch "$STAMP"
link_into_project
write_env_file

say ""
say "Installed libsodium, libsecp256k1 and libblst into the per-user cache:"
say "  $PREFIX"
say "and linked them into the project at:"
say "  $LINK"
say ""
say "To build with them:"
say "  source $ENV_FILE"
say "  cabal build all"
