import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ErrorNote } from "./action";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Why this wave will not print.
 *
 * Gating a print on full allocation is only defensible if the refusal is
 * legible: which lines are short, by how much, and which of the three reasons
 * applies — nothing at the site, stock at the site but not in the area with a
 * replenishment task open, or stock that cannot be moved in at all. The
 * printing button lives here rather than in the action bar so that the refusal
 * lands next to the evidence for it.
 */

type Wave = { wave_id: string; code: string; release_area: string; status: string };

type ReadinessLine = {
  item_code: string;
  item_name: string;
  wanted: number;
  allocated: number;
  short: number;
  cause: string;
  explanation: string;
};

type Readiness = {
  wave_code: string;
  status: string;
  gate_printing: boolean;
  short_lines: number;
  can_print: boolean;
  lines: ReadinessLine[];
  replenishment_tasks: { item_code: string; quantity: number; status: string }[];
};

export function WavePrintReadiness() {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [waveId, setWaveId] = useState("");

  const waves = useQuery({
    queryKey: ["erp_release_waves", { p_limit: 100 }],
    queryFn: () => callErp<Wave[]>("erp_release_waves", { p_limit: 100 }),
  });

  const readiness = useQuery({
    queryKey: ["erp_wave_print_readiness", waveId],
    queryFn: () => callErp<Readiness>("erp_wave_print_readiness", { p_wave_id: waveId }),
    enabled: waveId !== "",
  });

  const print = useMutation({
    mutationFn: () => callErp("erp_print_release_wave", { p_wave_id: waveId }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["erp_release_waves"] });
      void readiness.refetch();
    },
  });

  const r = readiness.data;

  return (
    <section className="rounded-xl border border-border bg-card p-4 sm:p-5">
      <h3 className="text-sm font-semibold">{ui("Printing readiness")}</h3>
      <p className="mt-1 text-xs text-muted-foreground">
        {ui(
          "Pick a wave to see exactly what is short and why before printing is attempted, rather than after it is refused.",
        )}
      </p>

      <div className="mt-4 flex flex-wrap items-end gap-2">
        <label className="flex min-w-64 flex-col gap-1 text-xs">
          <span className="text-muted-foreground">{ui("Wave")}</span>
          <select
            className="h-10 rounded-md border border-border bg-background px-2 text-sm"
            value={waveId}
            onChange={(e) => setWaveId(e.target.value)}
          >
            <option value="">{ui("Choose a wave")}</option>
            {(waves.data ?? []).map((w) => (
              <option key={w.wave_id} value={w.wave_id}>
                {w.code} — {w.release_area} ({w.status})
              </option>
            ))}
          </select>
        </label>

        {r && hasPermission(session, "logistics.despatch") ? (
          <ActionButton
            busy={print.isPending}
            disabled={!r.can_print}
            title={r.can_print ? undefined : "This wave has lines that have not allocated in full."}
            onClick={() => print.mutate()}
          >
            {ui("Print the wave")}
          </ActionButton>
        ) : null}
      </div>

      <div className="mt-3 space-y-3">
        <ErrorNote error={waves.error} />
        <ErrorNote error={readiness.error} />
        <ErrorNote error={print.error} />
      </div>

      {r ? (
        <div className="mt-4 flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-2 text-xs">
            <Pill tone={r.can_print ? "ok" : "warn"}>
              {r.can_print ? ui("Ready to print") : ui("Printing blocked")}
            </Pill>
            <Pill tone="muted">
              {r.short_lines} {ui("short line(s)")}
            </Pill>
            <Pill tone="muted">
              {r.gate_printing ? ui("Gated on full allocation") : ui("Printing not gated")}
            </Pill>
          </div>

          {r.lines.length > 0 ? (
            <Table
              columns={[ui("Item"), ui("Wanted"), ui("Allocated"), ui("Short"), ui("Why")]}
            >
              {r.lines.map((l) => (
                <tr key={l.item_code} className="border-b border-border/60 last:border-0">
                  <td className="py-2 pr-4 font-mono text-xs">{l.item_code}</td>
                  <td className="py-2 pr-4 tabular-nums">{l.wanted}</td>
                  <td className="py-2 pr-4 tabular-nums">{l.allocated}</td>
                  <td className="py-2 pr-4 tabular-nums">{l.short}</td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{l.explanation}</td>
                </tr>
              ))}
            </Table>
          ) : (
            <p className="text-xs text-muted-foreground">
              {ui("Every line on this wave has allocated in full.")}
            </p>
          )}

          {r.replenishment_tasks.length > 0 ? (
            <div>
              <p className="text-xs font-medium">{ui("Replenishment raised by this wave")}</p>
              <Table columns={[ui("Item"), ui("Quantity"), ui("Status")]}>
                {r.replenishment_tasks.map((t, i) => (
                  <tr key={`${t.item_code}-${i}`} className="border-b border-border/60 last:border-0">
                    <td className="py-2 pr-4 font-mono text-xs">{t.item_code}</td>
                    <td className="py-2 pr-4 tabular-nums">{t.quantity}</td>
                    <td className="py-2 pr-4">
                      <Pill tone={t.status === "done" ? "ok" : "warn"}>{t.status}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            </div>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
