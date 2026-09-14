import { expiryDate } from "./invitation-email";

/**
 * Who can sign in, and what may be done about it, as the People panel shows it.
 *
 * Pure, so every state is tested without a database. Nothing here decides
 * anything the database does not decide again: erp.remove_principal,
 * erp.withdraw_invitation and erp.restore_principal authorise
 * administration.users themselves and refuse by name. What this file decides
 * is only which buttons a row offers, and which of them are shown pressed-in
 * with the reason beside them.
 *
 * Every key the directory added with the withdraw-and-restore migration is
 * optional here, because the desk and the database are deployed separately:
 * for a while this screen may read a directory that does not carry them yet.
 */

/** One principal, as public.erp_permissions_directory() returns it. */
export type DirectoryPrincipal = {
  id: string;
  display_name: string;
  email: string | null;
  kind: "person" | "service";
  /** erp.principal_status: invited, active, suspended or disabled. */
  status: string;
  created_at: string;
  /** Whether an auth account is attached, which is whether they ever joined. */
  has_signed_in?: boolean | undefined;
  /** The newest invitation neither claimed nor withdrawn. */
  invited_at?: string | null | undefined;
  invitation_expires_at?: string | null | undefined;
  invitation_state?: "pending" | "expired" | "none" | undefined;
  /** Holds administration.users organisation-wide today. */
  manages_users?: boolean | undefined;
  /** Platform staff who entered through a support window. */
  is_support?: boolean | undefined;
};

export type AccessState = "invited" | "invitation_expired" | "active" | "removed" | "suspended";

/**
 * Where somebody stands.
 *
 * principal_context resolves only 'active', so every other status is a person
 * who cannot sign in, and a status this screen does not know is shown as
 * removed rather than as anything that suggests access.
 *
 * An invited person whose directory says no invitation is open has no link
 * that works, which is what an expired invitation means to whoever is looking.
 */
export function accessState(principal: DirectoryPrincipal): AccessState {
  switch (principal.status) {
    case "active":
      return "active";
    case "suspended":
      return "suspended";
    case "invited":
      return principal.invitation_state === "expired" || principal.invitation_state === "none"
        ? "invitation_expired"
        : "invited";
    default:
      return "removed";
  }
}

/** The words on the status pill. */
export function accessLabel(principal: DirectoryPrincipal): string {
  const state = accessState(principal);
  switch (state) {
    case "invited": {
      const until = expiryDate(principal.invitation_expires_at);
      return until ? `Invited · link expires ${until}` : "Invited";
    }
    case "invitation_expired":
      return "Invitation expired";
    case "active":
      return "Active";
    case "suspended":
      return "Suspended";
    case "removed":
      return "Removed";
  }
}

/** The same, as one lower-case word, for a picker that already names the person. */
export function accessWord(principal: DirectoryPrincipal): string {
  const state = accessState(principal);
  return state === "invitation_expired" ? "invitation expired" : state;
}

export type AccessAction =
  | "send_invitation_again"
  | "withdraw_invitation"
  | "remove_access"
  | "restore_access"
  | "invite_again";

export type OfferedAction = {
  action: AccessAction;
  /** Why it is offered but cannot be pressed; null when it can. */
  disabledReason: string | null;
};

export const CANNOT_REMOVE_YOURSELF =
  "You cannot remove your own access. Another administrator can remove you.";

export const LAST_USER_MANAGER =
  "They are the last person who can manage users. Give somebody else a role with administration.users first.";

export const NO_EMAIL_ADDRESS = "There is no email address to send an invitation to.";

/**
 * The people other than `excluding` who can manage users today: active,
 * people, not platform support, holding administration.users organisation-wide.
 *
 * The same count erp.user_managers_remaining() makes, from what the directory
 * says about each principal, so the screen can say "the last one" before the
 * database has to.
 */
export function userManagersOtherThan(
  principals: readonly DirectoryPrincipal[],
  excluding: string,
): number {
  return principals.filter(
    (p) =>
      p.id !== excluding &&
      p.kind === "person" &&
      p.status === "active" &&
      p.is_support !== true &&
      p.manages_users === true,
  ).length;
}

/**
 * The actions a row offers.
 *
 *   Platform support             nothing: they come back through the console
 *   Service user, active         remove
 *   Service user, otherwise      nothing
 *   Invited, or it expired       send the invitation again, withdraw it
 *   Active                       remove, pressed-in for yourself or the last user manager
 *   Removed or suspended         restore if they ever signed in, else invite again
 */
export function actionsFor(
  principal: DirectoryPrincipal,
  context: { selfId: string | null; managersRemaining: number },
): OfferedAction[] {
  if (principal.is_support === true) return [];

  const state = accessState(principal);
  const noEmail = principal.email === null || principal.email.trim() === "";

  if (principal.kind === "service") {
    return state === "active"
      ? [
          {
            action: "remove_access",
            disabledReason: principal.id === context.selfId ? CANNOT_REMOVE_YOURSELF : null,
          },
        ]
      : [];
  }

  switch (state) {
    case "invited":
    case "invitation_expired":
      return [
        { action: "send_invitation_again", disabledReason: noEmail ? NO_EMAIL_ADDRESS : null },
        { action: "withdraw_invitation", disabledReason: null },
      ];
    case "active":
      return [
        {
          action: "remove_access",
          disabledReason:
            principal.id === context.selfId
              ? CANNOT_REMOVE_YOURSELF
              : principal.manages_users === true && context.managersRemaining <= 0
                ? LAST_USER_MANAGER
                : null,
        },
      ];
    case "removed":
    case "suspended":
      return principal.has_signed_in === true
        ? [{ action: "restore_access", disabledReason: null }]
        : [{ action: "invite_again", disabledReason: noEmail ? NO_EMAIL_ADDRESS : null }];
  }
}

/* -------------------------------------------------------------------------- */
/* What the doors said, as a sentence.                                        */
/* -------------------------------------------------------------------------- */

function field(record: unknown, name: string): unknown {
  return typeof record === "object" && record !== null && !Array.isArray(record)
    ? (record as Record<string, unknown>)[name]
    : undefined;
}

function count(record: unknown, name: string): number {
  const value = field(record, name);
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** erp_remove_principal: {app_user_id, status, already_removed, grants_ended, invitations_withdrawn}. */
export function removalOutcome(name: string, result: unknown): string {
  if (field(result, "already_removed") === true) {
    return `${name} had already been removed, so nothing changed.`;
  }
  const parts = [`${name} no longer has access.`];
  const grants = count(result, "grants_ended");
  if (grants > 0) parts.push(`${plural(grants, "role", "roles")} ended.`);
  const invitations = count(result, "invitations_withdrawn");
  if (invitations > 0) {
    parts.push(
      invitations === 1
        ? "Their open invitation was withdrawn."
        : `${invitations} open invitations were withdrawn.`,
    );
  }
  return parts.join(" ");
}

/**
 * erp_withdraw_invitation: {app_user_id, status, invitations_withdrawn}.
 *
 * Nought withdrawn is still a withdrawal: an invitation that had already
 * expired has no link to end, and the person is no longer invited either way.
 */
export function withdrawalOutcome(name: string, result: unknown): string {
  return count(result, "invitations_withdrawn") > 0
    ? `The invitation to ${name} was withdrawn. Its link no longer works.`
    : `${name} is no longer invited.`;
}

/**
 * erp_restore_principal: {app_user_id, status, roles_restored: 0}.
 *
 * Restoring gives nothing back but the ability to sign in, so the sentence
 * says where the roles are given rather than reading a count that is always 0.
 */
export function restoreOutcome(name: string): string {
  return `${name} can sign in again. They hold no roles yet, so give them the roles they need below.`;
}
