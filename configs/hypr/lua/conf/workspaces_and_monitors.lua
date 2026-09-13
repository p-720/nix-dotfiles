
-- Monitor definitions
hl.monitor({ output = monitor_1, mode = "2560x1080@74.99Hz", position = "0x0", scale = 1})
hl.monitor({ output = monitor_2, mode = "preferred", position = "2560x0", scale = 1 })
hl.monitor({ output = test, disabled = true })
-- hl.monitor({ output = test, mode = "2000x1200@60.00Hz", position = "2000x1080", scale = 1})

-- Workspace rules (persistent)
for i = 1, 6 do
    hl.workspace_rule({ workspace = tostring(i), monitor = monitor_1, persistent = true })
end


for i = 7, 11 do
    hl.workspace_rule({ workspace = tostring(i), monitor = monitor_2, persistent = true })
end

hl.workspace_rule({ workspace = '1', default = true})
hl.workspace_rule({ workspace = '9', default = true})
hl.workspace_rule({ workspace = '11', layout = "lua:ff-tg" })
hl.workspace_rule({ workspace = '12', monitor = monitor_2, on_created_empty = "firefox-pwa https://web.max.ru/"})
