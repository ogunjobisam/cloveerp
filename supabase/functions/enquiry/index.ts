/**
 * The contact form's ingress.
 *
 * A visitor to cloveerp.com is not authenticated and must not become a way
 * into the product. erp.assert_public_api_safe() refuses any public.erp_*
 * function executable by anon — absolutely, with no exemption register — and
 * that refusal is the reason this file exists rather than a public door: the
 * function is the boundary, it holds the connection, and everything it calls
 * lives in erp_meta where anon could never reach. The connection it holds is
 * postgres, so it reduces itself to clove_enquiry before every statement — see
 * INGRESS_ROLE.
 *
 * It does two things and reports both honestly:
 *
 *   1. Stores the enquiry, through erp.record_enquiry(), which is what refuses
 *      a nameless sender, an address nobody could reply to, a message nobody
 *      could answer, and a sixth submission from one visitor in an hour. It is
 *      reached through erp_ingress, as clove_enquiry: see INGRESS_ROLE.
 *
 *   2. Emails whoever erp_meta.platform_staff says should hear about it, and
 *      then records either the provider's id for the message or the reason it
 *      did not go. A form that stores a lead and tells nobody is worse than no
 *      form, because the sender has already been told they were heard — so
 *      "notified" is never written unless Resend named the message.
 *
 * Storing and sending are deliberately not one transaction. If the send fails
 * the enquiry is still kept and still visible on the platform console: losing
 * somebody's message because our mail provider was down would be the worse of
 * the two failures by a wide margin.
 *
 * Deploy the migration first. 20260905000000 creates the clove_enquiry role and
 * the erp_ingress schema this file calls; a deploy that lands ahead of it makes
 * every submission a 500, because the role it switches to does not exist yet.
 *
 * Deploy:
 *   supabase functions deploy enquiry
 *   supabase secrets set RESEND_API_KEY=... \
 *                        CLOVEERP_ENQUIRY_FROM='Clove ERP <hello@cloveerp.com>' \
 *                        CLOVEERP_ENQUIRY_IP_SALT=...
 *
 * The connection is not in that list on purpose: SUPABASE_DB_URL is a reserved
 * default present in every project, and CLOVEERP_DATABASE_URL only has to be set
 * to override it.
 *
 * verify_jwt is false for this one function, in supabase/config.toml, because
 * the whole point is a caller with no session. Nothing else about the product
 * opens: the rate limit, the length bounds and the refusals all live in
 * erp.record_enquiry(), on the far side of a connection this file holds and a
 * visitor does not.
 */
import { asRole, connect } from "../../../worker/src/core/db.ts";
import { PermanentSendFailure, sendViaResend } from "../../../worker/src/core/resend.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

const DEFAULT_ORIGINS = ["https://cloveerp.com", "https://www.cloveerp.com"];

/**
 * The role every statement in this file runs as.
 *
 * The connection is postgres, because that is what the platform provides (see
 * databaseUrl). postgres has BYPASSRLS and can execute all 781 routines in erp,
 * so a public form holding it unmodified is the project's widest privilege
 * sitting behind its most exposed door. Nothing had gone wrong; it was simply
 * more authority than the work needs.
 *
 * 20260905000000 gives the work its own role and its own schema. clove_enquiry
 * holds USAGE on erp_ingress and on nothing else, and EXECUTE on the four
 * wrappers there and nothing else — proven in that migration rather than
 * asserted here, by counting what the role can reach and refusing any number but
 * four. So inside asRole(), erp.record_enquiry is not merely forbidden, it is
 * unnameable: "permission denied for schema erp".
 *
 * The switch is honest about what it is. Code holding a postgres connection can
 * always RESET ROLE, so this reduces what the code does, not what it could do.
 * The wall version is one step further and needs no change here: give
 * clove_enquiry LOGIN and a password, set CLOVEERP_DATABASE_URL to it, and the
 * switch becomes a no-op onto the role the connection already is.
 */
const INGRESS_ROLE = "clove_enquiry";

/**
 * Refuse to start half-configured, the same way worker/src/core/config.ts does.
 *
 * A contact form that quietly stops emailing looks exactly like one nobody has
 * used, which is the failure this whole feature is built to avoid. Missing
 * configuration is a 500 that names the variable, not a silent degradation.
 */
function required(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.trim().length === 0) {
    throw new Error(`${name} is not set, so an enquiry could be stored and nobody told`);
  }
  return v.trim();
}

/**
 * The connection, without anybody copying a database password into a secret.
 *
 * SUPABASE_DB_URL is the project's own postgres connection, injected into every
 * Edge Function by the platform as a reserved default. It cannot point at the
 * wrong project and it cannot go stale, and nobody has to move a password by
 * hand — a step that failed three times running here before anybody noticed the
 * secret had simply never saved.
 *
 * It is also the most privileged connection the project has, which is why every
 * statement below runs inside asRole(): see INGRESS_ROLE.
 *
 * CLOVEERP_DATABASE_URL still wins when set, so an explicit override — a
 * different host, a pooler, or clove_enquiry itself once it has been given LOGIN
 * and a password — remains possible with no change to this file.
 *
 * Refusing to start half-configured is unchanged: this throws naming both names
 * when there is genuinely nothing to connect with.
 */
function databaseUrl(): string {
  const explicit = Deno.env.get("CLOVEERP_DATABASE_URL")?.trim();
  if (explicit) return explicit;
  const provided = Deno.env.get("SUPABASE_DB_URL")?.trim();
  if (provided) return provided;
  throw new Error(
    "neither CLOVEERP_DATABASE_URL nor SUPABASE_DB_URL is set, so an enquiry " +
      "could be stored and nobody told",
  );
}

type Body = {
  full_name?: unknown;
  email?: unknown;
  organisation?: unknown;
  message?: unknown;
  source_page?: unknown;
  /** The honeypot. A person never sees this field, so a person never fills it. */
  company_website?: unknown;
};

function text(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length === 0 ? null : t.slice(0, max);
}

function allowedOrigin(req: Request): string | null {
  const configured = Deno.env.get("CLOVEERP_ENQUIRY_ORIGINS");
  const allowed = configured
    ? configured
        .split(",")
        .map((s: string) => s.trim())
        .filter(Boolean)
    : DEFAULT_ORIGINS;
  const origin = req.headers.get("origin");
  if (origin && allowed.includes(origin)) return origin;
  return allowed[0] ?? null;
}

function cors(req: Request): Record<string, string> {
  const origin = allowedOrigin(req);
  return {
    "access-control-allow-origin": origin ?? "https://cloveerp.com",
    // apikey and authorization, not just content-type.
    //
    // The page sends an `apikey` header whenever VITE_SUPABASE_PUBLISHABLE_KEY
    // is defined at build time (src/routes/contact.tsx), and it is. A header
    // the preflight does not allow makes the browser reject the whole request
    // before it is ever sent — so the form showed "We could not reach the
    // server" while the function sat there working, and nothing reached the
    // logs to say why. The two halves were written separately and this pair
    // never met a browser: the suite exercises erp.record_enquiry(), which is
    // reached over a database connection with no CORS in sight.
    //
    // authorization is allowed for the same reason before it bites: Supabase
    // clients and the gateway attach one by habit, and verify_jwt = false
    // means this function ignores it rather than needing it.
    "access-control-allow-headers": "content-type, apikey, authorization",
    "access-control-allow-methods": "POST, OPTIONS",
    // A preflight per submission is a round trip nobody needs.
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

function reply(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...cors(req) },
  });
}

/**
 * A salted digest of the caller's address, never the address.
 *
 * The only question this has to answer is "has this same visitor just sent
 * forty", and a digest answers it exactly as well as an IP would while being
 * useless to anybody who later reads the table. The salt is required rather
 * than defaulted: an unsalted hash of an IPv4 address is reversible by anyone
 * with an afternoon, so a default would be a privacy claim the code could not
 * keep.
 */
async function hashAddress(req: Request, salt: string): Promise<string | null> {
  const forwarded = req.headers.get("x-forwarded-for");
  const address = forwarded?.split(",")[0]?.trim() || req.headers.get("cf-connecting-ip");
  if (!address) return null;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${salt}:${address}`),
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * What the owner reads in their inbox, as text.
 *
 * Sent alongside the HTML rather than instead of it. A message with no text
 * part reads as blank to anyone whose client does not render HTML, and counts
 * against the sender with every spam filter besides — so this stays the whole
 * message, not a line telling somebody to open it elsewhere.
 */
function compose(e: {
  fullName: string;
  email: string;
  organisation: string | null;
  message: string;
  sourcePage: string | null;
}): string {
  return [
    `${e.fullName} <${e.email}> got in touch through cloveerp.com.`,
    e.organisation ? `Organisation: ${e.organisation}` : null,
    e.sourcePage ? `Page: ${e.sourcePage}` : null,
    "",
    e.message,
    "",
    "— Reply directly to this message and it goes to them.",
  ]
    .filter((l) => l !== null)
    .join("\n");
}

/**
 * Everything a visitor typed is attacker-controlled, so nothing reaches the
 * markup unescaped.
 *
 * The name, the organisation and the message are whatever was posted to a form
 * on the open internet. erp.record_enquiry() bounds their length and refuses an
 * address that is not an address; it does not, and should not, care whether
 * they contain angle brackets. This is the only place that has to.
 *
 * Ampersand first, or the escapes escape each other. Quotes as well as brackets
 * because some of these land in attribute values.
 */
function escapeHtml(v: string): string {
  return v
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/**
 * A mailto: that survives an apostrophe.
 *
 * Two encodings, in this order, because there are two readers: the URL is
 * percent-encoded so a mail client parses the address it was given, and the
 * result is HTML-escaped so the attribute closes where it should. Skipping the
 * second is how an href becomes a way into the document.
 */
function mailto(address: string, subject: string): string {
  // %40 back to @, and only that. RFC 6068's grammar has the address as
  // local-part "@" domain, so the separator is literal there and a client is
  // entitled to read an encoded one as part of the local part. Everything else
  // encodeURIComponent touched stays encoded.
  const to = encodeURIComponent(address).replaceAll("%40", "@");
  return escapeHtml(`mailto:${to}?subject=${encodeURIComponent(subject)}`);
}

/**
 * The message, as paragraphs, with every line the sender typed still where they
 * put it.
 *
 * A blank line starts a paragraph and a single newline is a break, which is how
 * people write and not how HTML collapses whitespace. \r\n first so a Windows
 * browser's line endings do not each become two.
 */
function paragraphs(message: string): string {
  return escapeHtml(message)
    .replaceAll("\r\n", "\n")
    .split(/\n{2,}/)
    .map(
      (block) =>
        `<p style="margin:0 0 14px;color:${INK};font-size:15px;line-height:1.6;word-break:break-word;">` +
        block.replaceAll("\n", "<br />") +
        `</p>`,
    )
    .join("");
}

// The site's palette, as hex.
//
// src/styles.css defines these in oklch, which Outlook, Gmail's web client and
// most of what reads mail on a phone do not understand — an unparsed colour is
// not a fallback, it is black text on a transparent background. Converted once,
// here, so the email is recognisably the same product as the page the enquiry
// came from.
const BRAND = "#36312B"; // --brand
const SURFACE = "#F6F4F0"; // --surface
const CARD = "#FEFDFA"; // --card-surface
const SOFT = "#E9E6DE"; // --soft
const LINE = "#DCD7CE"; // --line
const INK = "#403B36"; // --ink
const MUTED = "#67625D"; // --ink-muted
const ACCENT = "#A2591E"; // --accent

/** One row of the detail table, or nothing when there is nothing to say. */
function detail(label: string, value: string | null, href?: string): string {
  if (!value) return "";
  const shown = escapeHtml(value);
  return (
    `<tr>` +
    `<td style="padding:0 0 8px;width:112px;vertical-align:top;color:${MUTED};` +
    `font-size:13px;line-height:1.5;">${escapeHtml(label)}</td>` +
    `<td style="padding:0 0 8px;vertical-align:top;color:${INK};font-size:14px;line-height:1.5;word-break:break-word;">` +
    (href ? `<a href="${href}" style="color:${ACCENT};text-decoration:none;">${shown}</a>` : shown) +
    `</td></tr>`
  );
}

/**
 * The same enquiry, laid out.
 *
 * Tables and inline styles, because that is what mail clients render: Outlook
 * on Windows uses Word to lay out HTML, and Gmail strips <style> blocks in
 * several of its clients. Nothing is fetched from anywhere — no image, no font,
 * no stylesheet — so it renders the same with remote content blocked, which is
 * the default for a first message from an unknown sender.
 *
 * One 600px column, one accent, and the message given the most room. What the
 * reader needs is who wrote, what they said, and one obvious way to answer.
 */
function composeHtml(e: {
  fullName: string;
  email: string;
  organisation: string | null;
  message: string;
  sourcePage: string | null;
  receivedAt: Date;
}): string {
  const received = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    dateStyle: "full",
    timeStyle: "short",
  }).format(e.receivedAt);
  const replyHref = mailto(e.email, `Re: your enquiry to Clove ERP`);
  // A first name on the button, when there is one short enough to read as a
  // name. A form field takes whatever somebody types, and "Reply to
  // Wolfeschlegelsteinhausenbergerdorff" wraps a button onto three lines.
  const firstName = e.fullName.split(/\s+/)[0] ?? e.fullName;
  const replyLabel = firstName.length > 0 && firstName.length <= 18
    ? `Reply to ${firstName}`
    : "Reply";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="light" />
<title>Enquiry from ${escapeHtml(e.fullName)}</title>
</head>
<body style="margin:0;padding:0;background:${SURFACE};">
<!-- The preview line, which every inbox shows next to the subject. Left to
     chance it is whatever text comes first, which would be the sender's own
     name repeated. -->
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:${SURFACE};font-size:1px;line-height:1px;">
${escapeHtml(e.message.slice(0, 140))}
</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${SURFACE};">
<tr><td align="center" style="padding:32px 16px;">
  <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background:${CARD};border:1px solid ${LINE};border-radius:14px;">

    <tr><td style="padding:20px 28px;background:${BRAND};border-radius:14px 14px 0 0;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
        <td style="color:#FFFFFF;font-family:Georgia,'Times New Roman',serif;font-size:18px;letter-spacing:0.02em;">Clove&nbsp;ERP</td>
        <td align="right" style="color:#C9C2B8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;text-transform:uppercase;letter-spacing:0.12em;">New enquiry</td>
      </tr></table>
    </td></tr>

    <tr><td style="padding:28px 28px 4px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
      <h1 style="margin:0 0 4px;color:${INK};font-size:21px;line-height:1.3;font-weight:600;word-break:break-word;">${escapeHtml(e.fullName)} got in touch</h1>
      <p style="margin:0 0 20px;color:${MUTED};font-size:13px;line-height:1.5;">${escapeHtml(received)}</p>

      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        ${detail("Email", e.email, mailto(e.email, "Re: your enquiry to Clove ERP"))}
        ${detail("Organisation", e.organisation)}
        ${detail("Page", e.sourcePage)}
      </table>
    </td></tr>

    <tr><td style="padding:20px 28px 4px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${SURFACE};border-left:3px solid ${ACCENT};border-radius:0 8px 8px 0;">
        <tr><td style="padding:18px 20px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          ${paragraphs(e.message)}
        </td></tr>
      </table>
    </td></tr>

    <tr><td style="padding:20px 28px 28px;">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
        <td style="background:${BRAND};border-radius:8px;">
          <a href="${replyHref}" style="display:inline-block;padding:12px 22px;color:#FFFFFF;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:14px;font-weight:600;text-decoration:none;">${escapeHtml(replyLabel)}</a>
        </td>
      </tr></table>
      <p style="margin:12px 0 0;color:${MUTED};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;line-height:1.5;">Replying to this message goes straight to them.</p>
    </td></tr>

    <tr><td style="padding:16px 28px;border-top:1px solid ${SOFT};border-radius:0 0 14px 14px;">
      <p style="margin:0;color:${MUTED};font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;">
        Sent by the contact form on cloveerp.com. The enquiry is stored on the platform console whether or not this message arrived.
      </p>
    </td></tr>

  </table>
</td></tr>
</table>
</body>
</html>`;
}

/**
 * CLOVEERP_* refusals are written to be read by the person who tripped them, so
 * they are passed through rather than replaced with something vaguer. Anything
 * else is ours and the visitor is told nothing about our internals.
 */
function refusal(message: string): { field: string | null; message: string } | null {
  // Both prefixes for one release, and digits in the class. 20260904980000
  // moved the prefix from ERPWARE_ to CLOVEERP_, and this function and the
  // database it calls are deployed separately and by hand — so whichever goes
  // first is briefly ahead of the other, and a single spelling would hand the
  // visitor "something went wrong" for a refusal that names its own field.
  const m = /^((?:CLOVEERP|ERPWARE)_[A-Z0-9_]+): (.*)$/s.exec(message);
  if (!m) return null;
  const token = m[1].replace(/^ERPWARE_/, "CLOVEERP_");
  const field =
    token === "CLOVEERP_ENQUIRY_NAME_REQUIRED"
      ? "full_name"
      : token === "CLOVEERP_ENQUIRY_EMAIL_INVALID"
        ? "email"
        : token === "CLOVEERP_ENQUIRY_MESSAGE_TOO_SHORT"
          ? "message"
          : null;
  return { field, message: m[2].split("\n")[0] };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "post an enquiry" });

  let sql;
  try {
    const connection = databaseUrl();
    const apiKey = required("RESEND_API_KEY");
    const from = required("CLOVEERP_ENQUIRY_FROM");
    const salt = required("CLOVEERP_ENQUIRY_IP_SALT");

    let body: Body;
    try {
      body = (await req.json()) as Body;
    } catch {
      return reply(req, 400, { error: "that was not JSON" });
    }

    // Refused rather than accepted-and-discarded. A form that answers "thank
    // you" and files nothing is the same lie as one that stores and never
    // sends; a person never reaches this branch, and a bot is owed nothing.
    if (text(body.company_website, 200) !== null) {
      return reply(req, 400, { error: "that submission looked automated" });
    }

    const fullName = text(body.full_name, 120);
    const email = text(body.email, 254);
    const message = text(body.message, 4000);
    const organisation = text(body.organisation, 160);
    const sourcePage = text(body.source_page, 200);

    if (!fullName || !email || !message) {
      return reply(req, 400, {
        error: "a name, an address and a message are all needed",
        field: !fullName ? "full_name" : !email ? "email" : "message",
      });
    }

    const ipHash = await hashAddress(req, salt);
    sql = connect(connection);

    let id: string;
    try {
      const rows = await asRole(
        sql,
        INGRESS_ROLE,
        (tx) =>
          tx`
        select erp_ingress.record_enquiry(
          ${fullName}, ${email}, ${message},
          ${organisation}, ${sourcePage}, ${ipHash},
          ${text(req.headers.get("user-agent"), 300)}
        ) as id` as unknown as Promise<Array<{ id: string }>>,
      );
      id = rows[0].id;
    } catch (err) {
      const known = refusal((err as Error).message);
      if (known) return reply(req, 400, { error: known.message, field: known.field });
      throw err;
    }

    // Stored. From here the enquiry exists whatever happens to the mail, and
    // the response says which of the two we managed.
    const recipients = await asRole(
      sql,
      INGRESS_ROLE,
      (tx) =>
        tx`select email from erp_ingress.enquiry_recipients()` as unknown as Promise<
          Array<{ email: string }>
        >,
    );

    if (recipients.length === 0) {
      await asRole(
        sql,
        INGRESS_ROLE,
        (tx) =>
          tx`select erp_ingress.fail_enquiry_notice(${id}::uuid,
        ${"erp_meta.platform_staff names nobody to tell"})`,
      );
      return reply(req, 200, { id, stored: true, notified: false });
    }

    const subject = `Enquiry from ${fullName}${organisation ? ` (${organisation})` : ""}`;
    const enquiry = { fullName, email, organisation, message, sourcePage };
    const composed = compose(enquiry);
    const rendered = composeHtml({ ...enquiry, receivedAt: new Date() });
    const ids: string[] = [];
    let failure: string | null = null;

    for (const r of recipients) {
      try {
        ids.push(
          await sendViaResend(apiKey, {
            id,
            to_address: r.email,
            subject,
            body: composed,
            html: rendered,
            from_address: from,
            // So answering the lead is one keystroke rather than a copy and paste.
            reply_to: email,
          }),
        );
      } catch (err) {
        const permanent = err instanceof PermanentSendFailure;
        failure = `${permanent ? "permanent" : "transient"} failure for ${r.email}: ${
          (err as Error).message
        }`;
        break;
      }
    }

    // Notified only when every recipient took it. Understating is safe;
    // overstating is the fault this feature was built around.
    if (failure === null) {
      await asRole(
        sql,
        INGRESS_ROLE,
        (tx) => tx`select erp_ingress.complete_enquiry_notice(${id}::uuid, ${ids.join(",")})`,
      );
      return reply(req, 200, { id, stored: true, notified: true });
    }

    await asRole(
      sql,
      INGRESS_ROLE,
      (tx) => tx`select erp_ingress.fail_enquiry_notice(${id}::uuid, ${failure})`,
    );
    return reply(req, 200, { id, stored: true, notified: false });
  } catch (err) {
    // 500 and nothing about our internals. The enquirer is told to use the
    // address in the footer, which is the one route that does not depend on
    // anything here working.
    console.error(err);
    return reply(req, 500, { error: "the form could not be submitted just now" });
  } finally {
    await sql?.end({ timeout: 5 });
  }
});
