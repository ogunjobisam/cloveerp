import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Mail } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { atLeast, type PlatformRole } from "../../lib/platform";
import { Card, Fail } from "./kit";

/**
 * The enquiries the website collects.
 *
 * The read and the erasure door both existed and nothing in the console reached
 * them, so the only way to see who had asked about the product was to query the
 * database. An enquiry is commercial information about a person, so the owner
 * can erase one and the erasure is itself recorded.
 */

type Enquiry = {
  id: string;
  submitted_at: string;
  full_name: string | null;
  email: string | null;
  organisation: string | null;
  message: string | null;
  source_page: string | null;
  status: string;
  notified_at: string | null;
  failure_reason: string | null;
};

export function Enquiries({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState<string | null>(null);
  const mayErase = atLeast(role, "owner");

  const rows = useQuery({
    queryKey: ["erp_platform_enquiries"],
    queryFn: () => callErp<Enquiry[]>("erp_platform_enquiries", { p_limit: 200 }),
  });

  const erase = useMutation({
    mutationFn: (v: { id: string; reason: string }) =>
      callErp("erp_platform_erase_enquiry", { p_id: v.id, p_reason: v.reason }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["erp_platform_enquiries"] }),
  });

  return (
    <Card
      title="Enquiries"
      icon={<Mail className="size-4 text-primary" />}
      description="What the website has collected, and whether each one reached you. Newest first."
    >
      {erase.error ? (
        <div className="mb-4">
          <Fail error={erase.error} />
        </div>
      ) : null}

      {rows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : rows.error ? (
        <Fail error={rows.error} />
      ) : (rows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nobody has asked anything yet.</p>
      ) : (
        <Table columns={["When", "Who", "Organisation", "Notified", mayErase ? "Actions" : ""]}>
          {(rows.data ?? []).map((e) => (
            <tr key={e.id} className="border-b border-border/60 align-top last:border-0">
              <td className="py-3 pr-4 text-xs whitespace-nowrap text-muted-foreground">
                {new Date(e.submitted_at).toLocaleDateString()}
              </td>
              <td className="py-3 pr-4 text-sm">
                <div className="font-medium">{e.full_name ?? "—"}</div>
                <div className="text-xs text-muted-foreground">{e.email ?? "—"}</div>
                {e.message ? (
                  <button
                    type="button"
                    onClick={() => setOpen(open === e.id ? null : e.id)}
                    className="mt-1 text-xs underline underline-offset-2"
                  >
                    {open === e.id ? "Hide message" : "Read message"}
                  </button>
                ) : null}
                {open === e.id && e.message ? (
                  <p className="mt-2 max-w-prose text-xs whitespace-pre-wrap text-muted-foreground">
                    {e.message}
                  </p>
                ) : null}
              </td>
              <td className="py-3 pr-4 text-sm">
                <div>{e.organisation ?? "—"}</div>
                {e.source_page ? (
                  <div className="text-xs text-muted-foreground">{e.source_page}</div>
                ) : null}
              </td>
              <td className="py-3 pr-4 text-xs">
                <Pill tone={e.notified_at ? "ok" : e.failure_reason ? "bad" : "warn"}>
                  {e.notified_at ? "Sent" : e.failure_reason ? "Failed" : e.status}
                </Pill>
                {e.failure_reason ? (
                  <div className="mt-1 text-xs text-muted-foreground">{e.failure_reason}</div>
                ) : null}
              </td>
              <td className="py-3 pr-0">
                {mayErase ? (
                  <button
                    type="button"
                    onClick={() => {
                      const reason = window.prompt("Erase this enquiry? Reason:");
                      if (reason) erase.mutate({ id: e.id, reason });
                    }}
                    className="rounded-md border border-destructive/40 px-2 py-1 text-xs font-medium text-destructive"
                  >
                    Erase
                  </button>
                ) : null}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  );
}
