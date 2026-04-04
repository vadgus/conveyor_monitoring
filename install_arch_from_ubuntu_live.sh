#!/usr/bin/env bash
set -euo pipefail

# === QUICK START ===
# sudo -i
# bash <(curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_ubuntu_live.sh)

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

WORKDIR="/tmp/arch-bootstrap"
PACMAN_CONF="$WORKDIR/pacman.conf"
MIRRORLIST="$WORKDIR/mirrorlist"

require_tools() {
    ${SUDO} apt update
    ${SUDO} apt install -y \
        arch-install-scripts \
        pacman-package-manager \
        gdisk parted dosfstools e2fsprogs curl
}

check_internet() {
    echo "Checking internet..."
    ping -c 1 archlinux.org >/dev/null || {
        echo "No internet"
        exit 1
    }
}

cleanup() {
    ${SUDO} umount -R /mnt 2>/dev/null || true
}

select_disk() {
    echo
    echo "Available disks:"
    echo

    mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')

    if [ "${#DISKS[@]}" -eq 0 ]; then
        echo "No disks found"
        lsblk
        exit 1
    fi

    DEFAULT=1

    for i in "${!DISKS[@]}"; do
        idx=$((i+1))
        name="${DISKS[$i]}"
        disk="/dev/$name"

        size=$(lsblk -dn -o SIZE "$disk")
        model=$(lsblk -dn -o MODEL "$disk" | xargs)
        tran=$(lsblk -dn -o TRAN "$disk")

        printf "%2d) %-14s %-8s %-6s %s\n" "$idx" "$disk" "${size:-?}" "${tran:-?}" "${model:-?}"

        if [[ "$name" == nvme* ]]; then
            DEFAULT=$idx
        fi
    done

    echo
    read -rp "Select disk [default $DEFAULT]: " CHOICE
    CHOICE="${CHOICE:-$DEFAULT}"

    DISK="/dev/${DISKS[$((CHOICE-1))]}"

    echo
    echo "Selected: $DISK"
    lsblk "$DISK"

    read -rp "Type YES to confirm wipe: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || exit 1
}

get_parts() {
    if [[ "$DISK" == *nvme* ]]; then
        EFI="${DISK}p1"
        ROOT="${DISK}p2"
    else
        EFI="${DISK}1"
        ROOT="${DISK}2"
    fi
}

partition() {
    echo "Partitioning..."
    ${SUDO} sgdisk --zap-all "$DISK"
    ${SUDO} parted -s "$DISK" mklabel gpt
    ${SUDO} parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    ${SUDO} parted -s "$DISK" set 1 esp on
    ${SUDO} parted -s "$DISK" mkpart primary ext4 513MiB 100%
    get_parts
    sleep 2
}

format() {
    echo "Formatting..."
    ${SUDO} mkfs.fat -F32 "$EFI"
    ${SUDO} mkfs.ext4 -F "$ROOT"
}

mount_fs() {
    echo "Mounting..."
    ${SUDO} mount "$ROOT" /mnt
    ${SUDO} mkdir -p /mnt/boot
    ${SUDO} mount "$EFI" /mnt/boot
}

prepare_pacman() {
    mkdir -p "$WORKDIR"
    mkdir -p /var/lib/pacman /var/cache/pacman/pkg

    cat > "$MIRRORLIST" <<EOF
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
EOF

    cat > "$PACMAN_CONF" <<EOF
[options]
Architecture = auto
SigLevel = Never
CacheDir = /var/cache/pacman/pkg/
DBPath = /var/lib/pacman/

[core]
Include = $MIRRORLIST

[extra]
Include = $MIRRORLIST
EOF
}

install_base() {
    echo "Installing base..."
    ${SUDO} pacstrap -C "$PACMAN_CONF" /mnt \
        base linux linux-firmware \
        nano networkmanager sudo grub efibootmgr archlinux-keyring

    ${SUDO} genfstab -U /mnt >> /mnt/etc/fstab
}

configure() {
    ${SUDO} arch-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

echo "127.0.0.1 localhost" > /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

pacman-key --init
pacman-key --populate archlinux

echo "Set ROOT password:"
passwd

useradd -m -G wheel $USERNAME
echo "Set password for $USERNAME:"
passwd $USERNAME

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm \
    xorg xfce4 xfce4-goodies \
    lightdm lightdm-gtk-greeter \
    firefox git htop curl

systemctl enable lightdm

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

finish() {
    echo
    echo "DONE"
    echo "Run:"
    echo "umount -R /mnt && reboot"
}

main() {
    require_tools
    check_internet
    cleanup
    select_disk
    partition
    format
    mount_fs
    prepare_pacman
    install_base
    configure
    finish
}

main
