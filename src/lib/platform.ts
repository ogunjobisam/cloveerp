import { useQuery } from "@tanstack/react-query";

import { APEX_HOST, DEMO_HOST } from "./backend";
import { callErp, supabase } from "./erp";
import { displayAddress } from "./tenant-address";

/**
 * The platform layer: the product's own staff, above every tenant.
 *
 * A tenant administrator is the most powerful person inside one company. This
 * is the other axis — the people who run the product itself, who create those
 * companies and can be let into them to help. It is deliberately a separate
 * list with its own ranks rather than a permission inside a tenant,
 * because "can administer Acme" and "can create companies" are not the same
 * claim and should never be reachable from one another.
 *
 * Four ranks, not three, since the administrator was added: running the
 * platform and owning it are separable, and everything an operator could not do
 * used to fall to the owner. An administrator runs it. Choosing who else runs
 * it, moving a company to another owner and purging one stay with the owner —
 * the last because it cannot be undone.
 */

export type PlatformRole = "owner" | "administrator" | "operator" | "support";

export type PlatformMe = {
  is_staff: boolean;
  role: PlatformRole | null;
  email?: string | null;
  display_name?: string | null;
  /** True only when the staff list is empty: the platform has no owner yet. */
  claimable: boolean;
  /**
   * Which deployment answered (20261010060000). Absent from a database older
   * than the marker, which is read as it always was: demonstrations are made
   * here. A client's own project answers `client` (20261011010000).
   */
  deployment?: DeploymentKind;
  /** Where this deployment is served from, once a release has said (20261011010000). */
  origin?: string | null;
  /** The Supabase project this deployment runs in, once a release has said. */
  project_ref?: string | null;
  /**
   * A client deployment's own code, the host label of its origin
   * (acme for https://acme.cloveerp.com): the code its one organisation must
   * have. Null anywhere but a client (20261011090000).
   */
  deployment_code?: string | null;
};

/**
 * The three kinds of deployment (20261011010000): production is the control
 * plane at cloveerp.com, with Clove Foods on it; the demonstration is its own
 * project at demo.cloveerp.com; a client is one customer's own project at
 * <code>.cloveerp.com.
 */
export type DeploymentKind = "production" | "demonstration" | "client";

/** Where a client deployment is, from requested to retired (erp_meta.deployment). */
export type ClientDeploymentStatus =
  | "requested"
  | "creating"
  | "building"
  | "built"
  | "live"
  | "suspended"
  | "retiring"
  | "retired"
  | "failed";

/**
 * The steps a person still does by hand after a client's build, in the order they are done.
 * Since 8 October the application is a Cloudflare Worker serving every subdomain through one
 * wildcard route, so a client needs no domain or DNS record of its own; the register still
 * accepts those two items for a row ticked before then.
 */
export const CHECKLIST_ITEMS = [
  { key: "google_sign_in", label: "Google sign-in (if wanted)" },
  { key: "resend_webhook", label: "Resend webhook" },
] as const;

export type ChecklistItem = (typeof CHECKLIST_ITEMS)[number]["key"];

/**
 * What the fleet poll last read from one client's own database
 * (erp_meta.record_deployment_health, 20261012010000). Every key may be
 * missing: a poll that could not read something leaves it out and says why
 * in errors.
 */
export type DeploymentHealth = {
  /** The commit the client's database says it was last released at. */
  release_sha?: string | null;
  /** How many assurance checks failed when the poll ran them; 0 is clean. */
  assurance_failures?: number | null;
  assurance_at?: string | null;
  database_bytes?: number | null;
  /** When the dispatch function last finished draining the client's queue. */
  last_drain_pass_at?: string | null;
  open_support_windows?: number | null;
  /** Whether the client's staff list matches the control plane's. */
  staff_in_step?: boolean | null;
  /** The newest backup of the client's project, and how many are kept. */
  backups_latest_at?: string | null;
  backups_count?: number | null;
  /** What the poll could not read, in plain words. */
  errors?: string[] | null;
  polled_at?: string | null;
};

/** One client deployment as the register holds it, for the Fleet view (erp_platform_deployments). */
export type ClientDeployment = {
  code: string;
  client_name: string;
  status: ClientDeploymentStatus;
  /** The first administrator; cleared when the deployment is retired (20261011040000). */
  owner_email: string | null;
  project_ref: string | null;
  api_url: string | null;
  region: string;
  instance_size: string;
  /** https://<code>.cloveerp.com, as the control plane's own origin spells the apex. */
  origin: string;
  build_run_id: string | null;
  built_at: string | null;
  last_release_sha: string | null;
  last_release_at: string | null;
  last_release_outcome: "success" | "failure" | "cancelled" | null;
  last_release_run_id: string | null;
  checklist: Partial<Record<ChecklistItem, { done: boolean; at: string; by: string }>>;
  note: string | null;
  created_at: string;
  updated_at: string;
  /** The latest build request: queued until the sweep starts the run, claimed once it has. */
  request_status: "requested" | "claimed" | "done" | "failed" | "cancelled" | null;
  request_run_id: string | null;
  /** When the latest build request was made, claimed by the sweep and settled. */
  request_created_at?: string | null;
  request_claimed_at?: string | null;
  request_settled_at?: string | null;
  /**
   * Whether Start again would be accepted now: the database's own rule
   * (erp_meta.deployment_restart_refusal, 20261011110000), so the console
   * offers the door only when the door would open.
   */
  restartable?: boolean;
  last_event: { phase: string; status: string; detail: string | null; at: string } | null;
  /**
   * What the fleet poll last read from the client's database, and when it was
   * recorded; null until a poll has reached it (20261012010000). Absent from
   * a register older than the poll.
   */
  health?: DeploymentHealth | null;
  health_at?: string | null;
  /**
   * The database's own judgement: built or live, and not heard from for 26
   * hours, or never.
   */
  silent?: boolean;
  /**
   * The address it is served at, <address>.cloveerp.com (20261012020000):
   * its code until it is renamed. The code never changes; a rename gives a
   * new address. Absent from a register older than renaming, where the
   * address is the code.
   */
  address?: string;
  /** The address it was renamed from, which sends people on until previous_address_until. */
  previous_address?: string | null;
  previous_address_until?: string | null;
  /** When offboarding began: the day its project is due to be purged. */
  purge_due_at?: string | null;
  /** Why its service is suspended, while it is. */
  suspended_reason?: string | null;
  /** The last export of its database off the platform, and the object it was written to. */
  last_export_at?: string | null;
  last_export_object?: string | null;
};

/**
 * When the sweep starts what the console asks for, as the console says it.
 * The control plane wakes the sweep the moment a request is written, when it
 * has been given the means to (20261012010000); otherwise the sweep's own
 * ten-minute schedule finds the request. The console cannot tell which, so it
 * says both.
 */
export const SWEEP_STARTS =
  "within a minute when the control plane can wake the sweep, otherwise within ten";

/**
 * How long a build request may sit with nothing happening before the owner is
 * offered Start again. The sweep claims a request within ten minutes at the
 * latest, and the build records its first step within a minute or two of
 * starting, so twenty minutes of silence means the request, or the run it
 * started, is lost.
 */
export const STALE_BUILD_REQUEST_MINUTES = 20;

/** The parts of a register row the build rule reads. */
export type BuildRequestView = Pick<
  ClientDeployment,
  | "status"
  | "request_status"
  | "request_created_at"
  | "request_claimed_at"
  | "request_settled_at"
  | "restartable"
  | "last_event"
>;

/** The latest of some timestamps, in milliseconds; null when none is readable. */
function latestOf(...values: (string | null | undefined)[]): number | null {
  let latest: number | null = null;
  for (const v of values) {
    if (typeof v !== "string") continue;
    const t = Date.parse(v);
    if (Number.isNaN(t)) continue;
    if (latest === null || t > latest) latest = t;
  }
  return latest;
}

/**
 * Whether the newest build request of a requested deployment has stalled.
 *
 * Two ways, both after twenty minutes with nothing happening:
 *
 *   - the request is still open (queued or claimed): the sweep never started
 *     it, or died between claiming and starting. Counted from when it last
 *     moved, its claim if it has one, so a request claimed late is not judged
 *     by its age alone.
 *   - the request is done, so the sweep started a run, but the deployment is
 *     still only requested: the run never got going. Counted from the later of
 *     the settling and the last step recorded on the deployment.
 *
 * A row whose request failed, was cancelled or does not exist has nothing in
 * flight; Retry is for that. Without the times, nothing is judged stale.
 */
export function buildRequestIsStale(d: BuildRequestView, now: Date): boolean {
  if (d.status !== "requested") return false;
  let since: number | null;
  if (d.request_status === "requested" || d.request_status === "claimed") {
    since = latestOf(d.request_created_at, d.request_claimed_at);
  } else if (d.request_status === "done") {
    since = d.request_settled_at ? latestOf(d.request_settled_at, d.last_event?.at) : null;
  } else {
    return false;
  }
  if (since === null) return false;
  return now.getTime() - since >= STALE_BUILD_REQUEST_MINUTES * 60_000;
}

/**
 * What the owner is offered to get a deployment's build going again.
 *
 *   retry        the build stopped (failed), or a requested deployment has no
 *                request in flight (its request failed, was cancelled, or
 *                there is none): erp_platform_retry_deployment.
 *   start-again  a requested deployment whose newest request has stalled
 *                (buildRequestIsStale): erp_platform_restart_deployment,
 *                which cancels the stalled request and queues a new one.
 *   null         nothing: a build is under way, or a request is in flight and
 *                has not stalled yet. A second build queued behind a running
 *                one waits for it and then finds the row built.
 */
export function buildRecovery(d: BuildRequestView, now: Date): "retry" | "start-again" | null {
  if (d.status === "failed") return "retry";
  if (d.status !== "requested") return null;
  const inFlight =
    d.request_status === "requested" ||
    d.request_status === "claimed" ||
    d.request_status === "done";
  if (!inFlight) return "retry";
  // The database says whether Start again would be accepted; follow it.
  if (d.restartable === true) return "start-again";
  if (!buildRequestIsStale(d, now)) return null;
  // Silent for twenty minutes, yet the door refuses: a run that said it had
  // started and was lost before it made anything. No request is open, so
  // Retry takes it.
  if (d.restartable === false) return d.request_status === "done" ? "retry" : null;
  // A register from before the rule was shared.
  return "start-again";
}

/**
 * How long ago a time was, as a person says it: "just now", "5 minutes ago",
 * "3 hours ago", "2 days ago". Hours run to two days so that a day and a bit
 * reads as the hours it is. A time ahead of the clock (a skewed one) is just
 * now; one that cannot be read is null.
 */
export function agoText(iso: string | null | undefined, now: Date): string | null {
  if (typeof iso !== "string") return null;
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return null;
  const minutes = Math.floor((now.getTime() - at) / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} ${minutes === 1 ? "minute" : "minutes"} ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours} ${hours === 1 ? "hour" : "hours"} ago`;
  return `${Math.floor(hours / 24)} days ago`;
}

/** 1536 as "1,536", whatever the browser's locale. */
function grouped(n: number): string {
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

/**
 * A database's size in megabytes (of 1,048,576 bytes, as Postgres counts
 * them): "8.4 MB" under ten, "312 MB" or "1,536 MB" above. Null for anything
 * that is not a size.
 */
export function databaseSizeText(bytes: number | null | undefined): string | null {
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0) return null;
  const tenths = Math.round((bytes / 1_048_576) * 10) / 10;
  if (tenths < 10) return `${tenths.toFixed(1)} MB`;
  return `${grouped(Math.round(tenths))} MB`;
}

/**
 * A count the poll wrote: a whole number, or one written as text. Anything
 * else is not known.
 */
function countOf(v: unknown): number | null {
  if (typeof v === "number") return Number.isInteger(v) && v >= 0 ? v : null;
  if (typeof v === "string" && /^\d+$/.test(v.trim())) return Number(v.trim());
  return null;
}

export type HealthTone = "ok" | "warn" | "bad" | "muted";

/** One phrase of a deployment's health line. */
export type HealthPart = { key: string; text: string; tone: HealthTone };

/**
 * A built or live deployment's health, compact: a sentence first when the
 * database marks it silent, then a phrase for each thing the poll read, then
 * what the poll could not read.
 */
export type HealthLine = { silence: string | null; parts: HealthPart[]; errors: string[] };

/** The states whose project the fleet poll reads. */
const POLLED: ReadonlySet<ClientDeploymentStatus> = new Set([
  "built",
  "live",
  "suspended",
  "retiring",
]);

/**
 * What the Fleet view says of a deployment's health (erp_platform_deployments'
 * health, health_at and silent).
 *
 * Only for a deployment whose project is up and the poll reads — built,
 * live, suspended (its project runs; only its address is not served) or
 * being offboarded — and only when the register says something: a register
 * older than the poll says nothing, so nothing is shown. Each phrase appears
 * only when the poll read it. Colour is kept for assurance, green when it is
 * clean, and for what wants attention: a failing assurance check, a support
 * window open, staff out of step, no backup, and errors. Silence is the
 * database's judgement and is said first, with when the poll last read the
 * deployment, if it ever has.
 */
export function deploymentHealthLine(
  d: Pick<ClientDeployment, "status" | "health" | "health_at" | "silent">,
  now: Date,
): HealthLine | null {
  if (!POLLED.has(d.status)) return null;
  const h: DeploymentHealth | null = d.health ?? null;
  const silent = d.silent === true;
  if (h === null && !silent) return null;

  const heard = agoText(h?.polled_at, now) ?? agoText(d.health_at, now);
  const silence = !silent
    ? null
    : heard === null
      ? "Not heard from yet: the fleet poll has never read it."
      : `Not heard from for over a day: the fleet poll last read it ${heard}.`;

  const parts: HealthPart[] = [];
  if (h === null) return { silence, parts, errors: [] };
  if (!silent && heard !== null)
    parts.push({ key: "polled", text: `polled ${heard}`, tone: "muted" });

  const failures = countOf(h.assurance_failures);
  if (failures === 0) parts.push({ key: "assurance", text: "assurance clean", tone: "ok" });
  else if (failures !== null)
    parts.push({
      key: "assurance",
      text: `${failures} assurance ${failures === 1 ? "check" : "checks"} failing`,
      tone: "bad",
    });

  const size = databaseSizeText(countOf(h.database_bytes));
  if (size !== null) parts.push({ key: "size", text: `database ${size}`, tone: "muted" });

  const drained = agoText(h.last_drain_pass_at, now);
  if (drained !== null)
    parts.push({ key: "drain", text: `queue drained ${drained}`, tone: "muted" });

  const windows = countOf(h.open_support_windows);
  if (windows === 0) parts.push({ key: "support", text: "no support window open", tone: "muted" });
  else if (windows !== null)
    parts.push({
      key: "support",
      text: `${windows} support ${windows === 1 ? "window" : "windows"} open`,
      tone: "warn",
    });

  if (h.staff_in_step === true) parts.push({ key: "staff", text: "staff in step", tone: "muted" });
  else if (h.staff_in_step === false)
    parts.push({ key: "staff", text: "staff out of step", tone: "warn" });

  const backups = countOf(h.backups_count);
  const backedUp = agoText(h.backups_latest_at, now);
  if (backups === 0) parts.push({ key: "backup", text: "no backup yet", tone: "warn" });
  else if (backedUp !== null)
    parts.push({
      key: "backup",
      text: backups === null ? `backup ${backedUp}` : `backup ${backedUp} (${backups} kept)`,
      tone: "muted",
    });
  else if (backups !== null)
    parts.push({
      key: "backup",
      text: `${backups} ${backups === 1 ? "backup" : "backups"} kept`,
      tone: "muted",
    });

  const errors = (Array.isArray(h.errors) ? (h.errors as unknown[]) : [])
    .filter((e): e is string => typeof e === "string" && e.trim() !== "")
    .map((e) => e.trim());

  return { silence, parts, errors };
}

/** The host an origin names (acme.cloveerp.com for https://acme.cloveerp.com); null if it is not one. */
export function hostOfOrigin(origin: string | null | undefined): string | null {
  if (typeof origin !== "string" || origin.trim() === "") return null;
  try {
    const host = new URL(origin.trim()).host;
    return host === "" ? null : host;
  } catch {
    return null;
  }
}

/**
 * The apex an origin is served under: cloveerp.com for
 * https://acme.cloveerp.com. Null for an origin with no label to drop.
 */
function apexOfOrigin(origin: string | null | undefined): string | null {
  const host = hostOfOrigin(origin);
  if (host === null) return null;
  const dot = host.indexOf(".");
  return dot > 0 && dot < host.length - 1 ? host.slice(dot + 1) : null;
}

/**
 * A client deployment's address, as a person reads it: acme.cloveerp.com.
 * Its address under the apex its origin is served from, once the register
 * says what the address is (a rename changes it, never the code); before
 * that, its origin's host; and failing both, its code under the apex.
 */
export function deploymentAddress(
  d: Pick<ClientDeployment, "code" | "origin"> & { address?: string | null | undefined },
): string {
  if (typeof d.address === "string" && d.address !== "") {
    return `${d.address}.${apexOfOrigin(d.origin) ?? APEX_HOST}`;
  }
  return hostOfOrigin(d.origin) ?? `${d.code}.${APEX_HOST}`;
}

/** Where a client deployment is served: https://acme.cloveerp.com, at its address. */
export function deploymentOrigin(
  d: Pick<ClientDeployment, "code" | "origin"> & { address?: string | null | undefined },
): string {
  return `https://${deploymentAddress(d)}`;
}

/**
 * An address a deployment can be given (erp_platform_request_deployment's
 * code, erp_platform_rename_deployment's new address): the shape the database
 * checks, a DNS label of three to sixty-three characters. Whether anybody
 * already holds it is the database's to say.
 */
export const DEPLOYMENT_ADDRESS_PATTERN = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;

export function isDeploymentAddress(value: string): boolean {
  return DEPLOYMENT_ADDRESS_PATTERN.test(value);
}

const MONTHS = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

/**
 * A day as a person reads it, the same wherever the console is opened:
 * 9 January 2027, in UTC. Null for anything that is not a time.
 */
export function dayText(iso: string | null | undefined): string | null {
  if (typeof iso !== "string") return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  const d = new Date(t);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()] ?? ""} ${d.getUTCFullYear()}`;
}

/**
 * How long after offboarding begins a client's project is purged, at the
 * earliest: thirty days after the later of that day and the end of the
 * current term of a contract in force naming it
 * (erp_platform_begin_offboarding).
 */
export const OFFBOARDING_COOL_OFF_DAYS = 30;

/** The earliest a client's project can be purged if offboarding begins at `now`. */
export function earliestPurgeDate(now: Date): string {
  return new Date(now.getTime() + OFFBOARDING_COOL_OFF_DAYS * 86_400_000).toISOString();
}

/**
 * What a row in the Fleet view offers, in the order it offers them.
 *
 *   open-console  its own console: built, live or being offboarded, the
 *                 states whose address is served. Not suspended: its address
 *                 shows only that it is suspended.
 *   onboard       its first organisation, on its own console: built or live.
 *   retry, start-again
 *                 getting a build going again (buildRecovery); the owner's.
 *   suspend       stop its address being served: built or live; the owner's.
 *   reinstate     serve it again: suspended; the owner's.
 *   rename        a new address: built, live or suspended; the owner's.
 *   export        an encrypted copy of its database off the platform: built,
 *                 live, suspended or being offboarded; an operator's and up.
 *   offboard      begin offboarding: built, live or suspended; the owner's.
 *   retire        the last step, before its project is deleted: any state
 *                 but a build under way and retired already; the owner's.
 *
 * The doors decide regardless (each requires its rank and refuses a state it
 * does not take); this is so the console offers only what would open.
 */
export type FleetAction =
  | "open-console"
  | "onboard"
  | "retry"
  | "start-again"
  | "suspend"
  | "reinstate"
  | "rename"
  | "export"
  | "offboard"
  | "retire";

/** The states whose address is served: the directory names their project. */
const SERVED: ReadonlySet<ClientDeploymentStatus> = new Set(["built", "live", "retiring"]);

/**
 * Where the owner may retire a deployment (20261011040000): any state but a
 * build in progress, which would refuse to finish, and retired already.
 */
const RETIRABLE: ReadonlySet<ClientDeploymentStatus> = new Set([
  "requested",
  "failed",
  "built",
  "live",
  "suspended",
  "retiring",
]);

export function fleetActions(
  d: BuildRequestView,
  role: PlatformRole | null | undefined,
  now: Date,
): FleetAction[] {
  const owner = atLeast(role, "owner");
  const operator = atLeast(role, "operator");
  const s = d.status;
  const up = s === "built" || s === "live";
  const actions: FleetAction[] = [];
  if (SERVED.has(s)) actions.push("open-console");
  if (up) actions.push("onboard");
  if (owner) {
    const recovery = buildRecovery(d, now);
    if (recovery !== null) actions.push(recovery);
    if (up) actions.push("suspend");
    if (s === "suspended") actions.push("reinstate");
    if (up || s === "suspended") actions.push("rename");
  }
  if (operator && (up || s === "suspended" || s === "retiring")) actions.push("export");
  if (owner) {
    if (up || s === "suspended") actions.push("offboard");
    if (RETIRABLE.has(s)) actions.push("retire");
  }
  return actions;
}

/**
 * What the Fleet view says of where a deployment stands in its lifecycle,
 * under its state: why it is suspended, when its project is due to be
 * purged, and the address it moved from while that still sends people on.
 */
export type LifecycleNote = { key: string; text: string; tone: HealthTone };

export function deploymentLifecycleNotes(
  d: Pick<
    ClientDeployment,
    | "code"
    | "origin"
    | "status"
    | "previous_address"
    | "previous_address_until"
    | "purge_due_at"
    | "suspended_reason"
  >,
  now: Date,
): LifecycleNote[] {
  const notes: LifecycleNote[] = [];
  if (d.status === "suspended") {
    const why = typeof d.suspended_reason === "string" ? d.suspended_reason.trim() : "";
    notes.push({
      key: "suspended",
      text:
        why === "" ? "Its address shows only that its service is suspended." : `Suspended: ${why}`,
      tone: "warn",
    });
  }
  if (d.status === "retiring") {
    const due = dayText(d.purge_due_at);
    notes.push({
      key: "purge",
      text:
        due === null
          ? "Being offboarded."
          : `Being offboarded: its project is due to be purged on ${due}.`,
      tone: "warn",
    });
  }
  const until = dayText(d.previous_address_until);
  const untilAt =
    typeof d.previous_address_until === "string" ? Date.parse(d.previous_address_until) : NaN;
  if (
    typeof d.previous_address === "string" &&
    d.previous_address !== "" &&
    until !== null &&
    untilAt > now.getTime()
  ) {
    notes.push({
      key: "moved",
      text: `Was ${d.previous_address}.${apexOfOrigin(d.origin) ?? APEX_HOST}, which sends people here until ${until}.`,
      tone: "muted",
    });
  }
  return notes;
}

/**
 * The last export of a deployment's database, as the Fleet view says it:
 * "exported 3 hours ago"; null when it has never been exported.
 */
export function lastExportText(
  d: Pick<ClientDeployment, "last_export_at">,
  now: Date,
): string | null {
  const ago = agoText(d.last_export_at, now);
  return ago === null ? null : `exported ${ago}`;
}

/**
 * Where an organisation listed on this console lives, for the Where column.
 *
 * On the control plane every organisation shares the one project and is
 * reached at cloveerp.com/<code>. A client's project is the organisation's
 * own, reached at its own address. The demonstration's organisations share
 * its project, at its own host.
 */
export function organisationWhere(
  code: string,
  me: Pick<PlatformMe, "deployment" | "origin"> | undefined,
): string {
  const host = hostOfOrigin(me?.origin);
  if (me?.deployment === "client") return `${host ?? "this address"}, own project`;
  if (me?.deployment === "demonstration") return `${host ?? DEMO_HOST}, shared`;
  return `${displayAddress(APEX_HOST, code)}, shared`;
}

/**
 * Somebody a contract or quote can be for: an organisation on this
 * deployment, or a client deployment, which holds its organisation in a
 * project of its own (20261011090000).
 */
export type CustomerChoice = {
  code: string;
  name: string;
  where: "organisation" | "deployment";
};

/** The deployment statuses a contract may still name: any but retiring and retired. */
const CONTRACTABLE_DEPLOYMENT: ReadonlySet<string> = new Set([
  "requested",
  "creating",
  "building",
  "built",
  "live",
  "suspended",
  "failed",
]);

/**
 * Who a quote or contract can be for: the organisations
 * erp_platform_commercial_state offers as candidates, less demonstrations and
 * the platform organisation itself, then every client deployment not being
 * retired. The deployments are never mixed into the candidates themselves,
 * which are also who may be designated the platform organisation: a
 * deployment cannot be. A code held by both (the database never lets it be)
 * is the organisation's.
 */
export function customerChoices(
  candidates: readonly { code: string; name: string; is_demonstration: boolean }[],
  deployments: readonly { code: string; name: string; status: string }[] | null | undefined,
  platformCode: string | null | undefined,
): CustomerChoice[] {
  const organisations: CustomerChoice[] = candidates
    .filter((c) => !c.is_demonstration && c.code !== platformCode)
    .map((c) => ({ code: c.code, name: c.name, where: "organisation" }));
  const taken = new Set(organisations.map((c) => c.code));
  const clients: CustomerChoice[] = (deployments ?? [])
    .filter((d) => CONTRACTABLE_DEPLOYMENT.has(d.status) && !taken.has(d.code))
    .map((d) => ({ code: d.code, name: d.name, where: "deployment" }));
  return [...organisations, ...clients];
}

/** How a choice reads in a picker; a client deployment says it is one. */
export function customerChoiceText(c: {
  code: string;
  name: string;
  where?: "organisation" | "deployment" | undefined;
}): string {
  return c.where === "deployment"
    ? `${c.name} (${c.code}), client deployment at ${c.code}.${APEX_HOST}`
    : `${c.name} (${c.code})`;
}

/** One step a workflow recorded on a client deployment (erp_platform_deployment_events). */
export type DeploymentEvent = {
  id: number;
  phase: string;
  status: "started" | "done" | "failed" | "note";
  detail: string | null;
  run_id: string | null;
  at: string;
};

export type PlatformTenant = {
  id: string;
  code: string;
  name: string;
  status: string;
  created_at: string;
  provisioned_at: string | null;
  suspended_at: string | null;
  /** When deletion was requested or the organisation was marked ended. */
  deleted_at: string | null;
  principals: number;
  entities: number;
  sites: number;
  open_invitations: number;
  /** Which platform owner is accountable for this company, if any yet. */
  owner_staff_id: string | null;
  owner_email: string | null;
  owner_name: string | null;
  owned_by_me: boolean | null;
  owner_since: string | null;
  /** Set while an offer is open, so the row can say so rather than offer again. */
  pending_transfer_to: string | null;
};

/** One person in an organisation, for its console page. Operator and up. */
export type OrganisationPerson = {
  principal_id: string;
  display_name: string | null;
  email: string | null;
  kind: string;
  status: string;
  roles: string[];
  /** From the sign-in service; null for somebody who has never signed in. */
  last_sign_in_at: string | null;
};

/** A support window still open, anywhere on the deployment. */
export type SupportWindow = {
  access_id: string;
  tenant_id: string;
  tenant_code: string;
  tenant_name: string;
  staff_email: string;
  staff_role: string;
  reason: string;
  is_write_access: boolean;
  granted_at: string;
  expires_at: string;
};

/** An issued contract invoice not yet paid, anywhere on the deployment. */
export type OpenInvoice = {
  invoice_id: string;
  reference: string;
  contract_id: string;
  tenant_code: string;
  customer_legal_name: string;
  period_start: string;
  period_end: string;
  due_on: string;
  issued_at: string | null;
  currency: string;
  total_minor: number;
  overdue: boolean;
  days_overdue: number;
  /** The client deployment the contract names, when it names one (20261011130000). */
  deployment_code?: string | null;
};

/**
 * An offer to hand a company to another owner.
 *
 * The row outlives the decision: declined and withdrawn offers stay exactly
 * where they are, because who was asked and refused is part of the record.
 */
export type OwnershipTransfer = {
  id: string;
  tenant_id: string;
  tenant_code: string | null;
  tenant_name: string | null;
  from_staff_id: string;
  from_email: string;
  from_name: string;
  to_staff_id: string;
  to_email: string;
  to_name: string;
  status: "pending" | "accepted" | "declined" | "cancelled" | "expired";
  reason: string | null;
  response_note: string | null;
  expires_at: string;
  created_at: string;
  settled_at: string | null;
  is_mine_to_answer: boolean;
  is_mine_to_withdraw: boolean;
};

export type PlatformStaff = {
  id: string;
  email: string;
  display_name: string;
  role: PlatformRole;
  bound: boolean;
  created_at: string;
  revoked_at: string | null;
};

export type PlatformAuditRow = {
  id: number;
  occurred_at: string;
  actor_email: string | null;
  actor_role: string | null;
  action: string;
  tenant_code: string | null;
  target: string | null;
  reason: string | null;
  detail: Record<string, unknown>;
};

/**
 * The same order erp_meta.platform_rank() computes in the database, and the
 * reason every gate here is a comparison rather than an equality: a rank added
 * between two others must not silently drop out of a test written as `===`.
 */
const RANK: Record<PlatformRole, number> = {
  owner: 4,
  administrator: 3,
  operator: 2,
  support: 1,
};

export function atLeast(role: PlatformRole | null | undefined, min: PlatformRole): boolean {
  return role ? RANK[role] >= RANK[min] : false;
}

/**
 * Whether the account is one of the people who run the product for customers:
 * a platform operator or owner. Support staff are not, and nor is anybody whose
 * answer has not arrived — a customer must never see the platform's own
 * material while the question is still outstanding.
 *
 * What it decides is only what the desk shows. The doors behind that material
 * decide for themselves.
 */
export function isPlatformOperator(me: Pick<PlatformMe, "is_staff" | "role"> | undefined): boolean {
  return me?.is_staff === true && atLeast(me.role, "operator");
}

/**
 * Whether demonstrations are made somewhere else (src/lib/backend.ts's
 * DEMO_ADDRESS) rather than here. Production says so, and its doors refuse to
 * make one (20261010061000); so does a client's own project (20261011010000).
 * A screen then offers the address instead of a button that can only be
 * refused. The demonstration, the schema build's database and one older than
 * the marker make demonstrations as before.
 */
export function demonstrationsLiveElsewhere(
  me: Pick<PlatformMe, "deployment"> | undefined,
): boolean {
  return me?.deployment === "production" || me?.deployment === "client";
}

export const ROLE_BLURB: Record<PlatformRole, string> = {
  owner:
    "Full control, including who else works on the platform, who each company belongs to, and purging one.",
  administrator:
    "Runs the platform: billing, sign-up, and ending or reinstating a company. Cannot change who runs it, and cannot purge.",
  operator: "Onboards and manages companies, and invites their administrators.",
  support: "Reads the company list and the activity log, and may be let in to help.",
};

/**
 * How a rank is shown wherever it is shown as a pill. Four ranks and three
 * usable tones, so the bands are "changes the platform itself" (owner and
 * administrator), "runs the companies" (operator) and "looks" (support); the
 * word inside the pill is what tells the first two apart. The fourth tone is
 * destructive red and a rank is not a fault.
 */
export const ROLE_TONE: Record<PlatformRole, "ok" | "warn" | "muted"> = {
  owner: "ok",
  administrator: "ok",
  operator: "warn",
  support: "muted",
};

/**
 * Asked once wherever the console might be offered. It answers on every
 * signed-in account, staff or not, so the absence of a menu entry is a fact
 * rather than a guess.
 */
export function usePlatformMe(enabled = true) {
  return useQuery({
    queryKey: ["erp_platform_me"],
    queryFn: () => callErp<PlatformMe>("erp_platform_me"),
    enabled: Boolean(supabase) && enabled,
    staleTime: 60_000,
  });
}

/* -------------------------------------------------------------------------- */
/* The superadmin console's reads.                                            */
/* -------------------------------------------------------------------------- */

export type DiagnosticCheck = {
  code: string;
  title: string;
  kind: "assertion" | "report";
  scope: "platform" | "tenant";
  blurb: string;
  runs_in_ci: boolean;
  has_detail: boolean;
  function: string;
};

/**
 * `ok` is deliberately nullable: a tenant-scoped check run outside an
 * organisation is neither passing nor failing, and reporting it as failed would
 * be a claim about the organisation rather than about the check.
 */
export type CheckResult = {
  code: string;
  title?: string;
  check: string;
  scope: "platform" | "tenant";
  blurb?: string;
  ok: boolean | null;
  summary: string | null;
  detail: string | null;
  findings: Record<string, unknown>[];
};

export type JobHandler = {
  code: string;
  description: string;
  runs_in_database: boolean;
  default_timeout_seconds: number;
};

export type DrainResult = {
  claimed: number;
  succeeded: number;
  failed: number;
  needs_worker: number;
  organisations: {
    organisation: string;
    runs: { job: string; outcome: string; error?: string }[];
  }[];
};

export type MyTenancy = {
  tenant_id: string;
  code: string;
  name: string;
  status: string;
  principal_status: string;
  is_active: boolean;
  /**
   * Holds a grant support access did not give: the organisation's own member,
   * not a visitor. Entering is a switch for a member, and Leave ends nothing.
   */
  is_member?: boolean;
  holds_administrator: boolean;
  is_current: boolean;
};

export type TenantConfiguration = {
  tenant_id: string;
  code: string;
  name: string;
  status: string;
  is_live: boolean;
  has_self_environment: boolean;
  entities: number;
  sites: number;
  principals: number;
  ledgers: number;
  accounts: number;
  document_types: number;
  posting_rules: number;
  jobs: number;
  modules_installed: string[];
  change_sets_awaiting: number;
  determination_findings: number;
};

/** One deploy of main to live, as erp_meta.release records it. */
export type Release = {
  id: string;
  recorded_at: string;
  deployed_at_start: string;
  git_sha: string;
  app_build: string | null;
  migrations_recorded: number;
  migrations_high: string | null;
  proved: boolean;
  recorded_by: string;
  ledger_now: string | null;
  moved_since: boolean;
  note: string | null;
};

export type DeploymentState = {
  migrations_known: boolean;
  migrations: { version: string; name: string | null }[];
  counts: Record<string, number>;
  registers: Record<string, number>;
  /** The last five releases; empty on a database nothing has deployed to. */
  releases?: Release[];
  generated_at: string;
};
