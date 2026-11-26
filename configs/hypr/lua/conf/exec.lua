-- hl = Hyprland
-- exec (runs every reload)
hl.exec_cmd("hyprctl setcursor Adwaita 10")
-- hl.exec_cmd("intel-gpu-tools --custom min=1100 max=1200")

-- exec-once
hl.on("hyprland.start", function()
    hl.exec_cmd("gammastep -c ~/.config/gammastep.conf")
    hl.exec_cmd("pasystray")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("sleep 5 && /etc/nixos/configs/hypr/awww.sh")
    hl.exec_cmd("flameshot")
    hl.exec_cmd("max")
end)
