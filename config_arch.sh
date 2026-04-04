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

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/locale.conf <<EOF
[Manager]
DefaultEnvironment=LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
EOF

ln -sf /usr/share/zoneinfo/Europe/Nicosia /etc/localtime
hwclock --systohc || true
systemctl daemon-reexec || true

echo "==> LightDM"
mkdir -p /etc/lightdm/lightdm.conf.d

cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$real_user
autologin-user-timeout=0
EOF

cat > /etc/lightdm/lightdm.conf.d/99-no-blanking.conf <<EOF
[Seat:*]
xserver-command=X -s 0 -dpms
EOF

systemctl enable lightdm || true

echo "==> Disable sleep"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
systemctl disable sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99.conf <<EOF
[Login]
HandleLidSwitch=ignore
IdleAction=ignore
EOF

systemctl restart systemd-logind || true

echo "==> Services"
systemctl enable sshd docker || true

groupadd docker 2>/dev/null || true
usermod -aG docker "$real_user"

echo "==> Aliases"
grep -q "alias ll=" "$bashrc_file" || echo "alias ll='ls -lah'" >> "$bashrc_file"
grep -q "alias upgrade=" "$bashrc_file" || echo "alias upgrade='sudo pacman -Syu --noconfirm'" >> "$bashrc_file"

echo "export LANG=en_US.UTF-8" >> "$bashrc_file"
echo "export LC_ALL=en_US.UTF-8" >> "$bashrc_file"

echo "==> Wallpaper"
wallpaper="/usr/local/share/backgrounds/cron.png"
mkdir -p /usr/local/share/backgrounds

curl -fsSL \
"https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/cron.png" \
-o "$wallpaper" || true

chmod 644 "$wallpaper" || true

echo "==> XFCE autostart"
mkdir -p "$user_home/.config/autostart"
mkdir -p "$user_home/.local/bin"

cat > "$user_home/.local/bin/apply_wallpaper.sh" <<EOF
#!/usr/bin/env bash
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$(id -u)/bus"

sleep 3

xfconf-query -c xfce4-desktop -p /backdrop/single-workspace-mode -n -t bool -s true >/dev/null 2>&1 || true

for monitor in monitor0 monitorHDMI-1; do
    xfconf-query -c xfce4-desktop -p "/backdrop/screen0/\${monitor}/workspace0/last-image" -n -t string -s "$wallpaper" >/dev/null 2>&1 || \
    xfconf-query -c xfce4-desktop -p "/backdrop/screen0/\${monitor}/workspace0/last-image" -s "$wallpaper" >/dev/null 2>&1 || true

    xfconf-query -c xfce4-desktop -p "/backdrop/screen0/\${monitor}/workspace0/image-style" -n -t int -s 1 >/dev/null 2>&1 || \
    xfconf-query -c xfce4-desktop -p "/backdrop/screen0/\${monitor}/workspace0/image-style" -s 1 >/dev/null 2>&1 || true
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

chown -R "$real_user:$real_user" "$user_home/.config"
chown -R "$real_user:$real_user" "$user_home/.local"

echo "==> DONE (reboot recommended)"
