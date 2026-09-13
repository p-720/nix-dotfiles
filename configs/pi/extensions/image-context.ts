// ~/.pi/agent/extensions/image-context.ts
//
// Vision via a side channel — images never enter the main prompt.
//
//   user message (text + image)
//     │
//     ├─ context hook: every image part → stable text placeholder
//     │    "[image: img_ab12cd34]"  (payload becomes 100% text)
//     │
//     ├─ main LLM decides it needs pixels → calls
//     │    inspect_image({ image_id, prompt })
//     │
//     ├─ tool handler: isolated single-turn request to the same vLLM
//     │    [system, user(image, prompt)]  →  answer text
//     │
//     └─ tool result: the answer, in the main (text-only) history
//
// Why: the 3090 vLLM runs --limit-mm-per-prompt {"image":{"count":1}} with
// prefix caching (hybrid GDN, --mamba-cache-mode align). A block hash chains
// the parent hash with the multimodal hash of any image it covers, so a
// changing image position breaks every block after it. With no images in the
// main payload, history is purely append-only → prefix hits never break, and
// the 1-image limit can't fire at all. Repeat questions about the same image
// share the side prompt's [system + image] prefix, so only the question and
// answer recompute (the ViT output is mm-hash cached — never re-encoded).
//
// Session files are never modified: the `context` hook receives a deep copy.
// The image registry is in-memory per pi process; a process that starts with
// images in history re-registers them on its first LLM call, so old images
// stay inspectable.

import type { ExtensionAPI, AgentMessage } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { Type } from "typebox";

type ImagePart = { type: "image"; data: string; mimeType: string };
type ContentPart = { type: string; [k: string]: unknown };
type ContentMessage = {
  role: string;
  content?: string | ContentPart[];
  [k: string]: unknown;
};

const PLACEHOLDER = (id: string) =>
  `[image: ${id} — you cannot see this image; call inspect_image to examine it]`;
const IMAGE_POLICY =
  "Images in this conversation appear as placeholders like [image: img_x] and you have no direct visual input. " +
  "Whenever a question, task, or user request involves an attached image, call inspect_image with that image's id " +
  "(as many times as needed, with different questions) BEFORE answering. Never guess at image contents.";
const ANALYST_SYSTEM =
  "You are a precise image analyst serving a coding agent that can only see your text. " +
  "Answer the question exactly and completely: quote exact text, code, values and labels verbatim, " +
  "describe layout and relationships, and say explicitly what is not visible when asked.";
const SIDE_TIMEOUT_MS = 120_000;
const SIDE_MAX_TOKENS = 500;

/** Same provider pi uses for the main model — single source of truth is
 *  ~/.pi/agent/models.json (env vars override). */
function resolveVisionTarget(): { baseUrl: string; apiKey: string; model: string } {
  const cfg = { baseUrl: "http://127.0.0.1:18020/v1", apiKey: "", model: "qwen3.8-27b" };
  try {
    const mj = JSON.parse(readFileSync(`${homedir()}/.pi/agent/models.json`, "utf8"));
    const p = mj?.providers?.[process.env.IMAGE_PROVIDER ?? "qwen38-huge"];
    if (p) {
      cfg.baseUrl = p.baseUrl ?? cfg.baseUrl;
      cfg.apiKey = p.apiKey ?? cfg.apiKey;
      cfg.model = p.models?.[0]?.id ?? cfg.model;
    }
  } catch {}
  return {
    baseUrl: process.env.VLLM_BASE_URL ?? cfg.baseUrl,
    apiKey: process.env.VLLM_API_KEY ?? cfg.apiKey,
    model: process.env.VLLM_MODEL ?? cfg.model,
  };
}

const vision = resolveVisionTarget();

/** Read an image from disk for direct (non-registry) inspection. */
const EXT_MIME: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
  ".bmp": "image/bmp",
};
function imageFromFilePath(p: string): ImagePart | null {
  const ext = (p.slice(p.lastIndexOf(".")).toLowerCase()) as keyof typeof EXT_MIME;
  const mime = EXT_MIME[ext];
  if (!mime) return null;
  try {
    const data = readFileSync(p).toString("base64");
    return { type: "image", data, mimeType: mime };
  } catch {
    return null;
  }
}

/** id = 8 hex chars of the image bytes: stable across calls and turns, so
 *  placeholders are byte-identical forever and the side prompt's [system +
 *  image] prefix is reusable across follow-up questions. */
const imageId = (data: string) => "img_" + createHash("sha256").update(data).digest("hex").slice(0, 8);

/** Image data seen so far in this process, keyed by id. */
const registry = new Map<string, ImagePart>();

async function inspect(img: ImagePart, question: string): Promise<string> {
  const res = await fetch(`${vision.baseUrl}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${vision.apiKey}`,
    },
    signal: AbortSignal.timeout(SIDE_TIMEOUT_MS),
    body: JSON.stringify({
      model: vision.model,
      // image BEFORE the question: follow-ups share the [system + image]
      // prefix, so only the question and answer recompute.
      messages: [
        { role: "system", content: ANALYST_SYSTEM },
        {
          role: "user",
          content: [
            { type: "image_url", image_url: { url: `data:${img.mimeType};base64,${img.data}` } },
            { type: "text", text: question },
          ],
        },
      ],
      max_tokens: SIDE_MAX_TOKENS,
      temperature: 0.2,
    }),
  });
  if (!res.ok) {
    throw new Error(`vision side request failed: HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
  }
  const j = (await res.json()) as { choices?: { message?: { content?: string } }[] };
  const text = j.choices?.[0]?.message?.content?.trim();
  return text ? `Image ${imageId(img.data)}: ${text}` : "(image analysis returned no text)";
}

export default function (pi: ExtensionAPI) {
  // Before every LLM call: swap every image part for a stable placeholder.
  // Synchronous — no latency on the main path; analysis is lazy (tool call).
  pi.on("context", (event) => {
    for (const m of event.messages as unknown as ContentMessage[]) {
      const parts = Array.isArray(m.content) ? m.content : null;
      if (!parts) continue;
      for (let i = 0; i < parts.length; i++) {
        const p = parts[i];
        if (p?.type !== "image") continue;
        const ip = p as ImagePart;
        const id = imageId(ip.data);
        registry.set(id, ip);
        parts[i] = { type: "text", text: PLACEHOLDER(id) };
      }
    }
    return { messages: event.messages };
  });

  // Standing policy in the system prompt: survives history compaction and
  // applies no matter how far back the image sits. Constant text -> stable
  // hash; appended once (idempotent across retries of the same request).
  pi.on("before_provider_request", (event) => {
    const msgs = event?.payload?.messages;
    if (!Array.isArray(msgs)) return;
    const sys = msgs.find((m) => m?.role === "system");
    if (sys && typeof sys.content === "string" && !sys.content.includes(IMAGE_POLICY)) {
      sys.content += "\n\n" + IMAGE_POLICY;
    }
  });

  pi.registerTool({
    name: "inspect_image",
    label: "Inspect image",
    description:
      "Examine an image — you cannot see images directly, this is the only way. " +
      "Pass image_id (from a placeholder like '[image: img_ab12cd34 ...]') for an image in this conversation, " +
      "or file_path for any image file on disk (png/jpg/webp/gif/bmp). " +
      "Runs an isolated vision request and returns the answer; call again with a different prompt for more detail.",
    parameters: Type.Object({
      image_id: Type.Optional(
        Type.String({ description: "Id from the image placeholder, e.g. img_ab12cd34 (in-context image)" }),
      ),
      file_path: Type.Optional(
        Type.String({ description: "Path to an image file on disk (png/jpg/webp/gif/bmp) — use when no placeholder id is available, e.g. after compaction" }),
      ),
      prompt: Type.String({ description: "What to find out about the image (e.g. 'list the connections to service B')" }),
    }),
    async execute(_toolCallId, params) {
      let img: ImagePart | undefined;
      if (params.image_id) {
        img = registry.get(params.image_id);
        if (!img) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Unknown image id '${params.image_id}': it is not in this session's placeholders. If you know the file path, retry with file_path.`,
              },
            ],
            details: {},
          };
        }
      } else if (params.file_path) {
        img = imageFromFilePath(params.file_path);
        if (!img) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Cannot read image file '${params.file_path}': not found or unsupported type (need .png/.jpg/.jpeg/.webp/.gif/.bmp).`,
              },
            ],
            details: {},
          };
        }
        // Register so the same file can also be reached by its id afterwards.
        registry.set(imageId(img.data), img);
      } else {
        return {
          content: [
            { type: "text" as const, text: "Provide either image_id (from a placeholder) or file_path (path to an image file)." },
          ],
          details: {},
        };
      }
      try {
        return { content: [{ type: "text" as const, text: await inspect(img, params.prompt) }], details: {} };
      } catch (err) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Image service error for ${params.image_id}: ${err instanceof Error ? err.message : String(err)}. The image stays available; retry or ask the user.`,
            },
          ],
          details: {},
        };
      }
    },
  });
}
