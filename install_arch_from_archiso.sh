#!/usr/bin/env bash
set -euo pipefail

# curl -fsSL https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/install_arch_from_archiso.sh -o /root/install_arch_from_archiso.sh
# bash /root/install_arch_from_archiso.sh

HOSTNAME="arch_nuc"
USERNAME="nuc"
TIMEZONE="Europe/Nicosia"
LOCALE="en_US.UTF-8"
KEYMAP="us"

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

check_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run as root"
}

check_internet() {
    log "Checking internet"
    ping -c 1 archlinux.org >/dev/null 2>&1 || die "Internet connection is required"
}

cleanup_mounts() {
    umount -R /mnt 2>/dev/null || true
}

get_install_media_disk() {
    local boot_source boot_pkname
    boot_source="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"

    if [[ -n "$boot_source" && -b "$boot_source" ]]; then
        boot_pkname="$(lsblk -no PKNAME "$boot_source" 2>/dev/null || true)"
        if [[ -n "$boot_pkname" ]]; then
            echo "/dev/$boot_pkname"
            return
        fi
        echo "$boot_source"
        return
    fi

    echo ""
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
        [[ -b "/dev/$dev" ]] && echo "/dev/$dev"
    done
}

select_disk() {
    log "Available disks"

    local install_media_disk
    install_media_disk="$(get_install_media_disk)"

    mapfile -t ALL_DISKS < <(list_real_disks)

    TARGET_DISKS=()
    local disk
    for disk in "${ALL_DISKS[@]}"; do
        if [[ -n "$install_media_disk" && "$disk" == "$install_media_disk" ]]; then
            continue
        fi
        TARGET_DISKS+=("$disk")
    done

    [[ ${#TARGET_DISKS[@]} -gt 0 ]] || die "No target disks found"

    local default_index=1
    local i name size model tran
    for i in "${!TARGET_DISKS[@]}"; do
        disk="${TARGET_DISKS[$i]}"
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

    if [[ -n "$install_media_disk" ]]; then
        echo
        echo "Install media excluded from list: $install_media_disk"
    fi

    echo
    read -r -p "Select disk number [default ${default_index}]: " choice
    choice="${choice:-$default_index}"

    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid disk selection"
    (( choice >= 1 && choice <= ${#TARGET_DISKS[@]} )) || die "Disk number out of range"

    DISK="${TARGET_DISKS[$((choice - 1))]}"

    echo
    echo "Selected disk: $DISK"
    lsblk "$DISK" || true
    echo
    read -r -p "ALL DATA ON $DISK WILL BE DESTROYED. Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || die "Cancelled"
}

partition_disk() {
    log "Partitioning $DISK"

    sgdisk --zap-all "$DISK"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%

    partprobe "$DISK" || true
    udevadm settle
    sleep 2

    if [[ "$DISK" == *"nvme"* ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi

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

install_base_system() {
    log "Installing base system"

    pacstrap /mnt \
        base \
        linux \
        linux-firmware \
        intel-ucode \
        nano \
        networkmanager \
        sudo \
        grub \
        efibootmgr \
        xorg \
        xfce4 \
        xfce4-goodies \
        lightdm \
        lightdm-gtk-greeter \
        firefox \
        git \
        htop \
        curl

    genfstab -U /mnt >> /mnt/etc/fstab
}

write_chroot_script() {
    log "Preparing post-install script"

    cat > /mnt/root/arch_postinstall.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail

: "${HOSTNAME:?}"
: "${USERNAME:?}"
: "${TIMEZONE:?}"
: "${LOCALE:?}"
: "${KEYMAP:?}"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

grep -q "^${LOCALE} UTF-8$" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo
echo "Set ROOT password:"
until passwd; do
    echo "Passwords did not match. Try again."
done

if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    useradd -m -G wheel "${USERNAME}"
fi

echo
echo "Set password for ${USERNAME}:"
until passwd "${USERNAME}"; do
    echo "Passwords did not match. Try again."
done

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable lightdm

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

rm -f /root/arch_postinstall.sh
CHROOT

    chmod +x /mnt/root/arch_postinstall.sh
}

configure_system() {
    log "Configuring installed system"

    HOSTNAME="$HOSTNAME" \
    USERNAME="$USERNAME" \
    TIMEZONE="$TIMEZONE" \
    LOCALE="$LOCALE" \
    KEYMAP="$KEYMAP" \
    arch-chroot /mnt /bin/bash /root/arch_postinstall.sh
}

finish() {
    log "Installation complete"
    echo "Run:"
    echo "  umount -R /mnt"
    echo "  reboot"
}

main() {
    need_cmd pacstrap
    need_cmd arch-chroot
    need_cmd lsblk
    need_cmd parted
    need_cmd sgdisk
    need_cmd mkfs.fat
    need_cmd mkfs.ext4
    need_cmd genfstab
    need_cmd ping

    check_root
    check_internet
    cleanup_mounts
    select_disk
    partition_disk
    format_partitions
    mount_partitions
    install_base_system
    write_chroot_script
    configure_system
    finish
}

main "$@"
