// Shared pieces for the pi-level integration tests: a scripted model endpoint and a sandboxed pi config.

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

export const EXT_DIR = path.join(import.meta.dirname, "..");
export const GATED_PORT = 40211;
export const FREE_PORT = 40212;

export type ChatRequest = { body: string; index: number };
/** Chunks to write for a request, in wire order. */
export type Responder = (request: ChatRequest) => string[];

export type Server = {
	url: string;
	requests: () => string[];
	maxConcurrent: () => number;
	start: () => Promise<void>;
	stop: () => Promise<void>;
};

export function chunk(content: string | null, toolCalls: unknown[] | null, finish: string | null, id: number): string {
	const delta: Record<string, unknown> = { role: "assistant" };
	if (content !== null) delta.content = content;
	if (toolCalls !== null) delta.tool_calls = toolCalls;
	return `data: ${JSON.stringify({
		id: `chatcmpl-${id}`,
		object: "chat.completion.chunk",
		created: Math.floor(Date.now() / 1000),
		model: "test",
		choices: [{ index: 0, delta, finish_reason: finish }],
		usage: { prompt_tokens: 8, completion_tokens: 2, total_tokens: 10 },
	})}\n\n`;
}

export function scriptedServer(port: number, delayMs: number, respond: Responder): Server {
	let inFlight = 0;
	let maxConcurrent = 0;
	const bodies: string[] = [];
	const server = http.createServer((req, res) => {
		if (req.method !== "POST") {
			res.writeHead(404).end();
			return;
		}
		let body = "";
		req.on("data", (chunk) => {
			body += chunk.toString("utf8");
		});
		req.on("end", () => {
			const index = bodies.push(body) - 1;
			inFlight += 1;
			maxConcurrent = Math.max(maxConcurrent, inFlight);
			res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
			const timer = setTimeout(() => {
				for (const line of respond({ body, index })) res.write(line);
				res.write("data: [DONE]\n\n");
				res.end();
				inFlight -= 1;
			}, delayMs);
			timer.unref?.();
		});
	});
	return {
		url: `http://127.0.0.1:${port}/v1`,
		requests: () => [...bodies],
		maxConcurrent: () => maxConcurrent,
		start: () =>
			new Promise<void>((resolve) => {
				server.listen(port, "127.0.0.1", resolve);
			}),
		stop: () =>
			new Promise<void>((resolve) => {
				server.close(() => resolve());
			}),
	};
}

export function plainResponder(content: string): Responder {
	return (_request) => [chunk(content, null, "stop", 1)];
}

export function modelProvider(name: string, port: number) {
	return {
		baseUrl: `http://127.0.0.1:${port}/v1`,
		apiKey: "slot-test-key",
		api: "openai-completions",
		models: [
			{
				id: "test",
				name: `${name} test`,
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 8192,
				maxTokens: 64,
			},
		],
	};
}

export type Sandbox = { dir: string; env: Record<string, string> };

export async function sandbox(t: { after: (fn: () => void) => void }, gatedUrl: string): Promise<Sandbox> {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "slot-pi-"));
	const extDir = path.join(dir, "extensions", "model-slot");
	fs.mkdirSync(extDir, { recursive: true });
	for (const file of ["index.ts", "client.ts", "slotd.mts"]) fs.copyFileSync(path.join(EXT_DIR, file), path.join(extDir, file));
	fs.writeFileSync(
		path.join(extDir, "config.json"),
		JSON.stringify({ endpoints: [gatedUrl], maxConcurrent: 1, familyIdleGraceMs: 10_000, humanHoldMs: 180_000, notifyAfterMs: 60_000, leaseTtlMs: 30_000 }),
	);
	fs.writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ compaction: { enabled: false } }));
	fs.writeFileSync(
		path.join(dir, "models.json"),
		JSON.stringify({ providers: { slotgated: modelProvider("slotgated", GATED_PORT), slotfree: modelProvider("slotfree", FREE_PORT) } }),
	);
	t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
	return {
		dir,
		env: {
			...process.env,
			PI_CODING_AGENT_DIR: dir,
			PI_SLOT_SOCKET: path.join(dir, "slot.sock"),
			PI_SLOT_CONFIG: path.join(extDir, "config.json"),
		},
	};
}

export type PiRun = { code: number; out: string; err: string };

export function runPi(sandboxDir: string, env: Record<string, string>, model: string, prompt: string): Promise<PiRun> {
	return new Promise((resolve) => {
		const proc = spawn(process.env.PI_BIN ?? "pi", ["-p", prompt, "--model", model, "--no-session", "--no-builtin-tools"], {
			cwd: sandboxDir,
			env,
			stdio: ["ignore", "pipe", "pipe"],
		});
		let out = "";
		let err = "";
		proc.stdout.on("data", (chunk) => {
			out += chunk.toString("utf8");
		});
		proc.stderr.on("data", (chunk) => {
			err += chunk.toString("utf8");
		});
		proc.on("exit", (code) => resolve({ code: code ?? -1, out, err }));
		proc.on("error", (error) => resolve({ code: -1, out, err: `${err}\nspawn error: ${error.message}` }));
	});
}
