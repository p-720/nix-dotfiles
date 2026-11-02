## Core environment

- The user runs **NixOS**. Assume NixOS unless told otherwise.
- Prefer concise, technical answers. Make progress instead of asking unnecessary questions.
- Inspect the existing project and environment before making changes. Do not guess at file contents, tool behavior, or system state.
- Use at most **1 subagent at a time**. Never run multiple agents in parallel.
- Prefer small, targeted changes. Avoid unrelated refactors.

## 1. Comments: explain WHY, never WHAT

**NEVER leave comments that only explain what the code does. Comments must explain why a decision was made.**

Useless — delete these:

- Narrating the next line: `// Cancel any pending restore` above `resetDelegate.RunTask()`.
- Section labels: `// Pass: results are being shown.`
- Restating the code: `// Add RandomV2 settings panel when the mod is active` above `if (Mods.OfType<OsuModRandomV2>() ...)`.
- Dead commented-out code blocks.
- Personal scratch notes.

Needed — keep these:

- Why this approach over the obvious one: `// LegacyScoreEncoder refuses non-legacy rulesets, so encode under the osu! ruleset identity`.
- What breaks if changed: `// self-remove on fire, or this lambda (capturing the player) pins the ruleset tree until session end`.
- Non-obvious constraints: `// NOTE cant alias - crashes without`.
- Non-obvious ordering or timing: `// BreakOverlay is assigned near the end of Player.load, which may run after this`.
- Contracts other callers rely on: `// idempotent: safe to call from the notification, results, and dispose paths`.
- Why the obvious thing is deliberately not done: `// deliberately not routed through the seek controller: must keep working while the setting is off`.

**Test:** Delete the comment in your head. If no answer to "why is it written this way?" is lost, the comment is useless.

Keep why-comments to 1–3 lines. A 5-line why is a design problem, not a comment problem.

Style: simple caveman. Short words, blunt, no filler.

Good: `// NOTE cant alias - crashes without`

Bad: `// Please note that an alias cannot be used here because the application will crash when it is absent`.

## 2. Shell commands and file search

- **NEVER use `find` or `grep** in shell commands.
- **ALWAYS use `fd`** to search for files.
- **ALWAYS use `rg` (ripgrep)** to search file contents.
- Do not use `find` or `grep` out of habit, including inside pipelines or scripts. Replace them with `fd` and `rg`.
- Use `rg` filters and globs to narrow searches instead of dumping huge amounts of output.
- Prefer targeted commands and limited output.
- Do not blindly read huge directories or entire log files.

Examples:

```bash
fd 'filename' .
fd -e cs .
fd -t f -g '*.toml' .
rg -n 'SomeSymbol' src/
rg -n -i 'error|failed|warning' logs/
rg -l 'SomeSymbol' .
```

## 3. Linux and NixOS rules

- Treat the system as NixOS, not Ubuntu or Debian.
- Do not suggest `apt`, `apt-get`, or other distribution-specific package managers.
- Check whether a command exists before relying on it:

```bash
command -v tool
```

- When a diagnostic tool is missing, prefer a temporary Nix environment instead of changing the user's system:

```bash
nix shell nixpkgs#tool -c tool --help
```

- Do not assume the user uses a particular desktop environment, window manager, display server, GPU, or audio stack. Inspect first.
- Prefer declarative NixOS configuration for persistent system changes. Do not edit unrelated system configuration.
- Do not run destructive commands, rebuild the system, restart critical services, or change boot settings without a clear reason.

## 4. ABSOLUTELY NO VISION

**This agent is text-only. NEVER use vision or image-based reasoning.**

- Never invoke image, vision, multimodal, OCR, screenshot-analysis, or image-understanding tools.
- Never ask the user to upload a screenshot.
- Never use a screenshot as the basis for a diagnosis.
- Do not attempt to infer UI state, errors, layout, or system behavior from pixels.
- If an image or screenshot is supplied, do not inspect it. Ask for the relevant text output, error message, or a description of the observed behavior.
- Do not use image generation or image editing tools.
- Do not pretend to have seen something that you cannot inspect.

**Use these alternatives instead:**

- Logs and error messages.
- Process and service state.
- Kernel messages and driver information.
- `/proc`, `/sys`, and `/run`.
- Command-line diagnostic utilities.
- Window manager and compositor IPC.
- X11 properties and window trees.
- Wayland protocol and compositor interfaces where available.
- Browser accessibility trees, DOM inspection, JavaScript console output, and computed styles.
- Reproduction steps and controlled experiments.

A visual problem is still debuggable without looking at a screenshot. Find measurable evidence.

## 5. Linux debugging workflow

**Do not guess. Gather evidence, form a hypothesis, test it, and report what the evidence shows.**

Use this general workflow:

1. Reproduce the problem and identify exactly what fails.
2. Inspect the relevant processes, services, logs, and configuration.
3. Check the relevant kernel, device, and subsystem state.
4. Form one or more specific hypotheses.
5. Run the smallest diagnostic that distinguishes between them.
6. Make a targeted fix.
7. Re-test and verify the result.

Start with basic system information when relevant:

```bash
uname -a
nixos-version
nix --version
printf 'Session: %s\nDesktop: %s\nWayland: %s\n' \
  "$XDG_SESSION_TYPE" "$XDG_CURRENT_DESKTOP" "$WAYLAND_DISPLAY"
lspci -nnk
lsmod
```

### Logs and services

Use `journalctl` before guessing:

```bash
journalctl -b -p warning..alert
journalctl -b -k
journalctl --user -b
systemctl --failed
systemctl status SERVICE
systemctl --user status SERVICE
```

Check the relevant service logs and boot messages. Filter with `rg` when needed.

### Processes and system state

```bash
ps -eo pid,ppid,stat,%cpu,%mem,comm --sort=-%cpu
pgrep -a PROCESS
ss -tulpn
ip -brief addr
ip route
```

Use `/proc` and `/sys` to inspect kernel and device state. Read the relevant files directly instead of relying on assumptions.

### GPU and graphics

Inspect the actual driver and hardware:

```bash
lspci -nnk
lsmod
journalctl -b -k
ls -la /sys/class/drm/
```

When available, use appropriate text-based tools such as:

- `glxinfo` for OpenGL.
- `vulkaninfo` for Vulkan.
- `vainfo` for VA-API.
- `modetest` for DRM/KMS.
- `udevadm` for device information.

Check whether the application is using hardware acceleration, which driver it loaded, and whether the kernel reported faults.

### X11 debugging

Never diagnose X11 problems by looking at screenshots. Inspect the actual X server state:

```bash
xrandr --query
xrandr --verbose
xprop -root
xwininfo -root -tree
wmctrl -lG
xset q
```

Use X11 properties, window geometry, window trees, outputs, modes, EDID data, and Xorg logs to isolate problems.

### Wayland debugging

Do not assume all Wayland compositors expose the same interfaces.

Use whichever tools the active compositor supports:

- `wayland-info` for Wayland protocol information.
- `wlr-randr` for compatible wlroots output management.
- `swaymsg -t get_outputs -r` and other compositor IPC commands for Sway.
- Compositor-specific IPC and logs for other compositors.
- `loginctl` and environment variables to inspect the session.

Check the compositor process, output state, active session, environment, and relevant user services.

### Browser and UI debugging

Use text-based browser inspection:

- Accessibility snapshots and element roles.
- DOM structure and attributes.
- JavaScript console output.
- Network and request failures where available.
- Computed CSS and layout geometry.
- Element bounding boxes and scroll dimensions.
- Event listeners and application state.

Do not use screenshots or pixel analysis to diagnose browser issues.

## 6. External research

Use `ketch` for external research: web pages, open-source code, and library documentation.

```bash
ketch search "query"
ketch search "query" --scrape
ketch search "query" --multi
ketch scrape <url> [url...]
curl ... | ketch extract
ketch code "query" --lang go
ketch code "query" --repo owner/name
ketch docs "query" --library /org/repo
ketch config
```

- Use `ketch code` to find real implementations in open-source repositories.
- Use `ketch docs` for version-aware library documentation.
- Use `ketch scrape` when the full page content matters.
- Check the project's actual dependency versions before applying documentation for a different version.
- Do not invent APIs or assume that an implementation works a certain way without checking.

## 7. T3 Code tools

### Subagents and delegation

- `delegate_task` — spawn a child agent.
- **HARD LIMIT: 1 active subagent at any time.**
- Never launch agents in parallel or use batch delegation to launch multiple agents.
- Wait for the current agent to finish before launching another.
- Use `mode: 'wait'` when the current task needs the result. Use async only when there is useful independent work to continue without the result.
- Use `isolation: 'worktree'` for a separate checkout/PR when appropriate.
- Check `orchestrator_capabilities` before overriding the child model or its options.
- `task_status` — read a child's final result.
- `task_cancel` — stop a child and its sub-delegates.
- Do not let a child agent spawn additional agents. The total agent concurrency must remain one.

Use an agent only when delegation meaningfully helps. Do not spawn agents merely to increase activity. Give each agent a clear, isolated task.

### Threads and worktrees

- `t3_thread_launch` — launch a top-level thread.
- `create_threads` — create several threads in one call.
- `t3_thread_send` — send, steer, queue, or restart a thread.
- `t3_thread_read` and `t3_thread_wait` — read and wait for thread results.
- `t3_worktree_status` and `t3_worktree_list` — inspect thread worktrees.
- `t3_worktree_handoff` — move a thread onto a new branch.

**Concurrency rule applies here too:** Never have more than one active delegated agent/thread working at once. Do not use batch thread launches.

### Pull requests

- `link_pull_request` and `watch_pull_request` — link and monitor PRs.
- `write_pull_request_guides` and `read_pull_request_guide` — manage review guides.

### Secrets

Use `request_secret` for sudo passwords, API keys, tokens, and other secrets.

- Never ask the user to paste secrets into chat.
- Never invent credentials.
- Use `delivery: 'secretRef'` when the target tool accepts a secret reference.
- Use `delivery: 'file'` only when a command needs a file-based secret.
- Never print, log, or expose secret contents.

## 8. Browser automation

Use T3 `preview_*` tools first.

Available tools:

- `preview_open` / `preview_navigate` — open a page or dev-server URL.
- `preview_snapshot` — inspect the accessibility tree and element references.
- `preview_act` — click, type, hover, select, drag, upload, press, or scroll.
- `preview_evaluate` — inspect or execute JavaScript in the page.
- `preview_wait_for` — wait for a selector, text, or URL.
- `preview_resize` — change device dimensions.
- `preview_set_appearance` — switch dark or light mode.
- `preview_dialog` — handle JavaScript dialogs.
- `preview_recording_start` / `preview_recording_stop` — record browser interactions.
- `t3_preview_list` / `t3_preview_close` — manage tabs.

**Use accessibility and DOM data, not vision.**

- Prefer `preview_snapshot` to identify elements.
- Use `aria-ref` references with `preview_act`.
- Use `preview_evaluate` to inspect DOM state, computed styles, and element geometry.
- Use `preview_wait_for` instead of arbitrary delays.
- Do not inspect screenshots or use image-based browser automation.
- Fall back to the Playwright MCP only when T3 preview tools do not cover the case. Connect to it first.

## 9. HTML rendering

- Always run `html_preview` first.
- Use its textual console output and `contentHeight` result.
- **Never inspect or reason from the PNG returned by `html_preview`.**
- Debug layout through DOM inspection, computed CSS, and element geometry.
- Fix layout issues before using `html_render`.
- `html_render` shows the finished page inline.

HTML requirements:

- Full, self-contained HTML.
- Inline `<style>` and `<script>`.
- Use theme CSS variables from `:root`; do not hardcode fixed colors.
- No page background.
- Use fixed pixel heights where needed.
- Do not use `vh` or `100%` on `html` or `body`.
- Pass the `contentHeight` returned by `html_preview` to `html_render`.

## 10. Implementation and verification

- Read the surrounding code before editing.
- Follow existing project conventions unless there is a concrete reason not to.
- Check callers, interfaces, lifecycle, ownership, threading, and disposal behavior before changing code.
- Prefer the smallest change that fixes the root cause.
- Do not add abstractions without a real need.
- Do not add comments that merely narrate code.
- Run relevant tests, builds, formatters, and static checks after editing.
- If a check cannot run, explain exactly why.
- Never claim something works without verifying it.
- Report changed files, important decisions, and test results.
- Be blunt about uncertainty. Separate facts from hypotheses.

## 11. General behavior

- Do not ask questions when the repository or system can answer them.
- Do not make the user repeat information already provided.
- Do not make unrelated changes.
- Do not hide failed tests or incomplete work.
- Do not fabricate command output, tool results, source code, or verification.
- Prefer evidence over intuition.
- **No vision. No `find`. No `grep`. Maximum 1 active agent. Use `fd`, `rg`, and text-based Linux diagnostics.**
