// ~/.pi/agent/extensions/image-context.ts
import type { ExtensionAPI, AgentMessage } from "@earendil-works/pi-coding-agent";

// Keep at most MAX_IMAGES images per LLM call: newest survive, older ones
// (user attachments and tool results) become a text placeholder. Without this,
// attached images accumulate across turns and providers limited to one image
// per prompt reject the request with:
//   400 "At most 1 image(s) may be provided in one prompt"
// Set MAX_IMAGES = 0 to strip every image, including the current one.
const MAX_IMAGES = 1;
const PLACEHOLDER = "[Image omitted from context history]";

type ContentPart = { type: string; [k: string]: unknown };

export function stripOldImages(messages: AgentMessage[]): void {
  let kept = 0;
  // Walk newest -> oldest so the most recent images survive.
  for (let i = messages.length - 1; i >= 0; i--) {
    const content = (messages[i] as { content?: unknown }).content;
    if (!Array.isArray(content)) continue;
    for (let j = content.length - 1; j >= 0; j--) {
      const part = content[j] as ContentPart | undefined;
      if (part?.type !== "image") continue;
      if (kept < MAX_IMAGES) kept++;
      else (content as ContentPart[])[j] = { type: "text", text: PLACEHOLDER };
    }
  }
}

export default function (pi: ExtensionAPI) {
  // `context` fires before every LLM call with a deep copy of the session
  // messages; returned messages replace the outgoing payload.
  pi.on("context", (event) => {
    stripOldImages(event.messages);
    return { messages: event.messages };
  });
}
