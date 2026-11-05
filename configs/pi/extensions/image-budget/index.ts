import { resizeImage } from "@mariozechner/pi-coding-agent";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { createHash } from "node:crypto";

// Keeps every picture in a request small enough to fit the size cap Strata's host gateway puts on a
// request body (apps/host/server/index.mjs reads /v1/messages with readBody(req, 12*1024*1024) and
// answers 500 "Request body too large" above it, before the engine ever sees the turn). base64 costs
// 4/3 of the picture's bytes, so ~9 MB of picture bytes is the real wall, and pi re-sends every
// picture of the conversation on every turn - the cap is on the whole conversation, not one message.
//
// The cap is not configurable upstream: readBody takes the limit as a plain argument, no env var, no
// settings key, and the literal is written at each call site. So the fix has to be the payload.

// Per-image target, not a share of the budget. A per-image target keeps each picture's re-encoded
// bytes identical whichever turn it is sent on, so Strata's encoder cache (keyed by the image's hash)
// and the engine's prefix KV reuse keep hitting. A budget/n split would re-encode old pictures again
// every time a new one arrives and force a full re-prefill.
// Side 1024 rather than a larger one: the second wall is not the byte cap but the engine's picture
// encoder, which runs on 6 CPU threads here (no VRAM is free for the GPU reader) and gives up at
// VISION_ENCODE_S = 300 s per request. Measured on this box: 20 pictures at side 1280 blew past 300 s
// and the request died at 502, 12 at side 1024 finished in 166 s. vision.max_tokens already clamps
// each picture to 1024 image tokens, so extra pixels buy encode time and nothing else.
const MAX_SIDE = intEnv("PI_IMAGE_MAX_SIDE", 1024);
const MAX_IMAGE_BYTES = intEnv("PI_IMAGE_MAX_BYTES_KIB", 300) << 10; // raw encoded bytes per picture
const QUALITY = intEnv("PI_IMAGE_QUALITY", 82);
const BUDGET_BYTES = intEnv("PI_IMAGE_BUDGET_KIB", 6144) << 10; // base64 characters over all pictures
const KEEP_LAST = intEnv("PI_IMAGE_KEEP_LAST", 0); // 0: re-encode only, never drop

function intEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

function blocks(message: any): any[] | null {
  return Array.isArray(message?.content) ? message.content : null;
}

// A content block's picture bytes. A dropped picture becomes a text block in place, and the reference to
// it stays in the list, so every total has to skip it instead of reading `.data` off a text block.
function blockSize(block: any): number {
  return block?.type === "image" && typeof block.data === "string" ? block.data.length : 0;
}

function imageRefs(messages: any[]): { content: any[]; i: number }[] {
  const found: { content: any[]; i: number }[] = [];
  for (const m of messages) {
    const parts = blocks(m);
    if (!parts) continue;
    parts.forEach((p: any, i: number) => {
      if (p?.type === "image" && typeof p.data === "string") found.push({ content: parts, i });
    });
  }
  return found;
}

const cache = new Map<string, { data: string; mimeType: string }>(); // original bytes hash -> its re-encode

async function shrink(ref: { content: any[]; i: number }): Promise<boolean> {
  const block = ref.content[ref.i];
  const rawBytes = (block.data.length * 3) / 4;
  if (rawBytes <= MAX_IMAGE_BYTES) return false; // already cheap: leave the pixels alone

  const key = createHash("sha256").update(block.data).digest("hex");
  let done = cache.get(key);
  if (!done) {
    // resizeImage picks PNG or JPEG, then falls through JPEG quality and dimensions until maxBytes.
    done = null;
    for (const side of [MAX_SIDE, MAX_SIDE * 0.75, MAX_SIDE * 0.5]) {
      const out = await resizeImage(new Uint8Array(Buffer.from(block.data, "base64")), block.mimeType ?? "image/png", {
        maxWidth: Math.round(side),
        maxHeight: Math.round(side),
        maxBytes: MAX_IMAGE_BYTES,
        jpegQuality: QUALITY,
      });
      if (out?.data) { done = { data: out.data, mimeType: out.mimeType }; break; }
    }
    if (!done) return false; // unreadable or too broken to re-encode: send it as it was
    cache.set(key, done);
    if (cache.size > 240) cache.delete(cache.keys().next().value as string);
  }
  if (done.data === block.data) return false;
  ref.content[ref.i] = { type: "image", data: done.data, mimeType: done.mimeType };
  return true;
}

export default function (pi: ExtensionAPI) {
  pi.on("context", async (event: any) => {
    // Work on a copy: pi hands the live transcript's message objects here, and the TUI renders the same
    // image blocks. Mutating them would turn the chat's own pictures into the shrunk ones.
    const messages: any[] = structuredClone(event?.messages ?? []);
    const refs = imageRefs(messages);
    if (!refs.length) return;

    let changed = false;
    const total = () => refs.reduce((s, r) => s + blockSize(r.content[r.i]), 0);

    if (total() > BUDGET_BYTES) {
      for (const ref of refs) if (await shrink(ref)) changed = true;
    }
    if (KEEP_LAST > 0 && refs.length > KEEP_LAST) {
      for (const ref of refs.slice(0, refs.length - KEEP_LAST)) {
        const bytes = blockSize(ref.content[ref.i]);
        if (!bytes) continue; // already a placeholder from an earlier pass
        ref.content[ref.i] = {
          type: "text",
          text: `[image dropped to keep the request under ${BUDGET_BYTES >> 10} KiB of pictures: about ${(bytes * 0.75 / 1024) | 0} KiB]`,
        };
        changed = true;
      }
    }
    // Belt and braces: re-encoding has a floor, so with a great many pictures it can still not fit.
    if (total() > BUDGET_BYTES) {
      let left = total();
      for (const ref of refs) {
        if (left <= BUDGET_BYTES) break;
        const bytes = blockSize(ref.content[ref.i]);
        if (!bytes || (bytes * 0.75) / 1024 < 40) continue; // keep the cheap ones
        left -= bytes;
        ref.content[ref.i] = {
          type: "text",
          text: `[image dropped to keep the request under ${BUDGET_BYTES >> 10} KiB of pictures: about ${(bytes * 0.75 / 1024) | 0} KiB]`,
        };
        changed = true;
      }
    }
    if (changed) return { messages };
  });

  pi.registerCommand("image-budget", {
    description: "Show the picture size budget and what the current conversation costs",
    handler: async (_args, ctx: any) => {
      const messages: any[] = (ctx as any)?.getSessionMessages?.() ?? [];
      const refs = imageRefs(messages);
      const raw = refs.reduce((s, r) => s + blockSize(r.content[r.i]) * 0.75, 0);
      ctx.ui.notify(
        `pictures: ${refs.length}  base64 ${(refs.reduce((s, r) => s + blockSize(r.content[r.i]), 0) / 1024) | 0} KiB  raw ${(raw / 1024) | 0} KiB` +
        `  |  budget ${BUDGET_BYTES >> 10} KiB base64, ${MAX_IMAGE_BYTES >> 10} KiB each, max side ${MAX_SIDE}, quality ${QUALITY}, keep_last ${KEEP_LAST || "all"}`,
        { kind: "info" },
      );
    },
  });
}
