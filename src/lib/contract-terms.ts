import { toMinor } from "./money";

/**
 * A contract's terms in words, and an amendment built from a form.
 *
 * The contract screen typed an amendment as JSON and showed the uplift rule and
 * the termination terms as JSON, which is the product's own rule broken in the
 * one place a mistake is signed. What erp.amend_contract accepts is a fixed set
 * of keys, each validated before it is recorded and each applied by
 * erp.sign_amendment:
 *
 *   plan_code, annual_value_minor, term_end, renewal_kind, notice_days,
 *   uplift_rule {kind, pct | index_code | cap_pct}, support_severity_code,
 *   entitlements [{code, limit_value}], capabilities [{code, action}]
 *
 * so the form asks for exactly those, and anything left blank is not sent: an
 * absent key is "unchanged" to the signer, where a null would not be.
 *
 * Pure, so the building and the wording are tested without a browser.
 */

export type RenewalKind = "automatic" | "by_agreement" | "none";
export type UpliftKind = "none" | "fixed_pct" | "index" | "capped";

export const RENEWAL_LABELS: Record<RenewalKind, string> = {
  automatic: "Renews automatically",
  by_agreement: "Renews by agreement",
  none: "Does not renew",
};

export const UPLIFT_LABELS: Record<UpliftKind, string> = {
  none: "No uplift",
  fixed_pct: "A fixed percentage",
  index: "In line with an index",
  capped: "In line with an index, capped",
};

export type AmendmentForm = {
  /** Every field is text as typed; blank means "leave it as it is". */
  planCode: string;
  annualValue: string;
  termEnd: string;
  renewalKind: "" | RenewalKind;
  noticeDays: string;
  upliftKind: "" | UpliftKind;
  upliftPct: string;
  upliftIndex: string;
  upliftCap: string;
  supportSeverity: string;
  /** A blank limit is unlimited, as the plan's own bands are. */
  entitlements: { code: string; limit: string }[];
  capabilities: { code: string; action: "add" | "remove" }[];
};

export const EMPTY_AMENDMENT: AmendmentForm = {
  planCode: "",
  annualValue: "",
  termEnd: "",
  renewalKind: "",
  noticeDays: "",
  upliftKind: "",
  upliftPct: "",
  upliftIndex: "",
  upliftCap: "",
  supportSeverity: "",
  entitlements: [],
  capabilities: [],
};

export type AmendmentChanges =
  { ok: true; changes: Record<string, unknown> } | { ok: false; problem: string };

function numberOf(text: string): number | null {
  const t = text.trim();
  if (t === "") return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

/**
 * The p_changes an amendment form means, or the first thing wrong with it.
 *
 * Only what the form can know is checked here — a number that is not a number,
 * an uplift missing the figure its kind needs, an amendment that changes
 * nothing. Whether the plan, band or feature exists is the door's to say, and
 * it says so by name.
 */
export function amendmentChanges(form: AmendmentForm, minorUnits = 2): AmendmentChanges {
  const changes: Record<string, unknown> = {};

  if (form.planCode.trim() !== "") changes["plan_code"] = form.planCode.trim();

  if (form.annualValue.trim() !== "") {
    const minor = toMinor(form.annualValue, minorUnits);
    if (minor === null || minor < 0) {
      return { ok: false, problem: "The annual value must be an amount, such as 24000." };
    }
    changes["annual_value_minor"] = minor;
  }

  if (form.termEnd.trim() !== "") changes["term_end"] = form.termEnd.trim();
  if (form.renewalKind !== "") changes["renewal_kind"] = form.renewalKind;

  if (form.noticeDays.trim() !== "") {
    const days = numberOf(form.noticeDays);
    if (days === null || days < 0 || !Number.isInteger(days)) {
      return { ok: false, problem: "The notice period must be a whole number of days." };
    }
    changes["notice_days"] = days;
  }

  if (form.upliftKind !== "") {
    if (form.upliftKind === "none") changes["uplift_rule"] = { kind: "none" };
    if (form.upliftKind === "fixed_pct") {
      const pct = numberOf(form.upliftPct);
      if (pct === null) return { ok: false, problem: "Say what percentage the uplift is." };
      changes["uplift_rule"] = { kind: "fixed_pct", pct };
    }
    if (form.upliftKind === "index" || form.upliftKind === "capped") {
      const index = form.upliftIndex.trim().toUpperCase();
      if (index === "")
        return { ok: false, problem: "Name the index the uplift follows, such as CPI." };
      if (form.upliftKind === "index")
        changes["uplift_rule"] = { kind: "index", index_code: index };
      else {
        const cap = numberOf(form.upliftCap);
        if (cap === null)
          return { ok: false, problem: "Say what percentage the uplift is capped at." };
        changes["uplift_rule"] = { kind: "capped", index_code: index, cap_pct: cap };
      }
    }
  }

  if (form.supportSeverity.trim() !== "") {
    changes["support_severity_code"] = form.supportSeverity.trim();
  }

  const entitlements: { code: string; limit_value: number | null }[] = [];
  for (const row of form.entitlements) {
    const code = row.code.trim();
    if (code === "") continue;
    if (row.limit.trim() === "") {
      entitlements.push({ code, limit_value: null });
      continue;
    }
    const limit = numberOf(row.limit);
    if (limit === null || limit < 0) {
      return {
        ok: false,
        problem: `The limit for ${code} must be a number, or blank for unlimited.`,
      };
    }
    entitlements.push({ code, limit_value: limit });
  }
  if (entitlements.length > 0) changes["entitlements"] = entitlements;

  const capabilities = form.capabilities
    .map((c) => ({ code: c.code.trim(), action: c.action }))
    .filter((c) => c.code !== "");
  if (capabilities.length > 0) changes["capabilities"] = capabilities;

  if (Object.keys(changes).length === 0) {
    return {
      ok: false,
      problem: "Change at least one thing: an amendment that changes nothing is refused.",
    };
  }
  return { ok: true, changes };
}

/* -------------------------------------------------------------------------- */
/* Reading terms back.                                                        */
/* -------------------------------------------------------------------------- */

function text(value: unknown): string | null {
  if (typeof value === "string" && value.trim() !== "") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

/** An uplift rule as a person says it. */
export function describeUplift(rule: unknown): string {
  if (!rule || typeof rule !== "object") return "No uplift";
  const r = rule as Record<string, unknown>;
  const kind = r["kind"];
  const pct = text(r["pct"]);
  const index = text(r["index_code"]);
  const cap = text(r["cap_pct"]);
  if (kind === undefined || kind === "none") return "No uplift";
  if (kind === "fixed_pct")
    return pct ? `Rises by ${pct}% at each renewal` : "Rises by a fixed percentage";
  if (kind === "index") return `Rises in line with ${index ?? "an index"} at each renewal`;
  if (kind === "capped") {
    return `Rises in line with ${index ?? "an index"} at each renewal, capped at ${cap ?? "a set"}%`;
  }
  return `Uplift by a rule this screen does not know (${String(kind)})`;
}

function humanise(key: string): string {
  const words = key.replace(/_/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** Termination terms as lines of text, the known ones first and in words. */
export function describeTermination(terms: unknown): string[] {
  if (!terms || typeof terms !== "object") return ["No termination terms recorded"];
  const t = terms as Record<string, unknown>;
  const lines: string[] = [];

  const rights = text(t["rights"]);
  if (rights) lines.push(`Termination rights: ${rights}`);
  const exit = text(t["exit_assistance_days"]);
  if (exit && exit !== "0")
    lines.push(`${exit} ${exit === "1" ? "day" : "days"} of exit assistance`);
  const data = text(t["data_return"]);
  if (data) lines.push(`Data return: ${data}`);

  for (const [key, value] of Object.entries(t)) {
    if (key === "rights" || key === "exit_assistance_days" || key === "data_return") continue;
    const said = text(value) ?? (typeof value === "boolean" ? (value ? "yes" : "no") : null);
    if (said) lines.push(`${humanise(key)}: ${said}`);
  }
  return lines.length > 0 ? lines : ["No termination terms recorded"];
}

/**
 * An amendment's changes as lines of text. `money` formats an amount in minor
 * units the way the rest of the contract screen does.
 */
export function describeChanges(changes: unknown, money: (minor: number) => string): string[] {
  if (!changes || typeof changes !== "object") return [];
  const c = changes as Record<string, unknown>;
  const lines: string[] = [];

  const plan = text(c["plan_code"]);
  if (plan) lines.push(`Plan becomes ${plan}`);
  if (typeof c["annual_value_minor"] === "number") {
    lines.push(`Annual value becomes ${money(c["annual_value_minor"])}`);
  }
  const end = text(c["term_end"]);
  if (end) lines.push(`Current term ends ${end}`);
  const renewal = c["renewal_kind"];
  if (typeof renewal === "string" && renewal in RENEWAL_LABELS) {
    lines.push(RENEWAL_LABELS[renewal as RenewalKind]);
  }
  const notice = text(c["notice_days"]);
  if (notice) lines.push(`Notice period becomes ${notice} days`);
  if (c["uplift_rule"] !== undefined) lines.push(describeUplift(c["uplift_rule"]));
  const support = text(c["support_severity_code"]);
  if (support) lines.push(`Support tier becomes ${support}`);

  if (Array.isArray(c["entitlements"])) {
    for (const e of c["entitlements"] as unknown[]) {
      if (!e || typeof e !== "object") continue;
      const row = e as Record<string, unknown>;
      const limit = text(row["limit_value"]);
      lines.push(`${text(row["code"]) ?? "A band"} limit becomes ${limit ?? "unlimited"}`);
    }
  }
  if (Array.isArray(c["capabilities"])) {
    for (const f of c["capabilities"] as unknown[]) {
      if (!f || typeof f !== "object") continue;
      const row = f as Record<string, unknown>;
      const code = text(row["code"]) ?? "a feature";
      lines.push(
        row["action"] === "remove" ? `Feature ${code} withdrawn` : `Feature ${code} added`,
      );
    }
  }
  return lines;
}
