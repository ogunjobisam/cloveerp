import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { chargeWords, landedCosts } from "../../lib/landed-costs";
import { formatMinor, isoMinorUnits } from "../../lib/money";
import { ErrorNote } from "./action";
import { Prose } from "./page";
import { Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Landed costs, on the Purchasing screen (20261004970000): each supplier's
 * bill for a charge on goods received, the receipt it was charged on, and how
 * much of it landed on the stock still held and how much stayed a cost of
 * sales. Bill a landed cost raises one.
 */
export function LandedCosts() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_landed_costs"],
    queryFn: () => callErp<unknown>("erp_landed_costs", { p_limit: 50 }),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const costs = landedCosts(data);
  const money = (n: number | null, currency: string) =>
    n === null ? "—" : formatMinor(n, currency, isoMinorUnits(currency));

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Landed costs")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui(
          "Duty, brokerage and other charges billed on goods received, and how much of each landed on the stock.",
        )}
      </Prose>
      <ErrorNote error={error} />
      {costs.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui("Nothing billed yet. Bill a landed cost against a posted receipt and it lands here.")}
        </p>
      ) : (
        <div className="mt-3">
          <Table
            columns={[
              ui("Bill"),
              ui("Receipt"),
              ui("Supplier"),
              ui("Charge"),
              ui("Net amount"),
              ui("Landed"),
              ui("Expensed"),
            ]}
          >
            {costs.map((c) => (
              <tr key={c.id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">
                  {c.billId ? (
                    <Link
                      to="/documents/$documentId"
                      params={{ documentId: c.billId }}
                      className="font-medium underline underline-offset-2"
                    >
                      {c.bill}
                    </Link>
                  ) : (
                    c.bill
                  )}
                </td>
                <td className="py-2 pr-4">
                  {c.receiptId ? (
                    <Link
                      to="/documents/$documentId"
                      params={{ documentId: c.receiptId }}
                      className="underline underline-offset-2"
                    >
                      {c.receipt}
                    </Link>
                  ) : (
                    c.receipt
                  )}
                </td>
                <td className="py-2 pr-4">{c.supplier}</td>
                <td className="py-2 pr-4">{ui(chargeWords(c.charge))}</td>
                <td className="py-2 pr-4 tabular-nums">{money(c.amountMinor, c.currency)}</td>
                <td className="py-2 pr-4 tabular-nums">{money(c.capitalisedMinor, c.currency)}</td>
                <td className="py-2 tabular-nums">{money(c.expensedMinor, c.currency)}</td>
              </tr>
            ))}
          </Table>
        </div>
      )}
    </section>
  );
}
