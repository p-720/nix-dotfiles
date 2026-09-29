/**
 * Clojure bracket guard
 *
 * The model frequently emits unbalanced parens when editing Clojure.
 * This extension pre-validates `edit`/`write` calls on .clj/.cljs/.cljc/.cljx/.edn
 * files and blocks the tool call with a precise diagnostic when the resulting
 * file would have unbalanced brackets.
 *
 * Also registers /clojure-check <file> for manual on-demand linting.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

const CLOJURE_EXTENSIONS = new Set([".clj", ".cljs", ".cljc", ".cljx", ".edn"]);

const OPENERS: Record<string, boolean> = { "(": true, "[": true, "{": true };
const MATCHING_OPEN: Record<string, string> = { ")": "(", "]": "[", "}": "{" };

interface BalanceProblem {
  line: number;
  col: number;
  description: string;
}

function isClojurePath(path: string): boolean {
  const base = path.replace(/\\/g, "/").split("/").pop() ?? path;
  const dot = base.lastIndexOf(".");
  return dot > 0 && CLOJURE_EXTENSIONS.has(base.slice(dot).toLowerCase());
}

/**
 * Lexical bracket balance check. Tracks line numbers; skips strings
 * (with \ escapes), ; comments, and \char literals so that brackets
 * inside them (e.g. ")", ; ), \( ) do not count.
 */
function checkBalance(src: string): BalanceProblem | null {
  const n = src.length;
  const stack: { ch: string; line: number }[] = [];
  let i = 0;
  let line = 1;
  let lineStart = 0;

  while (i < n) {
    const c = src[i];
    if (c === "\n") {
      line++;
      lineStart = i + 1;
      i++;
      continue;
    }
    if (c === ";") {
      // Comment runs to end of line; brackets inside are inert.
      let j = i;
      while (j < n && src[j] !== "\n") j++;
      i = j;
      continue;
    }
    if (c === '"') {
      // String runs to the unescaped quote (Clojure strings may span lines);
      // ; and brackets inside are inert.
      let j = i + 1;
      while (j < n) {
        if (src[j] === "\\") {
          j += 2;
          continue;
        }
        if (src[j] === '"') break;
        j++;
      }
      const nl = src.lastIndexOf("\n", j - 1);
      if (nl >= i) {
        line += countNewlines(src, i, nl + 1);
        lineStart = nl + 1;
      }
      i = j < n && src[j] === '"' ? j + 1 : j;
      continue;
    }
    if (c === "\\") {
      // \char literal: the next character is a literal, not a delimiter.
      i += 2;
      continue;
    }
    if (OPENERS[c]) {
      stack.push({ ch: c, line });
      i++;
      continue;
    }
    const open = MATCHING_OPEN[c];
    if (open) {
      if (stack.length === 0) {
        return { line, col: i - lineStart + 1, description: `"${c}" at line ${line} has no matching opener` };
      }
      const top = stack[stack.length - 1];
      if (top.ch !== open) {
        return { line, col: i - lineStart + 1, description: `"${c}" at line ${line} does not match innermost opener "${top.ch}" (opened at line ${top.line})` };
      }
      stack.pop();
      i++;
      continue;
    }
    i++;
  }

  if (stack.length > 0) {
    const unclosed = stack.map((s) => `"${s.ch}" from line ${s.line}`).join(", ");
    return {
      line,
      col: 1,
      description: `EOF reached with ${stack.length} unclosed bracket(s): ${unclosed}`,
    };
  }
  return null;
}

function countNewlines(src: string, from: number, to: number): number {
  let count = 0;
  for (let k = from; k < to && k < src.length; k++) {
    if (src[k] === "\n") count++;
  }
  return count;
}

interface EditOp {
  oldText: string;
  newText: string;
}

// Models (Opus, GLM) sometimes send edits as a JSON string or a bare object;
// mirror the edit tool's own argument normalization so simulation sees an array.
// The tool's prepareArguments also wraps a legacy top-level {oldText,newText}
// (no edits key); mirror that, or such calls slip past validation.
function normalizeEdits(input: unknown): EditOp[] | null {
  const obj = input as { edits?: unknown; oldText?: unknown; newText?: unknown } | null;
  let edits = obj?.edits;
  if (typeof edits === "string") {
    try {
      const parsed = JSON.parse(edits);
      edits = Array.isArray(parsed) ? parsed : parsed && typeof parsed === "object" ? [parsed] : null;
    } catch {
      return null;
    }
  }
  if (edits && !Array.isArray(edits) && typeof edits === "object" && "oldText" in (edits as object)) {
    edits = [edits];
  }
  if (obj && typeof obj.oldText === "string" && typeof obj.newText === "string") {
    edits = Array.isArray(edits)
      ? [...edits, { oldText: obj.oldText, newText: obj.newText }]
      : [{ oldText: obj.oldText, newText: obj.newText }];
  }
  if (!Array.isArray(edits)) return null;
  // Empty oldText: the real tool rejects it itself; skip like other tool-handled errors.
  const ops = edits.filter(
    (e): e is EditOp =>
      e &&
      typeof e === "object" &&
      typeof (e as EditOp).oldText === "string" &&
      (e as EditOp).oldText.length > 0 &&
      typeof (e as EditOp).newText === "string",
  );
  return ops.length > 0 ? ops : null;
}

// Apply edits the way the edit tool does: every oldText matches the ORIGINAL
// content exactly once, then replacements are applied at those positions.
// Returns the simulated result, or null if any oldText is missing/duplicated —
// in that case the real tool produces its own (more accurate) error.
function simulateEdit(original: string, edits: EditOp[]): string | null {
  const matches = edits.map((e) => {
    const idx = original.indexOf(e.oldText);
    if (idx === -1) return null;
    if (original.indexOf(e.oldText, idx + 1) !== -1) return null;
    return { idx, len: e.oldText.length, newText: e.newText };
  });
  if (matches.some((m) => m === null)) return null;
  const sorted = (matches as NonNullable<(typeof matches)[number]>[]).sort((a, b) => a.idx - b.idx);
  for (let k = 1; k < sorted.length; k++) {
    if (sorted[k - 1].idx + sorted[k - 1].len > sorted[k].idx) return null;
  }
  let content = original;
  for (let k = sorted.length - 1; k >= 0; k--) {
    const m = sorted[k];
    content = content.slice(0, m.idx) + m.newText + content.slice(m.idx + m.len);
  }
  return content;
}

// Lowest edit index (1-based) whose application first breaks balance.
// Each prefix is applied to the ORIGINAL content (same as simulateEdit), not
// sequentially: an earlier newText may contain a later oldText as a substring,
// which would relocate the later edit and skew the reported index.
function findOffendingEdit(original: string, edits: EditOp[]): number {
  for (let k = 1; k <= edits.length; k++) {
    const content = simulateEdit(original, edits.slice(0, k));
    if (content !== null && checkBalance(content) !== null) return k;
  }
  return edits.length;
}

function blockReason(path: string, problem: BalanceProblem, editNote: string | null): string {
  const note = editNote ? ` after applying ${editNote}` : "";
  return `Blocked: unbalanced brackets in ${path}${note}.\n  ${problem.description}\nFix the brackets and retry the edit.`;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "write") {
      const input = event.input as { path?: string; content?: string };
      if (typeof input.path !== "string" || !isClojurePath(input.path)) return;
      if (typeof input.content !== "string") return;
      const problem = checkBalance(input.content);
      if (problem) return { block: true, reason: blockReason(input.path, problem, null) };
      return;
    }

    if (event.toolName !== "edit") return;
    const input = event.input as { path?: string; edits?: unknown };
    if (typeof input.path !== "string" || !isClojurePath(input.path)) return;
    const edits = normalizeEdits(input);
    if (!edits) return;

    // The tool resolves relative paths against the session cwd.
    const filePath = isAbsolute(input.path) ? input.path : join(ctx?.cwd ?? "", input.path);
    let original: string;
    try {
      // The edit tool matches oldText against LF-normalized content (CRLF
      // files are normalized, edited, then restored). Mirror it, or multi-line
      // oldText never matches a CRLF file and validation silently skips.
      original = (await readFile(filePath, "utf-8")).replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    } catch {
      return; // file missing/unreadable: the edit tool reports that itself
    }

    // A file that is already unbalanced is not this edit's fault; blocking
    // would make it impossible to work on a broken file.
    if (checkBalance(original) !== null) return;

    const simulated = simulateEdit(original, edits);
    if (simulated === null) return;

    const problem = checkBalance(simulated);
    if (!problem) return;

    const offending = findOffendingEdit(original, edits);
    const note = edits.length > 1 ? `edit #${offending}` : null;
    return { block: true, reason: blockReason(input.path, problem, note) };
  });

  pi.registerCommand("clojure-check", {
    description: "Check a Clojure/EDN file for balanced brackets (usage: /clojure-check <file>)",
    handler: async (args, ctx) => {
      const file = args.trim().replace(/^["']|["']$/g, "");
      if (!file) {
        ctx.ui.notify("Usage: /clojure-check <file>", "warning");
        return;
      }
      const path = isAbsolute(file) ? file : join(ctx.cwd, file);
      let content: string;
      try {
        content = (await readFile(path, "utf-8")).replace(/^\uFEFF/, "");
      } catch {
        ctx.ui.notify(`Cannot read ${path}`, "error");
        return;
      }
      const problem = checkBalance(content);
      if (problem) {
        ctx.ui.notify(`Unbalanced brackets in ${path}: ${problem.description}`, "error");
      } else {
        ctx.ui.notify(`Balanced: ${path}`, "info");
      }
    },
  });
}
