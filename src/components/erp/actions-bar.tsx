import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog, type Field } from "./action";

/**
 * The verbs.
 *
 * Every module page could read its module and none of them could drive it: the
 * database exposes the whole operating loop — receive against an order, raise
 * and close a works order, count and post, plan and despatch a shipment, close
 * a period — and the interface called none of it. Which is also why the
 * screens were empty: nothing in the product could produce a movement.
 *
 * An action is declared, not written. It names the function, the fields it
 * asks for, the permission the database will check anyway, and the reads it
 * invalidates when it succeeds. `ActionDialog` does the rest, including not
 * rendering at all when the session does not hold the permission — so a bar
 * with nothing in it disappears rather than teasing.
 */
export type ActionSpec = {
  label: string;
  title?: string;
  description?: string;
  permission?: string;
  fn: string;
  fields?: Field[];
  /** Query keys — the `fn` names of the reads this action makes stale. */
  invalidates?: string[];
  /** For arguments the form cannot express directly — arrays, mostly. */
  mapArgs?: (values: Record<string, string>) => Record<string, unknown>;
  submitLabel?: string;
};

export function ActionBar({ actions, note }: { actions: ActionSpec[]; note?: string }) {
  const { ui } = useT();
  if (actions.length === 0) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {ui("Actions")}
      </h2>
      {note ? <p className="mt-1 text-sm text-muted-foreground">{ui(note)}</p> : null}
      <div className="mt-3 flex flex-wrap gap-2">
        {actions.map((a) => (
          <ActionDialog
            key={`${a.fn}-${a.label}`}
            trigger={<ActionButton variant="secondary">{ui(a.label)}</ActionButton>}
            title={a.title ?? a.label}
            {...(a.description ? { description: a.description } : {})}
            {...(a.permission ? { permission: a.permission } : {})}
            fn={a.fn}
            fields={a.fields ?? []}
            {...(a.mapArgs ? { mapArgs: a.mapArgs } : {})}
            invalidates={a.invalidates ?? []}
            submitLabel={a.submitLabel ?? a.label}
          />
        ))}
      </div>
    </section>
  );
}

/** Shared field builders, so twenty declarations do not each invent one. */
export const pickItem = (name = "p_item_id", label = "Item"): Field => ({
  kind: "select",
  name,
  label,
  required: true,
  options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
});

export const pickParty = (
  roleKind: string,
  name = "p_party_id",
  label = "Party",
  required = true,
): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: {
    fn: "erp_parties",
    args: { p_role_kind: roleKind },
    value: "party_id",
    label: ["code", "name"],
  },
});

export const pickSite = (name = "p_site_id", label = "Site", required = true): Field => ({
  kind: "site",
  name,
  label,
  required,
});

export const pickFrom = (
  fn: string,
  value: string,
  labels: string[],
  name: string,
  label: string,
  args?: Record<string, unknown>,
  /* Mandatory by default, because most references are. Overridable because
     some are not: a door that defaults the value itself should not be fronted
     by a form that insists, least of all when the list holds one option. */
  required = true,
): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn, value, label: labels, ...(args ? { args } : {}) },
});

export const reason = (name = "p_reason", label = "Reason", required = false): Field => ({
  kind: "text",
  name,
  label,
  required,
  hint: "Recorded against the action in the audit trail.",
});

/** A place in a warehouse, chosen rather than typed. */
export const pickLocation = (
  name = "p_location_id",
  label = "Location",
  required = false,
): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_locations", value: "location_id", label: ["code", "name"] },
});

/** A line of a document, shown as its number, item and quantity. */
export const pickLine = (
  typeCode: string,
  name = "p_order_line_id",
  label = "Order line",
): Field => ({
  kind: "select",
  name,
  label,
  required: true,
  options: {
    fn: "erp_document_lines",
    args: { p_type_code: typeCode, p_limit: 200 },
    value: "line_id",
    label: ["document_number", "item", "quantity"],
  },
});

/** A batch, chosen from the register. */
export const pickBatch = (name = "p_batch_id", label = "Batch", required = false): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_batches", value: "batch_id", label: ["batch_number", "item"] },
});
