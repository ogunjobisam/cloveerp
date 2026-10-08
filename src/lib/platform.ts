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
  last_event: { phase: string; status: string; detail: string | null; at: string } | null;
};

/**
 * How long a build request may sit with nothing happening before the owner is
 * offered Start again. The sweep claims a request within ten minutes and the
 * build records its first step within a minute or two of starting, so twenty
 * minutes of silence means the request, or the run it started, is lost.
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
  return buildRequestIsStale(d, now) ? "start-again" : null;
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

/** A client deployment's address, as a person reads it: acme.cloveerp.com. */
export function deploymentAddress(d: Pick<ClientDeployment, "code" | "origin">): string {
  return hostOfOrigin(d.origin) ?? `${d.code}.${APEX_HOST}`;
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
