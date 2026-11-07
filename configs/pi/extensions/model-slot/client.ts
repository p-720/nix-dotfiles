// Client used by the model-slot extension. Knows how to raise the broker and talk to it.

import { randomUUID } from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

export interface QueueInfo {
	ahead: number;
	holders: number;
	max: number;
}

export type AcquireResult =
	| { status: "granted"; reqId: string; waitedMs: number }
	| { status: "aborted" }
	| { status: "unavailable" };

export type SlotState = {
	at: string;
	pid: number;
	socket: string;
	endpoints: {
		url: string;
		max: number;
		ownerFamily: string | null;
		holders: { clientId: string; family: string; label: string; heldMs: number }[];
		queue: { clientId: string; family: string; label: string; waitingMs: number }[];
	}[];
	clients: {
		id: string;
		pid: number;
		label: string;
		family: string;
		threadId: string | null;
		connected: boolean;
			holdRemainingMs: number;
			priorityRemainingMs: number;
		leases: number;
		queued: number;
		children: string[];
	}[];
};

// An unref'd timer cannot hold the event loop open. Awaiting one in a harness that has nothing
// else ref'd (pi's print mode) lets Node exit with the promise still pending.
function sleep(ms: number, keepAlive = false): Promise<void> {
	return new Promise((resolve) => {
		const timer = setTimeout(resolve, ms);
		if (!keepAlive) timer.unref?.();
	});
}

/** Endpoint identity shared by the extension and the broker: they must key the same map. */
export function normalizeUrl(url: string): string {
	const trimmed = url.trim().replace(/\/+$/, "");
	try {
		const parsed = new URL(trimmed);
		const protocol = parsed.protocol.toLowerCase().replace(/:$/, "");
		const pathname = parsed.pathname.replace(/\/+$/, "");
		return `${protocol}://${parsed.host.toLowerCase()}${pathname === "/" ? "" : pathname}`;
	} catch {
		return trimmed.toLowerCase();
	}
}

function moduleDir(): string | null {
	const url = import.meta.url;
	if (typeof url !== "string" || !url.startsWith("file:")) return null;
	return path.dirname(url.replace(/^file:\/\//, ""));
}

export function socketPath(): string {
	const override = process.env.PI_SLOT_SOCKET?.trim();
	if (override) return override;
	const dir = process.env.XDG_RUNTIME_DIR?.trim() || "/tmp";
	return path.join(dir, "pi-model-slot.sock");
}

function daemonPath(): string {
	const override = process.env.PI_SLOT_DAEMON?.trim();
	if (override) return override;
	const local = moduleDir();
	if (local !== null && fs.existsSync(path.join(local, "slotd.mts"))) return path.join(local, "slotd.mts");
	return path.join(process.env.HOME ?? "", ".pi/agent/extensions/model-slot/slotd.mts");
}

interface Pending {
	resolve: (waitedMs: number) => void;
	reject: (error: Error) => void;
}

export class SlotClient {
	private sock: net.Socket | null = null;
	private pending = new Map<string, Pending>();
	private heartbeat: NodeJS.Timeout | null = null;
	private readonly clientId = randomUUID();
	private readonly label: string;
	onQueue: ((reqId: string, info: QueueInfo) => void) | null = null;

	constructor(label: string) {
		this.label = label;
	}

	get connected(): boolean {
		return this.sock !== null;
	}

	private write(message: Record<string, unknown>): void {
		if (this.sock === null) return;
		try {
			this.sock.write(`${JSON.stringify(message)}\n`);
		} catch {
			// Socket is gone; pending work rejects through the close handler.
		}
	}

	private async tryConnect(): Promise<boolean> {
		return await new Promise<boolean>((resolve) => {
			const sock = net.connect(socketPath());
			let settled = false;
			const finish = (ok: boolean, accepted: net.Socket | null) => {
				if (settled) return;
				settled = true;
				if (!ok) sock.destroy();
				resolve(ok);
				if (ok && accepted) this.attach(accepted);
			};
			sock.setTimeout(1500, () => finish(false, null));
			sock.on("connect", () => finish(true, sock));
			sock.on("error", () => finish(false, null));
		});
	}

	private attach(sock: net.Socket): void {
		this.sock = sock;
		sock.setTimeout(0);
		let buffer = "";
		sock.on("data", (chunk) => {
			buffer += chunk.toString("utf8");
			let index = buffer.indexOf("\n");
			while (index >= 0) {
				const line = buffer.slice(0, index).trim();
				buffer = buffer.slice(index + 1);
				index = buffer.indexOf("\n");
				if (line) this.handle(line);
			}
		});
		const fail = () => {
			if (this.sock === sock) this.sock = null;
			for (const [reqId, entry] of [...this.pending]) {
				this.pending.delete(reqId);
				entry.reject(new Error("slot broker connection lost"));
			}
			if (this.heartbeat !== null) {
				clearInterval(this.heartbeat);
				this.heartbeat = null;
			}
		};
		sock.on("close", fail);
		sock.on("error", fail);

		this.write({ t: "hello", pid: process.pid, label: this.label });
		if (this.heartbeat === null) {
			this.heartbeat = setInterval(() => this.write({ t: "heartbeat" }), 5_000);
			this.heartbeat.unref?.();
		}
	}

	private handle(line: string): void {
		let message: Record<string, unknown>;
		try {
			message = JSON.parse(line) as Record<string, unknown>;
		} catch {
			return;
		}
		const reqId = typeof message.reqId === "string" ? message.reqId : "";
		if (message.t === "granted" && reqId) {
			const entry = this.pending.get(reqId);
			if (entry !== undefined) {
				this.pending.delete(reqId);
				entry.resolve(typeof message.waitedMs === "number" ? message.waitedMs : 0);
			}
			return;
		}
		if (message.t === "status_resp" && this.statusResolver !== null) {
			this.statusResolver(message.state as SlotState);
			return;
		}
		if (message.t === "queued" && reqId && this.onQueue !== null) {
			this.onQueue(reqId, {
				ahead: typeof message.ahead === "number" ? message.ahead : 0,
				holders: typeof message.holders === "number" ? message.holders : 1,
				max: typeof message.max === "number" ? message.max : 1,
			});
		}
	}

	/** Connect, starting the broker detached when nothing answers. */
	async connect(): Promise<boolean> {
		if (this.sock !== null) return true;
		if (await this.tryConnect()) return true;
		const script = daemonPath();
		if (!fs.existsSync(script)) return false;
		try {
			const { spawn } = await import("node:child_process");
			const child = spawn(process.execPath, [script], { detached: true, stdio: "ignore" });
			child.on("error", () => undefined);
			child.unref();
		} catch {
			return false;
		}
		for (let attempt = 0; attempt < 25; attempt++) {
			await sleep(80, true);
			if (await this.tryConnect()) return true;
		}
		return false;
	}

	/** Wait for a free request slot on `endpoint`. Aborts with the turn's signal. */
	async acquire(endpoint: string, signal: AbortSignal | undefined, requestId?: string): Promise<AcquireResult> {
		if (this.sock === null) return { status: "unavailable" };
		const reqId = requestId ?? randomUUID();
		let settle: { resolve: (waitedMs: number) => void; reject: (error: Error) => void } | null = null;
		const waited = new Promise<number>((resolve, reject) => {
			settle = { resolve, reject };
		});
		if (settle === null) return { status: "unavailable" };
		this.pending.set(reqId, settle);
		this.write({ t: "acquire", reqId, endpoint });

		let aborted = false;
		const onAbort = () => {
			aborted = true;
			this.write({ t: "cancel", reqId });
			const entry = this.pending.get(reqId);
			if (entry !== undefined) {
				this.pending.delete(reqId);
				entry.reject(new Error("aborted"));
			}
		};
		if (signal !== undefined) {
			if (signal.aborted) {
				onAbort();
			} else {
				signal.addEventListener("abort", onAbort, { once: true });
			}
		}

		try {
			const waitedMs = await waited;
			return { status: "granted", reqId, waitedMs };
		} catch {
			return { status: aborted ? "aborted" : "unavailable" };
		} finally {
			this.pending.delete(reqId);
			if (signal !== undefined) signal.removeEventListener("abort", onAbort);
		}
	}

	release(reqId: string): void {
		this.write({ t: "release", reqId });
	}

	link(childThreadId: string): void {
		this.write({ t: "link", childThreadId });
	}

	/** A delegation has started but its child thread id is not known yet: wait mode only reports
	 * the child after the child already finished. */
	reserve(): void {
		this.write({ t: "reserve" });
	}

	selfId(threadId: string): void {
		this.write({ t: "selfid", threadId });
	}

	/** `ms` lets a turn-end grace differ from a human wait, which waits as long as it takes. */
	hold(on: boolean, endpoint: string | null, ms?: number): void {
		this.write({ t: "hold", on, ...(endpoint === null ? {} : { endpoint }), ...(ms === undefined ? {} : { ms }) });
	}

	/** Claim the slot for this thread: other families are parked while the claim stands. */
	priority(on: boolean): void {
		this.write({ t: "priority", on });
	}

	idle(isIdle: boolean): void {
		this.write({ t: "idle", idle: isIdle });
	}

	async status(): Promise<SlotState | null> {
		if (this.sock === null) return null;
		const answer = new Promise<SlotState | null>((resolve) => {
			const timer = setTimeout(() => {
				this.statusResolver = null;
				resolve(null);
			}, 2_000);
			timer.unref?.();
			this.statusResolver = (state) => {
				clearTimeout(timer);
				this.statusResolver = null;
				resolve(state);
			};
		});
		this.write({ t: "status" });
		return await answer;
	}

	private statusResolver: ((state: SlotState) => void) | null = null;

	close(): void {
		this.write({ t: "bye" });
		if (this.heartbeat !== null) {
			clearInterval(this.heartbeat);
			this.heartbeat = null;
		}
		const sock = this.sock;
		this.sock = null;
		sock?.destroy();
		for (const [, entry] of [...this.pending]) {
			entry.reject(new Error("closed"));
		}
		this.pending.clear();
	}
}
