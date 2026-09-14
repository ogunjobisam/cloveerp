import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Mail } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { atLeast, type PlatformRole } from "../../lib/platform";
import { ReasonDialog } from "./dialogs";
import { Card, Fail } from "./kit";

/**
 * The enquiries the website collects.
 *
 * The read and the erasure door both existed and nothing in the console reached
 * them, so the only way to see who had asked about the product was to query the
 * database. An enquiry is commercial information about a person, so the owner
 * can erase one and the erasure is itself recorded.
 *
 * An operator can also mark one handled, with a note of what was done, which
 * takes it off Today without destroying it: on 14 September two test
 * enquiries from before the sender was set up sat on Today as "not emailed to
 * you" with no way to clear them short of erasing them.
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
  handled_at: string | null;
  handled_by: string | null;
  handled_note: string | null;
};

export function Enquiries({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState<string | null>(null);
  const mayErase = atLeast(role, "owner");
  const mayHandle = atLeast(role, "operator");

  const rows = useQuery({
    queryKey: ["erp_platform_enquiries"],
    queryFn: () => callErp<Enquiry[]>("erp_platform_enquiries", { p_limit: 200 }),
  });

  return (
    <Card
      title="Enquiries"
      icon={<Mail className="size-4 text-primary" />}
      description="What the website has collected, and whether each one reached you. Newest first."
    >
      {rows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : rows.error ? (
        <Fail error={rows.error} />
      ) : (rows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nobody has asked anything yet.</p>
      ) : (
        <Table columns={["When", "Who", "Organisation", "Notified", mayHandle ? "Actions" : ""]}>
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
                {e.handled_at ? (
                  <div className="mt-2 text-xs">
                    <Pill tone="muted">Handled</Pill>
                    <span className="ml-1 text-muted-foreground">
                      {new Date(e.handled_at).toLocaleDateString()} by {e.handled_by}:{" "}
                      {e.handled_note}
                    </span>
                  </div>
                ) : null}
              </td>
              <td className="py-3 pr-0">
                <div className="flex flex-wrap items-start gap-2">
                  {e.status !== "erased" && e.email ? (
                    <a
                      href={`mailto:${e.email}?subject=${encodeURIComponent("Your enquiry to Clove ERP")}`}
                      className="rounded-md border border-input px-2 py-1 text-xs font-medium"
                    >
                      Reply
                    </a>
                  ) : null}
                  {mayHandle && e.status !== "erased" && !e.handled_at ? (
                    <ReasonDialog
                      trigger={
                        <button
                          type="button"
                          className="rounded-md border border-input px-2 py-1 text-xs font-medium"
                        >
                          Mark handled
                        </button>
                      }
                      title={`Mark the enquiry from ${e.full_name ?? e.email ?? "this person"} handled`}
                      description="It stops needing anybody on Today. What the email did stays on record, and your note says what was done."
                      reasonLabel="What was done?"
                      placeholder="For example: replied by email and booked a demo"
                      submitLabel="Mark handled"
                      busyLabel="Saving…"
                      run={(note) =>
                        callErp("erp_platform_mark_enquiry_handled", { p_id: e.id, p_note: note })
                      }
                      onDone={() =>
                        void queryClient.invalidateQueries({ queryKey: ["erp_platform_enquiries"] })
                      }
                    />
                  ) : null}
                  {mayErase && e.status !== "erased" ? (
                    <ReasonDialog
                      trigger={
                        <button
                          type="button"
                          className="rounded-md border border-destructive/40 px-2 py-1 text-xs font-medium text-destructive"
                        >
                          Erase
                        </button>
                      }
                      title={`Erase the enquiry from ${e.full_name ?? e.email ?? "this person"}`}
                      description="Their name, email, organisation and message are removed for good. The enquiry stays in the list, marked erased, with your reason."
                      reasonLabel="Why is it being erased?"
                      placeholder="For example: they asked us to delete their details"
                      submitLabel="Erase"
                      busyLabel="Erasing…"
                      danger
                      run={(reason) =>
                        callErp("erp_platform_erase_enquiry", { p_id: e.id, p_reason: reason })
                      }
                      onDone={() =>
                        void queryClient.invalidateQueries({ queryKey: ["erp_platform_enquiries"] })
                      }
                    />
                  ) : null}
                </div>
              </td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  );
}
