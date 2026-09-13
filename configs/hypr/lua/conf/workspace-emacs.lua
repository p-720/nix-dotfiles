-- special:emacs layout — [Notion Calendar 20% | Pomotask 20% | Emacs 60%]

local WS_NAME  = "special:emacs"
local URL_CAL  = "https://calendar.notion.so/"
local URL_POMO = "https://ug.kyrgyzstan.kg/pomotask/"
local SHARES   = { cal = 0.2, pomo = 0.2, emacs = 0.6 }
local INSET    = 2.5

local identity = {} -- [address] = { role = "cal"|"pomo", pid = n }

local function roleOf(w)
    local t = (w.title or ""):lower()
    
    -- 1. Check Emacs
    if w.class == "emacs" or w.class == "Emacs" then
        if t:find("emacs%-todo") or t:find("emacs") or t == "" then
            return "emacs"
        end
    end

    if w.class ~= "firefox" and w.class ~= "Firefox" then
        return nil
    end

    -- 2. Check cached identity
    local rec = identity[w.address]
    if rec and rec.pid == w.pid then
        return rec.role
    end

    -- 3. Match by Title
    if t:find("notion calendar") or t:find("calendar") then
        identity[w.address] = { role = "cal", pid = w.pid }
        return "cal"
    elseif t:find("pomotask") then
        identity[w.address] = { role = "pomo", pid = w.pid }
        return "pomo"
    end

    return nil
end

local function inset(b)
    return { x = b.x + INSET, y = b.y + INSET, w = b.w - 2 * INSET, h = b.h - 2 * INSET }
end

hl.layout.register("emacs3", {
    recalculate = function(ctx)
        local cal, pomo, emacs, others = nil, nil, nil, {}
        local unclassified_ff = {}

        for _, target in ipairs(ctx.targets) do
            local w = target.window
            if w then
                local r = roleOf(w)
                if r == "cal" and not cal then cal = target
                elseif r == "pomo" and not pomo then pomo = target
                elseif r == "emacs" and not emacs then emacs = target
                elseif (w.class == "firefox" or w.class == "Firefox") and not r then
                    unclassified_ff[#unclassified_ff + 1] = target
                else 
                    others[#others + 1] = target 
                end
            end
        end

        -- Temporarily assign loading Firefox windows to missing slots (cal/pomo)
        if not cal and #unclassified_ff > 0 then
            cal = table.remove(unclassified_ff, 1)
        end
        if not pomo and #unclassified_ff > 0 then
            pomo = table.remove(unclassified_ff, 1)
        end
        for _, target in ipairs(unclassified_ff) do
            others[#others + 1] = target
        end

        local area = ctx.area
        local T = { cal = cal, pomo = pomo, emacs = emacs }

        -- Hardcoded Left / Middle / Right horizontal layout allocation
        local cal_w   = area.w * SHARES.cal
        local pomo_w  = area.w * SHARES.pomo
        local emacs_w = area.w - cal_w - pomo_w

        local cols = {
            cal   = { x = area.x, y = area.y, w = cal_w, h = area.h },
            pomo  = { x = area.x + cal_w, y = area.y, w = pomo_w, h = area.h },
            emacs = { x = area.x + cal_w + pomo_w, y = area.y, w = emacs_w, h = area.h },
        }

        -- Place recognized roles
        if T.cal then T.cal:place(inset(cols.cal)) end
        if T.pomo then T.pomo:place(inset(cols.pomo)) end

        -- Stack Emacs + any extra/unrecognized windows in the right column (60% width)
        local right_stack = {}
        if T.emacs then right_stack[#right_stack + 1] = T.emacs end
        for _, ot in ipairs(others) do right_stack[#right_stack + 1] = ot end

        if #right_stack > 0 then
            local slice = cols.emacs.h / #right_stack
            local y = cols.emacs.y
            for _, target in ipairs(right_stack) do
                target:place(inset({ x = cols.emacs.x, y = y, w = cols.emacs.w, h = slice }))
                y = y + slice
            end
        end
    end,

    layout_msg = function()
        return true
    end,
})

-- PWA mode for Firefox
hl.on("window.open", function(w)
    if not (w.workspace and w.workspace.name == WS_NAME) then return end
    if w.class ~= "firefox" and w.class ~= "Firefox" then return end
    hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 2, window = w }))
end)

-- Title change listener triggers relayout
local focused_mon
hl.on("monitor.focused", function(m)
    focused_mon = m and m.name
end)

hl.on("window.title", function(w)
    if not (w.workspace and w.workspace.name == WS_NAME and w.workspace.active) then return end
    if focused_mon and w.monitor and w.monitor.name ~= focused_mon then return end
    hl.dispatch(hl.dsp.layout("refresh"))
end)

hl.on("window.close", function(w)
    identity[w.address] = nil
end)

hl.on("workspace.created", function(ws)
    if ws.name ~= WS_NAME then return end

    local has, unknown = { cal = false, pomo = false, emacs = false }, 0
    for _, w in ipairs(ws:get_windows()) do
        local r = roleOf(w)
        if r == "cal" then has.cal = true
        elseif r == "pomo" then has.pomo = true
        elseif r == "emacs" then has.emacs = true
        elseif w.class == "firefox" or w.class == "Firefox" then unknown = unknown + 1
        end
    end

    local want = {}
    if not has.cal then want[#want + 1] = "cal" end
    if not has.pomo then want[#want + 1] = "pomo" end
    local launch = math.min(#want, math.max(0, #want - unknown))
    for i = 1, launch do
        local url = want[i] == "cal" and URL_CAL or URL_POMO
        hl.exec_cmd('firefox --new-window "' .. url .. '"', { workspace = WS_NAME })
    end

    if not has.emacs then
        hl.exec_cmd("emacsclient -c -F '((name . \"emacs-todo\"))'")
    end
end)
