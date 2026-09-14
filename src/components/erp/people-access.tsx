import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

import { callErp, hasPermission, InviteOutcomeUnknown } from "../../lib/erp";
import { INVITE_VALID_DAYS } from "../../lib/invitation-email";
import {
  accessLabel,
  accessState,
  actionsFor,
  removalOutcome,
  restoreOutcome,
  userManagersOtherThan,
  withdrawalOutcome,
  type AccessAction,
  type AccessState,
  type DirectoryPrincipal,
  type OfferedAction,
} from "../../lib/people-access";
import { ActionButton, ErrorNote } from "./action";
import {
  CreateWithoutEmail,
  createInvitationWithoutEmail,
  InvitationOutcome,
  sendInvitation,
  type PersonInviteRequest,
} from "./invite-dialog";
import { Prose, TOUCH } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Who can sign in to the organisation, and the way to change it.
 *
 * One row per person, with what can be done about them: an invitation sent
 * again or withdrawn, access removed, access restored. The rules for which
 * row offers what live in src/lib/people-access.ts, where every state is
 * tested; this file lays them out and calls the doors.
 *
 * Nothing destructive happens on one press. Withdrawing, removing and
 * restoring each open a confirmation that says what will happen, because the
 * button that ended somebody's access used to sit beside "Save roles".
 *
 * The permission check is convenience: erp.remove_principal,
 * erp.withdraw_invitation and erp.restore_principal authorise
 * administration.users themselves and refuse by name — yourself, the last
 * person who can manage users, somebody who never joined — and a refusal is
 * shown in the dialog in the database's words, with its next action.
 *
 * The words are plain JSX rather than ui(), as in invite-dialog.tsx: a string
 * handed to ui() has to be seeded as a screen string by a migration.
 */

type ConfirmedAction = Extract<
  AccessAction,
  "withdraw_invitation" | "remove_access" | "restore_access"
>;
type InvitingAction = Extract<AccessAction, "send_invitation_again" | "invite_again">;

type Change = { action: ConfirmedAction; principal: DirectoryPrincipal };
type Reinvitation = { action: InvitingAction; principal: DirectoryPrincipal };

const ACTION_WORDS: Record<AccessAction, string> = {
  send_invitation_again: "Send the invitation again",
  withdraw_invitation: "Withdraw invitation",
  remove_access: "Remove access",
  restore_access: "Restore access",
  invite_again: "Invite again",
};

const TONE: Record<AccessState, "ok" | "warn" | "bad" | "muted"> = {
  active: "ok",
  invited: "warn",
  invitation_expired: "bad",
  suspended: "warn",
  removed: "muted",
};

const DIRECTORY_KEY = ["erp_permissions_directory"];

export function PeopleAccess({ principals }: { principals: readonly DirectoryPrincipal[] }) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const permitted = hasPermission(session, "administration.users");
  const organisation = session.tenant?.name ?? "this organisation";

  const [confirming, setConfirming] = useState<Change | null>(null);
  const [reinviting, setReinviting] = useState<Reinvitation | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = () => void queryClient.invalidateQueries({ queryKey: DIRECTORY_KEY });

  const change = useMutation({
    mutationFn: (request: Change) => applyChange(request),
    onSuccess: (sentence) => {
      setNotice(sentence);
      setConfirming(null);
    },
    // A refusal can mean the list was out of date — somebody else removed
    // them first — so it is brought up to date either way.
    onSettled: refresh,
  });

  const open = (action: AccessAction, principal: DirectoryPrincipal) => {
    setNotice(null);
    if (action === "send_invitation_again" || action === "invite_again") {
      setReinviting({ action, principal });
      return;
    }
    change.reset();
    setConfirming({ action, principal });
  };

  const people = principals.filter((p) => p.kind !== "service");
  const services = principals.filter((p) => p.kind === "service");

  const row = (principal: DirectoryPrincipal) => (
    <PersonRow
      key={principal.id}
      principal={principal}
      self={principal.id === session.principal_id}
      offered={
        permitted
          ? actionsFor(principal, {
              selfId: session.principal_id,
              managersRemaining: userManagersOtherThan(principals, principal.id),
            })
          : []
      }
      onAction={(action) => open(action, principal)}
    />
  );

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">People</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Everybody invited into {organisation}, and whether they can sign in. Removing somebody
          ends their access without deleting them: the record of what they did stays, and their
          access can be restored later.
        </Prose>
      </header>

      {notice ? (
        <p
          role="status"
          className="mx-4 mt-3 rounded-md border border-primary/40 bg-primary/5 p-3 text-sm sm:mx-5"
        >
          {notice}
        </p>
      ) : null}

      {!permitted ? (
        <p className="px-4 pt-3 text-xs text-muted-foreground sm:px-5">
          Changing somebody&apos;s access needs{" "}
          <code className="font-mono text-xs">administration.users</code>, which this account does
          not hold.
        </p>
      ) : null}

      {people.length === 0 ? (
        <p className="px-4 py-4 text-sm text-muted-foreground sm:px-5">
          Nobody has been invited yet.
        </p>
      ) : (
        <ul className="divide-y divide-border/60">{people.map(row)}</ul>
      )}

      {services.length > 0 ? (
        <details className="border-t border-border">
          <summary
            className={`${TOUCH} flex cursor-pointer items-center px-4 text-sm font-medium sm:px-5`}
          >
            Service users ({services.length})
          </summary>
          <ul className="divide-y divide-border/60 border-t border-border/60">
            {services.map(row)}
          </ul>
        </details>
      ) : null}

      <ConfirmChange
        change={confirming}
        organisation={organisation}
        busy={change.isPending}
        error={change.error}
        onConfirm={() => {
          if (confirming && !change.isPending) change.mutate(confirming);
        }}
        onCancel={() => setConfirming(null)}
      />

      {reinviting ? (
        <SendInvitationAgain
          key={`${reinviting.action}:${reinviting.principal.id}`}
          reinvitation={reinviting}
          organisation={organisation}
          onSent={refresh}
          onClose={() => setReinviting(null)}
        />
      ) : null}
    </section>
  );
}

/** What each confirmed change calls, and the sentence its answer becomes. */
async function applyChange({ action, principal }: Change): Promise<string> {
  const args = { p_app_user_id: principal.id };
  switch (action) {
    case "remove_access":
      return removalOutcome(
        principal.display_name,
        await callErp<unknown>("erp_remove_principal", args),
      );
    case "withdraw_invitation":
      return withdrawalOutcome(
        principal.display_name,
        await callErp<unknown>("erp_withdraw_invitation", args),
      );
    case "restore_access":
      await callErp<unknown>("erp_restore_principal", args);
      return restoreOutcome(principal.display_name);
  }
}

function PersonRow({
  principal,
  self,
  offered,
  onAction,
}: {
  principal: DirectoryPrincipal;
  self: boolean;
  offered: OfferedAction[];
  onAction: (action: AccessAction) => void;
}) {
  const reasonId = `access-reason-${principal.id}`;
  const reasons = [
    ...new Set(offered.map((o) => o.disabledReason).filter((r): r is string => r !== null)),
  ];

  return (
    <li className="flex flex-col gap-3 px-4 py-3 sm:px-5 md:flex-row md:items-start md:justify-between md:gap-4">
      <div className="min-w-0">
        <p className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
          <span className="break-words font-medium">{principal.display_name}</span>
          {self ? <span className="text-xs text-muted-foreground">(you)</span> : null}
          <Pill tone={TONE[accessState(principal)]}>{accessLabel(principal)}</Pill>
          {principal.is_support === true ? <Pill tone="muted">Platform support</Pill> : null}
        </p>
        <p className="mt-0.5 break-words text-xs text-muted-foreground">
          {principal.email ??
            (principal.kind === "service" ? "Machine account" : "No email address")}
        </p>
        {reasons.length > 0 ? (
          <p id={reasonId} className="mt-1 text-xs text-muted-foreground">
            {reasons.join(" ")}
          </p>
        ) : null}
      </div>

      {offered.length > 0 ? (
        <div className="flex flex-wrap gap-2 md:shrink-0 md:justify-end">
          {offered.map((o) => (
            <RowButton
              key={o.action}
              danger={o.action === "remove_access" || o.action === "withdraw_invitation"}
              disabled={o.disabledReason !== null}
              describedBy={o.disabledReason !== null ? reasonId : undefined}
              onClick={() => onAction(o.action)}
            >
              {ACTION_WORDS[o.action]}
            </RowButton>
          ))}
        </div>
      ) : null}
    </li>
  );
}

/**
 * A row's button. ActionButton has no destructive look, and the two that end
 * something should not read like the two that do not.
 */
function RowButton({
  children,
  onClick,
  danger,
  disabled,
  describedBy,
}: {
  children: ReactNode;
  onClick: () => void;
  danger: boolean;
  disabled: boolean;
  describedBy: string | undefined;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-describedby={describedBy}
      className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium disabled:opacity-50 ${danger ? "text-destructive" : ""}`}
    >
      {children}
    </button>
  );
}

type Confirmation = {
  heading: string;
  body: string;
  confirm: string;
  working: string;
  danger: boolean;
};

/** Exactly what happens, in the words the dialog uses. */
function confirmationFor({ action, principal }: Change, organisation: string): Confirmation {
  const name = principal.display_name;
  switch (action) {
    case "remove_access":
      return principal.kind === "service"
        ? {
            heading: `Remove ${name}?`,
            body: `This service user stops working in ${organisation} now. Its roles end, and the record of what it did stays.`,
            confirm: "Remove access",
            working: "Removing…",
            danger: true,
          }
        : {
            heading: `Remove ${name}'s access?`,
            body: "Their access ends now. Their roles end, and the record of what they did stays. You can restore access later, and give roles again.",
            confirm: "Remove access",
            working: "Removing…",
            danger: true,
          };
    case "withdraw_invitation":
      return {
        heading: `Withdraw the invitation to ${name}?`,
        body: `Any link sent to ${principal.email ?? name} stops working now, and they do not join ${organisation}. Any roles already given to them end. You can invite them again later.`,
        confirm: "Withdraw invitation",
        working: "Withdrawing…",
        danger: true,
      };
    case "restore_access":
      return {
        heading: `Restore ${name}'s access?`,
        body: `They can sign in to ${organisation} again with the account they used before. None of their roles come back, so they can do nothing until you give them roles below.`,
        confirm: "Restore access",
        working: "Restoring…",
        danger: false,
      };
  }
}

/**
 * The confirmation, on the AlertDialog primitive.
 *
 * Its buttons are ordinary buttons rather than AlertDialogAction, which closes
 * on press: the dialog stays open while the door answers, so a refusal is read
 * where the decision was made, and it cannot be dismissed mid-call.
 */
function ConfirmChange({
  change,
  organisation,
  busy,
  error,
  onConfirm,
  onCancel,
}: {
  change: Change | null;
  organisation: string;
  busy: boolean;
  error: unknown;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const words = change ? confirmationFor(change, organisation) : null;

  return (
    <AlertDialog
      open={change !== null}
      onOpenChange={(next) => {
        if (!next && !busy) onCancel();
      }}
    >
      {words ? (
        <AlertDialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
          <AlertDialogHeader>
            <AlertDialogTitle>{words.heading}</AlertDialogTitle>
            <AlertDialogDescription>{words.body}</AlertDialogDescription>
          </AlertDialogHeader>
          <ErrorNote error={error} />
          <AlertDialogFooter className="gap-2 sm:space-x-0">
            <ActionButton variant="secondary" onClick={onCancel} disabled={busy}>
              Cancel
            </ActionButton>
            <button
              type="button"
              onClick={onConfirm}
              disabled={busy}
              className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md px-4 text-sm font-semibold disabled:opacity-60 ${
                words.danger
                  ? "bg-destructive text-destructive-foreground"
                  : "bg-primary text-primary-foreground"
              }`}
            >
              {busy ? words.working : words.confirm}
            </button>
          </AlertDialogFooter>
        </AlertDialogContent>
      ) : null}
    </AlertDialog>
  );
}

/**
 * A new invitation for somebody already on the list, through the invite
 * function, with the same outcome and link to copy that InviteDialog shows.
 *
 * erp.invite_principal re-invites a person who has never signed in and
 * withdraws the link they held, so "send again" and "invite again" are the
 * same call; only the words differ. The person's address is the one on file,
 * which is the only address the invitation may go to.
 */
function SendInvitationAgain({
  reinvitation,
  organisation,
  onSent,
  onClose,
}: {
  reinvitation: Reinvitation;
  organisation: string;
  onSent: () => void;
  onClose: () => void;
}) {
  const { action, principal } = reinvitation;
  const email = (principal.email ?? "").trim();
  const days = INVITE_VALID_DAYS.erp_invite_principal;

  const invite = useMutation({
    mutationFn: (request: PersonInviteRequest) => sendInvitation(request),
    onSuccess: onSent,
    // It may have been made: the list is where to look, so bring it up to date.
    onError: (error) => {
      if (error instanceof InviteOutcomeUnknown) onSent();
    },
  });
  const direct = useMutation({
    mutationFn: (request: PersonInviteRequest) => createInvitationWithoutEmail(request),
    onSuccess: onSent,
  });

  const outcome = invite.data ?? direct.data;
  const pending = invite.isPending || direct.isPending;
  const uncertain = invite.error instanceof InviteOutcomeUnknown ? invite.variables : undefined;
  const again = action === "send_invitation_again";

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        // Never mid-send: the invitation may already exist, and closing would
        // lose the only place its link is shown.
        if (!next && !pending) onClose();
      }}
    >
      <DialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {again
              ? `Send the invitation to ${principal.display_name} again`
              : `Invite ${principal.display_name} again`}
          </DialogTitle>
          <DialogDescription>
            {again
              ? `A new link is emailed to ${email}, and stays open for ${days} days. The link sent before stops working.`
              : `They never joined ${organisation}. A new invitation is emailed to ${email}, and stays open for ${days} days. Roles they were given before do not come back.`}
          </DialogDescription>
        </DialogHeader>

        {outcome ? (
          <div className="flex flex-col gap-3">
            <InvitationOutcome result={outcome} />
            <div className="flex flex-wrap justify-end gap-2">
              <ActionButton onClick={onClose}>Done</ActionButton>
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            <ErrorNote error={invite.error} />
            {uncertain ? (
              <>
                <CreateWithoutEmail
                  busy={direct.isPending}
                  onCreate={() => direct.mutate(uncertain)}
                />
                <ErrorNote error={direct.error} />
              </>
            ) : null}
            <div className="mt-2 flex flex-wrap justify-end gap-2">
              <ActionButton variant="secondary" onClick={onClose} disabled={pending}>
                Cancel
              </ActionButton>
              <ActionButton
                busy={invite.isPending}
                disabled={direct.isPending}
                onClick={() => {
                  if (pending) return;
                  direct.reset();
                  invite.mutate({
                    door: "erp_invite_principal",
                    args: { p_email: email, p_display_name: principal.display_name },
                  });
                }}
              >
                {invite.isPending ? "Sending…" : "Send invitation"}
              </ActionButton>
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
