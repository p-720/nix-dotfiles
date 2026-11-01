#/usr/bin/env nix-shell
#!nix-shell -p feh
# /nix/store/4nyqjyfzdfp87z5illnm6jz6jw95w6ka-dbus-1.14.10/bin/dbus-update-activation-environment --systemd --all
hyprctl hyprpaper wallpaper ",/etc/nixos/light.jpg"

if [ "$XDG_CURRENT_DESKTOP" = "Hyprland"];
then
    hyprctl hyprpaper wallpaper ",/etc/nixos/light.jpg"
else
    if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
        export SWAYSOCK="/run/user/$(id -u)/sway-ipc.$(id -u).$(pidof sway).sock"
        swaymsg "output * bg /etc/nixos/light.jpg fill"
    else
        if [ "$WORK_MODE" = "1" ]; then
            feh --bg-fill --geometry +0+0 /etc/nixos/work-bg.jpg /etc/nixos/work-bg.jpg /etc/nixos/work-bg.jpg;
        else
            feh --bg-fill --geometry +0+0 /etc/nixos/light.jpg /etc/nixos/light.jpg /etc/nixos/light.jpg;
        fi

        touch $HOME/.xsettingsd
        cat > $HOME/.xsettingsd <<-EOF
    Net/IconThemeName "Obsidian"
    Net/ThemeName "Adwaita"
EOF
        pkill -HUP xsettingsd
    fi
fi

# touch $HOME/.config/gtk-3.0/settings.ini;
# cat > $HOME/.config/gtk-3.0/settings.ini <<-EOF
# [Settings]
# gtk-icon-theme-name=Obsidian
# gtk-theme-name=Breeze
# EOF
# EOF

# configure-gtk
# gnome_schema=org.gnome.desktop.interface
# gsettings set $gnome_schema gtk-theme 'Adwaita'
# gsettings set $gnome_schema icon-theme 'Obsidian'


# emacsclient -e '(toggle-day-night-theme :light)'
