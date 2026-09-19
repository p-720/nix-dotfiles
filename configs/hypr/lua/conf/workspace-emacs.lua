-- -- special:emacs layout — [Notion Calendar 20% | Pomotask 20% | Emacs 60%]
-- --
-- -- Windows are identified by role (roleOf) and placed in fixed columns;
-- -- unrecognized windows stack in the emacs column.
-- --
-- -- Columns must stay adjacent (gap <= 2px): Hyprland's movefocus only
-- -- considers windows within 2px of each other (isAdjacent, Compositor.cpp),
-- -- so mod+h/j/k/l navigation breaks if visible gaps are introduced here.

-- local WS_NAME  = "special:emacs"
-- local URL_CAL  = "https://calendar.notion.so/"
-- local URL_POMO = "https://ug.kyrgyzstan.kg/pomotask/"
-- local SHARES   = { cal = 0.2, pomo = 0.2, emacs = 0.6 }

-- -- The firefox windows share one class and the same initial title, so the
-- -- first real title a window shows pins its role. [address] = { role, pid }.
-- local identity = {}

-- local function classOf(w)
--     return (w.class or ""):lower()
-- end

-- local function roleOf(w)
--     local cl, t = classOf(w), (w.title or ""):lower()

--     if cl == "emacs" then
--         if t:find("emacs") or t == "" then
--             return "emacs"
--         end
--         return nil
--     end

--     if cl ~= "firefox" then
--         return nil
--     end

--     local rec = identity[w.address]
--     if rec and rec.pid == w.pid then
--         return rec.role
--     end

--     if t:find("notion calendar") or t:find("calendar") then
--         identity[w.address] = { role = "cal", pid = w.pid }
--         return "cal"
--     elseif t:find("pomotask") then
--         identity[w.address] = { role = "pomo", pid = w.pid }
--         return "pomo"
--     end

--     return nil
-- end

-- -- Focus the role-matched emacs window in this workspace.
-- local function focusEmacs()
--     local ws = hl.get_workspace(WS_NAME)
--     if not ws then return end
--     for _, w in ipairs(ws:get_windows()) do
--         if roleOf(w) == "emacs" then
--             hl.dispatch(hl.dsp.focus({ window = w }))
--             return
--         end
--     end
-- end

-- -- Split the workspace area into the three fixed columns.
-- local function columnsFor(area)
--     local cal_w  = area.w * SHARES.cal
--     local pomo_w = area.w * SHARES.pomo
--     return {
--         cal   = { x = area.x, y = area.y, w = cal_w, h = area.h },
--         pomo  = { x = area.x + cal_w, y = area.y, w = pomo_w, h = area.h },
--         emacs = { x = area.x + cal_w + pomo_w, y = area.y, w = area.w - cal_w - pomo_w, h = area.h },
--     }
-- end

-- hl.layout.register("emacs3", {
--     recalculate = function(ctx)
--         local slots, unclassified, strays = {}, {}, {}

--         -- First target per role wins; unclassified firefox (title not
--         -- arrived yet) is kept separate so it can fill an empty slot.
--         for _, target in ipairs(ctx.targets) do
--             local w = target.window
--             if w then
--                 local r = roleOf(w)
--                 if not r then
--                     if classOf(w) == "firefox" then
--                         unclassified[#unclassified + 1] = target
--                     else
--                         strays[#strays + 1] = target
--                     end
--                 elseif not slots[r] then
--                     slots[r] = target
--                 else
--                     strays[#strays + 1] = target
--                 end
--             end
--         end

--         for _, role in ipairs({ "cal", "pomo" }) do
--             if not slots[role] and unclassified[1] then
--                 slots[role] = table.remove(unclassified, 1)
--             end
--         end
--         for _, target in ipairs(unclassified) do
--             strays[#strays + 1] = target
--         end

--         local cols = columnsFor(ctx.area)
--         if slots.cal  then slots.cal:place(cols.cal)  end
--         if slots.pomo then slots.pomo:place(cols.pomo) end

--         -- Emacs plus anything unrecognized share the right column, stacked.
--         if slots.emacs then
--             local stack = { slots.emacs }
--             for _, t in ipairs(strays) do stack[#stack + 1] = t end
--             local slice = cols.emacs.h / #stack
--             for i, t in ipairs(stack) do
--                 t:place({ x = cols.emacs.x, y = cols.emacs.y + (i - 1) * slice, w = cols.emacs.w, h = slice })
--             end
--         end
--     end,

--     -- Returning true makes the layout recalculate after the message,
--     -- which is how "refresh" (dispatched on title change) re-tiles.
--     layout_msg = function()
--         return true
--     end,
-- })

-- -- PWA fake-fullscreen for the firefox windows; focus emacs when it opens.
-- hl.on("window.open", function(w)
--     if not (w.workspace and w.workspace.name == WS_NAME) then return end
--     if classOf(w) == "emacs" then
--         focusEmacs()
--     elseif classOf(w) == "firefox" then
--         hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 2, window = w }))
--     end
-- end)

-- -- Re-tile when a title arrives late (identities are title-based).
-- local focused_mon
-- hl.on("monitor.focused", function(m)
--     focused_mon = m and m.name
-- end)

-- hl.on("window.title", function(w)
--     local ws = w.workspace
--     if not (ws and ws.name == WS_NAME and ws.active) then return end
--     if focused_mon and w.monitor and w.monitor.name ~= focused_mon then return end
--     hl.dispatch(hl.dsp.layout("refresh"))
-- end)

-- hl.on("window.close", function(w)
--     identity[w.address] = nil
-- end)

-- -- Spawn whatever is missing when the workspace is (re)created.
-- hl.on("workspace.created", function(ws)
--     if ws.name ~= WS_NAME then return end

--     local has, pending_ff = { cal = false, pomo = false, emacs = false }, 0
--     for _, w in ipairs(ws:get_windows()) do
--         local r = roleOf(w)
--         if r then
--             has[r] = true
--         elseif classOf(w) == "firefox" then
--             pending_ff = pending_ff + 1
--         end
--     end

--     local want = {}
--     if not has.cal then want[#want + 1] = URL_CAL end
--     if not has.pomo then want[#want + 1] = URL_POMO end
--     local launch = math.max(0, #want - pending_ff)
--     for i = 1, launch do
--         hl.exec_cmd('firefox --new-window "' .. want[i] .. '"', { workspace = WS_NAME })
--     end

--     if has.emacs then
--         focusEmacs()
--     else
--         hl.exec_cmd("emacsclient -c -F '((name . \"emacs-todo\"))'")
--     end
-- end)
