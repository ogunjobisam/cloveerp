/**
 * The shared barcode parser, on the client.
 *
 * Specification v1.2 §14.4: "A single scan populates several fields, and the
 * parser is shared, not per-screen." The database owns the definition —
 * `erp.parse_gs1()` and `erp.evaluate_scan()`, with the application
 * identifiers as reference data — and this module is the same two functions
 * written once for the client, so a scan can be validated against cached rules
 * in a cold store with no signal (§14.5) and within §14.7's three hundred
 * milliseconds. The identifier register is not repeated here: it is fetched
 * from `erp_gs1_application_identifiers()` and cached, so an identifier added
 * by a migration reaches the device without a release.
 *
 * Anything this decides is decided again by the database when the action is
 * applied. The client's verdict is what the operator sees now; the module
 * function's refusal, if any, is what the queue shows later as a conflict.
 */

export type ApplicationIdentifier = {
  ai: string;
  field_name: string;
  /** Fixed length in characters, or null for a variable-length field. */
  data_length: number | null;
  is_numeric: boolean;
};

export type ScanRule = {
  item_class: string | null;
  accepted_symbologies: string[];
  mandatory_identifiers: string[];
  when_absent: "exception_with_reason" | "refuse" | "accept" | string;
};

export type Symbology = { code: string; is_gs1: boolean };

export type ScanFields = Record<string, string>;

export type ScanVerdict = {
  outcome: "accepted" | "refused" | "exception" | "rejected";
  reason: string | null;
  scanned_value?: string;
  symbology: string;
  fields: ScanFields;
  missing_identifiers: string[];
  rule: { item_class: string | null; when_absent: string } | null;
};

/** ASCII group separator: FNC1 as most scanners emit it. */
const GS = "\u001d";

export class ScanError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(`${code}: ${message}`);
    this.name = "ScanError";
  }
}

/** §14.4's expiry: a day of 00 means the end of the month, resolved once. */
function expiryToIso(yymmdd: string): string {
  const yy = Number(yymmdd.slice(0, 2));
  const mm = Number(yymmdd.slice(2, 4));
  const dd = Number(yymmdd.slice(4, 6));
  const year = 2000 + yy;
  if (dd === 0) {
    const last = new Date(Date.UTC(year, mm, 0)).getUTCDate();
    return `${year}-${String(mm).padStart(2, "0")}-${String(last).padStart(2, "0")}`;
  }
  return `${year}-${String(mm).padStart(2, "0")}-${String(dd).padStart(2, "0")}`;
}

/**
 * Mirrors `erp.parse_gs1()`: longest application identifier first, fixed
 * lengths taken as stated, variable lengths to the separator or the end, and
 * an unrecognised identifier rejected with the value shown.
 */
export function parseGs1(barcode: string, register: ApplicationIdentifier[]): ScanFields {
  let input = barcode;
  if (input.trim() === "") throw new ScanError("ERPWARE_EMPTY_SCAN", "nothing was scanned");
  while (input.startsWith(GS)) input = input.slice(1);

  const byAi = new Map(register.map((a) => [a.ai, a]));
  const out: ScanFields = {};
  let pos = 0;
  const len = input.length;

  while (pos < len) {
    let rec: ApplicationIdentifier | undefined;
    for (const n of [4, 3, 2]) {
      if (pos + n > len) continue;
      const candidate = byAi.get(input.slice(pos, pos + n));
      if (candidate) {
        rec = candidate;
        break;
      }
    }
    if (!rec) {
      throw new ScanError(
        "ERPWARE_UNRECOGNISED_BARCODE",
        `${barcode} is not a barcode this product reads (stopped at position ${pos + 1} of ${len})`,
      );
    }
    pos += rec.ai.length;

    let value: string;
    if (rec.data_length !== null) {
      value = input.slice(pos, pos + rec.data_length);
      if (value.length < rec.data_length) {
        throw new ScanError(
          "ERPWARE_TRUNCATED_BARCODE",
          `identifier ${rec.ai} needs ${rec.data_length} characters and ${barcode} has fewer`,
        );
      }
      pos += rec.data_length;
    } else {
      const gs = input.indexOf(GS, pos);
      if (gs === -1) {
        value = input.slice(pos);
        pos = len;
      } else {
        value = input.slice(pos, gs);
        pos = gs + 1;
      }
    }

    if (rec.is_numeric && !/^[0-9]+$/.test(value)) {
      throw new ScanError(
        "ERPWARE_BARCODE_FIELD_NOT_NUMERIC",
        `identifier ${rec.ai} carried ${value}`,
      );
    }

    out[rec.field_name] = rec.ai === "17" ? expiryToIso(value) : value;
  }
  return out;
}

/**
 * A barcode that is not GS1 carries one value and nothing to parse. §14.4
 * accepts EAN-13, UPC-A, Code 128 and Code 39 "for legacy and internal
 * marking"; a retail code is a GTIN, so it is offered as one, zero-padded to
 * fourteen digits the way GS1 defines the comparison.
 */
export function plainFields(barcode: string, symbology: string): ScanFields {
  const value = barcode.trim();
  const fields: ScanFields = { value };
  if ((symbology === "ean_13" || symbology === "upc_a") && /^[0-9]{8,14}$/.test(value)) {
    fields["gtin"] = value.padStart(14, "0");
  }
  return fields;
}

/** The most specific rule wins: one naming the item class, else the default. */
export function pickRule(rules: ScanRule[], itemClass: string | null): ScanRule | null {
  return (
    rules.find((r) => r.item_class !== null && r.item_class === itemClass) ??
    rules.find((r) => r.item_class === null) ??
    null
  );
}

/**
 * Mirrors `erp.evaluate_scan()`. Rejected means the barcode could not be read
 * at all; refused means the rule said no; exception means a mandatory field is
 * absent and the step captures it with a reason; accepted means go.
 */
export function evaluateScan(input: {
  barcode: string;
  symbology: string;
  symbologies: Symbology[];
  rules: ScanRule[];
  itemClass?: string | null;
  register: ApplicationIdentifier[];
}): ScanVerdict {
  const sym = input.symbologies.find((s) => s.code === input.symbology);
  if (!sym) {
    throw new ScanError(
      "ERPWARE_UNKNOWN_SYMBOLOGY",
      `${input.symbology} is not a symbology this product reads`,
    );
  }

  let fields: ScanFields;
  try {
    fields = sym.is_gs1
      ? parseGs1(input.barcode, input.register)
      : plainFields(input.barcode, input.symbology);
  } catch (e) {
    return {
      outcome: "rejected",
      reason: e instanceof Error ? e.message.slice(0, 200) : String(e),
      scanned_value: input.barcode,
      symbology: input.symbology,
      fields: {},
      missing_identifiers: [],
      rule: null,
    };
  }

  const rule = pickRule(input.rules, input.itemClass ?? null);
  if (!rule) {
    return {
      outcome: "accepted",
      reason: "no scan rule is configured for this step",
      symbology: input.symbology,
      fields,
      missing_identifiers: [],
      rule: null,
    };
  }
  const ruleOut = { item_class: rule.item_class, when_absent: rule.when_absent };

  if (!rule.accepted_symbologies.includes(input.symbology)) {
    return {
      outcome: "refused",
      reason: `${input.symbology} is not accepted at this step; it accepts ${rule.accepted_symbologies.join(", ")}`,
      symbology: input.symbology,
      fields,
      missing_identifiers: [],
      rule: ruleOut,
    };
  }

  const missing: string[] = [];
  for (const ai of rule.mandatory_identifiers) {
    const field = input.register.find((a) => a.ai === ai)?.field_name;
    if (!field || !(field in fields)) missing.push(field ?? ai);
  }

  if (missing.length === 0) {
    return {
      outcome: "accepted",
      reason: null,
      symbology: input.symbology,
      fields,
      missing_identifiers: [],
      rule: ruleOut,
    };
  }
  const list = missing.join(", ");
  if (rule.when_absent === "refuse") {
    return {
      outcome: "refused",
      reason: `${list} is mandatory at this step and the barcode does not carry it`,
      symbology: input.symbology,
      fields,
      missing_identifiers: missing,
      rule: ruleOut,
    };
  }
  if (rule.when_absent === "accept") {
    return {
      outcome: "accepted",
      reason: `${list} absent, and this step accepts that`,
      symbology: input.symbology,
      fields,
      missing_identifiers: missing,
      rule: ruleOut,
    };
  }
  return {
    outcome: "exception",
    reason: `${list} absent; capture it with a reason or abandon the step`,
    symbology: input.symbology,
    fields,
    missing_identifiers: missing,
    rule: ruleOut,
  };
}
