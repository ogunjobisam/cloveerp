/**
 * The contact form's ingress.
 *
 * A visitor to cloveerp.com is not authenticated and must not become a way
 * into the product. erp.assert_public_api_safe() refuses any public.erp_*
 * function executable by anon — absolutely, with no exemption register — and
 * that refusal is the reason this file exists rather than a public door: the
 * function is the boundary, it holds the connection, and everything it calls
 * lives in erp/erp_meta where anon could never reach.
 *
 * It does two things and reports both honestly:
 *
 *   1. Stores the enquiry, through erp.record_enquiry(), which is what refuses
 *      a nameless sender, an address nobody could reply to, a message nobody
 *      could answer, and a sixth submission from one visitor in an hour.
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
import { connect } from "../../../worker/src/core/db.ts";
import { PermanentSendFailure, sendViaResend } from "../../../worker/src/core/resend.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

const DEFAULT_ORIGINS = ["https://cloveerp.com", "https://www.cloveerp.com"];

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
 * erp.record_enquiry() and the three routines around it are SECURITY INVOKER with
 * ACL postgres=X/postgres — only the postgres role may execute them. So this
 * function needs the project's own postgres connection string, and asking a person
 * to paste one into a secret is asking them to move a password by hand. That step
 * failed three times running before anybody noticed the secret had simply never
 * saved.
 *
 * SUPABASE_DB_URL is that exact connection, injected into every Edge Function by
 * the platform as a reserved default. It cannot point at the wrong project and it
 * cannot go stale. CLOVEERP_DATABASE_URL still wins when set, so an explicit
 * override — a different host, a pooler, a narrower role once these routines are
 * granted to one — remains possible.
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

/** What the owner reads in their inbox. Plain text: it is a lead, not a leaflet. */
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
      const rows = (await sql`
        select erp.record_enquiry(
          ${fullName}, ${email}, ${message},
          ${organisation}, ${sourcePage}, ${ipHash},
          ${text(req.headers.get("user-agent"), 300)}
        ) as id`) as unknown as Array<{ id: string }>;
      id = rows[0].id;
    } catch (err) {
      const known = refusal((err as Error).message);
      if (known) return reply(req, 400, { error: known.message, field: known.field });
      throw err;
    }

    // Stored. From here the enquiry exists whatever happens to the mail, and
    // the response says which of the two we managed.
    const recipients = (await sql`
      select email from erp.enquiry_recipients()`) as unknown as Array<{ email: string }>;

    if (recipients.length === 0) {
      await sql`select erp.fail_enquiry_notice(${id}::uuid,
        ${"erp_meta.platform_staff names nobody to tell"})`;
      return reply(req, 200, { id, stored: true, notified: false });
    }

    const subject = `Enquiry from ${fullName}${organisation ? ` (${organisation})` : ""}`;
    const composed = compose({ fullName, email, organisation, message, sourcePage });
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
      await sql`select erp.complete_enquiry_notice(${id}::uuid, ${ids.join(",")})`;
      return reply(req, 200, { id, stored: true, notified: true });
    }

    await sql`select erp.fail_enquiry_notice(${id}::uuid, ${failure})`;
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
