import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Building2, ChevronRight, Plus, Trash2 } from "lucide-react";

import { InvitationOutcome, sendInvitation, type InvitationSent } from "../erp/invite-dialog";
import { Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp, ErpError, InviteOutcomeUnknown } from "../../lib/erp";
import type { OnboardCompanyArgs } from "../../lib/invitation-email";
import {
  atLeast,
  type MyTenancy,
  type PlatformRole,
  type PlatformTenant,
} from "../../lib/platform";
import { FormDialog } from "./dialogs";
import { Card, ConsoleLink, Fail, INPUT, OrganisationName } from "./kit";
import { OrganisationActions } from "./organisation-actions";

/**
 * Every organisation, and the way into each one's page.
 *
 * The actions on a row are the ones on the organisation's own page, from
 * organisation-actions.tsx, so the list and the page cannot drift apart.
 */

export function Companies({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
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
  // The last organisation onboarded here: whether its invitation was emailed,
  // and its link. Shown once, because the database keeps only a digest of the
  // token inside it.
  const [invitation, setInvitation] = useState<InvitationSent | null>(null);

  const tenants = useQuery({
    queryKey: ["erp_platform_tenants"],
    queryFn: () => callErp<PlatformTenant[]>("erp_platform_tenants"),
  });

  const refresh = () => queryClient.invalidateQueries();

  // The code of an organisation whose onboarding could not reach the invite
  // function. It may well exist now, so a later attempt refused as a duplicate
  // is most likely that one, and the screen says so rather than leaving the
  // operator to wonder who else took the code.
  const [uncertainCode, setUncertainCode] = useState<string | null>(null);

  // The invite function calls erp_platform_onboard_company as the signed-in
  // operator, then emails the first administrator their invitation. Never
  // retried without it: a second call is refused because the organisation the
  // first one made already exists.
  const onboard = useMutation({
    mutationFn: (args: OnboardCompanyArgs) =>
      sendInvitation({ door: "erp_platform_onboard_company", args }),
    onError: (error, args) => {
      if (!(error instanceof InviteOutcomeUnknown)) return;
      setUncertainCode(args.p_code);
      void refresh();
    },
    onSuccess: (sent) => {
      setUncertainCode(null);
      setInvitation(sent);
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

  const probablyCreated =
    uncertainCode !== null &&
    onboard.variables?.p_code.trim().toLowerCase() === uncertainCode.trim().toLowerCase() &&
    isOrganisationExists(onboard.error);

  /**
   * Which organisations you are currently inside.
   *
   * Entering grants you the administrator role there — a real grant on a real
   * principal — so the row says so and offers Leave instead of Enter.
   */
  const mine = useQuery({
    queryKey: ["erp_platform_my_tenancies"],
    queryFn: () => callErp<MyTenancy[]>("erp_platform_my_tenancies"),
  });
  const inside = new Set((mine.data ?? []).filter((m) => m.is_active).map((m) => m.tenant_id));

  const rows = tenants.data ?? [];

  return (
    <div className="flex flex-col gap-5">
      {invitation ? (
        <InvitationOutcome
          result={invitation}
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
      {onboard.error ? <Fail error={onboard.error} /> : null}
      {probablyCreated ? (
        <p role="status" className="-mt-3 text-xs text-muted-foreground">
          The organisation was probably created by the earlier attempt, which could not reach the
          invitation service. Look for {onboard.variables?.p_code ?? "it"} in the list below.
        </p>
      ) : null}

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
              {open ? "Close" : "New organisation"}
            </button>
          }
        >
          {open ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                onboard.mutate({
                  p_code: form.code,
                  p_name: form.name,
                  p_admin_email: form.admin_email,
                  p_admin_display_name: form.admin_display_name || form.admin_email,
                  p_base_currency: form.currency,
                  p_country_code: form.country,
                });
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
              Its first administrator is emailed an invitation when the organisation is created, and
              the link appears here once, to copy.
            </p>
          )}
        </Card>
      ) : null}

      <Card
        title="Organisations"
        icon={<Building2 className="size-4 text-primary" />}
        description="Every organisation on this deployment. Open one to see its plan, contract, invoices and people. Suspending and marking ended change a status; purging is the only thing here that removes data."
      >
        {atLeast(role, "owner") ? <DeletionSweep /> : null}

        {tenants.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : tenants.error ? (
          <Fail error={tenants.error} />
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No organisations yet. Onboarding one is the first thing to do.
          </p>
        ) : (
          <Table columns={["Organisation", "Owner", "People", "Structure", "Actions"]}>
            {rows.map((t) => (
              <tr key={t.id} className="border-b border-border/60 align-top last:border-0">
                <td className="py-3 pr-4">
                  <OrganisationName name={t.name} code={t.code} status={t.status}>
                    <ConsoleLink
                      section="customers"
                      view="organisations"
                      org={t.code}
                      className="inline-flex items-center gap-0.5 font-medium underline-offset-2 hover:underline"
                    >
                      {t.name}
                      <ChevronRight className="size-3.5 text-muted-foreground" />
                    </ConsoleLink>
                  </OrganisationName>
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
                  {t.entities} {t.entities === 1 ? "company" : "companies"} · {t.sites}{" "}
                  {t.sites === 1 ? "site" : "sites"}
                </td>
                <td className="py-3 pr-0">
                  <OrganisationActions tenant={t} role={role} inside={inside.has(t.id)} />
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
 * Finishes every deletion request whose grace period has elapsed.
 *
 * When an administrator requests deletion, their organisation is suspended and
 * its keys destroyed, but its rows stay until they are purged. Nothing runs
 * this on a schedule yet.
 */
function DeletionSweep() {
  const queryClient = useQueryClient();
  const [days, setDays] = useState("7");
  const n = Number(days);
  const valid = days.trim() !== "" && Number.isInteger(n) && n >= 0;

  return (
    <div className="mb-4 flex flex-wrap items-center gap-3 rounded-lg border border-border bg-muted/40 px-3 py-2">
      <p className="min-w-0 flex-1 text-xs text-muted-foreground">
        When an administrator requests deletion, their organisation is suspended and its keys are
        destroyed, but its rows remain until they are purged. The sweep purges every request older
        than the grace period. Nothing runs it on a schedule yet.
      </p>
      <FormDialog
        trigger={
          <button
            type="button"
            className="inline-flex shrink-0 items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium"
          >
            <Trash2 className="size-3.5" />
            Run deletion sweep
          </button>
        }
        title="Run the deletion sweep"
        description="Every organisation whose administrator asked for deletion longer ago than the grace period is purged, permanently. Organisations nobody asked to delete are not touched."
        submitLabel="Purge what is due"
        busyLabel="Sweeping…"
        danger
        ready={valid}
        run={() =>
          callErp<{ purged: number }>("erp_platform_purge_due_tenants", { p_grace_days: n })
        }
        onDone={() => void queryClient.invalidateQueries()}
        done={(result) => (
          <p role="status" className="text-sm">
            The sweep purged {result?.purged ?? 0}{" "}
            {(result?.purged ?? 0) === 1 ? "organisation" : "organisations"}.
          </p>
        )}
        onClosed={() => setDays("7")}
      >
        <label className="flex flex-col gap-1 text-sm font-medium">
          Grace period, in days
          <input
            type="number"
            min={0}
            step={1}
            value={days}
            onChange={(e) => setDays(e.target.value)}
            className={INPUT}
          />
          <span className="text-xs font-normal text-muted-foreground">
            {valid
              ? `Purges deletion requests made more than ${n} ${n === 1 ? "day" : "days"} ago.`
              : "A whole number of days, 0 or more."}
          </span>
        </label>
      </FormDialog>
    </div>
  );
}

/**
 * The refusal erp.provision_tenant raises for a code already taken:
 * CLOVEERP_TENANT_EXISTS, or ERPWARE_ for as long as errors.ts accepts both, or
 * the unique constraint itself if two attempts race past that check.
 */
function isOrganisationExists(error: unknown): boolean {
  if (!(error instanceof ErpError)) return false;
  return /^(?:CLOVEERP|ERPWARE)_TENANT_EXISTS$/.test(error.erpCode ?? "") || error.code === "23505";
}

export { Ownership } from "../erp/ownership";
