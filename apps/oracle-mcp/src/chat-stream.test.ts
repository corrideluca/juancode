import { describe, expect, it } from "vitest";
import { ChatStreamReducer } from "./oracle.ts";

// The reducer is the fragile contract with claude's `--output-format stream-json`
// NDJSON. These tests pin the three shapes it must tolerate (token partials, whole
// assistant messages, the final result) and the de-dup between them.

/** Feed an array of events through a fresh reducer, collecting every emitted chunk. */
function run(events: Record<string, unknown>[]): {
  reducer: ChatStreamReducer;
  emitted: string[];
} {
  const reducer = new ChatStreamReducer();
  const emitted: string[] = [];
  for (const e of events) emitted.push(...reducer.push(e));
  const fallback = reducer.fallbackText();
  if (fallback) emitted.push(fallback);
  return { reducer, emitted };
}

const partial = (text: string) => ({
  type: "stream_event",
  event: { type: "content_block_delta", delta: { type: "text_delta", text } },
});

describe("ChatStreamReducer", () => {
  it("streams token-level partials and ignores the trailing whole message + result", () => {
    const { reducer, emitted } = run([
      { type: "system", subtype: "init", session_id: "s1" },
      partial("Hel"),
      partial("lo"),
      partial(" there"),
      { type: "assistant", message: { content: [{ type: "text", text: "Hello there" }] }, session_id: "s1" },
      { type: "result", subtype: "success", result: "Hello there", is_error: false, session_id: "s1" },
    ]);
    expect(emitted.join("")).toBe("Hello there");
    expect(emitted).toEqual(["Hel", "lo", " there"]); // not re-emitted by assistant/result
    expect(reducer.sessionId).toBe("s1");
    expect(reducer.isError).toBe(false);
    expect(reducer.done).toBe(true);
  });

  it("falls back to the whole assistant message when no partials arrive", () => {
    const { emitted } = run([
      { type: "system", subtype: "init", session_id: "s2" },
      { type: "assistant", message: { content: [{ type: "text", text: "Full reply." }] }, session_id: "s2" },
      { type: "result", subtype: "success", result: "Full reply.", is_error: false, session_id: "s2" },
    ]);
    expect(emitted).toEqual(["Full reply."]);
  });

  it("surfaces the final result text when nothing streamed (no partials, no assistant text)", () => {
    const { reducer, emitted } = run([
      { type: "system", subtype: "init", session_id: "s3" },
      { type: "result", subtype: "success", result: "Only the summary", is_error: false, session_id: "s3" },
    ]);
    expect(emitted).toEqual(["Only the summary"]);
    expect(reducer.fallbackText).toBeTypeOf("function");
  });

  it("ignores tool-use blocks but still streams later text", () => {
    const { emitted } = run([
      { type: "assistant", message: { content: [{ type: "tool_use", name: "bd", input: {} }] }, session_id: "s4" },
      { type: "assistant", message: { content: [{ type: "text", text: "Done." }] }, session_id: "s4" },
      { type: "result", subtype: "success", result: "Done.", is_error: false, session_id: "s4" },
    ]);
    expect(emitted).toEqual(["Done."]);
  });

  it("captures the session id and marks errors from the result event", () => {
    const { reducer } = run([
      partial("oops"),
      { type: "result", subtype: "error_max_turns", result: "", is_error: true, session_id: "s5" },
    ]);
    expect(reducer.sessionId).toBe("s5");
    expect(reducer.isError).toBe(true);
    expect(reducer.done).toBe(true);
  });

  it("does not emit fallback once any text streamed", () => {
    const { emitted } = run([
      partial("hi"),
      { type: "result", subtype: "success", result: "hi (full)", is_error: false, session_id: "s6" },
    ]);
    expect(emitted).toEqual(["hi"]); // result text not appended on top of streamed deltas
  });
});
