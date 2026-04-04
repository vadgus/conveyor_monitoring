#!/usr/bin/env bash
# curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/config_arch.sh?ts=$(date +%s)" | sudo bash

set -euo pipefail

real_user="$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1 || true)"
[[ -z "${real_user:-}" ]] && real_user="${SUDO_USER:-}"
[[ -z "${real_user:-}" ]] && { echo "Failed to determine real user"; exit 1; }

user_home="$(getent passwd "$real_user" | cut -d: -f6)"
[[ -z "${user_home:-}" || ! -d "$user_home" ]] && user_home="/home/$real_user"

bashrc_file="$user_home/.bashrc"
mkdir -p "$(dirname "$bashrc_file")"
touch "$bashrc_file"

command -v pacman >/dev/null 2>&1 || { echo "Arch only"; exit 1; }

echo "==> System update"
pacman -Syu --noconfirm || true

echo "==> Install packages"
pacman -S --needed --noconfirm \
    openssh curl git tmux sudo btop \
    python python-pip tk \
    docker \
    lightdm xfce4 xfce4-goodies \
    xorg-server dbus xfconf \
    adwaita-icon-theme

echo "==> Sudo NOPASSWD"
mkdir -p /etc/sudoers.d
echo "$real_user ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$real_user"
chmod 0440 "/etc/sudoers.d/$real_user"

echo "==> Locale"
grep -q '^en_US.UTF-8 UTF-8$' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<EOF
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

cat > /etc/environment <<EOF
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

ln -sf /usr/share/zoneinfo/Europe/Nicosia /etc/localtime
hwclock --systohc || true

echo "==> LightDM"
mkdir -p /etc/lightdm/lightdm.conf.d

cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$real_user
autologin-user-timeout=0
EOF

systemctl enable lightdm || true

echo "==> Disable sleep"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

echo "==> Services"
systemctl enable sshd docker || true

groupadd docker 2>/dev/null || true
usermod -aG docker "$real_user"

echo "==> Wallpaper setup"

wallpaper="/usr/local/share/backgrounds/cron.png"
mkdir -p /usr/local/share/backgrounds

curl -fsSL \
"https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/cron.png" \
-o "$wallpaper" || true

chmod 644 "$wallpaper" || true

mkdir -p "$user_home/.local/bin"
mkdir -p "$user_home/.config/autostart"

# удаляем старый мусор
rm -f "$user_home/.local/bin/apply_xfce_wallpaper.sh" || true
rm -f "$user_home/.config/autostart/apply-xfce-wallpaper.desktop" || true

cat > "$user_home/.local/bin/apply_wallpaper.sh" <<EOF
#!/usr/bin/env bash
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"

sleep 2

wallpaper="$wallpaper"

xfconf-query -c xfce4-desktop -p /backdrop/single-workspace-mode -n -t bool -s true >/dev/null 2>&1 || true

monitor_keys=\$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/workspace0/image-style$' || true)

for key in \$monitor_keys; do
    base="\${key%/image-style}"

    xfconf-query -c xfce4-desktop -p "\${base}/last-image" -n -t string -s "\$wallpaper" >/dev/null 2>&1 || \
    xfconf-query -c xfce4-desktop -p "\${base}/last-image" -s "\$wallpaper" >/dev/null 2>&1 || true

    xfconf-query -c xfce4-desktop -p "\${base}/image-style" -n -t int -s 1 >/dev/null 2>&1 || \
    xfconf-query -c xfce4-desktop -p "\${base}/image-style" -s 1 >/dev/null 2>&1 || true
done

xfdesktop --reload >/dev/null 2>&1 || true
EOF

chmod +x "$user_home/.local/bin/apply_wallpaper.sh"

cat > "$user_home/.config/autostart/wallpaper.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Wallpaper
Exec=$user_home/.local/bin/apply_wallpaper.sh
EOF

chown -R "$real_user:$real_user" "$user_home/.local"
chown -R "$real_user:$real_user" "$user_home/.config"

echo "==> Apply now (live session)"

sudo -u "$real_user" env \
    DISPLAY=:0 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$real_user")/bus" \
    "$user_home/.local/bin/apply_wallpaper.sh" || true

echo "==> DONE"
