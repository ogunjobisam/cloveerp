import { describe, expect, test } from "bun:test";

import {
  enqueue,
  forget,
  inputMethodOf,
  markFailed,
  markSent,
  newIdempotencyKey,
  pending,
  resolveKey,
  settledKeys,
  summarise,
  unresolvedKeys,
  type QueuedAction,
} from "./device-queue";

function capture(key: string, at: string, keyed = false) {
  return {
    idempotency_key: key,
    device_code: "SCAN-01",
    task_code: "putaway",
    payload: { task_id: "t1", quantity: 5 },
    captures: {
      task_id: { raw: "t1", id: "t1", label: "Putaway 1", fields: {}, keyed },
    },
    input_method: keyed ? ("keyed" as const) : ("scanned" as const),
    keyed_reason: keyed ? "label torn" : null,
    captured_at: at,
  };
}

describe("§14.5 store and forward", () => {
  test("every queued action carries its idempotency key from capture", () => {
    const a = newIdempotencyKey();
    const b = newIdempotencyKey();
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThan(10);
  });

  test("the same key queued twice is one action", () => {
    let q: QueuedAction[] = [];
    q = enqueue(q, capture("k1", "2026-09-02T10:00:00Z"));
    q = enqueue(q, capture("k1", "2026-09-02T10:00:01Z"));
    expect(q).toHaveLength(1);
  });

  test("pending actions go in the order they were captured, not the order they were queued", () => {
    let q: QueuedAction[] = [];
    q = enqueue(q, capture("later", "2026-09-02T10:05:00Z"));
    q = enqueue(q, capture("earlier", "2026-09-02T10:01:00Z"));
    expect(pending(q).map((x) => x.idempotency_key)).toEqual(["earlier", "later"]);
  });

  test("a server acknowledgement marks the action sent, duplicate or not", () => {
    let q = enqueue([], capture("k1", "2026-09-02T10:00:00Z"));
    q = markSent(q, "k1", { action_id: "a1", status: "queued", duplicate: true });
    expect(q[0]!.state).toBe("sent");
    expect(q[0]!.action_id).toBe("a1");
    expect(pending(q)).toHaveLength(0);
  });

  test("a failed send stays pending with the reason shown", () => {
    let q = enqueue([], capture("k1", "2026-09-02T10:00:00Z"));
    q = markFailed(q, "k1", "Failed to fetch");
    expect(q[0]!.state).toBe("pending");
    expect(q[0]!.last_error).toBe("Failed to fetch");
    expect(summarise(q)).toEqual({ pending: 1, sent: 0, failing: 1 });
  });

  test("an action the server has applied or conflicted leaves the device", () => {
    let q = enqueue([], capture("k1", "2026-09-02T10:00:00Z"));
    q = enqueue(q, capture("k2", "2026-09-02T10:00:01Z"));
    q = markSent(q, "k1", { action_id: "a1", status: "queued", duplicate: false });
    q = markSent(q, "k2", { action_id: "a2", status: "queued", duplicate: false });
    const gone = settledKeys(q, { a1: "applied", a2: "queued" });
    expect(gone).toEqual(["k1"]);
    expect(forget(q, gone).map((x) => x.idempotency_key)).toEqual(["k2"]);
  });
});

describe("§14.2 scan first, type never", () => {
  test("one keyed capture makes the whole action a keyed one", () => {
    expect(inputMethodOf({ a: capture("k", "x").captures.task_id })).toBe("scanned");
    expect(inputMethodOf({ a: capture("k", "x", true).captures.task_id })).toBe("keyed");
  });
});

describe("offline capture resolves on reconnection", () => {
  test("an identifier captured offline is unresolved until the server names it", () => {
    const a: QueuedAction = {
      ...capture("k1", "2026-09-02T10:00:00Z"),
      payload: { item_id: null, quantity: 3 },
      captures: {
        item_id: {
          raw: "0105012345678900",
          id: null,
          label: null,
          fields: { gtin: "05012345678900" },
          keyed: false,
        },
      },
      state: "pending",
      action_id: null,
      server_status: null,
      conflict_reason: null,
      attempts: 0,
      last_error: null,
    };
    expect(unresolvedKeys(a)).toEqual(["item_id"]);
    const r = resolveKey(a, "item_id", "item-uuid", "WIDGET Widget");
    expect(r.payload["item_id"]).toBe("item-uuid");
    expect(unresolvedKeys(r)).toEqual([]);
  });
});
