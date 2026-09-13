// ~/.pi/agent/extensions/image-context.ts
//
// Keeps at most MAX_IMAGES images in every outgoing LLM payload so providers
// with a per-prompt image limit (e.g. vLLM --limit-mm-per-prompt {"image":
// {"count":1}}) don't 400 with "At most 1 image(s) may be provided in one
// prompt" once older images accumulate in history.
//
// vLLM prefix-cache semantics this is designed around (v0.28.0, verified in
// vllm/v1/core/kv_cache_utils.py: block hash = chain(parent hash, block
// tokens, (mm identifier, offset-in-block) for blocks covering an image):
//   - Any change at token position P invalidates every block after P.
//   - An image whose placeholder tokens AND pixel hash are unchanged keeps
//     its block hashes stable across calls -> a permanent prefix-cache hit,
//     no matter how much history is appended after it.
// So the newest image is NEVER moved: it stays in its original message and
// becomes part of the stable prefix. Only strictly older images are evicted,
// replaced by a fixed placeholder string (stable across all later calls).
// The one unavoidable miss is the eviction event itself: when a new image
// arrives, the previous image's position changes and the blocks after it
// (the previous assistant reply + the new turn) are recomputed once.
//
// Sessions are never modified: the `context` hook receives a deep copy and
// only the outgoing payload is transformed.
import type { ExtensionAPI, AgentMessage } from "@earendil-works/pi-coding-agent";

const MAX_IMAGES = 1;
const PLACEHOLDER = "[Image omitted from context history]";

type ContentPart = { type: string; [k: string]: unknown };
type ContentMessage = {
  role: string;
  content?: string | ContentPart[];
  [k: string]: unknown;
};

function contentParts(m: ContentMessage): ContentPart[] | null {
  const c = m.content;
  return Array.isArray(c) ? c : null;
}

/**
 * Transform a payload in place: keep the newest MAX_IMAGES image parts (in
 * their original positions), replace every older image part with a fixed
 * placeholder. Returns the transformed list (the deep copy handed to the
 * `context` hook; safe to mutate).
 */
export function prepareImagePayload(messages: AgentMessage[]): AgentMessage[] {
  const msgs = messages as unknown as ContentMessage[];
  let kept = 0;
  // Walk newest -> oldest (message order, then part order within a message).
  for (let i = msgs.length - 1; i >= 0; i--) {
    const parts = contentParts(msgs[i]);
    if (!parts) continue;
    for (let j = parts.length - 1; j >= 0; j--) {
      if (parts[j]?.type !== "image") continue;
      if (kept < MAX_IMAGES) kept++;
      else parts[j] = { type: "text", text: PLACEHOLDER };
    }
  }
  return messages;
}

export default function (pi: ExtensionAPI) {
  // Fires before every LLM call with a deep copy of the session messages.
  pi.on("context", (event) => {
    prepareImagePayload(event.messages);
    return { messages: event.messages };
  });
}
