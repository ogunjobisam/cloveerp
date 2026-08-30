import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Handshake, ArrowLeftRight } from "lucide-react";

import { friendlyError } from "@/lib/errors";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  type OwnershipTransfer,
  type PlatformRole,
  type PlatformStaff,
  type PlatformTenant,
} from "../../lib/platform";
import { Pill, Table } from "./panel";
import { TOUCH } from "./page";

/**
 * Handing a company to another owner.
 *
 * Two-sided on purpose. An owner offers; the receiving owner accepts. Nothing
 * moves on one person's say-so, and nothing is erased when it does move: the
 * offer keeps its own row in whatever state it ended, and every step is written
 * to the platform activity trail, so the chain of custody reads end to end long
 * after the handover.
 */

const BTN =
  "inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium";

function Fail({ error }: { error: unknown }) {
  const f = friendlyError(error);
  return (
    <div role="alert" className="rounded-lg border border-destructive/30 bg-destructive/5 p-3">
      <p className="text-sm font-medium text-destructive">{f.title}</p>
      {f.body ? <p className="mt-1 text-xs text-muted-foreground">{f.body}</p> : null}
    </div>
  );
}

function transferTone(status: string): "ok" | "warn" | "bad" | "muted" {
  if (status === "accepted") return "ok";
  if (status === "pending") return "warn";
  if (status === "declined") return "bad";
  return "muted";
}

/** The offer control that lives in the companies table, one row at a time. */
export function OfferOwnership({ tenant, role }: { tenant: PlatformTenant; role: PlatformRole }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [to, setTo] = useState("");
  const [reason, setReason] = useState("");

  const staff = useQuery({
    queryKey: ["erp_platform_staff"],
    queryFn: () => callErp<PlatformStaff[]>("erp_platform_staff"),
    enabled: open,
  });

  const offer = useMutation({
    mutationFn: () =>
      callErp("erp_platform_offer_ownership", {
        p_tenant_id: tenant.id,
        p_to_staff_id: to,
        p_reason: reason || null,
      }),
    onSuccess: async () => {
      setOpen(false);
      setTo("");
      setReason("");
      await queryClient.invalidateQueries();
    },
  });

  // Only an owner may hand a company on, and only the owner who holds it.
  if (!atLeast(role, "owner")) return null;
  if (tenant.owner_staff_id && !tenant.owned_by_me) return null;
  if (tenant.status === "deleted") return null;

  const candidates = (staff.data ?? []).filter(
    (s) => s.role === "owner" && !s.revoked_at && s.id !== tenant.owner_staff_id,
  );

  if (tenant.pending_transfer_to) {
    return (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <Handshake className="size-3.5" />
        Offered to {tenant.pending_transfer_to}
      </span>
    );
  }

  return (
    <span className="inline-flex flex-col gap-2">
      <button type="button" onClick={() => setOpen((v) => !v)} className={BTN}>
        <ArrowLeftRight className="size-3.5" />
        {open ? "Cancel" : "Transfer"}
      </button>

      {open ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (to) offer.mutate();
          }}
          className="flex w-64 flex-col gap-2 rounded-lg border border-border bg-card p-3"
        >
          <label className="block text-xs font-medium">
            Hand to
            <select
              required
              value={to}
              onChange={(e) => setTo(e.target.value)}
              className="mt-1 w-full rounded-md border border-input bg-background px-2 py-1.5 text-xs"
            >
              <option value="">Choose an owner…</option>
              {candidates.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.display_name} · {s.email}
                </option>
              ))}
            </select>
          </label>
          {staff.data && candidates.length === 0 ? (
            <p className="text-xs text-muted-foreground">
              There is no other platform owner to hand this to yet.
            </p>
          ) : null}
          <label className="block text-xs font-medium">
            Why
            <input
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Recorded against your name"
              className="mt-1 w-full rounded-md border border-input bg-background px-2 py-1.5 text-xs"
            />
          </label>
          <button
            type="submit"
            disabled={offer.isPending || !to}
            className={`${TOUCH} rounded-md bg-primary px-3 text-xs font-semibold text-primary-foreground disabled:opacity-60`}
          >
            {offer.isPending ? "Offering…" : "Send offer"}
          </button>
          <p className="text-[11px] text-muted-foreground">
            They must accept before ownership moves. The offer lapses after seven days.
          </p>
          {offer.error ? <Fail error={offer.error} /> : null}
        </form>
      ) : null}
    </span>
  );
}

/** The whole record of handovers: open offers first, then everything settled. */
export function Ownership() {
  const queryClient = useQueryClient();

  const transfers = useQuery({
    queryKey: ["erp_platform_ownership_transfers"],
    queryFn: () =>
      callErp<OwnershipTransfer[]>("erp_platform_ownership_transfers", {
        p_tenant_id: null,
        p_limit: 200,
      }),
  });

  const respond = useMutation({
    mutationFn: (v: { id: string; accept: boolean; note?: string | undefined }) =>
      callErp("erp_platform_respond_ownership_transfer", {
        p_transfer_id: v.id,
        p_accept: v.accept,
        p_note: v.note ?? null,
      }),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const withdraw = useMutation({
    mutationFn: (v: { id: string; reason?: string | undefined }) =>
      callErp("erp_platform_cancel_ownership_transfer", {
        p_transfer_id: v.id,
        p_reason: v.reason ?? null,
      }),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const rows = transfers.data ?? [];
  const mine = rows.filter((r) => r.is_mine_to_answer);
  const error = transfers.error ?? respond.error ?? withdraw.error ?? null;

  return (
    <div className="flex flex-col gap-5">
      {error ? <Fail error={error} /> : null}

      {mine.length > 0 ? (
        <section className="surface-card rounded-xl border border-primary/40 bg-primary/5 p-5">
          <h2 className="flex items-center gap-2 font-display text-base font-semibold">
            <Handshake className="size-4 text-primary" />
            Waiting on you
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            A company has been offered to you. Accepting makes you the owner of record; declining
            leaves it exactly where it is. Either way the offer stays in the trail.
          </p>
          <div className="mt-4 flex flex-col gap-3">
            {mine.map((r) => (
              <div
                key={r.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border bg-card p-3"
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium">
                    {r.tenant_name} <span className="font-mono text-xs">({r.tenant_code})</span>
                  </p>
                  <p className="text-xs text-muted-foreground">
                    From {r.from_name} · {r.from_email}
                    {r.reason ? ` · ${r.reason}` : ""}
                  </p>
                  <p className="text-[11px] text-muted-foreground">
                    Lapses {new Date(r.expires_at).toLocaleString()}
                  </p>
                </div>
                <div className="flex gap-2">
                  <button
                    type="button"
                    disabled={respond.isPending}
                    onClick={() => respond.mutate({ id: r.id, accept: true })}
                    className={`${TOUCH} rounded-md bg-primary px-3 text-xs font-semibold text-primary-foreground disabled:opacity-60`}
                  >
                    Accept
                  </button>
                  <button
                    type="button"
                    disabled={respond.isPending}
                    onClick={() => {
                      const note = window.prompt(`Why are you declining ${r.tenant_name}?`);
                      if (note !== null)
                        respond.mutate({ id: r.id, accept: false, note: note || undefined });
                    }}
                    className={BTN}
                  >
                    Decline
                  </button>
                </div>
              </div>
            ))}
          </div>
        </section>
      ) : null}

      <section className="surface-card rounded-xl border border-border bg-card p-5">
        <h2 className="flex items-center gap-2 font-display text-base font-semibold">
          <ArrowLeftRight className="size-4 text-primary" />
          Handover history
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Every offer ever made, in whatever state it ended. Nothing here is removed.
        </p>
        <div className="mt-4">
          {transfers.isPending ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : rows.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No company has been handed over yet. Offer one from the Companies tab.
            </p>
          ) : (
            <Table columns={["Company", "From", "To", "Status", "When", ""]}>
              {rows.map((r) => (
                <tr key={r.id} className="border-b border-border/60 align-top last:border-0">
                  <td className="py-3 pr-4">
                    <div className="text-sm font-medium">{r.tenant_name ?? "—"}</div>
                    <div className="font-mono text-xs text-muted-foreground">{r.tenant_code}</div>
                  </td>
                  <td className="py-3 pr-4 text-xs">{r.from_email}</td>
                  <td className="py-3 pr-4 text-xs">{r.to_email}</td>
                  <td className="py-3 pr-4">
                    <Pill tone={transferTone(r.status)}>{r.status}</Pill>
                    {r.reason || r.response_note ? (
                      <div className="mt-1 text-[11px] text-muted-foreground">
                        {[r.reason, r.response_note].filter(Boolean).join(" · ")}
                      </div>
                    ) : null}
                  </td>
                  <td className="py-3 pr-4 text-xs text-muted-foreground">
                    {new Date(r.created_at).toLocaleString()}
                    {r.settled_at ? (
                      <div>settled {new Date(r.settled_at).toLocaleString()}</div>
                    ) : null}
                  </td>
                  <td className="py-3 pr-0">
                    {r.is_mine_to_withdraw ? (
                      <button
                        type="button"
                        disabled={withdraw.isPending}
                        onClick={() => {
                          const reason = window.prompt("Why are you withdrawing this offer?");
                          if (reason !== null)
                            withdraw.mutate({ id: r.id, reason: reason || undefined });
                        }}
                        className={BTN}
                      >
                        Withdraw
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </Table>
          )}
        </div>
      </section>
    </div>
  );
}
