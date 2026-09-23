-- workspace 11 (telegram) layout — [Pomotask 20% | Notion Calendar 20% | Telegram 60%]
--
-- All firefox windows share the class "firefox", so roles are identified by
-- title and pinned per address+pid (same as workspace-emacs).
-- Notion Calendar is spawned with firefox-pwa, same as workspace-emacs.

local WS_ID      = 11
local POMO_URL   = "https://ug.kyrgyzstan.kg/pomotask/"
local NOTION_URL = "https://calendar.notion.so/"
local PHI        = 0.618

-- [address] = { role, pid }. The first real title a firefox window shows
-- pins its role.
local identity = {}

local function roleOf(w)
    local cl = (w.class or ""):lower()
    if cl ~= "firefox" then
        return nil
    end

    local rec = identity[w.address]
    if rec and rec.pid == w.pid then
        return rec.role
    end

    local t = (w.title or ""):lower()
    if t:find("notion calendar") or t:find("calendar.notion") then
        identity[w.address] = { role = "notion", pid = w.pid }
        return "notion"
    elseif t:find("pomotask") then
        identity[w.address] = { role = "pomo", pid = w.pid }
        return "pomo"
    end

    return nil
end

-- Telegram runs via XWayland ("TelegramDesktop") or Wayland
-- ("org.telegram.desktop").
local function isTelegram(w)
    return (w.class or ""):lower():find("telegram") ~= nil
end

-- Split the workspace area into the three fixed columns.
local function columnsFor(area)
    local notion_w = area.w * 0.25
    local pomo_w   = area.w * 0.2
    return {
        pomo   = { x = area.x, y = area.y, w = pomo_w, h = area.h },
        notion = { x = area.x + pomo_w, y = area.y, w = notion_w, h = area.h },
        tg     = { x = area.x + pomo_w + notion_w, y = area.y, w = area.w - pomo_w - notion_w, h = area.h },
    }
end

hl.layout.register("ff-tg", {
    recalculate = function(ctx)
        local notion, pomo, telegram, others = nil, nil, nil, {}

        -- First target per role wins; everything else stacks in the
        -- telegram column.
        for _, target in ipairs(ctx.targets) do
            local w = target.window
            if w then
                if isTelegram(w) then
                    if not telegram then
                        telegram = target
                    else
                        others[#others + 1] = target
                    end
                else
                    local r = roleOf(w)
                    if r == "notion" then
                        if not notion then
                            notion = target
                        else
                            others[#others + 1] = target
                        end
                    elseif r == "pomo" then
                        if not pomo then
                            pomo = target
                        else
                            others[#others + 1] = target
                        end
                    else
                        others[#others + 1] = target
                    end
                end
            end
        end

        local cols = columnsFor(ctx.area)
        if notion then
            notion:place(cols.notion)
        end
        if pomo then
            pomo:place(cols.pomo)
        end

        -- Telegram plus anything unrecognized share the right column,
        -- golden-ratio split, stacked.
        if telegram then
            if #others > 0 then
                telegram:place(ctx:split(cols.tg, "left", PHI))
                local col = ctx:split(cols.tg, "right", 1.0 - PHI)
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
                telegram:place(cols.tg)
            end
        end
    end,

    -- Returning true makes the layout recalculate after the message,
    -- which is how "refresh" (dispatched on title change) re-tiles.
    layout_msg = function()
        return true
    end,
})

-- PWA fake-fullscreen for the firefox windows (same as workspace-emacs).
hl.on("window.open", function(w)
    if not (w.workspace and w.workspace.id == WS_ID) then return end
    if (w.class or ""):lower() == "firefox" then
        hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 2, window = w }))
    end
end)

-- Re-tile when a title arrives late (identities are title-based).
local focused_mon
hl.on("monitor.focused", function(m)
    focused_mon = m and m.name
end)

hl.on("window.title", function(w)
    local ws = w.workspace
    if not (ws and ws.id == WS_ID and ws.active) then return end
    if focused_mon and w.monitor and w.monitor.name ~= focused_mon then return end
    hl.dispatch(hl.dsp.layout("refresh"))
end)

hl.on("window.close", function(w)
    identity[w.address] = nil
end)

-- Spawn whatever is missing when the workspace is (re)activated.
hl.on("workspace.active", function(ws)
    if ws.id ~= WS_ID then return end

    local ws_obj = hl.get_workspace(WS_ID)
    if not ws_obj then return end

    local has, pending_ff = { notion = false, pomo = false, tg = false }, 0
    for _, w in ipairs(ws_obj:get_windows()) do
        if isTelegram(w) then
            has.tg = true
        else
            local r = roleOf(w)
            if r then
                has[r] = true
            elseif (w.class or ""):lower() == "firefox" then
                -- Title not arrived yet; may be any of the firefox roles.
                pending_ff = pending_ff + 1
            end
        end
    end

    local want = {}
    if not has.notion then want[#want + 1] = NOTION_URL end
    if not has.pomo then want[#want + 1] = POMO_URL end
    local launch = math.max(0, #want - pending_ff)
    for i = 1, launch do
        hl.exec_cmd('firefox-pwa "' .. want[i] .. '"', { workspace = tostring(WS_ID) })
    end

    if not has.tg then
        hl.exec_cmd("env GDK_BACKEND=x11 QT_QPA_PLATFORM=xcb WEBKIT_DISABLE_DMABUF_RENDERER=1 Telegram")
    end
end)
