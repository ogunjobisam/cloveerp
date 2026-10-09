import { whenText } from "./when";

/**
 * Who an incident or a maintenance window reaches, as the doors say it
 * (20261012060000: incidents and maintenance reach every client).
 *
 * The control plane declares; a client's own project is sent a copy of each
 * incident and window that reaches it, and holds it as received. So the
 * console reads three new things off the rows it already has:
 *
 *   - every_client: the explicit choice that reaches every client deployment,
 *     separate from affects_all_tenants, which still means every
 *     organisation on this database;
 *   - the client deployments reached, each with when it was named, when the
 *     sweep last sent it the incident and when the client told its own people
 *     (shown here, never asserted: a client that is down would otherwise turn
 *     the control plane's release red);
 *   - received_at, on a client's own project: a copy the control plane sent,
 *     which is changed there and never here.
 *
 * Every one of those keys may be missing — a database older than the
 * migration says none of them — or of another shape, so nothing here takes a
 * row on trust. Pure, so it is tested without a screen or a database.
 */

type Row = Record<string, unknown>;

function objectOf(v: unknown): Row | null {
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Row) : null;
}

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

function countOf(v: unknown): number | null {
  if (typeof v === "number") return Number.isInteger(v) && v >= 0 ? v : null;
  if (typeof v === "string" && /^\d+$/.test(v.trim())) return Number(v.trim());
  return null;
}

/* -------------------------------------------------------------------------- */
/* A received copy, on a client's own project.                                */
/* -------------------------------------------------------------------------- */

/** When the control plane's copy of this incident or window arrived here; null for one made here. */
export function receivedAtOf(row: unknown): string | null {
  const o = objectOf(row);
  return o === null ? null : timeTextOf(o["received_at"]);
}

/**
 * Whether a row is a copy the control plane sent: it says when it arrived,
 * or says outright that it was received.
 */
export function isReceived(row: unknown): boolean {
  const o = objectOf(row);
  if (o === null) return false;
  return o["received"] === true || receivedAtOf(o) !== null;
}

/**
 * The received copy among `rows` that `code` names, or null when the code
 * names nothing received — one made here, one not yet listed, or no code. The
 * console offers no write on a received copy: the database refuses every one,
 * and the place to change it is the control plane.
 */
export function receivedCopy(
  code: string,
  rows: readonly unknown[] | null | undefined,
): { code: string; receivedAt: string | null } | null {
  const wanted = code.trim();
  if (wanted === "") return null;
  for (const row of rows ?? []) {
    const o = objectOf(row);
    if (o === null || textOf(o["code"]) !== wanted) continue;
    return isReceived(o) ? { code: wanted, receivedAt: receivedAtOf(o) } : null;
  }
  return null;
}

/* -------------------------------------------------------------------------- */
/* Every client, and the client deployments reached.                          */
/* -------------------------------------------------------------------------- */

/**
 * Whether the row reaches every client deployment. Null where the door does
 * not say: a database older than the choice, where nothing reached a client.
 */
export function everyClientOf(row: unknown): boolean | null {
  const o = objectOf(row);
  if (o === null) return null;
  const v = o["every_client"];
  return typeof v === "boolean" ? v : null;
}

/**
 * How a client deployment was reached: named by somebody, or as every client
 * from when the sweep first handed it the incident or window. Null where the
 * door does not say.
 */
export type Reach = "named" | "every_client";

/** One client deployment an incident or window reached, as the control plane records it. */
export type DeploymentReached = {
  /** The deployment's code: the host label of its address. */
  code: string;
  /** Named, or reached as every client; null where the door does not say. */
  reach: Reach | null;
  /**
   * When it was named, by whom — or, reached as every client, when the sweep
   * first handed it out, by nobody.
   */
  namedAt: string | null;
  namedBy: string | null;
  /** When the sweep last sent it the incident or window; null until the first send. */
  sentAt: string | null;
  /** When the client's own project told its people; null until it says it has. */
  toldAt: string | null;
};

function reachOf(v: unknown): Reach | null {
  return v === "named" || v === "every_client" ? v : null;
}

function deploymentOf(v: unknown): DeploymentReached | null {
  const o = objectOf(v);
  if (o === null) return null;
  const code = textOf(o["deployment_code"]) ?? textOf(o["code"]);
  if (code === null) return null;
  return {
    code,
    reach: reachOf(o["reach"]),
    namedAt: timeTextOf(o["named_at"]),
    namedBy: textOf(o["named_by"]),
    sentAt: timeTextOf(o["last_pushed_at"]) ?? timeTextOf(o["pushed_at"]),
    toldAt: timeTextOf(o["client_told_at"]) ?? timeTextOf(o["told_at"]),
  };
}

function deploymentsIn(v: unknown): DeploymentReached[] {
  if (!Array.isArray(v)) return [];
  const out: DeploymentReached[] = [];
  for (const item of v as unknown[]) {
    const d = deploymentOf(item);
    if (d !== null) out.push(d);
  }
  return out;
}

/** The later of two times, either of which may be missing. */
function laterOf(a: string | null, b: string | null): string | null {
  if (a === null) return b;
  if (b === null) return a;
  return Date.parse(b) > Date.parse(a) ? b : a;
}

/**
 * Lists of deployments reached, from more than one door, as one: one entry a
 * code, in code order, each field the newest any list knew.
 */
export function mergeDeployments(
  ...lists: readonly (readonly DeploymentReached[])[]
): DeploymentReached[] {
  const byCode = new Map<string, DeploymentReached>();
  for (const list of lists) {
    for (const d of list) {
      const held = byCode.get(d.code);
      byCode.set(
        d.code,
        held === undefined
          ? { ...d }
          : {
              code: d.code,
              reach: held.reach ?? d.reach,
              namedAt: held.namedAt ?? d.namedAt,
              namedBy: held.namedBy ?? d.namedBy,
              sentAt: laterOf(held.sentAt, d.sentAt),
              toldAt: laterOf(held.toldAt, d.toldAt),
            },
      );
    }
  }
  return [...byCode.values()].sort((a, b) => a.code.localeCompare(b.code));
}

/** The client deployments a row of the incident or window list carries. Empty where it carries none. */
export function deploymentsOf(row: unknown): DeploymentReached[] {
  const o = objectOf(row);
  return o === null ? [] : mergeDeployments(deploymentsIn(o["deployments"]));
}

/**
 * How many client deployments a row reached: the list's length, or the count
 * the row states instead. Null where the row says nothing of deployments.
 */
export function deploymentCountOf(row: unknown): number | null {
  const o = objectOf(row);
  if (o === null) return null;
  const v = o["deployments"];
  if (Array.isArray(v)) return deploymentsIn(v).length;
  return countOf(v);
}

/** An organisation named as reached, as erp_platform_incident_organisations says it. */
export type OrganisationNamed = { code: string; namedAt: string | null; namedBy: string | null };

/**
 * What erp_platform_incident_organisations answers, in whichever shape: the
 * list of organisations it has always been, each row possibly a deployment
 * instead (it carries deployment_code), or one object holding the two lists.
 */
export function readNamed(raw: unknown): {
  organisations: OrganisationNamed[];
  deployments: DeploymentReached[];
} {
  const organisations: OrganisationNamed[] = [];
  const deployments: DeploymentReached[] = [];
  const takeOrganisation = (v: unknown) => {
    const o = objectOf(v);
    const code = o === null ? null : textOf(o["tenant_code"]);
    if (o === null || code === null) return;
    organisations.push({
      code,
      namedAt: timeTextOf(o["named_at"]),
      namedBy: textOf(o["named_by"]),
    });
  };

  if (Array.isArray(raw)) {
    for (const item of raw as unknown[]) {
      const o = objectOf(item);
      if (o === null) continue;
      if (textOf(o["deployment_code"]) !== null) {
        const d = deploymentOf(o);
        if (d !== null) deployments.push(d);
      } else {
        takeOrganisation(o);
      }
    }
  } else {
    const o = objectOf(raw);
    if (o !== null) {
      if (Array.isArray(o["organisations"])) {
        for (const item of o["organisations"] as unknown[]) takeOrganisation(item);
      }
      deployments.push(...deploymentsIn(o["deployments"]));
    }
  }
  return { organisations, deployments: mergeDeployments(deployments) };
}

/**
 * Who has been named so far, from the record rather than from memory of
 * what was typed: the organisations, then the client deployments named, then
 * those reached as every client, which nobody named.
 */
export function namedWords(named: {
  organisations: readonly OrganisationNamed[];
  deployments: readonly DeploymentReached[];
}): string {
  const organisations = named.organisations.map((o) => o.code).join(", ");
  const deployments = named.deployments
    .filter((d) => d.reach !== "every_client")
    .map((d) => d.code)
    .join(", ");
  const everyClient = named.deployments
    .filter((d) => d.reach === "every_client")
    .map((d) => d.code)
    .join(", ");
  let words: string | null = null;
  if (organisations !== "" && deployments !== "") {
    words = `Named: ${organisations}; client deployments: ${deployments}`;
  } else if (organisations !== "") {
    words = `Named: ${organisations}`;
  } else if (deployments !== "") {
    words = `Named client deployments: ${deployments}`;
  }
  if (everyClient !== "") {
    return words === null
      ? `Reached as every client: ${everyClient}`
      : `${words}; reached as every client: ${everyClient}`;
  }
  return words ?? "Nobody named yet: everyone, or nobody, depending on the scope declared.";
}

/**
 * How one client deployment came to be reached, in plain words: named, when
 * and by whom, or reached as every client from when the sweep first handed it
 * out. A row from a door that does not say how, and names nobody, was reached
 * as every client: naming always records who named.
 */
export function reachWords(d: DeploymentReached, time: (iso: string) => string = whenText): string {
  if (d.reach === "every_client" || (d.reach === null && d.namedAt === null)) {
    return d.namedAt === null
      ? "Reached as every client"
      : `Reached as every client, ${time(d.namedAt)}`;
  }
  if (d.namedAt === null) return "Named";
  return `Named ${time(d.namedAt)}${d.namedBy !== null ? ` by ${d.namedBy}` : ""}`;
}

/**
 * Where one client deployment stands with an incident or window, in plain
 * words. A window is shown when it was sent, and told only where the client
 * says so; an incident is the client's to tell its people about, so one not
 * yet told says that.
 */
export function deliveryWords(
  d: DeploymentReached,
  options: { tells: boolean; time?: (iso: string) => string } = { tells: true },
): string {
  const time = options.time ?? whenText;
  if (d.sentAt === null) return "Not sent yet";
  const sent = `Sent ${time(d.sentAt)}`;
  if (d.toldAt !== null) return `${sent}; its people told ${time(d.toldAt)}`;
  return options.tells ? `${sent}; its people not told yet` : sent;
}

/**
 * The client deployments reached, in one line for a list's row: every client,
 * or how many, and how many have told their people.
 */
export function deploymentSummary(
  everyClient: boolean | null,
  deployments: readonly DeploymentReached[],
  count: number | null,
): string | null {
  const n = deployments.length > 0 ? deployments.length : (count ?? 0);
  const told = deployments.filter((d) => d.toldAt !== null).length;
  const reached = n === 1 ? "1 client deployment" : `${n} client deployments`;
  const toldWords = deployments.length > 0 ? `, ${told} told` : "";
  if (everyClient === true) return n > 0 ? `every client · ${reached}${toldWords}` : "every client";
  return n > 0 ? `${reached}${toldWords}` : null;
}

/* -------------------------------------------------------------------------- */
/* What the console sends.                                                    */
/* -------------------------------------------------------------------------- */

/**
 * A comma separated list of codes, as typed: organisations on this database,
 * client deployments by code or address, or both. Null when nothing was typed,
 * so the door is told nobody rather than an empty list.
 */
export function codesOf(text: string): string[] | null {
  const seen = new Set<string>();
  for (const part of text.split(/[\s,;]+/)) {
    const code = part.trim();
    if (code !== "") seen.add(code);
  }
  return seen.size > 0 ? [...seen] : null;
}

/**
 * The arguments with the "every client" choice added last, only when it is
 * made: a door that has never heard of it is then never sent it, and leaving
 * it unticked is the door's own default rather than a no from this screen.
 */
export function withEveryClient<T extends Record<string, unknown>>(
  args: T,
  everyClient: boolean,
): T | (T & { p_every_client: true }) {
  return everyClient ? { ...args, p_every_client: true } : args;
}

/**
 * What containing sends for "every client", given what the incident says now
 * and what the form shows: true or false when the form says other than the
 * incident does — so "every client" can be withdrawn as well as said — and
 * nothing when it says the same or was not touched, which the door reads as
 * "as declared". Where the incident's setting is not known (a row from an
 * older database, or a code not in the list), only a yes is sent.
 */
export function everyClientChange(current: boolean | null, chosen: boolean | null): boolean | null {
  if (chosen === null) return null;
  if (current === null) return chosen ? true : null;
  return chosen === current ? null : chosen;
}

/** The containment's arguments, with the "every client" change added last when there is one. */
export function withEveryClientChange<T extends Record<string, unknown>>(
  args: T,
  current: boolean | null,
  chosen: boolean | null,
): T | (T & { p_every_client: boolean }) {
  const change = everyClientChange(current, chosen);
  return change === null ? args : { ...args, p_every_client: change };
}

/** What the incident says now of every client, for the containment form; null where it does not say. */
export function everyClientNowWords(current: boolean | null): string | null {
  if (current === true) return "Now it reaches every client deployment.";
  if (current === false) return "Now it reaches only the client deployments named.";
  return null;
}

/* -------------------------------------------------------------------------- */
/* The organisation's own banner.                                             */
/* -------------------------------------------------------------------------- */

/**
 * Who an incident on the service banner affects, as the organisation reads
 * it: "service" when it reached this service — a copy the control plane sent,
 * or one marked for every organisation on a client's own project, which holds
 * one organisation, so "every organisation" would claim others it does not
 * have — "everyone" when it reached every organisation here, and null when it
 * was named against this organisation alone, which says nothing more.
 */
export function noticeReach(
  incident: unknown,
  onClientDeployment: boolean,
): "service" | "everyone" | null {
  const o = objectOf(incident);
  if (o === null) return null;
  if (isReceived(o)) return "service";
  if (o["affects_all_tenants"] !== true) return null;
  return onClientDeployment ? "service" : "everyone";
}
