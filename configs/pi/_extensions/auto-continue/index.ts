/**
 * auto-continue — resume the agent after compaction instead of waiting for
 * the user to type "continue".
 *
 * On every `session_compact` (manual /compact, auto threshold, overflow):
 *
 *   - willRetry (overflow recovery)    → skip: pi retries the aborted turn itself
 *   - user prompt in flight            → skip: that prompt drives the next turn
 *   - messages already queued          → skip: they drive the continuation
 *   - otherwise:
 *       run still active (post-run auto-compaction) → defer to agent_settled,
 *                                                    when the session is idle
 *       idle (manual /compact)         → send immediately
 *
 * The message is delivered as "followUp": it runs immediately when the
 * session is idle, and is queued (drained by the agent loop) when a run is
 * active — so one call shape is safe in every state.
 *
 * The prompt tells the model to resume unfinished work from the compaction
 * summary, or to stop with a one-line confirmation when the last exchange
 * was complete — a compaction after a finished task costs at most one cheap
 * turn instead of spiralling into invented work.
 *
 * `/autocontinue on|off|status` toggles it for the session (default: on in
 * TUI/RPC, off in print/JSON mode).
 *
 * Note: other extensions reacting to session_compact (e.g. evidence-compact's
 * bridge message) may deliver their own message too; if both fire the model
 * gets two short user messages — redundant but harmless.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const CONTINUE_PROMPT =
	"[auto-continue] The conversation was just compacted. Check the compaction " +
	"summary at the top of the context: if the current task is unfinished or lists " +
	"next steps, continue that work now without asking. If the last exchange was " +
	"fully complete and nothing is pending, do not start new work — reply with one " +
	"line describing the finished state and stop.";

export interface CompactContext {
	/** event.willRetry — overflow recovery auto-retries the aborted turn. */
	willRetry: boolean;
	/** A user input was received but its message has not reached the agent yet. */
	userPromptPending: boolean;
	/** Steering/follow-up messages already queued; they drive the continuation. */
	hasPendingMessages: boolean;
}

/** The single decision made per session_compact. */
export function shouldAutoContinue(c: CompactContext): boolean {
	if (c.willRetry) return false;
	if (c.userPromptPending) return false;
	if (c.hasPendingMessages) return false;
	return true;
}

export default function (pi: ExtensionAPI) {
	let enabled = true;
	// Set by non-extension `input` events, cleared when the message actually
	// reaches the agent (`message_start`). Distinguishes pre-prompt compaction
	// (user prompt in flight — skip) from idle compaction (send).
	let userPromptPending = false;
	// Set when compaction happened while a run was still active; delivered on
	// agent_settled, where the session is guaranteed idle.
	let wantsContinue = false;

	const deliver = (ctx: ExtensionContext) => {
		wantsContinue = false;
		ctx.ui.notify("auto-continue: resuming after compaction", "info");
		pi.sendUserMessage(CONTINUE_PROMPT, { deliverAs: "followUp" });
	};

	pi.on("session_start", (_event, ctx) => {
		enabled = ctx.mode === "tui" || ctx.mode === "rpc";
	});

	pi.on("input", (event) => {
		if (event.source !== "extension") userPromptPending = true;
	});

	pi.on("message_start", (event) => {
		if ((event.message as { role?: string }).role === "user") userPromptPending = false;
	});

	pi.on("session_compact", async (event, ctx) => {
		if (!enabled) return;
		if (
			!shouldAutoContinue({
				willRetry: event.willRetry,
				userPromptPending,
				hasPendingMessages: ctx.hasPendingMessages(),
			})
		) {
			return;
		}
		if (ctx.isIdle()) {
			deliver(ctx);
		} else {
			wantsContinue = true; // delivered from agent_settled
		}
	});

	pi.on("agent_settled", (_event, ctx) => {
		if (!wantsContinue) return;
		if (userPromptPending || ctx.hasPendingMessages()) {
			wantsContinue = false; // the user has their own continuation
			return;
		}
		deliver(ctx);
	});

	pi.registerCommand("autocontinue", {
		description: "Toggle auto-continue after compaction (on|off|status)",
		handler: async (args, ctx) => {
			const arg = args.trim().toLowerCase();
			if (arg === "on") enabled = true;
			else if (arg === "off") enabled = false;
			ctx.ui.notify(`auto-continue: ${enabled ? "on" : "off"}`, "info");
		},
	});
}
