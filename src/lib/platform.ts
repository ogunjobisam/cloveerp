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
 *
 * Since 20261012050000 the build makes the client's Resend webhook itself when it holds the
 * key to, proves it, and ticks the step (erp_meta.deployment_checklist_by_build); the row then
 * says the build set it (checklistStep). Without the key the step is left for a person, as
 * before.
 */
export const CHECKLIST_ITEMS = [
  { key: "google_sign_in", label: "Google sign-in (if wanted)" },
  { key: "resend_webhook", label: "Resend webhook" },
] as const;

export type ChecklistItem = (typeof CHECKLIST_ITEMS)[number]["key"];

/** What the Fleet view says beside a step the build did itself. */
export const SET_BY_THE_BUILD = "set by the build";

/** One step of a client's checklist, as the Fleet view shows it. */
export type ChecklistStep = {
  done: boolean;
  /** Ticked by the build rather than by a person. */
  byBuild: boolean;
  /** What the row says beside the step: that the build set it, or nothing. */
  note: string | null;
};

/**
 * Whether a step's "by" names the build rather than a person. A person's
 * tick is signed with their address; the build signs with words that say
 * "build" ("the build", "the build, run 123", build_from_empty). An address
 * is a person's whatever it says ("build@…" among them), so the words are
 * read with every address taken out; and "rebuild" is not the build.
 */
export function namesTheBuild(by: unknown): boolean {
  const t = textOf(by);
  if (t === null) return false;
  return t
    .replace(/\S*@\S*/g, " ")
    .toLowerCase()
    .split(/[^a-z]+/)
    .includes("build");
}

/**
 * One step of the register's checklist, read without trusting its shape
 * (erp_platform_deployments returns what was written: { done, at, by }).
 * Done only when it says so, as true or "true". Set by the build when its
 * "by" names the build, or it says so outright (by_build: true). Anything
 * missing or of another shape is a step not done, by nobody.
 */
export function checklistStep(checklist: unknown, key: ChecklistItem): ChecklistStep {
  const entry = objectOf(objectOf(checklist)?.[key]);
  if (entry === null) return { done: false, byBuild: false, note: null };
  const done = entry["done"] === true || entry["done"] === "true";
  const byBuild = namesTheBuild(entry["by"]) || entry["by_build"] === true;
  return { done, byBuild, note: done && byBuild ? SET_BY_THE_BUILD : null };
}

/**
 * What retiring a client leaves a person to do about its Resend webhook:
 * retiring deletes nothing, and the endpoint would go on being sent every
 * event of the account. Said for every client being offboarded or retired,
 * whatever its checklist says, because the step does not say whether an
 * endpoint exists: one can be made and then fail its proof, or be proved and
 * never ticked, or be unticked by a person. Deleting one that does not exist
 * changes nothing, so it says "if it has one". Null for a client in any other
 * state, which resend_webhook_delete refuses. The fleet secrets workflow's
 * resend_webhook_delete deletes the endpoint and its stored secret
 * (20261012050000).
 */
export function retiredWebhookText(d: Pick<ClientDeployment, "code" | "status">): string | null {
  if (d.status !== "retiring" && d.status !== "retired") return null;
  return `Delete its Resend webhook if it has one: run the fleet secrets workflow with the action resend_webhook_delete for ${d.code}.`;
}

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
   * The address it is served at, <address>.cloveerp.com (20261012030000):
   * its code until it is renamed. The code never changes; a rename gives a
   * new address. Absent from a register older than renaming, where the
   * address is the code.
   */
  address?: string;
  /**
   * The newest address it was renamed from that still sends people on, and
   * until when. Every address a deployment leaves stays held for it for good,
   * never given to another; only the sending on ends. So does every address
   * it was ever asked to be renamed to, whatever became of the asking.
   */
  previous_address?: string | null;
  previous_address_until?: string | null;
  /** While it is being offboarded: the day its project is due to be purged. */
  purge_due_at?: string | null;
  /** When its offboarding began; null when it is not being offboarded. */
  offboarding_at?: string | null;
  /**
   * Why its service is suspended, while it is: set when it is suspended, and
   * when it is suspended while being offboarded (serviceSuspended).
   */
  suspended_reason?: string | null;
  /**
   * When its service was suspended, while it is: set and cleared with the
   * reason, and kept when its offboarding begins or is cancelled. Once it is
   * being offboarded, only a copy of its data taken at or after this, and
   * after its offboarding began, lets it be retired
   * (exportedSinceServiceStopped).
   */
  suspended_at?: string | null;
  /**
   * The last export of its database off the platform: when it was recorded,
   * once written, and the object it was written to.
   */
  last_export_at?: string | null;
  last_export_object?: string | null;
  /**
   * When the last export's copy was taken (20261012030000): the moment its
   * dump began, by the control plane's clock. A copy holds the data as it
   * stood then, not when it was recorded, so this is the time that says
   * whether it is a copy of the data after its service stopped.
   */
  last_export_taken_at?: string | null;
  /**
   * Whether the last export's copy was taken after the client's own
   * organisation was confirmed stopped. An export of a client whose service
   * is suspended first suspends its organisation on its own project, and
   * takes the copy after; when that cannot be confirmed, the copy is still
   * taken, and this is false. Only a copy taken with it true can be the last
   * one (exportedSinceServiceStopped). Absent from a register older than it.
   */
  last_export_service_stopped?: boolean;
  /**
   * Its contract as the control plane holds it for it, and how far its own
   * database has caught up (20261012040000): read only through
   * readDeploymentCommercial, which takes nothing on trust. Absent from a
   * register older than it.
   */
  commercial?: DeploymentCommercial | null;
};

/**
 * What the register says of a client's contract (erp_platform_deployments'
 * commercial, 20261012040000). Every key may be missing or of another shape;
 * readDeploymentCommercial reads it.
 */
export type DeploymentCommercial = {
  /** The contract, from the newest position sent to it. */
  contract_ref?: string | null;
  /** active, terminating, expired or terminated, from the same position. */
  contract_status?: string | null;
  /** The plan that position holds it to. */
  plan_code?: string | null;
  /** applied, pending (sent, not yet applied by its database), or none sent. */
  position?: string | null;
  position_applied_at?: string | null;
  position_pending_since?: string | null;
  /** What its database last answered about the position, in plain words. */
  position_detail?: string | null;
  /** Notices of its contract's events not yet recorded on its database, and those it refused. */
  notices_pending?: number | string | null;
  notices_failed?: number | string | null;
  /**
   * The latest month the fleet poll read for each meter. A meter it never
   * measured is said to be not measured, never 0.
   */
  usage?: unknown;
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

/**
 * What the rename dialog says of a rename before it is asked for
 * (erp_platform_rename_deployment, 20261012030000). Every address a client
 * leaves stays its own for good, and so does every address it is asked to
 * move to, from the moment it is asked, whatever becomes of the rename: so a
 * rename that stops part-way is finished by asking for it again, and nobody
 * else can take the address meanwhile.
 */
export function renameDescription(
  d: Pick<ClientDeployment, "code" | "origin"> & { address?: string | null | undefined },
): string {
  return `Its people sign in at the new address once the rename has run, which starts ${SWEEP_STARTS}. Its old address, ${deploymentAddress(d)}, sends them on for ninety days and stays its own afterwards: it is never given to another client. The new address is its own from the moment it is asked for, even if the rename stops, so asking for it again finishes the move. Its code, ${d.code}, stays the same.`;
}

/**
 * What the rename dialog says under the new address as it is typed: the
 * shape it must have, that it is the address already, or who may have it.
 */
export function renameAddressHint(typed: string, current: string): string {
  if (typed !== "" && !isDeploymentAddress(typed)) {
    return "Three to sixty-three lower-case letters, digits or hyphens, not starting or ending with a hyphen.";
  }
  if (typed === current) return "That is its address now.";
  return "Held once across the fleet, like a code: refused if any other client has it, ever had it or was ever asked to move to it. Its own code, any address it had before and any address it was asked to move to can be given to it.";
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
 * Whether a client's service is suspended (20261012030000): its suspension
 * is its reason, so it is suspended, or being offboarded while suspended.
 * Its address then shows only that its service is suspended, and its
 * organisation is suspended on its own project too.
 */
export function serviceSuspended(
  d: Pick<ClientDeployment, "status" | "suspended_reason">,
): boolean {
  if (d.status === "suspended") return true;
  return d.status === "retiring" && typeof d.suspended_reason === "string";
}

/**
 * Whether the day a deployment being offboarded may be purged has come. A
 * day that cannot be read has not come.
 */
export function purgeDateHasCome(d: Pick<ClientDeployment, "purge_due_at">, now: Date): boolean {
  if (typeof d.purge_due_at !== "string") return false;
  const due = Date.parse(d.purge_due_at);
  return !Number.isNaN(due) && due <= now.getTime();
}

/** A time as milliseconds; null when there is none, or it cannot be read. */
function timeOf(iso: string | null | undefined): number | null {
  if (typeof iso !== "string") return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : t;
}

/**
 * Whether a deployment being offboarded has nothing left to export: it never
 * had a database (never built), or the last copy of its database is one it
 * can leave with (erp_platform_retire_deployment, 20261012030000). That copy
 * was taken after its own organisation was confirmed stopped, and taken — its
 * dump begun, not merely recorded — at or after both the moment its
 * offboarding began and the moment its service was suspended. So the copy it
 * leaves with is its data as it stood once nobody could change it any more:
 * a dump begun while its people could still write, and recorded after the
 * suspension, is not. An export asked for after suspending it is taken that
 * way. A time that cannot be read, or is not there, is no copy: without all
 * three, no copy can be shown to be since. Whether its service is suspended
 * now is serviceSuspended's to say.
 */
export function exportedSinceServiceStopped(
  d: Pick<
    ClientDeployment,
    | "built_at"
    | "offboarding_at"
    | "suspended_at"
    | "last_export_taken_at"
    | "last_export_service_stopped"
  >,
): boolean {
  if (d.built_at === null) return true;
  if (d.last_export_service_stopped !== true) return false;
  const taken = timeOf(d.last_export_taken_at);
  const began = timeOf(d.offboarding_at);
  const stopped = timeOf(d.suspended_at);
  if (taken === null || began === null || stopped === null) return false;
  return taken >= Math.max(began, stopped);
}

/** What is left before a client being offboarded is retired, in the order it is done. */
export type OffboardingStep = "suspend" | "export" | "retire";

/**
 * What is left to do, once its purge date has come, before a client being
 * offboarded that ever had a database is retired (20261012030000), naming
 * only the steps not yet done, in order:
 *
 *   suspend  its service, so its address stops being served and its own
 *            organisation can be stopped;
 *   export   its database, after that: a copy taken once its own
 *            organisation was stopped is the last one, the data as it stood
 *            when nobody could change it any more. An export asked for after
 *            suspending it stops that organisation first, if the status sync
 *            has not yet, and takes the copy after;
 *   retire   it.
 *
 * Nothing before its purge date, and nothing for one never built: it has no
 * data to keep, and is retired on its purge date as it is.
 */
export function offboardingStepsLeft(
  d: Pick<
    ClientDeployment,
    | "status"
    | "built_at"
    | "purge_due_at"
    | "suspended_reason"
    | "suspended_at"
    | "offboarding_at"
    | "last_export_taken_at"
    | "last_export_service_stopped"
  >,
  now: Date,
): OffboardingStep[] {
  if (d.status !== "retiring" || d.built_at === null || !purgeDateHasCome(d, now)) return [];
  const suspended = serviceSuspended(d);
  const steps: OffboardingStep[] = [];
  if (!suspended) steps.push("suspend");
  // A copy taken before its own organisation was stopped is never the last one.
  if (!suspended || !exportedSinceServiceStopped(d)) steps.push("export");
  steps.push("retire");
  return steps;
}

/**
 * When a copy of a client being offboarded is the one it leaves with
 * (exportedSinceServiceStopped), as the console says it: the steps left, the
 * export owed, and the Suspend, Export and Retire dialogs.
 */
export const LAST_COPY_RULE =
  "Only a copy taken after its own organisation was stopped counts as the last one";

const STEP_TEXT: Record<OffboardingStep, string> = {
  suspend: "suspend it",
  export: "export it",
  retire: "retire it",
};

/**
 * The steps left, as the row says them: "Left to do, in order: export it,
 * then retire it.", and when exporting it is among them, which copy counts.
 */
function stepsLeftText(steps: readonly OffboardingStep[]): string | null {
  const said = steps.map((s) => STEP_TEXT[s]);
  const last = said.pop();
  if (last === undefined) return null;
  const left =
    said.length === 0
      ? `Left to do: ${last}.`
      : `Left to do, in order: ${said.join(", ")}, then ${last}.`;
  if (!steps.includes("export")) return left;
  return `${left} ${LAST_COPY_RULE}: an export asked for after suspending it makes sure of that first.`;
}

/**
 * What a row says, beside its last export, while a client being offboarded
 * is suspended and its last copy is not the one it leaves with
 * (exportedSinceServiceStopped), before its purge date (once the date has
 * come its lifecycle note names every step left, this among them). Null
 * otherwise: a client still served is not owed an export yet, because its
 * people can still change its data.
 *
 * It says why the last copy does not count, where the row can tell, and that
 * an export asked for now is one that does: its service is suspended, so the
 * export stops its own organisation first.
 */
export function exportOwedText(
  d: Pick<
    ClientDeployment,
    | "status"
    | "built_at"
    | "purge_due_at"
    | "suspended_reason"
    | "suspended_at"
    | "offboarding_at"
    | "last_export_at"
    | "last_export_taken_at"
    | "last_export_service_stopped"
  >,
  now: Date,
): string | null {
  if (d.status !== "retiring" || d.built_at === null || purgeDateHasCome(d, now)) return null;
  if (!serviceSuspended(d) || exportedSinceServiceStopped(d)) return null;
  const taken = timeOf(d.last_export_taken_at);
  const stopped = timeOf(d.suspended_at);
  const began = timeOf(d.offboarding_at);
  // Taken once its organisation was stopped, but before its offboarding began.
  const beforeOffboarding =
    d.last_export_service_stopped === true &&
    taken !== null &&
    stopped !== null &&
    began !== null &&
    taken >= stopped &&
    taken < began;
  const first =
    timeOf(d.last_export_at) === null && taken === null
      ? "Not exported yet."
      : beforeOffboarding
        ? "Its last copy was taken before its offboarding began, so it does not count."
        : "Its last copy does not count.";
  return `${first} ${LAST_COPY_RULE} and lets it be retired: an export asked for now makes sure of that first.`;
}

/**
 * What the Export dialog says (erp_platform_request_export, 20261012030000):
 * where the copy goes and when it starts, and, while its service is
 * suspended, that the export stops its own organisation before it takes the
 * copy. For a client being offboarded, whether this copy can be the last one:
 * only one taken after its own organisation was stopped is, so one still
 * served has to be suspended first. One already waiting is reused; so is one
 * being written, unless it started before the suspension, when a new one is
 * queued beside it and only the new one can be the last.
 */
export function exportDescription(
  d: Pick<ClientDeployment, "code" | "status" | "suspended_reason">,
): string {
  const suspended = serviceSuspended(d);
  const where = `A copy of its database and of the documents it has produced, encrypted to the backup key and written to the off-platform bucket under exports/${d.code}/. It starts ${SWEEP_STARTS}, and its row says when it is made or why it was not.`;
  const again = suspended
    ? " While one is waiting, or being written since its service was suspended, asking again queues nothing more; one that started before the suspension does not stop a new one."
    : " While one is waiting or being written, asking again queues nothing more.";
  const stopped = !suspended
    ? d.status === "retiring"
      ? ` Its people can still change its data, so this is not the copy it is retired with. ${LAST_COPY_RULE}: suspend it first, and an export asked for after that makes sure of it.`
      : ""
    : d.status === "retiring"
      ? ` Its service is suspended, so the export first makes sure its own organisation is stopped, then takes the copy. ${LAST_COPY_RULE}, and lets it be retired; if the organisation cannot be shown to be stopped, the copy is still taken, but it does not count.`
      : " Its service is suspended, so the export first makes sure its own organisation is stopped, then takes the copy.";
  return `${where}${again}${stopped}`;
}

/**
 * The states a release goes to (deploy.yml's targets and
 * erp_platform_request_release, 20261012030000): the project is up. A
 * suspended client's project keeps running, and one being offboarded is
 * released to while it has a database.
 */
const RELEASED: ReadonlySet<ClientDeploymentStatus> = new Set([
  "built",
  "live",
  "suspended",
  "retiring",
]);

/**
 * Whether a client takes releases: built, live or suspended, or being
 * offboarded once it was built. One being offboarded whose build never
 * finished has no database to release to; the release door refuses its code
 * and deploy.yml leaves it out.
 */
export function takesReleases(d: Pick<ClientDeployment, "status" | "built_at">): boolean {
  if (!RELEASED.has(d.status)) return false;
  return d.status !== "retiring" || d.built_at !== null;
}

/**
 * What a row in the Fleet view offers, in the order it offers them
 * (20261012030000).
 *
 *   open-console  its own console: built, live, or being offboarded once
 *                 built and not suspended, the states whose address is
 *                 served. Not when its service is suspended: its address
 *                 shows only that. Not one being offboarded whose build never
 *                 finished: its address answers nothing.
 *   onboard       its first organisation, on its own console: built or live.
 *   retry, start-again
 *                 getting a build going again (buildRecovery); the owner's.
 *   suspend       stop serving it: built, live, or being offboarded once
 *                 built and not suspended; the owner's. One never built has
 *                 no service to stop.
 *   reinstate     serve it again: suspended, or being offboarded while
 *                 suspended; the owner's.
 *   rename        a new address: built, live or suspended; the owner's.
 *   export        an encrypted copy of its database off the platform: one
 *                 that has a database (built_at) and is built, live,
 *                 suspended or being offboarded; an operator's and up.
 *   offboard      begin offboarding: requested, failed, built, live or
 *                 suspended; not while a build runs; the owner's. A
 *                 requested one whose build the sweep has already started is
 *                 refused by the door for a while, which the row cannot
 *                 always tell, so it is offered on every requested row.
 *   cancel-offboarding
 *                 stop offboarding it: being offboarded; the owner's.
 *   retire        the last step, before its project is deleted: requested,
 *                 failed, built, live or suspended; and one being offboarded
 *                 only once its purge date has come and, if it ever had a
 *                 database, its service is suspended and its last copy was
 *                 taken after its own organisation was stopped and its
 *                 offboarding began (exportedSinceServiceStopped;
 *                 offboardingStepsLeft says what is left). The owner's.
 *
 * The doors decide regardless (each requires its rank and refuses a state it
 * does not take, and retiring refuses while a contract in force names the
 * deployment, which a row does not say); this is so the console offers only
 * what would open.
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
  | "cancel-offboarding"
  | "retire";

/** The parts of a register row that decide what it offers. */
export type FleetRowView = BuildRequestView &
  Pick<
    ClientDeployment,
    | "built_at"
    | "suspended_reason"
    | "suspended_at"
    | "purge_due_at"
    | "offboarding_at"
    | "last_export_taken_at"
    | "last_export_service_stopped"
  >;

/** The states a deployment can be offboarded from: any but a build under way, retiring and retired. */
const OFFBOARDABLE: ReadonlySet<ClientDeploymentStatus> = new Set([
  "requested",
  "failed",
  "built",
  "live",
  "suspended",
]);

/** The states that hold a database a copy can be made of, once it was built. */
const EXPORTABLE: ReadonlySet<ClientDeploymentStatus> = new Set([
  "built",
  "live",
  "suspended",
  "retiring",
]);

export function fleetActions(
  d: FleetRowView,
  role: PlatformRole | null | undefined,
  now: Date,
): FleetAction[] {
  const owner = atLeast(role, "owner");
  const operator = atLeast(role, "operator");
  const s = d.status;
  const up = s === "built" || s === "live";
  const suspended = serviceSuspended(d);
  const offboarding = s === "retiring";
  const built = d.built_at !== null;
  // Being offboarded, its address is served only if it was ever built and
  // its service is not suspended (erp_deployment_for_host).
  const served = up || (offboarding && built && !suspended);
  const actions: FleetAction[] = [];
  if (served) actions.push("open-console");
  if (up) actions.push("onboard");
  if (owner) {
    const recovery = buildRecovery(d, now);
    if (recovery !== null) actions.push(recovery);
    if (served) actions.push("suspend");
    if (suspended) actions.push("reinstate");
    if (up || s === "suspended") actions.push("rename");
  }
  if (operator && built && EXPORTABLE.has(s)) actions.push("export");
  if (owner) {
    if (OFFBOARDABLE.has(s)) actions.push("offboard");
    if (offboarding) actions.push("cancel-offboarding");
    // Retired directly from any state it could be offboarded from (a contract
    // in force refuses it at the door). Once offboarding, only at the end:
    // its purge date come and, if it ever had a database, its service
    // stopped and its data copied once its own organisation was stopped.
    if (
      OFFBOARDABLE.has(s) ||
      (offboarding &&
        purgeDateHasCome(d, now) &&
        (!built || (suspended && exportedSinceServiceStopped(d))))
    ) {
      actions.push("retire");
    }
  }
  return actions;
}

/**
 * What the Fleet view says of where a deployment stands in its lifecycle,
 * under its state: why it is suspended, when its project is due to be
 * purged, once that day has come what is left before it is retired
 * (offboardingStepsLeft), and the address it moved from while that still
 * sends people on. A deployment suspended while it is being offboarded says
 * both.
 */
export type LifecycleNote = { key: string; text: string; tone: HealthTone };

export function deploymentLifecycleNotes(
  d: Pick<
    ClientDeployment,
    | "code"
    | "origin"
    | "status"
    | "built_at"
    | "previous_address"
    | "previous_address_until"
    | "purge_due_at"
    | "offboarding_at"
    | "suspended_reason"
    | "suspended_at"
    | "last_export_taken_at"
    | "last_export_service_stopped"
  >,
  now: Date,
): LifecycleNote[] {
  const notes: LifecycleNote[] = [];
  if (serviceSuspended(d)) {
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
          : purgeDateHasCome(d, now)
            ? `Being offboarded: its purge date, ${due}, has come.`
            : `Being offboarded: its project is due to be purged on ${due}.`,
      tone: "warn",
    });
    const left = stepsLeftText(offboardingStepsLeft(d, now));
    if (left !== null) notes.push({ key: "steps", text: left, tone: "warn" });
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
    // The newest old address still sending people on. Every address it left
    // stays its own for good, so none is ever another client's.
    notes.push({
      key: "moved",
      text: `Was ${d.previous_address}.${apexOfOrigin(d.origin) ?? APEX_HOST}, which sends people here until ${until} and is never given to another client.`,
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

/* -------------------------------------------------------------------------- */
/* A client's contract, as the Fleet view reads it (20261012040000).          */
/* -------------------------------------------------------------------------- */

/** Where a client's own database stands with the newest contract position sent to it. */
export type CommercialPosition = "applied" | "pending" | "none";

/** One meter's latest month on a client's database. A null quantity was never measured. */
export type UsageReading = {
  meter_code: string;
  /** The meter's own title, when the register gives one. */
  title: string | null;
  quantity: number | null;
  period_start: string | null;
  period_end: string | null;
};

/** The register's commercial key, read: anything unreadable is null. */
export type CommercialView = {
  contract_ref: string | null;
  contract_status: string | null;
  plan_code: string | null;
  position: CommercialPosition | null;
  position_applied_at: string | null;
  position_pending_since: string | null;
  position_detail: string | null;
  notices_pending: number | null;
  notices_failed: number | null;
  /**
   * The latest month per meter. Null when the register said nothing of
   * usage; empty when it said nothing was measured.
   */
  usage: UsageReading[] | null;
};

/** Text with something in it, trimmed; anything else is nothing. */
function textOf(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t === "" ? null : t;
}

/** A time that can be read, as it was written; anything else is nothing. */
function timeTextOf(v: unknown): string | null {
  const t = textOf(v);
  return t !== null && !Number.isNaN(Date.parse(t)) ? t : null;
}

/**
 * A quantity a meter measured: a number not below zero, or one written as
 * text. Anything else, "not measured" among it, was not measured.
 */
function quantityOf(v: unknown): number | null {
  if (typeof v === "number") return Number.isFinite(v) && v >= 0 ? v : null;
  if (typeof v === "string" && /^\d+(\.\d+)?$/.test(v.trim())) return Number(v.trim());
  return null;
}

function objectOf(v: unknown): Record<string, unknown> | null {
  return v !== null && typeof v === "object" && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : null;
}

/** One meter's reading, from a row of the register's usage, or a value under a meter's code. */
function readingOf(code: string | null, v: unknown): UsageReading | null {
  const o = objectOf(v);
  if (o === null) {
    return code === null
      ? null
      : {
          meter_code: code,
          title: null,
          quantity: quantityOf(v),
          period_start: null,
          period_end: null,
        };
  }
  const meter = textOf(o["meter_code"]) ?? textOf(o["meter"]) ?? textOf(o["code"]) ?? code;
  if (meter === null) return null;
  return {
    meter_code: meter,
    title: textOf(o["title"]),
    quantity: quantityOf(o["quantity"] ?? o["value"]),
    period_start: timeTextOf(o["period_start"]),
    period_end: timeTextOf(o["period_end"]),
  };
}

/** Whether reading a is a later month than b: measured beats not measured, then the later period. */
function laterReading(a: UsageReading, b: UsageReading): boolean {
  if ((a.quantity === null) !== (b.quantity === null)) return a.quantity !== null;
  const at = a.period_start === null ? -Infinity : Date.parse(a.period_start);
  const bt = b.period_start === null ? -Infinity : Date.parse(b.period_start);
  return at > bt;
}

/**
 * The register's usage, in whichever shape it comes: a list of rows, an
 * object keyed by meter (each a row, a number, or "not measured"), or one
 * word for all of it. Null when it says nothing (absent); empty when it says
 * nothing was measured. One reading per meter, the latest month it measured.
 */
function readUsage(v: unknown): UsageReading[] | null {
  if (v === undefined) return null;
  const readings: UsageReading[] = [];
  if (Array.isArray(v)) {
    for (const item of v as unknown[]) {
      const r = readingOf(null, item);
      if (r !== null) readings.push(r);
    }
  } else {
    const o = objectOf(v);
    if (o !== null) {
      for (const [code, value] of Object.entries(o)) {
        const r = readingOf(textOf(code), value);
        if (r !== null) readings.push(r);
      }
    }
  }
  const latest = new Map<string, UsageReading>();
  for (const r of readings) {
    const held = latest.get(r.meter_code);
    if (held === undefined || laterReading(r, held)) latest.set(r.meter_code, r);
  }
  return [...latest.values()];
}

const POSITIONS: ReadonlySet<string> = new Set(["applied", "pending", "none"]);

/**
 * The register's commercial key, read without trusting its shape
 * (erp_platform_deployments, 20261012040000). Null when there is none: a
 * register older than it, or something that is not an object.
 */
export function readDeploymentCommercial(raw: unknown): CommercialView | null {
  const o = objectOf(raw);
  if (o === null) return null;
  const position = textOf(o["position"]);
  return {
    contract_ref: textOf(o["contract_ref"]),
    contract_status: textOf(o["contract_status"]),
    plan_code: textOf(o["plan_code"]),
    position:
      position !== null && POSITIONS.has(position) ? (position as CommercialPosition) : null,
    position_applied_at: timeTextOf(o["position_applied_at"]),
    position_pending_since: timeTextOf(o["position_pending_since"]),
    position_detail: textOf(o["position_detail"]),
    notices_pending: countOf(o["notices_pending"]),
    notices_failed: countOf(o["notices_failed"]),
    usage: readUsage(o["usage"]),
  };
}

/**
 * The meters a client's usage is measured by (erp_meta.meter_kind), in the
 * order the Fleet view says them, with how each reads: one, many, and its
 * name when it was not measured.
 */
const METERS: readonly { code: string; one: string; many: string; name: string }[] = [
  {
    code: "documents_posted",
    one: "document posted",
    many: "documents posted",
    name: "documents posted",
  },
  {
    code: "movements_recorded",
    one: "stock movement recorded",
    many: "stock movements recorded",
    name: "stock movements",
  },
  { code: "messages_sent", one: "message sent", many: "messages sent", name: "messages sent" },
  // Never measured by anything yet: no job runs its measurement, so it reads
  // "not measured", never 0.
  { code: "active_users", one: "active user", many: "active users", name: "active users" },
];

/** A quantity as a person reads it: 1,234, or 12.5. */
function quantityText(n: number): string {
  if (Number.isInteger(n)) return grouped(n);
  const [whole, fraction] = n.toFixed(2).replace(/0+$/, "").split(".");
  return fraction ? `${grouped(Number(whole))}.${fraction}` : grouped(Number(whole));
}

/** The month a period starts in, as a person reads it: September 2026, in UTC. */
function monthText(iso: string | null): string | null {
  if (iso === null) return null;
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return null;
  const d = new Date(t);
  return `${MONTHS[d.getUTCMonth()] ?? ""} ${d.getUTCFullYear()}`;
}

/**
 * A client's latest usage, as the Fleet view says it: "September 2026:
 * 1,234 documents posted, 56 stock movements recorded, 12 messages sent,
 * active users not measured". Each registered meter is named, in order,
 * then any other the register gives; a meter never measured is said to be
 * not measured, never 0. The month is said once when every measured meter
 * shares it, and after each otherwise. Null when the register said nothing
 * of usage; "not measured yet" when nothing was.
 */
export function deploymentUsageText(usage: readonly UsageReading[] | null): string | null {
  if (usage === null) return null;
  const measured = usage.filter((r) => r.quantity !== null);
  if (measured.length === 0) return "not measured yet";
  const months = new Set(measured.map((r) => monthText(r.period_start)));
  const oneMonth = months.size === 1 ? ([...months][0] ?? null) : null;
  const byCode = new Map(usage.map((r) => [r.meter_code, r]));
  const known = new Set(METERS.map((m) => m.code));
  // Its month, after it, when the measured meters do not share one.
  const dated = (text: string, r: UsageReading) => {
    const month = monthText(r.period_start);
    return oneMonth === null && month !== null ? `${text} (${month})` : text;
  };
  const parts = METERS.map((m) => {
    const r = byCode.get(m.code);
    if (r === undefined || r.quantity === null) return `${m.name} not measured`;
    return dated(`${quantityText(r.quantity)} ${r.quantity === 1 ? m.one : m.many}`, r);
  });
  // A meter registered after this was written: its title, or its code, then the count.
  const others = usage
    .filter((r) => !known.has(r.meter_code))
    .sort((a, b) => a.meter_code.localeCompare(b.meter_code));
  for (const r of others) {
    const name = (r.title ?? r.meter_code.replace(/_/g, " ")).toLowerCase();
    parts.push(
      r.quantity === null
        ? `${name} not measured`
        : dated(`${name}: ${quantityText(r.quantity)}`, r),
    );
  }
  const list = parts.join(", ");
  return oneMonth === null ? list : `${oneMonth}: ${list}`;
}

/** How long a position may wait to be applied on a client that is up before the Fleet says so. */
export const POSITION_PENDING_NOTE_HOURS = 24;

/**
 * Whether the newest position sent to a client has waited more than a day
 * to be applied. The fleet sync sends it on every run, hourly, to every
 * client whose project is up, so a day of waiting means its database keeps
 * answering that it cannot take it yet. A time that cannot be read has not
 * waited.
 */
export function positionPendingTooLong(
  c: Pick<CommercialView, "position" | "position_pending_since">,
  now: Date,
  builtAt?: string | null,
): boolean {
  if (c.position !== "pending") return false;
  const queued = timeOf(c.position_pending_since);
  if (queued === null) return false;
  // A position queued before its deployment was built is not sent until the
  // build is done: it has waited only since then.
  const built = timeOf(builtAt ?? null);
  const since = built !== null && built > queued ? built : queued;
  return now.getTime() - since > POSITION_PENDING_NOTE_HOURS * 3_600_000;
}

/**
 * What the Fleet view says of a client's contract, under its health: a note
 * first when its position has waited over a day to be applied, then a phrase
 * for the plan in force and the contract's state, the position's state and
 * the notices waiting, then its latest usage, and last a note when any
 * notice of its contract failed.
 */
export type CommercialLine = {
  waiting: string | null;
  parts: HealthPart[];
  usage: string | null;
  failed: string | null;
};

const CONTRACT_TONE: Record<string, HealthTone> = {
  active: "ok",
  terminating: "warn",
  expired: "warn",
  terminated: "muted",
};

/**
 * What the Fleet view says of a deployment's contract (erp_platform_
 * deployments' commercial, 20261012040000), or null when there is nothing
 * to say: a register older than it, or a retired deployment, which is owed
 * nothing more.
 *
 * The position is sent to a client only while its project is up (built,
 * live, suspended or being offboarded). Before that it waits for the build,
 * which sends it as it finishes, so its waiting is only noted, and usage is
 * read, once it is up. A note is also made when any notice of its contract
 * was refused by its database: those are not sent again.
 */
export function deploymentCommercialLine(
  d: Pick<ClientDeployment, "status" | "commercial"> & { built_at?: string | null | undefined },
  now: Date,
): CommercialLine | null {
  if (d.status === "retired") return null;
  const c = readDeploymentCommercial(d.commercial);
  if (c === null) return null;
  // The deployments the fleet's sync sends a position to and the poll reads:
  // up, and when being offboarded, only one that was built.
  const neverBuilt = typeof d.built_at !== "string";
  const up = POLLED.has(d.status) && !(d.status === "retiring" && neverBuilt);
  const parts: HealthPart[] = [];

  if (c.plan_code !== null) {
    parts.push({
      key: "plan",
      text:
        c.contract_status === null
          ? `on the ${c.plan_code} plan`
          : `on the ${c.plan_code} plan, contract ${c.contract_status}`,
      tone: c.contract_status === null ? "muted" : (CONTRACT_TONE[c.contract_status] ?? "muted"),
    });
  }

  const tooLong = up && positionPendingTooLong(c, now, d.built_at ?? null);
  if (c.position === "applied") {
    const applied = agoText(c.position_applied_at, now);
    parts.push({
      key: "position",
      text: applied === null ? "position applied" : `position applied ${applied}`,
      tone: "muted",
    });
  } else if (c.position === "pending" && !tooLong) {
    const queued = agoText(c.position_pending_since, now);
    parts.push({
      key: "position",
      text: !up
        ? d.status === "retiring"
          ? "position not sent: it was never built"
          : "position waits for its build"
        : queued === null
          ? "position not applied yet"
          : `position queued ${queued}, not applied yet`,
      tone: "muted",
    });
  } else if (c.position === "none" && c.plan_code === null) {
    parts.push({ key: "position", text: "no contract sent to it", tone: "muted" });
  }

  const pending = c.notices_pending;
  if (pending !== null && pending > 0) {
    parts.push({
      key: "notices",
      text: `${pending} ${pending === 1 ? "notice" : "notices"} waiting`,
      tone: "muted",
    });
  }

  const waiting = !tooLong
    ? null
    : `Its contract's position has waited over a day to be applied, though the fleet sync sends it every hour: it was queued ${
        agoText(c.position_pending_since, now) ?? "over a day ago"
      }.${c.position_detail === null ? "" : ` Its database last answered: ${c.position_detail}`}`;

  const failedCount = c.notices_failed;
  const failed =
    failedCount === null || failedCount === 0
      ? null
      : `${failedCount === 1 ? "A notice" : `${failedCount} notices`} of its contract could not be recorded on its database, and ${
          failedCount === 1 ? "is" : "are"
        } not sent again.`;

  const usage = up ? deploymentUsageText(c.usage) : null;

  if (waiting === null && parts.length === 0 && usage === null && failed === null) return null;
  return { waiting, parts, usage, failed };
}

/**
 * How many client deployments hold a contract in force on a plan, as the
 * plans view says it (erp_platform_plans' deployments, 20261012040000):
 * "1 client deployment", "3 client deployments". Null when there are none,
 * or the register is older than the count.
 */
export function planDeploymentsText(p: { deployments?: unknown }): string | null {
  const n = countOf(p.deployments);
  if (n === null || n === 0) return null;
  return `${n} client ${n === 1 ? "deployment" : "deployments"}`;
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

/**
 * How a choice reads in a picker; a client deployment says it is one. Not
 * where it is served: a rename moves its address while its code stays, and
 * the picker has only the code.
 */
export function customerChoiceText(c: {
  code: string;
  name: string;
  where?: "organisation" | "deployment" | undefined;
}): string {
  return c.where === "deployment"
    ? `${c.name} (${c.code}), a client deployment`
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
