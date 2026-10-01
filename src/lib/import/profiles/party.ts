import { countryToIso2 } from "../values";
import type { Finding, Json, PartyRole, ProfileContext } from "../types";

/**
 * What the party profiles share: payment terms mapped onto the product's
 * list, addresses in the shape erp.record_party_address takes, and the roles
 * a contact stands at once a person has had their say.
 *
 * The product's terms are a fixed list (erp_ref.payment_term). A legacy term
 * that is not on it maps to the nearest one, and the line says so: a finance
 * person reads the list before loading, and the term is changed on the party
 * afterwards if the nearest is not close enough.
 */

const NET_DAYS = [7, 14, 30, 45, 60, 90] as const;

export type TermMapping = { code: string; note: string | null };

function nearestNet(days: number): TermMapping {
  let best: number = NET_DAYS[0];
  for (const d of NET_DAYS) if (Math.abs(d - days) < Math.abs(best - days)) best = d;
  return {
    code: `NET${best}`,
    note: best === days ? null : `${days} days has no term of its own; NET${best} is the nearest`,
  };
}

/**
 * Xero's DueDate…Day and DueDate…Term: "30" with "DAYSAFTERBILLDATE", or the
 * words the export spells it with. Null where the contact carries no term.
 */
export function xeroTerm(dayText: string, termText: string): TermMapping | null {
  const term = termText.toLowerCase().replace(/[^a-z]/g, "");
  if (term === "") return null;
  const day = Number.parseInt(dayText, 10);
  const days = Number.isFinite(day) ? day : 0;
  if (term.includes("afterbilldate") || term.includes("afterinvoicedate") || term === "daysafter") {
    return days === 0
      ? { code: "COD", note: "0 days after the invoice is on delivery" }
      : nearestNet(days);
  }
  if (
    term.includes("afterbillmonth") ||
    term.includes("afterendofmonth") ||
    term.includes("afterinvoicemonth")
  ) {
    return days === 0
      ? { code: "EOM", note: null }
      : { code: "EOM30", note: `${days} days after the end of the month maps to EOM30` };
  }
  if (term.includes("followingmonth")) {
    return { code: "EOM30", note: `day ${days || "?"} of the following month maps to EOM30` };
  }
  if (term.includes("currentmonth")) {
    return { code: "EOM", note: `day ${days || "?"} of the current month maps to EOM` };
  }
  return null;
}

/** Unleashed's payment term as its name reads: "Net 30", "30 Days", "20th Month Following". */
export function unleashedTerm(text: string): TermMapping | null {
  const t = text.trim().toLowerCase();
  if (t === "") return null;
  if (/prepa(id|y)|in advance|pro ?forma/.test(t)) return { code: "PREPAID", note: null };
  if (/\bcod\b|cash on delivery|on delivery/.test(t)) return { code: "COD", note: null };
  if (/following|next month/.test(t)) {
    return { code: "EOM30", note: `"${text.trim()}" maps to EOM30` };
  }
  if (/end of (the )?month|\beom\b/.test(t)) {
    const plus = /(\d+)/.exec(t);
    return plus
      ? { code: "EOM30", note: plus[1] === "30" ? null : `"${text.trim()}" maps to EOM30` }
      : { code: "EOM", note: null };
  }
  const days = /(\d+)/.exec(t);
  return days ? nearestNet(Number(days[1])) : null;
}

export type AddressIn = {
  kind: "billing" | "delivery";
  lines: string[];
  locality: string;
  region: string;
  postcode: string;
  country: string;
};

/**
 * An address as record_party_address takes it, or null where the file gave
 * none. A partial address — a town and nothing else — is reported, not staged:
 * the desk refuses one without a first line.
 */
export function address(
  a: AddressIn,
  line: number,
  findings: Finding[],
): { [key: string]: Json } | null {
  const lines = a.lines.map((l) => l.trim()).filter((l) => l !== "");
  const any = lines.length > 0 || a.locality || a.postcode || a.region;
  if (!any) return null;
  if (lines.length === 0 || (a.locality.trim() === "" && a.postcode.trim() === "")) {
    findings.push({
      line,
      severity: "warning",
      message: `the ${a.kind} address has no first line or no town and postcode, so it is left out`,
    });
    return null;
  }
  const out: { [key: string]: Json } = { kind: a.kind, lines };
  if (a.locality.trim()) out["locality"] = a.locality.trim();
  if (a.region.trim()) out["region"] = a.region.trim();
  if (a.postcode.trim()) out["postcode"] = a.postcode.trim();
  if (a.country.trim()) {
    const iso = countryToIso2(a.country);
    if (iso) out["country_code"] = iso;
    else {
      findings.push({
        line,
        severity: "warning",
        message: `the ${a.kind} address's country "${a.country}" is not recognised, so it is left off the address`,
      });
    }
  }
  return out;
}

/** The roles a contact stands at: a person's choice, else the file's, else the default. */
export function rolesFor(
  key: string,
  fromFile: readonly PartyRole[],
  ctx: ProfileContext,
): PartyRole[] {
  const chosen = ctx.partyRoles[key];
  if (chosen) return [...chosen];
  if (fromFile.length > 0) return [...fromFile];
  return ctx.defaultPartyRole === "none" ? [] : [ctx.defaultPartyRole];
}
