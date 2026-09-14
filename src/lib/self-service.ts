import { readJoinArrival } from "./invitation-email";

/**
 * Self-service sign-up, as the desk reads it.
 *
 * Organisations come by invitation. Somebody who signs in and belongs to no
 * organisation cannot make one, or a demo, unless they are a platform operator
 * or owner, or the platform owner has opened self-service sign-up from the
 * console. The
 * database refuses regardless — erp_onboard_tenant and the demo doors check the
 * switch and the caller themselves — so what is decided here is only which
 * screen to show, and a screen that guessed wrong would still be refused.
 *
 * Pure, so the choice can be tested without a browser. Nothing here imports the
 * Supabase client.
 */

/**
 * What public.erp_self_service_organisations_open() said, read strictly.
 *
 * Only a literal true opens anything. A missing door on an older schema, an
 * error, or any other payload is closed: the screen that asks for an invitation
 * is the safe one to show, because the database would refuse the other.
 */
export function selfServiceIsOpen(answer: unknown): boolean {
  return answer === true;
}

/**
 * Whether the desk offers demo data at all: to platform operators and owners,
 * and to anybody while self-service sign-up is open — the same two the demo
 * doors serve.
 *
 * A customer is neither, and is not shown a card that talks about demo data
 * with nothing on it to press. `open` is the switch's raw answer, so an
 * outstanding or failed answer offers nothing.
 */
export function maySeedDemo(input: { staff: boolean; open: unknown }): boolean {
  return input.staff || selfServiceIsOpen(input.open);
}

/** What public.erp_platform_set_self_service_organisations() returns. */
export type SelfServiceChange = {
  open: boolean;
  reason: string | null;
  updated_at: string | null;
};

/** The change the door reports, or null when the answer is not that shape. */
export function readSelfServiceChange(answer: unknown): SelfServiceChange | null {
  if (typeof answer !== "object" || answer === null || Array.isArray(answer)) return null;
  const row = answer as Record<string, unknown>;
  const open = row["open"];
  if (typeof open !== "boolean") return null;
  const reason = row["reason"];
  const updated = row["updated_at"];
  return {
    open,
    reason: typeof reason === "string" && reason.trim() !== "" ? reason : null,
    updated_at: typeof updated === "string" && updated !== "" ? updated : null,
  };
}

/**
 * A reason the switch can be changed with. The door refuses an empty one by
 * name; this only saves the round trip.
 */
export function usableReason(reason: string): boolean {
  return reason.trim().length > 0;
}

/**
 * The screen somebody signed in without an organisation sees.
 *
 *   join             an invitation is held — arrived by link or pasted — and
 *                    the only thing on the screen is the card that names the
 *                    account about to join it
 *   checking         not yet known whether this account is a platform operator
 *                    or owner, or whether self-service sign-up is open
 *   create           platform operators and owners, or anybody while
 *                    self-service sign-up is open: the invitation hint, and
 *                    creating an organisation or a demo, as before invitations
 *                    were the only way in
 *   invitation-only  everybody else: they need an invitation
 *
 * `staff` is whether the account is platform staff who may create regardless
 * of the switch — an operator or an owner; support staff are not. `staff` and
 * `open` are undefined while their answers are outstanding. The switch is only
 * asked about for somebody who is not, so `open` is ignored for staff.
 */
export type OnboardingView = "join" | "checking" | "create" | "invitation-only";

export function onboardingView(input: {
  invitation: string | null;
  staff: boolean | undefined;
  open: boolean | undefined;
}): OnboardingView {
  if (input.invitation !== null && input.invitation.trim() !== "") return "join";
  if (input.staff === undefined) return "checking";
  if (input.staff) return "create";
  if (input.open === undefined) return "checking";
  return input.open ? "create" : "invitation-only";
}

/**
 * What somebody pasted: a bare token, or the join link an inviter copied, whose
 * token sits after the #. Anything else is passed on as typed, and the
 * database says what is wrong with it.
 */
export function pastedToken(pasted: string): string {
  const value = pasted.trim();
  const hash = value.indexOf("#");
  return (hash >= 0 ? readJoinArrival(value.slice(hash)).invitation : null) ?? value;
}
