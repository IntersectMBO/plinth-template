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
# containing just the files that environment needs (the repository itself
# carries the union of all environments) and — for the GHC+Cabal
# environment — optionally installs the Cardano crypto C libraries.
#
# Non-interactive use (all prompts have flags; --yes accepts defaults):
#
#   sh install.sh --env cabal --dir my-project --crypto-libs local --yes
#
# Flags:
#   --env ENV           nix | docker | demeter | cabal
#   --docker-mode MODE  codespaces | devcontainer | standalone  (with --env docker)
#   --crypto-libs MODE  local | system | skip                   (with --env cabal)
#   --prefix DIR        prefix for --crypto-libs system (default /usr/local)
#   --dir NAME          project directory to create (default: my-plinth-project)
#   --repo URL          template repository (default: official plinth-template)
#   --branch NAME       fetch NAME instead of the repository's default branch
#   --from DIR          take the template from a local directory instead of
#                       fetching it (offline installs, CI)
#   --yes, -y           don't ask; use defaults for unanswered questions
#   --help, -h          this text
#
# Environment variables:
#   PLINTH_TEMPLATE_REPO   same as --repo
#   NO_COLOR               disable colored output
#
# POSIX sh; no bashisms. The entire logic lives in functions and the last
# line is `main "$@"`, so a partially downloaded script executes nothing.

set -eu

REPO_DEFAULT="https://github.com/IntersectMBO/plinth-template"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

setup_colors() {
  if [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
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
ok()   { printf '%s\n' "${GREEN} ok${RESET} $*" >&2; }
warn() { printf '%s\n' "${YELLOW}warning:${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# On a fresh macOS, /usr/bin/git is the Xcode CLT stub: it exists but every
# invocation pops the "install developer tools" dialog and fails. Only treat
# git as available when it actually runs.
git_works() { have git && git --version >/dev/null 2>&1; }

# The shell does not expand ~ in `read` answers or in flag values that were
# quoted; do it ourselves for everything used as a path.
expand_tilde() {
  # shellcheck disable=SC2088 # matching a LITERAL ~ the shell didn't expand
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# expand_tilde + absolutize, for paths echoed back as export lines.
normalize_path() {
  _p="$(expand_tilde "$1")"
  case "$_p" in
    /*) printf '%s' "$_p" ;;
    *) printf '%s/%s' "$PWD" "$_p" ;;
  esac
}

# ---------------------------------------------------------------------------
# Interaction. When the script is piped into sh (`curl ... | sh`) stdin is the
# script itself, so questions are read from /dev/tty instead. With --yes, or
# when no terminal is available at all, defaults are used. Answers are read
# from fd 3. PLINTH_INSTALL_TTY overrides the answer source (used by the CI
# tests to feed scripted answers).
# ---------------------------------------------------------------------------

INTERACTIVE=0

setup_input() {
  [ "$ASSUME_YES" = 1 ] && return 0
  # Test hook: pretend no terminal is available.
  [ -n "${PLINTH_INSTALL_NO_TTY:-}" ] && return 0
  if [ -n "${PLINTH_INSTALL_TTY:-}" ]; then
    [ -r "$PLINTH_INSTALL_TTY" ] || die "cannot read from PLINTH_INSTALL_TTY=$PLINTH_INSTALL_TTY"
    exec 3< "$PLINTH_INSTALL_TTY"
    INTERACTIVE=1
  elif [ -t 0 ]; then
    exec 3<&0
    INTERACTIVE=1
  elif (exec < /dev/tty) 2>/dev/null; then
    exec 3< /dev/tty
    INTERACTIVE=1
  fi
}

# ask PROMPT DEFAULT -> stdout: the answer (DEFAULT when non-interactive,
# empty input, or EOF).
ask() {
  if [ "$INTERACTIVE" = 0 ]; then
    printf '%s' "$2"
    return 0
  fi
  printf '%s [%s]: ' "${BOLD}$1${RESET}" "$2" >&2
  ans=""
  read -r ans <&3 || ans=""
  [ -n "$ans" ] || ans="$2"
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

# choose DEFAULT_NUMBER N -> stdout: chosen number (1..N). The caller prints
# the menu beforehand.
choose() {
  while :; do
    ans="$(ask "Enter a number (1-$2)" "$1")"
    case "$ans" in
      *[!0-9]*|'') ;;
      *) if [ "$ans" -ge 1 ] && [ "$ans" -le "$2" ]; then printf '%s' "$ans"; return 0; fi ;;
    esac
    [ "$INTERACTIVE" = 1 ] || die "invalid default answer '$ans'"
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
      if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi
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

check_nix() {
  have nix || die "nix is not installed.
Follow https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md
to install AND configure it (the configuration step sets up IOG's binary
caches — without them the first build compiles GHC from source and takes
hours), then run this installer again."
  feats="$(nix config show experimental-features 2>/dev/null \
           || nix show-config 2>/dev/null | sed -n 's/^experimental-features = //p')" || feats=""
  case " $feats " in
    *" flakes "*) ok "nix $(nix --version 2>/dev/null | sed 's/^nix (Nix) //') with flakes enabled" ;;
    *)
      warn "could not confirm that nix flakes are enabled. If 'nix develop'
fails, add 'experimental-features = nix-command flakes' to your nix.conf
(see https://github.com/input-output-hk/iogx/blob/main/doc/nix-setup-guide.md)."
      ;;
  esac
  warn "make sure IOG's binary caches are configured (cache.iog.io); the
nix-setup-guide linked above explains how. Without them the first
'nix develop' builds GHC from source."
}

check_docker() {
  # $1 = docker mode
  case "$1" in
    codespaces)
      say "Codespaces run in GitHub's cloud; nothing to check locally."
      ;;
    devcontainer|standalone)
      have docker || die "docker is not installed (https://docs.docker.com/get-docker/).
On Windows, install Docker on the native OS, not inside a VM
(https://docs.docker.com/desktop/setup/vm-vdi/)."
      if docker info >/dev/null 2>&1; then
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

# ver_ge A B: true when major.minor of A >= major.minor of B
ver_ge() {
  a_major=${1%%.*}; a_rest=${1#*.}; a_minor=${a_rest%%.*}
  b_major=${2%%.*}; b_rest=${2#*.}; b_minor=${b_rest%%.*}
  case "$a_major$a_minor" in *[!0-9]*) return 1 ;; esac
  [ "$a_major" -gt "$b_major" ] || { [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -ge "$b_minor" ]; }
}

check_cabal_env() {
  have ghc || die "ghc not found on PATH. Plinth supports GHC 9.6.x and 9.12.x.
Install one with ghcup (https://www.haskell.org/ghcup/):
  ghcup install ghc 9.6.7 && ghcup set ghc 9.6.7"
  ghc_version="$(ghc --numeric-version)"
  case "$ghc_version" in
    9.6.*|9.12.*) ok "ghc $ghc_version ($(command -v ghc))" ;;
    *) die "unsupported GHC version $ghc_version: Plinth supports 9.6.x and 9.12.x.
Switch with ghcup, e.g.: ghcup install ghc 9.6.7 && ghcup set ghc 9.6.7" ;;
  esac

  have cabal || die "cabal not found on PATH. Install it with ghcup:
  ghcup install cabal latest && ghcup set cabal latest"
  cabal_version="$(cabal --numeric-version)"
  ver_ge "$cabal_version" 3.8 \
    || die "cabal $cabal_version is too old: 3.8 or newer is required (3.12+ recommended).
Upgrade with: ghcup install cabal latest && ghcup set cabal latest"
  ok "cabal $cabal_version ($(command -v cabal))"

  have pkg-config || die "pkg-config not found on PATH; the project uses it to
locate the crypto C libraries. Install it with:
  macOS:         brew install pkgconf
  Debian/Ubuntu: sudo apt install pkg-config"
  ok "pkg-config $(pkg-config --version) ($(command -v pkg-config))"

  have curl || die "curl is required (to download the crypto C libraries)"
}

# Quiet probe used only to pick a sensible default menu entry.
cabal_env_looks_ready() {
  have ghc && have cabal && have pkg-config || return 1
  case "$(ghc --numeric-version 2>/dev/null)" in
    9.6.*|9.12.*) ;;
    *) return 1 ;;
  esac
  ver_ge "$(cabal --numeric-version 2>/dev/null)" 3.8
}

# ---------------------------------------------------------------------------
# Environment selection
# ---------------------------------------------------------------------------

detected_default_env() {
  if have nix; then echo nix
  elif cabal_env_looks_ready; then echo cabal
  elif have docker; then echo docker
  else echo nix
  fi
}

mark() { # mark CMD: "(detected)" suffix for menu lines
  if have "$1"; then printf '%s' " ${GREEN}(detected)${RESET}"; fi
}

select_env() {
  [ -n "$ENV_CHOICE" ] && return 0
  if [ "$INTERACTIVE" = 0 ]; then
    ENV_CHOICE="$(detected_default_env)"
    info "No answers available (--yes / no terminal): using environment '$ENV_CHOICE' (override with --env)"
    return 0
  fi
  default_env="$(detected_default_env)"
  say ""
  info "Which development environment do you want to use?"
  say ""
  say "  1) Nix        ${DIM}nix develop shell with the full toolchain (recommended)${RESET}$(mark nix)"
  say "  2) Docker     ${DIM}devx container: Codespaces, VSCode devcontainer or standalone${RESET}$(mark docker)"
  say "  3) Demeter    ${DIM}hosted cloud workspace at https://demeter.run${RESET}"
  say "  4) GHC+Cabal  ${DIM}your own ghc/cabal from ghcup, no nix, no docker${RESET}$(mark ghc)"
  say ""
  case "$default_env" in
    nix) default_n=1 ;;
    docker) default_n=2 ;;
    demeter) default_n=3 ;;
    cabal) default_n=4 ;;
  esac
  n="$(choose "$default_n" 4)"
  case "$n" in
    1) ENV_CHOICE=nix ;;
    2) ENV_CHOICE=docker ;;
    3) ENV_CHOICE=demeter ;;
    4) ENV_CHOICE=cabal ;;
  esac
}

select_docker_mode() {
  [ "$ENV_CHOICE" = docker ] || return 0
  [ -n "$DOCKER_MODE" ] && return 0
  if [ "$INTERACTIVE" = 0 ]; then
    DOCKER_MODE=devcontainer
    info "Using default docker mode 'devcontainer' (override with --docker-mode)"
    return 0
  fi
  say ""
  info "How do you want to run the Docker environment?"
  say ""
  say "  1) Devcontainer  ${DIM}open the project in VSCode's Dev Containers${RESET}"
  say "  2) Codespaces    ${DIM}run it on GitHub's cloud, in the browser${RESET}"
  say "  3) Standalone    ${DIM}plain 'docker run' with the project mounted${RESET}"
  say ""
  n="$(choose 1 3)"
  case "$n" in
    1) DOCKER_MODE=devcontainer ;;
    2) DOCKER_MODE=codespaces ;;
    3) DOCKER_MODE=standalone ;;
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

select_crypto_mode() {
  [ "$ENV_CHOICE" = cabal ] || return 0
  [ -n "$CRYPTO_MODE" ] && return 0
  if [ "$INTERACTIVE" = 0 ]; then
    CRYPTO_MODE=local
    info "Using default crypto-libs mode 'local' (override with --crypto-libs)"
    return 0
  fi
  say ""
  info "How do you want to install the crypto C libraries?"
  say ""
  say "  1) Managed        ${DIM}downloaded once into ~/.cache/plinth-crypto-libs, linked into"
  say "                    <project>/dist-newstyle — nothing system-wide (recommended)${RESET}"
  say "  2) System-wide    ${DIM}into a prefix such as /usr/local (may need sudo)${RESET}"
  say "  3) Skip           ${DIM}install them yourself later${RESET}"
  say ""
  n="$(choose 1 3)"
  case "$n" in
    1) CRYPTO_MODE=local ;;
    2) CRYPTO_MODE=system ;;
    3) CRYPTO_MODE=skip ;;
  esac
}

install_crypto_libs() {
  [ "$ENV_CHOICE" = cabal ] || return 0
  case "$CRYPTO_MODE" in
    local)
      say ""
      info "Installing the crypto C libraries (per-user cache, linked into the project)"
      (cd "$TARGET_DIR" && ./scripts/get-crypto-libs.sh) \
        || die "crypto library installation failed; you can retry later with
  cd $TARGET_DIR && ./scripts/get-crypto-libs.sh"
      say ""
      say "  ${YELLOW}Note:${RESET} the project only holds a link (dist-newstyle/crypto-libs) to"
      say "  the per-user cache (~/.cache/plinth-crypto-libs, shared by all your"
      say "  Plinth projects), so 'cabal clean' costs nothing: the next build"
      say "  re-links instantly, and nothing is ever re-downloaded."
      ;;
    system)
      prefix="$(normalize_path "$(ask "Install prefix" "$CRYPTO_PREFIX")")"
      say ""
      info "Installing the crypto C libraries into $prefix"
      if mkdir -p "$prefix/lib" "$prefix/include" 2>/dev/null && [ -w "$prefix/lib" ]; then
        "$TARGET_DIR/scripts/get-crypto-libs.sh" --prefix "$prefix" \
          || die "crypto library installation failed"
      elif [ "$INTERACTIVE" = 1 ] && confirm "$prefix is not writable; use sudo?" n; then
        sudo "$TARGET_DIR/scripts/get-crypto-libs.sh" --prefix "$prefix" \
          || die "crypto library installation failed"
      else
        die "$prefix is not writable. Rerun the installation yourself with:
  sudo $TARGET_DIR/scripts/get-crypto-libs.sh --prefix $prefix"
      fi
      SYSTEM_CRYPTO_PREFIX="$prefix"
      ;;
    skip)
      say ""
      say "  Skipping. Install libsodium (VRF-patched), libsecp256k1 and libblst"
      say "  yourself — see the 'installing with cabal' section of"
      say "  https://developers.cardano.org/docs/get-started/cardano-node/installing-cardano-node/"
      say "  — or run ./scripts/get-crypto-libs.sh inside the project later."
      say ""
      say "  If you install them system-wide, build with"
      say "  PLINTH_USE_SYSTEM_CRYPTO_LIBS=1 (and PKG_CONFIG_PATH pointing at"
      say "  them) so the project uses your libraries instead of downloading"
      say "  its own."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Cloning
# ---------------------------------------------------------------------------

# fetch_tarball REF DIR: download a github.com tarball into DIR (REF is a
# branch name, or HEAD for the default branch). Extracts into a sibling temp
# dir first so a failure never leaves a half-created DIR behind.
fetch_tarball() {
  case "$REPO" in
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  slug="${REPO#https://github.com/}"; slug="${slug%.git}"; slug="${slug%/}"
  case "$1" in
    HEAD) _ref="HEAD" ;;
    *) _ref="refs/heads/$1" ;;
  esac
  _tmp="$2.download.$$"
  mkdir -p "$_tmp"
  if curl -fsSL --proto '=https' --tlsv1.2 \
       "https://codeload.github.com/$slug/tar.gz/$_ref" \
       | tar -xzf - --strip-components=1 -C "$_tmp"; then
    mv "$_tmp" "$2"
  else
    rm -rf "$_tmp"
    return 1
  fi
}

# The repository is a single branch carrying the union of every
# environment's files. fetch_source obtains a copy (git clone, tarball, or a
# local directory via --from) and create_project copies just the files the
# chosen environment needs into the new project directory.

SRC_DIR=""
SRC_CLEANUP=""

fetch_source() {
  if [ -n "$FROM_DIR" ]; then
    [ -d "$FROM_DIR" ] || die "--from: '$FROM_DIR' is not a directory"
    SRC_DIR="$(cd "$FROM_DIR" && pwd)"
    [ -f "$SRC_DIR/plinth-template.cabal" ] \
      || die "--from: '$FROM_DIR' does not look like a plinth-template checkout"
    return 0
  fi
  say ""
  info "Fetching $REPO${BRANCH_OVERRIDE:+ (branch $BRANCH_OVERRIDE)}"
  SRC_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plinth-template-src.XXXXXX")"
  SRC_CLEANUP="$SRC_DIR"
  rm -rf "$SRC_DIR"
  if git_works; then
    if git clone --quiet --depth 1 ${BRANCH_OVERRIDE:+--branch "$BRANCH_OVERRIDE"} \
         --single-branch "$REPO" "$SRC_DIR"; then
      return 0
    fi
    warn "git clone failed; trying a tarball download instead"
  fi
  fetch_tarball "${BRANCH_OVERRIDE:-HEAD}" "$SRC_DIR" \
    || die "could not fetch $REPO
(the tarball fallback only works for github.com repositories)"
}

# list_source_files: relative paths of the template files, one per line.
# Inside a git checkout (--from on a working tree) this respects .gitignore,
# so build artifacts never leak into the new project. `.git` may be a FILE
# (worktrees), hence -e, and the find fallback must skip it by name.
list_source_files() {
  if [ -e "$SRC_DIR/.git" ] && git_works \
     && git -C "$SRC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SRC_DIR" ls-files --cached --others --exclude-standard
  else
    (cd "$SRC_DIR" && find . -type f ! -name .git ! -path './.git/*' | sed 's|^\./||')
  fi
}

# include_file ENV PATH: 0 when PATH belongs in an ENV project.
include_file() {
  case "$2" in
    # never copy git metadata (a copied worktree .git POINTER FILE would make
    # `git init` reinitialize the source repository!)
    .git|.git/*) return 1 ;;
    # replaced by the environment-specific README from dev/readmes/
    README.md) return 1 ;;
    # repo machinery, never part of a project
    .github/*|install.sh|dev/*) return 1 ;;
    SECURITY.md|CODEOWNERS.md|CONTRIBUTING.md|CODE_OF_CONDUCT.md) return 1 ;;
    CHANGELOG.md|DESCRIPTION.md) return 1 ;;
  esac
  case "$1" in
    nix|demeter)
      case "$2" in .devcontainer/*|scripts/*) return 1 ;; esac ;;
    docker)
      case "$2" in nix/*|flake.nix|flake.lock|scripts/*) return 1 ;; esac ;;
    cabal)
      case "$2" in nix/*|flake.nix|flake.lock|.devcontainer/*) return 1 ;; esac ;;
  esac
  return 0
}

# transform_block FILE BEGIN-MARKER END-MARKER [REPLACEMENT-LINE]
# Removes the marked block (markers included), optionally putting a single
# replacement line in its place. Fails loudly when the marker is missing —
# a silently kept block would produce a broken project.
transform_block() {
  grep -qF -e "$2" "$1" || die "template drift: marker '$2' not found in $1"
  awk -v b="$2" -v e="$3" -v r="${4:-}" '
    $0 == b { skip = 1; if (r != "") print r; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

create_project() {
  # $1 = env, $2 = target dir
  say ""
  info "Creating $2 ($1 project)"

  files_list="$(mktemp "${TMPDIR:-/tmp}/plinth-files.XXXXXX")"
  list_source_files > "$files_list"
  mkdir -p "$2"
  while IFS= read -r f; do
    [ -f "$SRC_DIR/$f" ] || continue
    include_file "$1" "$f" || continue
    case "$f" in
      */*) mkdir -p "$2/${f%/*}" ;;
    esac
    cp -p "$SRC_DIR/$f" "$2/$f"
  done < "$files_list"
  rm -f "$files_list"

  # Environment-specific README
  case "$1" in
    cabal) _readme="ghc-cabal" ;;
    *) _readme="$1" ;;
  esac
  [ -f "$SRC_DIR/dev/readmes/$_readme.md" ] \
    || die "template drift: dev/readmes/$_readme.md missing from the template"
  cp "$SRC_DIR/dev/readmes/$_readme.md" "$2/README.md"

  # Environment-specific bits inside shared files
  case "$1" in
    nix|demeter|docker)
      transform_block "$2/cabal.project" \
        "-- BEGIN ghc-cabal only" "-- END ghc-cabal only"
      ;;
    cabal)
      # the block stays; only the installer-facing marker lines go
      grep -vF -e "-- BEGIN ghc-cabal only" -e "-- END ghc-cabal only" \
        -e "-- (install.sh removes this whole block for Nix/Docker/Demeter projects)" \
        "$2/cabal.project" > "$2/cabal.project.tmp" \
        && mv "$2/cabal.project.tmp" "$2/cabal.project"
      ;;
  esac
  case "$1" in
    nix|demeter)
      transform_block "$2/nix/project.nix" \
        "      # BEGIN union source only" "      # END union source only" \
        "      src = lib.cleanSource ../.;"
      ;;
  esac

  # Fresh history: this is a template, not a fork.
  if git_works; then
    (cd "$2" && { git init -q -b main 2>/dev/null || git init -q; }) || warn "git init failed"
    ok "project created in $2 (fresh git history — make your first commit when ready)"
  else
    ok "project created in $2"
  fi
}

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------

next_steps() {
  say ""
  info "All set! Next steps"
  say ""
  case "$ENV_CHOICE" in
    nix)
      say "  cd $TARGET_DIR"
      say "  nix develop          ${DIM}# first run downloads the toolchain from IOG's cache${RESET}"
      say "  cabal build all      ${DIM}# builds the example auction validator${RESET}"
      say ""
      say "  ${DIM}GHC 9.6 is the default; 'nix develop .#ghc912' gives you GHC 9.12.${RESET}"
      ;;
    docker)
      case "$DOCKER_MODE" in
        devcontainer)
          say "  1. Open $TARGET_DIR in VSCode (with the Dev Containers extension)."
          say "  2. Accept 'Reopen in Container' when prompted."
          say "  3. In the container's terminal, run:  cabal build all"
          ;;
        codespaces)
          say "  1. Push $TARGET_DIR to a GitHub repository."
          say "  2. On GitHub: Code -> Codespaces -> Create codespace."
          say "  3. In the codespace's terminal, run:  cabal build all"
          ;;
        standalone)
          say "  cd $TARGET_DIR"
          say "  docker run -v \"\$PWD:/workspaces/my-project\" -w /workspaces/my-project \\"
          say "    -it ghcr.io/input-output-hk/devx-devcontainer:x86_64-linux.ghc96-iog"
          say "  # then, inside the container:"
          say "  cabal build all"
          ;;
      esac
      ;;
    demeter)
      say "  1. Push $TARGET_DIR to a GitHub repository."
      say "  2. Create an account at https://demeter.run and follow"
      say "     https://docs.demeter.run to open a workspace from your repository."
      say "  3. In the workspace's terminal, run:"
      say "       nix develop --accept-flake-config   ${DIM}# first run downloads the toolchain${RESET}"
      say "       cabal build all"
      ;;
    cabal)
      say "  cd $TARGET_DIR"
      say "  cabal update"
      if [ "$CRYPTO_MODE" = system ]; then
        say "  export PKG_CONFIG_PATH=\"$SYSTEM_CRYPTO_PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}\""
        say "  export PLINTH_USE_SYSTEM_CRYPTO_LIBS=1   ${DIM}# add both to your shell profile${RESET}"
      fi
      say "  cabal build all"
      if [ "$CRYPTO_MODE" = local ] || [ "$CRYPTO_MODE" = skip ]; then
        say ""
        say "  ${DIM}Run cabal from the project root. If the very first build stops once"
        say "  with \"Cannot find the program 'pkg-config'\", just re-run it — that"
        say "  happens only on the first cold build (see README).${RESET}"
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
  say "Usage: install.sh [flags]     (interactive when a terminal is available)"
  say ""
  say "  --env ENV           nix | docker | demeter | cabal"
  say "  --docker-mode MODE  codespaces | devcontainer | standalone (with --env docker)"
  say "  --crypto-libs MODE  local | system | skip                  (with --env cabal)"
  say "  --prefix DIR        prefix for --crypto-libs system (default /usr/local)"
  say "  --dir NAME          project directory to create (default: my-plinth-project)"
  say "  --repo URL          template repository (or set PLINTH_TEMPLATE_REPO)"
  say "  --branch NAME       fetch NAME instead of the repository's default branch"
  say "  --from DIR          take the template from a local directory (offline, CI)"
  say "  --yes, -y           don't ask; use defaults for unanswered questions"
  say "  --help, -h          this text"
}

main() {
  setup_colors
  REPO="${PLINTH_TEMPLATE_REPO:-$REPO_DEFAULT}"
  ENV_CHOICE=""
  DOCKER_MODE=""
  CRYPTO_MODE=""
  CRYPTO_PREFIX="/usr/local"
  SYSTEM_CRYPTO_PREFIX=""
  TARGET_DIR=""
  BRANCH_OVERRIDE=""
  FROM_DIR=""
  ASSUME_YES=0

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
      --repo) shift; REPO="${1:?--repo needs an argument}" ;;
      --repo=*) REPO="${1#--repo=}" ;;
      --branch) shift; BRANCH_OVERRIDE="${1:?--branch needs an argument}" ;;
      --branch=*) BRANCH_OVERRIDE="${1#--branch=}" ;;
      --from) shift; FROM_DIR="${1:?--from needs an argument}" ;;
      --from=*) FROM_DIR="${1#--from=}" ;;
      -y|--yes) ASSUME_YES=1 ;;
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

  setup_input
  detect_platform

  say ""
  say "${BOLD}plinth-template${RESET} — set up a new Plinth smart contract project"
  say "${DIM}Plinth is Cardano's Haskell-based smart contract language (GHC 9.6/9.12).${RESET}"
  [ "$IS_WSL" = 1 ] && say "${DIM}(WSL detected — following the Linux path.)${RESET}"

  if [ "$INTERACTIVE" = 0 ] && [ "$ASSUME_YES" = 0 ] && [ -z "$ENV_CHOICE" ]; then
    die "no terminal available for questions: pass --env (and other flags), or --yes for defaults"
  fi

  select_env
  [ -z "$ENV_CHOICE" ] && ENV_CHOICE="$(detected_default_env)"
  select_docker_mode
  [ "$ENV_CHOICE" = docker ] && [ -z "$DOCKER_MODE" ] && DOCKER_MODE=devcontainer

  explain_crypto_libs
  select_crypto_mode
  [ "$ENV_CHOICE" = cabal ] && [ -z "$CRYPTO_MODE" ] && CRYPTO_MODE=local

  say ""
  info "Checking prerequisites for the '$ENV_CHOICE' environment"
  case "$ENV_CHOICE" in
    nix)     check_nix ;;
    docker)  check_docker "$DOCKER_MODE" ;;
    demeter) check_demeter ;;
    cabal)   check_cabal_env ;;
  esac

  [ -n "$TARGET_DIR" ] || TARGET_DIR="$(ask "Project directory" "my-plinth-project")"
  TARGET_DIR="$(expand_tilde "$TARGET_DIR")"
  [ -e "$TARGET_DIR" ] && die "target directory '$TARGET_DIR' already exists; pick another name (--dir)"

  trap 'if [ -n "$SRC_CLEANUP" ]; then rm -rf "$SRC_CLEANUP"; fi' EXIT
  fetch_source
  create_project "$ENV_CHOICE" "$TARGET_DIR"
  install_crypto_libs
  next_steps
}

main "$@"
