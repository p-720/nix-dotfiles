// Broker behaviour tests: real `slotd.mts` process, real unix socket, no pi involved.
//   node --test ~/.pi/agent/extensions/model-slot/test/daemon.test.mts

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const DAEMON = path.join(import.meta.dirname, "..", "slotd.mts");
const GATED = "http://127.0.0.1:40999/v1";

type Message = Record<string, unknown>;

class Peer {
	private sock: net.Socket | null = null;
	private buffer = "";
	label: string;
	private socket: string;
	private queue: Message[] = [];
	private waiters: { match: (m: Message) => boolean; resolve: (m: Message) => void }[] = [];

	constructor(socket: string, label: string) {
		this.socket = socket;
		this.label = label;
	}

	connect(): Promise<void> {
		return new Promise((resolve, reject) => {
			const sock = net.connect(this.socket);
			sock.on("error", reject);
			sock.on("connect", () => {
				this.sock = sock;
				sock.on("data", (chunk) => this.absorb(chunk.toString("utf8")));
				sock.on("close", () => {
					this.sock = null;
				});
				resolve();
			});
		});
	}

	private absorb(chunk: string): void {
		this.buffer += chunk;
		let index = this.buffer.indexOf("\n");
		while (index >= 0) {
			const line = this.buffer.slice(0, index).trim();
			this.buffer = this.buffer.slice(index + 1);
			index = this.buffer.indexOf("\n");
			if (!line) continue;
			const message = JSON.parse(line) as Message;
			const waiterIndex = this.waiters.findIndex((waiter) => waiter.match(message));
			if (waiterIndex >= 0) {
				const waiter = this.waiters[waiterIndex]!;
				this.waiters.splice(waiterIndex, 1);
				waiter.resolve(message);
			} else {
				this.queue.push(message);
			}
		}
	}

	send(message: Message): void {
		if (this.sock === null) throw new Error(`${this.label} is not connected`);
		this.sock.write(`${JSON.stringify(message)}\n`);
	}

	/** Takes a message already delivered, or waits for the next one that matches. */
	take(match: (m: Message) => boolean, why: string): Promise<Message> {
		const index = this.queue.findIndex(match);
		if (index >= 0) return Promise.resolve(this.queue.splice(index, 1)[0]!);
		return new Promise((resolve) => this.waiters.push({ match, resolve })).then((message) => {
			if (message === undefined) throw new Error(`${this.label}: no message for ${why}`);
			return message;
		});
	}

	next(why: string): Promise<Message> {
		return this.take(() => true, why);
	}

	hello(threadId?: string): Promise<Message> {
		this.send({ t: "hello", label: this.label, pid: process.pid, threadId });
		return this.take((m) => m.t === "hello_ack", "hello_ack");
	}

	acquire(reqId: string, endpoint = GATED): void {
		this.send({ t: "acquire", reqId, endpoint });
	}

	granted(reqId: string): Promise<Message> {
		return this.take((m) => m.t === "granted" && m.reqId === reqId, `granted for ${reqId}`);
	}

	queued(reqId: string): Promise<Message> {
		return this.take((m) => m.t === "queued" && m.reqId === reqId, `queued for ${reqId}`);
	}

	release(reqId: string): void {
		this.send({ t: "release", reqId });
	}

	status(): Promise<Message> {
		this.send({ t: "status" });
		return this.take((m) => m.t === "status_resp", "status_resp").then((m) => m.state as Message);
	}

	close(): void {
		this.sock?.destroy();
		this.sock = null;
	}
}

async function startBroker(
	t: TestContext,
	overrides: Record<string, string> = {},
): Promise<{ socket: string; peers: (n: number) => Promise<Peer[]>; socketDir: string }> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "slot-daemon-"));
	const socket = path.join(dir, "slot.sock");
	fs.writeFileSync(
		path.join(dir, "config.json"),
		JSON.stringify({ endpoints: [GATED], maxConcurrent: 1, familyIdleGraceMs: 1500 }),
	);
	const env = {
		...process.env,
		PI_SLOT_SOCKET: socket,
		PI_SLOT_CONFIG: path.join(dir, "config.json"),
		PI_SLOT_GRACE_MS: "1500",
		PI_SLOT_TTL_MS: "6000",
		PI_SLOT_SWEEP_MS: "150",
		PI_SLOT_CLOSE_GRACE_MS: "150",
		PI_SLOT_HOLD_MS: "2000",
		PI_SLOT_IDLE_EXIT_MS: "60000",
		PI_SLOT_CHILD_CLAIM_MS: "60000",
		...overrides,
	};
	const proc = spawn(process.execPath, [DAEMON], { cwd: dir, env, stdio: ["ignore", "ignore", "pipe"] });
	let stderr = "";
	proc.stderr.on("data", (chunk) => {
		stderr += chunk.toString("utf8");
	});
	t.after(() => {
		proc.kill();
		fs.rmSync(dir, { recursive: true, force: true });
	});

	const deadline = Date.now() + 10_000;
	while (!fs.existsSync(socket)) {
		if (Date.now() > deadline) throw new Error(`broker did not start: ${stderr}`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}

	const peers = async (count: number) => {
		const list: Peer[] = [];
		for (let i = 0; i < count; i += 1) {
			const peer = new Peer(socket, `peer${list.length + 1}`);
			await peer.connect();
			await peer.hello();
			list.push(peer);
		}
		return list;
	};
	return { socket, peers, socketDir: dir };
}

test("a second family waits for the slot and is granted it after the first releases", async (t) => {
	const broker = await startBroker(t);
	const [first, second] = await broker.peers(2);

	first.acquire("r1");
	const grant = await first.granted("r1");
	second.acquire("r2");
	const queued = await second.queued("r2");
	assert.equal(queued.holders, 1, "second family was not told the slot is busy");
	assert.equal(queued.max, 1, "second family was told the wrong slot width");

	first.release("r1");
	await second.granted("r2");
	const state = await first.status();
	const endpoint = (state.endpoints as Message[])[0]!;
	assert.equal((endpoint.holders as Message[]).length, 1, "slot is not held by exactly one request");
});

test("the owning family goes ahead of a stranger that queued earlier", async (t) => {
	const broker = await startBroker(t);
	const [owner, stranger] = await broker.peers(2);

	owner.acquire("r1");
	await owner.granted("r1");
	stranger.acquire("s1");
	await stranger.queued("s1");
	owner.acquire("r2");
	await owner.queued("r2");

	owner.release("r1");
	await owner.granted("r2");

	const state = await owner.status();
	const endpoint = (state.endpoints as Message[])[0]!;
	assert.ok((endpoint.holders as Message[]).some((h) => h.clientId === idOf(state, owner)), "the slot left the owning family");
	assert.ok(strangerQueued(state, stranger), "the stranger was granted out of order or dropped");
	assert.equal((endpoint.ownerFamily as string), familyOf(state, owner), "ownership was not kept with the family");
});

test("a parent parked on a delegated child yields the slot to that child, not to a stranger", async (t) => {
	const broker = await startBroker(t);
	const [parent, stranger] = await broker.peers(2);
	const child = new Peer(broker.socket, "child");
	await child.connect();

	parent.acquire("p1");
	await parent.granted("p1");
	parent.release("p1");
	// The parent announces the delegation before the child's pi exists.
	parent.send({ t: "link", childThreadId: "thread-child" });

	stranger.acquire("s1");
	await stranger.queued("s1");

	await child.hello("thread-child");
	child.acquire("c1");
	await child.granted("c1");

	const state = await child.status();
	const endpoint = (state.endpoints as Message[])[0]!;
	assert.equal((endpoint.holders as Message[]).length, 1);
	assert.ok(strangerQueued(state, stranger, "s1"), "the stranger took a slot reserved for the family's child");

	assert.equal(familyOf(state, child), familyOf(state, parent), "the child was not adopted into the parent's family");
});

test("a parent parked on a child waits behind that child for the same slot", async (t) => {
	const broker = await startBroker(t);
	const [parent] = await broker.peers(1);
	const child = new Peer(broker.socket, "child");
	await child.connect();
	await child.hello("thread-child");
	parent.send({ t: "link", childThreadId: "thread-child" });
	const stranger = (await broker.peers(1))[0]!;

	child.acquire("c1");
	await child.granted("c1");
	parent.acquire("p1");
	await parent.queued("p1");
	stranger.acquire("s1");
	await stranger.queued("s1");

	child.release("c1");
	await parent.granted("p1");
	const state = await parent.status();
	assert.ok(strangerQueued(state, stranger), "the stranger jumped the parked parent");
});

test("a human hold keeps the slot reserved and expires on its own", async (t) => {
	const broker = await startBroker(t);
	const [holder, stranger] = await broker.peers(2);

	holder.acquire("h1");
	await holder.granted("h1");
	holder.release("h1");
	holder.send({ t: "hold", on: true, endpoint: GATED });

	stranger.acquire("s1");
	await stranger.queued("s1");

	// PI_SLOT_HOLD_MS is 2s for these tests: the slot must free itself without another message.
	await stranger.granted("s1");
});

test("a soft hold keeps priority but never blocks a stranger that has work", async (t) => {
	const broker = await startBroker(t);
	const [holder, stranger] = await broker.peers(2);

	holder.acquire("g1");
	await holder.granted("g1");
	holder.release("g1");
	holder.send({ t: "hold", on: true, hard: false, endpoint: GATED });

	stranger.acquire("s1");
	await stranger.granted("s1");
});

test("a client that dies without releasing still gives the slot back", async (t) => {
	const broker = await startBroker(t);
	const [doomed, survivor] = await broker.peers(2);

	doomed.acquire("d1");
	await doomed.granted("d1");
	doomed.close();

	survivor.acquire("s1");
	await survivor.granted("s1");
});

test("cancelling a queued request takes it out of line", async (t) => {
	const broker = await startBroker(t);
	const [busy, waiter, other] = await broker.peers(3);

	busy.acquire("b1");
	await busy.granted("b1");
	waiter.acquire("w1");
	await waiter.queued("w1");
	other.acquire("o1");
	await other.queued("o1");

	waiter.send({ t: "cancel", reqId: "w1" });
	busy.release("b1");
	await other.granted("o1");

	const state = await other.status();
	const endpoint = (state.endpoints as Message[])[0]!;
	assert.equal((endpoint.queue as Message[]).length, 0, "a cancelled request stayed in line");
});

function idOf(state: Message, peer: Peer): string {
	const matches = (state.clients as Message[]).filter((c) => c.label === peer.label);
	assert.ok(matches.length > 0, `broker does not know ${peer.label}`);
	return matches[matches.length - 1]!.id as string;
}

function familyOf(state: Message, peer: Peer): string {
	return (state.clients as Message[]).find((c) => c.label === peer.label)!.family as string;
}

function strangerQueued(state: Message, peer: Peer, reqId: string): boolean {
	void reqId;
	const id = idOf(state, peer);
	const endpoint = (state.endpoints as Message[])[0]!;
	return (endpoint.queue as Message[]).some((item) => item.clientId === id);
}

test("the client that appears right after a delegation is treated as the delegated child", async (t) => {
	const broker = await startBroker(t);
	const [parent, stranger] = await broker.peers(2);

	parent.acquire("r1");
	await parent.granted("r1");
	parent.release("r1");
	parent.send({ t: "link", childThreadId: "thread-unknown-child" });

	stranger.acquire("s1");
	await stranger.queued("s1");

	// The child's pi process announces nothing about itself; it only arrived after the delegation.
	const newcomer = (await broker.peers(1))[0]!;
	newcomer.acquire("n1");
	await newcomer.granted("n1");

	const state = await newcomer.status();
	assert.equal(familyOf(state, newcomer), familyOf(state, parent), "the newcomer did not join the delegating family");
	assert.ok(strangerQueued(state, stranger), "a stranger took a slot the delegating family was holding");
});

test("a delegation whose child never arrives stops reserving the slot", async (t) => {
	const broker = await startBroker(t, { PI_SLOT_CHILD_CLAIM_MS: "700" });
	const [parent, stranger] = await broker.peers(2);

	parent.acquire("r1");
	await parent.granted("r1");
	parent.release("r1");
	parent.send({ t: "link", childThreadId: "thread-that-never-starts" });

	stranger.acquire("s1");
	await stranger.queued("s1");

	// Nothing else claims it, so the reservation has to lapse on its own.
	await stranger.granted("s1");
});

test("a delegation that has not named its child yet keeps the slot for that child", async (t) => {
	const broker = await startBroker(t);
	const [parent, stranger] = await broker.peers(2);

	parent.acquire("r1");
	await parent.granted("r1");
	parent.release("r1");
	// delegate_task in wait mode: the call is running, the child process is about to appear.
	parent.send({ t: "reserve" });

	stranger.acquire("s1");
	await stranger.queued("s1");

	const newcomer = (await broker.peers(1))[0]!;
	newcomer.acquire("n1");
	await newcomer.granted("n1");

	const state = await newcomer.status();
	assert.equal(familyOf(state, newcomer), familyOf(state, parent), "the child did not join the delegating family");
	assert.ok(strangerQueued(state, stranger), "a stranger took the slot the delegation was holding");
});
