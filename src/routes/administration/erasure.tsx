import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { friendlyError } from "@/lib/errors";

import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { RpcButton } from "../../components/erp/rpc-button";
import { callErp } from "../../lib/erp";

export const Route = createFileRoute("/administration/erasure")({
  head: () => ({
    meta: [
      { title: "Personal data and erasure — Clove ERP" },
      {
        name: "description",
        content: "Personal-data register and erasure requests, handled under UK GDPR.",
      },
      { property: "og:title", content: "Personal data and erasure — Clove ERP" },
      {
        property: "og:description",
        content: "Personal-data register and erasure requests, handled under UK GDPR.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Erasure />
    </Gate>
  ),
});

/** Shaped by erp_erasure_requests(): every request in the organisation,
 *  newest first, with the certificate once executed. */
type Request = {
  request_id: string;
  subject_kind: "principal" | "contact";
  subject_id: string;
  subject_label: string;
  reason: string;
  status: "requested" | "executed" | "refused";
  requested_by: string | null;
  executed_by: string | null;
  executed_at: string | null;
  refused_reason: string | null;
  certificate: {
    fields?: { column: string; erasure: string }[];
    copies?: Record<string, number>;
  } | null;
  created_at: string;
};

/** Shaped by erp_personal_data_register(): product data, the same for every
 *  organisation. */
type Register = {
  fields: {
    schema_name: string;
    table_name: string;
    column_name: string;
    subject_kind: string;
    subject_column: string;
    erasure: "placeholder" | "null" | "redact_copy";
    placeholder: string | null;
    note: string;
  }[];
  exemptions: {
    schema_name: string;
    table_name: string;
    column_name: string;
    rationale: string;
  }[];
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function statusTone(status: Request["status"]): "ok" | "warn" | "bad" | "muted" {
  switch (status) {
    case "executed":
      return "ok";
    case "requested":
      return "warn";
    case "refused":
      return "muted";
    default:
      return "muted";
  }
}

function erasureWord(erasure: Register["fields"][number]["erasure"]): string {
  switch (erasure) {
    case "placeholder":
      return "overwritten with a placeholder";
    case "null":
      return "set to nothing";
    case "redact_copy":
      return "redacted in the ledger's copy";
  }
}

function Erasure() {
  const register = useQuery({
    queryKey: ["erp_personal_data_register", {}],
    queryFn: () => callErp<Register>("erp_personal_data_register", {}),
  });

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Personal data and erasure">
        Events carry references, never personal data. When a person must be erased, the reference
        stays and the referent is destroyed: their name and details are overwritten from a register
        of every column that holds them, and the copies the ledger kept are redacted in place. The
        ledger still adds up and still says who, by id, did what; the person is no longer
        identifiable. A request is executed by somebody other than the person who made it.
      </PageHeader>

      <ActionBar
        title="Requesting an erasure"
        note="Request the erasure of a principal or a business partner's contact. Another administrator executes it from the list below."
        actions={[
          {
            label: "Request an erasure",
            permission: "administration.users",
            fn: "erp_request_erasure",
            description:
              "Refused for yourself, for a subject with an open request, and for a subject already erased.",
            fields: [
              pickFrom(
                "erp_erasure_subjects",
                "subject_id",
                ["kind", "label"],
                "p_subject_id",
                "Person",
              ),
              {
                kind: "choice",
                name: "p_subject_kind",
                label: "Kind",
                required: true,
                choices: [
                  { value: "principal", label: "Principal (someone who signs in)" },
                  { value: "contact", label: "Contact at a business partner" },
                ],
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                required: true,
                hint: "Kept with the request: a subject access request, a leaver, a legal instruction.",
              },
            ],
            invalidates: ["erp_erasure_requests", "erp_erasure_subjects"],
          },
        ]}
      />

      <DataPanel<Request>
        title="Erasure requests"
        description="Newest first. An open request is executed or refused by an administrator other than the one who made it; an executed one carries the certificate of what was overwritten and how many ledger copies were redacted."
        fn="erp_erasure_requests"
        empty="No erasure has been requested. Raise one under Actions above; it is executed by a second administrator, never the one who asked."
      >
        {(rows) => (
          <Table
            columns={["Subject", "Reason", "State", "Requested", "Done", "Certificate", "Actions"]}
          >
            {rows.map((r) => (
              <tr key={r.request_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.subject_label}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.subject_kind} · {r.subject_id.slice(0, 8)}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">{r.reason}</td>
                <td className="py-2 pr-4">
                  <Pill tone={statusTone(r.status)}>{r.status}</Pill>
                  {r.refused_reason ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.refused_reason}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.created_at)}
                  <div className="mt-0.5">{r.requested_by ?? "—"}</div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.executed_at)}
                  <div className="mt-0.5">{r.executed_by ?? "—"}</div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.certificate ? (
                    <>
                      <div>{(r.certificate.fields ?? []).length} field(s) overwritten</div>
                      {Object.entries(r.certificate.copies ?? {}).map(([k, v]) => (
                        <div key={k} className="font-mono">
                          {k}: {v}
                        </div>
                      ))}
                    </>
                  ) : (
                    "—"
                  )}
                </td>
                <td className="py-2">
                  {r.status === "requested" ? (
                    <span className="flex flex-wrap gap-2">
                      <RpcButton
                        label="Execute"
                        fn="erp_execute_erasure"
                        args={{ p_request_id: r.request_id }}
                        permission="administration.users"
                        confirm="Erase this person? Their name and details are overwritten and the ledger's copies redacted. This cannot be undone."
                        invalidates={["erp_erasure_requests", "erp_erasure_subjects"]}
                      />
                      <RpcButton
                        label="Refuse"
                        fn="erp_refuse_erasure"
                        args={{
                          p_request_id: r.request_id,
                          p_reason: "Refused from the erasure screen",
                        }}
                        permission="administration.users"
                        invalidates={["erp_erasure_requests"]}
                      />
                    </span>
                  ) : (
                    <span className="text-xs text-muted-foreground">—</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">What erasure touches</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Product data, the same for every organisation. Every column that holds a person&apos;s
            identifying data, and what an erasure does to it. The build fails if a column that looks
            personal is added to the product and is in neither this list nor the exemptions below.
          </Prose>
        </header>
        <div className="px-4 py-4 sm:px-5">
          {register.isPending ? (
            <p role="status" className="text-sm text-muted-foreground">
              Loading…
            </p>
          ) : register.error ? (
            <div role="alert">
              <p className="text-sm font-medium text-destructive">This did not load.</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {friendlyError(register.error).title}
              </p>
            </div>
          ) : register.data ? (
            <>
              <Table columns={["Column", "Whose", "Tied by", "On erasure", "Note"]}>
                {register.data.fields.map((f) => (
                  <tr
                    key={`${f.table_name}.${f.column_name}`}
                    className="border-b border-border/50 align-top last:border-0"
                  >
                    <td className="py-2 pr-4 font-mono text-xs">
                      {f.schema_name}.{f.table_name}.{f.column_name}
                    </td>
                    <td className="py-2 pr-4 text-sm">{f.subject_kind}</td>
                    <td className="py-2 pr-4 font-mono text-xs">{f.subject_column}</td>
                    <td className="py-2 pr-4 text-sm">
                      <Pill tone={f.erasure === "redact_copy" ? "warn" : "ok"}>
                        {erasureWord(f.erasure)}
                      </Pill>
                      {f.placeholder ? (
                        <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                          {f.placeholder}
                        </div>
                      ) : null}
                    </td>
                    <td className="py-2 text-xs text-muted-foreground">{f.note}</td>
                  </tr>
                ))}
              </Table>
              <h3 className="mt-6 text-sm font-semibold">Kept, with the reason</h3>
              <div className="mt-2">
                <Table columns={["Column", "Why it is not erased per person"]}>
                  {register.data.exemptions.map((x) => (
                    <tr
                      key={`${x.schema_name}.${x.table_name}.${x.column_name}`}
                      className="border-b border-border/50 align-top last:border-0"
                    >
                      <td className="py-2 pr-4 font-mono text-xs">
                        {x.schema_name}.{x.table_name}.{x.column_name}
                      </td>
                      <td className="py-2 text-xs text-muted-foreground">{x.rationale}</td>
                    </tr>
                  ))}
                </Table>
              </div>
            </>
          ) : null}
        </div>
      </section>
    </div>
  );
}
