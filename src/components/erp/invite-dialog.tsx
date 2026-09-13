import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

import { callErp, callInvite, hasPermission, InviteUnreachable } from "../../lib/erp";
import { invitationFrom, joinLink, type InviteRequest } from "../../lib/invitation-email";
import { ActionButton, ErrorNote } from "./action";
import { registerActionOpener } from "./action-registry";
import { TOUCH } from "./page";
import { useErpSession } from "./session-context";
import { useUnsavedGuard } from "./unsaved";

/**
 * Inviting a person, by email.
 *
 * This was an ActionBar action, which called the door and threw away the
 * token it returned — so an invitation was made and nobody was told. It is a
 * form of its own now because what happens after the door is the point: the
 * invite function emails the link, and the screen says whether it did and
 * offers the link to copy either way.
 *
 * The permission check is convenience. erp.invite_principal authorises
 * administration.users itself, and the function calls it as the signed-in
 * person.
 *
 * The words here are plain JSX rather than ui(): a string handed to ui() has
 * to be seeded as a screen string by a migration, and this change has none.
 */
export function InviteDialog({ onInvited }: { onInvited?: () => void }) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const permitted = hasPermission(session, "administration.users");

  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");

  // The Settings walkthrough's "Invite a person" step opens this by its door.
  useEffect(
    () =>
      permitted ? registerActionOpener("erp_invite_principal", () => setOpen(true)) : undefined,
    [permitted],
  );

  const invite = useMutation({
    mutationFn: () =>
      sendInvitation({
        door: "erp_invite_principal",
        args: { p_email: email.trim(), p_display_name: name.trim() },
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["erp_permissions_directory"] });
      onInvited?.();
    },
  });

  useUnsavedGuard(open && !invite.isSuccess && (email !== "" || name !== ""));

  if (!permitted) return null;

  const startAgain = () => {
    setEmail("");
    setName("");
    invite.reset();
  };
  // Closing from a button does not pass through onOpenChange, so it resets too.
  const close = () => {
    setOpen(false);
    startAgain();
  };

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">Invite a person</h2>
      <p className="mt-0.5 text-xs text-muted-foreground">
        They are emailed a link that brings them into {session.tenant?.name ?? "this organisation"}.
        Their roles are set below once they are on the list.
      </p>
      <div className="mt-3">
        <Dialog
          open={open}
          onOpenChange={(next) => {
            // Never mid-send: the invitation may already exist, and closing
            // would lose the only place its link is shown.
            if (!next && invite.isPending) return;
            setOpen(next);
            if (!next) startAgain();
          }}
        >
          <DialogTrigger asChild>
            <ActionButton variant="secondary">Invite a person</ActionButton>
          </DialogTrigger>
          <DialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
            <DialogHeader>
              <DialogTitle>Invite a person</DialogTitle>
              <DialogDescription>
                They get an email with a link that signs them in and brings them into the
                organisation. Nobody&apos;s password is typed here.
              </DialogDescription>
            </DialogHeader>

            {invite.data ? (
              <div className="flex flex-col gap-3">
                <InvitationOutcome result={invite.data} />
                <div className="flex flex-wrap justify-end gap-2">
                  <ActionButton variant="secondary" onClick={startAgain}>
                    Invite someone else
                  </ActionButton>
                  <ActionButton onClick={close}>Done</ActionButton>
                </div>
              </div>
            ) : (
              <form
                className="flex flex-col gap-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (!invite.isPending) invite.mutate();
                }}
              >
                <label className="flex flex-col gap-1 text-sm font-medium">
                  Email
                  <input
                    type="email"
                    required
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="sam@northwindfoods.co.uk"
                    autoComplete="off"
                    className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm font-normal`}
                  />
                  <span className="text-xs font-normal text-muted-foreground">
                    The invitation goes here, and they sign in with this address.
                  </span>
                </label>
                <label className="flex flex-col gap-1 text-sm font-medium">
                  Name
                  <input
                    required
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="Sam Ogunjobi"
                    autoComplete="off"
                    className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm font-normal`}
                  />
                  <span className="text-xs font-normal text-muted-foreground">
                    The name shown beside their actions.
                  </span>
                </label>

                <ErrorNote error={invite.error} />

                <div className="mt-2 flex flex-wrap justify-end gap-2">
                  <ActionButton variant="secondary" onClick={close} disabled={invite.isPending}>
                    Cancel
                  </ActionButton>
                  <ActionButton type="submit" busy={invite.isPending}>
                    {invite.isPending ? "Sending…" : "Send invitation"}
                  </ActionButton>
                </div>
              </form>
            )}
          </DialogContent>
        </Dialog>
      </div>
    </section>
  );
}

/** What an invitation became, as a screen shows it. */
export type InvitationSent = {
  email: string;
  /** True only when the email service named the message. */
  emailed: boolean;
  /** Why it was not emailed; null when it was. */
  reason: string | null;
  /** The plain join link, to copy. Never the one-click sign-in link. */
  link: string;
};

/**
 * Make an invitation and email it, through the invite function.
 *
 * A refusal throws the ErpError callInvite built, so the form shows it the way
 * it shows any other. The function answering at all means it did whatever it
 * did — so its answer is final and nothing is retried, because each door call
 * supersedes the token before it.
 *
 * Only when the function could not be reached at all — not deployed yet, the
 * relay down, a network that blocks it — is the door called directly, which is
 * what the screen did before email existed: the invitation is still made, its
 * link is still offered, and the reason says why nothing was sent.
 */
export async function sendInvitation(request: InviteRequest): Promise<InvitationSent> {
  try {
    const answer = await callInvite(request);
    const link = typeof answer.join_link === "string" ? answer.join_link : "";
    if (answer.emailed === true) {
      return { email: answer.email, emailed: true, reason: null, link };
    }
    return {
      email: answer.email,
      emailed: false,
      reason: answer.reason || "The email was not sent",
      link,
    };
  } catch (error) {
    if (!(error instanceof InviteUnreachable)) throw error;
    const args: Record<string, unknown> = { ...request.args };
    const made = await callErp<unknown>(request.door, args);
    const invited = invitationFrom(request.door, args, made);
    if (!invited) throw new Error("The invitation was not created.");
    const origin = typeof window === "undefined" ? "" : window.location.origin;
    return {
      email: invited.email,
      emailed: false,
      reason: error.message,
      link: joinLink(origin, invited.token),
    };
  }
}

/**
 * What became of an invitation: emailed or not, and its link to copy.
 *
 * The link is offered even when the email went, because "I never got it" is
 * the commonest reply to an invitation and the answer should not be another
 * invitation. It is shown once: the database keeps only a digest of the token
 * inside it. The clipboard is not always there — an insecure origin, a browser
 * that refuses — so a failed copy shows the link in a field instead.
 */
export function InvitationOutcome({
  result,
  note,
}: {
  result: InvitationSent;
  /** What happens next, where that is not obvious from the invitation. */
  note?: string | undefined;
}) {
  const [copy, setCopy] = useState<"idle" | "copied" | "manual">("idle");

  const copyLink = async () => {
    try {
      if (typeof navigator === "undefined" || !navigator.clipboard) throw new Error("no clipboard");
      await navigator.clipboard.writeText(result.link);
      setCopy("copied");
    } catch {
      setCopy("manual");
    }
  };

  return (
    <div role="status" className="rounded-lg border border-primary/40 bg-primary/5 p-3">
      <p className="text-sm font-medium">
        {result.emailed
          ? `Invitation emailed to ${result.email}.`
          : `Invitation made for ${result.email}, but not emailed.`}
      </p>
      {result.emailed ? (
        <p className="mt-1 text-xs text-muted-foreground">
          If it does not arrive, copy the link below and send it to them yourself.
        </p>
      ) : (
        <p className="mt-1 text-xs text-muted-foreground">
          {(result.reason ?? "The email was not sent").replace(/[.\s]+$/, "")}. Copy the link and
          send it to them yourself.
        </p>
      )}
      {note ? <p className="mt-1 text-xs text-muted-foreground">{note}</p> : null}
      {result.link ? (
        <>
          <p className="mt-1 text-xs text-muted-foreground">
            The link is shown once and works for whoever opens it first, so send it only to them.
          </p>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => void copyLink()}
              className={`${TOUCH} inline-flex items-center rounded-md border border-input bg-background px-3 text-xs font-medium`}
            >
              {copy === "copied" ? "Link copied" : "Copy link"}
            </button>
          </div>
          {copy === "manual" ? (
            <label className="mt-2 flex flex-col gap-1 text-xs font-medium">
              The clipboard is not available here. Select the link and copy it:
              <input
                readOnly
                value={result.link}
                onFocus={(e) => e.currentTarget.select()}
                className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 font-mono text-xs font-normal`}
              />
            </label>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
