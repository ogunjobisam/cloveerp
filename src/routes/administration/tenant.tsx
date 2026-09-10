import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useRef, useState } from "react";

import { ErrorNote, PermissionNote, useErpAction } from "../../components/erp/action";
import { ActionBar, type ActionSpec } from "../../components/erp/actions-bar";
import { AutoPanel, StatusPill, shortDate } from "../../components/erp/auto";
import { BrandingPanel } from "../../components/erp/branding";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose } from "../../components/erp/page";
import { RpcButton } from "../../components/erp/rpc-button";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/administration/tenant")({
  head: () => ({
    meta: [
      { title: "Organisation lifecycle — Clove ERP" },
      {
        name: "description",
        content:
          "Go-live readiness, organisation data export and portability, and deletion that removes the data rather than promising to.",
      },
      { property: "og:title", content: "Organisation lifecycle — Clove ERP" },
      {
        property: "og:description",
        content: "Go-live, export and portability, and deletion that deletes.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <TenantLifecycle />
    </Gate>
  ),
});

function TenantLifecycle() {
  const { t } = useT();
  const { session } = useErpSession();
  const mayAdminister = hasPermission(session, "administration.configure");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.tenant_lifecycle", "Organisation lifecycle")}>
        Everything here acts on{" "}
        <strong className="font-semibold text-foreground">
          {session.tenant?.name ?? "the organisation you are signed in to"}
        </strong>
        {session.tenant?.code ? (
          <span className="font-mono text-xs text-muted-foreground"> ({session.tenant.code})</span>
        ) : null}{" "}
        and nothing else — every other organisation on this deployment is reached from the platform
        console. An organisation is not only rows: it starts (go-live), it can leave (export), and
        it can end — and each of those is an operation with a record rather than a support request.
      </PageHeader>

      {mayAdminister ? null : <PermissionNote code="administration.configure" />}

      <section className="rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">Go-live</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Going live freezes the organisation identifier and turns on the controls that only make
            sense against real data. It reports what is still missing rather than refusing silently.
          </Prose>
        </header>
        <div className="px-4 py-4 sm:px-5">
          <RpcButton
            label="Run go-live checks"
            fn="erp_go_live"
            permission="administration.configure"
            variant="primary"
            invalidates={["erp_session", "erp_platform_assurance"]}
          />
        </div>
      </section>

      {mayAdminister ? <BrandingPanel /> : null}

      <EncryptionKeysPanel />

      <DemoHistoryPanel />

      <ExportPanel />

      <section className="rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">Deletion</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Requesting deletion suspends this organisation immediately. Terminology overrides,
            cached material and — decisively — its encryption keys are destroyed at request time, so
            anything encrypted under them is unreadable from that moment. Its remaining rows are not
            removed here: that is a separate, deliberate step performed by a platform owner, which
            is what gives a mistaken request time to be caught.
          </Prose>
        </header>
        <div className="px-4 py-4 sm:px-5">
          <RpcButton
            label="Request deletion"
            fn="erp_request_tenant_deletion"
            permission="administration.configure"
            confirm="Suspend this organisation and destroy its encryption keys? The keys cannot be recovered. Export first if the data is wanted."
            invalidates={["erp_session", "erp_my_tenants"]}
          />
        </div>
      </section>

      <AutoPanel
        title="Platform assurance"
        description="What the platform itself says about this organisation's configuration and isolation."
        fn="erp_platform_assurance"
        loading="Running every check against this database. This takes up to a minute."
        empty="No assurance checks reported. That is itself unexpected — the platform runs these against every organisation."

        rowKey={(r, i) => `${String(r["code"] ?? i)}-${i}`}
        columns={[
          // check_code / state / result were none of them keys this RPC returns,
          // so two of these three columns had always rendered blank.
          { header: "Check", cell: (r) => String(r["title"] ?? r["check"] ?? "") },
          {
            header: "Result",
            cell: (r) =>
              r["ok"] === null ? (
                <StatusPill value="not run" />
              ) : (
                <StatusPill value={r["ok"] ? "holds" : "violated"} />
              ),
          },
          { header: "Detail", cell: (r) => String(r["summary"] ?? r["detail"] ?? "—") },
        ]}
      />
    </div>
  );
}

/**
 * Keys.
 *
 * An organisation's confidential material is encrypted under a key that
 * belongs to that organisation alone. Rotation re-protects what is stored and then destroys the
 * superseded key; deletion destroys every key outright. Destruction is the
 * point — after it, the ciphertext is unreadable by anybody, including us,
 * which is the only version of "deleted" that can be demonstrated rather than
 * promised.
 */
function EncryptionKeysPanel() {
  const rotate: ActionSpec = {
    label: "Rotate the key",
    title: "Rotate this organisation's encryption key",
    description:
      "A new key is created, everything protected is re-encrypted under it, and the old key is destroyed. There is no way back to the old key afterwards.",
    permission: "administration.configure",
    fn: "erp_rotate_tenant_key",
    fields: [
      {
        kind: "text",
        name: "p_purpose",
        label: "Purpose",
        hint: "Leave as tenant_data unless a separate key is in use.",
      },
      {
        kind: "text",
        name: "p_reason",
        label: "Reason",
        required: true,
        placeholder: "Scheduled annual rotation",
        hint: "Recorded permanently against the key.",
      },
    ],
    invalidates: ["erp_tenant_keys", "erp_protected_values"],
    submitLabel: "Rotate and destroy the old key",
  };

  return (
    <section className="flex min-w-0 flex-col gap-4 rounded-xl border border-border bg-card p-4 sm:p-5">
      <header>
        <h2 className="text-sm font-semibold">Encryption keys</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Confidential material is encrypted under this organisation's own key, held in the platform
          key store rather than in the database. Rotating or deleting destroys the previous key
          irreversibly.
        </Prose>
      </header>

      <ActionBar actions={[rotate]} />

      <AutoPanel
        title="Key register"
        description="Every key this organisation has held, and what became of it."
        fn="erp_tenant_keys"
        empty="No key has been issued yet. Rotate above to issue the first one; nothing can be stored encrypted until there is a key."
        rowKey={(r, i) => `${String(r["key_id"] ?? i)}`}
        columns={[
          { header: "Purpose", cell: "purpose" },
          { header: "Version", cell: "key_version", numeric: true },
          { header: "State", cell: (r) => <StatusPill value={r["state"]} /> },
          { header: "Activated", cell: (r) => shortDate(r["activated_at"]) },
          { header: "Destroyed", cell: (r) => shortDate(r["destroyed_at"]) },
          { header: "Witness", cell: "witness" },
          { header: "Protected values", cell: "protected_values", numeric: true },
        ]}
      />

      <AutoPanel
        title="Protected values"
        description="Stored encrypted under the key above; unreadable once it is destroyed."
        fn="erp_protected_values"
        empty="Nothing is stored under the key yet. A protected value is written by the feature that owns it, not from this screen."
        rowKey={(r, i) => `${String(r["code"] ?? i)}`}
        columns={[
          { header: "Name", cell: "code" },
          { header: "Key version", cell: "key_version", numeric: true },
          { header: "Updated", cell: (r) => shortDate(r["updated_at"]) },
        ]}
      />
    </section>
  );
}

/**
 * A year of trading, one week per call.
 *
 * Master data alone leaves every dashboard at zero, because a dashboard reads
 * movements, not records; and three documents dated today leave an ageing
 * report, a margin report and a stock ledger with nothing to draw. This builds
 * a year — purchase orders and receipts, sales orders, despatches, invoices and
 * cash, quotations and requisitions — through the same functions a person's
 * document goes through, so everything it writes reconciles exactly as a
 * customer's would.
 *
 * The database builds one week per call and says where the next call should
 * start; the button loops until it says it is done. That is what keeps each
 * call inside the statement timeout a signed-in user has, and what lets a call
 * that failed be repeated: a week that already exists is skipped, not
 * duplicated.
 */
type DemoHistoryStep = {
  done?: boolean;
  from?: string;
  to?: string;
  built_through?: string;
  next_from?: string | null;
  built?: number;
  notes?: unknown;
};

function DemoHistoryPanel() {
  const queryClient = useQueryClient();
  const building = useErpAction({ fn: "erp_seed_demo_history", invalidates: [] });
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<{
    from: string;
    to: string;
    through: string;
    documents: number;
  } | null>(null);
  const [notes, setNotes] = useState<string[]>([]);
  const stop = useRef(false);

  async function run() {
    stop.current = false;
    setRunning(true);
    setNotes([]);
    setProgress(null);
    let from: string | null = null;
    let documents = 0;
    try {
      for (;;) {
        const step = (await building.mutateAsync(from ? { p_from: from } : {})) as DemoHistoryStep;
        documents += Number(step.built ?? 0);
        if (step.from && step.to && step.built_through) {
          setProgress({ from: step.from, to: step.to, through: step.built_through, documents });
        }
        const fresh = Array.isArray(step.notes) ? step.notes.map(String) : [];
        if (fresh.length > 0) {
          setNotes((prior) => [...prior, ...fresh].slice(-6));
        }
        if (step.done || !step.next_from || stop.current) break;
        from = step.next_from;
      }
    } finally {
      setRunning(false);
      // Every list, dashboard and report on the site reads what was just
      // written; naming them one by one is how a screen stays stale.
      void queryClient.invalidateQueries();
    }
  }

  const percent =
    progress && progress.to > progress.from
      ? Math.min(
          100,
          Math.round(
            ((Date.parse(progress.through) - Date.parse(progress.from)) /
              (Date.parse(progress.to) - Date.parse(progress.from))) *
              100,
          ),
        )
      : null;

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Demonstration trading history</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Builds a year of purchasing, receipts, sales, despatches, invoices and cash, with the
          quotations and requisitions around them, so the dashboards, ageing, margin and the stock
          ledger have a year to show. One week is built per call and the button keeps calling until
          the year is done; a week that already exists is skipped. Refused in a live organisation.
        </Prose>
      </header>
      <div className="flex flex-col gap-3 px-4 py-4 sm:px-5">
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            className="min-h-11 w-fit rounded-md border border-input px-4 text-sm font-medium"
            disabled={running}
            onClick={() => void run()}
          >
            {running ? "Building…" : "Build a year of trading history"}
          </button>
          {running ? (
            <button
              type="button"
              className="min-h-11 w-fit rounded-md px-3 text-sm text-muted-foreground"
              onClick={() => {
                stop.current = true;
              }}
            >
              Stop after this week
            </button>
          ) : null}
        </div>
        {progress ? (
          <div className="flex flex-col gap-1 text-sm">
            <div className="h-2 w-full overflow-hidden rounded bg-muted" aria-hidden="true">
              <div
                className="h-full bg-primary transition-[width]"
                style={{ width: `${percent ?? 0}%` }}
              />
            </div>
            <p className="text-muted-foreground" aria-live="polite">
              Built through {shortDate(progress.through)} — {progress.documents} documents
              {percent !== null ? ` (${percent}%)` : ""}
              {running ? "" : "."}
            </p>
          </div>
        ) : null}
        {building.error ? <ErrorNote error={building.error} /> : null}
        {notes.length > 0 ? (
          <ul className="list-disc pl-5 text-sm text-muted-foreground">
            {notes.map((n, i) => (
              <li key={`${i}-${n}`}>{n}</li>
            ))}
          </ul>
        ) : null}
      </div>
    </section>
  );
}

/** Export is a read that produces a file, so it does not fit the button pattern. */
function ExportPanel() {
  const [preview, setPreview] = useState<unknown>(null);
  const exporting = useErpAction({ fn: "erp_export_tenant", invalidates: [] });

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Export and portability</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          A structured export of this organisation's own data — configuration, master data,
          documents and balances — in a form that can be read without this application.
        </Prose>
      </header>
      <div className="flex flex-col gap-3 px-4 py-4 sm:px-5">
        <div className="flex flex-wrap gap-2">
          <RpcButton
            label="Build export"
            fn="erp_export_tenant"
            permission="administration.configure"
            variant="primary"
            invalidates={[]}
          />
          <button
            type="button"
            className="min-h-11 rounded-md border border-input px-4 text-sm font-medium"
            onClick={() =>
              exporting.mutateAsync({}).then((result) => {
                setPreview(result);
                const blob = new Blob([JSON.stringify(result, null, 2)], {
                  type: "application/json",
                });
                const url = URL.createObjectURL(blob);
                const a = document.createElement("a");
                a.href = url;
                a.download = "clove-erp-tenant-export.json";
                a.click();
                URL.revokeObjectURL(url);
              })
            }
          >
            Download as JSON
          </button>
        </div>
        {exporting.error ? <ErrorNote error={exporting.error} /> : null}
        {preview ? (
          <pre className="max-h-64 overflow-auto rounded-md bg-muted p-3 text-xs">
            {JSON.stringify(preview, null, 2).slice(0, 4000)}
          </pre>
        ) : null}
      </div>
    </section>
  );
}
