/**
 * Inviting somebody, and telling them.
 *
 * The invitation itself is the database's: the door is called with the
 * caller's own bearer token, so erp.authorise() and row security decide who
 * may invite exactly as they do from any screen. Nothing here widens that. A
 * refusal comes back as { ok: false } in the database's own words.
 *
 * Only once the door has said yes does this do anything the caller could not:
 *
 *   - with the service role available, ask Supabase Auth for a sign-in link
 *     to the invitee's address that lands on /join carrying the token, so one
 *     click signs them in and brings them in. That link goes into the email
 *     and nowhere else — never back to the caller, because a sign-in link for
 *     somebody else's account is not something an inviter may hold.
 *   - post the email through Resend.
 *
 * Email is optional for a site. Without a key and a sender it says so and
 * still returns the plain join link, which is what the screen offers to copy
 * in every case. Neither the token nor either link is ever logged.
 */
import { createServerFn } from "@tanstack/react-start";
import { getRequest } from "@tanstack/react-start/server";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

import { callErp, ErpError, supabase } from "./erp";
import {
  invitationEmail,
  joinLink,
  oneLine,
  redirectKeepsInvitation,
  sendWithResend,
} from "./invitation-email";

/** erp.invite_principal's p_valid_for default (20260910135355). */
const ORGANISATION_INVITATION_DAYS = 7;
/** public.erp_platform_invite_admin's expiry (20260830091046). */
const PLATFORM_INVITATION_DAYS = 14;

const NOT_SET_UP = "Email is not set up for this site yet";

const address = z
  .string()
  .trim()
  .min(3)
  .max(320)
  .refine((v) => v.includes("@"), "An email address is required.");
const name = z.string().trim().min(1).max(200);

const input = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("organisation"), email: address, displayName: name }),
  z.object({
    kind: z.literal("platform"),
    tenantId: z.string().uuid(),
    email: address,
    displayName: name,
  }),
]);

export type InvitationRequest = z.input<typeof input>;

export type InvitationSent = {
  ok: true;
  emailed: boolean;
  /** Why it was not emailed; null when it was. */
  reason: string | null;
  email: string;
  /** The plain join link, for copying. Never the one-click sign-in link. */
  link: string;
  token: string;
};

export type InvitationResult = { ok: false; error: string; code: string | null } | InvitationSent;

/** What either door returns: erp_invite_principal has no email, the platform's does. */
type Invited = { token?: string; email?: string };

export const sendInvitation = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((data: InvitationRequest) => input.parse(data))
  .handler(async ({ data, context }): Promise<InvitationResult> => {
    const rpc = <T = unknown>(fn: string, args?: Record<string, unknown>) =>
      (
        context.supabase.rpc as unknown as (
          n: string,
          a?: Record<string, unknown>,
        ) => Promise<{ data: T; error: { message: string; code?: string } | null }>
      )(fn, args);

    const invited =
      data.kind === "organisation"
        ? await rpc<Invited | null>("erp_invite_principal", {
            p_email: data.email,
            p_display_name: data.displayName,
          })
        : await rpc<Invited | null>("erp_platform_invite_admin", {
            p_tenant_id: data.tenantId,
            p_email: data.email,
            p_display_name: data.displayName,
          });
    if (invited.error) {
      return { ok: false, error: invited.error.message, code: invited.error.code ?? null };
    }

    const token = String(invited.data?.token ?? "");
    // The platform door lower-cases the address it stored; say that one back.
    const email = invited.data?.email || data.email;
    if (!token) {
      return { ok: false, error: "The invitation was not created.", code: null };
    }

    // From here the invitation exists. Nothing below may throw, or the screen
    // would report a failure for an invitation that was made.
    let link = joinLink("", token);
    try {
      link = joinLink(appOrigin(), token);

      const apiKey = process.env["RESEND_API_KEY"];
      const from = process.env["CLOVEERP_MAIL_FROM"];
      if (!apiKey || !from) return sent(email, link, token, NOT_SET_UP);

      const names = await namesFor(data, rpc);
      const message = invitationEmail({
        organisation: names.organisation,
        inviter: names.inviter,
        inviteeName: data.displayName,
        link: await oneClickLink(email, link),
        expiresInDays:
          data.kind === "organisation" ? ORGANISATION_INVITATION_DAYS : PLATFORM_INVITATION_DAYS,
      });

      const posted = await sendWithResend({ apiKey, from, to: email, ...message });
      return sent(email, link, token, posted.ok ? null : posted.reason);
    } catch (error) {
      return sent(
        email,
        link,
        token,
        `The email could not be sent (${oneLine(error instanceof Error ? error.message : String(error), 160)})`,
      );
    }
  });

function sent(email: string, link: string, token: string, reason: string | null): InvitationSent {
  return { ok: true, emailed: reason === null, reason, email, link, token };
}

/**
 * The site's own address. CLOVEERP_APP_URL wins where it is set, and should be
 * set in production: the request's own URL is only as trustworthy as the host
 * that answered it.
 */
function appOrigin(): string {
  const configured = process.env["CLOVEERP_APP_URL"]?.trim();
  if (configured) {
    try {
      return new URL(configured).origin;
    } catch {
      /* not a URL; fall back to the request */
    }
  }
  return new URL(getRequest().url).origin;
}

type Rpc = <T = unknown>(
  fn: string,
  args?: Record<string, unknown>,
) => Promise<{ data: T; error: { message: string } | null }>;

/** Who is inviting, into what. Either may be unknown; the email copes. */
async function namesFor(
  data: z.output<typeof input>,
  rpc: Rpc,
): Promise<{ organisation: string | null; inviter: string | null }> {
  if (data.kind === "organisation") {
    const session = await rpc<{
      tenant?: { name?: string | null } | null;
      principal?: { display_name?: string | null } | null;
    } | null>("erp_session");
    return {
      organisation: session.data?.tenant?.name ?? null,
      inviter: session.data?.principal?.display_name ?? null,
    };
  }
  const [tenants, me] = await Promise.all([
    rpc<Array<{ id?: string; name?: string | null }> | null>("erp_platform_tenants"),
    rpc<{ display_name?: string | null } | null>("erp_platform_me"),
  ]);
  const tenant = (tenants.data ?? []).find((t) => t.id === data.tenantId);
  return { organisation: tenant?.name ?? null, inviter: me.data?.display_name ?? null };
}

/**
 * A link that signs the invitee in and lands on /join with the token.
 *
 * 'invite' for an address with no account yet; 'magiclink' when it already
 * has one, which is what the invite call's error means. Anything else — no
 * service role, Auth refusing, a redirect Auth would not honour — and the
 * plain join link is what gets sent: it still works, it just asks them to
 * sign in first.
 */
async function oneClickLink(email: string, link: string): Promise<string> {
  if (!process.env["SUPABASE_SERVICE_ROLE_KEY"]) return link;
  try {
    const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
    for (const type of ["invite", "magiclink"] as const) {
      const generated = await supabaseAdmin.auth.admin.generateLink({
        type,
        email,
        options: { redirectTo: link },
      });
      if (generated.error) continue;
      const properties = generated.data.properties;
      return properties?.action_link && redirectKeepsInvitation(properties.redirect_to, link)
        ? properties.action_link
        : link;
    }
  } catch {
    /* the admin client could not be built or reached; the plain link still works */
  }
  return link;
}

/* -------------------------------------------------------------------------- */
/* The browser's side.                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Invite, email, and hand back what the screen needs.
 *
 * A refusal throws an ErpError, as callErp does, so friendlyError() reads it
 * the same way. If the server function itself cannot be reached — a host
 * missing its Supabase variables, an old deployment — the door is called
 * directly instead, which is what the screen did before email existed: the
 * invitation is still made and its link is still offered, and the reason it
 * was not emailed says what went wrong.
 */
export async function requestInvitation(request: InvitationRequest): Promise<InvitationSent> {
  const session = supabase ? (await supabase.auth.getSession()).data.session : null;

  let result: InvitationResult;
  try {
    result = await sendInvitation({
      data: request,
      headers: session ? { Authorization: `Bearer ${session.access_token}` } : {},
    });
  } catch (error) {
    return inviteWithoutEmail(request, error);
  }

  if (!result.ok) throw new ErpError(result.error, { code: result.code ?? undefined });
  return { ...result, link: absolute(result.link) };
}

async function inviteWithoutEmail(
  request: InvitationRequest,
  cause: unknown,
): Promise<InvitationSent> {
  const made =
    request.kind === "organisation"
      ? await callErp<Invited>("erp_invite_principal", {
          p_email: request.email.trim(),
          p_display_name: request.displayName.trim(),
        })
      : await callErp<Invited>("erp_platform_invite_admin", {
          p_tenant_id: request.tenantId,
          p_email: request.email.trim(),
          p_display_name: request.displayName.trim(),
        });
  const token = String(made.token ?? "");
  if (!token) throw new ErpError("The invitation was not created.", {});
  const why = oneLine(cause instanceof Error ? cause.message : String(cause), 160);
  return sent(
    made.email || request.email.trim(),
    absolute(joinLink("", token)),
    token,
    `The email service for this site could not be reached${why ? ` (${why})` : ""}`,
  );
}

/** A link built without an origin is completed from the page it is shown on. */
function absolute(link: string): string {
  if (typeof window === "undefined" || !link.startsWith("/")) return link;
  return `${window.location.origin}${link}`;
}
