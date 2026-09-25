import { createPortal } from "react-dom";

import {
  pageSize,
  printed,
  type RenderedBlock,
  type RenderedDocument,
} from "../../lib/count-worklist";
import { useT } from "../../lib/i18n";
import { ActionButton } from "./action";

/**
 * A count sheet on paper (PR10 M3b).
 *
 * public.erp_render_count_sheet renders the sheet through the organisation's
 * count sheet layout (20260927100000) and answers with its blocks — title,
 * issuer, summary, lines and signature — already labelled in the reader's
 * language and through the organisation's own words. This draws those blocks
 * and nothing of its own: the labels are the layout's, so an organisation
 * that renames a column on its layout renames it here.
 *
 * The sheet is rendered straight into <body>, beside the application rather
 * than inside it, as `[data-print-root]`. While it is there src/styles.css
 * takes everything else in <body> out of the printed layout (display, not
 * visibility, so the desk leaves no blank pages behind it) and prints the
 * sheet on its own named page, sized as the layout says. A page with no sheet
 * open prints as it always has. On the screen it is a preview over the desk,
 * until it is closed.
 */

function Fields({ block }: { block: RenderedBlock }) {
  const fields = block.fields ?? [];
  if (fields.length === 0) return null;
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
      {fields.map((f, i) => (
        <div key={`${f.field}-${i}`} className="contents">
          <dt className="text-muted-foreground print:text-black">{f.label ?? f.field}</dt>
          <dd className="whitespace-pre-line">{printed(f.value)}</dd>
        </div>
      ))}
    </dl>
  );
}

function Block({ block }: { block: RenderedBlock }) {
  switch (block.kind) {
    case "title": {
      const first = block.fields?.[0];
      return <h3 className="text-lg font-semibold">{printed(first?.value)}</h3>;
    }
    case "issuer":
    case "summary":
      return <Fields block={block} />;
    case "lines": {
      const columns = block.columns ?? [];
      const rows = block.rows ?? [];
      return (
        <div className="flex flex-col gap-2">
          {block.label ? <h4 className="text-sm font-semibold">{block.label}</h4> : null}
          <table className="w-full border-collapse text-left text-sm">
            <thead>
              <tr>
                {columns.map((c, i) => (
                  <th
                    key={`${c.field}-${i}`}
                    scope="col"
                    className="border-b border-border px-2 py-1 text-xs font-medium print:border-black"
                  >
                    {c.label ?? c.field}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                // The position as well as the line number: a layout that
                // repeats a line, or sends none, still keys each row once.
                <tr key={`${printed(r["line_no"])}-${i}`} className="break-inside-avoid">
                  {columns.map((c, j) =>
                    c.field === "counted_quantity" ? (
                      // The blank the counter writes in.
                      <td
                        key={`${c.field}-${j}`}
                        data-blank=""
                        className="min-w-24 border border-border px-2 py-2 print:border-black"
                      >
                        {printed(r[c.field])}
                      </td>
                    ) : (
                      <td
                        key={`${c.field}-${j}`}
                        className="whitespace-pre-line border-b border-border/60 px-2 py-2 tabular-nums print:border-black"
                      >
                        {printed(r[c.field])}
                      </td>
                    ),
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    }
    case "signature":
      return (
        <div className="mt-8 flex items-end gap-3 text-sm">
          <span>{block.label ?? ""}</span>
          <span className="h-6 flex-1 border-b border-foreground print:border-black" />
        </div>
      );
    default:
      return (
        <div className="flex flex-col gap-1">
          {block.label ? <h4 className="text-sm font-semibold">{block.label}</h4> : null}
          <Fields block={block} />
        </div>
      );
  }
}

/** The rendered sheet: a preview over the desk on the screen, alone on paper when printed. */
export function CountSheetPrint({
  sheet,
  onPrint,
  onClose,
  printing,
}: {
  sheet: RenderedDocument;
  onPrint: () => void;
  onClose: () => void;
  printing: boolean;
}) {
  const { ui } = useT();
  if (typeof document === "undefined") return null;
  return createPortal(
    <div
      data-print-root=""
      className="fixed inset-0 z-50 overflow-y-auto bg-background/95 p-4 sm:p-8 print:static print:inset-auto print:z-auto print:overflow-visible print:bg-white print:p-0"
    >
      {/* The layout's paper, on the sheet's own page only. */}
      <style>{`@page sheet { size: ${pageSize(sheet.page)}; margin: 12mm; }`}</style>
      <section
        aria-label={sheet.title ?? ui("Count sheet")}
        className="mx-auto flex max-w-4xl flex-col gap-4 rounded-xl border border-border bg-card p-4 sm:p-5 print:max-w-none print:rounded-none print:border-0 print:bg-white print:p-0 print:text-black"
      >
        <div className="flex flex-wrap items-center justify-between gap-2 print:hidden">
          <p className="text-sm font-semibold">{sheet.title ?? ui("Count sheet")}</p>
          <div className="flex gap-2">
            <ActionButton variant="secondary" busy={printing} onClick={onPrint}>
              {ui("Print the count sheet")}
            </ActionButton>
            <ActionButton variant="secondary" onClick={onClose}>
              {ui("Close")}
            </ActionButton>
          </div>
        </div>
        {(sheet.blocks ?? []).map((b, i) => (
          <Block key={`${b.kind}-${i}`} block={b} />
        ))}
      </section>
    </div>,
    document.body,
  );
}
