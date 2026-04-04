#!/usr/bin/env bash
set -euo pipefail

# === QUICK START ===
# sudo -i
# bash <(curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_ubuntu_live.sh)

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"

log() {
    printf "\n==> %s\n" "$1"
}

die() {
    printf "\nERROR: %s\n" "$1" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

install_tools() {
    log "Installing required tools"
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y \
        arch-install-scripts \
        pacman-package-manager \
        gdisk \
        parted \
        dosfstools \
        e2fsprogs \
        curl \
        util-linux
}

check_internet() {
    log "Checking internet"
    ping -c 1 archlinux.org >/dev/null 2>&1 || die "Internet connection is required"
}

cleanup_mounts() {
    umount -R /mnt 2>/dev/null || true
}

list_disks() {
    local dev
    for dev in /sys/block/*; do
        dev="$(basename "$dev")"
        case "$dev" in
            loop*|ram*|zram*|sr*|md*|dm-*)
                continue
                ;;
        esac
        [[ -b "/dev/$dev" ]] && echo "/dev/$dev"
    done
}

pick_disk() {
    log "Available disks"

    mapfile -t DISKS < <(list_disks)
    [[ ${#DISKS[@]} -gt 0 ]] || die "No disks found"

    local default_index=1
    local i disk name size model tran

    for i in "${!DISKS[@]}"; do
        disk="${DISKS[$i]}"
        name="$(basename "$disk")"
        size="$(lsblk -dn -o SIZE "$disk" 2>/dev/null | xargs || true)"
        model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null | xargs || true)"
        tran="$(lsblk -dn -o TRAN "$disk" 2>/dev/null | xargs || true)"

        printf "%2d) %-14s %-8s %-6s %s\n" \
            "$((i + 1))" "$disk" "${size:-?}" "${tran:-?}" "${model:-?}"

        if [[ "$name" == nvme* ]]; then
            default_index=$((i + 1))
        fi
    done

    echo
    read -r -p "Select disk number [default ${default_index}]: " choice
    choice="${choice:-$default_index}"

    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid disk selection"
    (( choice >= 1 && choice <= ${#DISKS[@]} )) || die "Disk number out of range"

    DISK="${DISKS[$((choice - 1))]}"

    echo
    echo "Selected disk: $DISK"
    lsblk "$DISK" || true
    echo
    read -r -p "ALL DATA ON $DISK WILL BE DESTROYED. Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || die "Cancelled"
}

make_partitions() {
    log "Partitioning $DISK"

    sgdisk --zap-all "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%

    if [[ "$DISK" == *nvme* ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi

    sleep 2
    [[ -b "$EFI_PART" ]] || die "EFI partition not found: $EFI_PART"
    [[ -b "$ROOT_PART" ]] || die "Root partition not found: $ROOT_PART"
}

format_partitions() {
    log "Formatting partitions"
    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
}

mount_partitions() {
    log "Mounting partitions"
    mkdir -p /mnt
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
}

prepare_pacstrap_config() {
    log "Preparing pacstrap config"
    mkdir -p /tmp/arch-bootstrap
    mkdir -p /var/lib/pacman /var/cache/pacman/pkg

    cat > /tmp/arch-bootstrap/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

    cat > /tmp/arch-bootstrap/pacman.conf <<'EOF'
[options]
Architecture = auto
CheckSpace
SigLevel = Never
LocalFileSigLevel = Never
ParallelDownloads = 5
CacheDir = /var/cache/pacman/pkg/
DBPath = /var/lib/pacman/

[core]
Include = /tmp/arch-bootstrap/mirrorlist

[extra]
Include = /tmp/arch-bootstrap/mirrorlist
EOF
}

run_pacstrap() {
    log "Installing Arch base system"
    pacstrap -C /tmp/arch-bootstrap/pacman.conf /mnt \
        base linux linux-firmware sudo nano networkmanager grub efibootmgr archlinux-keyring

    [[ -x /mnt/bin/bash ]] || die "pacstrap finished, but /mnt/bin/bash is missing. Base system was not installed correctly."

    genfstab -U /mnt >> /mnt/etc/fstab
}

prepare_installed_arch() {
    log "Preparing pacman mirrors inside installed Arch"

    mkdir -p /mnt/etc/pacman.d
    cat > /mnt/etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

    cat > /mnt/etc/vconsole.conf <<'EOF'
KEYMAP=us
EOF
}

configure_inside_chroot() {
    [[ -x /mnt/bin/bash ]] || die "/mnt/bin/bash is missing before chroot"

    log "Configuring installed system"
    arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

grep -q '^$LOCALE UTF-8$' /etc/locale.gen || echo '$LOCALE UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=$LOCALE' > /etc/locale.conf

echo '$HOSTNAME' > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm archlinux-keyring

echo
echo 'Set ROOT password:'
until passwd; do
    echo 'Passwords did not match. Try again.'
done

if ! id -u '$USERNAME' >/dev/null 2>&1; then
    useradd -m -G wheel '$USERNAME'
fi

echo
echo 'Set password for $USERNAME:'
until passwd '$USERNAME'; do
    echo 'Passwords did not match. Try again.'
done

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm \
    xorg \
    xfce4 \
    xfce4-goodies \
    lightdm \
    lightdm-gtk-greeter \
    firefox \
    git \
    htop \
    curl

systemctl enable lightdm

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

finish() {
    log "Installation complete"
    echo "Run:"
    echo "umount -R /mnt"
    echo "reboot"
}

main() {
    need_cmd apt
    need_cmd lsblk
    need_cmd parted
    need_cmd sgdisk
    need_cmd mkfs.fat
    need_cmd mkfs.ext4

    install_tools
    check_internet
    cleanup_mounts
    pick_disk
    make_partitions
    format_partitions
    mount_partitions
    prepare_pacstrap_config
    run_pacstrap
    prepare_installed_arch
    configure_inside_chroot
    finish
}

main "$@"
