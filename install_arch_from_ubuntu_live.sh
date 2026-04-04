#!/usr/bin/env bash
set -euo pipefail

# === QUICK START ===
# sudo -i
# bash <(curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_ubuntu_live.sh)

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"

WORKDIR="/tmp/arch-bootstrap"
PACMAN_CONF="${WORKDIR}/pacman.conf"
BOOTSTRAP_MIRRORLIST="${WORKDIR}/mirrorlist"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1"
        exit 1
    }
}

require_tools() {
    apt update
    apt install -y \
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
    echo
    echo "Checking internet..."
    ping -c 1 archlinux.org >/dev/null 2>&1 || {
        echo "Error: internet connection is required."
        exit 1
    }
}

cleanup_mounts() {
    umount -R /mnt 2>/dev/null || true
}

list_real_disks() {
    local dev
    for dev in /sys/block/*; do
        dev="$(basename "$dev")"
        case "$dev" in
            loop*|ram*|zram*|sr*|md*|dm-*)
                continue
                ;;
        esac
        if [[ -b "/dev/$dev" ]]; then
            echo "$dev"
        fi
    done
}

disk_size_human() {
    local disk="$1"
    lsblk -dn -o SIZE "/dev/$disk" 2>/dev/null | head -n1 | xargs
}

disk_model() {
    local disk="$1"
    cat "/sys/block/$disk/device/model" 2>/dev/null | xargs || true
}

disk_tran() {
    local disk="$1"
    lsblk -dn -o TRAN "/dev/$disk" 2>/dev/null | head -n1 | xargs
}

select_disk() {
    echo
    echo "Available disks:"
    echo

    mapfile -t DISKS < <(list_real_disks)

    if [[ "${#DISKS[@]}" -eq 0 ]]; then
        echo "No disks found."
        echo
        echo "Debug:"
        ls /sys/block || true
        echo
        lsblk || true
        exit 1
    fi

    local DEFAULT_INDEX=""
    local i idx name size model tran

    for i in "${!DISKS[@]}"; do
        idx=$((i + 1))
        name="${DISKS[$i]}"
        size="$(disk_size_human "$name")"
        model="$(disk_model "$name")"
        tran="$(disk_tran "$name")"

        [[ -n "$size" ]] || size="-"
        [[ -n "$model" ]] || model="-"
        [[ -n "$tran" ]] || tran="-"

        printf "%2d) %-14s  %-8s  %-6s  %s\n" "$idx" "/dev/$name" "$size" "$tran" "$model"

        if [[ -z "$DEFAULT_INDEX" ]]; then
            if [[ "$name" == nvme* ]]; then
                DEFAULT_INDEX="$idx"
            elif [[ "$tran" != "usb" ]]; then
                DEFAULT_INDEX="$idx"
            fi
        fi
    done

    [[ -n "$DEFAULT_INDEX" ]] || DEFAULT_INDEX="1"

    echo
    read -r -p "Select disk number [default ${DEFAULT_INDEX}]: " CHOICE
    CHOICE="${CHOICE:-$DEFAULT_INDEX}"

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#DISKS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    DISK="/dev/${DISKS[$((CHOICE - 1))]}"

    echo
    echo "Selected disk: $DISK"
    lsblk "$DISK" || true
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
    sgdisk --zap-all "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%
    get_partitions
    sleep 2
}

format_partitions() {
    echo
    echo "Formatting partitions..."
    mkfs.fat -F32 "$EFI_PART"
    mkfs.ext4 -F "$ROOT_PART"
}

mount_partitions() {
    echo
    echo "Mounting partitions..."
    mkdir -p /mnt
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot
}

prepare_bootstrap_pacman() {
    echo
    echo "Preparing pacman bootstrap config..."
    mkdir -p "$WORKDIR"
    mkdir -p /var/lib/pacman
    mkdir -p /var/cache/pacman/pkg

    cat > "$BOOTSTRAP_MIRRORLIST" <<'EOF'
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
Include = $BOOTSTRAP_MIRRORLIST

[extra]
Include = $BOOTSTRAP_MIRRORLIST
EOF
}

install_base() {
    echo
    echo "Installing base system..."
    pacstrap -C "$PACMAN_CONF" /mnt \
        base \
        linux \
        linux-firmware \
        nano \
        networkmanager \
        sudo \
        grub \
        efibootmgr \
        archlinux-keyring

    genfstab -U /mnt >> /mnt/etc/fstab
}

prepare_installed_system_repos() {
    echo
    echo "Preparing mirrors inside installed Arch..."
    mkdir -p /mnt/etc/pacman.d

    cat > /mnt/etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
EOF

    if [[ -f /mnt/etc/pacman.conf ]]; then
        sed -i 's|^#\s*ParallelDownloads|ParallelDownloads|' /mnt/etc/pacman.conf || true
    fi
}

configure_system() {
    echo
    echo "Configuring installed system..."
    arch-chroot /mnt /bin/bash <<EOF
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

cat > /etc/vconsole.conf <<VCONSOLE
KEYMAP=us
FONT=
VCONSOLE

mkdir -p /etc/pacman.d
if [[ ! -f /etc/pacman.d/mirrorlist ]]; then
cat > /etc/pacman.d/mirrorlist <<MIRRORS
Server = https://geo.mirror.pkgbuild.com/\\$repo/os/\\$arch
Server = https://mirror.rackspace.com/archlinux/\\$repo/os/\\$arch
Server = https://mirrors.kernel.org/archlinux/\\$repo/os/\\$arch
MIRRORS
fi

sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist || true

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
    need_cmd apt
    need_cmd lsblk
    need_cmd parted
    need_cmd sgdisk
    need_cmd mkfs.fat
    need_cmd mkfs.ext4

    require_tools
    check_internet
    cleanup_mounts
    select_disk
    partition_disk
    format_partitions
    mount_partitions
    prepare_bootstrap_pacman
    install_base
    prepare_installed_system_repos
    configure_system
    finish_message
}

main "$@"
