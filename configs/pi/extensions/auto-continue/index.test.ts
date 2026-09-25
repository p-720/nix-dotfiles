import { describe, expect, it } from "vitest";
import { shouldAutoContinue } from "./index.ts";

describe("shouldAutoContinue", () => {
	const base = { willRetry: false, userPromptPending: false, hasPendingMessages: false };

	it("continues on a plain compaction", () => {
		expect(shouldAutoContinue(base)).toBe(true);
	});

	it("skips when the aborted turn is auto-retried (overflow recovery)", () => {
		expect(shouldAutoContinue({ ...base, willRetry: true })).toBe(false);
	});

	it("skips while a user prompt is in flight (pre-prompt compaction)", () => {
		expect(shouldAutoContinue({ ...base, userPromptPending: true })).toBe(false);
	});

	it("skips when messages are already queued", () => {
		expect(shouldAutoContinue({ ...base, hasPendingMessages: true })).toBe(false);
	});
});
