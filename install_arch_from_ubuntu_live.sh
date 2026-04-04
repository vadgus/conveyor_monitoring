#!/usr/bin/env bash
set -euo pipefail

# === QUICK START (Ubuntu/Xubuntu Live) ===
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

PACMAN_WORKDIR="/tmp/arch-bootstrap"
PACMAN_CONF="${PACMAN_WORKDIR}/pacman.conf"
MIRRORLIST="${PACMAN_WORKDIR}/mirrorlist"

require_tools() {
    ${SUDO} apt update
    ${SUDO} apt install -y \
        arch-install-scripts \
        pacman-package-manager \
        gdisk \
        parted \
        dosfstools \
        e2fsprogs \
        curl
}

check_internet() {
    echo
    echo "Checking internet..."
    if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
        echo "Error: internet connection is required."
        exit 1
    fi
}

cleanup_mounts() {
    ${SUDO} umount -R /mnt 2>/dev/null || true
}

print_disks() {
    echo
    echo "Available disks:"
    echo
}

select_disk() {
    print_disks

    mapfile -t DISK_LINES < <(
        lsblk -d -e 7,11 -o NAME,SIZE,MODEL,TRAN,TYPE |
        awk 'NR>1 && $5=="disk" {print}'
    )

    if [ "${#DISK_LINES[@]}" -eq 0 ]; then
        echo "No disks found."
        exit 1
    fi

    DISK_PATHS=()
    DEFAULT_INDEX=""

    for i in "${!DISK_LINES[@]}"; do
        idx=$((i + 1))

        name="$(echo "${DISK_LINES[$i]}" | awk '{print $1}')"
        size="$(echo "${DISK_LINES[$i]}" | awk '{print $2}')"
        type="$(echo "${DISK_LINES[$i]}" | awk '{print $NF}')"
        tran="$(echo "${DISK_LINES[$i]}" | awk '{print $(NF-1)}')"
        model="$(echo "${DISK_LINES[$i]}" | awk '{for (j=3; j<=NF-2; j++) printf $j (j<NF-2?" ":"")}')"

        disk="/dev/$name"
        DISK_PATHS+=("$disk")

        printf "%2d) %-14s  %-8s  %-6s  %s\n" "$idx" "$disk" "$size" "${tran:--}" "$model"

        if [ -z "$DEFAULT_INDEX" ]; then
            if [[ "$name" == nvme* ]]; then
                DEFAULT_INDEX="$idx"
            elif [[ "$tran" != "usb" ]]; then
                DEFAULT_INDEX="$idx"
            fi
        fi
    done

    if [ -z "$DEFAULT_INDEX" ]; then
        DEFAULT_INDEX="1"
    fi

    echo
    read -r -p "Select disk number [default ${DEFAULT_INDEX}]: " CHOICE
    CHOICE="${CHOICE:-$DEFAULT_INDEX}"

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#DISK_PATHS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    DISK="${DISK_PATHS[$((CHOICE - 1))]}"

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

partition_disk() {
    echo
    echo "Partitioning $DISK..."
    ${SUDO} sgdisk --zap-all "$DISK"
    ${SUDO} parted -s "$DISK" mklabel gpt
    ${SUDO} parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    ${SUDO} parted -s "$DISK" set 1 esp on
    ${SUDO} parted -s "$DISK" mkpart primary ext4 513MiB 100%
    get_partitions
    sleep 2
}

format_partitions() {
    echo
    echo "Formatting partitions..."
    ${SUDO} mkfs.fat -F32 "$EFI_PART"
    ${SUDO} mkfs.ext4 -F "$ROOT_PART"
}

mount_partitions() {
    echo
    echo "Mounting partitions..."
    ${SUDO} mount "$ROOT_PART" /mnt
    ${SUDO} mkdir -p /mnt/boot
    ${SUDO} mount "$EFI_PART" /mnt/boot
}

prepare_pacman_bootstrap() {
    echo
    echo "Preparing pacman bootstrap config..."
    ${SUDO} mkdir -p "$PACMAN_WORKDIR"
    ${SUDO} mkdir -p /var/lib/pacman
    ${SUDO} mkdir -p /var/cache/pacman/pkg

    cat > "$MIRRORLIST" <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

    cat > "$PACMAN_CONF" <<EOF
[options]
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Never
LocalFileSigLevel = Never
CacheDir = /var/cache/pacman/pkg/
DBPath = /var/lib/pacman/
RootDir = /
GPGDir = /etc/pacman.d/gnupg/
HookDir = /etc/pacman.d/hooks/
HoldPkg = pacman glibc

[core]
Include = $MIRRORLIST

[extra]
Include = $MIRRORLIST
EOF
}

install_base() {
    echo
    echo "Installing base system..."
    ${SUDO} pacstrap -C "$PACMAN_CONF" /mnt \
        base linux linux-firmware nano networkmanager sudo grub efibootmgr \
        archlinux-keyring
    ${SUDO} genfstab -U /mnt | ${SUDO} tee /mnt/etc/fstab >/dev/null
}

configure_system() {
    echo
    echo "Configuring installed system..."
    ${SUDO} arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

grep -q '^$LOCALE UTF-8$' /etc/locale.gen || echo '$LOCALE UTF-8' >> /etc/locale.gen
locale-gen
echo 'LANG=$LOCALE' > /etc/locale.conf

echo '$HOSTNAME' > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm archlinux-keyring

echo
echo 'Set ROOT password:'
passwd

if ! id -u '$USERNAME' >/dev/null 2>&1; then
    useradd -m -G wheel '$USERNAME'
fi

echo
echo 'Set password for $USERNAME:'
passwd '$USERNAME'

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

finish_message() {
    echo
    echo "Installation complete."
    echo "Target disk: $DISK"
    echo
    echo "Next:"
    echo "  umount -R /mnt"
    echo "  reboot"
    echo
}

main() {
    require_tools
    check_internet
    cleanup_mounts
    select_disk
    partition_disk
    format_partitions
    mount_partitions
    prepare_pacman_bootstrap
    install_base
    configure_system
    finish_message
}

main "$@"
