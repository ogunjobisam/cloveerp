import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { AtSign, Mail } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import {
  readAddressList,
  readEnquiryNotify,
  rejectedAddresses,
  type EnquiryNotify,
} from "../../lib/enquiry-notify";
import { atLeast, type PlatformRole } from "../../lib/platform";
import { ReasonDialog } from "./dialogs";
import { Card, Fail, INPUT } from "./kit";

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
  const mayErase = atLeast(role, "administrator");
  const mayHandle = atLeast(role, "operator");

  const rows = useQuery({
    queryKey: ["erp_platform_enquiries"],
    queryFn: () => callErp<Enquiry[]>("erp_platform_enquiries", { p_limit: 200 }),
  });

  return (
    <div className="flex flex-col gap-6">
      <NotifyTo role={role} />
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
                          void queryClient.invalidateQueries({
                            queryKey: ["erp_platform_enquiries"],
                          })
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
                          void queryClient.invalidateQueries({
                            queryKey: ["erp_platform_enquiries"],
                          })
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
    </div>
  );
}

/**
 * Where a new enquiry is sent.
 *
 * Until 20260920500000 this was whoever held platform owner, so moving the
 * leads meant handing somebody the console or taking it off the person who had
 * it. It is now a setting, and owning the platform went back to meaning what it
 * says. Support and operators can see where the leads go — they are the people
 * who notice when the mailbox goes quiet — and only an owner may move them.
 *
 * Two lists, because they answer different questions: what somebody set, and
 * where the next enquiry actually goes. They differ exactly when nothing is
 * set, and that is the case most worth saying out loud rather than leaving to
 * be inferred from an empty field.
 */
function NotifyTo({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const mayMove = atLeast(role, "owner");
  const [editing, setEditing] = useState(false);
  const [typed, setTyped] = useState("");
  const [reason, setReason] = useState("");

  const state = useQuery({
    queryKey: NOTIFY_TO_KEY,
    queryFn: () => callErp<unknown>("erp_platform_enquiry_notify_to"),
  });
  const now: EnquiryNotify | null = state.isSuccess ? readEnquiryNotify(state.data) : null;

  const move = useMutation({
    mutationFn: (v: { emails: string[]; reason: string }) =>
      callErp<unknown>("erp_platform_set_enquiry_notify_to", {
        p_emails: v.emails,
        p_reason: v.reason.trim(),
      }),
    onSuccess: () => {
      setEditing(false);
      setReason("");
      void queryClient.invalidateQueries({ queryKey: NOTIFY_TO_KEY });
    },
  });

  const ask = () => {
    move.reset();
    setTyped((now?.configured ?? []).join(", "));
    setReason("");
    setEditing(true);
  };

  const wrong = rejectedAddresses(typed);
  const sendable = wrong.length === 0 && reason.trim() !== "";

  return (
    <Card
      title="Where enquiries are sent"
      icon={<AtSign className="size-4 text-primary" />}
      description="The mailbox that hears about a new enquiry from the website. The enquirer's own address is always the reply-to, whatever is set here."
    >
      {state.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : state.error ? (
        <Fail error={state.error} />
      ) : now === null ? (
        <p className="text-sm text-muted-foreground">
          This console could not read where enquiries are sent.
        </p>
      ) : (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0">
              <p className="flex flex-wrap items-center gap-2 text-sm font-medium">
                A new enquiry goes to
                {now.recipients.length === 0 ? (
                  <Pill tone="bad">Nobody</Pill>
                ) : (
                  now.recipients.map((r) => (
                    <Pill key={r} tone="ok">
                      {r}
                    </Pill>
                  ))
                )}
              </p>
              <p className="mt-1 max-w-prose text-xs text-muted-foreground">
                {now.recipients.length === 0
                  ? "No address is set and no platform owner is left to fall back to. Enquiries are still stored, and nobody is being told about them."
                  : now.fallsBackToOwners
                    ? "No address is set, so enquiries go to the platform owners. Setting one separates answering a lead from holding the console."
                    : now.reason
                      ? `Set because: ${now.reason}${now.updatedAt ? `, ${when(now.updatedAt)}` : ""}.`
                      : "Set from this console. The change is recorded in Activity."}
              </p>
            </div>
            {mayMove && !editing ? (
              <button
                type="button"
                onClick={ask}
                className={`${TOUCH} shrink-0 rounded-md border border-input px-3 text-sm font-medium`}
              >
                {now.fallsBackToOwners ? "Set an address" : "Change"}
              </button>
            ) : null}
          </div>

          {editing ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (sendable) move.mutate({ emails: readAddressList(typed), reason });
              }}
              className="rounded-lg border border-border p-3"
            >
              <label className="block text-sm font-medium">
                Address
                <input
                  type="text"
                  value={typed}
                  onChange={(e) => setTyped(e.target.value)}
                  placeholder="sales@cloveerp.com"
                  aria-describedby="notify-to-hint"
                  className={INPUT}
                />
              </label>
              <p id="notify-to-hint" className="mt-1 text-xs text-muted-foreground">
                More than one is allowed, separated by commas — each gets its own copy. Leave it
                empty to send enquiries to the platform owners instead.
              </p>
              {wrong.length > 0 ? (
                <p role="alert" className="mt-2 text-xs text-destructive">
                  {wrong.join(", ")} {wrong.length === 1 ? "does" : "do"} not look like an email
                  address.
                </p>
              ) : null}
              <label className="mt-3 block text-sm font-medium">
                Reason
                <textarea
                  required
                  rows={2}
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Why, for the platform's record"
                  className={INPUT}
                />
              </label>
              {move.error ? (
                <div className="mt-3">
                  <Fail error={move.error} />
                </div>
              ) : null}
              <div className="mt-3 flex flex-wrap gap-2">
                <button
                  type="submit"
                  disabled={move.isPending || !sendable}
                  className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
                >
                  {move.isPending
                    ? "Saving…"
                    : readAddressList(typed).length === 0
                      ? "Send to the owners"
                      : "Save"}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    move.reset();
                    setEditing(false);
                  }}
                  disabled={move.isPending}
                  className={`${TOUCH} rounded-md border border-input px-4 text-sm font-medium disabled:opacity-60`}
                >
                  Cancel
                </button>
              </div>
            </form>
          ) : null}
        </div>
      )}
    </Card>
  );
}

const NOTIFY_TO_KEY = ["erp_platform_enquiry_notify_to"];

function when(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}
