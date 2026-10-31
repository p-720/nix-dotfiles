
-- Monitor variables (global, referenced in other files)
monitor_1 = "desc:LG Electronics LG HDR WFHD 0x00077717"
monitor_2 = "desc:AOC 2269W BGMD59A000839"
test = "HDMI-A-2"

-- Environment variables
hl.config({
    env = {
        "BROWSER,firefox",
        "MOZ_ENABLE_WAYLAND,1",
        "QT_QPA_PLATFORMTHEME,gnome",
        "QT_QPA_PLATFORM,wayland",
        "LIBGL_ALWAYS_SOFTWARE,1",
        "WLR_RENDERER_ALLOW_SOFTWARE,1",
        "ANKI_WAYLAND,1",
        "XDG_SESSION_TYPE,wayland",
    }
})

-- GUAKE_ENABLE_WAYLAND uses = without space (hyprlang syntax variant)
-- In Lua env format, all use KEY,VALUE
