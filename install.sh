#!/usr/bin/env bash
#
# install.sh: sets up the Hyprland dotfiles from this repo, plus the stuff
# around them (packages, greetd/gtkgreet, services).
#
# Works on Fedora (see TESTED_FEDORA_VERSIONS). On Arch it only copies the
# files, no packages and no services yet, proper support is coming later.
#
# Usage: ./install.sh [-y|--yes] [-n|--dry-run] [--no-apps]
#                     [--wallpaper PATH] [--no-wallpaper] [-h|--help]
#
# Expected repo layout:
#   home/lvkaszus/  -> $HOME
#   etc/            -> /etc   (sudo)
#   usr/            -> /usr   (sudo)
#   packages/<distro>.txt       core packages, one per line
#   packages/<distro>-apps.txt  optional apps, the script asks first

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_SRC="$REPO_DIR/home/lvkaszus"
# overridable for testing
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
OSTREE_MARKER="${OSTREE_MARKER:-/run/ostree-booted}"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
# Target wallpaper path: <Pictures dir>/Wallpaper.jpg, Pictures dir comes from
# xdg-user-dirs. hyprpaper and hyprlock read it and it also gets copied to the
# greetd background. Set in resolve_wallpaper_target.
WALLPAPER=""
WALLPAPER_TILDE=""   # same path, with a leading ~ if possible
WALLPAPER_MOVED=0    # 1 if it's not ~/Pictures/Wallpaper.jpg
# Where the wallpaper comes from: --wallpaper, the prompt, or $WALLPAPER
WALLPAPER_SRC=""
SKIP_WALLPAPER=0
# Fedora versions I ran this on. Add a version after a successful run, any
# other one just gets a warning.
TESTED_FEDORA_VERSIONS=(44)

# Home path hardcoded in some configs (Qt's color_scheme_path doesn't expand
# $HOME or ~), gets swapped for the current $HOME when deploying
REPO_HOME_PATH=/home/lvkaszus
# Wallpaper path as it's written in the configs (hyprpaper, hyprlock)
# shellcheck disable=SC2088
REPO_WALLPAPER_TILDE="~/Pictures/Wallpaper.jpg"
REPO_WALLPAPER_ABS="$REPO_HOME_PATH/Pictures/Wallpaper.jpg"

# User units to enable. No --now, some need a graphical session, so they just
# start after reboot.
USER_UNITS=(
    hyprpolkitagent.service
    hypridle.service
    pipewire.service
    wireplumber.service
    pipewire-pulse.socket
    gnome-keyring-daemon.socket
    gnome-keyring-daemon.service
)

ASSUME_YES=0
DRY_RUN=0
FILES_ONLY=0
# optional apps: 1 = yes, 0 = no, empty = ask (--no-apps sets 0)
INSTALL_APPS=""
BACKED_UP=0
TMP_PATHS=()
DISTRO=""
OS_NAME=""
OS_VERSION=""

# ---------------------------------------------------------------- helpers ---

if [[ -t 1 ]]; then
    C_BLUE=$'\e[1;34m' C_YELLOW=$'\e[1;33m' C_RED=$'\e[1;31m' C_OFF=$'\e[0m'
else
    C_BLUE='' C_YELLOW='' C_RED='' C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

cleanup() {
    if (( ${#TMP_PATHS[@]} )); then
        rm -rf "${TMP_PATHS[@]}"
    fi
}

# run a command, or just print it with --dry-run
run() {
    if (( DRY_RUN )); then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  -y, --yes       do not ask for confirmation
  -n, --dry-run   print what would be done without changing anything
      --no-apps   skip the optional apps (packages/<distro>-apps.txt)
      --wallpaper PATH  use this wallpaper file instead of asking (--wallpaper=PATH works too)
      --no-wallpaper    do not install any wallpaper
  -h, --help      show this help
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            -y|--yes)         ASSUME_YES=1 ;;
            -n|--dry-run)     DRY_RUN=1 ;;
            --no-apps)        INSTALL_APPS=0 ;;
            --no-wallpaper)   SKIP_WALLPAPER=1 ;;
            --wallpaper)
                [[ $# -ge 2 ]] || die "--wallpaper needs a path"
                WALLPAPER_SRC=$2
                shift
                ;;
            --wallpaper=*)    WALLPAPER_SRC=${1#--wallpaper=} ;;
            -h|--help)        usage; exit 0 ;;
            *)                usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done
}

# --------------------------------------------------------------- checks ---

detect_distro() {
    [[ -r $OS_RELEASE ]] || die "Cannot read $OS_RELEASE"

    local ID="" ID_LIKE="" VERSION_ID="" PRETTY_NAME=""
    # shellcheck disable=SC1090
    . "$OS_RELEASE"
    OS_NAME=${PRETTY_NAME:-$ID}
    OS_VERSION=${VERSION_ID:-}

    case " $ID $ID_LIKE " in
        *" arch "*)
            DISTRO=arch
            FILES_ONLY=1
            warn "Arch Linux support is planned, but it is not complete yet."
            warn "Only the config files will be copied: no packages are installed and"
            warn "no services are enabled. There is no guarantee that everything will work."
            return 0
            ;;
    esac

    [[ $ID == fedora ]] || die "Unsupported distribution: $OS_NAME. Only Fedora is supported for now."
    if [[ -e $OSTREE_MARKER ]]; then
        die "Atomic Fedora variants (Silverblue, Kinoite, ...) are not supported: dnf cannot install packages there."
    fi
    DISTRO=fedora

    local tested=0 v
    for v in "${TESTED_FEDORA_VERSIONS[@]}"; do
        if [[ $OS_VERSION == "$v" ]]; then
            tested=1
        fi
    done
    if (( ! tested )); then
        warn "Tested on Fedora ${TESTED_FEDORA_VERSIONS[*]}, you are on $OS_NAME. Some steps may fail."
    fi
}

check_repo() {
    local path
    local -a required=("$HOME_SRC" "$REPO_DIR/etc/greetd" "$REPO_DIR/usr")
    if (( ! FILES_ONLY )); then
        required+=("$REPO_DIR/packages/$DISTRO.txt" "$REPO_DIR/packages/$DISTRO-apps.txt")
    fi
    for path in "${required[@]}"; do
        [[ -e $path ]] || die "Missing from the repo: ${path#"$REPO_DIR"/}"
    done
}

confirm() {
    if (( ASSUME_YES || DRY_RUN )); then
        return 0
    fi
    if (( FILES_ONLY )); then
        cat <<EOF
Detected: $OS_NAME (files only)

This will:
  1. copy the dotfiles to $HOME (files that get replaced are backed up first)
  2. install the greetd/gtkgreet files to /etc and /usr (uses sudo)

It will NOT install packages or enable any services.
EOF
    else
        cat <<EOF
Detected: $OS_NAME

This will:
  1. install the packages from packages/$DISTRO.txt (optional apps: asked next)
  2. copy the dotfiles to $HOME (files that get replaced are backed up first)
  3. install the greetd/gtkgreet files to /etc and /usr (uses sudo)
  4. install the Tela icon theme for your user
  5. enable greetd and the user services
EOF
    fi
    local answer
    read -r -p "Continue? [y/N] " answer || die "No input. Use -y for non-interactive runs."
    [[ $answer =~ ^[Yy]$ ]] || die "Aborted."
}

# ------------------------------------------------------------- packages ---

# print package names from a list, skipping comments and empty lines
read_packages() {
    awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if (length) print }' "$1"
}

choose_apps() {
    if [[ -n $INSTALL_APPS ]]; then
        return 0
    fi
    if (( ASSUME_YES || DRY_RUN )); then
        INSTALL_APPS=1
        return 0
    fi

    local list answer
    list=$(read_packages "$REPO_DIR/packages/$DISTRO-apps.txt" | tr '\n' ' ')
    printf 'Optional apps: %s\n' "$list"
    read -r -p "Install them too? Without them you still get the terminal (kitty). [Y/n] " answer || answer=""
    if [[ $answer =~ ^[Nn]$ ]]; then
        INSTALL_APPS=0
    else
        INSTALL_APPS=1
    fi
}

choose_wallpaper() {
    if (( SKIP_WALLPAPER )) || [[ -n $WALLPAPER_SRC ]]; then
        return 0
    fi
    if (( ASSUME_YES || DRY_RUN )); then
        WALLPAPER_SRC=$WALLPAPER
        return 0
    fi

    local answer
    read -e -r -p "Wallpaper file [$WALLPAPER]: " answer || answer=""
    answer=${answer/#\~/$HOME}
    WALLPAPER_SRC=${answer:-$WALLPAPER}
}

fedora_install_packages() {
    info "Enabling the lionheartp/Hyprland COPR (third-party repo)"
    run sudo dnf copr enable -y lionheartp/Hyprland \
        || die "Could not enable the COPR. Is the dnf5-plugins package installed?"

    local -a pkgs
    mapfile -t pkgs < <(read_packages "$REPO_DIR/packages/fedora.txt")
    if (( INSTALL_APPS )); then
        mapfile -t -O "${#pkgs[@]}" pkgs < <(read_packages "$REPO_DIR/packages/fedora-apps.txt")
    fi
    info "Installing ${#pkgs[@]} packages"
    run sudo dnf install -y "${pkgs[@]}"
}

post_package_setup() {
    info "Creating user directories and refreshing the font cache"
    run xdg-user-dirs-update
    run fc-cache -f
}

# ---------------------------------------------------------------- files ---

backup_file() {
    local dest=$1
    info "Backing up existing $dest"
    run mkdir -p "$BACKUP_DIR"
    # --parents keeps the full original path inside the backup dir
    run cp -a --parents "$dest" "$BACKUP_DIR" || warn "Could not back up $dest"
    BACKED_UP=1
}

# install one file: deploy_file <src> <dest> <mode> [--root]
deploy_file() {
    local src=$1 dest=$2 mode=$3 use_sudo=${4:-}
    local -a pre=()
    if [[ $use_sudo == --root ]]; then
        pre=(sudo)
    fi

    if [[ -e $dest || -L $dest ]] && ! cmp -s "$src" "$dest"; then
        backup_file "$dest"
    fi
    run "${pre[@]}" install -D -m "$mode" "$src" "$dest"
}

# print the Pictures dir (~/Obrazy on a Polish system). Uses xdg-user-dir, or
# reads ~/.config/user-dirs.dirs if it's not installed yet, falls back to
# ~/Pictures.
detect_pictures_dir() {
    local dir="" line=""
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
    if command -v xdg-user-dir >/dev/null 2>&1; then
        dir=$(xdg-user-dir PICTURES 2>/dev/null) || dir=""
    elif [[ -r $cfg ]]; then
        line=$(grep -E '^XDG_PICTURES_DIR=' "$cfg" | tail -n 1) || line=""
        dir=${line#*=}
        dir=${dir//\"/}
        dir=${dir/#\$HOME/$HOME}
    fi
    # xdg-user-dir returns $HOME when the dir isn't configured
    if [[ -z $dir || ${dir%/} == "$HOME" ]]; then
        dir=$HOME/Pictures
    fi
    printf '%s\n' "${dir%/}"
}

resolve_wallpaper_target() {
    WALLPAPER="$(detect_pictures_dir)/Wallpaper.jpg"
    WALLPAPER_TILDE=$WALLPAPER
    if [[ $WALLPAPER == "$HOME"/* ]]; then
        # literal ~ on purpose, this goes into config files
        # shellcheck disable=SC2088
        WALLPAPER_TILDE="~/${WALLPAPER#"$HOME"/}"
    fi
    WALLPAPER_MOVED=0
    if [[ $WALLPAPER != "$HOME/Pictures/Wallpaper.jpg" ]]; then
        WALLPAPER_MOVED=1
    fi
}

needs_rewrite() {
    local file=$1
    if [[ $HOME != "$REPO_HOME_PATH" ]] && grep -qIF "$REPO_HOME_PATH" "$file"; then
        return 0
    fi
    if (( WALLPAPER_MOVED )) && grep -qIF -e "$REPO_WALLPAPER_TILDE" -e "$REPO_WALLPAPER_ABS" "$file"; then
        return 0
    fi
    return 1
}

# copy <src> to <dst> and fix the repo's paths on the way: wallpaper (if
# Pictures isn't ~/Pictures) and home
rewrite_paths() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        if (( WALLPAPER_MOVED )); then
            line=${line//"$REPO_WALLPAPER_ABS"/"$WALLPAPER"}
            line=${line//"$REPO_WALLPAPER_TILDE"/"$WALLPAPER_TILDE"}
        fi
        printf '%s\n' "${line//"$REPO_HOME_PATH"/"$HOME"}"
    done < "$1" > "$2"
}

# install everything from <src_root> into <dest_root>, same layout. Mode is 755
# if the file is executable in the repo, 644 otherwise. Files with hardcoded
# paths go through rewrite_paths first.
# deploy_tree <src_root> <dest_root> [--root]
deploy_tree() {
    local src_root=$1 dest_root=$2 use_sudo=${3:-} src file mode tmp
    while IFS= read -r -d '' src; do
        mode=644
        if [[ -x $src ]]; then
            mode=755
        fi

        file=$src
        tmp=""
        if needs_rewrite "$src"; then
            info "Rewriting paths in ${src#"$REPO_DIR"/}"
            tmp=$(mktemp)
            TMP_PATHS+=("$tmp")
            rewrite_paths "$src" "$tmp"
            file=$tmp
        fi

        deploy_file "$file" "$dest_root/${src#"$src_root"/}" "$mode" "$use_sudo"
        if [[ -n $tmp ]]; then
            rm -f "$tmp"
        fi
    done < <(find "$src_root" -type f -print0 | sort -z)
}

deploy_wallpaper() {
    if (( SKIP_WALLPAPER )); then
        info "Skipping the wallpaper"
        return 0
    fi
    if [[ ! -f $WALLPAPER_SRC ]]; then
        warn "Wallpaper not found: $WALLPAPER_SRC"
        warn "hyprpaper/hyprlock expect $WALLPAPER and the greetd background"
        warn "is copied from it. Re-run with --wallpaper PATH, or place the files yourself."
        return 0
    fi

    case ${WALLPAPER_SRC,,} in
        *.jpg|*.jpeg) ;;
        *) warn "$WALLPAPER_SRC is not a .jpg, but the configs expect $WALLPAPER. Copying it under that name anyway." ;;
    esac

    # hyprpaper and hyprlock read $WALLPAPER, so the file has to end up there
    if [[ ! $WALLPAPER_SRC -ef $WALLPAPER ]]; then
        deploy_file "$WALLPAPER_SRC" "$WALLPAPER" 644
    fi
    deploy_file "$WALLPAPER_SRC" /etc/greetd/gtkgreet-background.jpg 644 --root
}

fix_selinux_labels() {
    if command -v restorecon >/dev/null 2>&1; then
        info "Restoring SELinux labels"
        run sudo restorecon -R /etc/greetd /usr/share/locale/pl
    fi
}

install_tela() {
    if [[ -d $HOME/.local/share/icons/Tela ]]; then
        info "Tela icon theme already installed, skipping"
        return 0
    fi

    info "Installing the Tela icon theme"
    local tmp
    tmp=$(mktemp -d)
    TMP_PATHS+=("$tmp")
    if run git clone --depth 1 https://github.com/vinceliuice/Tela-icon-theme "$tmp/Tela-icon-theme" \
        && run bash -c 'cd "$1" && ./install.sh standard' _ "$tmp/Tela-icon-theme"; then
        :
    else
        warn "Tela icon theme installation failed, continuing without it"
    fi
    rm -rf "$tmp"
}

# ------------------------------------------------------------- services ---

enable_services() {
    info "Enabling greetd and booting to the graphical target"
    # --force overwrites the existing display-manager.service link (gdm etc.)
    run sudo systemctl enable --force greetd
    run sudo systemctl set-default graphical.target

    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "No systemd user session found, skipping user services."
        warn "After logging in, run:"
        printf '  systemctl --user enable %s\n' "${USER_UNITS[*]}" >&2
        return 0
    fi

    info "Enabling user services"
    local unit
    for unit in "${USER_UNITS[@]}"; do
        if ! run systemctl --user enable "$unit"; then
            warn "Could not enable user unit: $unit"
        fi
    done
}

# ----------------------------------------------------------------- main ---

print_manual_steps() {
    cat <<'EOF'

Files-only mode: nothing else was done. Still to do by hand:
  - install the packages (packages/fedora.txt shows what this setup uses)
  - sudo systemctl enable --force greetd
  - enable the user services:
EOF
    printf '      systemctl --user enable %s\n' "${USER_UNITS[*]}"
    echo "  - install the Tela icon theme"
}

main() {
    trap cleanup EXIT
    parse_args "$@"
    # the shell doesn't expand ~ in --wallpaper=~/x
    WALLPAPER_SRC=${WALLPAPER_SRC/#\~/$HOME}

    if [[ $EUID -eq 0 ]]; then
        die "Do not run this as root. It uses sudo where needed."
    fi

    detect_distro
    check_repo
    confirm

    resolve_wallpaper_target
    choose_wallpaper
    if (( ! FILES_ONLY )); then
        choose_apps
    fi

    if (( DRY_RUN )); then
        info "Dry run: nothing will be changed"
    else
        sudo -v
    fi

    if (( ! FILES_ONLY )); then
        "${DISTRO}_install_packages"
        post_package_setup
    fi

    # xdg-user-dirs-update could have just created the localized dirs
    resolve_wallpaper_target

    info "Copying dotfiles to $HOME"
    deploy_tree "$HOME_SRC" "$HOME"

    info "Installing greetd/gtkgreet files"
    deploy_tree "$REPO_DIR/etc" /etc --root
    deploy_tree "$REPO_DIR/usr" /usr --root
    deploy_wallpaper
    fix_selinux_labels

    if (( ! FILES_ONLY )); then
        install_tela
        enable_services
    fi

    info "Done."
    if (( ! FILES_ONLY && ! INSTALL_APPS )); then
        info "Optional apps were skipped. Install them later with:"
        # only Fedora has a package list for now
        printf '  sudo dnf install %s\n' "$(read_packages "$REPO_DIR/packages/$DISTRO-apps.txt" | tr '\n' ' ')"
    fi
    if (( BACKED_UP )); then
        info "Replaced files were backed up to $BACKUP_DIR"
    fi
    if (( FILES_ONLY )); then
        print_manual_steps
    else
        cat <<'EOF'

Reboot now so greetd and the gnome-keyring socket start from a clean session.
Log in through gtkgreet and type your password: that is what creates and
unlocks the login keyring (Thunar then remembers saved passwords).
EOF
    fi
}

# run main only when executed, so the file can be sourced for testing
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
