import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import {
  INVITE_DOORS,
  INVITE_VALID_DAYS,
  escapeHtml,
  expiryDate,
  invitationEmail,
  invitationFrom,
  isInviteDoor,
  joinLink,
  oneLine,
  plausibleInvitationToken,
  readJoinArrival,
  refusalStatus,
  verifiedSignInLink,
} from "./invitation-email";

const TOKEN = "a".repeat(64);
const SUPABASE = "https://xpzffnnhnhcqyjqcueja.supabase.co";
const ACTION = `${SUPABASE}/auth/v1/verify?token=pkce_123&type=invite&redirect_to=https://cloveerp.com/join`;

describe("the module both runtimes read", () => {
  const source = readFileSync(new URL("./invitation-email.ts", import.meta.url), "utf8");

  test("imports nothing, so Deno can follow it from the invite function", () => {
    expect(source).not.toMatch(/^\s*import\s/m);
    expect(source).not.toMatch(/\brequire\(/);
  });

  test("reaches for no runtime of its own", () => {
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    for (const global of ["process.", "window.", "Deno.", "import.meta", "document."]) {
      expect(code).not.toContain(global);
    }
  });

  test("names the three doors as literals, which is what app_doors.sh reads", () => {
    for (const door of INVITE_DOORS) expect(source).toContain(`"${door}"`);
    expect(isInviteDoor("erp_invite_principal")).toBe(true);
    expect(isInviteDoor("erp_claim_invitation")).toBe(false);
    expect(isInviteDoor(null)).toBe(false);
  });

  test("states an expiry for every door", () => {
    for (const door of INVITE_DOORS) expect(INVITE_VALID_DAYS[door]).toBeGreaterThan(0);
  });
});

describe("the join link", () => {
  test("carries the token in the fragment, where no server sees it", () => {
    const link = joinLink("https://cloveerp.com", TOKEN);
    expect(link).toBe(`https://cloveerp.com/join#invitation=${TOKEN}`);
    const url = new URL(link);
    expect(url.search).toBe("");
    expect(url.pathname).toBe("/join");
  });

  test("carries the sign-in link encoded, so it cannot add a parameter of its own", () => {
    const link = joinLink("https://cloveerp.com/", TOKEN, `${ACTION}&invitation=evil`);
    expect(link.startsWith(`https://cloveerp.com/join#invitation=${TOKEN}&signin=`)).toBe(true);
    const arrival = readJoinArrival(new URL(link).hash);
    expect(arrival.invitation).toBe(TOKEN);
    expect(arrival.signin).toBe(`${ACTION}&invitation=evil`);
  });

  test("a token with characters in it cannot break out of its parameter", () => {
    const link = joinLink("https://cloveerp.com", "a b&signin=x#y");
    expect(link).toBe("https://cloveerp.com/join#invitation=a%20b%26signin%3Dx%23y");
  });
});

describe("arriving at /join", () => {
  test("reads the token and the sign-in link", () => {
    const arrival = readJoinArrival(`#invitation=${TOKEN}&signin=${encodeURIComponent(ACTION)}`);
    expect(arrival).toEqual({ invitation: TOKEN, signin: ACTION, failure: null });
  });

  test("keeps rubbish out rather than holding it as a token", () => {
    expect(readJoinArrival("#invitation=short").invitation).toBeNull();
    expect(readJoinArrival("#invitation=%3Cscript%3E").invitation).toBeNull();
    expect(readJoinArrival("").invitation).toBeNull();
  });

  test("hears Supabase Auth saying the link expired, in the fragment or the query", () => {
    const hash =
      "#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired";
    expect(readJoinArrival(hash).failure).toBe("Email link is invalid or has expired");
    expect(readJoinArrival("", "?error=access_denied&error_code=otp_expired").failure).toBe(
      "otp_expired",
    );
  });

  test("a session coming back is not a failure and not an invitation", () => {
    const arrival = readJoinArrival("#access_token=x&refresh_token=y&type=invite");
    expect(arrival).toEqual({ invitation: null, signin: null, failure: null });
  });
});

describe("the sign-in link the page will follow", () => {
  test("is this project's own verification endpoint", () => {
    expect(verifiedSignInLink(ACTION, SUPABASE)).toBe(ACTION);
    expect(verifiedSignInLink(ACTION, `${SUPABASE}/`)).toBe(ACTION);
  });

  test("nothing else: another host, a lookalike, another path, a script", () => {
    expect(verifiedSignInLink(ACTION.replace("xpzff", "evil"), SUPABASE)).toBeNull();
    expect(
      verifiedSignInLink(`${SUPABASE}.evil.example/auth/v1/verify?token=x`, SUPABASE),
    ).toBeNull();
    expect(verifiedSignInLink(`${SUPABASE}@evil.example/auth/v1/verify?x`, SUPABASE)).toBeNull();
    expect(verifiedSignInLink(`${SUPABASE}/auth/v1/verify/../admin?x`, SUPABASE)).toBeNull();
    expect(verifiedSignInLink(`${SUPABASE}/auth/v1/user?x`, SUPABASE)).toBeNull();
    expect(verifiedSignInLink("javascript:alert(1)", SUPABASE)).toBeNull();
    expect(verifiedSignInLink(`${ACTION}\n`, SUPABASE)).toBeNull();
    expect(verifiedSignInLink(null, SUPABASE)).toBeNull();
  });
});

describe("what a door handed back", () => {
  test("an organisation's invitation has no email in it, so the argument is used", () => {
    expect(
      invitationFrom(
        "erp_invite_principal",
        { p_email: "  sam@example.com ", p_display_name: "Sam" },
        { app_user_id: "u1", token: TOKEN },
      ),
    ).toEqual({ appUserId: "u1", email: "sam@example.com", token: TOKEN, organisation: null });
  });

  test("the platform's names the address it stored", () => {
    expect(
      invitationFrom(
        "erp_platform_invite_admin",
        { p_email: "Sam@Example.com" },
        { app_user_id: "u2", email: "sam@example.com", token: TOKEN },
      ),
    ).toEqual({ appUserId: "u2", email: "sam@example.com", token: TOKEN, organisation: null });
  });

  test("onboarding names the organisation it created", () => {
    expect(
      invitationFrom(
        "erp_platform_onboard_company",
        { p_admin_email: "ada@acme.example" },
        {
          tenant_id: "t1",
          name: "Acme",
          admin_user_id: "u3",
          admin_email: "ada@acme.example",
          admin_token: TOKEN,
        },
      ),
    ).toEqual({ appUserId: "u3", email: "ada@acme.example", token: TOKEN, organisation: "Acme" });
  });

  test("a result that is not an invitation is null, not a guess", () => {
    expect(invitationFrom("erp_invite_principal", { p_email: "a@b.c" }, null)).toBeNull();
    expect(invitationFrom("erp_invite_principal", { p_email: "a@b.c" }, [TOKEN])).toBeNull();
    expect(
      invitationFrom("erp_invite_principal", {}, { app_user_id: "u1", token: TOKEN }),
    ).toBeNull();
    expect(
      invitationFrom("erp_platform_onboard_company", {}, { app_user_id: "u", token: TOKEN }),
    ).toBeNull();
  });
});

describe("which refusals the caller reads", () => {
  test("the database saying no to this person is 403", () => {
    expect(refusalStatus("42501", "permission denied for function erp_platform_invite_admin")).toBe(
      403,
    );
    expect(refusalStatus("P0001", "CLOVEERP_PERMISSION_DENIED: administration.users")).toBe(403);
    expect(refusalStatus("P0001", "ERPWARE_PERMISSION_DENIED: administration.users")).toBe(403);
  });

  test("a refusal written for a person is 400, with or without words after it", () => {
    expect(refusalStatus("P0001", "CLOVEERP_VALIDATION: an email address is required")).toBe(400);
    expect(refusalStatus("23503", "ERPWARE_UNKNOWN_TENANT")).toBe(400);
    expect(refusalStatus("23505", 'duplicate key value violates unique constraint "x"')).toBe(400);
    expect(refusalStatus("22P02", 'invalid input syntax for type uuid: "nope"')).toBe(400);
  });

  test("anything else is ours to log, not theirs to read", () => {
    expect(refusalStatus("PGRST202", "Could not find the function")).toBeNull();
    expect(refusalStatus("XX000", "internal error")).toBeNull();
    expect(refusalStatus(undefined, undefined)).toBeNull();
    expect(refusalStatus("P0002", "CLOVEERP_C1 without its colon")).toBeNull();
  });
});

describe("the email", () => {
  const link = joinLink("https://cloveerp.com", TOKEN, ACTION);
  const base = {
    organisation: "Northwind Foods",
    inviter: "Ada Lovelace",
    invitee: "Sam",
    link,
    expiresAt: new Date("2026-09-20T16:30:09Z"),
  };

  test("names who invited them, to what, and carries the link in both parts", () => {
    const m = invitationEmail(base);
    expect(m.subject).toBe("Ada Lovelace invited you to join Northwind Foods on Clove ERP");
    expect(m.text).toContain("Hello Sam,");
    expect(m.text).toContain("Ada Lovelace has invited you to join Northwind Foods on Clove ERP.");
    expect(m.text).toContain(link);
    expect(m.html).toContain(`href="${escapeHtml(link)}"`);
  });

  test("says the link works once, when the invitation ends, and what to do if unexpected", () => {
    const m = invitationEmail(base);
    for (const part of [m.text, m.html]) {
      expect(part).toContain("works once");
      expect(part).toContain("stays open until 20 September 2026");
      expect(part).toContain("not expecting this");
    }
  });

  test("a resent link says so, and names nobody as the inviter", () => {
    const m = invitationEmail({ ...base, inviter: null, resent: true });
    expect(m.subject).toBe("Your sign-in link for Northwind Foods on Clove ERP");
    expect(m.text).toContain("new sign-in link for your invitation to join Northwind Foods");
    expect(m.text).toContain("did not ask for a new link");
  });

  test("escapes what a tenant typed, so a name cannot become markup", () => {
    const m = invitationEmail({
      ...base,
      organisation: `<img src=x onerror="alert(1)">`,
      inviter: `Eve & "friends"`,
      invitee: "<b>Sam</b>",
    });
    expect(m.html).not.toContain("<img");
    expect(m.html).not.toContain("<b>");
    expect(m.html).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
    expect(m.html).toContain("Eve &amp; &quot;friends&quot;");
    expect(m.html).toContain("&lt;b&gt;Sam&lt;/b&gt;");
  });

  test("escapes the link inside the attribute it sits in", () => {
    const m = invitationEmail({
      ...base,
      link: `https://cloveerp.com/join#invitation=x"><script>`,
    });
    expect(m.html).not.toContain("<script>");
    expect(m.html).toContain(
      'href="https://cloveerp.com/join#invitation=x&quot;&gt;&lt;script&gt;"',
    );
  });

  test("keeps a name on one line, so it cannot add a line to the subject", () => {
    const m = invitationEmail({ ...base, organisation: "Acme\r\nBcc: someone@example.com" });
    expect(m.subject).not.toMatch(/[\r\n]/);
    expect(m.subject).toBe(
      "Ada Lovelace invited you to join Acme Bcc: someone@example.com on Clove ERP",
    );
  });

  test("copes with an inviter, an organisation and an expiry nobody could name", () => {
    const m = invitationEmail({
      ...base,
      organisation: null,
      inviter: "  ",
      invitee: null,
      expiresAt: "not a date",
    });
    expect(m.subject).toBe("You are invited to join an organisation on Clove ERP");
    expect(m.text.startsWith("Hello,\n")).toBe(true);
    expect(m.text).not.toContain("stays open until");
  });

  test("carries no images, no scripts and no remote assets; every URL is the link", () => {
    const m = invitationEmail(base);
    expect(m.html).not.toMatch(/<img|<script|<iframe|<link|url\(/i);
    const urls = (m.html.match(/https?:\/\/[^"<\s]+/g) ?? []).map((u) =>
      u.replaceAll("&amp;", "&"),
    );
    expect(urls.length).toBeGreaterThan(0);
    expect(new Set(urls)).toEqual(new Set([link]));
  });
});

describe("the small helpers", () => {
  test("escapeHtml covers the five characters that matter", () => {
    expect(escapeHtml(`&<>"'`)).toBe("&amp;&lt;&gt;&quot;&#39;");
  });

  test("oneLine flattens and bounds", () => {
    expect(oneLine(" a\tb\n\nc ")).toBe("a b c");
    expect(oneLine("x".repeat(10), 5)).toBe("xxxx…");
    expect(oneLine(null)).toBe("");
  });

  test("expiryDate reads a date or a timestamp, and nothing else", () => {
    expect(expiryDate("2026-09-27T23:30:00+00:00")).toBe("27 September 2026");
    expect(expiryDate(new Date(Date.UTC(2026, 0, 1)))).toBe("1 January 2026");
    expect(expiryDate(null)).toBeNull();
    expect(expiryDate("")).toBeNull();
    expect(expiryDate("soon")).toBeNull();
  });

  test("a plausible token is long and plain", () => {
    expect(plausibleInvitationToken(TOKEN)).toBe(true);
    expect(plausibleInvitationToken("short")).toBe(false);
    expect(plausibleInvitationToken(`${TOKEN}<`)).toBe(false);
    expect(plausibleInvitationToken(42)).toBe(false);
  });
});
