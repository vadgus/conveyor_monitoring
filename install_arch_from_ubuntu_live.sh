#!/usr/bin/env bash
set -euo pipefail

# === QUICK START ===
# sudo -i
# bash <(curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_ubuntu_live.sh)

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"

echo "Installing required tools..."
apt update
apt install -y arch-install-scripts pacman-package-manager gdisk parted dosfstools e2fsprogs curl

echo "Checking internet..."
ping -c 1 archlinux.org >/dev/null

umount -R /mnt 2>/dev/null || true

echo
echo "Available disks:"
mapfile -t DISKS < <(lsblk -dpno NAME,SIZE | grep -E '^/dev/(sd|nvme)' | grep -v loop)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "No disks found"
    exit 1
fi

for i in "${!DISKS[@]}"; do
    echo "$((i+1))) ${DISKS[$i]}"
done

echo
read -rp "Select disk number: " CHOICE

DISK=$(echo "${DISKS[$((CHOICE-1))]}" | awk '{print $1}')

echo "Selected: $DISK"
read -rp "Type YES to wipe disk: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

echo "Partitioning..."
sgdisk --zap-all "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB 100%

if [[ "$DISK" == *"nvme"* ]]; then
    EFI="${DISK}p1"
    ROOT="${DISK}p2"
else
    EFI="${DISK}1"
    ROOT="${DISK}2"
fi

sleep 2

echo "Formatting..."
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

echo "Mounting..."
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "Creating pacman config..."
mkdir -p /tmp/arch-bootstrap

cat > /tmp/arch-bootstrap/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

cat > /tmp/arch-bootstrap/pacman.conf <<EOF
[options]
Architecture = auto
CheckSpace
SigLevel = Never
LocalFileSigLevel = Never

[core]
Include = /tmp/arch-bootstrap/mirrorlist

[extra]
Include = /tmp/arch-bootstrap/mirrorlist
EOF

echo "Installing base..."
pacstrap -C /tmp/arch-bootstrap/pacman.conf /mnt base linux linux-firmware sudo nano networkmanager grub efibootmgr archlinux-keyring

genfstab -U /mnt >> /mnt/etc/fstab

echo "Fixing mirrors..."
mkdir -p /mnt/etc/pacman.d

cat > /mnt/etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

echo "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "KEYMAP=us" > /etc/vconsole.conf

pacman-key --init
pacman-key --populate archlinux

pacman -Sy

echo "Set ROOT password:"
passwd

useradd -m -G wheel $USERNAME

echo "Set password for $USERNAME:"
passwd $USERNAME

sed -i 's/^# %wheel/%wheel/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm xorg xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox

systemctl enable lightdm

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo
echo "DONE"
echo "Now run:"
echo "umount -R /mnt"
echo "reboot"
