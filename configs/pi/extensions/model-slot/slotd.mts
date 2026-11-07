#!/usr/bin/env node
// Single-slot model arbiter. One broker per machine, unix socket, newline-delimited JSON.
//   node slotd.mts          run the broker
//   node slotd.mts status   print live state and exit

import fs from "node:fs";
import net from "node:net";
import { normalizeUrl } from "./client.ts";
import path from "node:path";

type Json = Record<string, unknown>;

const DEFAULTS = {
	endpoints: [] as (string | { url: string; maxConcurrent?: number })[],
	maxConcurrent: 1,
	familyIdleGraceMs: 10_000,
	humanHoldMs: 180_000,
	priorityTtlMs: 900_000,
	leaseTtlMs: 30_000,
};

function readConfig(): typeof DEFAULTS {
	const file = process.env.PI_SLOT_CONFIG ?? path.join(import.meta.dirname, "config.json");
	try {
		const raw = JSON.parse(fs.readFileSync(file, "utf8")) as Partial<typeof DEFAULTS>;
		return { ...DEFAULTS, ...raw };
	} catch {
		return { ...DEFAULTS };
	}
}

const cfg = readConfig();
const num = (name: string, fallback: number) => {
	const raw = process.env[name]?.trim();
	const parsed = raw === undefined ? Number.NaN : Number(raw);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
};

const SOCKET_PATH =
	process.env.PI_SLOT_SOCKET ?? path.join(process.env.XDG_RUNTIME_DIR?.trim() || "/tmp", "pi-model-slot.sock");
const STATE_PATH = `${SOCKET_PATH}.json`;
const GLOBAL_MAX = num("PI_SLOT_MAX", cfg.maxConcurrent);
const GRACE_MS = num("PI_SLOT_GRACE_MS", cfg.familyIdleGraceMs);
const TTL_MS = num("PI_SLOT_TTL_MS", cfg.leaseTtlMs);
const HOLD_MS = num("PI_SLOT_HOLD_MS", cfg.humanHoldMs);
const MAX_HOLD_MS = num("PI_SLOT_MAX_HOLD_MS", 6 * 3_600_000);
const PRIORITY_MS = num("PI_SLOT_PRIORITY_MS", cfg.priorityTtlMs);
const IDLE_EXIT_MS = num("PI_SLOT_IDLE_EXIT_MS", 30_000);
const SWEEP_MS = num("PI_SLOT_SWEEP_MS", 2_000);
const CLOSE_GRACE_MS = num("PI_SLOT_CLOSE_GRACE_MS", 3_000);
const CHILD_FORGET_MS = num("PI_SLOT_CHILD_FORGET_MS", 30 * 60_000);
const CHILD_CLAIM_MS = num("PI_SLOT_CHILD_CLAIM_MS", 120_000);

interface ChildDecl {
	declaredAt: number;
	finished: boolean;
	childClientId: string | null;
}

interface Client {
	id: string;
	sock: net.Socket | null;
	closedAt: number | null;
	pid: number;
	label: string;
	threadId: string | null;
	family: string;
	lastSeen: number;
	holdUntil: number;
	priorityUntil: number;
	idle: boolean;
	children: Map<string, ChildDecl>;
	leases: Set<string>;
	queued: Set<string>;
}

interface Lease {
	reqId: string;
	clientId: string;
	family: string;
	at: number;
}

interface QueueItem {
	reqId: string;
	clientId: string;
	family: string;
	at: number;
	lastAhead: number;
}

interface Endpoint {
	url: string;
	max: number;
	holders: Map<string, Lease>;
	queue: QueueItem[];
	sticky: { family: string; at: number } | null;
}

const LOG_PATH = process.env.PI_SLOT_LOG ?? `${SOCKET_PATH}.log`;
function logEvent(text: string): void {
	try {
		fs.appendFileSync(LOG_PATH, `${new Date().toISOString()} ${text}\n`);
	} catch {
		// Logging must not take the broker down.
	}
}

const clients = new Map<string, Client>();
const endpoints = new Map<string, Endpoint>();



function endpointFor(url: string): Endpoint {
	const key = normalizeUrl(url);
	const existing = endpoints.get(key);
	if (existing) return existing;
	const override = cfg.endpoints.find(
		(entry) => normalizeUrl(typeof entry === "string" ? entry : entry.url) === key,
	);
	const configured = override && typeof override === "object" ? override.maxConcurrent : undefined;
	const created: Endpoint = {
		url: key,
		max: Math.max(1, Math.floor(configured ?? GLOBAL_MAX)),
		holders: new Map(),
		queue: [],
		sticky: null,
	};
	endpoints.set(key, created);
	return created;
}

function send(client: Client, message: Json): void {
	if (client.sock === null) return;
	try {
		client.sock.write(`${JSON.stringify(message)}\n`);
	} catch {
		// Socket is dying; the sweeper retires this client.
	}
}

function familyActive(ep: Endpoint, family: string): boolean {
	for (const lease of ep.holders.values()) if (lease.family === family) return true;
	return ep.queue.some((item) => item.family === family);
}

function familyHoldUntil(family: string, now: number): number {
	let until = 0;
	for (const client of clients.values()) {
		if (client.family === family && client.holdUntil > until) until = client.holdUntil;
	}
	return until > now ? until : 0;
}

/**
 * A family whose delegated child is unfinished, or parked for a human, keeps an empty slot empty:
 * handing it to someone else is what re-prefills the family's context for nothing.
 * It never preempts work already running.
 */
function childPending(client: Client, decl: ChildDecl, now: number): boolean {
	if (decl.finished) return false;
	if (now - decl.declaredAt > CHILD_FORGET_MS) {
		decl.finished = true;
		return false;
	}
	const child = decl.childClientId === null ? undefined : clients.get(decl.childClientId);
	// Declared but not connected yet: the parent is parked waiting for that thread to start. Only
	// hold the slot while that start is still plausible, or a child that never announces itself
	// would reserve the model for the whole forget window with nothing running.
	if (child === undefined) return now - decl.declaredAt < CHILD_CLAIM_MS;
	if (child.idle && !anyPendingChild(child, now)) {
		decl.finished = true;
		return false;
	}
	return true;
}

function anyPendingChild(client: Client, now: number): boolean {
	for (const decl of client.children.values()) {
		if (childPending(client, decl, now)) return true;
	}
	return false;
}

function reservedFamily(now: number): string | null {
	for (const client of clients.values()) {
		if (client.holdUntil > now) return client.family;
		if (anyPendingChild(client, now)) return client.family;
	}
	return null;
}

function priorityFamily(now: number): string | null {
	for (const client of clients.values()) {
		if (client.priorityUntil > now) return client.family;
	}
	return null;
}

function currentOwner(ep: Endpoint, now: number): string | null {
	const sticky = ep.sticky;
	if (sticky === null) return null;
	const keepsOwnership =
		familyActive(ep, sticky.family) ||
		familyHoldUntil(sticky.family, now) > 0 ||
		now - sticky.at < GRACE_MS;
	if (!keepsOwnership) {
		ep.sticky = null;
		return null;
	}
	return sticky.family;
}

function rank(item: QueueItem, owner: string | null, pri: string | null, now: number): [number, number, number] {
	const familyRank = pri !== null && item.family === pri ? 0 : owner !== null && item.family === owner ? 1 : 2;
	// A parent parked on its own delegated children waits behind them.
	const self = clients.get(item.clientId);
	const childRank = self !== undefined && anyPendingChild(self, now) ? 1 : 0;
	return [familyRank, childRank, item.at];
}

function compare(
	ep: Endpoint,
	a: QueueItem,
	b: QueueItem,
	owner: string | null,
	pri: string | null,
	now: number,
): number {
	const left = rank(a, owner, pri, now);
	const right = rank(b, owner, pri, now);
	return left[0] - right[0] || left[1] - right[1] || left[2] - right[2];
}

function rebalance(ep: Endpoint): void {
	const now = Date.now();
	const owner = currentOwner(ep, now);
	const pri = priorityFamily(now);
	while (ep.queue.length > 0) {
		const sorted = [...ep.queue].sort((a, b) => compare(ep, a, b, owner, pri, now));
		const best = sorted[0]!;
		if (ep.holders.size === 0) {
			const reserved = reservedFamily(now);
			if (reserved !== null && best.family !== reserved) break;
			// A claimed thread parks everyone else: it is the one being waited on.
			if (reserved === null && pri !== null && best.family !== pri) break;
		}
		// One request in flight per slot, even for the same process: the extension releases its
		// lease before queueing a next turn, so a process never waits behind itself by accident.
		if (ep.holders.size >= ep.max) break;
		ep.queue = ep.queue.filter((item) => item.reqId !== best.reqId);
		const client = clients.get(best.clientId);
		if (client === undefined) continue;
		ep.holders.set(best.reqId, { reqId: best.reqId, clientId: best.clientId, family: best.family, at: now });
		client.queued.delete(best.reqId);
		client.idle = false;
		ep.sticky = { family: best.family, at: now };
		send(client, { t: "granted", reqId: best.reqId, waitedMs: now - best.at });
		logEvent(`grant ${best.clientId} ${best.reqId} family=${best.family} queued=${ep.queue.length}`);
	}
	const currentOwnerFamily = currentOwner(ep, now);
	for (const item of ep.queue) {
		const client = clients.get(item.clientId);
		if (client === undefined) continue;
		const ahead = ep.queue.filter(
				(other) => other.reqId !== item.reqId && compare(ep, other, item, currentOwnerFamily, pri, now) < 0,
		).length;
		if (ahead === item.lastAhead && item.lastAhead !== -1) continue;
		item.lastAhead = ahead;
		send(client, { t: "queued", reqId: item.reqId, ahead, holders: ep.holders.size, max: ep.max });
	}
	scheduleStateWrite();
}

function retagFamily(clientId: string, family: string): void {
	const client = clients.get(clientId);
	if (client !== undefined) client.family = family;
	for (const ep of endpoints.values()) {
		for (const item of ep.queue) if (item.clientId === clientId) item.family = family;
		for (const lease of ep.holders.values()) if (lease.clientId === clientId) lease.family = family;
	}
}

function adopt(client: Client, threadId: string): void {
	for (const candidate of clients.values()) {
		if (candidate.id === client.id) continue;
		const decl = candidate.children.get(threadId);
		if (decl === undefined || decl.finished || decl.childClientId !== null) continue;
		decl.childClientId = client.id;
		retagFamily(client.id, candidate.family);
		return;
	}
}

/** The child often announces itself before its parent reports the delegation. */
function claimExistingChild(parent: Client, childThreadId: string): void {
	const decl = parent.children.get(childThreadId);
	if (decl === undefined) return;
	for (const candidate of clients.values()) {
		if (candidate.id === parent.id || candidate.threadId !== childThreadId) continue;
		decl.childClientId = candidate.id;
		retagFamily(candidate.id, parent.family);
		return;
	}
}

/**
 * Pi can only learn a T3 thread id from tool output, so a delegated child usually cannot announce
 * itself. When exactly one delegation is waiting for its child, the next client that shows up is
 * that child: it joins the parent's family and inherits the priority the family already has.
 * A wrong claim only mis-ranks one request; nothing is blocked on it.
 */
function claimByElimination(client: Client, now: number): void {
	if (client.threadId !== null) return;
	const candidates: { parent: Client; decl: ChildDecl }[] = [];
	for (const other of clients.values()) {
		if (other.id === client.id || other.sock === null) continue;
		for (const decl of other.children.values()) {
			if (decl.finished || decl.childClientId !== null) continue;
			if (now - decl.declaredAt > CHILD_CLAIM_MS) continue;
			candidates.push({ parent: other, decl });
		}
	}
	if (candidates.length !== 1) return;
	const claim = candidates[0]!;
	claim.decl.childClientId = client.id;
	retagFamily(client.id, claim.parent.family);
}

function markIdleIfEmpty(client: Client): void {
	if (client.leases.size === 0 && client.queued.size === 0) client.idle = true;
}

function dropClient(client: Client): void {
	if (!clients.has(client.id)) return;
	clients.delete(client.id);
	// A child that disconnected cannot still hold its parent's family hostage.
	for (const other of clients.values()) {
		for (const decl of other.children.values()) {
			if (decl.childClientId === client.id) decl.finished = true;
		}
	}
	for (const ep of endpoints.values()) {
		let touched = false;
		for (const [reqId, lease] of ep.holders) {
			if (lease.clientId !== client.id) continue;
			ep.holders.delete(reqId);
			ep.sticky = { family: lease.family, at: Date.now() };
			touched = true;
		}
		const before = ep.queue.length;
		ep.queue = ep.queue.filter((item) => item.clientId !== client.id);
		if (ep.queue.length !== before) touched = true;
		if (touched) rebalance(ep);
	}
	scheduleStateWrite();
}

function snapshot(): Json {
	const now = Date.now();
	return {
		at: new Date(now).toISOString(),
		pid: process.pid,
		socket: SOCKET_PATH,
		endpoints: [...endpoints.values()].map((ep) => {
			const owner = currentOwner(ep, now);
			return {
				url: ep.url,
				max: ep.max,
				ownerFamily: owner,
				holders: [...ep.holders.values()].map((lease) => ({
					clientId: lease.clientId,
					family: lease.family,
					label: clients.get(lease.clientId)?.label ?? "?",
					heldMs: now - lease.at,
				})),
				queue: [...ep.queue]
					.sort((a, b) => compare(ep, a, b, owner, now))
					.map((item) => ({
						clientId: item.clientId,
						family: item.family,
						label: clients.get(item.clientId)?.label ?? "?",
						waitingMs: now - item.at,
					})),
			};
		}),
		clients: [...clients.values()].map((client) => ({
			id: client.id,
			pid: client.pid,
			label: client.label,
			family: client.family,
			threadId: client.threadId,
			connected: client.sock !== null,
			holdRemainingMs: client.holdUntil > now ? client.holdUntil - now : 0,
			priorityRemainingMs: client.priorityUntil > now ? client.priorityUntil - now : 0,
			leases: client.leases.size,
			queued: client.queued.size,
			children: [...client.children.keys()],
		})),
	};
}

let stateWrite: NodeJS.Timeout | null = null;
function scheduleStateWrite(): void {
	if (stateWrite !== null) return;
	stateWrite = setTimeout(() => {
		stateWrite = null;
		try {
			fs.writeFileSync(STATE_PATH, `${JSON.stringify(snapshot(), null, 2)}\n`);
		} catch {
			// Inspection file only.
		}
	}, 250);
	stateWrite.unref?.();
}

function rebalanceAll(): void {
	for (const ep of endpoints.values()) rebalance(ep);
}

function handleMessage(client: Client, message: Json): void {
	const now = Date.now();
	client.lastSeen = now;
	const str = (key: string): string => (typeof message[key] === "string" ? (message[key] as string) : "");

	switch (message.t) {
		case "hello": {
			client.pid = typeof message.pid === "number" ? message.pid : 0;
			client.label = str("label") || client.id.slice(0, 8);
			logEvent(`hello ${client.id} pid=${client.pid} label=${client.label}`);
			const threadId = str("threadId");
			if (threadId) {
				client.threadId = threadId;
				adopt(client, threadId);
			}
			claimByElimination(client, Date.now());
			send(client, { t: "hello_ack", clientId: client.id });
			return;
		}
		case "heartbeat":
			return;
		case "acquire": {
			const endpoint = str("endpoint");
			const reqId = str("reqId");
			if (!endpoint || !reqId) return;
			const ep = endpointFor(endpoint);
			if (ep.holders.has(reqId) || ep.queue.some((item) => item.reqId === reqId)) return;
			ep.queue.push({ reqId, clientId: client.id, family: client.family, at: now, lastAhead: -1 });
			client.queued.add(reqId);
			client.idle = false;
			logEvent(`acquire ${client.id} ${endpoint} ${reqId}`);
			rebalance(ep);
			return;
		}
		case "release": {
			const reqId = str("reqId");
			let touched = false;
			for (const ep of endpoints.values()) {
				const lease = ep.holders.get(reqId);
				if (lease !== undefined) {
					ep.holders.delete(reqId);
					ep.sticky = { family: lease.family, at: now };
					client.leases.delete(reqId);
					touched = true;
				}
				const before = ep.queue.length;
				ep.queue = ep.queue.filter((item) => item.reqId !== reqId);
				client.queued.delete(reqId);
				if (ep.queue.length !== before) touched = true;
			}
			markIdleIfEmpty(client);
			if (touched) rebalanceAll();
			return;
		}
		case "cancel": {
			const reqId = str("reqId");
			let touched = false;
			for (const ep of endpoints.values()) {
				const before = ep.queue.length;
				ep.queue = ep.queue.filter((item) => item.reqId !== reqId);
				if (ep.queue.length !== before) touched = true;
			}
			client.queued.delete(reqId);
			markIdleIfEmpty(client);
			if (touched) rebalanceAll();
			return;
		}
		case "link": {
			const childThreadId = str("childThreadId");
			if (!childThreadId) return;
			client.children.set(childThreadId, { declaredAt: now, finished: false, childClientId: null });
			claimExistingChild(client, childThreadId);
			rebalanceAll();
			return;
		}
		case "reserve": {
			// A delegation is running and its child will show up shortly as its own process.
			client.children.set(`reserve-${now}-${client.children.size + 1}`, { declaredAt: now, finished: false, childClientId: null });
			client.idle = false;
			rebalanceAll();
			return;
		}
		case "selfid": {
			const threadId = str("threadId");
			if (!threadId) return;
			// Another process already claims that thread; a wrong id would graft the wrong family.
			for (const other of clients.values()) {
				if (other.id !== client.id && other.threadId === threadId) return;
			}
			client.threadId = threadId;
			adopt(client, threadId);
			rebalanceAll();
			return;
		}
		case "hold": {
			const on = message.on === true;
			const requested = typeof message.ms === "number" && Number.isFinite(message.ms) ? message.ms : HOLD_MS;
			client.holdUntil = on ? now + Math.min(Math.max(requested, 0), MAX_HOLD_MS) : 0;
			const endpoint = str("endpoint");
			if (on && endpoint) {
				const ep = endpointFor(endpoint);
				ep.sticky = { family: client.family, at: now };
			}
			rebalanceAll();
			return;
		}
		case "priority": {
			// Extended, not reset, so a claimed thread that is still working keeps its claim.
			client.priorityUntil = message.on === true ? now + PRIORITY_MS : 0;
			rebalanceAll();
			return;
		}
		case "idle":
			client.idle = message.idle === true;
			rebalanceAll();
			return;
		case "status":
			send(client, { t: "status_resp", state: snapshot() });
			return;
		case "probe":
			send(client, { t: "probe_ack", pid: process.pid });
			return;
		default:
			return;
	}
}

let idleExit: NodeJS.Timeout | null = null;
function scheduleIdleExit(): void {
	if (idleExit !== null) return;
	idleExit = setTimeout(() => {
		try {
			fs.unlinkSync(SOCKET_PATH);
		} catch {
			// Already gone.
		}
		logEvent("idle-exit");
		process.exit(0);
	}, IDLE_EXIT_MS);
	idleExit.unref?.();
}

function clearIdleExit(): void {
	if (idleExit !== null) {
		clearTimeout(idleExit);
		idleExit = null;
	}
}

function probeAlive(done: (alive: boolean) => void): void {
	const sock = net.connect(SOCKET_PATH);
	let settled = false;
	const finish = (alive: boolean) => {
		if (settled) return;
		settled = true;
		sock.destroy();
		done(alive);
	};
	sock.setTimeout(1500, () => finish(false));
	sock.on("connect", () => sock.write(`${JSON.stringify({ t: "probe" })}\n`));
	sock.on("data", (chunk) => finish(chunk.toString("utf8").includes("probe_ack")));
	sock.on("error", () => finish(false));
	sock.on("close", () => finish(false));
}

function serve(): void {
	const server = net.createServer((sock) => {
		const id = `c${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
		const client: Client = {
			id,
			sock,
			closedAt: null,
			pid: 0,
			label: id,
			threadId: null,
			family: id,
			lastSeen: Date.now(),
			holdUntil: 0,
			priorityUntil: 0,
			idle: false,
			children: new Map(),
			leases: new Set(),
			queued: new Set(),
		};
		clients.set(id, client);
		clearIdleExit();
		let buffer = "";
		sock.on("data", (chunk) => {
			buffer += chunk.toString("utf8");
			let index = buffer.indexOf("\n");
			while (index >= 0) {
				const line = buffer.slice(0, index).trim();
				buffer = buffer.slice(index + 1);
				index = buffer.indexOf("\n");
				if (!line) continue;
				let parsed: unknown;
				try {
					parsed = JSON.parse(line);
				} catch {
					continue;
				}
				if (parsed !== null && typeof parsed === "object") handleMessage(client, parsed as Json);
			}
		});
		const close = () => {
			client.sock = null;
			client.closedAt = Date.now();
		};
		sock.on("close", close);
		sock.on("error", close);
	});

	server.on("error", (error: NodeJS.ErrnoException) => {
		if (error.code !== "EADDRINUSE") {
			process.stderr.write(`slotd: ${error.message}\n`);
			process.exit(1);
		}
		probeAlive((alive) => {
			if (alive) process.exit(0);
			try {
				fs.unlinkSync(SOCKET_PATH);
			} catch {
				// Nothing to unlink.
			}
			server.listen(SOCKET_PATH);
		});
	});

	server.listen(SOCKET_PATH, () => {
		try {
			fs.chmodSync(SOCKET_PATH, 0o600);
		} catch {
			// Best effort.
		}
	});

	const sweeper = setInterval(() => {
		const now = Date.now();
		for (const client of [...clients.values()]) {
			if (client.sock === null) {
				if (client.closedAt !== null && now - client.closedAt > CLOSE_GRACE_MS) dropClient(client);
				continue;
			}
			if (now - client.lastSeen > TTL_MS) dropClient(client);
		}
		rebalanceAll();
		if (clients.size === 0) scheduleIdleExit();
	}, SWEEP_MS);
	sweeper.unref?.();
}

if (process.argv[2] === "status") {
	const sock = net.connect(SOCKET_PATH);
	sock.setTimeout(3000, () => {
		process.stderr.write(`slotd: no broker answered at ${SOCKET_PATH}\n`);
		sock.destroy();
		process.exit(1);
	});
	sock.on("connect", () => sock.write(`${JSON.stringify({ t: "status" })}\n`));
	sock.on("data", (chunk) => {
		process.stdout.write(chunk.toString("utf8"));
		sock.destroy();
		process.exit(0);
	});
	sock.on("error", (error) => {
		process.stderr.write(`slotd: no broker at ${SOCKET_PATH}: ${error.message}\n`);
		process.exit(1);
	});
} else {
	serve();
	for (const signal of ["SIGTERM", "SIGINT"] as const) {
		process.on(signal, () => {
			try {
				fs.unlinkSync(SOCKET_PATH);
			} catch {
				// Already gone.
			}
			process.exit(0);
		});
	}
}
