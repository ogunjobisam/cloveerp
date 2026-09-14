import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { Archive, LogIn, LogOut, Pause, Play, Trash2, UserPlus } from "lucide-react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

import {
  createInvitationWithoutEmail,
  CreateWithoutEmail,
  InvitationOutcome,
  sendInvitation,
  type PersonInviteRequest,
} from "../erp/invite-dialog";
import { OfferOwnership } from "../erp/ownership";
import { TOUCH } from "../erp/page";
import { callErp, InviteOutcomeUnknown } from "../../lib/erp";
import { atLeast, type PlatformRole, type PlatformTenant } from "../../lib/platform";
import { ConfirmCodeDialog, DIALOG_PRIMARY, DIALOG_SECONDARY, ReasonDialog } from "./dialogs";
import { Fail, INPUT } from "./kit";

/**
 * What can be done to one organisation, wherever it is shown.
 *
 * The same controls, with the same gates, on a row of All organisations and on
 * the organisation's own page, so the two can never offer different things.
 * The gates are the ones the list has always had: anybody on the platform may
 * enter and leave, an operator invites, suspends and reactivates, an owner
 * marks ended, purges and hands an organisation on. Hiding a button is the
 * convenience; each door checks the role on its first line.
 */

const COMPACT =
  "inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 text-xs font-medium disabled:opacity-60";
const FULL = `${TOUCH} inline-flex items-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium disabled:opacity-60`;

export function OrganisationActions({
  tenant: t,
  role,
  inside,
  size = "compact",
}: {
  tenant: PlatformTenant;
  role: PlatformRole;
  /** Whether the signed-in person is currently inside this organisation. */
  inside: boolean;
  size?: "compact" | "full";
}) {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const mayOperate = atLeast(role, "operator");
  const isOwner = atLeast(role, "owner");
  const button = size === "full" ? FULL : COMPACT;
  const danger = `${button} border-destructive/40 text-destructive`;
  const icon = size === "full" ? "size-4" : "size-3.5";

  const refresh = () => queryClient.invalidateQueries();

  const leave = useMutation({
    mutationFn: () => callErp("erp_platform_leave_tenant", { p_tenant_id: t.id }),
    onSuccess: refresh,
  });

  const reactivate = useMutation({
    mutationFn: () =>
      callErp("erp_platform_set_tenant_status", {
        p_tenant_id: t.id,
        p_status: "active",
        p_reason: null,
      }),
    onSuccess: refresh,
  });

  const clickError = leave.error ?? reactivate.error ?? null;

  return (
    <div className="flex flex-wrap items-start gap-2">
      {inside ? (
        <button
          type="button"
          disabled={leave.isPending}
          onClick={() => leave.mutate()}
          title="Ends your access and removes the administrator role it gave you"
          className={`${button} border-primary/50 bg-primary/5`}
        >
          <LogOut className={icon} />
          {leave.isPending ? "Leaving…" : "Leave"}
        </button>
      ) : (
        <ReasonDialog
          trigger={
            <button type="button" className={button}>
              <LogIn className={icon} />
              Enter
            </button>
          }
          title={`Enter ${t.name}`}
          description="You are given the administrator role inside it until you leave. Why you went in is recorded against your name, and its administrators can see it."
          reasonLabel="Why are you entering?"
          placeholder="For example: helping their administrator set up finance, ticket 1042"
          submitLabel="Enter the organisation"
          busyLabel="Entering…"
          run={(reason) =>
            callErp("erp_platform_enter_tenant", { p_tenant_id: t.id, p_reason: reason })
          }
          onDone={() => {
            void refresh().then(() => navigate({ to: "/" }));
          }}
        />
      )}

      {mayOperate ? (
        <>
          <InviteAdminDialog tenant={t} className={button} icon={icon} />

          {t.status === "suspended" ? (
            <button
              type="button"
              disabled={reactivate.isPending}
              onClick={() => reactivate.mutate()}
              className={button}
            >
              <Play className={icon} />
              {reactivate.isPending ? "Reactivating…" : "Reactivate"}
            </button>
          ) : t.status === "active" ? (
            <ReasonDialog
              trigger={
                <button type="button" className={button}>
                  <Pause className={icon} />
                  Suspend
                </button>
              }
              title={`Suspend ${t.name}`}
              description="Nobody in it can work until it is reactivated. Nothing is removed."
              reasonLabel="Why is it being suspended?"
              placeholder="For example: invoice 2026-004 is 60 days overdue"
              submitLabel="Suspend"
              busyLabel="Suspending…"
              danger
              run={(reason) =>
                callErp("erp_platform_set_tenant_status", {
                  p_tenant_id: t.id,
                  p_status: "suspended",
                  p_reason: reason,
                })
              }
              onDone={() => void refresh()}
            />
          ) : null}

          {/* A status, and only a status. It used to say Delete and remove
              nothing, which is the whole reason organisations piled up. */}
          {isOwner && t.status !== "deleted" ? (
            <ReasonDialog
              trigger={
                <button type="button" className={button}>
                  <Archive className={icon} />
                  Mark ended
                </button>
              }
              title={`Mark ${t.name} as ended`}
              description="This records that the organisation has ended and removes no data. Purging is a separate step, afterwards."
              reasonLabel="Why has it ended?"
              placeholder="For example: contract terminated on 31 August"
              submitLabel="Mark ended"
              busyLabel="Saving…"
              run={(reason) =>
                callErp("erp_platform_set_tenant_status", {
                  p_tenant_id: t.id,
                  p_status: "deleted",
                  p_reason: reason,
                })
              }
              onDone={() => void refresh()}
            />
          ) : null}

          {/* This one empties it. Owner only, refused by the database on an
              active organisation, and the code has to be typed. */}
          {isOwner && t.status !== "active" ? (
            <ConfirmCodeDialog
              trigger={
                <button type="button" className={danger}>
                  <Trash2 className={icon} />
                  Purge
                </button>
              }
              title={`Purge ${t.name} permanently`}
              description="Every row belonging to it is removed and cannot be recovered. Export first if anybody wants the data."
              code={t.code}
              submitLabel="Purge permanently"
              busyLabel="Purging… this can take up to a minute"
              run={(typed, reason) =>
                callErp<{ code: string }>("erp_platform_purge_tenant", {
                  p_tenant_id: t.id,
                  p_confirm_code: typed,
                  p_reason: reason,
                })
              }
              onDone={() => void refresh()}
            />
          ) : null}
        </>
      ) : null}

      <OfferOwnership tenant={t} role={role} />

      {clickError ? (
        <div className="basis-full">
          <Fail error={clickError} />
        </div>
      ) : null}
    </div>
  );
}

/**
 * A further administrator for an organisation that exists.
 *
 * The invite function emails the link and the dialog shows it once, to copy,
 * whether or not the email went. When the function could not be reached, the
 * invitation may or may not exist, so making one without email is offered
 * rather than done.
 */
function InviteAdminDialog({
  tenant,
  className,
  icon,
}: {
  tenant: PlatformTenant;
  className: string;
  icon: string;
}) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");

  const refresh = () => void queryClient.invalidateQueries({ queryKey: ["erp_platform_tenants"] });

  const invite = useMutation({
    mutationFn: (request: PersonInviteRequest) => sendInvitation(request),
    onSuccess: refresh,
    onError: (error) => {
      if (error instanceof InviteOutcomeUnknown) refresh();
    },
  });
  const direct = useMutation({
    mutationFn: (request: PersonInviteRequest) => createInvitationWithoutEmail(request),
    onSuccess: refresh,
  });

  const outcome = invite.data ?? direct.data;
  const pending = invite.isPending || direct.isPending;
  const uncertain = invite.error instanceof InviteOutcomeUnknown ? invite.variables : undefined;

  const reset = () => {
    setEmail("");
    setName("");
    invite.reset();
    direct.reset();
  };
  const close = () => {
    setOpen(false);
    reset();
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next && pending) return;
        if (next) setOpen(true);
        else close();
      }}
    >
      <DialogTrigger asChild>
        <button type="button" className={className}>
          <UserPlus className={icon} />
          Invite administrator
        </button>
      </DialogTrigger>
      <DialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Invite an administrator to {tenant.name}</DialogTitle>
          <DialogDescription>
            They are emailed a link that brings them into the organisation as an administrator. The
            link is also shown here once, to copy.
          </DialogDescription>
        </DialogHeader>

        {outcome ? (
          <div className="flex flex-col gap-4">
            <InvitationOutcome result={outcome} />
            <div className="flex flex-wrap justify-end gap-2">
              <button type="button" className={DIALOG_SECONDARY} onClick={reset}>
                Invite someone else
              </button>
              <button type="button" className={DIALOG_PRIMARY} onClick={close}>
                Done
              </button>
            </div>
          </div>
        ) : (
          <form
            className="flex flex-col gap-4"
            onSubmit={(e) => {
              e.preventDefault();
              if (pending || email.trim() === "") return;
              direct.reset();
              invite.mutate({
                door: "erp_platform_invite_admin",
                args: {
                  p_tenant_id: tenant.id,
                  p_email: email.trim(),
                  p_display_name: name.trim() || email.trim(),
                },
              });
            }}
          >
            <label className="flex flex-col gap-1 text-sm font-medium">
              Email
              <input
                type="email"
                required
                autoComplete="off"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className={INPUT}
              />
              <span className="text-xs font-normal text-muted-foreground">
                The invitation goes here, and they sign in with it.
              </span>
            </label>
            <label className="flex flex-col gap-1 text-sm font-medium">
              Name
              <input
                autoComplete="off"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className={INPUT}
              />
              <span className="text-xs font-normal text-muted-foreground">
                Optional. Their email is used if it is left blank.
              </span>
            </label>

            {invite.error ? <Fail error={invite.error} /> : null}
            {uncertain ? (
              <>
                <CreateWithoutEmail
                  busy={direct.isPending}
                  onCreate={() => direct.mutate(uncertain)}
                />
                {direct.error ? <Fail error={direct.error} /> : null}
              </>
            ) : null}

            <div className="flex flex-wrap justify-end gap-2">
              <button type="button" className={DIALOG_SECONDARY} onClick={close} disabled={pending}>
                Cancel
              </button>
              <button
                type="submit"
                className={DIALOG_PRIMARY}
                disabled={pending || email.trim() === ""}
              >
                {invite.isPending ? "Sending…" : "Send invitation"}
              </button>
            </div>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
