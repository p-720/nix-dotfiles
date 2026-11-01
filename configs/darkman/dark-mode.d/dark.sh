#/usr/bin/env nix-shell
#!nix-shell -p sway feh hyprland
# /nix/store/4nyqjyfzdfp87z5illnm6jz6jw95w6ka-dbus-1.14.10/bin/dbus-update-activation-environment --systemd --all

if [ "$XDG_CURRENT_DESKTOP" = "Hyprland"];
then
    hyprctl hyprpaper wallpaper ",/etc/nixos/bg_old.png"
else
    if [ "$XDG_SESSION_TYPE" = "wayland" ];
    then
        export SWAYSOCK="/run/user/$(id -u)/sway-ipc.$(id -u).$(pidof sway).sock"
        swaymsg "output * bg /etc/nixos/bg_old.png fill"
    else
        if [ "$WORK_MODE" = "1" ]; then
            feh --bg-fill --geometry +0+0 /etc/nixos/work-bg.jpg /etc/nixos/work-bg.jpg /etc/nixos/work-bg.jpg;
        else
            feh --bg-fill --geometry +0+0 /etc/nixos/bg_old.png /etc/nixos/bg_old.png /etc/nixos/bg_old.png;
        fi
        touch $HOME/.xsettingsd
        cat > $HOME/.xsettingsd <<-EOF
    Net/IconThemeName "Obsidian"
    Net/ThemeName "Adwaita-dark"
EOF
        pkill -HUP xsettingsd

    fi
fi

# configure-gtk
# gnome_schema=org.gnome.desktop.interface
# gsettings set $gnome_schema gtk-theme 'Adwaita-dark'
# gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
# gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
