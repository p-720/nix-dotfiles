
local menu = "~/.config/rofi/launchers/colorful/launcher.sh"

local terminal = "foot"
local fileManager = "dolphin"
mainMod = "SUPER"

-- Basic binds
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + x", hl.dsp.window.close())
hl.bind(mainMod .. " + SHIFT + q", hl.dsp.exit())
hl.bind(mainMod .. " + SHIFT + r", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + ALT + b", hl.dsp.exec_cmd("systemctl --user restart waybar"))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + t", hl.dsp.window.float())
hl.bind(mainMod .. " + d", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + P", hl.dsp.exec_cmd("~/.config/rofi/launchers/colorful/pomotask.sh"))
-- hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + bracketright", hl.dsp.exec_cmd("~/.config/polybar/light_control.sh"))

-- Screenshots and recording
hl.bind("Print", hl.dsp.exec_cmd("fish -c 'flameshot_hyprland'"))
hl.bind("Scroll_Lock", hl.dsp.exec_cmd("fish -c 'record_screen_replay_sound'"))
hl.bind("SHIFT + Scroll_Lock", hl.dsp.exec_cmd("fish -c 'trim_last_replay'"))
hl.bind("CTRL + Scroll_Lock", hl.dsp.exec_cmd("fish -c 'copy_last_replay'"))
hl.bind("CTRL + SHIFT + Scroll_Lock", hl.dsp.exec_cmd("fish -c 'record_screen_replay_sound_stop'"))
hl.bind("CTRL + SHIFT", hl.dsp.exec_cmd("env flameshot full -c"))
hl.bind("CTRL + SHIFT + Print", hl.dsp.exec_cmd("sh -c '~/.config/i3/screenshot_window.sh activewindow'"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("fish -c 'flameshot_screen'"))
hl.bind("Pause", hl.dsp.exec_cmd("fish -c 'record'"))
hl.bind("SHIFT + Pause", hl.dsp.exec_cmd("fish -c 'trim_video_from_clipboard'"))
hl.bind("CTRL + SHIFT + u", hl.dsp.exec_cmd("fish -c 'shorten-url'"))
hl.bind(mainMod .. " + SHIFT + l", hl.dsp.exec_cmd("hyprlock"))

-- Move focus (vim-style)
hl.bind(mainMod .. " + h", hl.dsp.focus({ direction = "l" }))
hl.bind(mainMod .. " + l", hl.dsp.focus({ direction = "r" }))
hl.bind(mainMod .. " + k", hl.dsp.focus({ direction = "u" }))
hl.bind(mainMod .. " + j", hl.dsp.focus({ direction = "d" }))

-- Move window (vim-style)
hl.bind(mainMod .. " + ALT + h", hl.dsp.window.move({ direction = "l" }))
hl.bind(mainMod .. " + ALT + l", hl.dsp.window.move({ direction = "r" }))
hl.bind(mainMod .. " + ALT + k", hl.dsp.window.move({ direction = "u" }))
hl.bind(mainMod .. " + ALT + j", hl.dsp.window.move({ direction = "d" }))

-- Switch workspaces
for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }))
end
hl.bind(mainMod .. " + 0", hl.dsp.focus({ workspace = 10 }))
hl.bind(mainMod .. " + minus", hl.dsp.focus({ workspace = 11 }))
hl.bind(mainMod .. " + equal", hl.dsp.focus({ workspace = 12 }))

-- Move active window to workspace
for i = 1, 9 do
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end
hl.bind(mainMod .. " + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }))
hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.window.move({ workspace = 11 }))
hl.bind(mainMod .. " + SHIFT + equal", hl.dsp.window.move({ workspace = 12 }))

-- Move current workspace to monitor
hl.bind("ALT + " .. mainMod .. " + 1", hl.dsp.workspace.move({ monitor = 0 }))
hl.bind("ALT + " .. mainMod .. " + 2", hl.dsp.workspace.move({ monitor = 1 }))
hl.bind("ALT + " .. mainMod .. " + 0", hl.dsp.workspace.move({ monitor = 0 }))
hl.bind("ALT + " .. mainMod .. " + 9", hl.dsp.workspace.move({ monitor = 1 }))
hl.bind("ALT + " .. mainMod .. " + minus", hl.dsp.workspace.move({ monitor = 2 }))

-- Special workspace
hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- Scroll through workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse:275", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:276", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + left", hl.dsp.focus({ workspace = "e-1" }))

-- Resize + center + move
-- hl.bind(mainMod .. " + bracketleft", function()
--     hl.dsp.exec_cmd("hyprctl dispatch resizeactive exact 100% 100% && hyprctl dispatch centerwindow && hyprctl dispatch moveactive 0 15")
-- end)

hl.bind(mainMod .. " + bracketleft", function()
    -- Native dispatcher calls are safer and significantly faster
    local monitor = hl.get_active_monitor()

    if not monitor then return end

    local height = monitor.height;

    local width = monitor.width;

    hl.dispatch(hl.dsp.window.resize({ x = width, y = height}))
    hl.dispatch(hl.dsp.window.center())
    hl.dispatch(hl.dsp.window.move({ x = 0, y = 15, relative = true }))
end)

hl.bind(mainMod .. " + PERIOD", hl.dsp.window.pin())
hl.bind(mainMod .. " + f", hl.dsp.window.fullscreen())
hl.bind("CTRL + backslash", hl.dsp.window.fullscreen_state({ internal = 0, client = 2 }))
hl.bind("CTRL + SHIFT", hl.dsp.pass({ window = "^((.+)fcitx(.+))$" }))

-- Mouse binds
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Volume and brightness (repeatable)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { repeating = true })
hl.bind("XF86Search", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { repeating = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { repeating = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl s 10%+"), { repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl s 10%-"), { repeating = true })

-- Playerctl (locked)
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })

-- Enter resize submap
hl.bind(mainMod .. " + R", hl.dsp.submap("resize"))

-- Resize submap
hl.define_submap("resize", function()
    hl.bind("right", hl.dsp.window.resize({ x = 50, y = 0, relative = true }), { repeating = true })
    hl.bind("left", hl.dsp.window.resize({ x = -50, y = 0, relative = true }), { repeating = true })
    hl.bind("up", hl.dsp.window.resize({ x = 0, y = -50, relative = true }), { repeating = true })
    hl.bind("down", hl.dsp.window.resize({ x = 0, y = 50, relative = true }), { repeating = true })
    hl.bind("l", hl.dsp.window.resize({ x = 50, y = 0, relative = true }), { repeating = true })
    hl.bind("h", hl.dsp.window.resize({ x = -50, y = 0, relative = true }), { repeating = true })
    hl.bind("k", hl.dsp.window.resize({ x = 0, y = -50, relative = true }), { repeating = true })
    hl.bind("j", hl.dsp.window.resize({ x = 0, y = 50, relative = true }), { repeating = true })
    hl.bind("escape", hl.dsp.submap("reset"))
    hl.bind(mainMod .. " + R", hl.dsp.submap("reset"))
end)
