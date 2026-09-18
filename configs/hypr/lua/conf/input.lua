
-- monitor_1 and monitor_2 are defined in env.lua (loaded first)

hl.config({
    general = {
        allow_tearing = true,
    },
    input = {
        kb_layout = "us,ru",
        kb_options = "grp:alt_shift_toggle",
        follow_mouse = 1,
        accel_profile = "flat",
        sensitivity = 0,
    },
})

-- Device: pen-passthrough
hl.device({
    name = "pen-passthrough",
    output = test,
    -- region_size = { 2000, 1200},
    -- active_area_size = { 306, 202}
    -- active_area_size = { 275, 192 },
    active_area_size = { 275, 192 },
})

-- Device: imps/2-generic-wheel-mouse (disabled)
hl.device({
    name = "imps/2-generic-wheel-mouse",
    enabled = false,
})

-- Device: mouse-passthrough (disabled)
hl.device({
    name = "mouse-passthrough-(absolute)",
    output = "HDMI-A-1",
    enabled = false,
})

-- Device: virtual-remapped-touchscreen-1 (disabled)
hl.device({
    name = "virtual-remapped-touchscreen-1",
    output = test,
    enabled = false,
})

-- Device: touch-passthrough-1
hl.device({
    name = "touch-passthrough-1",
    output = test,
    transform = 0
})

hl.device({
    name = "calibrated-touch-passthrough-1",
    output = test
})
