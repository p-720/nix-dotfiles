// Behaviour tests for the slot broker: scripted clients, no models, no GPU.
//   node --test ~/.pi/agent/_extensions/model-slot/test/

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

const DAEMON = path.join(import.meta.dirname, "..", "slotd.mts");
const ENDPOINT = "http://127.0.0.1:40119/v1";

type Msg = Record<string, unknown>;
type Context = { after: (fn: () => void) => void };

const sleep = (ms: number) =>
	new Promise<void>((resolve) => {
		const timer = setTimeout(resolve, ms);
		timer.unref?.();
	});

class TestClient {
	private readonly sock: net.Socket;
	private buffer = "";
	private readonly messages: Msg[] = [];
	private readonly waiters: { match: (m: Msg) => boolean; resolve: (m: Msg) => void }[] = [];
	private heartbeat: NodeJS.Timeout | null = null;
	id = "";

	private constructor(sock: net.Socket) {
		this.sock = sock;
		sock.on("data", (chunk) => {
			this.buffer += chunk.toString("utf8");
			let index = this.buffer.indexOf("\n");
			while (index >= 0) {
				const line = this.buffer.slice(0, index);
				this.buffer = this.buffer.slice(index + 1);
				index = this.buffer.indexOf("\n");
				if (!line.trim()) continue;
				const parsed = JSON.parse(line) as Msg;
				this.messages.push(parsed);
				if (parsed.t === "hello_ack" && typeof parsed.clientId === "string") this.id = parsed.clientId;
				for (const waiter of [...this.waiters]) {
					if (waiter.match(parsed)) {
						this.waiters.splice(this.waiters.indexOf(waiter), 1);
						waiter.resolve(parsed);
					}
				}
			}
		});
	}

	static async connect(socket: string, label: string): Promise<TestClient> {
		const sock = net.connect(socket);
		const client = new TestClient(sock);
		await new Promise<void>((resolve, reject) => {
			sock.once("connect", resolve);
			sock.once("error", reject);
		});
		client.send({ t: "hello", pid: process.pid, label });
		client.heartbeat = setInterval(() => client.send({ t: "heartbeat" }), 100);
		client.heartbeat.unref?.();
		await client.expect((m) => m.t === "hello_ack");
		return client;
	}

	send(message: Msg): void {
		this.sock.write(`${JSON.stringify(message)}\n`);
	}

	stopHeartbeat(): void {
		if (this.heartbeat !== null) {
			clearInterval(this.heartbeat);
			this.heartbeat = null;
		}
	}

	expect(match: (m: Msg) => boolean, timeoutMs = 2_000): Promise<Msg> {
		const seen = this.messages.find(match);
		if (seen !== undefined) return Promise.resolve(seen);
		return new Promise<Msg>((resolve, reject) => {
			const waiter = {
				match,
				resolve: (m: Msg) => {
					clearTimeout(timer);
					resolve(m);
				},
			};
			const timer = setTimeout(() => {
				const index = this.waiters.indexOf(waiter);
				if (index >= 0) this.waiters.splice(index, 1);
				reject(new Error(`no matching broker message within ${timeoutMs}ms`));
			}, timeoutMs);
			this.waiters.push(waiter);
		});
	}

	granted(reqId: string, timeoutMs = 2_000): Promise<Msg> {
		return this.expect((m) => m.t === "granted" && m.reqId === reqId, timeoutMs);
	}

	/** True when this client has not been granted reqId during the window. */
	async quiet(reqId: string, windowMs = 250): Promise<boolean> {
		await sleep(windowMs);
		return !this.messages.some((m) => m.t === "granted" && m.reqId === reqId);
	}

	close(): void {
		this.stopHeartbeat();
		this.sock.destroy();
	}
}

async function familyOf(client: TestClient, wantFamily: string): Promise<string | null> {
	client.send({ t: "status" });
	const state = (await client.expect((m) => m.t === "status_resp")).state as {
		clients: { id: string; family: string }[];
	};
	return state.clients.find((entry) => entry.id === wantFamily)?.family ?? null;
}

async function startBroker(t: Context, overrides: Record<string, string> = {}): Promise<string> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "slotd-test-"));
	const socket = path.join(dir, "broker.sock");
	const env: Record<string, string> = {
		PI_SLOT_SOCKET: socket,
		PI_SLOT_MAX: "1",
		PI_SLOT_GRACE_MS: "300",
		PI_SLOT_CHILD_RESERVE_MS: "1500",
		PI_SLOT_TTL_MS: "3000",
		PI_SLOT_HOLD_MS: "600",
		PI_SLOT_SWEEP_MS: "100",
		PI_SLOT_CLOSE_GRACE_MS: "200",
		PI_SLOT_IDLE_EXIT_MS: "10000",
		...overrides,
	};
	const proc = spawn(process.execPath, [DAEMON], { env: { ...process.env, ...env }, stdio: ["ignore", "ignore", "pipe"] });
	const stderr: string[] = [];
	proc.stderr?.on("data", (chunk) => stderr.push(chunk.toString("utf8")));
	proc.on("error", (error) => stderr.push(`spawn error: ${error.message}`));
	t.after(() => {
		try {
			proc.kill("SIGKILL");
		} catch {
			// Already gone.
		}
		fs.rmSync(dir, { recursive: true, force: true });
	});
	for (let attempt = 0; attempt < 60 && !fs.existsSync(socket); attempt++) await sleep(30);
	assert.ok(fs.existsSync(socket), `broker did not create ${socket}: ${stderr.join("")}`);
	return socket;
}

test("one slot per endpoint, handed to the next waiter on release", async (t) => {
	const socket = await startBroker(t);
	const a = await TestClient.connect(socket, "a");
	const b = await TestClient.connect(socket, "b");

	a.send({ t: "acquire", reqId: "a1", endpoint: ENDPOINT });
	await a.granted("a1");
	b.send({ t: "acquire", reqId: "b1", endpoint: ENDPOINT });
	assert.ok(await b.quiet("b1"), "second family was granted while the first still held the slot");

	a.send({ t: "release", reqId: "a1" });
	await b.granted("b1");
	a.close();
	b.close();
});

test("the owning family keeps the slot while its work is unfinished", async (t) => {
	const socket = await startBroker(t);
	const parent = await TestClient.connect(socket, "parent");
	const child = await TestClient.connect(socket, "child");
	const outsider = await TestClient.connect(socket, "outsider");

	parent.send({ t: "link", childThreadId: "T-linked" });
	child.send({ t: "selfid", threadId: "T-linked" });

	parent.send({ t: "acquire", reqId: "p1", endpoint: ENDPOINT });
	await parent.granted("p1");
	outsider.send({ t: "acquire", reqId: "o1", endpoint: ENDPOINT });
	child.send({ t: "acquire", reqId: "c1", endpoint: ENDPOINT });

	parent.send({ t: "release", reqId: "p1" });
	await child.granted("c1");
	assert.ok(await outsider.quiet("o1"), "an unrelated family took the slot mid-family");

	parent.close();
	child.close();
	outsider.close();
});

test("a delegated child runs before the parent that spawned it", async (t) => {
	const socket = await startBroker(t);
	const parent = await TestClient.connect(socket, "parent");
	const child = await TestClient.connect(socket, "child");

	parent.send({ t: "acquire", reqId: "p1", endpoint: ENDPOINT });
	await parent.granted("p1");
	parent.send({ t: "link", childThreadId: "T-order" });
	child.send({ t: "selfid", threadId: "T-order" });

	// Barrier: the daemon must have linked the child into the parent's family before queueing.
	const linked = await familyOf(child, parent.id);
	assert.equal(linked, parent.id, "child was not adopted into the parent's family");

	// The parent queues its own resumption before the child queues anything.
	parent.send({ t: "acquire", reqId: "p2", endpoint: ENDPOINT });
	await parent.expect((m) => m.t === "queued" && m.reqId === "p2");
	child.send({ t: "acquire", reqId: "c1", endpoint: ENDPOINT });
	await child.expect((m) => m.t === "queued" && m.reqId === "c1");

	parent.send({ t: "release", reqId: "p1" });
	await child.granted("c1");
	assert.ok(await parent.quiet("p2", 150), "the parent resumed ahead of its own delegated child");

	parent.close();
	child.close();
});

test("an empty slot stays empty while a delegated child is still starting", async (t) => {
	const socket = await startBroker(t);
	const parent = await TestClient.connect(socket, "parent");
	const outsider = await TestClient.connect(socket, "outsider");
	const child = await TestClient.connect(socket, "child");

	parent.send({ t: "acquire", reqId: "p1", endpoint: ENDPOINT });
	await parent.granted("p1");
	parent.send({ t: "link", childThreadId: "T-starting" });
	parent.send({ t: "release", reqId: "p1" });

	outsider.send({ t: "acquire", reqId: "o1", endpoint: ENDPOINT });
	assert.ok(await outsider.quiet("o1"), "the slot was spent on an unrelated family mid-delegation");

	child.send({ t: "selfid", threadId: "T-starting" });
	child.send({ t: "acquire", reqId: "c1", endpoint: ENDPOINT });
	await child.granted("c1");
	child.send({ t: "release", reqId: "c1" });
	await outsider.granted("o1");

	parent.close();
	outsider.close();
	child.close();
});

test("a human-input hold reserves the slot, then expires", async (t) => {
	const socket = await startBroker(t);
	const parked = await TestClient.connect(socket, "parked");
	const other = await TestClient.connect(socket, "other");

	parked.send({ t: "acquire", reqId: "h1", endpoint: ENDPOINT });
	await parked.granted("h1");
	parked.send({ t: "hold", on: true, endpoint: ENDPOINT });
	parked.send({ t: "release", reqId: "h1" });

	other.send({ t: "acquire", reqId: "o1", endpoint: ENDPOINT });
	assert.ok(await other.quiet("o1"), "another family ran while the slot was reserved for a human answer");

	parked.send({ t: "hold", on: false });
	await other.granted("o1");
	parked.close();
	other.close();
});

test("a hold that is never released stops reserving after its window", async (t) => {
	const socket = await startBroker(t, { PI_SLOT_HOLD_MS: "300" });
	const parked = await TestClient.connect(socket, "parked");
	const other = await TestClient.connect(socket, "other");

	parked.send({ t: "hold", on: true, endpoint: ENDPOINT });
	other.send({ t: "acquire", reqId: "o1", endpoint: ENDPOINT });
	await other.granted("o1", 2_000);
	parked.close();
	other.close();
});

test("a wedged holder is reclaimed by the lease TTL", async (t) => {
	const socket = await startBroker(t, { PI_SLOT_TTL_MS: "400" });
	const wedged = await TestClient.connect(socket, "wedged");
	const next = await TestClient.connect(socket, "next");

	wedged.stopHeartbeat();
	wedged.send({ t: "acquire", reqId: "x1", endpoint: ENDPOINT });
	await wedged.granted("x1");
	next.send({ t: "acquire", reqId: "n1", endpoint: ENDPOINT });
	assert.ok(await next.quiet("n1"), "the slot was handed out while the wedged holder still leased it");

	await next.granted("n1", 3_000);
	wedged.close();
	next.close();
});

test("a queued request waits behind its own process's running request", async (t) => {
	const socket = await startBroker(t);
	const solo = await TestClient.connect(socket, "solo");
	const other = await TestClient.connect(socket, "other");
	solo.send({ t: "acquire", reqId: "outer", endpoint: ENDPOINT });
	await solo.granted("outer");
	solo.send({ t: "acquire", reqId: "next", endpoint: ENDPOINT });
	assert.ok(await solo.quiet("next"), "a process granted itself a second concurrent request");
	solo.send({ t: "release", reqId: "outer" });
	await solo.granted("next");
	void other;
	solo.close();
	other.close();
});

test("releasing every lease marks the family idle", async (t) => {
	const socket = await startBroker(t);
	const a = await TestClient.connect(socket, "a");
	a.send({ t: "acquire", reqId: "a1", endpoint: ENDPOINT });
	await a.granted("a1");
	a.send({ t: "release", reqId: "a1" });

	a.send({ t: "status" });
	const state = (await a.expect((m) => m.t === "status_resp")).state as {
		endpoints: { url: string; holders: unknown[]; queue: unknown[] }[];
	};
	const endpoint = state.endpoints.find((entry) => entry.url === ENDPOINT.replace(/\/+$/, ""));
	assert.ok(endpoint, "endpoint missing from status");
	assert.equal(endpoint.holders.length, 0);
	assert.equal(endpoint.queue.length, 0);
	a.close();
});
