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
apt install -y arch-install-scripts pacman-package-manager gdisk parted dosfstools e2fsprogs curl util-linux

echo "Checking internet..."
ping -c 1 archlinux.org >/dev/null

umount -R /mnt 2>/dev/null || true

echo
echo "Available disks:"
mapfile -t DISKS < <(for d in /sys/block/*; do
    n="$(basename "$d")"
    case "$n" in
        loop*|ram*|zram*|sr*|md*|dm-*) continue ;;
    esac
    [ -b "/dev/$n" ] && echo "/dev/$n"
done)

if [[ ${#DISKS[@]} -eq 0 ]]; then
    echo "No disks found"
    ls /sys/block || true
    lsblk || true
    exit 1
fi

DEFAULT_INDEX=1
for i in "${!DISKS[@]}"; do
    disk="${DISKS[$i]}"
    size="$(lsblk -dn -o SIZE "$disk" 2>/dev/null | head -n1 | xargs)"
    model="$(lsblk -dn -o MODEL "$disk" 2>/dev/null | head -n1 | xargs)"
    tran="$(lsblk -dn -o TRAN "$disk" 2>/dev/null | head -n1 | xargs)"
    printf "%2d) %-14s %-8s %-6s %s\n" "$((i+1))" "$disk" "${size:-?}" "${tran:-?}" "${model:-?}"
    name="$(basename "$disk")"
    if [[ "$name" == nvme* ]]; then
        DEFAULT_INDEX=$((i+1))
    fi
done

echo
read -rp "Select disk number [default ${DEFAULT_INDEX}]: " CHOICE
CHOICE="${CHOICE:-$DEFAULT_INDEX}"

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#DISKS[@]} )); then
    echo "Invalid disk selection"
    exit 1
fi

DISK="${DISKS[$((CHOICE-1))]}"

echo
echo "Selected: $DISK"
lsblk "$DISK" || true
echo
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
mkdir -p /mnt
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

echo "Creating pacman bootstrap config..."
mkdir -p /tmp/arch-bootstrap
mkdir -p /var/lib/pacman /var/cache/pacman/pkg

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
ParallelDownloads = 5
CacheDir = /var/cache/pacman/pkg/
DBPath = /var/lib/pacman/

[core]
Include = /tmp/arch-bootstrap/mirrorlist

[extra]
Include = /tmp/arch-bootstrap/mirrorlist
EOF

echo "Installing base..."
pacstrap -C /tmp/arch-bootstrap/pacman.conf /mnt \
    base linux linux-firmware sudo nano networkmanager grub efibootmgr archlinux-keyring

genfstab -U /mnt >> /mnt/etc/fstab

echo "Preparing mirrors inside installed Arch..."
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

grep -q '^$LOCALE UTF-8$' /etc/locale.gen || echo '$LOCALE UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=$LOCALE' > /etc/locale.conf

echo '$HOSTNAME' > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

mkdir -p /etc/pacman.d
cat > /etc/pacman.d/mirrorlist <<'MIRRORS'
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
MIRRORS

echo 'KEYMAP=us' > /etc/vconsole.conf

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

echo
echo "DONE"
echo "Run:"
echo "umount -R /mnt"
echo "reboot"
