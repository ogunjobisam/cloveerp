import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { friendlyError } from "@/lib/errors";

import { Gate } from "../components/erp/gate";
import { useErpSession } from "../components/erp/session-context";
import {
  enqueue,
  forget,
  inputMethodOf,
  markFailed,
  markSent,
  newIdempotencyKey,
  pending,
  resolveKey,
  summarise,
  unresolvedKeys,
  type QueuedAction,
  type RecordResult,
  type ScanCapture,
} from "../lib/device-queue";
import { callErp, hasPermission } from "../lib/erp";
import {
  evaluateScan,
  type ApplicationIdentifier,
  type ScanRule,
  type ScanVerdict,
  type Symbology,
} from "../lib/gs1";
import { useT } from "../lib/i18n";

/**
 * The warehouse application. Specification v1.2 Part 14.
 *
 * "The warehouse does not use the application described in Part 7. It uses a
 * different application against the same functions: one task at a time,
 * driven by scanning, operated with gloves on, in poor light, sometimes
 * without a network."
 *
 * Everything on this screen is one of §14.2's constraints made concrete:
 *
 *   One decision per screen. Each stage below asks one thing.
 *   Scan first, type never. An identifier is scanned; typing it is an
 *     exception path that always asks for a reason, and the action is recorded
 *     as keyed so the supplier's data quality can be measured against it.
 *   48 pixel targets, 64 preferred. TARGET is 64; nothing tappable is smaller
 *     than 48.
 *   No colour-only meaning. Every verdict is a word and a shape as well as a
 *     colour; the state chip says "Offline, 3 queued" rather than turning red.
 *   Portrait, thumb-reachable. Primary actions sit at the bottom; the one
 *     destructive act, abandoning a task, sits at the top where a thumb does
 *     not rest.
 *   No modals, no nested navigation. Back is always one step and always the
 *     same button.
 *   Audible and haptic feedback on every scan, distinct for accepted, rejected
 *     and complete.
 *   The session survives sleep and signal loss: the device, the task in hand
 *     and the queue are kept in the browser and picked up on resume.
 *
 * Nothing here decides anything about stock. The task register says what each
 * step's payload must carry; the scan rules say what a barcode must contain;
 * the module function named by the handler register applies the action and,
 * where it refuses, its refusal is the conflict the operator reads. The client
 * captures, validates against cached rules, queues, and shows its own state
 * plainly (§14.5).
 */

export const Route = createFileRoute("/device")({
  head: () => ({
    meta: [
      { title: "Scanner — Clove ERP" },
      { name: "viewport", content: "width=device-width, initial-scale=1, maximum-scale=1" },
    ],
  }),
  component: () => (
    <Gate bare>
      <DeviceClient />
    </Gate>
  ),
});

// ── Shapes read from the doors ───────────────────────────────────────────────

type Device = {
  code: string;
  name: string;
  device_class: string;
  site: string;
  status: string;
  open_session: boolean;
};

type PayloadKey = { key: string; type: string; required: boolean };

type TaskHandler = {
  code: string;
  name: string;
  task_group: string;
  seq: number;
  module_code: string | null;
  sql_function: string | null;
  payload_keys: PayloadKey[];
  writes_nothing: boolean;
  not_handled_reason: string | null;
  note: string;
};

type DeviceTask = {
  code: string;
  works_offline: boolean;
  starts_when: string;
  completes_when: string;
  abandons_when: string;
  scan_rules: ScanRule[];
};

type Resolution = {
  resolved: boolean;
  id: string | null;
  kind: string | null;
  label: string | null;
  reason: string | null;
};

type QueueRow = {
  action_id: string;
  task_code: string;
  status: string;
  captured_at: string;
  conflict_reason: string | null;
};

type Position = {
  item: string;
  item_name: string;
  location: string;
  container: string | null;
  batch: string | null;
  expires_on: string | null;
  stock_status: string;
  quantity: number;
};

type Principal = { id: string; display_name: string; kind: string };

// ── Persistence: the browser is the device's memory ─────────────────────────

const KEY_DEVICE = "clove-erp.device.code";
const KEY_QUEUE = "clove-erp.device.queue";
const KEY_PROGRESS = "clove-erp.device.progress";
const KEY_CACHE = "clove-erp.device.cache";

function readJson<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function writeJson(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* storage unavailable; the session still works for this page */
  }
}

/** Reference data the client needs before it can validate a scan offline. */
type Cache = {
  handlers: TaskHandler[];
  tasks: DeviceTask[];
  symbologies: (Symbology & { name: string })[];
  register: ApplicationIdentifier[];
};

// ── Feedback: §14.2 "in noise, haptics carry" ───────────────────────────────

type Signal = "accepted" | "rejected" | "complete";

let audio: AudioContext | null = null;

function beep(frequency: number, ms: number, at = 0) {
  try {
    const Ctx =
      window.AudioContext ??
      (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    audio ??= new Ctx();
    const osc = audio.createOscillator();
    const gain = audio.createGain();
    osc.frequency.value = frequency;
    osc.connect(gain);
    gain.connect(audio.destination);
    gain.gain.value = 0.2;
    osc.start(audio.currentTime + at / 1000);
    osc.stop(audio.currentTime + (at + ms) / 1000);
  } catch {
    /* no audio on this device; the haptic and the words still carry */
  }
}

function signal(kind: Signal) {
  try {
    if (kind === "accepted") {
      navigator.vibrate?.(60);
      beep(1200, 80);
    } else if (kind === "rejected") {
      navigator.vibrate?.([200, 80, 200]);
      beep(300, 220);
      beep(300, 220, 300);
    } else {
      navigator.vibrate?.([60, 60, 60, 60, 60]);
      beep(900, 80);
      beep(1200, 80, 120);
      beep(1500, 120, 240);
    }
  } catch {
    /* a browser that refuses vibration is still a browser that shows the words */
  }
}

// ── Sizes: §14.2 "gloves are assumed, not accommodated" ─────────────────────

/** Preferred target, 64 pixels. */
const TARGET = "min-h-16";
/** The floor, 48 pixels, for secondary controls. */
const TARGET_MIN = "min-h-12";

const PRIMARY = `${TARGET} w-full rounded-xl bg-primary px-5 text-xl font-semibold text-primary-foreground active:scale-[0.98] disabled:opacity-40`;
const SECONDARY = `${TARGET} w-full rounded-xl border-2 border-input bg-card px-5 text-lg font-medium active:scale-[0.98] disabled:opacity-40`;
const SMALL = `${TARGET_MIN} rounded-lg px-4 text-base font-medium underline underline-offset-4`;
const FIELD = `${TARGET} w-full rounded-xl border-2 border-input bg-background px-4 text-2xl`;

function isNetworkError(e: unknown): boolean {
  return e instanceof TypeError || /fetch|network/i.test(e instanceof Error ? e.message : "");
}

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
}

// ── The client ───────────────────────────────────────────────────────────────

type Stage =
  | { kind: "device" }
  | { kind: "session" }
  | { kind: "tasks" }
  | {
      kind: "capture";
      task: string;
      step: number;
      captures: Record<string, ScanCapture>;
      payload: Record<string, unknown>;
      reasons: string[];
    }
  | { kind: "done"; task: string }
  | { kind: "enquiry"; task: string }
  | { kind: "queue" };

type Progress = { stage: Stage; sessionOpen: boolean };

function DeviceClient() {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();

  const [deviceCode, setDeviceCode] = useState<string | null>(() =>
    readJson<string | null>(KEY_DEVICE, null),
  );
  const [progress, setProgress] = useState<Progress>(() =>
    readJson<Progress>(KEY_PROGRESS, { stage: { kind: "device" }, sessionOpen: false }),
  );
  const [queue, setQueue] = useState<QueuedAction[]>(() => readJson<QueuedAction[]>(KEY_QUEUE, []));
  const [online, setOnline] = useState<boolean>(() =>
    typeof navigator === "undefined" ? true : navigator.onLine,
  );
  const [syncing, setSyncing] = useState(false);
  const [lastSync, setLastSync] = useState<string | null>(null);
  const [conflicts, setConflicts] = useState<QueueRow[]>([]);

  useEffect(() => writeJson(KEY_DEVICE, deviceCode), [deviceCode]);
  useEffect(() => writeJson(KEY_PROGRESS, progress), [progress]);
  useEffect(() => writeJson(KEY_QUEUE, queue), [queue]);

  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    return () => {
      window.removeEventListener("online", up);
      window.removeEventListener("offline", down);
    };
  }, []);

  const stage = progress.stage;
  const setStage = (s: Stage) => setProgress((p) => ({ ...p, stage: s }));

  // Reference data, cached so a device that starts in a cold store still has
  // its rules. The server copy wins whenever it can be read.
  const cached = useMemo(() => readJson<Cache | null>(KEY_CACHE, null), []);
  const refQuery = useQuery({
    queryKey: ["device-reference"],
    queryFn: async (): Promise<Cache> => {
      const [handlers, tasks, symbologies, register] = await Promise.all([
        callErp<TaskHandler[]>("erp_device_task_handlers"),
        callErp<DeviceTask[]>("erp_device_tasks"),
        callErp<(Symbology & { name: string })[]>("erp_symbologies"),
        callErp<ApplicationIdentifier[]>("erp_gs1_application_identifiers"),
      ]);
      const c = { handlers, tasks, symbologies, register };
      writeJson(KEY_CACHE, c);
      return c;
    },
    staleTime: 5 * 60_000,
    retry: false,
  });
  const ref = refQuery.data ?? cached;

  const devices = useQuery({
    queryKey: ["erp_devices", {}],
    queryFn: () => callErp<Device[]>("erp_devices"),
    retry: false,
  });

  const device = deviceCode ? (devices.data?.find((d) => d.code === deviceCode) ?? null) : null;

  // ── Store and forward ─────────────────────────────────────────────────────

  const flushing = useRef(false);
  const flush = useCallback(async () => {
    if (!deviceCode || flushing.current || !online) return;
    flushing.current = true;
    setSyncing(true);
    let current = queue;
    let sentAny = false;
    try {
      for (const action of pending(current)) {
        let a = action;
        // An identifier captured offline is resolved now, against master data.
        for (const key of unresolvedKeys(a)) {
          const cap = a.captures[key]!;
          try {
            const r = await callErp<Resolution>("erp_resolve_scan", {
              p_key: key,
              p_barcode: cap.raw,
              p_fields: cap.fields,
              p_device_code: deviceCode,
            });
            if (r.resolved && r.id) a = resolveKey(a, key, r.id, r.label);
          } catch (e) {
            if (isNetworkError(e)) throw e;
            // Not resolvable: recorded anyway, so the drain conflicts with the
            // module's reason rather than the action vanishing on the device.
          }
        }
        try {
          const result = await callErp<RecordResult>("erp_record_device_action", {
            p_device_code: a.device_code,
            p_task_code: a.task_code,
            p_idempotency_key: a.idempotency_key,
            p_payload: a.payload,
            p_input_method: a.input_method,
            p_keyed_reason: a.keyed_reason,
            p_captured_at: a.captured_at,
          });
          current = markSent(
            current.map((q) => (q.idempotency_key === a.idempotency_key ? a : q)),
            a.idempotency_key,
            result,
          );
          sentAny = true;
        } catch (e) {
          if (isNetworkError(e)) throw e;
          current = markFailed(current, a.idempotency_key, friendlyError(e).title);
        }
        setQueue(current);
      }

      const sent = current.filter((q) => q.state === "sent");
      if (sentAny || sent.length > 0) {
        try {
          await callErp("erp_drain_device_actions", { p_device_code: deviceCode, p_limit: 100 });
        } catch (e) {
          if (isNetworkError(e)) throw e;
          // The drain refusing is a queue-level condition the queue screen shows.
        }
        const rows = await callErp<QueueRow[]>("erp_device_queue", { p_device_code: deviceCode });
        setConflicts(rows.filter((r) => r.status === "conflicted"));
        const stillQueued = new Set(
          rows.filter((r) => r.status === "queued").map((r) => r.action_id),
        );
        // Applied or conflicted: the server's record now, not the device's.
        const settled = sent
          .filter((q) => q.action_id && !stillQueued.has(q.action_id))
          .map((q) => q.idempotency_key);
        current = forget(current, settled);
        setQueue(current);
      }
      setLastSync(new Date().toISOString());
      setOnline(true);
      void queryClient.invalidateQueries({ queryKey: ["erp_device_actions"] });
    } catch (e) {
      if (isNetworkError(e)) setOnline(false);
    } finally {
      flushing.current = false;
      setSyncing(false);
    }
  }, [deviceCode, online, queue, queryClient]);

  // Flush when the queue changes, when the network returns, and on a timer
  // while anything is waiting, so the operator never has to ask.
  useEffect(() => {
    if (!online || !deviceCode) return;
    if (pending(queue).length > 0 || queue.some((q) => q.state === "sent")) void flush();
    const t = setInterval(() => void flush(), 15_000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [online, deviceCode, queue.length]);

  const summary = summarise(queue);

  // ── Session ───────────────────────────────────────────────────────────────

  async function openSession(supervisor: { id: string; reason: string } | null) {
    if (!deviceCode) return;
    await callErp("erp_open_device_session", {
      p_device_code: deviceCode,
      p_supervisor_user_id: supervisor?.id ?? null,
      p_supervisor_reason: supervisor?.reason ?? null,
    });
    setProgress({ stage: { kind: "tasks" }, sessionOpen: true });
    void queryClient.invalidateQueries({ queryKey: ["erp_devices"] });
  }

  async function signOut() {
    try {
      await callErp("erp_close_device_session", { p_end_reason: "signed out" });
    } catch {
      /* offline: the next operator's session supersedes this one on the server */
    }
    setProgress({ stage: { kind: "device" }, sessionOpen: false });
    setDeviceCode(null);
    void queryClient.invalidateQueries({ queryKey: ["erp_devices"] });
  }

  // ── Capture ───────────────────────────────────────────────────────────────

  function startTask(code: string) {
    const handler = ref?.handlers.find((h) => h.code === code);
    if (!handler) return;
    if (handler.writes_nothing) {
      setStage({ kind: "enquiry", task: code });
      return;
    }
    setStage({ kind: "capture", task: code, step: 0, captures: {}, payload: {}, reasons: [] });
  }

  function queueAction(s: Extract<Stage, { kind: "capture" }>) {
    if (!deviceCode) return;
    const next = enqueue(queue, {
      idempotency_key: newIdempotencyKey(),
      device_code: deviceCode,
      task_code: s.task,
      payload: s.payload,
      captures: s.captures,
      input_method: inputMethodOf(s.captures),
      keyed_reason: s.reasons.length > 0 ? s.reasons.join("; ") : null,
      captured_at: new Date().toISOString(),
    });
    setQueue(next);
    signal("complete");
    setStage({ kind: "done", task: s.task });
  }

  function advance(
    s: Extract<Stage, { kind: "capture" }>,
    key: string,
    value: unknown,
    capture: ScanCapture | null,
    reason: string | null,
  ) {
    const handler = ref?.handlers.find((h) => h.code === s.task);
    if (!handler) return;
    const nextStage: Extract<Stage, { kind: "capture" }> = {
      ...s,
      step: s.step + 1,
      payload: { ...s.payload, [key]: value },
      captures: capture ? { ...s.captures, [key]: capture } : s.captures,
      reasons: reason ? [...s.reasons, reason] : s.reasons,
    };
    if (nextStage.step >= handler.payload_keys.length) {
      queueAction(nextStage);
    } else {
      setStage(nextStage);
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  const handlers = ref?.handlers ?? [];
  const operator = session.principal?.given_name ?? session.principal?.display_name ?? "";

  return (
    <div className="mx-auto flex min-h-screen w-full max-w-md flex-col bg-background text-foreground">
      <a
        href="#device-main"
        className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded-md focus:bg-card focus:px-3 focus:py-2"
      >
        {ui("Skip to the task")}
      </a>

      <header className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <div className="truncate text-base font-semibold">{device?.name ?? ui("Scanner")}</div>
          <div className="truncate text-sm text-muted-foreground">
            {device ? `${device.code} · ${device.site}` : ui("No device chosen")}
            {operator ? ` · ${operator}` : ""}
          </div>
        </div>
        <StateChip online={online} syncing={syncing} queued={summary.pending + summary.sent} />
      </header>

      {!online && !ref ? (
        <p role="status" className="border-b border-border bg-muted px-4 py-3 text-base">
          {ui("Offline with no cached rules. Connect once so the scanner can learn its steps.")}
        </p>
      ) : null}

      <main id="device-main" className="flex flex-1 flex-col px-4 py-4">
        {stage.kind === "device" ? (
          <DevicePick
            devices={(devices.data ?? []).filter((d) => d.status === "active")}
            loading={devices.isPending}
            error={devices.error}
            onPick={(code) => {
              setDeviceCode(code);
              setStage({ kind: "session" });
            }}
          />
        ) : null}

        {stage.kind === "session" && device ? (
          <SessionStart
            device={device}
            canSupervise={hasPermission(session, "administration.read")}
            online={online}
            onBack={() => setStage({ kind: "device" })}
            onOpen={openSession}
          />
        ) : null}

        {stage.kind === "tasks" ? (
          <TaskPick
            handlers={handlers}
            tasks={ref?.tasks ?? []}
            online={online}
            onPick={startTask}
            conflicts={conflicts.length}
            onQueue={() => setStage({ kind: "queue" })}
          />
        ) : null}

        {stage.kind === "capture" && ref && deviceCode ? (
          <CaptureStep
            key={`${stage.task}-${stage.step}`}
            stage={stage}
            handler={handlers.find((h) => h.code === stage.task)!}
            task={ref.tasks.find((t) => t.code === stage.task)!}
            reference={ref}
            deviceCode={deviceCode}
            online={online}
            onAbandon={() => setStage({ kind: "tasks" })}
            onBack={() =>
              stage.step === 0
                ? setStage({ kind: "tasks" })
                : setStage({ ...stage, step: stage.step - 1 })
            }
            onAdvance={(key, value, capture, reason) => advance(stage, key, value, capture, reason)}
          />
        ) : null}

        {stage.kind === "enquiry" && ref && deviceCode ? (
          <Enquiry
            reference={ref}
            task={ref.tasks.find((t) => t.code === stage.task)!}
            deviceCode={deviceCode}
            online={online}
            onBack={() => setStage({ kind: "tasks" })}
          />
        ) : null}

        {stage.kind === "done" ? (
          <Done
            taskName={handlers.find((h) => h.code === stage.task)?.name ?? stage.task}
            queued={summary.pending}
            online={online}
            onAgain={() => startTask(stage.task)}
            onTasks={() => setStage({ kind: "tasks" })}
          />
        ) : null}

        {stage.kind === "queue" ? (
          <QueueScreen
            queue={queue}
            conflicts={conflicts}
            online={online}
            syncing={syncing}
            lastSync={lastSync}
            onSync={() => void flush()}
            onBack={() => setStage({ kind: "tasks" })}
          />
        ) : null}
      </main>

      <footer className="flex items-center justify-between gap-2 border-t border-border px-4 py-2 text-sm">
        {progress.sessionOpen ? (
          <button type="button" className={SMALL} onClick={() => void signOut()}>
            {ui("Sign out of this device")}
          </button>
        ) : (
          <Link to="/" className={`${SMALL} inline-flex items-center`}>
            {ui("Back to the desk")}
          </Link>
        )}
        {progress.sessionOpen ? (
          <button type="button" className={SMALL} onClick={() => setStage({ kind: "queue" })}>
            {ui("Queue")} ({summary.pending + summary.sent + conflicts.length})
          </button>
        ) : null}
      </footer>
    </div>
  );
}

// ── The chip: §14.5 "the device shows its own state plainly" ────────────────

function StateChip({
  online,
  syncing,
  queued,
}: {
  online: boolean;
  syncing: boolean;
  queued: number;
}) {
  const { ui } = useT();
  const text = syncing
    ? ui("Syncing…")
    : online
      ? queued > 0
        ? `${ui("Connected")} · ${queued}`
        : ui("Connected")
      : `${ui("Offline")} · ${queued}`;
  const shape = syncing ? "◐" : online ? "●" : "○";
  return (
    <span
      role="status"
      className={`${TARGET_MIN} inline-flex shrink-0 items-center gap-2 rounded-full border-2 px-3 text-sm font-semibold ${
        online ? "border-input" : "border-foreground bg-muted"
      }`}
    >
      <span aria-hidden="true">{shape}</span>
      {text}
    </span>
  );
}

// ── Stage: choose the device ─────────────────────────────────────────────────

function DevicePick({
  devices,
  loading,
  error,
  onPick,
}: {
  devices: Device[];
  loading: boolean;
  error: unknown;
  onPick: (code: string) => void;
}) {
  const { ui } = useT();
  return (
    <div className="flex flex-1 flex-col gap-3">
      <h1 className="text-2xl font-semibold">{ui("Which device is this?")}</h1>
      <p className="text-base text-muted-foreground">
        {ui("A device is registered at a site; an unregistered one cannot transact.")}
      </p>
      {loading ? <p role="status">{ui("Loading…")}</p> : null}
      {error ? <p role="alert">{friendlyError(error).title}</p> : null}
      {!loading && devices.length === 0 ? (
        <p className="text-base">
          {ui("No active device is registered. Ask an administrator to register one.")}
        </p>
      ) : null}
      <div className="mt-2 flex flex-col gap-3">
        {devices.map((d) => (
          <button
            key={d.code}
            type="button"
            className={`${SECONDARY} text-left`}
            onClick={() => onPick(d.code)}
          >
            <span className="block text-lg font-semibold">{d.name}</span>
            <span className="block text-sm text-muted-foreground">
              {d.code} · {d.site} · {d.device_class}
              {d.open_session ? ` · ${ui("in use")}` : ""}
            </span>
          </button>
        ))}
      </div>
    </div>
  );
}

// ── Stage: open a session ────────────────────────────────────────────────────

function SessionStart({
  device,
  canSupervise,
  online,
  onBack,
  onOpen,
}: {
  device: Device;
  canSupervise: boolean;
  online: boolean;
  onBack: () => void;
  onOpen: (supervisor: { id: string; reason: string } | null) => Promise<void>;
}) {
  const { ui } = useT();
  const [supervised, setSupervised] = useState(false);
  const [supervisor, setSupervisor] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);

  const principals = useQuery({
    queryKey: ["erp_principals", {}],
    queryFn: () => callErp<Principal[]>("erp_principals"),
    enabled: canSupervise && supervised,
    retry: false,
  });

  async function start() {
    setBusy(true);
    setError(null);
    try {
      await onOpen(supervised && supervisor ? { id: supervisor, reason } : null);
    } catch (e) {
      setError(e);
      signal("rejected");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <button type="button" className={`${SMALL} self-start`} onClick={onBack}>
        {ui("Back")}
      </button>
      <h1 className="text-2xl font-semibold">
        {ui("Start work on")} {device.name}
      </h1>
      <p className="text-base text-muted-foreground">
        {ui(
          "Every action you capture is recorded against you, never against the device. Whoever held it last is signed out.",
        )}
      </p>
      {!online ? (
        <p role="status" className="text-base">
          {ui("A session needs the network to open. Connect, then start.")}
        </p>
      ) : null}
      {canSupervise ? (
        <label className={`${TARGET_MIN} flex items-center gap-3 text-base`}>
          <input
            type="checkbox"
            className="h-6 w-6"
            checked={supervised}
            onChange={(e) => setSupervised(e.target.checked)}
          />
          {ui("A supervisor is authorising this session")}
        </label>
      ) : null}
      {supervised ? (
        <div className="flex flex-col gap-3">
          <label className="block text-base font-medium">
            {ui("Supervisor")}
            <select
              className={FIELD}
              value={supervisor}
              onChange={(e) => setSupervisor(e.target.value)}
            >
              <option value="">{ui("Choose a person")}</option>
              {(principals.data ?? [])
                .filter((p) => p.kind === "person")
                .map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.display_name}
                  </option>
                ))}
            </select>
          </label>
          <label className="block text-base font-medium">
            {ui("Why")}
            <input className={FIELD} value={reason} onChange={(e) => setReason(e.target.value)} />
          </label>
        </div>
      ) : null}
      {error ? (
        <p role="alert" className="text-base">
          {friendlyError(error).title}
        </p>
      ) : null}
      <div className="mt-auto">
        <button
          type="button"
          className={PRIMARY}
          disabled={busy || !online || (supervised && (!supervisor || !reason.trim()))}
          onClick={() => void start()}
        >
          {busy ? ui("Starting…") : ui("Start")}
        </button>
      </div>
    </div>
  );
}

// ── Stage: choose the task ───────────────────────────────────────────────────

const GROUP_NAMES: Record<string, string> = {
  inbound: "Inbound",
  stock: "Stock",
  outbound: "Outbound",
  production: "Production",
  quality: "Quality",
};

function TaskPick({
  handlers,
  tasks,
  online,
  conflicts,
  onPick,
  onQueue,
}: {
  handlers: TaskHandler[];
  tasks: DeviceTask[];
  online: boolean;
  conflicts: number;
  onPick: (code: string) => void;
  onQueue: () => void;
}) {
  const { ui } = useT();
  const [explain, setExplain] = useState<string | null>(null);
  const groups = [...new Set(handlers.map((h) => h.task_group))];

  return (
    <div className="flex flex-1 flex-col gap-4">
      <h1 className="text-2xl font-semibold">{ui("What are you doing?")}</h1>
      {conflicts > 0 ? (
        <button type="button" className={`${SECONDARY} text-left`} onClick={onQueue}>
          <span className="block text-lg font-semibold">
            {ui("Needs your attention")}: {conflicts}
          </span>
          <span className="block text-sm text-muted-foreground">
            {ui("An action could not be applied. The reason is in the queue.")}
          </span>
        </button>
      ) : null}
      {explain ? (
        <p role="status" className="rounded-xl bg-muted px-4 py-3 text-base">
          {explain}
        </p>
      ) : null}
      {groups.map((g) => (
        <section key={g} className="flex flex-col gap-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
            {ui(GROUP_NAMES[g] ?? g)}
          </h2>
          {handlers
            .filter((h) => h.task_group === g)
            .map((h) => {
              const task = tasks.find((t) => t.code === h.code);
              const usable = Boolean(h.sql_function) || h.writes_nothing;
              const offlineOk = task?.works_offline ?? false;
              const blocked = !usable || (!online && !offlineOk);
              return (
                <button
                  key={h.code}
                  type="button"
                  className={`${SECONDARY} text-left ${blocked ? "opacity-60" : ""}`}
                  aria-disabled={blocked}
                  onClick={() => {
                    if (!usable) {
                      setExplain(h.not_handled_reason ?? h.note);
                      signal("rejected");
                    } else if (!online && !offlineOk) {
                      setExplain(
                        ui(
                          "This step needs a decision only the server can make. Reconnect to do it.",
                        ),
                      );
                      signal("rejected");
                    } else {
                      setExplain(null);
                      onPick(h.code);
                    }
                  }}
                >
                  <span className="block text-lg font-semibold">{h.name}</span>
                  <span className="block text-sm text-muted-foreground">
                    {!usable
                      ? ui("Not yet — tap to see why")
                      : offlineOk
                        ? ui("Works offline")
                        : ui("Needs the network")}
                  </span>
                </button>
              );
            })}
        </section>
      ))}
    </div>
  );
}

// ── Stage: capture one value ─────────────────────────────────────────────────

/** Which keys are scanned, and what a scan of each should be resolved as. */
function isScanKey(k: PayloadKey): boolean {
  return k.type === "uuid";
}

const KEY_WORDS: Record<string, string> = {
  item_id: "Scan the product",
  component_item_id: "Scan the component",
  location_id: "Scan the location",
  to_location_id: "Scan the destination location",
  from_location_id: "Scan the source location",
  container_id: "Scan the handling unit",
  batch_id: "Scan the batch",
  works_order_id: "Scan the works order",
  task_id: "Scan the task",
  allocation_id: "Scan the pick",
  receipt_id: "Scan the receipt",
  order_line_id: "Scan the order line",
  original_document_id: "Scan the original document",
  shipment_id: "Scan the shipment",
  inspection_id: "Scan the inspection",
  quantity: "How many?",
  minutes: "How many minutes?",
  reason: "Why?",
  note: "Note",
  status: "New status",
  carrier_code: "Carrier",
  service_code: "Service",
  reason_code: "Reason code",
  severity: "Severity",
  batch_number: "Batch number",
  characteristic: "Characteristic",
  numeric_value: "Measured value",
  operation_seq: "Operation number",
  quantity_scrapped: "How many scrapped?",
  scrap_reason: "Why scrapped?",
  disposition: "Disposition",
};

function CaptureStep({
  stage,
  handler,
  task,
  reference,
  deviceCode,
  online,
  onAbandon,
  onBack,
  onAdvance,
}: {
  stage: Extract<Stage, { kind: "capture" }>;
  handler: TaskHandler;
  task: DeviceTask;
  reference: Cache;
  deviceCode: string;
  online: boolean;
  onAbandon: () => void;
  onBack: () => void;
  onAdvance: (
    key: string,
    value: unknown,
    capture: ScanCapture | null,
    reason: string | null,
  ) => void;
}) {
  const { ui } = useT();
  const key = handler.payload_keys[stage.step]!;
  const total = handler.payload_keys.length;
  const prompt = ui(KEY_WORDS[key.key] ?? key.key);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center justify-between">
        <button type="button" className={SMALL} onClick={onBack}>
          {ui("Back")}
        </button>
        <button type="button" className={SMALL} onClick={onAbandon}>
          {ui("Abandon this task")}
        </button>
      </div>
      <p className="text-sm text-muted-foreground">
        {handler.name} · {stage.step + 1}/{total}
      </p>
      <h1 className="text-2xl font-semibold">{prompt}</h1>
      {stage.step === 0 ? (
        <p className="text-base text-muted-foreground">{task.starts_when}</p>
      ) : null}
      {isScanKey(key) ? (
        <ScanInput
          key={key.key}
          payloadKey={key.key}
          taskCode={handler.code}
          rules={task.scan_rules}
          reference={reference}
          deviceCode={deviceCode}
          online={online}
          onCaptured={(value, capture, reason) => onAdvance(key.key, value, capture, reason)}
        />
      ) : (
        <TypedInput
          key={key.key}
          payloadKey={key}
          required={key.required}
          onCaptured={(value) => onAdvance(key.key, value, null, null)}
        />
      )}
    </div>
  );
}

function ScanInput({
  payloadKey,
  taskCode,
  rules,
  reference,
  deviceCode,
  online,
  onCaptured,
}: {
  payloadKey: string;
  taskCode: string;
  rules: ScanRule[];
  reference: Cache;
  deviceCode: string;
  online: boolean;
  onCaptured: (value: string | null, capture: ScanCapture, reason: string | null) => void;
}) {
  const { ui } = useT();
  const [value, setValue] = useState("");
  const [symbology, setSymbology] = useState(() => reference.symbologies[0]?.code ?? "gs1_128");
  const [verdict, setVerdict] = useState<ScanVerdict | null>(null);
  const [keyed, setKeyed] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => input.current?.focus(), []);

  async function submit() {
    const raw = value.trim();
    if (raw === "") return;
    if (keyed && reason.trim() === "") {
      setNote(ui("Typing an identifier needs a reason."));
      signal("rejected");
      return;
    }

    // §14.7: validated against cached rules first, within the budget, and the
    // same evaluation the server would make.
    let v: ScanVerdict;
    try {
      v = evaluateScan({
        barcode: raw,
        symbology,
        symbologies: reference.symbologies,
        rules,
        register: reference.register,
      });
    } catch (e) {
      setNote(friendlyError(e).title);
      signal("rejected");
      return;
    }
    setVerdict(v);
    if (v.outcome === "rejected" || v.outcome === "refused") {
      signal("rejected");
      setValue("");
      input.current?.focus();
      return;
    }
    if (v.outcome === "exception" && reason.trim() === "") {
      // §14.4: capture it with a reason, or abandon. The reason field opens
      // and the same scan is confirmed once it is filled.
      signal("rejected");
      setKeyed(true);
      setNote(v.reason);
      return;
    }

    // Resolve the scan to the identifier the module function wants. Offline,
    // the raw value and its fields are kept and resolved on reconnection.
    setBusy(true);
    let resolution: Resolution | null = null;
    if (online) {
      try {
        resolution = await callErp<Resolution>("erp_resolve_scan", {
          p_key: payloadKey,
          p_barcode: raw,
          p_fields: v.fields,
          p_device_code: deviceCode,
        });
      } catch (e) {
        if (!isNetworkError(e)) {
          setBusy(false);
          setNote(friendlyError(e).title);
          signal("rejected");
          return;
        }
      }
    }
    setBusy(false);
    if (resolution && !resolution.resolved) {
      setNote(resolution.reason ?? ui("Nothing matches that scan."));
      signal("rejected");
      setValue("");
      input.current?.focus();
      return;
    }
    signal("accepted");
    onCaptured(
      resolution?.id ?? (isUuid(raw) ? raw : null),
      {
        raw,
        id: resolution?.id ?? (isUuid(raw) ? raw : null),
        label: resolution?.label ?? null,
        fields: v.fields,
        keyed,
      },
      keyed ? reason.trim() : null,
    );
  }

  return (
    <form
      className="flex flex-1 flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault();
        void submit();
      }}
    >
      <label className="block text-base font-medium">
        {keyed ? ui("Type the identifier") : ui("Scan now, or tap here to see the last scan")}
        <input
          ref={input}
          className={FIELD}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          autoComplete="off"
          autoCapitalize="off"
          spellCheck={false}
          inputMode={keyed ? "text" : "none"}
          enterKeyHint="done"
        />
      </label>
      <label className="block text-base font-medium">
        {ui("Barcode type")}
        <select
          className={`${TARGET_MIN} w-full rounded-xl border-2 border-input bg-background px-4 text-base`}
          value={symbology}
          onChange={(e) => setSymbology(e.target.value)}
        >
          {reference.symbologies.map((s) => (
            <option key={s.code} value={s.code}>
              {s.name}
            </option>
          ))}
        </select>
      </label>
      {keyed ? (
        <label className="block text-base font-medium">
          {ui("Why is this typed rather than scanned?")}
          <input className={FIELD} value={reason} onChange={(e) => setReason(e.target.value)} />
        </label>
      ) : null}
      {verdict && verdict.outcome !== "accepted" ? (
        <p
          role="alert"
          className="rounded-xl border-2 border-foreground px-4 py-3 text-lg font-semibold"
        >
          {verdict.outcome === "rejected"
            ? `✕ ${ui("Not read")}: ${verdict.scanned_value ?? ""}`
            : verdict.outcome === "refused"
              ? `✕ ${ui("Refused")}`
              : `! ${ui("Missing")}`}
          <span className="mt-1 block text-base font-normal">{verdict.reason}</span>
        </p>
      ) : null}
      {note && !(verdict && verdict.outcome !== "accepted" && verdict.reason === note) ? (
        <p role="status" className="rounded-xl bg-muted px-4 py-3 text-base">
          {note}
        </p>
      ) : null}
      <div className="mt-auto flex flex-col gap-3">
        <button type="submit" className={PRIMARY} disabled={busy}>
          {busy ? ui("Checking…") : keyed ? ui("Use what I typed") : ui("Confirm scan")}
        </button>
        {!keyed ? (
          <button
            type="button"
            className={SECONDARY}
            onClick={() => {
              setKeyed(true);
              input.current?.focus();
            }}
          >
            {ui("Cannot scan it — type it with a reason")}
          </button>
        ) : (
          <button
            type="button"
            className={SECONDARY}
            onClick={() => {
              setKeyed(false);
              setReason("");
              setNote(null);
              input.current?.focus();
            }}
          >
            {ui("Scan instead")}
          </button>
        )}
      </div>
    </form>
  );
}

function TypedInput({
  payloadKey,
  required,
  onCaptured,
}: {
  payloadKey: PayloadKey;
  required: boolean;
  onCaptured: (value: unknown) => void;
}) {
  const { ui } = useT();
  const [value, setValue] = useState("");
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => input.current?.focus(), []);
  const numeric = payloadKey.type === "numeric" || payloadKey.type === "integer";

  function submit() {
    const raw = value.trim();
    if (raw === "" && required) {
      signal("rejected");
      return;
    }
    if (raw === "") {
      onCaptured(null);
      return;
    }
    if (numeric) {
      const n = Number(raw);
      if (!Number.isFinite(n)) {
        signal("rejected");
        return;
      }
      signal("accepted");
      onCaptured(n);
      return;
    }
    signal("accepted");
    onCaptured(raw);
  }

  return (
    <form
      className="flex flex-1 flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
    >
      <label className="block text-base font-medium">
        {numeric ? ui("Enter the number") : ui("Enter the value")}
        <input
          ref={input}
          className={`${FIELD} ${numeric ? "text-4xl tabular-nums" : ""}`}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          inputMode={numeric ? "decimal" : "text"}
          enterKeyHint="done"
          autoComplete="off"
        />
      </label>
      <div className="mt-auto flex flex-col gap-3">
        <button type="submit" className={PRIMARY}>
          {ui("Next")}
        </button>
        {!required ? (
          <button type="button" className={SECONDARY} onClick={() => onCaptured(null)}>
            {ui("Skip")}
          </button>
        ) : null}
      </div>
    </form>
  );
}

// ── Stage: stock enquiry, the one step that writes nothing ──────────────────

function Enquiry({
  reference,
  task,
  deviceCode,
  online,
  onBack,
}: {
  reference: Cache;
  task: DeviceTask;
  deviceCode: string;
  online: boolean;
  onBack: () => void;
}) {
  const { ui } = useT();
  const [rows, setRows] = useState<Position[] | null>(null);
  const [label, setLabel] = useState<string | null>(null);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <button type="button" className={`${SMALL} self-start`} onClick={onBack}>
        {ui("Back")}
      </button>
      <h1 className="text-2xl font-semibold">{ui("Scan a product, location or handling unit")}</h1>
      {!online ? (
        <p role="status" className="text-base">
          {ui("Positions are read from the server. Reconnect to see them.")}
        </p>
      ) : null}
      {rows === null ? (
        <ScanInput
          payloadKey="any"
          taskCode={task.code}
          rules={task.scan_rules}
          reference={reference}
          deviceCode={deviceCode}
          online={online}
          onCaptured={(_value, capture) => {
            setLabel(capture.label);
            if (!capture.id) {
              setRows([]);
              return;
            }
            void callErp<Position[]>("erp_device_stock_position", {
              p_reference_id: capture.id,
              p_device_code: deviceCode,
            })
              .then(setRows)
              .catch(() => setRows([]));
          }}
        />
      ) : (
        <div className="flex flex-1 flex-col gap-3">
          {label ? <p className="text-lg font-semibold">{label}</p> : null}
          {rows.length === 0 ? <p className="text-base">{ui("Nothing is held here.")}</p> : null}
          <ul className="flex flex-col gap-2">
            {rows.map((r, i) => (
              <li key={i} className="rounded-xl border-2 border-input px-4 py-3">
                <div className="text-lg font-semibold tabular-nums">
                  {r.quantity} · {r.item}
                </div>
                <div className="text-base text-muted-foreground">
                  {r.item_name} · {r.location}
                  {r.container ? ` · ${r.container}` : ""}
                </div>
                <div className="text-sm text-muted-foreground">
                  {r.stock_status}
                  {r.batch ? ` · ${r.batch}` : ""}
                  {r.expires_on ? ` · ${ui("expires")} ${r.expires_on}` : ""}
                </div>
              </li>
            ))}
          </ul>
          <div className="mt-auto">
            <button
              type="button"
              className={PRIMARY}
              onClick={() => {
                setRows(null);
                setLabel(null);
              }}
            >
              {ui("Scan another")}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Stage: done ──────────────────────────────────────────────────────────────

function Done({
  taskName,
  queued,
  online,
  onAgain,
  onTasks,
}: {
  taskName: string;
  queued: number;
  online: boolean;
  onAgain: () => void;
  onTasks: () => void;
}) {
  const { ui } = useT();
  return (
    <div className="flex flex-1 flex-col gap-4">
      <h1 className="text-2xl font-semibold">
        ✓ {ui("Captured")}: {taskName}
      </h1>
      <p className="text-base text-muted-foreground">
        {online
          ? ui(
              "Sent. It applies in the order it was captured; a conflict shows in the queue with its reason.",
            )
          : `${ui("Held on this device until the network returns.")} ${queued}`}
      </p>
      <div className="mt-auto flex flex-col gap-3">
        <button type="button" className={PRIMARY} onClick={onAgain}>
          {ui("Same task again")}
        </button>
        <button type="button" className={SECONDARY} onClick={onTasks}>
          {ui("Another task")}
        </button>
      </div>
    </div>
  );
}

// ── Stage: the queue ─────────────────────────────────────────────────────────

function QueueScreen({
  queue,
  conflicts,
  online,
  syncing,
  lastSync,
  onSync,
  onBack,
}: {
  queue: QueuedAction[];
  conflicts: QueueRow[];
  online: boolean;
  syncing: boolean;
  lastSync: string | null;
  onSync: () => void;
  onBack: () => void;
}) {
  const { ui } = useT();
  const s = summarise(queue);
  return (
    <div className="flex flex-1 flex-col gap-4">
      <button type="button" className={`${SMALL} self-start`} onClick={onBack}>
        {ui("Back")}
      </button>
      <h1 className="text-2xl font-semibold">{ui("Your queue")}</h1>
      <p className="text-base text-muted-foreground">
        {ui("Waiting to send")}: {s.pending} · {ui("Sent, not yet applied")}: {s.sent} ·{" "}
        {ui("Conflicted")}: {conflicts.length}
        {lastSync ? ` · ${ui("last sync")} ${new Date(lastSync).toLocaleTimeString()}` : ""}
      </p>
      {conflicts.length > 0 ? (
        <section className="flex flex-col gap-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide">
            {ui("Could not be applied")}
          </h2>
          {conflicts.map((c) => (
            <div key={c.action_id} className="rounded-xl border-2 border-foreground px-4 py-3">
              <div className="text-lg font-semibold">✕ {c.task_code}</div>
              <div className="text-base">{c.conflict_reason}</div>
              <div className="text-sm text-muted-foreground">
                {new Date(c.captured_at).toLocaleString()}
              </div>
            </div>
          ))}
        </section>
      ) : null}
      {queue.length > 0 ? (
        <section className="flex flex-col gap-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide">{ui("On this device")}</h2>
          {queue.map((q) => (
            <div key={q.idempotency_key} className="rounded-xl border-2 border-input px-4 py-3">
              <div className="text-lg font-semibold">
                {q.state === "pending" ? "○" : "●"} {q.task_code}
              </div>
              <div className="text-base text-muted-foreground">
                {q.state === "pending" ? ui("Waiting to send") : ui("Sent, not yet applied")}
                {q.input_method === "keyed" ? ` · ${ui("keyed")}` : ""}
              </div>
              {q.last_error ? <div className="text-base">{q.last_error}</div> : null}
              <div className="text-sm text-muted-foreground">
                {new Date(q.captured_at).toLocaleString()}
              </div>
            </div>
          ))}
        </section>
      ) : null}
      {queue.length === 0 && conflicts.length === 0 ? (
        <p className="text-base">{ui("Everything you captured has landed.")}</p>
      ) : null}
      <div className="mt-auto">
        <button type="button" className={PRIMARY} disabled={!online || syncing} onClick={onSync}>
          {syncing ? ui("Syncing…") : online ? ui("Sync now") : ui("Offline")}
        </button>
      </div>
    </div>
  );
}
