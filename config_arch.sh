#!/usr/bin/env bash
# curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/config_arch.sh?ts=$(date +%s)" | sudo bash

set -euo pipefail

real_user="$(logname 2>/dev/null || who | awk '{print $1}' | head -n 1 || true)"
if [[ -z "${real_user:-}" ]]; then
    real_user="${SUDO_USER:-}"
fi
if [[ -z "${real_user:-}" ]]; then
    echo "Failed to determine real user"
    exit 1
fi

user_home="$(getent passwd "$real_user" | cut -d: -f6)"
if [[ -z "${user_home:-}" || ! -d "$user_home" ]]; then
    user_home="/home/$real_user"
fi

bashrc_file="$user_home/.bashrc"
mkdir -p "$(dirname "$bashrc_file")"
touch "$bashrc_file"

if ! command -v pacman >/dev/null 2>&1; then
    echo "This script supports Arch-based systems only"
    exit 1
fi

echo "==> Updating system"
pacman -Syu --noconfirm || true

echo "==> Installing packages"
pacman -S --needed --noconfirm \
    openssh \
    curl \
    git \
    tmux \
    sudo \
    btop \
    python \
    python-pip \
    tk \
    docker \
    lightdm \
    xfce4 \
    xfce4-goodies \
    xorg-server \
    dbus \
    xfconf \
    adwaita-icon-theme

echo "==> Sudo without password"
mkdir -p /etc/sudoers.d
echo "$real_user ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$real_user"
chmod 0440 "/etc/sudoers.d/$real_user"

echo "==> Locale & timezone"
grep -q '^en_US.UTF-8 UTF-8$' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

cat > /etc/environment <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/locale.conf <<'EOF'
[Manager]
DefaultEnvironment=LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
EOF

ln -sf /usr/share/zoneinfo/Europe/Nicosia /etc/localtime
hwclock --systohc || true
systemctl daemon-reexec || true

echo "==> LightDM autologin"
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=$real_user
autologin-user-timeout=0
EOF

cat > /etc/lightdm/lightdm.conf.d/99-no-blanking.conf <<'EOF'
[Seat:*]
xserver-command=X -s 0 -dpms
EOF

systemctl enable lightdm || true

echo "==> Disable sleep/hibernate"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
systemctl disable sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-24-7.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=0
EOF

systemctl restart systemd-logind 2>/dev/null || true

echo "==> Services"
systemctl enable sshd || true
systemctl enable docker || true
systemctl disable bluetooth.service 2>/dev/null || true
systemctl stop bluetooth.service 2>/dev/null || true

groupadd docker 2>/dev/null || true
usermod -aG docker "$real_user"

echo "==> Aliases"
if grep -q "^alias ll=" "$bashrc_file"; then
    sed -i "s|^alias ll=.*|alias ll='ls -lah'|" "$bashrc_file"
else
    echo "alias ll='ls -lah'" >> "$bashrc_file"
fi

if ! grep -q "^alias upgrade=" "$bashrc_file"; then
    echo "alias upgrade='sudo pacman -Syu --noconfirm'" >> "$bashrc_file"
fi

if ! grep -q "^export LANG=en_US.UTF-8$" "$bashrc_file"; then
    echo 'export LANG=en_US.UTF-8' >> "$bashrc_file"
fi

if ! grep -q "^export LC_ALL=en_US.UTF-8$" "$bashrc_file"; then
    echo 'export LC_ALL=en_US.UTF-8' >> "$bashrc_file"
fi

echo "==> Wallpaper"
wallpaper_dir="/usr/local/share/backgrounds"
wallpaper_file="$wallpaper_dir/cron.png"
mkdir -p "$wallpaper_dir"

curl -fsSL -H 'Cache-Control: no-cache' \
    "https://raw.githubusercontent.com/vadgus/debug/refs/heads/main/cron.png" \
    -o "$wallpaper_file" || true

chmod 0644 "$wallpaper_file" 2>/dev/null || true

echo "==> XFCE autostart"
if systemctl is-enabled lightdm >/dev/null 2>&1; then
    mkdir -p "$user_home/.config/autostart"
    mkdir -p "$user_home/.local/bin"

    cat > "$user_home/.config/autostart/disable-screen-blanking.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Disable Screen Blanking
Exec=sh -c 'xset s off -dpms s noblank'
X-GNOME-Autostart-enabled=true
EOF

    cat > "$user_home/.config/autostart/apply-xfce-theme.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Apply XFCE Theme
Exec=sh -c 'sleep 3; xfconf-query -c xsettings -p /Net/ThemeName -s Adwaita-dark >/dev/null 2>&1 || true; xfconf-query -c xsettings -p /Net/IconThemeName -s Adwaita >/dev/null 2>&1 || true'
X-GNOME-Autostart-enabled=true
EOF

    cat > "$user_home/.local/bin/apply_xfce_wallpaper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

wallpaper_file="$wallpaper_file"

sleep 8

if ! command -v xfconf-query >/dev/null 2>&1; then
    exit 0
fi

if ! command -v xfdesktop >/dev/null 2>&1; then
    exit 0
fi

for _ in \$(seq 1 20); do
    if xfconf-query -c xfce4-desktop -l >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

xfconf-query -c xfce4-desktop -p /backdrop/single-workspace-mode -n -t bool -s true >/dev/null 2>&1 || true

last_image_paths=\$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/last-image$' || true)
image_style_paths=\$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep '/image-style$' || true)

for p in \$last_image_paths; do
    xfconf-query -c xfce4-desktop -p "\$p" -s "\$wallpaper_file" >/dev/null 2>&1 || true
done

for p in \$image_style_paths; do
    xfconf-query -c xfce4-desktop -p "\$p" -s 3 >/dev/null 2>&1 || true
done

xfdesktop --reload >/dev/null 2>&1 || true
EOF

    chmod +x "$user_home/.local/bin/apply_xfce_wallpaper.sh"

    cat > "$user_home/.config/autostart/apply-xfce-wallpaper.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Apply XFCE Wallpaper
Exec=sh -c "$HOME/.local/bin/apply_xfce_wallpaper.sh"
X-GNOME-Autostart-enabled=true
EOF

    chown -R "$real_user:$real_user" "$user_home/.config"
    chown -R "$real_user:$real_user" "$user_home/.local"
fi

echo "==> Done. Reboot recommended."
