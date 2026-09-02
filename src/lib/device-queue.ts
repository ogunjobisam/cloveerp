/**
 * Store and forward for the device client.
 *
 * Specification v1.2 §14.5: "Store and forward with idempotency keys on every
 * queued action, so reconnection never duplicates." An action is given its key
 * the moment it is captured, before anything is sent, and keeps it through
 * every retry. The database's `erp.record_device_action()` answers a key it has
 * seen with the original row and `duplicate: true`, so a resend after a lost
 * response lands once.
 *
 * Pure functions over a plain array, so the queue can be tested without a
 * browser. The screen owns persistence and the network; this owns the rules.
 */

export type ScanCapture = {
  /** What the barcode said, or what was typed. */
  raw: string;
  /** The identifier the value was resolved to, when it was. */
  id: string | null;
  label: string | null;
  fields: Record<string, string>;
  keyed: boolean;
};

export type QueuedAction = {
  idempotency_key: string;
  device_code: string;
  task_code: string;
  /** The payload the handler register expects: key → value. */
  payload: Record<string, unknown>;
  /** What each scanned key was resolved from, for a resend that must resolve first. */
  captures: Record<string, ScanCapture>;
  input_method: "scanned" | "keyed";
  keyed_reason: string | null;
  captured_at: string;
  /** Local state: waiting to be sent, or acknowledged by the server. */
  state: "pending" | "sent";
  action_id: string | null;
  server_status: string | null;
  conflict_reason: string | null;
  attempts: number;
  last_error: string | null;
};

export type RecordResult = {
  action_id: string;
  status: string;
  duplicate: boolean;
  conflict_reason?: string | null;
};

export function newIdempotencyKey(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  // A fallback for very old WebViews; still unique enough for one device.
  return `k-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/** §14.2: keyboard entry is the exception path, and it always carries a reason. */
export function inputMethodOf(captures: Record<string, ScanCapture>): "scanned" | "keyed" {
  return Object.values(captures).some((c) => c.keyed) ? "keyed" : "scanned";
}

export function enqueue(
  queue: QueuedAction[],
  action: Omit<
    QueuedAction,
    "state" | "action_id" | "server_status" | "conflict_reason" | "attempts" | "last_error"
  >,
): QueuedAction[] {
  if (queue.some((q) => q.idempotency_key === action.idempotency_key)) return queue;
  return [
    ...queue,
    {
      ...action,
      state: "pending",
      action_id: null,
      server_status: null,
      conflict_reason: null,
      attempts: 0,
      last_error: null,
    },
  ];
}

/** Everything still to send, oldest first, because the queue is applied in capture order. */
export function pending(queue: QueuedAction[]): QueuedAction[] {
  return queue
    .filter((q) => q.state === "pending")
    .sort((a, b) => a.captured_at.localeCompare(b.captured_at));
}

/** The server acknowledged the key: sent, whether or not it was a duplicate. */
export function markSent(queue: QueuedAction[], key: string, result: RecordResult): QueuedAction[] {
  return queue.map((q) =>
    q.idempotency_key === key
      ? {
          ...q,
          state: "sent",
          action_id: result.action_id,
          server_status: result.status,
          conflict_reason: result.conflict_reason ?? null,
          last_error: null,
          attempts: q.attempts + 1,
        }
      : q,
  );
}

/** A failed send stays pending, with the reason kept for the operator to see. */
export function markFailed(queue: QueuedAction[], key: string, error: string): QueuedAction[] {
  return queue.map((q) =>
    q.idempotency_key === key ? { ...q, attempts: q.attempts + 1, last_error: error } : q,
  );
}

/** Once the server has applied an action it is the server's record, not the device's. */
export function forget(queue: QueuedAction[], keys: string[]): QueuedAction[] {
  const gone = new Set(keys);
  return queue.filter((q) => !gone.has(q.idempotency_key));
}

/** Keys of sent actions the server now reports applied or conflicted, so the local copy can go. */
export function settledKeys(
  queue: QueuedAction[],
  serverStatuses: Record<string, string>,
): string[] {
  return queue
    .filter((q) => q.state === "sent" && q.action_id !== null)
    .filter((q) => {
      const s = serverStatuses[q.action_id!];
      return s === "applied" || s === "conflicted";
    })
    .map((q) => q.idempotency_key);
}

export type QueueSummary = { pending: number; sent: number; failing: number };

export function summarise(queue: QueuedAction[]): QueueSummary {
  return {
    pending: queue.filter((q) => q.state === "pending").length,
    sent: queue.filter((q) => q.state === "sent").length,
    failing: queue.filter((q) => q.state === "pending" && q.last_error !== null).length,
  };
}

/** Which keys of an action were captured and never resolved to an identifier. */
export function unresolvedKeys(action: QueuedAction): string[] {
  return Object.entries(action.captures)
    .filter(([key, c]) => c.id === null && key.endsWith("_id"))
    .map(([key]) => key);
}

/** After a resolver filled a key, both the payload and the capture record it. */
export function resolveKey(
  action: QueuedAction,
  key: string,
  id: string,
  label: string | null,
): QueuedAction {
  const capture = action.captures[key];
  if (!capture) return action;
  return {
    ...action,
    payload: { ...action.payload, [key]: id },
    captures: { ...action.captures, [key]: { ...capture, id, label } },
  };
}
