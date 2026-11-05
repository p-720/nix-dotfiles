// Integration tests: real pi processes against a scripted model endpoint.
// Proves the gate serializes gated requests and leaves non-gated models alone.
//   node --test ~/.pi/agent/extensions/model-slot/test/gate.test.mts

import assert from "node:assert/strict";
import test from "node:test";

import { FREE_PORT, GATED_PORT, plainResponder, runPi, sandbox, scriptedServer } from "./helpers.mts";

test("gated requests from separate pi processes run one at a time", async (t) => {
	const gated = scriptedServer(GATED_PORT, 500, plainResponder("slot-ok"));
	await gated.start();
	const box = await sandbox(t, gated.url);
	try {
		const runs = await Promise.all(["one", "two", "three"].map((label) => runPi(box.dir, box.env, "slotgated/test", `say ${label}`)));
		for (const run of runs) {
			assert.equal(run.code, 0, `pi failed: ${run.err}`);
			assert.match(run.out.toLowerCase(), /slot-ok/, "pi produced no model output");
		}
		assert.equal(gated.requests().length, 3, "the gated endpoint did not see one request per pi process");
		assert.equal(gated.maxConcurrent(), 1, "the gated endpoint saw concurrent requests");
	} finally {
		await gated.stop();
	}
});

test("a non-gated model keeps running in parallel while the gate is busy", async (t) => {
	const gated = scriptedServer(GATED_PORT, 500, plainResponder("slot-ok"));
	const free = scriptedServer(FREE_PORT, 600, plainResponder("free-ok"));
	await gated.start();
	await free.start();
	const box = await sandbox(t, gated.url);
	try {
		const runs = await Promise.all([
			runPi(box.dir, box.env, "slotgated/test", "gate one"),
			runPi(box.dir, box.env, "slotgated/test", "gate two"),
			runPi(box.dir, box.env, "slotfree/test", "free one"),
			runPi(box.dir, box.env, "slotfree/test", "free two"),
		]);
		for (const run of runs) assert.equal(run.code, 0, `pi failed: ${run.err}`);
		assert.equal(free.maxConcurrent(), 2, "non-gated requests were serialized");
		assert.equal(gated.maxConcurrent(), 1, "gated requests were not serialized");
	} finally {
		await gated.stop();
		await free.stop();
	}
});
