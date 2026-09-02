import { useQuery } from "@tanstack/react-query";
import type React from "react";
import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/operations/output")({
  head: () => ({ meta: [{ title: "Output and printing — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Output />
    </Gate>
  ),
});

/** Shaped by erp.output_integrity_report(): what §15 says must hold and does
 *  not — a label template that never passed its decode check, a delivery with
 *  no confirmation, a render whose checksum does not match. */
type Finding = {
  finding: string;
  reference: string;
  detail: string;
};

/** Shaped by erp_output_template_versions(), newest version first within a
 *  template. A label template's decode check is the proof the barcode it
 *  prints can be read back; a document template has none. */
type TemplateVersion = {
  id: string;
  template_code: string;
  name_key: string;
  kind: string;
  base_type_code: string | null;
  version: number;
  rendering_engine: string;
  page: string | null;
  label_language: string | null;
  required_permission: string | null;
  status: string;
  effective_from: string | null;
  effective_to: string | null;
  decode_check_passed: boolean | null;
  decoded_value: string | null;
  block_count: number | null;
  note: string | null;
};

/** Shaped by erp_printers(). */
type Printer = {
  id: string;
  code: string;
  name: string;
  site: string;
  printer_type: string;
  language: string | null;
  dots_per_inch: number | null;
  physical_location: string | null;
  default_stock: string | null;
  queue_address: string | null;
  status: string;
  updated_at: string;
};

/** Shaped by erp_output_requests(): a request, its latest render and that
 *  render's latest delivery, newest first. */
type Request = {
  id: string;
  template_code: string;
  version: number | null;
  object_type: string;
  object_id: string;
  destination_kind: string;
  printer: string | null;
  locale: string | null;
  copies: number;
  triggering_event: string | null;
  requested_by: string | null;
  requested_at: string;
  rendered_at: string | null;
  format: string | null;
  checksum: string | null;
  byte_size: number | null;
  document_reference: string | null;
  is_copy: boolean | null;
  delivery_status: string | null;
  destination: string | null;
  attempts: number | null;
  confirmed_at: string | null;
  failure_reason: string | null;
};

/** Shaped by erp_email_suppressions(). */
type Suppression = {
  id: string;
  address: string;
  reason: string;
  is_permanent: boolean;
  suppressed_at: string;
  note: string | null;
};

/** From erp.printer's checks. */
const PRINTER_TYPES = [
  { value: "label", label: "Label printer" },
  { value: "document", label: "Document printer" },
];

const LANGUAGES = [
  { value: "zpl", label: "ZPL" },
  { value: "epl", label: "EPL" },
  { value: "ipl", label: "IPL" },
  { value: "pdf", label: "PDF" },
];

/** Shaped by erp_print_routes(). */
type PrintRoute = {
  code: string;
  output_kind: string;
  template_code: string | null;
  site: string | null;
  workstation: string | null;
  person: string | null;
  printer: string;
  priority: number;
  status: string;
};

/** Shaped by erp.print_queue_health_report(): §15.4's signals per printer. */
type QueueHealth = {
  printer_code: string;
  site_code: string;
  queued: number;
  failed: number;
  oldest_queued_minutes: number | null;
  last_confirmed_at: string | null;
  signal: string | null;
};

/** Shaped by erp_sender_identities(). */
type Senders = {
  identities: {
    domain: string;
    category: string;
    from_address: string;
    reply_to: string | null;
    spf_verified_at: string | null;
    dkim_verified_at: string | null;
    dmarc_verified_at: string | null;
    verified_at: string | null;
    status: string;
    checklist: { record: string; type: string; name: string; value: string; why: string }[];
  }[];
  transactional: { from_address: string; reply_to: string | null; own_domain: boolean };
  operational: { from_address: string; reply_to: string | null; own_domain: boolean };
};

type OutputHealth = {
  requests_24h: number;
  requests_7d: number;
  deliveries_7d: Record<string, number>;
  failure_rate_7d: number;
  print_queue_depth: number;
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

/** From erp.output_delivery's status check: queued, sent, confirmed, failed. */
function deliveryTone(status: string | null): "ok" | "warn" | "bad" | "muted" {
  switch (status) {
    case "confirmed":
      return "ok";
    case "failed":
      return "bad";
    case "queued":
    case "sent":
      return "warn";
    default:
      return "muted";
  }
}

function Output() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Output and printing">
        Every document and label the organisation produces comes from a template version, is
        rendered once with a checksum, and is delivered to a printer, a mailbox or a file with a
        record of whether it arrived. A label template is not live until its barcode has been
        decoded back from a test render.
      </PageHeader>

      <ActionBar
        note="Printers are configuration: on a live organisation the change goes through a change set, and a direct write here is refused. A label printer needs a language and a resolution; a document printer needs neither."
        actions={[
          {
            label: "Add a print route",
            permission: "administration.configure",
            fn: "erp_upsert_print_route",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              {
                kind: "choice",
                name: "p_output_kind",
                label: "Output kind",
                required: true,
                choices: [
                  { value: "label", label: "Labels" },
                  { value: "document", label: "Documents" },
                ],
              },
              pickFrom("erp_printers", "code", ["code", "name"], "p_printer_code", "Printer"),
              {
                kind: "text",
                name: "p_template_code",
                label: "Template code",
                hint: "Leave empty for any template of the kind.",
              },
              { kind: "site", name: "p_site_id", label: "Site", required: false },
              { kind: "text", name: "p_workstation", label: "Workstation" },
              {
                kind: "number",
                name: "p_priority",
                label: "Priority",
                hint: "Lower wins among equally specific routes.",
              },
            ],
            invalidates: ["erp_print_routes", "erp_output_integrity"],
          },
          {
            label: "Render a label",
            permission: "inventory.read",
            fn: "erp_render_label",
            fields: [
              pickFrom(
                "erp_output_templates",
                "code",
                ["code", "kind"],
                "p_template_code",
                "Label template",
              ),
              pickFrom("erp_printers", "code", ["code", "name"], "p_printer_code", "Printer"),
              {
                kind: "text",
                name: "p_document_id",
                label: "Document id",
                hint: "Optional; a label for a document carries its number.",
              },
            ],
            invalidates: ["erp_output_requests", "erp_print_queue_health", "erp_output_health"],
          },
          {
            label: "Reprint",
            permission: "inventory.read",
            fn: "erp_reprint_output",
            fields: [
              { kind: "text", name: "p_render_id", label: "Render id", required: true },
              pickFrom("erp_printers", "code", ["code", "name"], "p_printer_code", "Printer"),
            ],
            invalidates: ["erp_output_requests", "erp_print_queue_health", "erp_output_health"],
          },
          {
            label: "Register a sending domain",
            permission: "administration.integrate",
            fn: "erp_upsert_sender_identity",
            fields: [
              { kind: "text", name: "p_domain", label: "Domain", required: true },
              {
                kind: "choice",
                name: "p_category",
                label: "Category",
                required: true,
                choices: [
                  { value: "transactional", label: "Transactional (invoices, orders)" },
                  { value: "operational", label: "Operational (alerts, reminders)" },
                ],
              },
              {
                kind: "text",
                name: "p_from_local_part",
                label: "From (local part)",
                hint: "e.g. invoices",
              },
              { kind: "text", name: "p_reply_to", label: "Reply-to" },
            ],
            invalidates: ["erp_sender_identities"],
          },
          {
            label: "Record DNS verification",
            permission: "administration.integrate",
            fn: "erp_record_sender_verification",
            fields: [
              { kind: "text", name: "p_domain", label: "Domain", required: true },
              {
                kind: "choice",
                name: "p_spf",
                label: "SPF verified",
                required: true,
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
              {
                kind: "choice",
                name: "p_dkim",
                label: "DKIM verified",
                required: true,
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
              {
                kind: "choice",
                name: "p_dmarc",
                label: "DMARC verified",
                required: true,
                boolean: true,
                choices: [
                  { value: "true", label: "Yes" },
                  { value: "false", label: "No" },
                ],
              },
            ],
            invalidates: ["erp_sender_identities"],
          },
          {
            label: "Register a printer",
            permission: "administration.configure",
            fn: "erp_upsert_printer",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "site", name: "p_site_id", label: "Site", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              {
                kind: "choice",
                name: "p_printer_type",
                label: "Type",
                required: true,
                choices: PRINTER_TYPES,
              },
              {
                kind: "choice",
                name: "p_language",
                label: "Language",
                choices: LANGUAGES,
                hint: "Required for a label printer.",
              },
              {
                kind: "number",
                name: "p_dots_per_inch",
                label: "Resolution",
                hint: "Dots per inch, e.g. 203 or 300. Required for a label printer.",
              },
              { kind: "text", name: "p_physical_location", label: "Where it stands" },
              {
                kind: "text",
                name: "p_default_stock",
                label: "Default stock",
                hint: "The label or paper stock loaded by default.",
              },
              {
                kind: "text",
                name: "p_queue_address",
                label: "Queue address",
                hint: "How the print agent reaches it, e.g. a host and port or a queue name.",
              },
            ],
            invalidates: ["erp_printers", "erp_output_integrity"],
          },
        ]}
      />

      <DataPanel<Finding>
        title="What is wrong"
        description="Read from the same report the build fails on. A template without a decode check, a render whose checksum drifted, a delivery that was never confirmed — one row here is one failure there."
        fn="erp_output_integrity"
        empty="Nothing to report. Every template, render and delivery is as §15 expects."
      >
        {(rows) => (
          <Table columns={["Finding", "Reference", "Detail"]}>
            {rows.map((r, i) => (
              <tr
                key={`${r.finding}-${r.reference}-${i}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4">
                  <Pill tone="bad">{r.finding}</Pill>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.reference}</td>
                <td className="py-2 text-sm text-muted-foreground">{r.detail}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<TemplateVersion>
        title="Template versions"
        description="Every version of every template, newest first. A label version shows whether its test barcode decoded and to what; a document version shows its page and how many blocks it lays out."
        fn="erp_output_template_versions"
        empty="No output template is installed. The base content pack carries the standard documents and labels; install it from Packs."
      >
        {(rows) => (
          <Table columns={["Template", "Version", "Engine", "Decode check", "Effective", "State"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.template_code}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.kind}
                    {r.base_type_code ? ` · ${r.base_type_code}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">v{r.version}</td>
                <td className="py-2 pr-4 text-sm">
                  {r.rendering_engine}
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {r.kind === "label"
                      ? (r.label_language ?? "—")
                      : `${r.page ?? "—"}${r.block_count != null ? ` · ${r.block_count} blocks` : ""}`}
                  </div>
                </td>
                <td className="py-2 pr-4">
                  {r.kind !== "label" ? (
                    <span className="text-xs text-muted-foreground">Not a label</span>
                  ) : r.decode_check_passed ? (
                    <>
                      <Pill tone="ok">Decoded</Pill>
                      {r.decoded_value ? (
                        <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                          {r.decoded_value}
                        </div>
                      ) : null}
                    </>
                  ) : (
                    <Pill tone="bad">Not decoded</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.effective_from ? new Date(r.effective_from).toLocaleDateString() : "—"}
                  {r.effective_to ? ` → ${new Date(r.effective_to).toLocaleDateString()}` : ""}
                </td>
                <td className="py-2">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Printer>
        title="Printers"
        description="Every printer the organisation can send to, by site. The queue address is what the print agent dials; the default stock is what it expects to find loaded."
        fn="erp_printers"
        empty="No printer is registered. Register one above; a label template cannot be sent anywhere until there is a label printer to send it to."
      >
        {(rows) => (
          <Table columns={["Printer", "Site", "Type", "Language", "Where", "Queue", "State"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">{r.code}</div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.site}</td>
                <td className="py-2 pr-4 text-sm">{r.printer_type}</td>
                <td className="py-2 pr-4 text-sm">
                  {r.language ? r.language.toUpperCase() : "—"}
                  {r.dots_per_inch ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {r.dots_per_inch} dpi
                    </div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.physical_location ?? "—"}
                  {r.default_stock ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.default_stock}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 font-mono text-xs text-muted-foreground">
                  {r.queue_address ?? "—"}
                </td>
                <td className="py-2">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Request>
        title="Requests, renders and deliveries"
        description="The last five hundred requests, newest first. Each carries the render it produced — format, size, checksum — and whether the delivery of that render was confirmed. A copy is marked as one so it cannot pass for the original."
        fn="erp_output_requests"
        empty="Nothing has been requested yet. A request is raised by an event — a despatch confirmed, an invoice posted — or by somebody asking for a reprint."
      >
        {(rows) => (
          <Table columns={["Requested", "Template", "For", "Destination", "Render", "Delivery"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.requested_at)}
                  <div className="mt-0.5">{r.requested_by ?? r.triggering_event ?? "—"}</div>
                </td>
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.template_code}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.version != null ? `v${r.version}` : "not rendered"}
                    {r.copies > 1 ? ` · ${r.copies} copies` : ""}
                    {r.is_copy ? " · copy" : ""}
                  </div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.object_type}
                  <div className="mt-0.5 text-muted-foreground">
                    {r.document_reference ?? r.object_id.slice(0, 8)}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.destination_kind}
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.printer ?? r.destination ?? "—"}
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.rendered_at ? (
                    <>
                      {r.format?.toUpperCase() ?? "—"}
                      {r.byte_size != null ? ` · ${r.byte_size.toLocaleString()} bytes` : ""}
                      <div className="mt-0.5 font-mono">{r.checksum?.slice(0, 12) ?? ""}</div>
                    </>
                  ) : (
                    "—"
                  )}
                </td>
                <td className="py-2">
                  <Pill tone={deliveryTone(r.delivery_status)}>
                    {r.delivery_status ?? "not delivered"}
                  </Pill>
                  {r.attempts != null && r.attempts > 1 ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {r.attempts} attempts
                    </div>
                  ) : null}
                  {r.failure_reason ? (
                    <div className="mt-0.5 text-xs text-destructive">{r.failure_reason}</div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Suppression>
        title="Suppressed addresses"
        description="Addresses the organisation will not email again: a hard bounce, a complaint, an unsubscribe. A permanent suppression outlives the reason; a temporary one is lifted when the reason is."
        fn="erp_email_suppressions"
        empty="No address is suppressed."
      >
        {(rows) => (
          <Table columns={["Address", "Reason", "Since", "Kind", "Note"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.address}</td>
                <td className="py-2 pr-4 text-sm">{r.reason}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{when(r.suppressed_at)}</td>
                <td className="py-2 pr-4">
                  {r.is_permanent ? (
                    <Pill tone="bad">Permanent</Pill>
                  ) : (
                    <Pill tone="warn">Temporary</Pill>
                  )}
                </td>
                <td className="py-2 text-xs text-muted-foreground">{r.note ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<PrintRoute>
        title="Print routes"
        description="Which printer a document or label goes to, by site, workstation or person. The most specific route that matches wins."
        fn="erp_print_routes"
        empty="No print route is defined; a print request has nowhere to go until one is."
      >
        {(rows) => (
          <Table columns={["Route", "Kind", "Scope", "Printer", "State"]}>
            {rows.map((r) => (
              <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.code}
                  <div className="mt-0.5 text-muted-foreground">priority {r.priority}</div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.output_kind}
                  {r.template_code ? ` · ${r.template_code}` : ""}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {[r.site, r.workstation, r.person].filter(Boolean).join(" · ") || "anywhere"}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.printer}</td>
                <td className="py-2">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<QueueHealth>
        title="Print queues"
        description="Queue depth, the oldest waiting print and the last confirmed one per printer, with the signal §15.4 names when something is wrong."
        fn="erp_print_queue_health"
        empty="No active printer is registered."
      >
        {(rows) => (
          <Table
            columns={["Printer", "Queued", "Failed", "Oldest waiting", "Last confirmed", "Signal"]}
          >
            {rows.map((q) => (
              <tr
                key={q.printer_code}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">
                  {q.printer_code}
                  <div className="mt-0.5 text-muted-foreground">{q.site_code}</div>
                </td>
                <td className="py-2 pr-4 text-xs tabular-nums">{q.queued}</td>
                <td className="py-2 pr-4 text-xs tabular-nums">{q.failed}</td>
                <td className="py-2 pr-4 text-xs">
                  {q.oldest_queued_minutes !== null ? `${q.oldest_queued_minutes} min` : "—"}
                </td>
                <td className="py-2 pr-4 text-xs">{when(q.last_confirmed_at)}</td>
                <td className="py-2">
                  {q.signal ? <Pill tone="bad">{q.signal}</Pill> : <Pill tone="ok">Healthy</Pill>}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <SenderIdentities />

      <OutputHealthPanel />
    </div>
  );
}

function Section({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{title}</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
      </header>
      <div className="px-4 py-4 sm:px-5">{children}</div>
    </section>
  );
}

function OutputHealthPanel() {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_output_health", {}],
    queryFn: () => callErp<OutputHealth>("erp_output_health"),
    refetchInterval: 30_000,
  });
  const h = q.data;
  return (
    <Section
      title={ui("Output health")}
      description={ui(
        "Requests, deliveries by state, the failure rate and the print queue depth, alongside job health.",
      )}
    >
      {!h ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : (
        <dl className="grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
          <dt className="text-muted-foreground">Requests, 24 h</dt>
          <dd className="tabular-nums">{h.requests_24h}</dd>
          <dt className="text-muted-foreground">Requests, 7 d</dt>
          <dd className="tabular-nums">{h.requests_7d}</dd>
          <dt className="text-muted-foreground">Failure rate, 7 d</dt>
          <dd className="tabular-nums">{h.failure_rate_7d}%</dd>
          <dt className="text-muted-foreground">Print queue depth</dt>
          <dd className="tabular-nums">{h.print_queue_depth}</dd>
          <dt className="text-muted-foreground">Deliveries, 7 d</dt>
          <dd className="font-mono text-xs">
            {Object.entries(h.deliveries_7d ?? {})
              .map(([k, v]) => `${k} ${v}`)
              .join(" · ") || "—"}
          </dd>
        </dl>
      )}
    </Section>
  );
}

function SenderIdentities() {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_sender_identities", {}],
    queryFn: () => callErp<Senders>("erp_sender_identities"),
  });
  const s = q.data;
  return (
    <Section
      title={ui("Sending domains")}
      description={ui(
        "Until a domain verifies its SPF, DKIM and DMARC records the organisation sends from the platform's address with its own reply-to. Each record to publish is listed with why.",
      )}
    >
      {!s ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : (
        <div className="flex flex-col gap-4">
          <p className="text-xs text-muted-foreground">
            {ui("Sends as")}: {s.transactional.from_address}
            {s.transactional.reply_to ? ` (reply-to ${s.transactional.reply_to})` : ""} ·{" "}
            {s.operational.from_address}
          </p>
          {s.identities.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui("No sending domain is registered; messages go from the platform's address.")}
            </p>
          ) : null}
          {s.identities.map((d) => (
            <div
              key={`${d.domain}-${d.category}`}
              className="border-b border-border/50 pb-3 last:border-0 last:pb-0"
            >
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-mono text-sm">{d.from_address}</span>
                <span className="text-xs text-muted-foreground">{d.category}</span>
                {d.verified_at ? (
                  <Pill tone="ok">{ui("Verified")}</Pill>
                ) : (
                  <Pill tone="warn">{ui("Not yet verified")}</Pill>
                )}
              </div>
              <ul className="mt-2 flex flex-col gap-1 text-xs">
                {d.checklist.map((c) => (
                  <li key={c.record}>
                    <span className="font-medium">{c.record}</span>{" "}
                    {(c.record === "SPF" && d.spf_verified_at) ||
                    (c.record === "DKIM" && d.dkim_verified_at) ||
                    (c.record === "DMARC" && d.dmarc_verified_at) ? (
                      <Pill tone="ok">{ui("Verified")}</Pill>
                    ) : (
                      <Pill tone="muted">{ui("Not yet verified")}</Pill>
                    )}
                    <div className="font-mono text-muted-foreground">
                      {c.type} {c.name} → {c.value}
                    </div>
                    <div className="text-muted-foreground">{c.why}</div>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}
