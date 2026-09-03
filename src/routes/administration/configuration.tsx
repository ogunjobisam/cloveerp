import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { ActionButton, ErrorNote, PermissionNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";

/**
 * Installing configuration, from the app.
 *
 * Every function this screen calls was already on the public API and reachable
 * from nothing. That is the whole gap it closes: the database could author,
 * approve and promote a change set, and the only way to ask it to was a SQL
 * client.
 *
 * Nothing here is a shortcut around B6. A module installer authors a change set
 * and submits it; approval and promotion are separate calls with separate
 * permissions, and the database refuses a self-approval on a live tenant no
 * matter what this screen offers. The screen's job is to make the sequence
 * visible, not to shorten it.
 */

export const Route = createFileRoute("/administration/configuration")({
  head: () => ({
    meta: [
      { title: "Configuration — Clove ERP" },
      {
        name: "description",
        content: "Install module configuration and promote change sets for a tenant.",
      },
      { property: "og:title", content: "Configuration — Clove ERP" },
      {
        property: "og:description",
        content: "Install module configuration and promote change sets for a tenant.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Configuration />
    </Gate>
  ),
});

type ChangeSet = {
  change_set_id: string;
  code: string;
  name: string;
  status: string;
  created_at: string;
  authored_by: string | null;
  /** The database's own answer to "may I approve this?" — the author may not. */
  is_own: boolean;
};

/**
 * A numeric knob on an installer.
 *
 * Every installer's parameters have defaults, so all fourteen can be called with
 * no arguments at all. These are offered only where the default is a business
 * decision somebody might reasonably want to make differently on the way in.
 */
type Param = { name: string; label: string; suffix?: string; initial: string };

type Module = {
  fn: string;
  name: string;
  blurb: string;
  param?: Param;
};

/**
 * The fourteen installers, in the order a tenant would sensibly run them:
 * the ledger and the item master first, because the things below post to them.
 */
const MODULES: Module[] = [
  {
    fn: "erp_configure_finance",
    name: "Finance",
    blurb:
      "Ledger, chart of accounts, fiscal periods and the posting rules documents post through.",
    param: { name: "p_fiscal_year", label: "Fiscal year", initial: "" },
  },
  {
    fn: "erp_configure_master_data",
    name: "Master data",
    blurb: "Change requests, field approval rules and data-quality scoring.",
  },
  {
    fn: "erp_configure_inventory",
    name: "Inventory",
    blurb: "Costing policy, stock valuation layers and counting programmes.",
  },
  {
    fn: "erp_configure_procurement",
    name: "Procurement",
    blurb:
      "Requisition, purchase order and goods receipt lifecycles, with a value-banded approval chain.",
    param: {
      name: "p_approval_threshold_minor",
      label: "Approval threshold",
      suffix: "minor units",
      initial: "1000000",
    },
  },
  {
    fn: "erp_configure_procurement_controls",
    name: "Procurement controls",
    blurb: "Three-way matching tolerances, GRNI and landed cost.",
  },
  {
    fn: "erp_configure_sales",
    name: "Sales",
    blurb:
      "Quotation, sales order and delivery lifecycles. A discount above the threshold needs approving.",
    param: {
      name: "p_discount_threshold_pct",
      label: "Discount threshold",
      suffix: "%",
      initial: "15",
    },
  },
  {
    fn: "erp_configure_sales_controls",
    name: "Sales controls",
    blurb: "Pricing policy, credit limits and margin floors.",
    param: { name: "p_min_margin_pct", label: "Minimum margin", suffix: "%", initial: "10" },
  },
  {
    fn: "erp_configure_receivables",
    name: "Receivables",
    blurb: "Invoicing, cash application and dunning.",
  },
  {
    fn: "erp_configure_tax",
    name: "Tax",
    blurb: "Home country and the standard rate used to determine tax on a document.",
    param: { name: "p_standard_rate", label: "Standard rate", suffix: "%", initial: "20" },
  },
  {
    fn: "erp_configure_period_close",
    name: "Period close",
    blurb: "The close checklist and the tasks that must pass before a period can shut.",
  },
  {
    fn: "erp_configure_planning",
    name: "Planning",
    blurb: "Forecasting, planning policy and the MRP/DRP run.",
    param: { name: "p_service_level_pct", label: "Service level", suffix: "%", initial: "95" },
  },
  {
    fn: "erp_configure_production",
    name: "Production",
    blurb: "Works orders, operations, batch records and production costing.",
  },
  {
    fn: "erp_configure_quality",
    name: "Quality",
    blurb: "Inspection plans, quality events, release records and recall readiness.",
  },
  {
    fn: "erp_configure_logistics",
    name: "Logistics",
    blurb: "Shipments, carrier selection and proof of delivery.",
  },
];

/**
 * Installers disagree about their return type — some hand back a bare uuid,
 * some a jsonb object carrying `change_set_id`. Both mean the same thing, and
 * the screen should not care which one it got.
 */
function changeSetIdOf(result: unknown): string | null {
  if (typeof result === "string") return result;
  if (result && typeof result === "object") {
    const v = (result as Record<string, unknown>)["change_set_id"];
    if (typeof v === "string") return v;
  }
  return null;
}

function statusTone(status: string): "ok" | "warn" | "muted" {
  if (status === "promoted") return "ok";
  if (status === "ready" || status === "approved") return "warn";
  return "muted";
}

function Configuration() {
  const { session } = useErpSession();
  const queryClient = useQueryClient();

  const allowed = hasPermission(session, "administration.configure");

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_change_sets"],
    queryFn: () => callErp<ChangeSet[]>("erp_change_sets"),
    enabled: allowed,
  });

  // A promotion changes what every other screen can show — document types,
  // posting rules, jobs. Nothing is scoped enough to invalidate selectively.
  const invalidate = () => queryClient.invalidateQueries();

  if (!allowed) {
    return (
      <div className="flex min-w-0 flex-col gap-6">
        <PageHeader title="Configuration">
          Installing a module authors a change set; promoting it puts the configuration in force.
        </PageHeader>
        <PermissionNote code="administration.configure" />
      </div>
    );
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Configuration">
        A module is content, not code: installing one authors a change set of rules, lifecycles and
        approval chains, and promoting that set is what puts them in force.
      </PageHeader>

      <BootstrapNotice sets={data ?? []} />

      <ModulesPanel onDone={invalidate} />

      {isPending ? (
        <p className="text-sm text-muted-foreground">Loading change sets…</p>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-border bg-card p-5">
          <p className="text-sm font-medium text-destructive">Change sets did not load.</p>
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
        </div>
      ) : (
        <ChangeSetsPanel sets={data ?? []} onDone={invalidate} />
      )}
    </div>
  );
}

/**
 * Explaining the bootstrap window without claiming to know which side of it you
 * are on.
 *
 * Nothing on the public API reports whether the tenant has gone live, so the
 * screen states the rule and lets the change-set list speak for the state: a set
 * sitting at `ready` is a set B6 is holding for a second person.
 */
function BootstrapNotice({ sets }: { sets: ChangeSet[] }) {
  const waiting = sets.filter((s) => s.status === "ready" || s.status === "approved");

  return (
    <section className="min-w-0 rounded-xl border border-dashed border-border bg-card/50 p-4 sm:p-5">
      <h2 className="text-sm font-semibold">Before and after go-live</h2>
      <Prose className="mt-1 text-xs text-muted-foreground">
        While an organisation is still being built, an installer approves and promotes its own
        change set — there is nobody else to ask, and requiring a second person would make a new
        organisation impossible to configure. Once you go live, separation of duties applies: the
        author of a change set may not approve it, so a second administrator is required.
      </Prose>
      {waiting.length > 0 ? (
        <p className="mt-3 text-xs text-muted-foreground">
          <span className="font-medium text-foreground">
            {waiting.length} change {waiting.length === 1 ? "set is" : "sets are"} waiting
          </span>{" "}
          — this organisation is live, so those need a second administrator.
        </p>
      ) : null}
    </section>
  );
}

function ModulesPanel({ onDone }: { onDone: () => void }) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Modules ({MODULES.length})</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          A module is installed once. Its change set is named after it, so asking again is refused
          rather than quietly configuring the same thing twice — open Change requests to see what
          the first install proposed. Finance first: everything that posts needs a ledger to post
          to.
        </Prose>
      </header>
      <div className="grid grid-cols-1 gap-3 px-4 py-4 sm:px-5 md:grid-cols-2 xl:grid-cols-3">
        {MODULES.map((m) => (
          <ModuleCard key={m.fn} module={m} onDone={onDone} />
        ))}
      </div>
    </section>
  );
}

function ModuleCard({ module: m, onDone }: { module: Module; onDone: () => void }) {
  const [value, setValue] = useState(m.param?.initial ?? "");
  const [error, setError] = useState<unknown>(null);
  const [outcome, setOutcome] = useState<string | null>(null);

  const install = useMutation({
    mutationFn: async () => {
      const args: Record<string, unknown> = {};
      if (m.param && value.trim() !== "") args[m.param.name] = Number(value);
      const result = await callErp<unknown>(m.fn, args);
      const id = changeSetIdOf(result);
      // Read the set back rather than assuming: whether it promoted or stopped
      // at `ready` is the bootstrap window answering, and it is the one thing
      // worth reporting.
      const sets = await callErp<ChangeSet[]>("erp_change_sets");
      return sets.find((s) => s.change_set_id === id) ?? null;
    },
    onSuccess: (set) => {
      setError(null);
      setOutcome(
        set === null
          ? "Installed."
          : set.status === "promoted"
            ? "Installed and promoted — the configuration is in force."
            : `Change set authored and left at "${set.status}" — it needs a second administrator to approve.`,
      );
      onDone();
    },
    onError: (e) => {
      setOutcome(null);
      setError(e);
    },
  });

  return (
    <div className="flex min-w-0 flex-col rounded-lg border border-border p-3">
      <h3 className="text-sm font-medium">{m.name}</h3>
      <Prose className="mt-0.5 text-xs text-muted-foreground">{m.blurb}</Prose>

      <div className="mt-3 flex flex-wrap items-end gap-2">
        {m.param ? (
          <label className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
              {m.param.label}
              {m.param.suffix ? ` (${m.param.suffix})` : ""}
            </span>
            <input
              type="number"
              inputMode="decimal"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="default"
              className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
            />
          </label>
        ) : null}

        <ActionButton
          onClick={() => {
            setError(null);
            setOutcome(null);
            install.mutate();
          }}
          busy={install.isPending}
        >
          {install.isPending ? "Installing…" : "Install"}
        </ActionButton>
      </div>

      {outcome ? <p className="mt-2 text-xs text-muted-foreground">{outcome}</p> : null}
      {/* configure_sales refuses with ERPWARE_NO_LEDGER and a hint naming
          erp.configure_finance(). That hint is the whole answer, and the old
          markup dropped it. */}
      {error ? (
        <div className="mt-2">
          <ErrorNote error={error} />
        </div>
      ) : null}
    </div>
  );
}

function ChangeSetsPanel({ sets, onDone }: { sets: ChangeSet[]; onDone: () => void }) {
  const [error, setError] = useState<unknown>(null);

  const approve = useMutation({
    mutationFn: (id: string) => callErp("erp_approve_change_set", { p_change_set_id: id }),
    onSuccess: () => {
      setError(null);
      onDone();
    },
    onError: (e) => setError(e),
  });

  const promote = useMutation({
    mutationFn: (id: string) => callErp("erp_promote_change_set", { p_change_set_id: id }),
    onSuccess: () => {
      setError(null);
      onDone();
    },
    onError: (e) => setError(e),
  });

  const busy = approve.isPending || promote.isPending;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Change sets ({sets.length})</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Approval and promotion are separate steps because they answer different questions: whether
          the change is wanted, and whether now is the moment to put it in force.
        </Prose>
      </header>

      <div className="w-full max-w-full overflow-x-auto px-4 py-4 sm:px-5">
        {sets.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No change sets yet. Installing a module above authors the first one.
          </p>
        ) : (
          <Table columns={["Set", "Author", "Status", "Created", ""]}>
            {sets.map((s) => (
              <tr key={s.change_set_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4">
                  <span className="font-mono text-xs text-muted-foreground">{s.code}</span> {s.name}
                </td>
                <td className="py-2 pr-4 text-muted-foreground">{s.authored_by ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={statusTone(s.status)}>{s.status}</Pill>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {new Date(s.created_at).toLocaleString()}
                </td>
                <td className="py-2 pr-4">
                  <div className="flex flex-wrap gap-2">
                    {s.status === "ready" ? (
                      <ActionButton
                        variant="secondary"
                        onClick={() => approve.mutate(s.change_set_id)}
                        disabled={busy || s.is_own}
                        title={
                          s.is_own
                            ? "You authored this change set, so you may not approve it."
                            : undefined
                        }
                      >
                        Approve
                      </ActionButton>
                    ) : null}
                    {s.status === "approved" ? (
                      <ActionButton onClick={() => promote.mutate(s.change_set_id)} disabled={busy}>
                        Promote
                      </ActionButton>
                    ) : null}
                    {s.status === "ready" && s.is_own ? (
                      <span className="self-center text-xs text-muted-foreground">
                        yours — needs another administrator
                      </span>
                    ) : null}
                  </div>
                </td>
              </tr>
            ))}
          </Table>
        )}

        {error ? (
          <div className="mt-3">
            <ErrorNote error={error} />
          </div>
        ) : null}
      </div>
    </section>
  );
}
