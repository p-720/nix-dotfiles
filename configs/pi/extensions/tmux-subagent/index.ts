import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { CONFIG_DIR_NAME, createAgentSession, type ExtensionAPI, type Session } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// Spawns a full interactive pi session in a tmux pane to the right of this
// one, blocks until it finishes, returns its final answer, then closes the pane.
// One subagent at a time.

const MAX_AGE_MS = 30 * 60 * 1000; // hard cap
const QUIET_DONE_MS = 5000; // final answer, then N ms of silence = done
const STALL_MS = 30 * 1000; // silence while tools were in flight = stalled
const TICK_MS = 1500;

let active: { pane: string; started: number } | null = null;

// node:child_process, not Bun.spawnSync — the reload path loads extensions
// in a context without the Bun global
function run(cmd: string): string {
	const r = spawnSync("bash", ["-c", cmd], { encoding: "utf8" });
	return `${r.stdout ?? ""}${r.stderr ?? ""}`;
}
const sh = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

function ownPane(): string {
	// TMUX_PANE is frozen at session start; tmux renumbers panes on close,
	// so verify it and fall back to matching my process tree against panes
	const envPane = process.env.TMUX_PANE;
	if (envPane) {
		const ids = run(`tmux list-panes -a -F '#{pane_id}' 2>/dev/null`);
		if (ids.split("\n").includes(envPane)) return envPane;
	}
	let pid = process.pid;
	for (let i = 0; i < 10; i++) {
		const ppid = run(`ps -o ppid= -p ${pid} 2>/dev/null`).trim();
		if (!ppid || ppid === "0" || ppid === "1") break;
		pid = Number(ppid);
		const match = run(`tmux list-panes -a -F '#{pane_id} #{pane_current_pid}' 2>/dev/null`)
			.split("\n")
			.map((l) => l.trim().split(/\s+/))
			.find((p) => p[1] === String(pid));
		if (match) return match[0];
	}
	return envPane ?? "";
}

function sessionsRoot(): string {
	return path.join(os.homedir(), CONFIG_DIR_NAME, "agent", "sessions");
}

// pi truncates session names to 50 chars in the file, so match prefix-tolerantly
const isSameName = (a: string, b: string) => a === b || a.startsWith(b) || b.startsWith(a);

// first 20 lines carry the session header (id) and, if set, session_info (name)
function readHeader(file: string): { name: string | null; id: string | null } {
	let text = "";
	try {
		text = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).slice(0, 20).join("\n");
	} catch {
		return { name: null, id: null };
	}
	let name: string | null = null;
	let id: string | null = null;
	for (const line of text.split("\n")) {
		let e: any;
		try { e = JSON.parse(line); } catch { continue; }
		if (e.type === "session_info" && typeof e.name === "string" && name === null) name = e.name;
		if (typeof e.id === "string" && id === null) id = e.id;
		if (name !== null && id !== null) break;
	}
	return { name, id };
}

// Name match only: the replica's file carries the --name we passed.
// No "freshest file" fallback — that would pick our own session file,
// which is the freshest one of all.
function findReplicaSessionFile(sinceMs: number, name: string, selfFile: string | null, selfId: string | null): string | null {
	const root = sessionsRoot();
	let dirs: string[] = [];
	try {
		dirs = fs.readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
	} catch {
		dirs = [];
	}
	let best: { file: string; m: number } | null = null;
	for (const d of dirs) {
		let files: string[] = [];
		try { files = fs.readdirSync(path.join(root, d)); } catch { continue; }
		for (const f of files) {
			if (!f.endsWith(".jsonl")) continue;
			const file = path.join(root, d, f);
			let st: fs.Stats;
			try { st = fs.statSync(file); } catch { continue; }
			const mtime = st.mtimeMs;
			if (mtime <= sinceMs) continue; // only files touched since the spawn
			if (selfFile && file === selfFile) continue;
			const header = readHeader(file);
			if (selfId && header.id === selfId) continue;
			if (header.name !== null && isSameName(header.name, name)) {
				if (!best || mtime > best.m) best = { file, m: mtime };
			}
		}
	}
	return best?.file ?? null;
}

// last entry decides: final answer vs. tools in flight
function lastState(file: string): "final" | "toolRunning" | "unknown" {
	const content = fs.readFileSync(file, "utf8");
	const lines = content.split("\n").filter((l) => l.trim().length > 0);
	for (let i = lines.length - 1; i >= 0; i--) {
		let e: any;
		try { e = JSON.parse(lines[i]); } catch { continue; }
		if (e.type === "message" && e.message?.role === "assistant") {
			const calls = e.message.content?.filter((c: any) => c.type === "toolCall") ?? [];
			return calls.length > 0 ? "toolRunning" : "final";
		}
	}
	return "unknown";
}

function extractAnswer(file: string): string {
	const lines = fs.readFileSync(file, "utf8").split("\n").filter((l) => l.trim().length > 0);
	const texts: string[] = [];
	for (const line of lines) {
		let e: any;
		try { e = JSON.parse(line); } catch { continue; }
		if (e.type === "message" && e.message?.role === "assistant" && e.message.stopReason === "stop") {
			for (const c of e.message.content ?? []) {
				if (c.type === "text" && c.text.trim()) texts.push(c.text.trim());
			}
		}
	}
	if (texts.length === 0) return "(no final answer found in session)";
	return texts[texts.length - 1];
}

async function waitReplica(file: string, started: number, signal: AbortSignal | undefined): Promise<string> {
	let lastActivity = Date.now();
	let quietSince: number | null = null;
	let lastStateSeen: "final" | "toolRunning" | "unknown" = "unknown";
	while (!signal?.aborted) {
		if (Date.now() - started > MAX_AGE_MS) throw new Error("30 minute cap reached");
		try {
			const mtime = fs.statSync(file).mtimeMs;
			if (mtime > lastActivity) {
				lastActivity = mtime;
				quietSince = null;
			}
			const st = lastState(file);
			if (st !== lastStateSeen) {
				lastStateSeen = st;
				quietSince = null; // restart the quiet window on state change
			}
			if (st === "final") {
				quietSince = quietSince ?? Date.now();
				if (Date.now() - quietSince >= QUIET_DONE_MS) return extractAnswer(file);
			} else if (st === "toolRunning") {
				// work in flight: long-running tools are fine, no stall timer
			} else if (Date.now() - lastActivity > STALL_MS) {
				throw new Error(`subagent stalled: ${Math.round(STALL_MS / 1000)}s of silence with no final answer`);
			}
		} catch (e: any) {
			if (e.message === "ENOENT") throw new Error("subagent session file disappeared");
			throw e;
		}
		await new Promise((r) => setTimeout(r, TICK_MS));
	}
	throw new Error("aborted");
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "tmux_subagent_spawn",
		label: "tmux_subagent_spawn",
		description:
			"Spawn a full pi session (your model, all tools) in a tmux pane to the right of this one. " +
			"BLOCKS until the subagent finishes, then returns its final answer and closes the pane. " +
			"Only one subagent may run at a time.",
		parameters: Type.Object({
			task: Type.String({ description: "The task for the subagent, self-contained (it has no context from this session)" }),
			cwd: Type.Optional(Type.String({ description: "Working directory for the subagent (default: this session's cwd)" })),
			model: Type.Optional(Type.String({ description: "Model override as \"provider/id\". Default: same model as this session." })),
		}),
		async execute(_id, params, signal, _onUpdate, ctx) {
			if (active) {
				const secs = Math.round((Date.now() - active.started) / 1000);
				return {
					content: [{ type: "text", text: `A subagent is already running (pane ${active.pane}, ${secs}s). One at a time — wait for it to finish or kill it with tmux_subagent_kill.` }],
					details: undefined,
				};
			}

			const pane = ownPane();
			if (!pane) throw new Error("TMUX_PANE not set — this session is not inside tmux");
			// quote #{pane_id}: an unquoted # starts a shell comment in bash -c
			const splitCmd = `tmux split-window -h -P -F '#{pane_id}' -t ${sh(pane)} -c ${sh(params.cwd ?? process.cwd())} 2>&1`;
			const sr = spawnSync("bash", ["-c", splitCmd], { encoding: "utf8" });
			const split = `${sr.stdout ?? ""}${sr.stderr ?? ""}`;
			const newPane = split.trim().split("\n")[0];
			if (!/^%\d+$/.test(newPane))
				throw new Error(
					`tmux split-window failed: [status=${sr.status} signal=${sr.signal} err=${String(sr.error)} bun=${typeof (globalThis as any).Bun} tmux=${process.env.TMUX ?? "UNSET"} pane=${pane}] cmd=${splitCmd} out=${split.trim()}`,
				);

			const name = `subagent: ${params.task}`.slice(0, 80);
			// print mode: task is an arg, pi exits when done. Wrapped in bash -c
			// because the pane's shell may be fish, where "( )" in the task text
			// would parse as command substitution
			const inner = `pi --name ${sh(name)}${params.model ? ` --model ${sh(params.model)}` : ""} -p ${sh(params.task)}`;
			const outer = `bash -c ${sh(inner)}`;
			run(`tmux send-keys -t ${newPane} ${sh(outer)} Enter`);

			active = { pane: newPane, started: Date.now() };
			const startedAt = active.started;
			let answer = "";
			try {
				const selfFile = process.env.PI_SESSION_FILE ?? null;
				const selfId = process.env.PI_SESSION_ID ?? null;

				// wait for the replica's session file to appear (max 30s)
				let file: string | null = null;
				for (let i = 0; i < 20 && !file && !signal?.aborted; i++) {
					file = findReplicaSessionFile(active.started - 2000, name, selfFile, selfId);
					if (!file) await new Promise((r) => setTimeout(r, 1500));
				}
				if (!file) {
					throw new Error(
						`no session file appeared (self file: ${selfFile ?? "UNKNOWN"}, self id: ${selfId ?? "UNKNOWN"}; pane: ${newPane})`,
					);
				}

				ctx.ui?.setStatus("subagent", `subagent running… 0s`);
				const updateStatus = () => {
					ctx.ui?.setStatus("subagent", `subagent running… ${Math.round((Date.now() - active!.started) / 1000)}s`);
				};
				const interval = setInterval(updateStatus, 5000);

				answer = await waitReplica(file, active.started, signal);

				clearInterval(interval);
				ctx.ui?.setStatus("subagent", null as any);
			} catch (e: any) {
				const detail = `(watching self file: ${process.env.PI_SESSION_FILE ?? "UNKNOWN"}, self id: ${process.env.PI_SESSION_ID ?? "UNKNOWN"}; pane: ${newPane})`;
				if (signal?.aborted) throw new Error(`Subagent aborted after ${Math.round((Date.now() - active.started) / 1000)}s; pane killed. ${detail}`);
				throw new Error(`Subagent failed: ${e.message ?? e}. ${detail}`);
			} finally {
				run(`tmux kill-pane -t ${newPane} 2>/dev/null`);
				active = null;
			}

			return {
				content: [{ type: "text", text: answer }],
				details: { pane: newPane, durationSec: Math.round((Date.now() - startedAt) / 1000) },
			};
		},
	});

	pi.registerTool({
		name: "tmux_subagent_kill",
		label: "tmux_subagent_kill",
		description: "Kill the currently running subagent pane (its blocking spawn then returns early).",
		parameters: Type.Object({
			pane: Type.String({ description: "tmux pane id, e.g. %7" }),
		}),
		async execute(_id, params) {
			if (active && active.pane === params.pane) {
				run(`tmux kill-pane -t ${params.pane} 2>/dev/null`);
				return {
					content: [{ type: "text", text: `Subagent pane ${params.pane} killed; its blocking spawn will return.` }],
					details: undefined,
				};
			}
			if (active) {
				return {
					content: [{ type: "text", text: `The running subagent is pane ${active.pane}, not ${params.pane}.` }],
					details: undefined,
				};
			}
			return { content: [{ type: "text", text: "No subagent is running." }], details: undefined };
		},
	});
}
