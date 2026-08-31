import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  Archive,
  Building2,
  ClipboardList,
  Copy,
  LogIn,
  Pause,
  Play,
  Plus,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
} from "lucide-react";

import { Wordmark } from "../components/erp/logo";
import { OfferOwnership, Ownership } from "../components/erp/ownership";
import { Pill, Table } from "../components/erp/panel";
import { TOUCH } from "../components/erp/page";
import { callErp, isConfigured, supabase } from "../lib/erp";
import {
  atLeast,
  ROLE_BLURB,
  usePlatformMe,
  type PlatformAuditRow,
  type PlatformRole,
  type PlatformStaff,
  type PlatformTenant,
} from "../lib/platform";

/**
 * The platform console.
 *
 * It sits outside the tenant shell on purpose. The shell exists to render one
 * company; this screen is about all of them, and its most important user — the
 * owner on the day the product is first deployed — has no company at all. A
 * console that only appeared once you belonged somewhere would be unreachable
 * exactly when it is needed.
 */

export const Route = createFileRoute("/platform")({
  head: () => ({
    meta: [
      { title: "Platform console — ERPWare" },
      {
        name: "description",
        content:
          "Onboard companies, manage platform staff, and review every platform action taken across ERPWare tenants.",
      },
      { property: "og:title", content: "Platform console — ERPWare" },
      {
        property: "og:description",
        content:
          "Onboard companies, manage platform staff, and review audited cross-tenant access.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: PlatformConsole,
});

const INPUT =
  "mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm placeholder:text-muted-foreground/70";

function Card({
  title,
  icon,
  description,
  children,
  action,
}: {
  title: string;
  icon?: ReactNode;
  description?: string;
  children: ReactNode;
  action?: ReactNode;
}) {
  return (
    <section className="surface-card min-w-0 rounded-xl border border-border bg-card p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="flex items-center gap-2 font-display text-base font-semibold">
            {icon}
            {title}
          </h2>
          {description ? <p className="mt-1 text-sm text-muted-foreground">{description}</p> : null}
        </div>
        {action}
      </div>
      <div className="mt-4 min-w-0">{children}</div>
    </section>
  );
}

function Fail({ error }: { error: unknown }) {
  const f = friendlyError(error);
  return (
    <div role="alert" className="rounded-lg border border-destructive/30 bg-destructive/5 p-3">
      <p className="text-sm font-medium text-destructive">{f.title}</p>
      {f.body ? <p className="mt-1 text-xs text-muted-foreground">{f.body}</p> : null}
    </div>
  );
}

/** A token is shown once and never again, so it is shown loudly. */
function TokenNotice({ email, token }: { email: string; token: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="rounded-lg border border-primary/40 bg-primary/5 p-3">
      <p className="text-sm font-medium">Invitation for {email}</p>
      <p className="mt-1 text-xs text-muted-foreground">
        This token works once and is shown once. Send it to them now — it cannot be recovered.
      </p>
      <div className="mt-2 flex items-center gap-2">
        <code className="min-w-0 flex-1 truncate rounded bg-muted px-2 py-1 font-mono text-xs">
          {token}
        </code>
        <button
          type="button"
          onClick={() => {
            void navigator.clipboard?.writeText(token);
            setCopied(true);
          }}
          className={`${TOUCH} inline-flex items-center gap-1 rounded-md border border-input px-3 text-xs font-medium`}
        >
          <Copy className="size-3.5" />
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
    </div>
  );
}

function statusTone(status: string): "ok" | "warn" | "bad" | "muted" {
  if (status === "active") return "ok";
  if (status === "suspended") return "warn";
  if (status === "deleted") return "bad";
  return "muted";
}

/* -------------------------------------------------------------------------- */

function Companies({ role }: { role: PlatformRole }) {
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
      callErp<{ admin_email: string; admin_token: string }>("erp_platform_onboard_company", {
        p_code: form.code,
        p_name: form.name,
        p_admin_email: form.admin_email,
        p_admin_display_name: form.admin_display_name || form.admin_email,
        p_base_currency: form.currency,
        p_country_code: form.country,
      }),
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
      {token ? <TokenNotice email={token.email} token={token.token} /> : null}
      {busyError ? <Fail error={busyError} /> : null}

      {mayOperate ? (
        <Card
          title="Onboard an organisation"
          icon={<Plus className="size-4 text-primary" />}
          description="Creates the tenant, its root entity, its administrator role, and a single-use invitation for its first administrator."
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

/* -------------------------------------------------------------------------- */

function Staff({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const mayManage = atLeast(role, "owner");
  const [form, setForm] = useState({ email: "", name: "", role: "operator" as PlatformRole });

  const staff = useQuery({
    queryKey: ["erp_platform_staff"],
    queryFn: () => callErp<PlatformStaff[]>("erp_platform_staff"),
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["erp_platform_staff"] });

  const add = useMutation({
    mutationFn: () =>
      callErp("erp_platform_add_staff", {
        p_email: form.email,
        p_display_name: form.name || form.email,
        p_role: form.role,
      }),
    onSuccess: () => {
      setForm({ email: "", name: "", role: "operator" });
      void refresh();
    },
  });

  const setRole = useMutation({
    mutationFn: (v: { id: string; role: PlatformRole }) =>
      callErp("erp_platform_set_staff_role", { p_id: v.id, p_role: v.role }),
    onSuccess: refresh,
  });

  const revoke = useMutation({
    mutationFn: (v: { id: string; reason: string }) =>
      callErp("erp_platform_revoke_staff", { p_id: v.id, p_reason: v.reason }),
    onSuccess: refresh,
  });

  const err = add.error ?? setRole.error ?? revoke.error ?? staff.error ?? null;

  return (
    <div className="flex flex-col gap-5">
      {err ? <Fail error={err} /> : null}

      {mayManage ? (
        <Card
          title="Add someone to the platform"
          icon={<UserPlus className="size-4 text-primary" />}
          description="They are matched by the address on their sign-in, so they can be added before they have ever signed in."
        >
          <form
            onSubmit={(e) => {
              e.preventDefault();
              add.mutate();
            }}
            className="grid gap-3 sm:grid-cols-4"
          >
            <label className="block text-sm font-medium sm:col-span-2">
              Email
              <input
                required
                type="email"
                value={form.email}
                onChange={(e) => setForm({ ...form, email: e.target.value })}
                className={INPUT}
              />
            </label>
            <label className="block text-sm font-medium">
              Name
              <input
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                className={INPUT}
              />
            </label>
            <label className="block text-sm font-medium">
              Role
              <select
                value={form.role}
                onChange={(e) => setForm({ ...form, role: e.target.value as PlatformRole })}
                className={INPUT}
              >
                <option value="owner">Owner</option>
                <option value="operator">Operator</option>
                <option value="support">Support</option>
              </select>
            </label>
            <p className="text-xs text-muted-foreground sm:col-span-3">{ROLE_BLURB[form.role]}</p>
            <button
              type="submit"
              disabled={add.isPending}
              className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
            >
              {add.isPending ? "Adding…" : "Add"}
            </button>
          </form>
        </Card>
      ) : null}

      <Card
        title="Platform staff"
        icon={<Users className="size-4 text-primary" />}
        description="Owner controls the platform, operator runs the companies, support can look and be let in."
      >
        {staff.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (
          <Table columns={["Person", "Role", "Signed in", mayManage ? "Actions" : ""]}>
            {(staff.data ?? []).map((s) => (
              <tr key={s.id} className="border-b border-border/60 last:border-0">
                <td className="py-3 pr-4">
                  <div className="font-medium">{s.display_name}</div>
                  <div className="text-xs text-muted-foreground">{s.email}</div>
                </td>
                <td className="py-3 pr-4">
                  <Pill tone={s.role === "owner" ? "ok" : s.role === "operator" ? "warn" : "muted"}>
                    {s.role}
                  </Pill>
                </td>
                <td className="py-3 pr-4 text-xs text-muted-foreground">
                  {s.bound ? "Yes" : "Not yet"}
                </td>
                <td className="py-3 pr-0">
                  {mayManage ? (
                    <div className="flex flex-wrap items-center gap-2">
                      <select
                        value={s.role}
                        onChange={(e) =>
                          setRole.mutate({ id: s.id, role: e.target.value as PlatformRole })
                        }
                        className="rounded-md border border-input bg-background px-2 py-1 text-xs"
                      >
                        <option value="owner">owner</option>
                        <option value="operator">operator</option>
                        <option value="support">support</option>
                      </select>
                      <button
                        type="button"
                        onClick={() => {
                          const reason = window.prompt(`Remove ${s.display_name}? Reason:`);
                          if (reason) revoke.mutate({ id: s.id, reason });
                        }}
                        className="rounded-md border border-destructive/40 px-2 py-1 text-xs font-medium text-destructive"
                      >
                        Remove
                      </button>
                    </div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}

/* -------------------------------------------------------------------------- */

function Activity() {
  const [action, setAction] = useState("");
  const rows = useQuery({
    queryKey: ["erp_platform_audit", action],
    queryFn: () =>
      callErp<PlatformAuditRow[]>("erp_platform_audit", {
        p_action: action || null,
        p_tenant_id: null,
        p_limit: 200,
      }),
  });

  return (
    <Card
      title="Platform activity"
      icon={<ClipboardList className="size-4 text-primary" />}
      description="Every platform action, including each entry into a customer company and the reason given."
      action={
        <select
          value={action}
          onChange={(e) => setAction(e.target.value)}
          className="rounded-md border border-input bg-background px-2 py-2 text-xs"
        >
          <option value="">All actions</option>
          <option value="platform.company_onboarded">Organisation onboarded</option>
          <option value="platform.tenant_entered">Organisation entered</option>
          <option value="platform.tenant_left">Organisation left</option>
          <option value="platform.admin_invited">Administrator invited</option>
          <option value="platform.tenant_status_changed">Status changed</option>
          <option value="platform.ownership_offered">Ownership offered</option>
          <option value="platform.ownership_accepted">Ownership accepted</option>
          <option value="platform.ownership_declined">Ownership declined</option>
          <option value="platform.ownership_cancelled">Ownership offer withdrawn</option>
          <option value="platform.staff_added">Staff added</option>
          <option value="platform.staff_role_changed">Staff role changed</option>
          <option value="platform.staff_revoked">Staff removed</option>
        </select>
      }
    >
      {rows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : rows.error ? (
        <Fail error={rows.error} />
      ) : (rows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nothing recorded under this filter.</p>
      ) : (
        <Table columns={["When", "Who", "Action", "Organisation", "Detail"]}>
          {(rows.data ?? []).map((r) => (
            <tr key={r.id} className="border-b border-border/60 last:border-0 align-top">
              <td className="py-3 pr-4 text-xs text-muted-foreground">
                {new Date(r.occurred_at).toLocaleString()}
              </td>
              <td className="py-3 pr-4 text-xs">
                <div>{r.actor_email}</div>
                <div className="text-muted-foreground">{r.actor_role}</div>
              </td>
              <td className="py-3 pr-4 text-sm">{r.action.replace("platform.", "")}</td>
              <td className="py-3 pr-4 font-mono text-xs">{r.tenant_code ?? "—"}</td>
              <td className="py-3 pr-0 text-xs text-muted-foreground">
                {[r.target, r.reason].filter(Boolean).join(" · ") || "—"}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  );
}

/* -------------------------------------------------------------------------- */

function Frame({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-20 border-b border-border bg-background/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-4 py-3">
          <div className="flex items-center gap-3">
            <Wordmark size={26} />
            <span className="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
              Platform
            </span>
          </div>
          <div className="flex items-center gap-3">
            {right}
            <Link
              to="/"
              className={`${TOUCH} inline-flex items-center text-sm underline underline-offset-2`}
            >
              Back to the app
            </Link>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
    </div>
  );
}

function PlatformConsole() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [tab, setTab] = useState<"companies" | "ownership" | "staff" | "activity">("companies");
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!supabase) {
      setReady(true);
      return;
    }
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const me = usePlatformMe(Boolean(session));

  const claim = useMutation({
    mutationFn: () => callErp("erp_platform_claim_ownership", { p_display_name: null }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["erp_platform_me"] }),
  });

  if (!isConfigured || !ready) {
    return (
      <Frame>
        <p className="text-sm text-muted-foreground">Loading…</p>
      </Frame>
    );
  }

  if (!session) {
    return (
      <Frame>
        <Card title="Sign in first" icon={<ShieldCheck className="size-4 text-primary" />}>
          <p className="text-sm text-muted-foreground">
            The platform console is only offered to signed-in platform staff.{" "}
            <Link to="/" className="underline underline-offset-2">
              Sign in
            </Link>{" "}
            and come back.
          </p>
        </Card>
      </Frame>
    );
  }

  if (me.isPending) {
    return (
      <Frame>
        <p className="text-sm text-muted-foreground">Checking your platform access…</p>
      </Frame>
    );
  }

  if (!me.data?.is_staff) {
    return (
      <Frame right={<span className="text-xs text-muted-foreground">{session.user.email}</span>}>
        <Card title="Not platform staff" icon={<ShieldCheck className="size-4 text-primary" />}>
          {me.data?.claimable ? (
            <>
              <p className="text-sm text-muted-foreground">
                Nobody owns this deployment yet. Claiming ownership makes this account the first
                owner, and the claim itself is recorded. It can only ever happen once.
              </p>
              {claim.error ? <div className="mt-3">{<Fail error={claim.error} />}</div> : null}
              <button
                type="button"
                onClick={() => claim.mutate()}
                disabled={claim.isPending}
                className={`${TOUCH} mt-4 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
              >
                {claim.isPending ? "Claiming…" : "Claim ownership"}
              </button>
            </>
          ) : (
            <p className="text-sm text-muted-foreground">
              This account is not on the platform staff list. An owner can add it.
            </p>
          )}
        </Card>
      </Frame>
    );
  }

  const role = me.data.role as PlatformRole;
  const tabs: { key: typeof tab; label: string; show: boolean }[] = [
    { key: "companies", label: "Organisations", show: true },
    { key: "ownership", label: "Ownership", show: true },
    { key: "staff", label: "Staff", show: true },
    { key: "activity", label: "Activity", show: true },
  ];

  return (
    <Frame
      right={
        <span className="hidden items-center gap-2 text-xs text-muted-foreground sm:inline-flex">
          {me.data.email}
          <Pill tone={role === "owner" ? "ok" : role === "operator" ? "warn" : "muted"}>
            {role}
          </Pill>
        </span>
      }
    >
      <div className="flex flex-col gap-5">
        <div>
          <h1 className="font-display text-2xl font-semibold tracking-tight">Platform console</h1>
          <p className="mt-1 text-sm text-muted-foreground">{ROLE_BLURB[role]}</p>
        </div>

        <nav className="flex gap-1 rounded-lg border border-border bg-card p-1">
          {tabs
            .filter((t) => t.show)
            .map((t) => (
              <button
                key={t.key}
                type="button"
                onClick={() => setTab(t.key)}
                className={`${TOUCH} flex-1 rounded-md px-3 text-sm font-medium ${
                  tab === t.key ? "bg-primary text-primary-foreground" : "hover:bg-muted"
                }`}
              >
                {t.label}
              </button>
            ))}
        </nav>

        {tab === "companies" ? <Companies role={role} /> : null}
        {tab === "ownership" ? <Ownership /> : null}
        {tab === "staff" ? <Staff role={role} /> : null}
        {tab === "activity" ? <Activity /> : null}
      </div>
    </Frame>
  );
}
