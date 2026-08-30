import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { ActionDialog, ActionButton, PermissionNote } from "../../components/erp/action";
import { Gate, useErpSession } from "../../components/erp/gate";
import { PageHeader, Prose } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/administration/terminology")({
  head: () => ({
    meta: [
      { title: "Terminology — ERPWare" },
      {
        name: "description",
        content:
          "Every user-facing label is a resource key. Override the wording for this tenant without changing the software.",
      },
      { property: "og:title", content: "Terminology — ERPWare" },
      {
        property: "og:description",
        content: "Override user-facing wording per tenant through resource keys.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Terminology />
    </Gate>
  ),
});

type Resource = {
  resource_key: string;
  locale: string;
  product_text: string | null;
  tenant_text: string | null;
};

function Terminology() {
  const { t, locale } = useT();
  const { session } = useErpSession();
  const [filter, setFilter] = useState("");
  const mayConfigure = hasPermission(session, "administration.configure");

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_resource_catalog", { p_locale: locale }],
    queryFn: () => callErp<Resource[]>("erp_resource_catalog", { p_locale: locale }),
  });

  const rows = (data ?? []).filter((r) =>
    filter
      ? `${r.resource_key} ${r.product_text ?? ""} ${r.tenant_text ?? ""}`
          .toLowerCase()
          .includes(filter.toLowerCase())
      : true,
  );

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.terminology", "Terminology")}>
        No label in this application is written into a screen. Each one is a key resolved against
        product text and, where a tenant disagrees, against its own wording. Changing what a
        delivery note is called is a row here, not a release.
      </PageHeader>

      {mayConfigure ? null : <PermissionNote code="administration.configure" />}

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
          <div>
            <h2 className="text-sm font-semibold">Resource keys</h2>
            <Prose className="mt-0.5 text-xs text-muted-foreground">
              Locale {locale}. Overridden keys are marked.
            </Prose>
          </div>
          <input
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            placeholder="Filter keys"
            className="min-h-11 rounded-md border border-input bg-background px-3 text-sm"
          />
        </header>

        <div className="px-4 py-4 sm:px-5">
          {isPending ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : error ? (
            <div role="alert">
              <p className="text-sm font-medium text-destructive">This did not load.</p>
              <p className="mt-1 text-xs text-muted-foreground">{(error as Error).message}</p>
            </div>
          ) : (
            <Table columns={["Key", "Product text", "This tenant", "", ""]}>
              {rows.slice(0, 300).map((r) => (
                <tr key={`${r.resource_key}-${r.locale}`} className="border-b border-border/50">
                  <td className="py-2 pr-4 font-mono text-xs">{r.resource_key}</td>
                  <td className="py-2 pr-4">{r.product_text ?? "—"}</td>
                  <td className="py-2 pr-4">{r.tenant_text ?? "—"}</td>
                  <td className="py-2 pr-4">
                    {r.tenant_text ? <Pill tone="warn">Overridden</Pill> : null}
                  </td>
                  <td className="py-2 pr-4">
                    <ActionDialog
                      trigger={<ActionButton variant="secondary">Reword</ActionButton>}
                      title={`Reword ${r.resource_key}`}
                      description="This wording applies to this tenant only, in this locale."
                      permission="administration.configure"
                      fn="erp_set_resource_override"
                      fields={[
                        {
                          kind: "text",
                          name: "p_text",
                          label: "Wording",
                          required: true,
                        },
                      ]}
                      mapArgs={(values) => ({
                        p_resource_key: r.resource_key,
                        p_locale: r.locale,
                        p_text: values["p_text"],
                      })}
                      invalidates={["erp_resource_catalog", "erp_resources"]}
                      submitLabel="Apply wording"
                    />
                  </td>
                </tr>
              ))}
            </Table>
          )}
        </div>
      </section>
    </div>
  );
}
