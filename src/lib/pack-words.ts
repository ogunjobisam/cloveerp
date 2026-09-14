/**
 * What a content pack's plan says, in words a person reads.
 *
 * The plan comes from the database in its own vocabulary: "3 item(s) are held
 * back because the batch_control capability is off", and decisions keyed
 * `FIN|invoice_reference|1`. A capability is a feature on every screen
 * (Terminology §4), and the feature has a title the Features screen already
 * shows; a band is a department, a kind of document and a number. These turn
 * one into the other. Anything they do not recognise is still returned as
 * words, never as an empty string.
 *
 * Pure, so it is tested on its own.
 */

import { prettifyField } from "./friendly";

/** A feature's title where the Features screen has one, otherwise its code as words. */
export function featureName(code: string, titles: Readonly<Record<string, string>>): string {
  const title = titles[code];
  return title !== undefined && title.trim() !== "" ? title : prettifyField(code);
}

const HELD_BACK = /^(\d+) item\(s\) are held back because the ([a-z][a-z0-9_]*) capability is off$/;

/**
 * One conflict or advisory from the plan.
 *
 * The advisory the Plan shows most — items held back by a feature that is off —
 * is rewritten whole. The others keep their sentence and lose the engine's
 * words: a capability becomes the feature by its title, and "(s)" plurals
 * become plurals.
 */
export function packConflictWords(text: string, titles: Readonly<Record<string, string>>): string {
  const held = HELD_BACK.exec(text.trim());
  if (held) {
    const n = Number(held[1]);
    const feature = featureName(held[2] ?? "", titles);
    return n === 1
      ? `1 item is held back because ${feature} is switched off`
      : `${n} items are held back because ${feature} is switched off`;
  }
  return text
    .replace(
      /\bthe ([a-z][a-z0-9_]*) capability\b/g,
      (_m, code: string) => `the ${featureName(code, titles)} feature`,
    )
    .replace(/\breport\(s\)/g, "reports")
    .replace(/\bitem\(s\)/g, "items");
}

/** The base pack's departments (Starter Content Packs §3.1), by code. */
const DEPARTMENTS: Readonly<Record<string, string>> = {
  EXEC: "Executive",
  FIN: "Finance",
  PROC: "Procurement",
  PLAN: "Supply chain and planning",
  OPS: "Operations",
  WHSE: "Warehouse",
  PROD: "Production",
  QUAL: "Quality",
  SALES: "Sales",
  CS: "Customer service",
  LOG: "Logistics",
  FAC: "Facilities",
  IT: "Information technology",
  PEOPLE: "People",
};

/** What each band approves, as the prompts beside them say it. */
const APPROVED: Readonly<Record<string, string>> = {
  requisition: "requisitions",
  purchase_order: "purchase orders",
  invoice_reference: "supplier invoices",
  sales_order: "sales orders held on credit",
};

/**
 * A decision's name. `PROC|requisition|1` is "Procurement: requisitions,
 * approval band 1". A key of another shape is its parts as words.
 */
export function decisionLabel(objectKind: string, objectKey: string): string {
  const parts = objectKey.split("|");
  if (objectKind === "approval_band" && parts.length === 3) {
    const [department = "", document = "", band = ""] = parts;
    if (/^\d+$/.test(band)) {
      const who = DEPARTMENTS[department] ?? department;
      const what = APPROVED[document] ?? prettifyField(document).toLowerCase();
      return `${who}: ${what}, approval band ${band}`;
    }
  }
  const words = parts
    .map((p) => p.trim())
    .filter((p) => p !== "")
    .map((p) => (/^[A-Z0-9]+$/.test(p) ? p : prettifyField(p)));
  return words.length === 0 ? prettifyField(objectKind) : words.join(", ");
}
