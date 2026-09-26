
-- Named window rules
hl.window_rule({
    name = "emacs-todo-rules",
    match = { title = "emacs-todo" },
    no_anim = true,
})

hl.window_rule({
    name = "firefox-emacs-rules",
    match = { workspace = "special:emacs", class = "firefox" },
    no_anim = true,
})

-- Workspace assignments to special workspaces
hl.window_rule({ match = { class = "FFPWA-01KHERYP04RMDFAT6ATRJKE17V" }, workspace = "special:openai" })
hl.window_rule({ match = { class = "qbittorrent" }, workspace = "special:default" })
hl.window_rule({ match = { class = "brave-hmhokoodddibbngajkfamdbkehcjlikn-Default" }, workspace = "special:default", render_unfocused = true })
hl.window_rule({ match = { class = "brave-gemini.google.com__-Default" }, workspace = "special:default" })
hl.window_rule({ match = { title = "_crx_hmhokoodddibbngajkfamdbkehcjlikn" }, render_unfocused = true })

-- Special workspace toggle binds
hl.bind(mainMod .. " + o", hl.dsp.workspace.toggle_special("openai"))
hl.bind(mainMod .. " + u", hl.dsp.workspace.toggle_special("grok"))
hl.bind(mainMod .. " + i", hl.dsp.workspace.toggle_special("otherai"))
hl.bind(mainMod .. " + g", hl.dsp.workspace.toggle_special("gemini"))
hl.bind(mainMod .. " + b", hl.dsp.workspace.toggle_special("deepseek"))
hl.bind(mainMod .. " + m", hl.dsp.workspace.toggle_special("music"))
hl.bind("F12", hl.dsp.workspace.toggle_special("alacritty"))
hl.bind(mainMod .. " + c", hl.dsp.workspace.toggle_special("speedcrunch"))
hl.bind(mainMod .. " + n", hl.dsp.workspace.toggle_special("emacs"))
-- hl.bind(mainMod .. " + z", hl.dsp.workspace.toggle_special("default"))
-- hl.bind(mainMod .. " + z", hl.dsp.exec_cmd("/etc/nixos/configs/hypr/position-emacs.py"))

-- Workspace rules with gaps and on-created-empty
hl.workspace_rule({ workspace = "special:default", gaps_out = 50, gaps_in = 15 })
hl.workspace_rule({ workspace = "special:alacritty", gaps_out = 50, gaps_in = 10, on_created_empty = "foot"})
hl.workspace_rule({ workspace = "special:openai", gaps_out = 50, gaps_in = 10, on_created_empty = "firefox-pwa https://chatgpt.com/" })
hl.workspace_rule({ workspace = "special:grok", gaps_out = 50, gaps_in = 10, on_created_empty = "firefox-pwa https://grok.com/" })
hl.workspace_rule({ workspace = "special:otherai", gaps_out = 50, gaps_in = 15, on_created_empty = "firefox-pwa https://claude.ai/" })
hl.workspace_rule({ workspace = "special:deepseek", gaps_out = 50, gaps_in = 10, on_created_empty = "firefox-pwa https://chat.deepseek.com/" })
hl.workspace_rule({ workspace = "special:gemini", gaps_out = 50, gaps_in = 10, on_created_empty = "firefox --new-window \"https://gemini.google.com\" &" })
hl.workspace_rule({ workspace = "special:emacs", gaps_in = 2.5, gaps_out = { top = 25, right = 25, bottom = 25, left = 50 }, layout = "master", layout_opts = {orientation = "right"}, on_created_empty = "/etc/nixos/configs/hypr/workspace-emacs.sh",})
hl.workspace_rule({ workspace = "special:speedcrunch", gaps_out = { top = 200, right = 50, bottom = 300, left = 1500 }, on_created_empty = "speedcrunch" })
hl.workspace_rule({ workspace = "m[" .. monitor_1 .. "]s[true]n[e:speedcrunch]", gaps_out = { top = 250, right = 25, bottom = 250, left = 2090 } })
hl.workspace_rule({ workspace = "m[" .. monitor_2 .. "]s[true]n[e:speedcrunch]", gaps_out = { top = 250, right = 25, bottom = 250, left = 1450 } })
hl.workspace_rule({ workspace = "special:music", gaps_out = 25, gaps_in = 10, on_created_empty = "firefox-pwa https://open.spotify.com/" })
