import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { ActionButton, ErrorNote, PermissionNote } from "../../components/erp/action";
import { ActionBar, codeField, pickFrom, reason } from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";
import { prettifyField } from "../../lib/friendly";
import { useT } from "../../lib/i18n";
import { toMinor } from "../../lib/money";
import { permissionName } from "../../lib/permission-name";

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

/** One row of erp_module_installations(): what this organisation holds. */
type ModuleInstallation = {
  install_code: string;
  module_code: string;
  installer_version: number;
  current_version: number;
  upgrade_available: boolean;
  installed_at: string | null;
};

/**
 * The erp_ref.reason_category codes, as seeded. The writers refuse anything
 * else, and a new category is a product change rather than a row, so a fixed
 * list is the honest control.
 */
const REASON_CATEGORIES = [
  { value: "STOCK_ADJUSTMENT", label: "Stock adjustment" },
  { value: "SCRAP", label: "Scrap and destruction" },
  { value: "RETURN_SUPPLIER", label: "Return to supplier" },
  { value: "RETURN_CUSTOMER", label: "Customer return" },
  { value: "ORDER_HOLD", label: "Order hold" },
  { value: "ORDER_CANCEL", label: "Order cancellation" },
  { value: "APPROVAL_REJECT", label: "Approval rejection" },
  { value: "BATCH_AMENDMENT", label: "Batch amendment" },
  { value: "ALLOCATION_OVERRIDE", label: "Allocation override" },
  { value: "PRICE_OVERRIDE", label: "Price and discount override" },
  { value: "PERIOD_REOPEN", label: "Period reopen" },
];

export const Route = createFileRoute("/administration/configuration")({
  // ?change=<id> arrives from the onboarding interview, so the change a person
  // was just told about is the row they see first. Optional, so every existing
  // link to this screen stays valid without it.
  validateSearch: (search: Record<string, unknown>): { change?: string } =>
    typeof search["change"] === "string" && search["change"] !== ""
      ? { change: search["change"] }
      : {},
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
  is_own: boolean;
  /**
   * The database's own answer to "may I approve this?": false only once the
   * organisation is live and the caller authored the change. Before go-live
   * there is nobody else to ask, and the database lets the author approve.
   */
  may_approve?: boolean;
};

/** A reader that predates may_approve falls back to the stricter rule. */
function mayApprove(s: ChangeSet): boolean {
  return s.may_approve ?? !s.is_own;
}

/**
 * A numeric knob on an installer.
 *
 * Every installer's parameters have defaults, so all fourteen can be called with
 * no arguments at all. These are offered only where the default is a business
 * decision somebody might reasonably want to make differently on the way in.
 */
type Param = {
  name: string;
  label: string;
  suffix?: string;
  initial: string;
  /** An amount: typed in pounds and pence, sent in the minor units the door takes. */
  money?: boolean;
};

/**
 * The role an installer asks to approve. Left on the default, the database
 * takes `preferred` where somebody holds it and administrator otherwise.
 */
type RoleParam = { name: string; label: string; preferred: string };

type Module = {
  fn: string;
  name: string;
  blurb: string;
  param?: Param;
  role?: RoleParam;
  /**
   * The permission the installer asks for on top of administration.configure,
   * which this whole screen already needs. The database refuses without it
   * whatever the card offers; the card says so first, and says who holds it.
   */
  permission?: string;
  /** Who can install it, shown to a reader who does not hold that permission. */
  whoCan?: string;
};

/** One row of erp_roles(). */
type RoleOption = { role_id: string; code: string; name: string };

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
    // erp.configure_finance() authorises finance.configure, and the change set
    // it raises authorises administration.configure: installing finance takes
    // both, and keeping the set-up of the ledger with finance is deliberate.
    permission: "finance.configure",
    whoCan:
      "Installing finance takes two permissions held by the same person: configuring finance and configuring administration. The finance manager role carries the first, so an administrator who also holds that role can install finance.",
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
      suffix: "GBP",
      initial: "10000",
      money: true,
    },
    role: { name: "p_approver_role", label: "Approver role", preferred: "procurement_manager" },
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
    role: { name: "p_approver_role", label: "Approver role", preferred: "sales_manager" },
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
  const { change } = Route.useSearch();

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
        <ChangeSetsPanel sets={data ?? []} onDone={invalidate} highlight={change ?? null} />
      )}

      <DataPanel<ModuleInstallation>
        title="Installed modules"
        description="What this organisation has installed, the version it holds, and whether the product ships a later one. An organisation configured before an installer changed keeps what it was given until it is upgraded."
        fn="erp_module_installations"
        empty="No module has been installed for this organisation yet."
      >
        {(rows) => (
          <Table columns={["Module", "Installed version", "Current", "Upgrade", "Installed"]}>
            {rows.map((r) => (
              <tr key={r.install_code} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.install_code}</td>
                <td className="py-2 pr-4">{r.installer_version}</td>
                <td className="py-2 pr-4">{r.current_version}</td>
                <td className="py-2 pr-4">
                  {r.upgrade_available ? (
                    <Pill tone="warn">Available</Pill>
                  ) : (
                    <span className="text-muted-foreground">Up to date</span>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.installed_at ? new Date(r.installed_at).toLocaleDateString() : "—"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <ActionBar
        title="Module upgrades"
        note="What a later version of an installer would add that this organisation does not hold. The upgrade is a change like any other: promoted at once where the environment is not live, and left for a second administrator where it is."
        actions={[
          {
            label: "What an upgrade would add",
            permission: "administration.read",
            fn: "erp_module_upgrade_plan",
            fields: [
              pickFrom(
                "erp_module_installations",
                "install_code",
                ["install_code", "module_code"],
                "p_install_code",
                "Module",
              ),
            ],
          },
          {
            label: "Upgrade a module's configuration",
            description:
              "Raises the change that brings this organisation up to the installer's current version.",
            permission: "administration.configure",
            fn: "erp_upgrade_module_configuration",
            fields: [
              pickFrom(
                "erp_module_installations",
                "install_code",
                ["install_code", "module_code"],
                "p_install_code",
                "Module",
              ),
            ],
            invalidates: ["erp_module_installations", "erp_change_sets"],
          },
        ]}
      />

      <ActionBar
        title="Changes and snapshots"
        note="A change is submitted for approval by hand when its author is done; a promoted snapshot can be rolled back to, with a reason, when a promotion turns out wrong."
        actions={[
          {
            label: "Submit a change for approval",
            permission: "administration.configure",
            fn: "erp_submit_change_set",
            fields: [
              pickFrom(
                "erp_change_sets",
                "change_set_id",
                ["code", "status"],
                "p_change_set_id",
                "Change set",
              ),
            ],
            invalidates: ["erp_change_sets"],
          },
          {
            label: "Roll back to a snapshot",
            description:
              "Restores the configuration a promotion took a snapshot of. The reason is kept with the rollback.",
            // The door authorises administration.promote: rolling a promotion
            // back is the promoter's act, as promoting was.
            permission: "administration.promote",
            fn: "erp_rollback_to_snapshot",
            fields: [
              pickFrom(
                "erp_config_snapshots",
                "snapshot_id",
                ["code", "change_code", "taken"],
                "p_snapshot_id",
                "Snapshot",
              ),
              reason("p_reason", "Reason", true),
            ],
            invalidates: ["erp_change_sets", "erp_config_snapshots"],
          },
        ]}
      />

      <ActionBar
        title="Reason codes"
        note="Why something happened, from a list the organisation maintains: a return, a write-off, a price override. A code can insist on a note or an approval."
        actions={[
          {
            label: "Add or amend a reason code",
            permission: "administration.configure",
            fn: "erp_upsert_reason_code",
            fields: [
              {
                kind: "choice",
                name: "p_category",
                label: "Category",
                required: true,
                hint: "The kind of action this reason belongs to.",
                choices: REASON_CATEGORIES,
              },
              // Codes are unique per category, so the same code may be listed
              // under two of them; the pick cannot follow the category above.
              codeField("p_code", "Code", "DAMAGED", {
                fn: "erp_reason_codes",
                value: "code",
                label: ["category", "code", "name"],
              }),
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Damaged in transit",
                hint: "What the reason means in plain words.",
              },
              {
                kind: "choice",
                name: "p_requires_note",
                label: "Requires a note",
                required: true,
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
              },
              {
                kind: "choice",
                name: "p_requires_approval",
                label: "Requires approval",
                required: true,
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
              },
              { kind: "number", name: "p_seq", label: "Order" },
            ],
            invalidates: ["erp_reason_codes"],
          },
          {
            label: "Switch a reason code on or off",
            permission: "administration.configure",
            fn: "erp_set_reason_code_status",
            fields: [
              {
                kind: "choice",
                name: "p_category",
                label: "Category",
                required: true,
                hint: "The kind of action this reason belongs to.",
                choices: REASON_CATEGORIES,
              },
              {
                // A combo, not a select: a code can sit under two categories,
                // and a select keyed by code would offer two identical options.
                kind: "combo",
                name: "p_code",
                label: "Code",
                required: true,
                placeholder: "DAMAGED",
                hint: "The reason code to switch.",
                options: {
                  fn: "erp_reason_codes",
                  value: "code",
                  label: ["category", "code", "name"],
                },
              },
              {
                kind: "choice",
                name: "p_active",
                label: "Active",
                required: true,
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
            ],
            invalidates: ["erp_reason_codes"],
          },
        ]}
      />

      <AutoPanel
        title="Reason codes"
        description="Every reason code by category, and what it insists on."
        fn="erp_reason_codes"
        empty="No reason codes yet. The base pack ships a starter set when it is applied; add one above."
        rowKey={(r, i) => `${String(r["category"] ?? i)}-${String(r["code"] ?? i)}`}
        columns={[
          { header: "Category", cell: "category" },
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Needs a note", cell: "requires_note" },
          { header: "Needs approval", cell: "requires_approval" },
          { header: "Status", cell: (r) => <StatusPill value={r["status"]} /> },
        ]}
      />
    </div>
  );
}

/**
 * Explaining the bootstrap window from what the database says about each row.
 *
 * Each change carries may_approve, so the screen no longer guesses whether the
 * organisation is live: a waiting change the reader authored and may not
 * approve is one the database is holding for a second administrator, and a
 * waiting change the reader may approve is simply waiting for them.
 */
function BootstrapNotice({ sets }: { sets: ChangeSet[] }) {
  const { ui } = useT();
  const waiting = sets.filter((s) => s.status === "ready" || s.status === "approved");
  const heldForSomeoneElse = waiting.filter((s) => s.status === "ready" && !mayApprove(s));

  return (
    <section className="min-w-0 rounded-xl border border-dashed border-border bg-card/50 p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Before and after go-live")}</h2>
      <Prose className="mt-1 text-xs text-muted-foreground">
        {ui(
          "While an organisation is still being set up, whoever makes a change can approve it and put it in force: there is nobody else to ask yet. Once the organisation is live, the person who made a change may not approve it, so a second administrator does.",
        )}
      </Prose>
      {waiting.length > 0 ? (
        <p className="mt-3 text-xs text-muted-foreground">
          <span className="font-medium text-foreground">
            {ui("Changes waiting")}: {waiting.length}
          </span>{" "}
          —{" "}
          {heldForSomeoneElse.length > 0
            ? ui(
                "this organisation is live, and the ones you made need another administrator to approve them.",
              )
            : ui("approve them and put them in force below.")}
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
  const { session } = useErpSession();
  // Convenience only: the database refuses inside the installer whatever this says.
  const permitted = m.permission === undefined || hasPermission(session, m.permission);
  const { resources } = useT();
  const [value, setValue] = useState(m.param?.initial ?? "");
  // Empty is the database's default approver role, not a missing answer.
  const [role, setRole] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [outcome, setOutcome] = useState<string | null>(null);

  const install = useMutation({
    mutationFn: async () => {
      const args: Record<string, unknown> = {};
      if (m.param && value.trim() !== "")
        args[m.param.name] = m.param.money ? toMinor(value) : Number(value);
      if (m.role && role !== "") args[m.role.name] = role;
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
              step={m.param.money ? "any" : undefined}
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder="default"
              className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
            />
          </label>
        ) : null}

        {m.role ? <ApproverRolePicker role={m.role} value={role} onChange={setRole} /> : null}

        <ActionButton
          onClick={() => {
            setError(null);
            setOutcome(null);
            install.mutate();
          }}
          busy={install.isPending}
          disabled={!permitted}
          title={
            permitted || m.permission === undefined
              ? undefined
              : `Requires ${permissionName(m.permission, resources)}`
          }
        >
          {install.isPending ? "Installing…" : "Install"}
        </ActionButton>
      </div>

      {!permitted && m.whoCan ? (
        <p className="mt-2 text-xs text-muted-foreground">{m.whoCan}</p>
      ) : null}
      {outcome ? <p className="mt-2 text-xs text-muted-foreground">{outcome}</p> : null}
      {/* configure_sales refuses with CLOVEERP_NO_LEDGER and a hint naming
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

/**
 * A role by its name: the organisation's own where it has the role, and the
 * code as words where it has not, never the code itself.
 */
function roleName(roles: RoleOption[] | undefined, code: string): string {
  return roles?.find((r) => r.code === code)?.name ?? prettifyField(code);
}

/**
 * Who is asked to approve what a module raises.
 *
 * The organisation's own roles, from erp_roles. Left on the default the
 * database picks the operational role where somebody holds it, and
 * administrator otherwise; the person who submits a document is never the one
 * asked to approve it.
 */
function ApproverRolePicker({
  role,
  value,
  onChange,
}: {
  role: RoleParam;
  value: string;
  onChange: (code: string) => void;
}) {
  const roles = useQuery({
    queryKey: ["erp_roles"],
    queryFn: () => callErp<RoleOption[]>("erp_roles"),
  });

  return (
    <label className="flex min-w-0 flex-1 flex-col gap-1">
      <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {role.label}
      </span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={roles.isPending}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
      >
        <option value="">
          {`Default: ${roleName(roles.data, role.preferred)}, or ${roleName(roles.data, "administrator")}`}
        </option>
        {(roles.data ?? []).map((r) => (
          <option key={r.role_id} value={r.code}>
            {r.name}
          </option>
        ))}
      </select>
    </label>
  );
}

function ChangeSetsPanel({
  sets,
  onDone,
  highlight,
}: {
  sets: ChangeSet[];
  onDone: () => void;
  highlight: string | null;
}) {
  const { ui } = useT();
  const [error, setError] = useState<unknown>(null);
  const highlighted = highlight !== null && sets.some((s) => s.change_set_id === highlight);

  // Bring the change a link pointed at into view once, when it is on the list.
  useEffect(() => {
    if (!highlighted || highlight === null) return;
    document
      .getElementById(`change-${highlight}`)
      ?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [highlight, highlighted]);

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
        {highlight !== null && !highlighted && sets.length > 0 ? (
          <p className="mb-3 text-xs text-muted-foreground">
            {ui("The change you followed a link to is not on this list.")}
          </p>
        ) : null}
        {sets.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No change sets yet. Installing a module above authors the first one.
          </p>
        ) : (
          <Table columns={["Set", "Author", "Status", "Created", ""]}>
            {sets.map((s) => (
              <tr
                key={s.change_set_id}
                id={`change-${s.change_set_id}`}
                aria-current={s.change_set_id === highlight ? "true" : undefined}
                className={`border-b border-border/50 last:border-0 ${
                  s.change_set_id === highlight
                    ? "bg-accent/10 outline outline-2 outline-accent"
                    : ""
                }`}
              >
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
                        disabled={busy || !mayApprove(s)}
                        title={
                          mayApprove(s)
                            ? undefined
                            : ui("You made this change, so another administrator approves it.")
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
                    {s.status === "ready" && !mayApprove(s) ? (
                      <span className="self-center text-xs text-muted-foreground">
                        {ui("Yours — another administrator approves it")}
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
