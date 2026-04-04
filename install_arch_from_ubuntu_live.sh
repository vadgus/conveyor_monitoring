#!/usr/bin/env bash
set -euo pipefail

# curl -O https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_ubuntu_live.sh
# chmod +x install_arch_from_ubuntu_live.sh
# ./install_arch_from_ubuntu_live.sh

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"

require_root_tools() {
    sudo -v
    sudo apt update
    sudo apt install -y arch-install-scripts gdisk parted dosfstools e2fsprogs pacman-package-manager
}

print_disks() {
    echo
    echo "Available disks:"
    lsblk -d -e 7,11 -o NAME,SIZE,MODEL,TYPE
    echo
}

select_disk() {
    print_disks
    read -r -p "Enter target disk (example: /dev/nvme0n1 or /dev/sda): " DISK

    if [[ ! -b "${DISK:-}" ]]; then
        echo "Error: disk '${DISK:-}' does not exist."
        exit 1
    fi

    if mount | grep -q "^${DISK}"; then
        echo "Error: selected disk appears to have mounted partitions."
        exit 1
    fi

    echo
    echo "Selected disk: $DISK"
    lsblk "$DISK"
    echo
    read -r -p "ALL DATA ON $DISK WILL BE DESTROYED. Type YES to continue: " CONFIRM

    if [[ "$CONFIRM" != "YES" ]]; then
        echo "Cancelled."
        exit 1
    fi
}

get_partitions() {
    if [[ "$DISK" == *"nvme"* ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
}

cleanup_mounts() {
    sudo umount -R /mnt 2>/dev/null || true
}

partition_disk() {
    echo "Partitioning $DISK..."
    sudo sgdisk --zap-all "$DISK"
    sudo parted -s "$DISK" mklabel gpt
    sudo parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    sudo parted -s "$DISK" set 1 esp on
    sudo parted -s "$DISK" mkpart primary ext4 513MiB 100%
    get_partitions
}

format_partitions() {
    echo "Formatting partitions..."
    sudo mkfs.fat -F32 "$EFI_PART"
    sudo mkfs.ext4 -F "$ROOT_PART"
}

mount_partitions() {
    echo "Mounting partitions..."
    sudo mount "$ROOT_PART" /mnt
    sudo mkdir -p /mnt/boot
    sudo mount "$EFI_PART" /mnt/boot
}

install_base() {
    echo "Installing base system..."
    sudo pacstrap /mnt base linux linux-firmware nano networkmanager sudo grub efibootmgr
    sudo genfstab -U /mnt | sudo tee /mnt/etc/fstab >/dev/null
}

configure_system() {
    echo "Configuring installed system..."
    sudo arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

grep -q '^$LOCALE UTF-8$' /etc/locale.gen || echo '$LOCALE UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=$LOCALE' > /etc/locale.conf

echo '$HOSTNAME' > /etc/hostname

echo
echo 'Set ROOT password:'
passwd

id -u '$USERNAME' >/dev/null 2>&1 || useradd -m -G wheel '$USERNAME'
echo
echo 'Set password for $USERNAME:'
passwd '$USERNAME'

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox git htop
systemctl enable lightdm
EOF
}

finish_message() {
    echo
    echo "Installation complete."
    echo "Target disk: $DISK"
    echo
    echo "To reboot:"
    echo "sudo umount -R /mnt && reboot"
    echo
}

main() {
    require_root_tools
    cleanup_mounts
    select_disk
    partition_disk
    format_partitions
    mount_partitions
    install_base
    configure_system
    finish_message
}

main "$@"
