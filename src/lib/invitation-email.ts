/**
 * An invitation, as an email: what it says, where its link goes, and the few
 * rules the sender and the page it lands on have to agree about.
 *
 * Two runtimes read this file. The invite Edge Function imports it as
 * ../../../src/lib/invitation-email.ts under Deno, and the desk imports it as
 * any other module under Vite and Bun. So it imports nothing, and it touches no
 * process, window, Deno or import.meta — only the language itself, URL,
 * URLSearchParams and Intl, which every one of those has. Deno also wants the
 * .ts extension on anything relative, which is a reason to have nothing
 * relative to import.
 *
 * Pure on purpose. Nothing here decides who may invite: the function calls the
 * door as the signed-in person and the database decides. This decides only
 * what the person invited reads and what the page they land on accepts.
 *
 * The organisation name and both people's names are typed by a tenant, so
 * all of them are treated as hostile: squeezed onto one line for the subject
 * and escaped for the HTML. The message carries no images, no tracking and no
 * remote assets; the only URL in it is the one the person should open.
 */

/**
 * The doors that make an invitation, by name.
 *
 * Kept as literals here, in src, because supabase/ci/app_doors.sh harvests the
 * quoted erp_* names under src to prove every door has a caller. The desk no
 * longer calls these through callErp in the ordinary case — the invite
 * function does, as the signed-in person — so without this list the build
 * would think nothing reaches them.
 */
export const INVITE_DOORS = [
  "erp_invite_principal",
  "erp_platform_invite_admin",
  "erp_platform_onboard_company",
] as const;

export type InviteDoor = (typeof INVITE_DOORS)[number];

export function isInviteDoor(value: unknown): value is InviteDoor {
  return typeof value === "string" && (INVITE_DOORS as readonly string[]).includes(value);
}

/**
 * How long each door's invitation stays open, in days.
 *
 * erp.invite_principal defaults p_valid_for to seven days (20260910135355);
 * erp_platform_invite_admin writes fourteen (20260830091046), and
 * erp_platform_onboard_company hands erp.provision_tenant fourteen
 * (20260904770000). The doors do not return the expiry, so the email states it
 * from here; a door that changes its interval should change this line too.
 */
export const INVITE_VALID_DAYS: Readonly<Record<InviteDoor, number>> = {
  erp_invite_principal: 7,
  erp_platform_invite_admin: 14,
  erp_platform_onboard_company: 14,
};

/* -------------------------------------------------------------------------- */
/* What passes between the desk and the invite function.                      */
/* -------------------------------------------------------------------------- */

export type OrganisationInviteArgs = { p_email: string; p_display_name: string };

export type PlatformInviteArgs = {
  p_tenant_id: string;
  p_email: string;
  p_display_name: string;
};

export type OnboardCompanyArgs = {
  p_code: string;
  p_name: string;
  p_admin_email: string;
  p_admin_display_name: string;
  p_base_currency?: string;
  p_country_code?: string;
  p_timezone?: string;
};

/** Make an invitation through one of the doors, then email it. Needs a session. */
export type InviteRequest =
  | { door: "erp_invite_principal"; args: OrganisationInviteArgs }
  | { door: "erp_platform_invite_admin"; args: PlatformInviteArgs }
  | { door: "erp_platform_onboard_company"; args: OnboardCompanyArgs };

/** Email a fresh sign-in link for an invitation still open. Needs no session. */
export type ResendRequest = { resend_token: string };

/**
 * What an invitation became.
 *
 * `join_link` is the plain link — the token and no sign-in part — which is
 * what the inviter may copy. The one-click sign-in link goes into the email
 * and nowhere else: a link that signs somebody in as another person is not
 * something an inviter may hold. Anything but `emailed === true` is not sent.
 */
export type InviteResponse =
  | {
      app_user_id: string;
      email: string;
      emailed: true;
      provider_message_id: string;
      join_link: string;
    }
  | { app_user_id: string; email: string; emailed: false; reason: string; join_link: string };

/** The same shape whether the token was good or not; `sent` is all it says. */
export type ResendResponse = { sent: boolean };

/** A refusal, in the database's own words, as the function passes it on. */
export type InviteErrorBody = { error: string; code?: string | null; hint?: string | null };

/* -------------------------------------------------------------------------- */
/* Reading what a door handed back.                                           */
/* -------------------------------------------------------------------------- */

/** The argument that names the invited address, per door. */
export function emailArgumentOf(door: InviteDoor): "p_email" | "p_admin_email" {
  return door === "erp_platform_onboard_company" ? "p_admin_email" : "p_email";
}

/** The argument that names the invited person, per door. */
export function nameArgumentOf(door: InviteDoor): "p_display_name" | "p_admin_display_name" {
  return door === "erp_platform_onboard_company" ? "p_admin_display_name" : "p_display_name";
}

export type Invited = {
  appUserId: string;
  /** The address the door accepted, which is the only address the email may go to. */
  email: string;
  token: string;
  /** Known from the result only when the door created the organisation. */
  organisation: string | null;
};

function field(record: unknown, name: string): unknown {
  return typeof record === "object" && record !== null && !Array.isArray(record)
    ? (record as Record<string, unknown>)[name]
    : undefined;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/**
 * The invitation a door just made, or null when the result is not one.
 *
 *   erp_invite_principal         {app_user_id, token}; it stores btrim(p_email)
 *   erp_platform_invite_admin    {app_user_id, email, token}
 *   erp_platform_onboard_company {admin_user_id, admin_email, admin_token, name, …}
 */
export function invitationFrom(
  door: InviteDoor,
  args: Record<string, unknown>,
  result: unknown,
): Invited | null {
  const onboarding = door === "erp_platform_onboard_company";
  const token = text(field(result, onboarding ? "admin_token" : "token"));
  const appUserId = text(field(result, onboarding ? "admin_user_id" : "app_user_id"));
  const email =
    text(field(result, onboarding ? "admin_email" : "email")) ?? text(args[emailArgumentOf(door)]);
  if (!token || !appUserId || !email) return null;
  return {
    appUserId,
    email,
    token,
    organisation: onboarding ? text(field(result, "name")) : null,
  };
}

/**
 * Which refusals are the caller's to read, and with what status.
 *
 * 403 for the database saying no to this person. 400 for a refusal it wrote
 * for a person to read — CLOVEERP_ or, for one more release, ERPWARE_, with or
 * without a message after the colon (erp_platform_invite_admin raises a bare
 * ERPWARE_UNKNOWN_TENANT) — for any other deliberate raise, and for input the
 * database would not take: a malformed id, a code that is already in use.
 * Anything else is ours, and null says so.
 */
export function refusalStatus(code: unknown, message: unknown): 400 | 403 | null {
  const sqlstate = typeof code === "string" ? code : "";
  const said = typeof message === "string" ? message : "";
  const token = /^((?:CLOVEERP|ERPWARE)_[A-Z0-9_]+)(?::|$)/.exec(said)?.[1] ?? null;
  if (sqlstate === "42501" || token === "CLOVEERP_PERMISSION_DENIED") return 403;
  if (token === "ERPWARE_PERMISSION_DENIED") return 403;
  if (token) return 400;
  if (sqlstate === "P0001" || /^2[23][0-9A-Z]{3}$/.test(sqlstate)) return 400;
  return null;
}

/* -------------------------------------------------------------------------- */
/* The link, and the page it lands on.                                        */
/* -------------------------------------------------------------------------- */

/** A token is hex today; this only keeps obvious rubbish out. */
const PLAUSIBLE_TOKEN = /^[A-Za-z0-9._~-]{32,512}$/;

export function plausibleInvitationToken(value: unknown): value is string {
  return typeof value === "string" && PLAUSIBLE_TOKEN.test(value);
}

/**
 * Where a person lands to accept.
 *
 * Everything after the `#`. A fragment is never sent to a server, so the token
 * and the sign-in link reach no access log, no proxy and no link scanner that
 * fetches the address to check it — which matters twice over for the sign-in
 * part, because it works once and a scanner that followed it would use it up.
 *
 * With `actionLink`, the page offers one button that signs the person in on
 * the way. Without it — the link an inviter copies — the page offers to email
 * them one.
 */
export function joinLink(origin: string, token: string, actionLink?: string | null): string {
  const base = `${origin.replace(/\/+$/, "")}/join#invitation=${encodeURIComponent(token)}`;
  return actionLink ? `${base}&signin=${encodeURIComponent(actionLink)}` : base;
}

export type JoinArrival = {
  /** The invitation token the link carried, if it looked like one. */
  invitation: string | null;
  /** The sign-in link it carried, unchecked; see verifiedSignInLink(). */
  signin: string | null;
  /** What Supabase Auth said went wrong, when it came back with an error. */
  failure: string | null;
};

/**
 * What the address bar says about how somebody arrived at /join.
 *
 * Supabase Auth reports a sign-in link that expired or was already used as
 * error, error_code and error_description — in the fragment for this client's
 * flow, and in the query for others — so both are read.
 */
export function readJoinArrival(hash: string, search = ""): JoinArrival {
  const fragment = new URLSearchParams(hash.replace(/^#/, ""));
  const query = new URLSearchParams(search.replace(/^\?/, ""));
  const invitation = fragment.get("invitation")?.trim() ?? "";
  const signin = fragment.get("signin")?.trim() ?? "";
  const described = fragment.get("error_description") ?? query.get("error_description");
  const failed =
    fragment.get("error_code") ??
    fragment.get("error") ??
    query.get("error_code") ??
    query.get("error");
  return {
    invitation: plausibleInvitationToken(invitation) ? invitation : null,
    signin: signin === "" ? null : signin,
    failure: described || failed ? oneLine(described || failed, 200) : null,
  };
}

/**
 * The sign-in link, only if it is Supabase Auth's own verification endpoint for
 * this project.
 *
 * The page navigates to it, and the fragment it came from is something anybody
 * can write, so anything else — another host, another path, a javascript: URL
 * — is dropped rather than followed. The prefix test is on the raw string and
 * the URL test on the parsed one, so neither a lookalike host nor a path trick
 * gets through the other.
 */
export function verifiedSignInLink(
  signin: string | null | undefined,
  supabaseUrl: string,
): string | null {
  if (!signin || /\s/.test(signin)) return null;
  if ([...signin].some((c) => c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127)) return null;
  const base = supabaseUrl.replace(/\/+$/, "");
  if (!signin.startsWith(`${base}/auth/v1/verify?`)) return null;
  try {
    const url = new URL(signin);
    return url.origin === new URL(base).origin && url.pathname === "/auth/v1/verify"
      ? signin
      : null;
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------------- */
/* The message.                                                               */
/* -------------------------------------------------------------------------- */

const HTML_ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (c) => HTML_ESCAPES[c] ?? c);
}

/**
 * One line, bounded. Control characters and line breaks become spaces, so a
 * name cannot start a second header line or a second paragraph.
 */
export function oneLine(value: string | null | undefined, max = 120): string {
  const flat = [...(value ?? "")]
    .map((c) => (c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 ? " " : c))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return flat.length > max ? `${flat.slice(0, max - 1).trimEnd()}…` : flat;
}

/** "20 September 2026", or null for nothing or nonsense. UTC, so it says one day everywhere. */
export function expiryDate(expiresAt: Date | string | null | undefined): string | null {
  if (expiresAt === null || expiresAt === undefined || expiresAt === "") return null;
  const when = expiresAt instanceof Date ? expiresAt : new Date(expiresAt);
  if (Number.isNaN(when.getTime())) return null;
  return new Intl.DateTimeFormat("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(when);
}

export type InvitationEmailInput = {
  /** The organisation they are invited into. */
  organisation: string | null | undefined;
  /** Who invited them, as the product shows that person's name. */
  inviter: string | null | undefined;
  /** The name the inviter typed for them. */
  invitee: string | null | undefined;
  /** The link to open. Used verbatim; build it with joinLink(). */
  link: string;
  /** When the invitation stops working. */
  expiresAt: Date | string | null | undefined;
  /**
   * A new sign-in link for an invitation already sent, asked for from the page
   * the first one opened. Same link, fewer words: they know who invited them.
   */
  resent?: boolean;
};

export type InvitationEmail = { subject: string; text: string; html: string };

// The site's palette as hex, as supabase/functions/enquiry/index.ts has it:
// src/styles.css defines these in oklch, which most mail clients do not read.
const BRAND = "#36312B";
const SURFACE = "#F6F4F0";
const CARD = "#FEFDFA";
const SOFT = "#E9E6DE";
const LINE = "#DCD7CE";
const INK = "#403B36";
const MUTED = "#67625D";
const ACCENT = "#A2591E";
const SANS = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

export function invitationEmail(input: InvitationEmailInput): InvitationEmail {
  const organisation = oneLine(input.organisation) || "an organisation";
  const inviter = oneLine(input.inviter);
  const invitee = oneLine(input.invitee);
  const until = expiryDate(input.expiresAt);
  const resent = input.resent === true;

  const subject = oneLine(
    resent
      ? `Your sign-in link for ${organisation} on Clove ERP`
      : inviter
        ? `${inviter} invited you to join ${organisation} on Clove ERP`
        : `You are invited to join ${organisation} on Clove ERP`,
    200,
  );
  const greeting = invitee ? `Hello ${invitee},` : "Hello,";
  const lead = resent
    ? `Here is a new sign-in link for your invitation to join ${organisation} on Clove ERP.`
    : inviter
      ? `${inviter} has invited you to join ${organisation} on Clove ERP.`
      : `You have been invited to join ${organisation} on Clove ERP.`;
  const action = resent ? "Sign in and join" : "Accept the invitation";
  const how =
    "The link signs you in with this email address and brings you into the organisation. " +
    "It works once, and only for a short while; if it has expired, the page it opens can " +
    "send you a new one.";
  const lasts = until ? `The invitation itself stays open until ${until}.` : null;
  const unexpected = resent
    ? "If you did not ask for a new link, you can ignore this email."
    : "If you were not expecting this, you can ignore this email. Nobody is added to " +
      "anything unless the link is used.";

  const text = [
    greeting,
    "",
    lead,
    "",
    `${action}:`,
    input.link,
    "",
    lasts ? `${how} ${lasts}` : how,
    "",
    unexpected,
    "",
  ].join("\n");

  const href = escapeHtml(input.link);
  const paragraph = (words: string, size = 15, colour = INK) =>
    `<p style="margin:0 0 16px;color:${colour};font-family:${SANS};font-size:${size}px;` +
    `line-height:1.55;word-break:break-word;">${escapeHtml(words)}</p>`;

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="light" />
<title>${escapeHtml(subject)}</title>
</head>
<body style="margin:0;padding:0;background:${SURFACE};">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:${SURFACE};font-size:1px;line-height:1px;">${escapeHtml(lead)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${SURFACE};">
<tr><td align="center" style="padding:32px 16px;">
  <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background:${CARD};border:1px solid ${LINE};border-radius:14px;">
    <tr><td style="padding:20px 28px;background:${BRAND};border-radius:14px 14px 0 0;color:#FFFFFF;font-family:Georgia,'Times New Roman',serif;font-size:18px;letter-spacing:0.02em;">Clove&nbsp;ERP</td></tr>
    <tr><td style="padding:28px 28px 8px;">
      ${paragraph(greeting)}
      ${paragraph(lead)}
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 20px;"><tr>
        <td style="background:${BRAND};border-radius:8px;">
          <a href="${href}" style="display:inline-block;padding:12px 22px;color:#FFFFFF;font-family:${SANS};font-size:15px;font-weight:600;text-decoration:none;">${escapeHtml(action)}</a>
        </td>
      </tr></table>
      ${paragraph(how, 13, MUTED)}
      ${lasts ? paragraph(lasts, 13, MUTED) : ""}
      <p style="margin:0 0 16px;color:${MUTED};font-family:${SANS};font-size:13px;line-height:1.55;">If the button does not work, open this address:<br /><a href="${href}" style="color:${ACCENT};word-break:break-all;">${href}</a></p>
    </td></tr>
    <tr><td style="padding:16px 28px;border-top:1px solid ${SOFT};border-radius:0 0 14px 14px;">
      ${paragraph(unexpected, 12, MUTED)}
    </td></tr>
  </table>
</td></tr>
</table>
</body>
</html>`;

  return { subject, text, html };
}
