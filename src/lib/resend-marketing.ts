/**
 * The follow-up list, for the people who asked to be on it.
 *
 * A visitor who ticks the box on /contact is asking for founding-customer
 * email from us, which is a different thing from the enquiry itself. The
 * enquiry is stored by erp.record_enquiry() and the owners are told; this file
 * does the one extra thing, and only when the box was ticked:
 *
 *   1. Create or update the contact in Resend, with the custom properties the
 *      account already defines (company_name, business_type, current_system,
 *      signup_source).
 *   2. Add that contact to the founding-customer segment.
 *   3. Send the "clove.demo_requested" event, which is what a Resend
 *      automation listens for.
 *
 * Every one of those is best effort. Resend being slow or down must never
 * change what the form tells somebody about their enquiry — the enquiry is the
 * thing that matters and it is already stored by the time this runs. So
 * nothing here throws: it returns the reason it stopped, the caller logs it,
 * and the response is unchanged.
 *
 * fetch arrives as an option so the sequence can be proved without a key and
 * without the network.
 */

/** "Clove – Founding list". */
export const FOUNDING_SEGMENT_ID = "302811c0-cf1e-4045-bb57-b38595d0104e";

/** Where the sign-up came from, recorded on the contact as a property. */
export const SIGNUP_SOURCE = "cloveerp.com contact form";

/** The event a Resend automation listens for. */
export const DEMO_REQUESTED_EVENT = "clove.demo_requested";

/** Short on purpose: a contact form must not wait on a marketing API. */
export const DEFAULT_TIMEOUT_MS = 5000;

const DEFAULT_BASE_URL = "https://api.resend.com";

export type FollowUpSignup = {
  email: string;
  fullName: string;
  organisation: string | null;
  businessType: string | null;
  currentSystem: string | null;
};

export type FollowUpOptions = {
  fetch?: typeof fetch;
  baseUrl?: string;
  timeoutMs?: number;
};

export type FollowUpOutcome = {
  /** True only when the contact, the segment and the event all went through. */
  ok: boolean;
  /** Why it stopped, for a log line. Never shown to the visitor. */
  failure: string | null;
};

/**
 * A first and last name out of whatever somebody typed into one box.
 *
 * One word is a first name with no last name, rather than a last name or a
 * duplicated one: "Hi Dana" reads correctly and "Hi " does not.
 */
export function splitName(fullName: string): { firstName: string; lastName: string } {
  const parts = fullName.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { firstName: "", lastName: "" };
  if (parts.length === 1) return { firstName: parts[0] as string, lastName: "" };
  return { firstName: parts[0] as string, lastName: parts.slice(1).join(" ") };
}

/** The four custom properties the Resend account already defines. */
export function contactProperties(signup: FollowUpSignup): Record<string, string> {
  return {
    company_name: signup.organisation ?? "",
    business_type: signup.businessType ?? "",
    current_system: signup.currentSystem ?? "",
    signup_source: SIGNUP_SOURCE,
  };
}

async function post(
  doFetch: typeof fetch,
  url: string,
  apiKey: string,
  body: unknown,
  timeoutMs: number,
): Promise<{ status: number; json: Record<string, unknown> }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await doFetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    let json: Record<string, unknown> = {};
    try {
      json = (await response.json()) as Record<string, unknown>;
    } catch {
      json = {};
    }
    return { status: response.status, json };
  } finally {
    clearTimeout(timer);
  }
}

function problem(step: string, status: number, json: Record<string, unknown>): string {
  const message = typeof json["message"] === "string" ? json["message"] : "";
  return `${step} failed (${status})${message ? `: ${message}` : ""}`;
}

/**
 * The three calls, in order, stopping at the first that does not work.
 *
 * Never throws. The caller logs `failure` and carries on.
 */
export async function subscribeToFollowUps(
  apiKey: string,
  signup: FollowUpSignup,
  options: FollowUpOptions = {},
): Promise<FollowUpOutcome> {
  const doFetch = options.fetch ?? fetch;
  const base = (options.baseUrl ?? DEFAULT_BASE_URL).replace(/\/$/, "");
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const { firstName, lastName } = splitName(signup.fullName);
  const properties = contactProperties(signup);

  try {
    const created = await post(
      doFetch,
      `${base}/contacts`,
      apiKey,
      {
        email: signup.email,
        first_name: firstName,
        last_name: lastName,
        unsubscribed: false,
        properties,
      },
      timeoutMs,
    );
    if (created.status >= 300) {
      return { ok: false, failure: problem("resend contact", created.status, created.json) };
    }

    // The segment can be addressed by contact id or by email; the id is what
    // the create call just handed back, and the address is the fallback when a
    // future response shape stops carrying one.
    const contactRef =
      typeof created.json["id"] === "string" && created.json["id"].length > 0
        ? (created.json["id"] as string)
        : signup.email;

    const segmented = await post(
      doFetch,
      `${base}/contacts/${encodeURIComponent(contactRef)}/segments/${FOUNDING_SEGMENT_ID}`,
      apiKey,
      {},
      timeoutMs,
    );
    if (segmented.status >= 300) {
      return { ok: false, failure: problem("resend segment", segmented.status, segmented.json) };
    }

    const event = await post(
      doFetch,
      `${base}/events/send`,
      apiKey,
      {
        event: DEMO_REQUESTED_EVENT,
        email: signup.email,
        payload: properties,
      },
      timeoutMs,
    );
    if (event.status >= 300) {
      return { ok: false, failure: problem("resend event", event.status, event.json) };
    }

    return { ok: true, failure: null };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return { ok: false, failure: `resend follow-up did not complete: ${reason}` };
  }
}
