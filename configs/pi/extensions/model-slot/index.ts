// Gates one local model endpoint to one agent family at a time.
//
// The gate sits in pi, not in T3 Code: pi waits inside `before_provider_request` until the
// broker hands out a request slot, so a queued thread stays a live, running turn instead of a
// failed one, and T3 needs no change.

import fs from "node:fs";
import path from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { SlotClient, type SlotState, normalizeUrl } from "./client.ts";

interface SlotConfig {
	endpoints: (string | { url: string; maxConcurrent?: number })[];
	maxConcurrent: number;
	familyIdleGraceMs: number;
	humanHoldMs: number;
	notifyAfterMs: number;
	leaseTtlMs: number;
}

const DEFAULTS: SlotConfig = {
	endpoints: [],
	maxConcurrent: 1,
	familyIdleGraceMs: 10_000,
	humanHoldMs: 180_000,
	notifyAfterMs: 180_000,
	leaseTtlMs: 30_000,
};

function moduleDir(): string | null {
	const url = import.meta.url;
	if (typeof url !== "string" || !url.startsWith("file:")) return null;
	return path.dirname(url.replace(/^file:\/\//, ""));
}

function loadConfig(): SlotConfig {
	const dir = moduleDir();
	const candidates = [
		process.env.PI_SLOT_CONFIG,
		dir === null ? undefined : path.join(dir, "config.json"),
		path.join(process.env.HOME ?? "", ".pi/agent/_extensions/model-slot/config.json"),
	];
	for (const candidate of candidates) {
		if (!candidate) continue;
		try {
			const raw = JSON.parse(fs.readFileSync(candidate, "utf8")) as Partial<SlotConfig>;
			return { ...DEFAULTS, ...raw };
		} catch {
			// Try the next candidate.
		}
	}
	const fromEnv = process.env.PI_SLOT_ENDPOINTS?.trim();
	if (fromEnv) return { ...DEFAULTS, endpoints: fromEnv.split(",").map((entry) => entry.trim()).filter(Boolean) };
	return { ...DEFAULTS };
}

function endpointKeys(cfg: SlotConfig): string[] {
	return cfg.endpoints.map((entry) => normalizeUrl(typeof entry === "string" ? entry : entry.url)).filter(Boolean);
}

function gatedEndpoint(cfg: SlotConfig, baseUrl: string | undefined): string | null {
	if (!baseUrl) return null;
	const key = normalizeUrl(baseUrl);
	for (const configured of endpointKeys(cfg)) {
		if (key === configured || key.startsWith(`${configured}/`) || configured.startsWith(`${key}/`)) return configured;
	}
	return null;
}

function secondsOf(ms: number): string {
	return ms < 1000 ? "0s" : `${Math.round(ms / 1000)}s`;
}

function resultText(result: unknown): string {
	if (result === null || typeof result !== "object") return "";
	const record = result as Record<string, unknown>;
	const parts: string[] = [];
	const content = record.content;
	if (Array.isArray(content)) {
		for (const item of content) {
			if (item !== null && typeof item === "object" && (item as Record<string, unknown>).type === "text") {
				const text = (item as Record<string, unknown>).text;
				if (typeof text === "string") parts.push(text);
			}
		}
	}
	if (record.structuredContent !== undefined) {
		try {
			parts.push(JSON.stringify(record.structuredContent));
		} catch {
			// Unserializable results carry nothing to sniff.
		}
	}
	if (typeof record.details === "string") parts.push(record.details);
	return parts.join("\n");
}

function labelFor(ctx: ExtensionContext): string {
	const model = ctx.model;
	const cwd = ctx.cwd.split("/").filter(Boolean).pop() ?? ctx.cwd;
	return `${cwd}${model ? ` · ${model.provider}/${model.id}` : ""}`;
}

const CONNECT_RETRY_MS = 4_000;
const CONNECT_MAX_ATTEMPTS = 10;

export default function (pi: ExtensionAPI) {
	const cfg = loadConfig();
	let client: SlotClient | null = null;
	let lease: string | null = null;
	let leaseEndpoint: string | null = null;
	let humanHold = false;
	let toolRegistered = false;
	let selfReported = false;
	let lastConnectAttemptAt = 0;
	let connectAttempts = 0;
	let gaveUpConnecting = false;
	const waiting = new Map<string, { startedAt: number; timer: NodeJS.Timeout | null }>();

	const releaseLease = (): void => {
		if (lease !== null && client !== null) client.release(lease);
		lease = null;
		leaseEndpoint = null;
	};

	const ensureClient = async (ctx: ExtensionContext): Promise<SlotClient | null> => {
		if (client !== null && client.connected) return client;
		// A missing broker is retried instead of latched: a T3 turn gets its own pi process, and
		// one failed attempt at process start would otherwise run the whole thread ungated.
		if (gaveUpConnecting) return null;
		const since = Date.now() - lastConnectAttemptAt;
		if (since < CONNECT_RETRY_MS) return null;
		lastConnectAttemptAt = Date.now();
		connectAttempts += 1;
		const candidate = new SlotClient(labelFor(ctx));
		candidate.onQueue = (reqId, info) => {
			const entry = waiting.get(reqId);
			if (entry === undefined) return;
			if (entry.timer === null) {
				const timer = setTimeout(() => {
					entry.timer = null;
					ctx.ui.notify(
						`model slot busy: waiting ${secondsOf(Date.now() - entry.startedAt)} (${info.holders}/${info.max} in use${info.ahead > 0 ? `, ${info.ahead} ahead` : ""})`,
						"info",
					);
				}, cfg.notifyAfterMs);
				timer.unref?.();
				entry.timer = timer;
			}
		};
		const connected = await candidate.connect();
		if (!connected) {
			if (connectAttempts === 1) ctx.ui.notify("model slot broker unreachable: running ungated until it answers", "warning");
			if (connectAttempts >= CONNECT_MAX_ATTEMPTS) {
				gaveUpConnecting = true;
				ctx.ui.notify(`model slot broker unreachable after ${connectAttempts} attempts: this thread runs ungated`, "error");
			}
			return null;
		}
		client = candidate;
		return candidate;
	};

	const registerAskHuman = (): void => {
		if (toolRegistered) return;
		toolRegistered = true;
		pi.registerTool({
			name: "ask_human",
			label: "Ask human",
			description:
				"Stop and ask the user for a decision before you continue. On a gated local model your request slot stays reserved for you for the hold window, so answering keeps your context warm.",
			promptSnippet:
				"ask_human: park your work and ask the user for a decision when the next step depends on something only they can decide.",
			promptGuidelines: [
				"Call ask_human instead of guessing when a decision belongs to the human; the model slot is held for them while they answer.",
				"Do not use ask_human for routine confirmations or to report finished work.",
			],
			annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: false, openWorldHint: false },
			parameters: Type.Object({
				question: Type.String({ description: "What you need decided, short and specific." }),
				options: Type.Optional(Type.Array(Type.String({ description: "A possible answer" }))),
			}),
			async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
				if (!ctx.hasUI) {
					return {
						content: [{ type: "text", text: "No interactive surface here. Continue with your best judgement and record what you assumed." }],
						details: { answered: false },
					};
				}
				const options = params.options ?? [];
				const answer = options.length > 0 ? await ctx.ui.select(params.question, options) : await ctx.ui.input(params.question);
				if (answer === undefined || answer === null || answer === "") {
					return {
						content: [{ type: "text", text: "No human answer arrived. Proceed with your best judgement and say what you assumed." }],
						details: { answered: false },
					};
				}
				return { content: [{ type: "text", text: `Human answer: ${answer}` }], details: { answered: true, answer } };
			},
		});
	};

	pi.on("session_start", async (_event, ctx) => {
		releaseLease();
		humanHold = false;
		selfReported = false;
		// Only sessions that can actually hit a gated endpoint attach to the broker.
		if (gatedEndpoint(cfg, ctx.model?.baseUrl) !== null) {
			registerAskHuman();
			await ensureClient(ctx);
		}
	});

	pi.on("session_shutdown", () => {
		for (const entry of waiting.values()) {
			if (entry.timer !== null) clearTimeout(entry.timer);
		}
		waiting.clear();
		releaseLease();
		client?.close();
		client = null;
	});

	// A handler failure here must not fail the turn: waiting is the whole point.
	pi.on("before_provider_request", async (event, ctx) => {
		const endpoint = gatedEndpoint(cfg, ctx.model?.baseUrl);
		if (endpoint === null) return event.payload;
		const active = await ensureClient(ctx);
		if (active === null) return event.payload;
		registerAskHuman();

		// Turn-scoped: a lease taken earlier in this turn covers the rest of its requests, so no
		// other thread can start while this one is mid-turn.
		if (lease !== null && leaseEndpoint === endpoint) return event.payload;
		// Never queue behind a lease this same process left over on a different endpoint.
		releaseLease();
		const reqId = `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
		const entry = { startedAt: Date.now(), timer: null as NodeJS.Timeout | null };
		waiting.set(reqId, entry);

		const result = await active.acquire(endpoint, ctx.signal, reqId);
		if (entry.timer !== null) clearTimeout(entry.timer);
		waiting.delete(reqId);

		if (result.status === "granted") {
			lease = result.reqId ?? null;
			leaseEndpoint = endpoint;
			if (result.waitedMs >= cfg.notifyAfterMs) {
				ctx.ui.notify(`model slot: resumed after ${secondsOf(result.waitedMs)} queued`, "info");
			}
			return event.payload;
		}
		if (result.status === "aborted") return event.payload;
		ungated = true;
		ctx.ui.notify("model slot broker lost: running ungated", "warning");
		return event.payload;
	});

	// A held lease is only handed back when the turn ends or when this process blocks on another
	// gated process of its own family, which otherwise queues behind the process waiting for it.
	pi.on("agent_end", () => {
		releaseLease();
		client?.idle(true);
	});
	pi.on("agent_settled", () => {
		releaseLease();
		client?.idle(true);
	});
	pi.on("session_compact", () => releaseLease());
	pi.on("session_compact_failed", () => releaseLease());

	pi.on("ui_prompt_start", () => {
		if (client === null || humanHold) return;
		humanHold = true;
		client.hold(true, leaseEndpoint ?? endpointKeys(cfg)[0] ?? null);
	});
	pi.on("ui_prompt_end", () => {
		if (client === null || !humanHold) return;
		humanHold = false;
		client.hold(false, null);
	});
	pi.on("input", () => {
		if (client === null || !humanHold) return;
		humanHold = false;
		client.hold(false, null);
	});

	// Family linkage with no T3 change. `delegate_task` in wait mode only names the child thread
	// after that child already finished, so the slot is reserved the moment the call starts; the
	// result text supplies the exact id when it lands. T3 MCP results carry the calling thread's own
	// id as `parentThreadId`, which is how a process announces itself.
	pi.on("tool_execution_start", (event) => {
		if (client === null) return;
		if (!/(delegate_task|t3_thread_launch|create_threads|run_scheduled_task_now)$/.test(event.toolName)) return;
		releaseLease();
		client.reserve();
	});

	pi.on("tool_execution_end", (event) => {
		if (client === null) return;
		const text = resultText(event.result);
		if (text.length === 0) return;
		for (const match of text.matchAll(/"childThreadId"\s*:\s*"([^"]+)"/g)) client.link(match[1]);
		if (!selfReported && /(orchestrator_capabilities|t3_thread_configure|preview_status)$/.test(event.toolName)) {
			const match = /"parentThreadId"\s*:\s*"([^"]+)"/.exec(text);
			if (match !== null) {
				client.selfId(match[1]);
				selfReported = true;
			}
		}
	});

	pi.on("model_select", (_event, ctx) => {
		if (gatedEndpoint(cfg, ctx.model?.baseUrl) !== null) registerAskHuman();
	});

	// The queue is invisible from the model's side unless it is said out loud: without this the
	// model reads a long wait as the harness being flaky and starts second-guessing its own work.
	pi.on("before_agent_start", (event, ctx) => {
		if (gatedEndpoint(cfg, ctx.model?.baseUrl) === null) return;
		return {
			systemPrompt: `${event.systemPrompt}\n\n## Model slot\nRequests to the active model are arbitrated by a single-slot broker on this machine: one request runs at a time, and a delegated subagent inherits this thread's place in line.\n- A request that had to queue is normal, not a fault. Wait it out; the wait is already paid for.\n- When the next step needs the human, call ask_human instead of stopping silently: the slot stays reserved for you while they answer, so you do not have to re-queue behind other work.`,
		};
	});

	pi.registerCommand("slot", {
		description: "Show model-slot state: who holds the model, who is queued",
		async handler(_args, ctx) {
			const active = await ensureClient(ctx);
			if (active === null) {
				ctx.ui.notify("model slot: no broker (ungated)", "warning");
				return;
			}
			const state = await active.status();
			if (state === null) {
				ctx.ui.notify("model slot: broker did not answer", "warning");
				return;
			}
			ctx.ui.notify(formatState(state), "info");
		},
	});
}

function formatState(state: SlotState): string {
	const lines: string[] = [`slot broker pid ${state.pid}`];
	for (const endpoint of state.endpoints) {
		lines.push(`${endpoint.url}  max ${endpoint.max}  owner ${endpoint.ownerFamily ?? "none"}`);
		for (const holder of endpoint.holders) {
			lines.push(`  running ${holder.label} (${holder.clientId}) ${secondsOf(holder.heldMs)}`);
		}
		for (const item of endpoint.queue) {
			lines.push(`  queued  ${item.label} (${item.clientId}) ${secondsOf(item.waitingMs)}`);
		}
		if (endpoint.holders.length === 0 && endpoint.queue.length === 0) lines.push("  idle");
	}
	const byFamily = new Map<string, string[]>();
	for (const client of state.clients) {
		const entry = byFamily.get(client.family) ?? [];
		entry.push(
			`${client.label}${client.threadId ? ` thread ${client.threadId.slice(0, 8)}` : ""}` +
				`${client.holdRemainingMs > 0 ? ` hold ${secondsOf(client.holdRemainingMs)}` : ""}` +
				`${client.children.length > 0 ? ` children ${client.children.length}` : ""}`,
		);
		byFamily.set(client.family, entry);
	}
	for (const [family, members] of byFamily) {
		if (members.length < 2) continue;
		lines.push(`family ${family.slice(0, 8)}: ${members.join(" | ")}`);
	}
	return lines.join("\n");
}
