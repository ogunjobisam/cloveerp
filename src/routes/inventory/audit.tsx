import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickChangeSet, pickFrom } from "../../components/erp/actions-bar";
import { CountWorklist } from "../../components/erp/count-worklist";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { useScope } from "../../components/erp/session-context";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useT } from "../../lib/i18n";
import { countPostingArgs } from "../../lib/modules";
import { formatMinor } from "../../lib/money";

export const Route = createFileRoute("/inventory/audit")({
  head: () => ({
    meta: [
      { title: "Stock audit — Clove ERP" },
      {
        name: "description",
        content:
          "Every location holding stock, the quantity and value standing in it, when it was last counted and by how much the count differed.",
      },
      { property: "og:title", content: "Stock audit — Clove ERP" },
      {
        property: "og:description",
        content:
          "Book quantity against counted quantity, location by location, with the variance and what it is worth.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <StockAudit />
    </Gate>
  ),
});

/**
 * Counting, and the book beside the count, per place.
 *
 * The top of the screen is the counter's: the worklist of places waiting to
 * be counted, one box and one press each, in the order of the count sheet,
 * and beneath it the counts that wait on somebody (src/components/erp/
 * count-worklist.tsx). A count task is the counter's unit.
 *
 * The balances below are the auditor's, whose unit is the place. An auditor
 * asks about a location, and the answer has to include the locations nobody
 * has counted: a bin with no count task raised against it is invisible in a
 * list of count tasks and is precisely the thing being looked for. So every
 * active location appears there, counted or not, and "never counted" is a
 * state rather than a blank.
 */
type AuditRow = {
  location_id: string;
  location: string;
  location_name: string | null;
  location_type: string;
  is_blocked: boolean;
  count_class: string | null;
  site: string;
  products: number;
  quantity: number;
  value_minor: number;
  currency: string;
  last_counted_at: string | null;
  counted_quantity: number | null;
  variance: number | null;
  variance_value_minor: number;
  counts_open: number;
  state: "counting" | "never counted" | "variance" | "agreed";
};

type AuditLine = {
  location_code: string;
  location_name: string | null;
  site_code: string;
  item_code: string;
  item_name: string | null;
  quantity: number;
  unit_cost_minor: number;
  value_minor: number;
  currency: string;
  last_counted_at: string | null;
  expected_quantity: number | null;
  counted_quantity: number | null;
  variance: number | null;
  variance_value_minor: number;
  count_status: string | null;
};

const day = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleDateString(undefined, {
        day: "numeric",
        month: "short",
        year: "numeric",
      })
    : "—";

const qty = (n: number | null | undefined) =>
  n == null ? "—" : new Intl.NumberFormat(undefined, { maximumFractionDigits: 3 }).format(n);

/** A variance reads as a signed number, because its direction is the point. */
const signed = (n: number | null | undefined) => {
  if (n == null) return "—";
  if (n === 0) return "0";
  return `${n > 0 ? "+" : ""}${qty(n)}`;
};

const stateTone = (state: AuditRow["state"]) =>
  state === "variance"
    ? "bad"
    : state === "never counted"
      ? "warn"
      : state === "counting"
        ? "muted"
        : "ok";

function StockAudit() {
  // The balances and the count tasks are about a place. The header names one
  // and this screen had never read it (20260920130000).
  const { siteId } = useScope();
  const { ui } = useT();
  const invalidates = [
    "erp_stock_audit",
    "erp_stock_audit_lines",
    "erp_count_tasks",
    "erp_count_accuracy",
    "erp_stock_health",
    "erp_stock_valuation",
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={ui("Stock audit")}
        howItWorks={ui(
          "A place nobody has counted shows as never counted rather than as agreeing. A count inside its tolerance corrects the stock as it is recorded, through a stock adjustment with a reason; one outside it corrects nothing until it is agreed and posted.",
        )}
      >
        {ui(
          "What the system says is in each place, what it is worth, and what the last count found.",
        )}
      </PageHeader>

      <ActionBar
        title="Counting"
        note="Raise tasks from a counting programme, then record each place on the worklist below. A count outside its tolerance is decided here by its approver."
        actions={[
          {
            label: "Raise count tasks",
            description: "Ask a counting programme for its next set of places to count.",
            permission: "inventory.count",
            fn: "erp_raise_count_tasks",
            // The door refuses a programme that is not active, so the status
            // is shown beside the code.
            fields: [
              pickFrom(
                "erp_count_programmes",
                "code",
                ["code", "name", "status"],
                "p_programme_code",
                "Programme",
              ),
            ],
            invalidates,
          },
          {
            // A count outside the tolerance of its programme waits on an
            // approval task, and until 20260914070000 deciding it moved
            // nothing: the count stayed waiting. Deciding it here approves or
            // refuses the count itself.
            label: "Decide a count difference",
            description:
              "A count outside its programme's tolerance waits for the approving role to agree. Agreed, it is posted by somebody who may adjust stock; refused, it stays as it was found and is not posted.",
            // No permission: the door gates on the task being assigned to the
            // caller, and a code here would hide it from an assignee who lacks it.
            fn: "erp_decide_approval",
            fields: [
              pickFrom(
                "erp_my_approvals",
                "task_id",
                ["object_type", "requested_by", "requested_at"],
                "p_task_id",
                "Approval waiting on me",
              ),
              {
                kind: "choice",
                name: "p_approve",
                label: "Decision",
                required: true,
                choices: [
                  { value: "true", label: "Approve" },
                  { value: "false", label: "Refuse" },
                ],
              },
              {
                kind: "text",
                name: "p_comment",
                label: "Comment",
                placeholder: "Recounted, the shortage is real",
              },
            ],
            mapArgs: (v) => ({
              p_task_id: v["p_task_id"],
              p_approve: v["p_approve"] === "true",
              ...(v["p_comment"] ? { p_comment: v["p_comment"] } : {}),
            }),
            invalidates: [...invalidates, "erp_my_approvals"],
            submitLabel: "Record the decision",
          },
          {
            // inventory.count_posting (20260927300000): whether a count inside
            // tolerance posts as it is recorded, per company or site.
            label: "Propose the count posting policy",
            description:
              "Whether a count inside its tolerance posts itself as it is recorded or waits for somebody to post it, and whether the counter's own does once the organisation is live. The tolerance is the counting programme's, in units or a share of the units expected, with no threshold by value. Proposed as a change like any other configuration.",
            permission: "administration.configure",
            fn: "erp_propose_count_posting_policy",
            mapArgs: countPostingArgs,
            fields: [
              {
                kind: "select",
                name: "p_entity_code",
                label: "Company",
                options: { fn: "erp_entities", value: "code", label: ["code", "name"] },
                hint: "Leave unchosen to set the policy for the whole organisation.",
              },
              {
                kind: "select",
                name: "p_site_code",
                label: "Site",
                options: { fn: "erp_sites", value: "code", label: ["code", "name"] },
                hint: "Leave unchosen to apply the policy across the whole company.",
              },
              {
                kind: "choice",
                name: "within_tolerance",
                label: "A count inside tolerance",
                choices: [
                  { value: "post", label: "Posts as it is recorded" },
                  { value: "hold", label: "Waits for somebody to post it" },
                ],
                hint: "Hold waits for somebody who may adjust stock to post each count, as outside tolerance. Left unchosen, the broader setting applies.",
              },
              {
                kind: "choice",
                name: "self_post_within_tolerance",
                label: "The counter's own count inside tolerance",
                boolean: true,
                choices: [
                  { value: "true", label: "Posts itself" },
                  { value: "false", label: "Waits for somebody else" },
                ],
                hint: "Once the organisation is live. Waits leaves the counter's own count for a second person, as every count outside tolerance is. Left unchosen, the broader setting applies.",
              },
              {
                ...pickChangeSet("p_change_set_id", "Add to an existing change", false),
                hint: "Leave unchosen to start a new change for this proposal.",
              },
            ],
            invalidates: ["erp_change_sets"],
          },
        ]}
      />

      <CountWorklist />

      <DataPanel<AuditRow>
        title={ui("Balances by location")}
        description={ui(
          "Every active place at every site, whether or not anything stands in it, with the last count against it.",
        )}
        fn="erp_stock_audit"
        args={{ p_site_id: siteId || null }}
        empty={ui(
          "No locations to audit yet. Add locations under Warehouse layout, and receive stock into them, and each one is listed here with its balance.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Location"),
              ui("Kind"),
              ui("Products"),
              ui("On hand"),
              ui("Value"),
              ui("Last counted"),
              ui("Counted"),
              ui("Difference"),
              ui("Difference in value"),
              ui("State"),
            ]}
          >
            {rows.map((r) => (
              <tr key={r.location_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.site}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{r.location}</span>
                  {r.location_name ? (
                    <span className="ml-2 text-muted-foreground">{r.location_name}</span>
                  ) : null}
                </td>
                <td className="py-2 pr-4">{r.location_type}</td>
                <td className="py-2 pr-4 tabular-nums">{r.products}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{formatMinor(r.value_minor, r.currency)}</td>
                <td className="py-2 pr-4">{day(r.last_counted_at)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(r.counted_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{signed(r.variance)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {r.variance_value_minor === 0
                    ? "—"
                    : formatMinor(r.variance_value_minor, r.currency)}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={stateTone(r.state)}>
                    {r.is_blocked ? ui("blocked") : ui(r.state)}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<AuditLine>
        title={ui("Balances by product within a location")}
        description={ui(
          "The same audit one line deeper: which product the quantity is, what it costs, and what the last count expected against what it found. Value in a bin is its share of the product's valuation at that site, not a separate cost.",
        )}
        fn="erp_stock_audit_lines"
        args={{ p_site_id: siteId || null }}
        empty={ui(
          "No stock standing anywhere and no counts raised. Receive a purchase order and put it away, and the lines appear here.",
        )}
      >
        {(rows) => (
          <Table
            columns={[
              ui("Site"),
              ui("Location"),
              ui("Product"),
              ui("On hand"),
              ui("Unit cost"),
              ui("Value"),
              ui("Expected"),
              ui("Counted"),
              ui("Difference"),
              ui("Last counted"),
              ui("Count"),
            ]}
          >
            {rows.map((l) => (
              <tr
                key={`${l.location_code}:${l.item_code}`}
                className="border-b border-border/60 last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{l.site_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.location_code}</td>
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs">{l.item_code}</span>
                  {l.item_name ? (
                    <span className="ml-2 text-muted-foreground">{l.item_name}</span>
                  ) : null}
                </td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">
                  {formatMinor(l.unit_cost_minor, l.currency)}
                </td>
                <td className="py-2 pr-4 tabular-nums">{formatMinor(l.value_minor, l.currency)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.expected_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{qty(l.counted_quantity)}</td>
                <td className="py-2 pr-4 tabular-nums">{signed(l.variance)}</td>
                <td className="py-2 pr-4">{day(l.last_counted_at)}</td>
                <td className="py-2 pr-4">
                  {l.count_status ? (
                    <Pill tone={l.variance ? "bad" : "muted"}>{l.count_status}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("never counted")}</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
