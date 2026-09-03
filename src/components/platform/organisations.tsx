import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import {
  Archive,
  Building2,
  ClipboardList,
  Copy,
  Gavel,
  LogIn,
  LogOut,
  Pause,
  Play,
  Plus,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
} from "lucide-react";

import { OfferOwnership } from "../erp/ownership";
import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  ROLE_BLURB,
  type PlatformAuditRow,
  type PlatformRole,
  type PlatformStaff,
  type PlatformTenant,
  type MyTenancy,
} from "../../lib/platform";
import { Card, Fail, TokenNotice, statusTone, INPUT } from "./kit";

/** Organisations, and everything done to one.
 *
 * Ownership lives here too. It was a tab of its own for an action taken once
 * in the life of a company, and it belongs beside the company it transfers. */

export function Companies({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const mayOperate = atLeast(role, "operator");

  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({
    code: "",
    name: "",
    admin_email: "",
    admin_display_name: "",
    currency: "GBP",
    country: "GB",
  });
  const [token, setToken] = useState<{ email: string; token: string } | null>(null);

  const tenants = useQuery({
    queryKey: ["erp_platform_tenants"],
    queryFn: () => callErp<PlatformTenant[]>("erp_platform_tenants"),
  });

  const refresh = () => queryClient.invalidateQueries();

  const onboard = useMutation({
    mutationFn: () =>
      callErp<{ admin_email: string; admin_token: string; is_live: boolean }>(
        "erp_platform_onboard_company",
        {
          p_code: form.code,
          p_name: form.name,
          p_admin_email: form.admin_email,
          p_admin_display_name: form.admin_display_name || form.admin_email,
          p_base_currency: form.currency,
          p_country_code: form.country,
        },
      ),
    onSuccess: (r) => {
      setToken({ email: r.admin_email, token: r.admin_token });
      setOpen(false);
      setForm({
        code: "",
        name: "",
        admin_email: "",
        admin_display_name: "",
        currency: "GBP",
        country: "GB",
      });
      void refresh();
    },
  });

  const setStatus = useMutation({
    mutationFn: (v: { id: string; status: string; reason?: string }) =>
      callErp("erp_platform_set_tenant_status", {
        p_tenant_id: v.id,
        p_status: v.status,
        p_reason: v.reason ?? null,
      }),
    onSuccess: refresh,
  });

  const invite = useMutation({
    mutationFn: (v: { id: string; email: string; name: string }) =>
      callErp<{ email: string; token: string }>("erp_platform_invite_admin", {
        p_tenant_id: v.id,
        p_email: v.email,
        p_display_name: v.name,
      }),
    onSuccess: (r) => {
      setToken({ email: r.email, token: r.token });
      void refresh();
    },
  });

  /**
   * Which organisations you are currently inside.
   *
   * Entering grants you the administrator role there — a real grant on a real
   * principal — and until now nothing in the product showed that, or offered a
   * way out. Leaving revokes it.
   */
  const mine = useQuery({
    queryKey: ["erp_platform_my_tenancies"],
    queryFn: () => callErp<MyTenancy[]>("erp_platform_my_tenancies"),
  });
  const inside = new Set((mine.data ?? []).filter((m) => m.is_active).map((m) => m.tenant_id));

  const leave = useMutation({
    mutationFn: (id: string) => callErp("erp_platform_leave_tenant", { p_tenant_id: id }),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const enter = useMutation({
    mutationFn: (v: { id: string; reason: string }) =>
      callErp("erp_platform_enter_tenant", { p_tenant_id: v.id, p_reason: v.reason }),
    onSuccess: async () => {
      await queryClient.invalidateQueries();
      void navigate({ to: "/" });
    },
  });

  /**
   * The one control here that removes data.
   *
   * "Mark ended" beside it writes a status and nothing else, which is why it no
   * longer says Delete. This is the button that actually empties an organisation, so
   * it asks for the code to be typed rather than accepting a click, and the
   * database refuses it on an organisation that is still active.
   */
  const purge = useMutation({
    mutationFn: (v: { id: string; code: string; reason: string }) =>
      callErp<{ code: string }>("erp_platform_purge_tenant", {
        p_tenant_id: v.id,
        p_confirm_code: v.code,
        p_reason: v.reason,
      }),
    onSuccess: refresh,
  });

  /** Finishes every deletion request whose grace period has elapsed. */
  const sweep = useMutation({
    mutationFn: (days: number) =>
      callErp<{ purged: number }>("erp_platform_purge_due_tenants", { p_grace_days: days }),
    onSuccess: refresh,
  });

  const busyError =
    onboard.error ??
    setStatus.error ??
    invite.error ??
    enter.error ??
    purge.error ??
    sweep.error ??
    tenants.error ??
    null;

  return (
    <div className="flex flex-col gap-5">
      {token ? (
        <TokenNotice
          email={token.email}
          token={token.token}
          /* An organisation is handed over in setup, not finished: its first
             administrator is its only one, and nobody may approve their own
             change set once it is live. Saying so here is cheaper than the
             support ticket that asks why nothing can be installed. */
          note={
            "The organisation is in setup. It installs and configures freely until it has a " +
            "second administrator and somebody takes it live."
          }
        />
      ) : null}
      {busyError ? <Fail error={busyError} /> : null}

      {mayOperate ? (
        <Card
          title="Onboard an organisation"
          icon={<Plus className="size-4 text-primary" />}
          description="Creates the organisation, its root company, its administrator role, and a single-use invitation for its first administrator."
          action={
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              className={`${TOUCH} rounded-md border border-input px-3 text-sm font-medium`}
            >
              {open ? "Close" : "New company"}
            </button>
          }
        >
          {open ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                onboard.mutate();
              }}
              className="grid gap-3 sm:grid-cols-2"
            >
              <label className="block text-sm font-medium">
                Organisation name
                <input
                  required
                  value={form.name}
                  onChange={(e) => setForm({ ...form, name: e.target.value })}
                  placeholder="Acme Manufacturing"
                  className={INPUT}
                />
              </label>
              <label className="block text-sm font-medium">
                Code
                <input
                  required
                  value={form.code}
                  onChange={(e) => setForm({ ...form, code: e.target.value })}
                  placeholder="acme"
                  className={`${INPUT} font-mono`}
                />
              </label>
              <label className="block text-sm font-medium">
                First administrator email
                <input
                  required
                  type="email"
                  value={form.admin_email}
                  onChange={(e) => setForm({ ...form, admin_email: e.target.value })}
                  className={INPUT}
                />
              </label>
              <label className="block text-sm font-medium">
                Their name
                <input
                  value={form.admin_display_name}
                  onChange={(e) => setForm({ ...form, admin_display_name: e.target.value })}
                  className={INPUT}
                />
              </label>
              <label className="block text-sm font-medium">
                Base currency
                <input
                  value={form.currency}
                  maxLength={3}
                  onChange={(e) => setForm({ ...form, currency: e.target.value.toUpperCase() })}
                  className={`${INPUT} font-mono`}
                />
              </label>
              <label className="block text-sm font-medium">
                Country
                <input
                  value={form.country}
                  maxLength={2}
                  onChange={(e) => setForm({ ...form, country: e.target.value.toUpperCase() })}
                  className={`${INPUT} font-mono`}
                />
              </label>
              <div className="sm:col-span-2">
                <button
                  type="submit"
                  disabled={onboard.isPending}
                  className={`${TOUCH} w-full rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60 sm:w-auto`}
                >
                  {onboard.isPending ? "Creating…" : "Create organisation"}
                </button>
              </div>
            </form>
          ) : (
            <p className="text-sm text-muted-foreground">
              The invitation token appears once, here, when the organisation is created.
            </p>
          )}
        </Card>
      ) : null}

      <Card
        title="Organisations"
        icon={<Building2 className="size-4 text-primary" />}
        description="Every organisation on this deployment. Suspending and marking ended change a status; purging is the only thing here that removes data."
      >
        {atLeast(role, "owner") ? (
          <div className="mb-4 flex flex-wrap items-center gap-3 rounded-lg border border-border bg-muted/40 px-3 py-2">
            <p className="min-w-0 flex-1 text-xs text-muted-foreground">
              When an administrator requests deletion, their organisation is suspended and its keys
              are destroyed, but its rows remain until they are purged. The sweep finishes every
              request older than the grace period. Nothing runs it on a schedule yet.
            </p>
            <button
              type="button"
              disabled={sweep.isPending}
              onClick={() => {
                const days = window.prompt(
                  "Purge every organisation whose deletion was requested more than how many days ago?",
                  "7",
                );
                if (days === null) return;
                const n = Number(days);
                if (!Number.isFinite(n) || n < 0) return;
                sweep.mutate(n);
              }}
              className="inline-flex shrink-0 items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
            >
              <Trash2 className="size-3.5" />
              {sweep.isPending ? "Sweeping…" : "Run deletion sweep"}
            </button>
          </div>
        ) : null}

        {sweep.isSuccess ? (
          <p className="mb-3 text-xs text-muted-foreground">
            Sweep purged {sweep.data?.purged ?? 0}{" "}
            {(sweep.data?.purged ?? 0) === 1 ? "organisation" : "organisations"}.
          </p>
        ) : null}

        {tenants.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (tenants.data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No organisations yet. Onboarding one is the first thing to do.
          </p>
        ) : (
          <Table columns={["Organisation", "Status", "Owner", "People", "Structure", "Actions"]}>
            {(tenants.data ?? []).map((t) => (
              <tr key={t.id} className="border-b border-border/60 last:border-0">
                <td className="py-3 pr-4">
                  <div className="font-medium">{t.name}</div>
                  <div className="font-mono text-xs text-muted-foreground">{t.code}</div>
                </td>
                <td className="py-3 pr-4">
                  <Pill tone={statusTone(t.status)}>{t.status}</Pill>
                </td>
                <td className="py-3 pr-4 text-xs">
                  {t.owner_email ? (
                    <>
                      <div className="text-sm">{t.owner_name ?? t.owner_email}</div>
                      <div className="text-muted-foreground">{t.owner_email}</div>
                    </>
                  ) : (
                    <span className="text-muted-foreground">Unassigned</span>
                  )}
                  {t.pending_transfer_to ? (
                    <div className="text-[11px] text-primary">
                      offer open to {t.pending_transfer_to}
                    </div>
                  ) : null}
                </td>
                <td className="py-3 pr-4 text-sm">
                  {t.principals}
                  {t.open_invitations > 0 ? (
                    <span className="ml-2 text-xs text-muted-foreground">
                      {t.open_invitations} invited
                    </span>
                  ) : null}
                </td>
                <td className="py-3 pr-4 text-xs text-muted-foreground">
                  {t.entities} entities · {t.sites} sites
                </td>
                <td className="py-3 pr-0">
                  <div className="flex flex-wrap gap-2">
                    {inside.has(t.id) ? (
                      <button
                        type="button"
                        disabled={leave.isPending}
                        onClick={() => leave.mutate(t.id)}
                        title="Ends your access and revokes the administrator role it granted you"
                        className="inline-flex items-center gap-1 rounded-md border border-primary/50 bg-primary/5 px-2 py-1 text-xs font-medium disabled:opacity-60"
                      >
                        <LogOut className="size-3.5" />
                        Leave
                      </button>
                    ) : (
                      <button
                        type="button"
                        onClick={() => {
                          const reason = window.prompt(
                            `Why are you entering ${t.name}? This is recorded against your name.`,
                          );
                          if (reason && reason.trim()) enter.mutate({ id: t.id, reason });
                        }}
                        className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
                      >
                        <LogIn className="size-3.5" />
                        Enter
                      </button>
                    )}

                    {mayOperate ? (
                      <>
                        <button
                          type="button"
                          onClick={() => {
                            const email = window.prompt(`Invite an administrator to ${t.name}:`);
                            if (!email) return;
                            const name = window.prompt("Their name:") ?? email;
                            invite.mutate({ id: t.id, email, name });
                          }}
                          className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
                        >
                          <UserPlus className="size-3.5" />
                          Invite admin
                        </button>

                        {t.status === "suspended" ? (
                          <button
                            type="button"
                            onClick={() => setStatus.mutate({ id: t.id, status: "active" })}
                            className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
                          >
                            <Play className="size-3.5" />
                            Reactivate
                          </button>
                        ) : t.status === "active" ? (
                          <button
                            type="button"
                            onClick={() => {
                              const reason = window.prompt(`Why is ${t.name} being suspended?`);
                              if (reason)
                                setStatus.mutate({ id: t.id, status: "suspended", reason });
                            }}
                            className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
                          >
                            <Pause className="size-3.5" />
                            Suspend
                          </button>
                        ) : null}

                        {/* A status, and only a status. It used to say Delete
                            and remove nothing, which is the whole reason
                            organisations piled up here. */}
                        {atLeast(role, "owner") && t.status !== "deleted" ? (
                          <button
                            type="button"
                            onClick={() => {
                              const reason = window.prompt(
                                `Mark ${t.name} as ended? This records a status and removes no ` +
                                  `data — purging is a separate step. Reason:`,
                              );
                              if (reason) setStatus.mutate({ id: t.id, status: "deleted", reason });
                            }}
                            className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
                          >
                            <Archive className="size-3.5" />
                            Mark ended
                          </button>
                        ) : null}

                        {/* This one empties it. Owner only, refused by the
                            database on an active company, and the code has to
                            be typed rather than a dialog dismissed. */}
                        {atLeast(role, "owner") && t.status !== "active" ? (
                          <button
                            type="button"
                            onClick={() => {
                              const code = window.prompt(
                                `Purge ${t.name} permanently?\n\n` +
                                  `Every row belonging to it is removed and cannot be recovered. ` +
                                  `Export first if the data is wanted.\n\n` +
                                  `Type its code (${t.code}) to confirm:`,
                              );
                              if (!code) return;
                              const reason = window.prompt("Why is it being purged?");
                              if (reason && reason.trim()) purge.mutate({ id: t.id, code, reason });
                            }}
                            className="inline-flex items-center gap-1 rounded-md border border-destructive/40 px-2 py-1 text-xs font-medium text-destructive"
                          >
                            <Trash2 className="size-3.5" />
                            Purge
                          </button>
                        ) : null}
                      </>
                    ) : null}

                    <OfferOwnership tenant={t} role={role} />
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

export { Ownership } from "../erp/ownership";
