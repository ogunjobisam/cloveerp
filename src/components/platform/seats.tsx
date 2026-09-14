import { useQuery } from "@tanstack/react-query";

import { callErp } from "../../lib/erp";
import { seatFigure, type PlatformSeats, type SeatFigure } from "../../lib/platform-seats";
import { Fail } from "./kit";

/**
 * An organisation's full and light users, with the limit each is sold against.
 *
 * Read from erp_platform_seats, which counts people the way the meter does, so
 * the figure here is the one an invoice would use. Console text is not tenant
 * terminology, so the figure takes a `caption`, not a `label`.
 */
export function Seats({ tenantId }: { tenantId: string }) {
  const q = useQuery({
    queryKey: ["erp_platform_seats", tenantId],
    queryFn: () => callErp<PlatformSeats>("erp_platform_seats", { p_tenant_id: tenantId }),
  });

  if (q.isPending) {
    return <p className="mt-3 text-xs text-muted-foreground">Counting full and light users…</p>;
  }
  if (q.error) {
    return (
      <div className="mt-3">
        <Fail error={q.error} />
      </div>
    );
  }

  return (
    <div className="mt-3 grid grid-cols-2 gap-3">
      <SeatTile caption="Full users" figure={seatFigure(q.data.full)} />
      <SeatTile caption="Light users" figure={seatFigure(q.data.light)} />
    </div>
  );
}

function SeatTile({ caption, figure }: { caption: string; figure: SeatFigure }) {
  return (
    <div className="rounded-lg border border-border/60 p-3">
      <div className="text-xs text-muted-foreground">{caption}</div>
      <div className="mt-1 text-lg font-semibold tabular-nums">{figure.value}</div>
      <div
        className={`mt-0.5 text-xs ${figure.over ? "text-destructive" : "text-muted-foreground"}`}
      >
        {figure.hint}
      </div>
    </div>
  );
}
