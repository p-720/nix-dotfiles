local FIREFOX_URL = "https://ug.kyrgyzstan.kg/pomotask/"
local PHI = 0.618

hl.layout.register("ff-tg", {
    recalculate = function(ctx)
        local firefox = nil
        local telegram = nil
        local others = {}

        for _, target in ipairs(ctx.targets) do
            local w = target.window
            if w then
                local class = w.class or ""
                if not firefox and class:find("firefox") then
                    firefox = target
                elseif not telegram and class:find("TelegramDesktop") then
                    telegram = target
                else
                    table.insert(others, target)
                end
            end
        end

        if firefox then
            firefox:place(ctx:split(ctx.area, "left", 0.2))
        end

        local right = ctx:split(ctx.area, "right", 0.8)

        if telegram then
            if #others > 0 then
                telegram:place(ctx:split(right, "left", PHI))
                local col = ctx:split(right, "right", 1.0 - PHI)
                for i, target in ipairs(others) do
                    if i == #others then
                        target:place(col)
                    else
                        local share = 1.0 / (#others - i + 1)
                        target:place(ctx:split(col, "top", share))
                        col = ctx:split(col, "bottom", 1.0 - share)
                    end
                end
            else
                telegram:place(right)
            end
        end
    end,

    layout_msg = function(ctx, msg)
        return "ff-tg: firefox 20%, telegram golden ratio master"
    end,
})

hl.on("workspace.active", function(ws)
    if ws.id ~= 11 then return end

    local ws_obj = hl.get_workspace(11)
    if not ws_obj then return end

    local has_ff, has_tg = false, false
    for _, w in ipairs(ws_obj:get_windows()) do
        local c = w.class or ""
        if c:find("firefox") then has_ff = true end
        if c:find("org%.telegram%.desktop") then has_tg = true end
    end

    if not has_ff then hl.exec_cmd("firefox-pwa " .. FIREFOX_URL) end
    if not has_tg then hl.exec_cmd("env GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb WEBKIT_DISABLE_DMABUF_RENDERER=1 Telegram") end
end)
