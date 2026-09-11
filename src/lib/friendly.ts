import { MODULES } from "./modules";

/**
 * Names people recognise, in place of the database's own.
 *
 * A routine is called `erp_complete_warehouse_task` in the database, and the
 * screens that drive it already carry a label written for the person using it.
 * This finds that label, and, where a routine belongs to no screen, turns the
 * name into a readable phrase rather than showing the raw one.
 */

let labels: Map<string, string> | null = null;

function labelIndex(): Map<string, string> {
  if (labels) return labels;
  const index = new Map<string, string>();
  for (const mod of MODULES) {
    for (const action of mod.actions ?? []) {
      if (!index.has(action.fn)) index.set(action.fn, action.title ?? action.label);
    }
    for (const inquiry of mod.inquiries ?? []) {
      if (!index.has(inquiry.fn)) index.set(inquiry.fn, inquiry.label);
    }
  }
  labels = index;
  return index;
}

/** Turn `erp_complete_warehouse_task` into `Complete warehouse task`. */
export function prettifyRoutine(name: string): string {
  const words = name
    .replace(/^(public\.)?erp_?/, "")
    .replace(/_/g, " ")
    .trim();
  if (words === "") return name;
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** The friendliest name for a database routine. */
export function routineLabel(name: string): string {
  return labelIndex().get(name) ?? prettifyRoutine(name);
}

/** Turn a column name such as `quantity_done` into `Quantity done`. */
export function prettifyField(name: string): string {
  const words = name.replace(/_/g, " ").replace(/\bid\b/gi, "").trim();
  if (words === "") return name;
  return words.charAt(0).toUpperCase() + words.slice(1);
}
