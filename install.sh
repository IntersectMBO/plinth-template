#!/bin/sh
#
# plinth-template installer
#
#   curl -fsSL https://raw.githubusercontent.com/IntersectMBO/plinth-template/main/install.sh | sh
#
# Interactively sets up a new Plinth smart contract project from
# https://github.com/IntersectMBO/plinth-template. It asks which development
# environment you want (Nix, Docker, Demeter, or plain GHC+Cabal), verifies
# the required tools are installed, then creates a fresh project directory
# containing just the files that environment needs (copied from the
# repository's template/ directory) and — for the GHC+Cabal environment —
# optionally installs the Cardano crypto C libraries.
#
# Every question has a flag; pass them all for non-interactive use:
#
#   sh install.sh --env cabal --dir my-project --crypto-libs local
#
# Flags:
#   --env ENV           nix | docker | demeter | cabal
#   --docker-mode MODE  codespaces | devcontainer | standalone  (with --env docker)
#   --crypto-libs MODE  local | system | skip                   (with --env cabal)
#   --prefix DIR        prefix for --crypto-libs system (default /usr/local)
#   --dir NAME          project directory to create (default: my-plinth-project)
#   --repo URL          template repository on github.com (default: the
#                       official plinth-template)
#   --from DIR          take the template from a local checkout instead of
#                       downloading it (offline installs, CI)
#   --help, -h          this text
#
# POSIX sh; no bashisms. The entire logic lives in functions and the last
# line is `main "$@"`, so a partially downloaded script executes nothing.

set -eu

GHC_SERIES_A="9.6"
GHC_SERIES_B="9.12"
GHC_SERIES_A_NIX="ghc96"
GHC_SERIES_B_NIX="ghc912"
GHC_RECOMMENDED="9.6.7"

CABAL_MIN="3.8"
CABAL_RECOMMENDED="3.12"
CABAL_OLD_SERIES_A="[012].*"
CABAL_OLD_SERIES_B="3.[0246].*"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

setup_colors() {
  if [ -t 2 ] && [ "${TERM:-dumb}" != dumb ]; then
    BOLD="$(printf '\033[1m')"
    DIM="$(printf '\033[2m')"
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    CYAN="$(printf '\033[36m')"
    RESET="$(printf '\033[0m')"
  else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
  fi
}

say()  { printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "${CYAN}==>${RESET} ${BOLD}$*${RESET}" >&2; }
ok()   { printf '%s\n' "${GREEN}ok:${RESET} $*" >&2; }
warn() { printf '%s\n' "${YELLOW}warning:${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }

# quietly CMD...: silence stderr, keeping stdout.
# silently CMD...: silence both streams, for commands run purely for their
# exit status.
quietly() { "$@" 2>/dev/null; }
silently() { "$@" >/dev/null 2>&1; }

# tool_path NAME -> stdout: the resolved path of NAME, as `which` would
# print it (also the presence test the `have` predicate is built on).
tool_path() { command -v "$1"; }

have() { silently tool_path "$1"; }

# report_tool NAME VERSION: "ok: ghc 9.6.7 (/path/to/ghc)"
report_tool() { ok "$1 $2 ($(tool_path "$1"))"; }

# ---------------------------------------------------------------------------
# Interaction. Questions are read from /dev/tty: when the script is piped
# into sh (`curl ... | sh`) stdin is the script itself. Every question has a
# flag, so with no terminal the flags are the way to answer.
# ---------------------------------------------------------------------------

# ask PROMPT DEFAULT -> stdout: the answer (DEFAULT on empty input).
ask() {
  printf '%s [%s]: ' "${BOLD}$1${RESET}" "$2" >&2
  read -r ans < /dev/tty
  if [ -z "$ans" ]; then
    ans="$2"
  fi
  printf '%s' "$ans"
}

# confirm PROMPT DEFAULT(y|n) -> exit status
confirm() {
  ans="$(ask "$1 (y/n)" "$2")"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# choose DEFAULT N -> stdout: the chosen menu entry, a single digit 1..N.
# The caller prints the menu beforehand.
choose() {
  while :; do
    n="$(ask "Enter a number (1-$2)" "$1")"
    case "$n" in
      [1-9])
        if [ "$n" -le "$2" ]; then
          printf '%s' "$n"
          return 0
        fi
        ;;
    esac
    warn "please answer with a number between 1 and $2"
  done
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

IS_WSL=0

detect_platform() {
  case "$(uname -s)" in
    Darwin) ;;
    Linux)
      if quietly grep -qi microsoft /proc/version; then IS_WSL=1; fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      die "native Windows is not supported by this installer.
  Install WSL2 (https://learn.microsoft.com/windows/wsl/install) and run the
  installer again from your WSL shell."
      ;;
    *)
      warn "unrecognized platform '$(uname -s)'; continuing as if it were Linux"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Per-environment tool checks
# ---------------------------------------------------------------------------

nix_experimental_features() {
  if ! quietly nix config show experimental-features; then
    quietly nix show-config | sed -n 's/^experimental-features = //p'
  fi
}

nix_has_flakes() {
  case " $(nix_experimental_features) " in
    *" flakes "*) return 0 ;;
    *) return 1 ;;
  esac
}

nix_version() { quietly nix --version | sed 's/^nix (Nix) //'; }

check_nix() {
  if ! have nix; then
    die "nix is not installed.
  Follow https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md
  to install AND configure it (the configuration step sets up IOG's binary
  caches — without them the first build compiles GHC from source and takes
  hours), then run this installer again."
  fi
  if nix_has_flakes; then
    ok "nix $(nix_version) with flakes enabled"
  else
    warn "could not confirm that nix flakes are enabled. If 'nix develop' fails, add
  'experimental-features = nix-command flakes' to your nix.conf."
  fi
  say ""
  warn "make sure IOG's binary caches are configured (cache.iog.io); this guide
  explains how: https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md.
  Without them the first 'nix develop' builds GHC from source."
}

check_docker() {
  # $1 = docker mode
  case "$1" in
    codespaces)
      say "Codespaces run in GitHub's cloud; nothing to check locally."
      ;;
    devcontainer|standalone)
      if ! have docker; then
        die "docker is not installed (https://docs.docker.com/get-docker/).
  On Windows, install Docker on the native OS, not inside a VM
  (https://docs.docker.com/desktop/setup/vm-vdi/)."
      fi
      if silently docker info; then
        ok "docker daemon is running"
      else
        warn "docker is installed but the daemon does not respond; start Docker before building."
      fi
      if [ "$1" = devcontainer ]; then
        say "You will also need VSCode with the 'Dev Containers' extension."
      fi
      ;;
  esac
}

check_demeter() {
  say "Demeter (https://demeter.run) is a hosted platform; nothing to check locally."
}

check_cabal_env() {
  if ! have ghc; then
    die "ghc not found on PATH. Plinth supports GHC $GHC_SERIES_A.x and $GHC_SERIES_B.x.
  Install one with ghcup (https://www.haskell.org/ghcup/):
  ghcup install ghc $GHC_RECOMMENDED && ghcup set ghc $GHC_RECOMMENDED"
  fi
  ghc_version="$(ghc --numeric-version)"
  case "$ghc_version" in
    $GHC_SERIES_A.*|$GHC_SERIES_B.*)
      report_tool ghc "$ghc_version"
      ;;
    *)
      die "unsupported GHC version $ghc_version: Plinth supports $GHC_SERIES_A.x and $GHC_SERIES_B.x.
  Switch with ghcup, e.g.: ghcup install ghc $GHC_RECOMMENDED && ghcup set ghc $GHC_RECOMMENDED"
      ;;
  esac

  if ! have cabal; then
    die "cabal not found on PATH. Install it with ghcup: ghcup install cabal latest && ghcup set cabal latest"
  fi
  cabal_version="$(cabal --numeric-version)"
  # shellcheck disable=SC2254 # these constants ARE globs; matching as globs
  # is the point
  case "$cabal_version" in
    $CABAL_OLD_SERIES_A|$CABAL_OLD_SERIES_B)
      die "cabal $cabal_version is too old: $CABAL_MIN or newer is required ($CABAL_RECOMMENDED+ recommended).
  Upgrade with: ghcup install cabal latest && ghcup set cabal latest"
      ;;
  esac
  report_tool cabal "$cabal_version"

  if ! have pkg-config; then
    die "pkg-config not found on PATH; the project uses it to locate the crypto C libraries.
  Install it with:  brew install pkgconf  (macOS)  or  sudo apt install pkg-config  (Debian/Ubuntu)"
  fi
  report_tool pkg-config "$(pkg-config --version)"

  if ! have curl; then
    die "curl is required (to download the crypto C libraries)"
  fi
}

# ---------------------------------------------------------------------------
# Environment selection
# ---------------------------------------------------------------------------

detected_default_env() {
  if have nix; then echo nix
  elif have cabal; then echo cabal
  elif have docker; then echo docker
  else echo nix
  fi
}

mark() { # mark CMD: "(detected)" suffix for menu lines
  if have "$1"; then printf '%s' " ${GREEN}(detected)${RESET}"; fi
}

# select_env -> stdout: nix | docker | demeter | cabal
select_env() {
  say ""
  info "Which development environment do you want to use?"
  say ""
  say "  1) Nix        ${DIM}nix develop shell with the full toolchain (recommended)${RESET}$(mark nix)"
  say "  2) Docker     ${DIM}devx container: Codespaces, VSCode devcontainer or standalone${RESET}$(mark docker)"
  say "  3) Demeter    ${DIM}hosted cloud workspace at https://demeter.run${RESET}"
  say "  4) GHC+Cabal  ${DIM}your own ghc/cabal from ghcup, no nix, no docker${RESET}$(mark ghc)"
  say ""
  case "$(detected_default_env)" in
    nix) default_n=1 ;;
    docker) default_n=2 ;;
    demeter) default_n=3 ;;
    cabal) default_n=4 ;;
  esac
  case "$(choose "$default_n" 4)" in
    1) echo nix ;;
    2) echo docker ;;
    3) echo demeter ;;
    4) echo cabal ;;
  esac
}

# select_docker_mode -> stdout: devcontainer | codespaces | standalone
select_docker_mode() {
  say ""
  info "How do you want to run the Docker environment?"
  say ""
  say "  1) Devcontainer  ${DIM}open the project in VSCode's Dev Containers${RESET}"
  say "  2) Codespaces    ${DIM}run it on GitHub's cloud, in the browser${RESET}"
  say "  3) Standalone    ${DIM}plain 'docker run' with the project mounted${RESET}"
  say ""
  case "$(choose 1 3)" in
    1) echo devcontainer ;;
    2) echo codespaces ;;
    3) echo standalone ;;
  esac
}

# ---------------------------------------------------------------------------
# Crypto C libraries
# ---------------------------------------------------------------------------

explain_crypto_libs() {
  say ""
  info "About the crypto C libraries"
  say ""
  say "  Plinth projects depend (via plutus-core and cardano-crypto-class) on"
  say "  three C libraries: ${BOLD}libsodium${RESET} (VRF-patched), ${BOLD}libsecp256k1${RESET} and ${BOLD}libblst${RESET}."
  case "$ENV_CHOICE" in
    nix)
      say "  Your Nix shell provides all three automatically — nothing to install."
      ;;
    docker)
      say "  The devx container image provides all three via nix — nothing to install."
      ;;
    demeter)
      say "  Demeter workspaces come with nix preinstalled, and the project's own"
      say "  nix shell provides all three libraries — nothing to install locally."
      ;;
    cabal)
      say "  Without nix, they must be available on your machine. This template can"
      say "  download the prebuilt binaries IOG publishes at"
      say "  https://github.com/input-output-hk/iohk-nix/releases (sha256- and"
      say "  commit-pinned) into a per-user cache linked into the project, or"
      say "  system-wide, or you can install them manually."
      ;;
  esac
}

# select_crypto_mode -> stdout: local | system | skip
select_crypto_mode() {
  say ""
  info "How do you want to install the crypto C libraries?"
  say ""
  say "  1) Managed        ${DIM}downloaded once into ~/.cache/plinth-crypto-libs, linked into"
  say "                    <project>/dist-newstyle — nothing system-wide (recommended)${RESET}"
  say "  2) System-wide    ${DIM}into a prefix such as /usr/local (may need sudo)${RESET}"
  say "  3) Skip           ${DIM}install them yourself later${RESET}"
  say ""
  case "$(choose 1 3)" in
    1) echo local ;;
    2) echo system ;;
    3) echo skip ;;
  esac
}

install_crypto_libs() {
  case "$CRYPTO_MODE" in
    local)
      say ""
      info "Installing the crypto C libraries (per-user cache, linked into the project)"
      if ! "$TARGET_DIR/get-crypto-libs.sh"; then
        die "crypto library installation failed; retry later with: cd $TARGET_DIR; ./get-crypto-libs.sh"
      fi
      say ""
      say "  ${YELLOW}Note:${RESET} the project only holds a link (dist-newstyle/crypto-libs) to"
      say "  the per-user cache (~/.cache/plinth-crypto-libs, shared by all your"
      say "  Plinth projects), so 'cabal clean' costs nothing: re-running"
      say "  ./get-crypto-libs.sh re-links instantly, nothing is re-downloaded."
      ;;
    system)
      if [ -z "$CRYPTO_PREFIX" ]; then
        CRYPTO_PREFIX="$(ask "Install prefix" "/usr/local")"
      fi
      say ""
      info "Installing the crypto C libraries into $CRYPTO_PREFIX"
      if quietly mkdir -p "$CRYPTO_PREFIX/lib" "$CRYPTO_PREFIX/include" && [ -w "$CRYPTO_PREFIX/lib" ]; then
        if ! "$TARGET_DIR/get-crypto-libs.sh" --prefix "$CRYPTO_PREFIX"; then
          die "crypto library installation failed"
        fi
      elif confirm "$CRYPTO_PREFIX is not writable; use sudo?" n; then
        if ! sudo "$TARGET_DIR/get-crypto-libs.sh" --prefix "$CRYPTO_PREFIX"; then
          die "crypto library installation failed"
        fi
      else
        die "$CRYPTO_PREFIX is not writable. Rerun the installation yourself with:
  sudo $TARGET_DIR/get-crypto-libs.sh --prefix $CRYPTO_PREFIX"
      fi
      SYSTEM_CRYPTO_PREFIX="$CRYPTO_PREFIX"
      ;;
    skip)
      say ""
      say "  Skipping. Run ./get-crypto-libs.sh inside the project later, or"
      say "  install libsodium (VRF-patched), libsecp256k1 and libblst yourself"
      say "  — see the 'installing with cabal' section of"
      say "  https://developers.cardano.org/docs/get-started/cardano-node/installing-cardano-node/"
      say "  — and make sure pkg-config can find them (PKG_CONFIG_PATH)."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Fetching the template
# ---------------------------------------------------------------------------

# fetch_tarball DIR: download and extract the repository tarball into DIR.
fetch_tarball() {
  curl -fsSL --proto '=https' --tlsv1.2 \
    "https://codeload.github.com/IntersectMBO/plinth-template/tar.gz/HEAD" \
    | tar -xzf - --strip-components=1 -C "$1"
}

SRC_DIR=""
SRC_CLEANUP=""

fetch_source() {
  if [ -n "$FROM_DIR" ]; then
    SRC_DIR="$FROM_DIR"
    return 0
  fi
  if ! have curl; then
    die "curl is required to download the template"
  fi
  say ""
  info "Fetching github.com/IntersectMBO/plinth-template"
  SRC_CLEANUP="$(mktemp -d)"
  SRC_DIR="$SRC_CLEANUP/repo"
  mkdir -p "$SRC_DIR"
  if ! fetch_tarball "$SRC_DIR"; then
    die "could not download github.com/IntersectMBO/plinth-template"
  fi
}

# create_project ENV DIR: copy the template files ENV needs into DIR.
create_project() {
  env="$1"
  dir="$2"

  say ""
  info "Creating $dir ($env project)"
  say "" 

  mkdir -p "$dir"
  src="$SRC_DIR/template"
  cp -r "$src/cabal.project"         "$dir"
  cp -r "$src/plinth-template.cabal" "$dir"
  cp -r "$src/app"                   "$dir"
  cp -r "$src/src"                   "$dir"

  case "$env" in
    nix)
      cp -r "$src/nix"         "$dir"
      cp "$src/flake.lock"     "$dir"
      cp "$src/flake.nix"      "$dir"
      cp "$src/readmes/nix.md" "$dir/README.md"
      ;;
    demeter)
      cp -r "$src/nix"             "$dir"
      cp "$src/flake.lock"         "$dir"
      cp "$src/flake.nix"          "$dir"
      cp "$src/readmes/demeter.md" "$dir/README.md"
      ;;
    docker)
      cp -r "$src/.devcontainer"  "$dir"
      cp "$src/readmes/docker.md" "$dir/README.md"
      ;;
    cabal)
      # get-crypto-libs.sh sits next to install.sh in the repository, not in
      # template/; cp -p keeps its executable bit.
      cp -p "$SRC_DIR/get-crypto-libs.sh" "$dir"
      cp "$src/readmes/ghc-cabal.md"      "$dir/README.md"
      ;;
  esac

  ok "project created in $dir"
}

next_steps() {
  say ""
  info "All set! Next steps"
  say ""

  case "$ENV_CHOICE" in
    nix)
      say "  cd $TARGET_DIR"
      say "  nix develop          ${DIM}# first run downloads the toolchain from IOG's cache${RESET}"
      say "  cabal update         ${DIM}# first time only: fetches the hackage and CHaP indexes${RESET}"
      say "  cabal build all      ${DIM}# builds the example auction validator${RESET}"
      say ""
      say "  ${DIM}GHC $GHC_SERIES_A is the default (same as 'nix develop .#$GHC_SERIES_A_NIX');"
      say "  'nix develop .#$GHC_SERIES_B_NIX' gives you GHC $GHC_SERIES_B.${RESET}"
      ;;
    docker)
      case "$DOCKER_MODE" in
        devcontainer)
          say "  1. Open $TARGET_DIR in VSCode (with the Dev Containers extension)."
          say "  2. Accept 'Reopen in Container' when prompted."
          say "  3. In the container's terminal, run:  cabal update all && cabal build all"
          ;;
        codespaces)
          say "  1. Push $TARGET_DIR to a GitHub repository."
          say "  2. On GitHub: Code -> Codespaces -> Create codespace."
          say "  3. In the codespace's terminal, run:  cabal update all && cabal build all"
          ;;
        standalone)
          say "  cd $TARGET_DIR"
          say "  docker run -v \"\$PWD:/workspaces/my-project\" -w /workspaces/my-project \\"
          say "    -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog"
          say "  # then, inside the container:"
          say "  cabal update all && cabal build all"
          ;;
      esac
      ;;
    demeter)
      say "  1. Push $TARGET_DIR to a GitHub repository."
      say "  2. Create an account at https://demeter.run and follow https://docs.demeter.run to open a workspace from your repository."
      say "  3. In the workspace's terminal, run:"
      say "       nix develop"
      say "       cabal update && cabal build all"
      say "       cabal build all"
      ;;
    cabal)
      say "  cd $TARGET_DIR"
      say "  cabal update"
      case "$CRYPTO_MODE" in
        local)
          say "  source dist-newstyle/crypto-libs/env.sh   ${DIM}# points pkg-config at the crypto libs${RESET}"
          ;;
        system)
          say "  export PKG_CONFIG_PATH=\"$SYSTEM_CRYPTO_PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}\""
          say "  export LD_LIBRARY_PATH=\"$SYSTEM_CRYPTO_PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
          say "                       ${DIM}# add both to your shell profile; on Linux the second one is"
          say "                       # what lets the executables you build find the libraries at"
          say "                       # run time, unless $SYSTEM_CRYPTO_PREFIX/lib is already on the loader path${RESET}"
          ;;
        skip)
          say "  ./get-crypto-libs.sh"
          say "  source dist-newstyle/crypto-libs/env.sh"
          say "                       ${DIM}# or point PKG_CONFIG_PATH at your own libraries${RESET}"
          ;;
      esac
      say "  cabal build all"
      if [ "$CRYPTO_MODE" = local ] || [ "$CRYPTO_MODE" = skip ]; then
        say ""
        say "  ${DIM}After 'cabal clean', re-run ./get-crypto-libs.sh (instant: it only"
        say "  re-links the per-user cache and rewrites env.sh — see README).${RESET}"
      fi
      ;;
  esac
  say ""
  say "  ${BOLD}cabal build all${RESET} compiles the example auction validator; then follow"
  say "  https://plutus.cardano.intersectmbo.org/docs/ to make it your own."
  say ""
}

# ---------------------------------------------------------------------------

usage() {
  say "plinth-template installer — set up a new Plinth smart contract project."
  say ""
  say "Usage: install.sh [flags]     (asks about anything not covered by a flag)"
  say ""
  say "  --env ENV           nix | docker | demeter | cabal"
  say "  --docker-mode MODE  codespaces | devcontainer | standalone (with --env docker)"
  say "  --crypto-libs MODE  local | system | skip                  (with --env cabal)"
  say "  --prefix DIR        prefix for --crypto-libs system (default /usr/local)"
  say "  --dir NAME          project directory to create (default: my-plinth-project)"
  say "  --from DIR          take the template from a local checkout (offline, CI)"
  say "  --help, -h          this text"
}

main() {
  setup_colors
  ENV_CHOICE=""
  DOCKER_MODE=""
  CRYPTO_MODE=""
  CRYPTO_PREFIX=""
  SYSTEM_CRYPTO_PREFIX=""
  TARGET_DIR=""
  FROM_DIR=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --env) shift; ENV_CHOICE="${1:?--env needs an argument}" ;;
      --env=*) ENV_CHOICE="${1#--env=}" ;;
      --docker-mode) shift; DOCKER_MODE="${1:?--docker-mode needs an argument}" ;;
      --docker-mode=*) DOCKER_MODE="${1#--docker-mode=}" ;;
      --crypto-libs) shift; CRYPTO_MODE="${1:?--crypto-libs needs an argument}" ;;
      --crypto-libs=*) CRYPTO_MODE="${1#--crypto-libs=}" ;;
      --prefix) shift; CRYPTO_PREFIX="${1:?--prefix needs an argument}" ;;
      --prefix=*) CRYPTO_PREFIX="${1#--prefix=}" ;;
      --dir) shift; TARGET_DIR="${1:?--dir needs an argument}" ;;
      --dir=*) TARGET_DIR="${1#--dir=}" ;;
      --from) shift; FROM_DIR="${1:?--from needs an argument}" ;;
      --from=*) FROM_DIR="${1#--from=}" ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1 (see --help)" ;;
    esac
    shift
  done

  case "$ENV_CHOICE" in
    ''|nix|docker|demeter|cabal) ;;
    ghc-cabal|ghc+cabal) ENV_CHOICE=cabal ;;
    *) die "invalid --env '$ENV_CHOICE' (valid: nix, docker, demeter, cabal)" ;;
  esac
  case "$DOCKER_MODE" in
    ''|codespaces|devcontainer|standalone) ;;
    *) die "invalid --docker-mode '$DOCKER_MODE' (valid: codespaces, devcontainer, standalone)" ;;
  esac
  case "$CRYPTO_MODE" in
    ''|local|system|skip) ;;
    *) die "invalid --crypto-libs '$CRYPTO_MODE' (valid: local, system, skip)" ;;
  esac

  detect_platform

  say ""
  say "${BOLD}plinth-template${RESET} — set up a new Plinth smart contract project"
  say "${DIM}Plinth is Cardano's Haskell-based smart contract language (GHC $GHC_SERIES_A/$GHC_SERIES_B).${RESET}"
  
  if [ "$IS_WSL" = 1 ]; then
    say "${DIM}(WSL detected — following the Linux path.)${RESET}"
  fi

  if [ -z "$ENV_CHOICE" ]; then
    ENV_CHOICE="$(select_env)"
  fi

  if [ "$ENV_CHOICE" = docker ] && [ -z "$DOCKER_MODE" ]; then
    DOCKER_MODE="$(select_docker_mode)"
  fi

  explain_crypto_libs

  if [ "$ENV_CHOICE" = cabal ] && [ -z "$CRYPTO_MODE" ]; then
    CRYPTO_MODE="$(select_crypto_mode)"
  fi

  say ""
  info "Checking prerequisites for the '$ENV_CHOICE' environment"
  say ""

  case "$ENV_CHOICE" in
    nix)     check_nix ;;
    docker)  check_docker "$DOCKER_MODE" ;;
    demeter) check_demeter ;;
    cabal)   check_cabal_env ;;
  esac

  if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$(ask "Project directory" "my-plinth-project")"
  fi

  if [ -e "$TARGET_DIR" ]; then
    die "target directory '$TARGET_DIR' already exists; pick another name (--dir)"
  fi

  trap 'if [ -n "$SRC_CLEANUP" ]; then rm -rf "$SRC_CLEANUP"; fi' EXIT
  fetch_source
  create_project "$ENV_CHOICE" "$TARGET_DIR"
  if [ "$ENV_CHOICE" = cabal ]; then
    install_crypto_libs
  fi
  next_steps
}

main "$@"
