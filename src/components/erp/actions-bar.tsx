import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog, type Field } from "./action";
import { Prose } from "./page";

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

/**
 * A bar of actions, under a heading that says what they act on.
 *
 * The heading used to be the literal word "Actions", on every one of these.
 * The organisation screen carries five, so it read as five identical cards
 * called ACTIONS — departments, approval bands, cover, sites and locations,
 * none of them named — with the only distinguishing words demoted to a
 * sentence of grey body text underneath. A page you cannot scan is a page you
 * read top to bottom every time, and "Actions" was never an answer to "what is
 * this card?": every card on every screen is actions.
 *
 * So the title names the subject and the note keeps its own job, which is to
 * say the one thing about that subject which is not obvious. The card now
 * reads the way DataPanel does, because it is the same kind of object.
 */
export function ActionBar({
  actions,
  title,
  note,
}: {
  actions: ActionSpec[];
  /**
   * Omitted only where the card around this one already carries the heading —
   * administration/tenant's "Encryption keys" is the one such place. Anywhere
   * else, leaving it out is a card with no name, which is the fault this
   * parameter exists to fix. It is not a fallback to "Actions".
   */
  title?: string;
  note?: string;
}) {
  const { ui } = useT();
  if (actions.length === 0) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      {title ? <h2 className="text-sm font-semibold">{ui(title)}</h2> : null}
      {note ? (
        <Prose className={`${title ? "mt-0.5" : ""} text-xs text-muted-foreground`}>
          {ui(note)}
        </Prose>
      ) : null}
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
