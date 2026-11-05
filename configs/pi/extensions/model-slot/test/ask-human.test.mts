// ask_human end to end: the model calls it, the tool answers without a UI, and the follow-up
// request re-takes the slot instead of deadlocking behind the lease the turn just released.
//   node --test ~/.pi/agent/extensions/model-slot/test/ask-human.test.mts

import assert from "node:assert/strict";
import test from "node:test";

import { GATED_PORT, chunk, plainResponder, runPi, sandbox, scriptedServer } from "./helpers.mts";

const toolCallResponder = () => {
	let calls = 0;
	return (_request: { body: string; index: number }) => {
		calls += 1;
		if (calls === 1) {
			return [
				chunk(
					null,
					[
						{
							index: 0,
							id: "call-ask-1",
							type: "function",
							function: { name: "ask_human", arguments: JSON.stringify({ question: "Red or blue?", options: ["red", "blue"] }) },
						},
					],
					"tool_calls",
					calls,
				),
			];
		}
		return [chunk("proceeded-with-a-guess", null, "stop", calls)];
	};
};

test("ask_human is offered to a gated model, answers in headless mode, and the turn continues", async (t) => {
	const gated = scriptedServer(GATED_PORT, 200, toolCallResponder());
	await gated.start();
	const box = await sandbox(t, gated.url);
	try {
		const run = await runPi(box.dir, box.env, "slotgated/test", "pick a colour");
		assert.equal(run.code, 0, `pi failed: ${run.err}`);

		const requests = gated.requests();
		assert.ok(requests.length >= 2, `the turn stopped after the tool call (saw ${requests.length} request(s))`);
		assert.match(requests[0]!, /ask_human/, "the gated model was not offered ask_human");
		assert.match(requests[1]!, /No interactive surface/, "the headless answer never reached the model");
		assert.match(run.out.toLowerCase(), /proceeded-with-a-guess/, "the model never continued after ask_human");
		assert.equal(gated.maxConcurrent(), 1, "the follow-up request overlapped another request");
	} finally {
		await gated.stop();
	}
});
