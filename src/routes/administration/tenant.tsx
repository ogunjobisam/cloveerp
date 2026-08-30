import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { ErrorNote, PermissionNote, useErpAction } from "../../components/erp/action";
import { AutoPanel, StatusPill } from "../../components/erp/auto";
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
      { title: "Tenant lifecycle — ERPWare" },
      {
        name: "description",
        content:
          "Go-live readiness, tenant data export and portability, and deletion with destruction of tenant-scoped material.",
      },
      { property: "og:title", content: "Tenant lifecycle — ERPWare" },
      {
        property: "og:description",
        content: "Go-live, export and portability, and tenant deletion.",
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
      <PageHeader title={t("module.tenant_lifecycle", "Tenant lifecycle")}>
        A tenant is not only rows. It starts (go-live), it can leave (export), and it can end
        (deletion) — and each of those is an operation with a record, not an support request.
      </PageHeader>

      {mayAdminister ? null : <PermissionNote code="administration.configure" />}

      <section className="rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">Go-live</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Going live freezes the tenant identifier and turns on the controls that only make sense
            against real data. It reports what is still missing rather than refusing silently.
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

      <ExportPanel />

      <section className="rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">Deletion</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Requesting deletion suspends the tenant immediately and schedules the purge. Tenant
            terminology overrides and cached material are destroyed at request time; operational
            data is removed by the purge, which is deliberately not instant so that a mistaken
            request can be caught.
          </Prose>
        </header>
        <div className="px-4 py-4 sm:px-5">
          <RpcButton
            label="Request tenant deletion"
            fn="erp_request_tenant_deletion"
            permission="administration.configure"
            confirm="Suspend this tenant and schedule deletion of its data? Export first if the data is wanted."
            invalidates={["erp_session", "erp_my_tenants"]}
          />
        </div>
      </section>

      <AutoPanel
        title="Platform assurance"
        description="What the platform itself says about this tenant's configuration and isolation."
        fn="erp_platform_assurance"
        empty="No assurance checks reported."
        rowKey={(r, i) => `${String(r["check_code"] ?? i)}-${i}`}
        columns={[
          { header: "Check", cell: "check_code" },
          { header: "Detail", cell: "detail" },
          { header: "Result", cell: (r) => <StatusPill value={r["state"] ?? r["result"]} /> },
        ]}
      />
    </div>
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
          A structured export of this tenant's own data — configuration, master data, documents and
          balances — in a form that can be read without this application.
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
                a.download = "erpware-tenant-export.json";
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
