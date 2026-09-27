import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { ActionButton, ErrorNote, useErpAction } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import type { FlowSpec } from "../../components/erp/process-flow";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { formatMinor, formatMinorWhole } from "../../lib/money";
import {
  VAT_EXPORT_FORMATS,
  boxLines,
  exceptionsOf,
  exportFile,
  nextReturns,
  normaliseObligations,
  statusTone,
  vatPresses,
  type VatExportFormat,
  type VatObligation,
} from "../../lib/vat-returns";

export const Route = createFileRoute("/finance/vat")({
  head: () => ({
    meta: [
      { title: "VAT returns — Clove ERP" },
      {
        name: "description",
        content:
          "Each VAT period with its due date and the nine boxes, finalised in one press and exported for bridging software in another.",
      },
      { property: "og:title", content: "VAT returns — Clove ERP" },
      {
        property: "og:description",
        content:
          "The nine VAT boxes from the ledger, the findings to check before filing, and a digitally linked export.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <VatReturns />
    </Gate>
  ),
});

/** Every step of the cycle lists the same periods, narrowed by where they stand. */
const PERIODS = {
  fn: "erp_vat_obligations",
  id: "period_end",
  title: ["company", "period_start", "period_end"],
  subtitle: ["due_on"],
  status: "status",
  noun: "period",
  nounPlural: "periods",
};

/**
 * The VAT cycle, two presses (erp_meta.flow_budget, row vat; D16): a period
 * is finalised once it has ended, then its return is exported for the bridging
 * software that files it. Declared here, beside its route, as PURCHASE_TO_PAY
 * is: supabase/ci/flow_steps.sh counts these verbs against the budget, and the
 * page below draws its three sections from these stages.
 */
const VAT_RETURNS: FlowSpec = {
  code: "vat",
  title: "VAT returns",
  stages: [
    {
      label: "Periods",
      hint: "Every VAT period of each company, with its due date and where it stands.",
      list: PERIODS,
    },
    {
      label: "Finalise",
      hint: "The next period to return, once it has ended: its nine boxes and what to check first.",
      states: ["due", "overdue"],
      list: PERIODS,
      actionFn: "erp_finalise_vat_return",
    },
    {
      label: "Export",
      hint: "A finalised return, as a file for the bridging software that files it.",
      states: ["finalised"],
      list: PERIODS,
      actionFn: "erp_vat_return_export",
    },
  ],
};

const [PERIODS_STAGE, FINALISE_STAGE, EXPORT_STAGE] = VAT_RETURNS.stages;

/** The reads a press makes stale. */
const INVALIDATES = ["erp_vat_obligations", "erp_vat_boxes", "erp_documents"];

/**
 * Hands the body the export door returned to the browser as a file, as it
 * came: the sha256 the return's vat_return.exported event carries is the
 * digest of exactly these bytes.
 */
function download(filename: string, mediaType: string, body: string) {
  const url = URL.createObjectURL(new Blob([body], { type: `${mediaType};charset=utf-8` }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

/**
 * VAT returns (PR14 M4): the obligations, the next return's nine boxes and
 * the findings to read before it is finalised, Finalise, and Export.
 *
 * Each press is drawn only where public.erp_vat_obligations says its door
 * would take it for this reader (can_finalise, can_export) and the session
 * holds finance.close_period; the database refuses regardless.
 */
function VatReturns() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const can = (code: string) => hasPermission(session, code);

  const obligations = useQuery({
    queryKey: ["erp_vat_obligations", {}],
    queryFn: async () => normaliseObligations(await callErp<unknown>("erp_vat_obligations", {})),
  });

  const rows = obligations.data ?? [];
  const next = nextReturns(rows);
  const finalised = rows.filter((r) => r.status === "finalised").reverse();

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.finance_vat", "VAT returns")}
        howItWorks={ui(
          "A return takes every VAT entry dated up to its period's end that no earlier return took, so something posted late into a finalised quarter is in the next return. Boxes 1 and 4 are the tax the ledger carries; boxes 6 and 7 are the net of the same documents, in whole pounds. Finalising freezes the boxes, and an error in a finalised return is corrected by posting the correction, which the next return takes. The product does not send anything to HMRC: the return is filed from bridging software, which reads the exported file. Bridging tools differ in what they import — most read a spreadsheet of the nine boxes, some the MTD return body as JSON — so check which yours reads; no tool is named or promised here.",
        )}
      >
        Two presses a period: finalise it once it has ended, then export the return for the bridging
        software that files it with HMRC.
      </PageHeader>

      {obligations.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          {ui("Reading the VAT periods…")}
        </p>
      ) : obligations.error ? (
        <ErrorNote error={obligations.error} />
      ) : rows.length === 0 ? (
        <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
          <p className="text-sm text-muted-foreground">
            {ui(
              "No VAT periods. A company has periods once its VAT registration is recorded on it.",
            )}
          </p>
        </section>
      ) : (
        <>
          {FINALISE_STAGE && next.length > 0 ? (
            <section className="flex min-w-0 flex-col gap-4" data-vat-next>
              <div>
                <h2 className="text-sm font-semibold">{ui(FINALISE_STAGE.label)}</h2>
                <p className="text-xs text-muted-foreground">{ui(FINALISE_STAGE.hint)}</p>
              </div>
              {next.map((row) => (
                <NextReturn key={`${row.entity_id}-${row.period_end}`} row={row} can={can} />
              ))}
            </section>
          ) : null}

          {PERIODS_STAGE ? (
            <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
              <h2 className="text-sm font-semibold">{ui(PERIODS_STAGE.label)}</h2>
              <p className="mb-3 text-xs text-muted-foreground">{ui(PERIODS_STAGE.hint)}</p>
              <Table
                columns={[
                  ui("Company"),
                  ui("Period"),
                  ui("Due"),
                  ui("State"),
                  ui("Net VAT"),
                  ui("Return"),
                ]}
              >
                {rows.map((row) => (
                  <ObligationRow key={`${row.entity_id}-${row.period_end}`} row={row} />
                ))}
              </Table>
            </section>
          ) : null}

          {EXPORT_STAGE && finalised.length > 0 ? (
            <section
              className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5"
              data-vat-exports
            >
              <h2 className="text-sm font-semibold">{ui(EXPORT_STAGE.label)}</h2>
              <p className="mb-3 text-xs text-muted-foreground">{ui(EXPORT_STAGE.hint)}</p>
              <div className="flex flex-col divide-y divide-border/60">
                {finalised.map((row) => (
                  <ExportRow key={`${row.entity_id}-${row.period_end}`} row={row} can={can} />
                ))}
              </div>
            </section>
          ) : null}
        </>
      )}
    </div>
  );
}

function periodOf(row: VatObligation): string {
  return `${row.period_start} – ${row.period_end}`;
}

function StatusPill({ row }: { row: VatObligation }) {
  const { ui } = useT();
  const words = {
    open: ui("Open"),
    due: ui("Due"),
    overdue: ui("Overdue"),
    finalised: ui("Finalised"),
  }[row.status];
  return <Pill tone={statusTone(row.status)}>{words}</Pill>;
}

function NetVat({ row }: { row: VatObligation }) {
  const { ui } = useT();
  if (!row.boxes) return <span>—</span>;
  return (
    <span>
      {formatMinor(row.boxes.box5_minor, row.currency)}{" "}
      <span className="text-xs text-muted-foreground">
        {row.boxes.box5_is === "repayable" ? ui("repayable") : ui("payable")}
      </span>
    </span>
  );
}

function ObligationRow({ row }: { row: VatObligation }) {
  return (
    <tr
      className="border-b border-border/60 align-top last:border-0"
      data-vat-period={row.period_end}
    >
      <td className="py-2 pr-4 text-sm">{row.company}</td>
      <td className="whitespace-nowrap py-2 pr-4 text-sm">{periodOf(row)}</td>
      <td className="whitespace-nowrap py-2 pr-4 text-sm">{row.due_on}</td>
      <td className="py-2 pr-4">
        <StatusPill row={row} />
      </td>
      <td className="whitespace-nowrap py-2 pr-4 text-sm tabular-nums">
        <NetVat row={row} />
      </td>
      <td className="py-2 pr-4 text-sm">{row.return_number ?? "—"}</td>
    </tr>
  );
}

/**
 * The period a company finalises next: its nine boxes as finalising it now
 * would freeze them, the findings to read first, and Finalise.
 */
function NextReturn({ row, can }: { row: VatObligation; can: (code: string) => boolean }) {
  const { ui } = useT();
  const presses = vatPresses(row, can);
  const finalise = useErpAction({ fn: "erp_finalise_vat_return", invalidates: INVALIDATES });

  // The findings finalising checks, over the same days: from the first day the
  // return takes entries from to its period end.
  const findings = useQuery({
    queryKey: [
      "erp_vat_boxes",
      { p_from: row.take_from, p_to: row.period_end, p_entity_id: row.entity_id },
    ],
    queryFn: async () =>
      exceptionsOf(
        await callErp<unknown>("erp_vat_boxes", {
          p_from: row.take_from,
          p_to: row.period_end,
          p_entity_id: row.entity_id,
        }),
        row.entity_id,
      ),
  });
  const exceptions = findings.data ?? [];
  const blocking = exceptions.filter((x) => x.blocks);
  const flags = exceptions.filter((x) => !x.blocks);

  return (
    <div
      className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5"
      data-vat-return={row.period_end}
    >
      <p className="text-sm font-semibold">
        {row.company}
        <span className="ml-2 font-normal text-muted-foreground">{periodOf(row)}</span>
        <span className="ml-2">
          <StatusPill row={row} />
        </span>
      </p>
      <p className="mt-1 text-xs text-muted-foreground">
        {ui("Due on")} {row.due_on} · {row.entries} {ui("entries")}
        {row.vrn ? ` · ${row.vrn}` : ""}
      </p>

      {row.boxes ? (
        <dl className="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2" data-vat-boxes>
          {boxLines(row.boxes).map((line) => (
            <div
              key={line.box}
              className="flex items-baseline justify-between gap-3 border-b border-border/40 py-1"
              data-box={line.box}
            >
              <dt className="text-muted-foreground">
                <span className="mr-2 font-medium text-foreground">{line.box}</span>
                {ui(line.label)}
              </dt>
              <dd className="tabular-nums">
                {line.whole
                  ? formatMinorWhole(line.minor, row.currency)
                  : formatMinor(line.minor, row.currency)}
                {line.box === 5 && row.boxes ? (
                  <span className="ml-1 text-xs text-muted-foreground">
                    {row.boxes.box5_is === "repayable" ? ui("repayable") : ui("payable")}
                  </span>
                ) : null}
              </dd>
            </div>
          ))}
        </dl>
      ) : null}

      {row.carried_forward && row.carried_forward.entries > 0 ? (
        <p className="mt-2 text-xs text-muted-foreground" data-vat-carried>
          {row.carried_forward.entries}{" "}
          {ui("entries dated in an earlier period are carried into this return.")}
          {row.carried_forward.over_threshold
            ? ` ${ui("They are more than a return may correct under VAT Notice 700/45: decide whether to notify HMRC separately.")}`
            : ""}
        </p>
      ) : null}

      <div className="mt-3" data-vat-findings>
        {findings.isPending ? (
          <p role="status" className="text-xs text-muted-foreground">
            {ui("Reading what to check…")}
          </p>
        ) : findings.error ? (
          <ErrorNote error={findings.error} />
        ) : exceptions.length === 0 ? (
          <p className="text-xs text-muted-foreground">
            {ui("Nothing to check before finalising.")}
          </p>
        ) : (
          <ul className="flex flex-col gap-1.5">
            {[...blocking, ...flags].map((x, i) => (
              <li
                key={`${x.finding}-${x.reference ?? i}`}
                className="text-xs"
                data-vat-finding={x.blocks ? "blocks" : "flag"}
              >
                <Pill tone={x.blocks ? "bad" : "warn"}>
                  {x.blocks ? ui("Blocks the return") : ui("Check")}
                </Pill>{" "}
                <span className={x.blocks ? "text-destructive" : "text-muted-foreground"}>
                  {x.detail}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="mt-3 flex flex-col gap-2">
        {presses.finalise ? (
          <div className="flex flex-wrap gap-2" data-vat-presses>
            <ActionButton
              busy={finalise.isPending}
              ariaLabel={`${ui("Finalise")} ${row.company} ${periodOf(row)}`}
              onClick={() =>
                finalise.mutate({ p_entity_id: row.entity_id, p_period_end: row.period_end })
              }
            >
              {ui("Finalise")}
            </ActionButton>
          </div>
        ) : row.finalise_blocked_by ? (
          <p className="text-xs text-muted-foreground" data-vat-blocked>
            {row.finalise_blocked_by}
          </p>
        ) : null}
        <ErrorNote error={finalise.error} />
      </div>
    </div>
  );
}

/** A finalised return and the three files it is exported as. */
function ExportRow({ row, can }: { row: VatObligation; can: (code: string) => boolean }) {
  const { ui } = useT();
  const presses = vatPresses(row, can);
  const [saved, setSaved] = useState<string | null>(null);
  const exporter = useErpAction({
    fn: "erp_vat_return_export",
    invalidates: [],
    onDone: (result) => {
      const file = exportFile(result);
      if (!file) return;
      download(file.filename, file.mediaType, file.body);
      setSaved(file.filename);
    },
  });

  const press = (format: VatExportFormat) => {
    if (!row.return_document_id) return;
    exporter.mutate({ p_document_id: row.return_document_id, p_format: format });
  };

  return (
    <div className="flex flex-col gap-2 py-3" data-vat-export={row.return_number ?? row.period_end}>
      <p className="text-sm">
        <span className="font-medium">{row.return_number}</span>
        <span className="ml-2 text-muted-foreground">
          {row.company} · {periodOf(row)}
        </span>
        <span className="ml-2 tabular-nums">
          <NetVat row={row} />
        </span>
      </p>
      {presses.export ? (
        <div className="flex flex-wrap gap-2">
          {VAT_EXPORT_FORMATS.map((f) => (
            <ActionButton
              key={f.format}
              variant={f.format === "csv" ? "primary" : "secondary"}
              busy={exporter.isPending}
              ariaLabel={`${ui("Export")} ${row.return_number ?? ""} ${ui(f.label)}`}
              onClick={() => press(f.format)}
            >
              {ui(f.label)}
            </ActionButton>
          ))}
        </div>
      ) : null}
      {saved ? (
        <p className="text-xs text-muted-foreground" data-vat-saved>
          {ui("Saved")} {saved}
        </p>
      ) : null}
      <ErrorNote error={exporter.error} />
    </div>
  );
}
