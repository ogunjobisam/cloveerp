import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { SeedDemoAction } from "../../components/erp/seed";

export const Route = createFileRoute("/sales/")({
  head: () => ({ meta: [{ title: "Sales — ERPWare" }] }),
  component: () => (
    <Gate>
      <Sales />
    </Gate>
  ),
});

type Doc = {
  document_id: string;
  document_number: string;
  document_type: string;
  document_date: string;
  currency: string;
  party: string | null;
  total_minor: number;
  state: string | null;
  state_name: string | null;
  is_committed: boolean;
};

/** Minor units are the storage; a person reads major. */
function money(minor: number, currency: string) {
  return new Intl.NumberFormat(undefined, {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
  }).format((minor ?? 0) / 100);
}

function DocTable({ rows }: { rows: Doc[] }) {
  return (
    <Table columns={["Number", "Date", "Party", "Value", "State"]}>
      {rows.map((d) => (
        <tr key={d.document_id} className="border-b border-border/50 last:border-0">
          <td className="py-2 pr-4 font-mono text-xs">{d.document_number}</td>
          <td className="py-2 pr-4 text-xs text-muted-foreground">{d.document_date}</td>
          <td className="py-2 pr-4">{d.party ?? "—"}</td>
          <td className="py-2 pr-4 text-right tabular-nums">{money(d.total_minor, d.currency)}</td>
          <td className="py-2 pr-4">
            {/*
              Committed is the distinction that matters operationally: it is the
              point past which the outside world believes the document, and for
              a delivery it is the moment stock actually left.
            */}
            <Pill tone={d.is_committed ? "ok" : "muted"}>{d.state_name ?? d.state ?? "—"}</Pill>
          </td>
        </tr>
      ))}
    </Table>
  );
}

function Sales() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Sales">
        Quotation to order to delivery. None of this is a table of its own — all three are
        configured document types on one spine, and posting a delivery moves stock through the same
        function a goods receipt uses, with the sign coming from the movement type.
      </PageHeader>

      <DataPanel<Doc>
        title="Quotations"
        description="Offers, before they are orders."
        fn="erp_documents"
        args={{ p_type_code: "quotation" }}
        empty="No quotations yet."
        emptyAction={<SeedDemoAction />}
      >
        {(rows) => <DocTable rows={rows} />}
      </DataPanel>

      <DataPanel<Doc>
        title="Sales orders"
        description="Commitments to a customer. Discount and credit bands decide what needs approving."
        fn="erp_documents"
        args={{ p_type_code: "sales_order" }}
        empty="No sales orders yet."
        emptyAction={<SeedDemoAction />}
      >
        {(rows) => <DocTable rows={rows} />}
      </DataPanel>

      <DataPanel<Doc>
        title="Deliveries"
        description="Goods leaving. Posting one is what takes the stock off the shelf."
        fn="erp_documents"
        args={{ p_type_code: "delivery" }}
        empty="No deliveries yet."
        emptyAction={<SeedDemoAction />}
      >
        {(rows) => <DocTable rows={rows} />}
      </DataPanel>
    </div>
  );
}
