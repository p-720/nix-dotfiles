- **NEVER LEAVE `WHAT CODE DOES` COMMENTS ONLY DO `WHY THAT DECISION WAS MADE` COMMENTS**
  - Useless (delete): narrating the line — `// Cancel any pending restore` above `resetDelegate.RunTask()`; section labels — `// Pass: results are being shown.`; restating the code — `// Add RandomV2 settings panel when the mod is active` above `if (Mods.OfType<OsuModRandomV2>() ...)`; dead commented-out code blocks; personal scratch notes.
  - Needed (keep): why this approach over the obvious one — `// LegacyScoreEncoder refuses non-legacy rulesets, so encode under the osu! ruleset identity`; what breaks if you change it — `// self-remove on fire, or this lambda (capturing the player) pins the ruleset tree until session end`; `// NOTE cant alias - crashes without` (above a class declaration that looks alias-able but isn't); non-obvious ordering/timing — `// BreakOverlay is assigned near the end of Player.load, which may run after this`; contracts other callers rely on — `// idempotent: safe to call from the notification, results, and dispose paths`; why the obvious thing is deliberately NOT done — `// deliberately not routed through the seek controller: must keep working while the setting is off`.
  - Test: delete the comment in your head. If no answer to "why is it written this way?" is lost, the comment was useless. Keep why-comments to 1–3 lines — a 5-line why is a design problem, not a comment problem.
  - Style: simple caveman. Short words, blunt, no filler — `// NOTE cant alias - crashes without`, never `// Please note that an alias cannot be used here because the application will crash when it is absent`.
- **NEVER use `find` or `grep`** in shell commands. They are slower and produce noisy output.
- **ALWAYS use `fd`** to search for files (faster, ignores .gitignore, colorized output).
- **ALWAYS use `rg` (ripgrep)** to search file contents (faster, respects .gitignore, better filtering).
- Use subagents up to 4 (parallelizing work actually more tokens per second)
- For browser automation use T3 `preview_*` tools first; fall back to the playwright MCP (connect first) if they don't cover the case.
- This is a hard rule, not a suggestion. Replace any instinct to use `find`/`grep` immediately.
- We're on NixOS

Use `ketch` for external research — web pages, OSS code, library docs.
- `ketch search "query"` / `ketch search "query" --scrape` for web results with optional full content (add `--multi` to federate across backends and rank-fuse)
- `ketch scrape <url> [url...]` for clean markdown from one or more URLs
- `ketch extract` for already-fetched/piped HTML (`curl ... | ketch extract`) — no fetch, no cache, no browser
- `ketch code "query" --lang go` for real OSS code with repo/line context; `--repo owner/name` searches one repository
- `ketch docs "query" --library /org/repo` for version-aware library docs
- All commands support `--json`. `ketch config` reports active backends.

## T3 Code tools

- **Subagents / delegation**
  - `delegate_task` — spawn a child agent. `mode:'wait'` only when this turn needs the result, else async. `isolation:'worktree'` for a separate checkout/PR per child. `target:{model, options}` overrides the inherited model — check `orchestrator_capabilities` first for what providers/models/options exist.
  - `task_status` — read a child's final result (marks it delivered). `task_cancel` — stop it and its sub-delegates.
  - Top-level threads: `t3_thread_launch` (one) / `create_threads` (batch). Drive with `t3_thread_send` (auto/steer/queue/restart), `t3_thread_read`, `t3_thread_wait`.
  - Threads can carry worktrees: `t3_worktree_status` / `t3_worktree_list` / `t3_worktree_handoff` (moves this thread onto a new branch).
  - PRs: `link_pull_request` + `watch_pull_request` (wakes on failed checks, new comments, conflicts); `write_pull_request_guides` / `read_pull_request_guide` for AI review guides.
  - **Secrets: `request_secret`** — for sudo passwords, API keys, tokens, anything sensitive.
    - Never ask for a secret in chat and never invent one — call `request_secret` with a `label` and `reason`.
    - The user types it into a private card; I never see the value.
    - `delivery:'secretRef'` (default) — returns a one-use ref to pass into a T3 tool that accepts it.
    - `delivery:'file'` — returns a path to read inside a shell command: `TOKEN="$(cat <file>)" wrangler whoami`, `echo "$(cat <file>)" | sudo -S <cmd>`.
    - `timeoutMs` bounds the wait (default 10 min); after a timeout/cancel, a new `clientRequestId` is needed.
- **Browser (preview_*)**
  - `preview_open` / `preview_navigate` — open a tab; URL or environment dev-server port.
  - `preview_snapshot` — accessibility tree with refs; target actions via `locator='aria-ref=<ref>'`.
  - `preview_act` — click / type / hover / select / drag / upload / press / scroll. `preview_evaluate` — run JS in the page. `preview_wait_for` — wait on selector/text/URL.
  - `preview_resize` (device presets), `preview_set_appearance` (dark/light), `preview_dialog` (accept/dismiss JS dialogs), `preview_recording_start` / `preview_recording_stop`.
  - `t3_preview_list` / `t3_preview_close` — manage this thread's tabs.
- **html_render**
  - Always `html_preview` first — returns PNG, console output, and contentHeight; fix layout before showing the user anything.
  - `html_render` — shows the finished page inline in the thread. Full self-contained HTML, inline `<style>`/`<script>`, theme CSS variables from `:root` (no fixed colors), no page background, fixed pixel heights (no vh / 100% on html/body), pass the contentHeight from `html_preview`.
