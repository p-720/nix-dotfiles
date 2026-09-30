
-- exec-once: tmux with HIS
hl.on("hyprland.start", function()
    hl.exec_cmd("tmux setenv -g HYPRLAND_INSTANCE_SIGNATURE \"$HYPRLAND_INSTANCE_SIGNATURE\"")
end)

hl.config({
    cursor = {},
    debug = {
        disable_logs = false,
        enable_stdout_logs = true,
    },
    general = {
        gaps_in = 0,
        gaps_out = 0,
        border_size = 2,
        ["col.active_border"] = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
        ["col.inactive_border"] = "rgba(595959aa)",
        allow_tearing = true,
    },
    decoration = {
        rounding = 10,
        active_opacity = 1.0,
        inactive_opacity = 1.0,
        shadow = {
            enabled = false,
            range = 10,
            render_power = 2,
            color = "rgba(1a1a1a22)",
        },
        blur = {
            enabled = false,
            size = 3,
            passes = 1,
            vibrancy = 0.1696,
        },
    },
    misc = {
        focus_on_activate = false,
        enable_anr_dialog = false,
        force_default_wallpaper = 0,
        disable_hyprland_logo = true
    },
})
