#!/usr/bin/env bash

#######################################################
# ARCH OS RECOVERY | Automated Arch Linux Recovery TUI
#######################################################

# SOURCE:   https://github.com/murkl/arch-os-recovery
# AUTOR:    murkl
# ORIGIN:   Germany
# LICENCE:  GPL 2.0

# CONFIG
set -o pipefail # A pipeline error results in the error status of the entire pipeline
set -e          # Terminate if any command exits with a non-zero
set -E          # ERR trap inherited by shell functions (errtrace)

# ENVIRONMENT
: "${DEBUG:=false}" # DEBUG=true ./recovery.sh
: "${GUM:=./gum}"   # GUM=/usr/bin/gum ./recovery.sh

# SCRIPT
VERSION='1.0.0'

# GUM
GUM_VERSION="0.16.0"

# ENVIRONMENT

# TEMP
SCRIPT_TMP_DIR="$(mktemp -d "./.tmp.XXXXX")"

# COLORS
COLOR_BLACK=0   #  #000000
COLOR_RED=9     #  #ff0000
COLOR_GREEN=10  #  #00ff00
COLOR_YELLOW=11 #  #ffff00
COLOR_BLUE=12   #  #0000ff
COLOR_PURPLE=13 #  #ff00ff
COLOR_CYAN=14   #  #00ffff
COLOR_WHITE=15  #  #ffffff

COLOR_FOREGROUND="${COLOR_BLUE}"
COLOR_BACKGROUND="${COLOR_WHITE}"

# ////////////////////////////////////////////////////////////////////////////////////////////////////
# RECOVERY
# ////////////////////////////////////////////////////////////////////////////////////////////////////

main() {

    # Check gum binary or download
    gum_init

    # Traps (error & exit)
    trap 'trap_exit' EXIT

    gum_header "Arch OS Recovery"
    local recovery_boot_partition recovery_root_partition user_input items options
    local recovery_mount_dir="/mnt/recovery"
    local recovery_crypt_label="cryptrecovery"
    local recovery_encryption_enabled
    local recovery_encryption_password
    local mount_target

    recovery_unmount() {
        set +e
        swapoff -a &>/dev/null
        umount -A -R "$recovery_mount_dir" &>/dev/null
        umount -l -A -R "$recovery_mount_dir" &>/dev/null
        cryptsetup close "$recovery_crypt_label" &>/dev/null
        umount -A -R /mnt &>/dev/null
        umount -l -A -R /mnt &>/dev/null
        cryptsetup close cryptroot &>/dev/null
        set -e
    }

    # Select disk
    mapfile -t items < <(lsblk -I 8,259,254 -d -o KNAME,SIZE -n)
    # size: $(lsblk -d -n -o SIZE "/dev/${item}")
    options=() && for item in "${items[@]}"; do options+=("/dev/${item}"); done
    user_input=$(gum_choose --header "+ Select Arch OS Disk" "${options[@]}") || exit 130
    gum_title "Recovery"
    [ -z "$user_input" ] && gum_fail "Disk is empty" && exit 1 # Check if new value is null
    user_input=$(echo "$user_input" | awk -F' ' '{print $1}')  # Remove size from input
    [ ! -e "$user_input" ] && gum_fail "Disk does not exists" && exit 130

    [[ "$user_input" = "/dev/nvm"* ]] && recovery_boot_partition="${user_input}p1" || recovery_boot_partition="${user_input}1"
    [[ "$user_input" = "/dev/nvm"* ]] && recovery_root_partition="${user_input}p2" || recovery_root_partition="${user_input}2"

    # Check encryption
    #if lsblk -ndo FSTYPE "$recovery_root_partition" 2>/dev/null | grep -q "crypto_LUKS"; then
    if lsblk -no fstype "${recovery_root_partition}" 2>/dev/null | grep -qw crypto_LUKS || false; then
        recovery_encryption_enabled="true"
        mount_target="/dev/mapper/${recovery_crypt_label}"
        gum_warn "The disk $recovery_root_partition is encrypted with LUKS"
    else
        recovery_encryption_enabled="false"
        mount_target="$recovery_root_partition"
        gum_info "The disk $recovery_root_partition is not encrypted"
    fi

    # Check archiso
    [ "$(cat /proc/sys/kernel/hostname)" != "archiso" ] && gum_fail "You must execute the Recovery from Arch ISO!" && exit 130

    # Make sure everything is unmounted
    recovery_unmount

    # Create mount dir
    mkdir -p "$recovery_mount_dir"

    # Env
    local mount_fs_btrfs
    local mount_fs_ext4

    # ---------------------------------------------------------------------------------------

    # Mount encrypted disk
    if [ "$recovery_encryption_enabled" = "true" ]; then

        # Encryption password
        recovery_encryption_password=$(gum_input --password --header "+ Enter Encryption Password" </dev/tty) || exit 130

        # Open encrypted Disk
        echo -n "$recovery_encryption_password" | cryptsetup open "$recovery_root_partition" "$recovery_crypt_label" &>/dev/null || {
            gum_fail "Wrong encryption password"
            exit 130
        }

        mount_fs_btrfs=$(lsblk -no fstype "${mount_target}" 2>/dev/null | grep -qw btrfs && echo true || echo false)
        mount_fs_ext4=$(lsblk -no fstype "${mount_target}" 2>/dev/null | grep -qw ext4 && echo true || echo false)

        # EXT4: Mount encrypted disk
        if $mount_fs_ext4; then
            gum_info "Mounting EXT4: /root"
            mount "${mount_target}" "$recovery_mount_dir"
        fi

        # BTRFS: Mount encrypted disk
        if $mount_fs_btrfs; then
            gum_info "Mounting BTRFS: @, @home & @snapshots"
            local mount_opts="defaults,noatime,compress=zstd"
            mount --mkdir -t btrfs -o ${mount_opts},subvolid=5 "${mount_target}" "${recovery_mount_dir}"
            mount --mkdir -t btrfs -o ${mount_opts},subvol=@home "${mount_target}" "${recovery_mount_dir}/home"
            mount --mkdir -t btrfs -o ${mount_opts},subvol=@snapshots "${mount_target}" "${recovery_mount_dir}/.snapshots"
        fi

        # TODO
        if false; then
            gum_info "Mounting BTRFS: @, @home & @snapshots"
            mount "$recovery_root_partition" "$recovery_mount_dir"
        fi

    else

        # ---------------------------------------------------------------------------------------

        mount_fs_btrfs=$(lsblk -no fstype "${mount_target}" 2>/dev/null | grep -qw btrfs && echo true || echo false)
        mount_fs_ext4=$(lsblk -no fstype "${mount_target}" 2>/dev/null | grep -qw ext4 && echo true || echo false)

        # EXT4: Mount unencrypted disk
        if $mount_fs_ext4; then
            gum_info "Mounting EXT4: /root"
            mount "$recovery_root_partition" "$recovery_mount_dir"
        fi

        # BTRFS: Mount unencrypted disk
        if $mount_fs_btrfs; then
            gum_info "Mounting BTRFS: @, @home & @snapshots"
            local mount_opts="defaults,noatime,compress=zstd"
            mount --mkdir -t btrfs -o ${mount_opts},subvolid=5 "${mount_target}" "${recovery_mount_dir}"
            mount --mkdir -t btrfs -o ${mount_opts},subvol=@home "${mount_target}" "${recovery_mount_dir}/home"
            mount --mkdir -t btrfs -o ${mount_opts},subvol=@snapshots "${mount_target}" "${recovery_mount_dir}/.snapshots"
        fi

        # TODO
        if false; then
            gum_info "Mounting BTRFS: @, @home & @snapshots"
            mount "$recovery_root_partition" "$recovery_mount_dir"
        fi
    fi

    # Check if ext4 OR btrfs found
    if ! $mount_fs_btrfs && ! $mount_fs_ext4; then
        gum_fail "ERROR: Filesystem not found. Only BTRFS & EXT4 supported."
        exit 130
    fi

    # Check if ext4 AND btrfs found
    if $mount_fs_btrfs && $mount_fs_ext4; then
        gum_fail "ERROR: BTRFS and EXT4 are found at the same device."
        exit 130
    fi

    # Mount boot
    gum_info "Mounting EFI: /boot"
    mkdir -p "$recovery_mount_dir/boot"
    mount "$recovery_boot_partition" "${recovery_mount_dir}/boot"

    # Chroot (ext4)
    if $mount_fs_ext4; then
        gum_green "!! YOUR ARE NOW ON YOUR RECOVERY SYSTEM !!"
        gum_yellow ">> Leave with command 'exit'"
        arch-chroot "$recovery_mount_dir" </dev/tty
        wait && recovery_unmount
        gum_green ">> Exit Recovery"
    fi

    # ---------------------------------------------------------------------------------------

    # BTRFS Rollback
    if $mount_fs_btrfs; then

        # Input & info
        echo && gum_title "BTRFS Rollback"
        local snapshots snapshot_input
        #snapshots=$(btrfs subvolume list "$recovery_mount_dir" | awk '$NF ~ /^@snapshots\/[0-9]+\/snapshot$/ {print $NF}')
        snapshots=$(btrfs subvolume list -o "${recovery_mount_dir}/.snapshots" | awk '{print $NF}')
        [ -z "$snapshots" ] && gum_fail "No Snapshot found in @snapshots" && exit 130
        snapshot_input=$(echo "$snapshots" | gum_filter --reverse --header "+ Select Snapshot") || exit 130
        gum_info "Snapshot: ${snapshot_input}"
        gum_confirm "Confirm Rollback @ to ${snapshot_input}?" || exit 130

        # Rollback
        btrfs subvolume delete --recursive "${recovery_mount_dir}/@"
        btrfs subvolume snapshot "${recovery_mount_dir}/${snapshot_input}" "${recovery_mount_dir}/@"

        # Mount new root & boot
        gum_info "Mounting BTRFS Snapshot"
        local mount_opts="defaults,noatime,compress=zstd"
        swapoff -a &>/dev/null
        umount -A -R "$recovery_mount_dir" &>/dev/null
        #mount --mkdir -t btrfs -o ${mount_opts},subvolid=5 "${mount_target}" "${recovery_mount_dir}"
        mount --mkdir -t btrfs -o ${mount_opts},subvol=@ "${mount_target}" "${recovery_mount_dir}"

        #fsck.vfat -v -a "$recovery_boot_partition" || true
        mount --mkdir "$recovery_boot_partition" "${recovery_mount_dir}/boot"

        # Remove pacman lock
        gum_info "Remove Pacman Lock"
        rm -f "${recovery_mount_dir}/var/lib/pacman/db.lck"

        # Rebuild kernel image for /boot
        if gum_confirm "Rebuild Kernel?"; then
            local kernel_version_dir kernel_version kernel_type kernel_pkg_files pkg_file
            for kernel_version_dir in "${recovery_mount_dir}/lib/modules/"*; do
                [ -d "$kernel_version_dir" ] || continue
                kernel_version=$(basename "$kernel_version_dir")

                # Supported kernel list
                if [[ "$kernel_version" == *zen* ]]; then
                    kernel_type="linux-zen"
                elif [[ "$kernel_version" == *lts* ]]; then
                    kernel_type="linux-lts"
                elif [[ "$kernel_version" == *hardened* ]]; then
                    kernel_type="linux-hardened"
                else
                    kernel_type="linux"
                fi

                gum_info "Restoring kernel image (${kernel_type}) for ${kernel_version} from package"

                # Find kernel package in cache (glob expansion safely)
                shopt -s nullglob
                kernel_pkg_files=("${recovery_mount_dir}/var/cache/pacman/pkg/${kernel_type}-"*"${kernel_version%%-*}"*.pkg.tar.*)
                shopt -u nullglob

                # Extract image
                if [ "${#kernel_pkg_files[@]}" -gt 0 ]; then
                    pkg_file="${kernel_pkg_files[0]}"
                    # Extract kernel image from package
                    bsdtar -xOf "$pkg_file" "usr/lib/modules/${kernel_version}/vmlinuz" > "${recovery_mount_dir}/boot/vmlinuz-${kernel_type}"
                    gum_info "Kernel image ${kernel_type} extracted"
                else
                    gum_fail "No matching kernel package for ${kernel_type} and version ${kernel_version} found in cache!"
                    exit 1
                fi

                # Build initramfs
                arch-chroot "${recovery_mount_dir}" mkinitcpio -c /etc/mkinitcpio.conf -k "${kernel_version}" -g "/boot/initramfs-${kernel_type}.img"
                arch-chroot "${recovery_mount_dir}" mkinitcpio -c /etc/mkinitcpio.conf -k "${kernel_version}" -g "/boot/initramfs-${kernel_type}-fallback.img" -S autodetect
            done

            # Update Grub
            if [ -d "${recovery_mount_dir}/boot/grub" ] && [ -f "${recovery_mount_dir}/boot/grub/grub.cfg" ]; then
                gum_info "Rebuilding Grub config"
                arch-chroot "${recovery_mount_dir}" grub-mkconfig -o /boot/grub/grub.cfg
            fi
        fi

        # Finish
        gum_info "Snapshot ${snapshot_input} is set to @ after next reboot"
        echo && gum_green "Rollback successfully finished"
        echo && gum_confirm "Unmount ${recovery_mount_dir}?" && recovery_unmount
    fi
}

# ////////////////////////////////////////////////////////////////////////////////////////////////////
# TRAPS
# ////////////////////////////////////////////////////////////////////////////////////////////////////

trap_exit() {
    local result_code="$?"
    rm -rf "$SCRIPT_TMP_DIR"
    exit "$result_code"
}

# ////////////////////////////////////////////////////////////////////////////////////////////////////
# GUM
# ////////////////////////////////////////////////////////////////////////////////////////////////////

gum_init() {
    if [ ! -x ./gum ]; then
        clear && echo "Loading Arch OS Recovery..." # Loading
        local gum_url gum_path                      # Prepare URL with version os and arch
        # https://github.com/charmbracelet/gum/releases
        gum_url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_$(uname -s)_$(uname -m).tar.gz"
        if ! curl -Lsf "$gum_url" >"${SCRIPT_TMP_DIR}/gum.tar.gz"; then echo "Error downloading ${gum_url}" && exit 1; fi
        if ! tar -xf "${SCRIPT_TMP_DIR}/gum.tar.gz" --directory "$SCRIPT_TMP_DIR"; then echo "Error extracting ${SCRIPT_TMP_DIR}/gum.tar.gz" && exit 1; fi
        gum_path=$(find "${SCRIPT_TMP_DIR}" -type f -executable -name "gum" -print -quit)
        [ -z "$gum_path" ] && echo "Error: 'gum' binary not found in '${SCRIPT_TMP_DIR}'" && exit 1
        if ! mv "$gum_path" ./gum; then echo "Error moving ${gum_path} to ./gum" && exit 1; fi
        if ! chmod +x ./gum; then echo "Error chmod +x ./gum" && exit 1; fi
    fi
}

gum() {
    if [ -n "$GUM" ] && [ -x "$GUM" ]; then
        "$GUM" "$@"
    else
        echo "Error: GUM='${GUM}' is not found or executable" >&2
        exit 1
    fi
}

# ////////////////////////////////////////////////////////////////////////////////////////////////////
# WRAPPER
# ////////////////////////////////////////////////////////////////////////////////////////////////////

gum_header() {
    local title="$1"
    clear && gum_foreground '
 █████  ██████   ██████ ██   ██      ██████  ███████ 
██   ██ ██   ██ ██      ██   ██     ██    ██ ██      
███████ ██████  ██      ███████     ██    ██ ███████ 
██   ██ ██   ██ ██      ██   ██     ██    ██      ██ 
██   ██ ██   ██  ██████ ██   ██      ██████  ███████'
    local header_version="               v. ${VERSION}"
    [ "$DEBUG" = "true" ] && header_version="               d. ${VERSION}"
    gum_white --margin "1 0" --align left --bold "Welcome to ${title} ${header_version}"
    return 0
}

# Gum colors (https://github.com/muesli/termenv?tab=readme-ov-file#color-chart)
gum_foreground() { gum_style --foreground "$COLOR_FOREGROUND" "${@}"; }
gum_background() { gum_style --foreground "$COLOR_BACKGROUND" "${@}"; }
gum_white() { gum_style --foreground "$COLOR_WHITE" "${@}"; }
gum_black() { gum_style --foreground "$COLOR_BLACK" "${@}"; }
gum_red() { gum_style --foreground "$COLOR_RED" "${@}"; }
gum_green() { gum_style --foreground "$COLOR_GREEN" "${@}"; }
gum_blue() { gum_style --foreground "$COLOR_BLUE" "${@}"; }
gum_yellow() { gum_style --foreground "$COLOR_YELLOW" "${@}"; }
gum_cyan() { gum_style --foreground "$COLOR_CYAN" "${@}"; }
gum_purple() { gum_style --foreground "$COLOR_PURPLE" "${@}"; }

# Gum prints
gum_title() { gum join "$(gum_foreground --bold "+ ")" "$(gum_foreground --bold "${*}")"; }
gum_info() { gum join "$(gum_green --bold "• ")" "$(gum_white "${*}")"; }
gum_warn() { gum join "$(gum_yellow --bold "• ")" "$(gum_white "${*}")"; }
gum_fail() { gum join "$(gum_red --bold "• ")" "$(gum_white "${*}")"; }

# Gum wrapper
gum_style() { gum style "${@}"; }
gum_confirm() { gum confirm --prompt.foreground "$COLOR_FOREGROUND" --selected.background "$COLOR_FOREGROUND" --selected.foreground "$COLOR_BACKGROUND" --unselected.foreground "$COLOR_FOREGROUND" "${@}"; }
gum_input() { gum input --placeholder "..." --prompt "> " --cursor.foreground "$COLOR_FOREGROUND" --prompt.foreground "$COLOR_FOREGROUND" --header.foreground "$COLOR_FOREGROUND" "${@}"; }
gum_choose() { gum choose --cursor "> " --header.foreground "$COLOR_FOREGROUND" --cursor.foreground "$COLOR_FOREGROUND" "${@}"; }
gum_filter() { gum filter --prompt "> " --indicator ">" --placeholder "Type to filter..." --height 8 --header.foreground "$COLOR_FOREGROUND" --indicator.foreground "$COLOR_FOREGROUND" --match.foreground "$COLOR_FOREGROUND" "${@}"; }
gum_write() { gum write --prompt "> " --show-cursor-line --char-limit 0 --cursor.foreground "$COLOR_FOREGROUND" --header.foreground "$COLOR_FOREGROUND" "${@}"; }
gum_spin() { gum spin --spinner line --title.foreground "$COLOR_FOREGROUND" --spinner.foreground "$COLOR_FOREGROUND" "${@}"; }

# ////////////////////////////////////////////////////////////////////////////////////////////////////
# START MAIN
# ////////////////////////////////////////////////////////////////////////////////////////////////////

main "$@"
