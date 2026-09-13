/**
 * Inviting somebody, and telling them.
 *
 * Until this existed an invitation was a token handed back to whoever made it,
 * and the organisation's own screen threw even that away: the person invited
 * was never told. The doors still make the invitation — this file adds the
 * email, and nothing else.
 *
 * Two requests, and the second needs no session.
 *
 *   { door, args }   A signed-in person makes an invitation through one of the
 *                    three doors in src/lib/invitation-email.ts. The door is
 *                    called AS THAT PERSON, through PostgREST with their own
 *                    bearer token, so erp.authorise(), erp_meta.require_platform()
 *                    and row security decide exactly as they do from any screen;
 *                    this file widens nothing. Only after the door has said yes
 *                    does it do what the caller could not: ask the database
 *                    whether this organisation may send another invitation
 *                    now, ask Supabase Auth for a one-time sign-in link to the
 *                    address the door accepted, and post the email through
 *                    Resend.
 *
 *   { resend_token } The page an invitation opens (/join) asks for a new
 *                    sign-in link when the one in the email has expired, or
 *                    when it was opened from a copied link that never had one.
 *                    erp.invitation_for_resend() answers only for an invitation
 *                    still open, and the link goes to the invited address and
 *                    nowhere else — never back in the response, which says
 *                    { sent } and nothing about whether the token was good.
 *
 * How often. Anybody with a Google account can create an organisation and
 * invite from it, so the sender is the verified cloveerp.com address in the
 * hands of whoever asks, and the Resend key is the one every other email Clove
 * sends depends on. erp.invitation_send_allowance() says whether a send may go —
 * a gap between one person's invitations and between their sign-in links, a
 * most for the links, and an hourly and a daily cap for the organisation, tighter
 * for one that is not live or is new; the figures live there. It is asked over
 * this function's own connection, after the invitation exists and before any
 * link is made, and erp.note_invitation_link_sent() records each send it
 * allowed. A refusal is not a failure of the invitation: the inviter is told why
 * and given the join link to copy, and a resend answers { sent: false } as for
 * any other reason. The per-isolate gap below stays as a first filter in front
 * of the database.
 *
 * A password nobody holds. An 'invite' link can be issued for an account
 * somebody registered with a password and never confirmed; following the link
 * confirms that account and keeps the password, so whoever typed it would sign
 * in as the person invited. So the moment Supabase Auth makes an invite link,
 * the account's password is replaced with a random one nobody is told, and if
 * that cannot be done the link is not sent.
 *
 * What never leaves this file: the sign-in link, its hashed token and OTP, the
 * service key and the Resend key. None is logged and none is returned. The
 * sign-in link in particular signs somebody in as the invited person, so the
 * inviter gets the plain join link (the token only) to copy, and the email
 * gets the one with the sign-in part.
 *
 * An invitation that exists is never reported as a failure. Once the door has
 * returned, everything after it — the names, the link, the send — ends in a
 * 200 that says emailed: false and why, because each door call supersedes the
 * token before it, and a screen told "failed" would invite again.
 *
 * Deploy: declared in supabase/config.toml, so the GitHub integration deploys
 * it with the others. verify_jwt is false there on purpose: the resend request
 * comes from a person with no session, and the invite request is checked here
 * against Supabase Auth, which is a stronger test than the gateway's (the anon
 * key is a valid JWT and would pass it).
 *
 * Configuration, and what each costs when missing:
 *   SUPABASE_URL, SUPABASE_ANON_KEY (or SUPABASE_PUBLISHABLE_KEYS.default),
 *   SUPABASE_SERVICE_ROLE_KEY (or SUPABASE_SECRET_KEYS.default)
 *       injected into every Edge Function. Read before any door is called: a
 *       function that cannot make a sign-in link refuses rather than making an
 *       invitation it cannot deliver.
 *   SUPABASE_DB_URL (or CLOVEERP_DATABASE_URL)
 *       injected; the send allowance, the record of a link sent and a resend's
 *       lookup are all trusted-only. Read before any door is called, like the
 *       keys: without it nothing could say whether an email may go.
 *   RESEND_API_KEY
 *       without it the invitation is still made, and the screen says it was
 *       not emailed and offers the link to copy.
 *   CLOVEERP_APP_URL      optional, default https://cloveerp.com
 *   CLOVEERP_INVITE_FROM  optional, default Clove ERP <no-reply@cloveerp.com>
 *
 * The imports carry explicit .ts extensions because Deno requires them, and
 * src/lib/invitation-email.ts imports nothing so that Deno can follow it.
 */
import { connect, type Sql } from "../../../worker/src/core/db.ts";
import { sendViaResend } from "../../../worker/src/core/resend.ts";
import {
  INVITE_VALID_DAYS,
  emailArgumentOf,
  invitationEmail,
  invitationFrom,
  isInviteDoor,
  joinLink,
  nameArgumentOf,
  oneLine,
  plausibleInvitationToken,
  refusalStatus,
} from "../../../src/lib/invitation-email.ts";
import type { InviteDoor, Invited } from "../../../src/lib/invitation-email.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

const DEFAULT_APP_URL = "https://cloveerp.com";
const DEFAULT_FROM = "Clove ERP <no-reply@cloveerp.com>";
const DAY_MS = 24 * 60 * 60 * 1000;

/** One new sign-in link per invitation a minute, per isolate: a page, not a pump. */
const RESEND_GAP_MS = 60 * 1000;
const lastResend = new Map<string, number>();

// ─── configuration ──────────────────────────────────────────────────────────

function env(name: string): string | null {
  const value = Deno.env.get(name);
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/** Refuse to start half-configured, naming the variable, as enquiry does. */
function required(name: string): string {
  const value = env(name);
  if (!value) throw new Error(`${name} is not set, so an invitation could be made and nobody told`);
  return value;
}

/**
 * A project key by its legacy name, or the default entry of the JSON map that
 * replaces it. Supabase injects both during the move to the new key format.
 */
function projectKey(legacy: string, map: string): string {
  const direct = env(legacy);
  if (direct) return direct;
  const raw = env(map);
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const value = parsed["default"];
      if (typeof value === "string" && value.trim() !== "") return value.trim();
    } catch {
      /* not JSON; refused below */
    }
  }
  throw new Error(
    `neither ${legacy} nor ${map}.default is set, so an invitation could be made and nobody told`,
  );
}

function databaseUrl(): string {
  const url = env("SUPABASE_DB_URL") ?? env("CLOVEERP_DATABASE_URL");
  if (!url) throw new Error("neither SUPABASE_DB_URL nor CLOVEERP_DATABASE_URL is set");
  return url;
}

/**
 * The site the link opens. Configured rather than read from the request: the
 * Origin header says where a request came from, not where the invited person
 * should go, and a preview origin in an email would outlive the preview.
 */
function appOrigin(): string {
  const configured = env("CLOVEERP_APP_URL");
  if (configured) {
    try {
      return new URL(configured).origin;
    } catch {
      console.error("invite: CLOVEERP_APP_URL is not a URL; using the default");
    }
  }
  return DEFAULT_APP_URL;
}

/** A secret key in the new format is not a JWT, and must not travel as a bearer. */
function serviceHeaders(serviceKey: string): Record<string, string> {
  return serviceKey.startsWith("sb_")
    ? { apikey: serviceKey }
    : { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
}

// ─── replies ────────────────────────────────────────────────────────────────

/**
 * The request's own origin, echoed. The invite request carries its session as
 * a bearer header and never as a cookie, so a page on another origin can do
 * nothing here without a session it could not have; and the resend request is
 * answerable to anybody holding the token by design. The header list is the
 * one supabase-js sends: a header missing from the preflight fails the whole
 * request in the browser before it is sent, and says so nowhere.
 */
function cors(req: Request): Record<string, string> {
  return {
    "access-control-allow-origin": req.headers.get("origin") ?? "*",
    "access-control-allow-headers":
      "authorization, x-client-info, apikey, content-type, x-retry-count, traceparent, tracestate, baggage",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

function reply(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...cors(req) },
  });
}

// ─── the database's say on sending ───────────────────────────────────────────

type Allowance = { allowed: boolean; reason: string | null };

/**
 * Whether one more email may go for this person's invitation, as
 * erp.invitation_send_allowance() decides: 'invite' counts the invitation the
 * door just made, 'resend' the links already sent for it. Anything but an
 * explicit yes is a no.
 */
async function sendAllowance(
  sql: Sql,
  appUserId: string,
  kind: "invite" | "resend",
): Promise<Allowance> {
  const rows = (await sql`
    select allowed, reason
      from erp.invitation_send_allowance(${appUserId}::uuid, ${kind}::text)
  `) as unknown as { allowed: unknown; reason: unknown }[];
  const row = rows[0];
  return { allowed: row?.allowed === true, reason: textOf(row?.reason) };
}

/**
 * The link has gone; the next allowance counts it. The email has already left,
 * so a failure here is logged and nothing more: telling the inviter it was not
 * sent would have them invite again.
 */
async function noteLinkSent(sql: Sql, appUserId: string): Promise<void> {
  try {
    await sql`select erp.note_invitation_link_sent(${appUserId}::uuid)`;
  } catch (err) {
    console.error(
      `invite: a sent link could not be recorded: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

/** Closing the connection is tidying up, and must not turn an answer into a 500. */
async function close(sql: Sql | undefined): Promise<void> {
  try {
    await sql?.end({ timeout: 5 });
  } catch {
    /* the isolate reclaims it */
  }
}

// ─── Supabase, over plain fetch ─────────────────────────────────────────────

function bearerOf(req: Request): string | null {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

/** A real signed-in user, as Supabase Auth says. The anon key is a JWT too, and is not one. */
async function signedIn(url: string, anonKey: string, bearer: string): Promise<boolean> {
  if (bearer === anonKey) return false;
  const response = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: anonKey, authorization: `Bearer ${bearer}` },
  });
  if (response.status >= 500) {
    throw new Error(`auth/v1/user answered ${response.status}`);
  }
  if (!response.ok) {
    await response.body?.cancel();
    return false;
  }
  const user = (await response.json()) as { id?: unknown };
  return typeof user.id === "string" && user.id !== "";
}

type RpcFailure = { code: unknown; message: unknown; hint: unknown };
type RpcResult = { ok: true; data: unknown } | { ok: false; status: number; error: RpcFailure };

/** A public door, called as the person whose bearer this is. */
async function asCaller(
  url: string,
  anonKey: string,
  bearer: string,
  door: string,
  args: Record<string, unknown>,
): Promise<RpcResult> {
  const response = await fetch(`${url}/rest/v1/rpc/${door}`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${bearer}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(args),
  });
  const raw = await response.text();
  let body: unknown = null;
  try {
    body = raw === "" ? null : JSON.parse(raw);
  } catch {
    body = { message: raw.slice(0, 300) };
  }
  if (response.ok) return { ok: true, data: body };
  const failure = (typeof body === "object" && body !== null ? body : {}) as Record<
    string,
    unknown
  >;
  return {
    ok: false,
    status: response.status,
    error: { code: failure["code"], message: failure["message"], hint: failure["hint"] },
  };
}

type SignInLink = { link: string } | { reason: string };

const PASSWORD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/**
 * Sixty-four characters nobody is ever told, with a lower-case letter, a capital
 * and a digit, which is what the project's password rules ask for. Bytes of 248
 * and over are skipped: 248 is the largest multiple of 62 below 256, so every
 * character is equally likely.
 */
function passwordNobodyHolds(): string {
  for (;;) {
    let out = "";
    for (const byte of crypto.getRandomValues(new Uint8Array(128))) {
      if (byte >= 248) continue;
      out += PASSWORD_ALPHABET.charAt(byte % 62);
      if (out.length === 64) break;
    }
    if (out.length === 64 && /[a-z]/.test(out) && /[A-Z]/.test(out) && /[0-9]/.test(out)) {
      return out;
    }
  }
}

/**
 * Replace the password on the account an invite link was just made for.
 *
 * Supabase Auth makes an 'invite' link only for an address with no confirmed
 * account, and nobody can sign in with the password of an unconfirmed one: for
 * a new address this does what Auth would have done when the link was
 * followed, and for one somebody registered earlier and never confirmed it
 * takes away the password they typed. The link just made is untouched. The password is sent once, to
 * Auth, and is never logged or kept.
 */
async function replacePassword(url: string, serviceKey: string, userId: unknown): Promise<boolean> {
  if (typeof userId !== "string" || !/^[0-9A-Fa-f-]{36}$/.test(userId)) return false;
  const response = await fetch(`${url}/auth/v1/admin/users/${userId}`, {
    method: "PUT",
    headers: { ...serviceHeaders(serviceKey), "content-type": "application/json" },
    body: JSON.stringify({ password: passwordNobodyHolds() }),
  });
  await response.body?.cancel();
  if (!response.ok) {
    console.error(`invite: the invited account's password could not be replaced (${response.status})`);
  }
  return response.ok;
}

/**
 * A one-time link that signs the invited address in and lands on /join.
 *
 * 'invite' for an address Supabase Auth has no confirmed account for, whose
 * password is then replaced (replacePassword); 'magiclink' when it already has a
 * confirmed account, which is what email_exists means. Nothing is mailed by
 * Supabase here — generate_link only makes the link — so the one email the
 * person gets is ours.
 */
async function signInLink(
  url: string,
  serviceKey: string,
  email: string,
  redirectTo: string,
): Promise<SignInLink> {
  for (const type of ["invite", "magiclink"] as const) {
    const response = await fetch(
      `${url}/auth/v1/admin/generate_link?redirect_to=${encodeURIComponent(redirectTo)}`,
      {
        method: "POST",
        headers: {
          ...serviceHeaders(serviceKey),
          "content-type": "application/json",
          "x-supabase-api-version": "2024-01-01",
        },
        body: JSON.stringify({ type, email, redirect_to: redirectTo }),
      },
    );
    const raw = await response.text();
    let body: Record<string, unknown> = {};
    try {
      const parsed: unknown = JSON.parse(raw);
      if (typeof parsed === "object" && parsed !== null) body = parsed as Record<string, unknown>;
    } catch {
      /* not JSON; judged by its status below */
    }
    if (response.ok) {
      const action = body["action_link"];
      if (typeof action !== "string" || !/^https?:\/\//.test(action)) {
        return { reason: "Supabase Auth made no sign-in link for this address" };
      }
      // generate_link answers with the account it acted on, id and all.
      if (type === "invite" && !(await replacePassword(url, serviceKey, body["id"]))) {
        return { reason: "The sign-in link could not be made safe to send, so no email went" };
      }
      return { link: action };
    }
    const code = body["code"] ?? body["error_code"];
    if (type === "invite" && (code === "email_exists" || code === "user_already_exists")) continue;
    const said = typeof body["msg"] === "string" ? body["msg"] : body["message"];
    return {
      reason:
        `Supabase Auth would not make a sign-in link for this address (${response.status}` +
        `${typeof said === "string" && said ? `: ${oneLine(said, 160)}` : ""})`,
    };
  }
  return { reason: "Supabase Auth would not make a sign-in link for this address" };
}

/** What the provider said, without the request that carried the key. */
function providerRefusal(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err);
  const detail = /^resend responded (\d+): (.*)$/s.exec(message);
  if (!detail) return oneLine(message, 200);
  try {
    const parsed = JSON.parse(detail[2]) as { message?: unknown };
    if (typeof parsed.message === "string") return `${detail[1]}: ${oneLine(parsed.message, 200)}`;
  } catch {
    /* not JSON; the raw slice is the detail */
  }
  return oneLine(`${detail[1]}: ${detail[2]}`, 200);
}

// ─── who is inviting, into what ─────────────────────────────────────────────

function textOf(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

function fieldOf(record: unknown, name: string): unknown {
  return typeof record === "object" && record !== null && !Array.isArray(record)
    ? (record as Record<string, unknown>)[name]
    : undefined;
}

/**
 * The names the email greets with, read as the caller from doors the desk
 * already reads. Best effort: an email that says "an organisation" is still an
 * invitation, and a failure here must not become a failure of one that exists.
 */
async function namesFor(
  call: (door: string) => Promise<RpcResult>,
  door: InviteDoor,
  args: Record<string, unknown>,
  invited: Invited,
): Promise<{ organisation: string | null; inviter: string | null }> {
  let organisation = invited.organisation;
  let inviter: string | null = null;
  try {
    if (door === "erp_invite_principal") {
      const session = await call("erp_session");
      if (session.ok) {
        organisation = textOf(fieldOf(fieldOf(session.data, "tenant"), "name"));
        inviter = textOf(fieldOf(fieldOf(session.data, "principal"), "display_name"));
      }
      return { organisation, inviter };
    }
    const me = await call("erp_platform_me");
    if (me.ok) inviter = textOf(fieldOf(me.data, "display_name"));
    if (!organisation) {
      const tenants = await call("erp_platform_tenants");
      if (tenants.ok && Array.isArray(tenants.data)) {
        const tenant = tenants.data.find((t) => fieldOf(t, "id") === args["p_tenant_id"]);
        organisation = textOf(fieldOf(tenant, "name"));
      }
    }
  } catch {
    /* the names are a courtesy */
  }
  return { organisation, inviter };
}

// ─── the two requests ───────────────────────────────────────────────────────

async function invite(req: Request, body: Record<string, unknown>): Promise<Response> {
  // Everything a delivery needs, before anything is created.
  const url = required("SUPABASE_URL").replace(/\/+$/, "");
  const anonKey = projectKey("SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEYS");
  const serviceKey = projectKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS");
  const connection = databaseUrl();
  const origin = appOrigin();
  const from = env("CLOVEERP_INVITE_FROM") ?? DEFAULT_FROM;
  const apiKey = env("RESEND_API_KEY");

  const bearer = bearerOf(req);
  if (!bearer || !(await signedIn(url, anonKey, bearer))) {
    return reply(req, 401, { error: "sign in to invite somebody" });
  }

  const door = body["door"];
  const args = body["args"];
  if (!isInviteDoor(door)) {
    return reply(req, 400, { error: "that is not a door this function invites through" });
  }
  if (typeof args !== "object" || args === null || Array.isArray(args)) {
    return reply(req, 400, { error: "the invitation needs its arguments" });
  }
  const given = args as Record<string, unknown>;
  if (typeof given[emailArgumentOf(door)] !== "string") {
    return reply(req, 400, { error: "an email address is required", field: emailArgumentOf(door) });
  }

  // The database decides. Refusals it wrote for a person are passed on in its
  // own words, with the code the desk's friendlyError() reads.
  const called = await asCaller(url, anonKey, bearer, door, given);
  if (!called.ok) {
    const { code, message, hint } = called.error;
    const status = called.status === 401 ? 401 : refusalStatus(code, message);
    if (status === 401) return reply(req, 401, { error: "sign in again to invite somebody" });
    if (status === 403) {
      return reply(req, 403, { error: String(message ?? "permission denied"), code: code ?? null });
    }
    if (status === 400) {
      return reply(req, 400, {
        error: String(message ?? "the invitation was refused"),
        code: code ?? null,
        hint: typeof hint === "string" ? hint : null,
      });
    }
    throw new Error(`${door} answered ${called.status} ${String(code)}: ${String(message)}`);
  }

  const invited = invitationFrom(door, given, called.data);
  if (!invited) throw new Error(`${door} succeeded but returned no invitation`);

  // The invitation exists from here. Every path below is a 200.
  const plain = joinLink(origin, invited.token);
  const notEmailed = (reason: string) =>
    reply(req, 200, {
      app_user_id: invited.appUserId,
      email: invited.email,
      emailed: false,
      reason,
      join_link: plain,
    });

  let sql: Sql | undefined;
  try {
    if (!apiKey) return notEmailed("Email is not set up for this site yet");

    // Before any link exists: a refused send makes no sign-in link and touches
    // no account.
    sql = connect(connection);
    const allowance = await sendAllowance(sql, invited.appUserId, "invite");
    if (!allowance.allowed) {
      return notEmailed(allowance.reason ?? "Too many invitations have been sent just now");
    }

    const names = await namesFor(
      (name) => asCaller(url, anonKey, bearer, name, {}),
      door,
      given,
      invited,
    );
    const link = await signInLink(url, serviceKey, invited.email, `${origin}/join`);
    if ("reason" in link) return notEmailed(link.reason);

    const message = invitationEmail({
      organisation: names.organisation,
      inviter: names.inviter,
      invitee: textOf(given[nameArgumentOf(door)]),
      link: joinLink(origin, invited.token, link.link),
      expiresAt: new Date(Date.now() + INVITE_VALID_DAYS[door] * DAY_MS),
    });

    let providerId: string;
    try {
      providerId = await sendViaResend(apiKey, {
        id: invited.appUserId,
        to_address: invited.email,
        subject: message.subject,
        body: message.text,
        html: message.html,
        from_address: from,
        reply_to: null,
      });
    } catch (err) {
      return notEmailed(`The email service did not take the message (${providerRefusal(err)})`);
    }

    await noteLinkSent(sql, invited.appUserId);
    return reply(req, 200, {
      app_user_id: invited.appUserId,
      email: invited.email,
      emailed: true,
      provider_message_id: providerId,
      join_link: plain,
    });
  } catch (err) {
    console.error(
      `invite: ${door} made an invitation that could not be emailed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    return notEmailed("The email could not be sent just now");
  } finally {
    await close(sql);
  }
}

async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** True when this invitation had a link sent within the last minute; records this one if not. */
async function tooSoon(token: string): Promise<boolean> {
  const key = await digest(token);
  const now = Date.now();
  if (lastResend.size > 1000) {
    for (const [k, at] of lastResend) if (now - at > RESEND_GAP_MS) lastResend.delete(k);
  }
  const last = lastResend.get(key);
  if (last !== undefined && now - last < RESEND_GAP_MS) return true;
  lastResend.set(key, now);
  return false;
}

type ResendRow = {
  app_user_id: string;
  email: string;
  display_name: string | null;
  tenant_name: string | null;
  expires_at: string | Date | null;
};

/**
 * A new sign-in link for an invitation still open.
 *
 * Always { sent }, and the same shape whether the token was never an
 * invitation, has been used, was superseded or has expired: the page needs to
 * know whether to say "check your inbox", and anybody guessing tokens needs to
 * learn nothing. Failures are logged — without the token or the link — because
 * this is the one place nobody else would hear about them.
 */
async function resend(req: Request, token: unknown): Promise<Response> {
  const nothing = () => reply(req, 200, { sent: false });
  if (!plausibleInvitationToken(token)) return nothing();

  let sql: Sql | undefined;
  try {
    const url = required("SUPABASE_URL").replace(/\/+$/, "");
    const serviceKey = projectKey("SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEYS");
    const apiKey = required("RESEND_API_KEY");
    const connection = databaseUrl();
    const origin = appOrigin();
    const from = env("CLOVEERP_INVITE_FROM") ?? DEFAULT_FROM;

    if (await tooSoon(token)) return nothing();

    // The connection is the project's own, which is what erp.session_is_trusted()
    // asks for; the function it reaches answers only for a pending invitation.
    sql = connect(connection);
    const rows = (await sql`
      select app_user_id, email, display_name, tenant_name, expires_at
        from erp.invitation_for_resend(${token}::text)
    `) as unknown as ResendRow[];
    const row = rows[0];
    if (!row || !row.email || !row.app_user_id) return nothing();

    // The database's gap and count, which every isolate shares; the map above
    // is only this isolate's.
    const allowance = await sendAllowance(sql, String(row.app_user_id), "resend");
    if (!allowance.allowed) return nothing();

    const link = await signInLink(url, serviceKey, row.email, `${origin}/join`);
    if ("reason" in link) {
      console.error(`invite: a resend made no sign-in link: ${link.reason}`);
      return nothing();
    }

    const message = invitationEmail({
      organisation: row.tenant_name,
      inviter: null,
      invitee: row.display_name,
      link: joinLink(origin, token, link.link),
      expiresAt: row.expires_at,
      resent: true,
    });
    await sendViaResend(apiKey, {
      id: "resend",
      to_address: row.email,
      subject: message.subject,
      body: message.text,
      html: message.html,
      from_address: from,
      reply_to: null,
    });
    await noteLinkSent(sql, String(row.app_user_id));
    return reply(req, 200, { sent: true });
  } catch (err) {
    console.error(
      `invite: a resend could not be sent: ${err instanceof Error ? err.message : String(err)}`,
    );
    return nothing();
  } finally {
    await close(sql);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "post an invitation" });

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return reply(req, 400, { error: "that was not JSON" });
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return reply(req, 400, { error: "that was not an invitation" });
  }
  const request = body as Record<string, unknown>;

  if ("resend_token" in request) return resend(req, request["resend_token"]);

  try {
    return await invite(req, request);
  } catch (err) {
    // Nothing about our internals goes back. Every path after a door that
    // returned an invitation answers 200, so this is a door that was never
    // reached, failed in a way nobody wrote for a person, or answered in a
    // shape this file cannot read — and the screen may say it failed.
    console.error(err);
    return reply(req, 500, { error: "the invitation could not be sent just now" });
  }
});
