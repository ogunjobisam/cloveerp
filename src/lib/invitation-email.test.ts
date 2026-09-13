import { describe, expect, test } from "bun:test";

import {
  RESEND_ENDPOINT,
  escapeHtml,
  invitationEmail,
  joinLink,
  oneLine,
  redirectKeepsInvitation,
  sendWithResend,
} from "./invitation-email";

const TOKEN = "a".repeat(64);

describe("the join link", () => {
  test("is the origin, /join and the token as its only query", () => {
    expect(joinLink("https://cloveerp.com", TOKEN)).toBe(
      `https://cloveerp.com/join?token=${TOKEN}`,
    );
  });

  test("encodes the token, so nothing in it can add a parameter or a fragment", () => {
    const link = joinLink("https://cloveerp.com", "a b&next=/evil#x");
    expect(link).toBe("https://cloveerp.com/join?token=a%20b%26next%3D%2Fevil%23x");
    const url = new URL(link);
    expect(url.searchParams.get("token")).toBe("a b&next=/evil#x");
    expect([...url.searchParams.keys()]).toEqual(["token"]);
    expect(url.hash).toBe("");
  });

  test("does not double the slash when the configured origin ends in one", () => {
    expect(joinLink("https://cloveerp.com/", TOKEN)).toBe(
      `https://cloveerp.com/join?token=${TOKEN}`,
    );
  });
});

describe("whether Supabase Auth kept the redirect", () => {
  const link = joinLink("https://cloveerp.com", TOKEN);

  test("the same page with the same token is kept", () => {
    expect(redirectKeepsInvitation(link, link)).toBe(true);
  });

  test("the Site URL it falls back to has lost the token", () => {
    expect(redirectKeepsInvitation("https://cloveerp.com", link)).toBe(false);
    expect(redirectKeepsInvitation("https://cloveerp.com/join", link)).toBe(false);
  });

  test("another host, nothing, or rubbish is not the invitation", () => {
    expect(redirectKeepsInvitation(`https://evil.example/join?token=${TOKEN}`, link)).toBe(false);
    expect(redirectKeepsInvitation(null, link)).toBe(false);
    expect(redirectKeepsInvitation("not a url", link)).toBe(false);
  });
});

describe("the email", () => {
  const base = {
    organisation: "Northwind Foods",
    inviter: "Ada Lovelace",
    inviteeName: "Sam",
    link: joinLink("https://cloveerp.com", TOKEN),
    expiresInDays: 7,
  };

  test("names who invited them, to what, and carries the link in both parts", () => {
    const m = invitationEmail(base);
    expect(m.subject).toBe("Ada Lovelace invited you to Northwind Foods on Clove ERP");
    expect(m.text).toContain("Hello Sam,");
    expect(m.text).toContain("Ada Lovelace has invited you to join Northwind Foods on Clove ERP.");
    expect(m.text).toContain(base.link);
    expect(m.html).toContain(`href="${base.link}"`);
  });

  test("says the link works once, when it expires, and what to do if unexpected", () => {
    const m = invitationEmail(base);
    for (const part of [m.text, m.html]) {
      expect(part).toContain("works once");
      expect(part).toContain("expires in 7 days");
      expect(part).toContain("did not expect this invitation");
    }
    expect(invitationEmail({ ...base, expiresInDays: 1 }).text).toContain("expires in 1 day.");
  });

  test("escapes what a tenant typed, so a name cannot become markup", () => {
    const m = invitationEmail({
      ...base,
      organisation: `<img src=x onerror="alert(1)">`,
      inviter: `Eve & "friends"`,
      inviteeName: "<b>Sam</b>",
    });
    expect(m.html).not.toContain("<img");
    expect(m.html).not.toContain("<b>");
    expect(m.html).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
    expect(m.html).toContain("Eve &amp; &quot;friends&quot;");
    expect(m.html).toContain("&lt;b&gt;Sam&lt;/b&gt;");
  });

  test("escapes the link inside the attribute it sits in", () => {
    const m = invitationEmail({ ...base, link: `https://cloveerp.com/join?token=x"><script>` });
    expect(m.html).not.toContain("<script>");
    expect(m.html).toContain('href="https://cloveerp.com/join?token=x&quot;&gt;&lt;script&gt;"');
  });

  test("keeps a name on one line, so it cannot add a line to the subject", () => {
    const m = invitationEmail({ ...base, organisation: "Acme\r\nBcc: someone@example.com" });
    expect(m.subject).not.toMatch(/[\r\n]/);
    expect(m.subject).toBe(
      "Ada Lovelace invited you to Acme Bcc: someone@example.com on Clove ERP",
    );
  });

  test("copes with an inviter and an organisation nobody could name", () => {
    const m = invitationEmail({ ...base, organisation: null, inviter: "  ", inviteeName: null });
    expect(m.subject).toBe("You are invited to an organisation on Clove ERP");
    expect(m.text.startsWith("Hello,\n")).toBe(true);
  });

  test("carries no images and no tracking", () => {
    const m = invitationEmail(base);
    expect(m.html).not.toMatch(/<img|<script|<iframe|<link/i);
    // Every URL in the message is the invitation link itself.
    const urls = m.html.match(/https?:\/\/[^"<\s]+/g) ?? [];
    expect(urls.length).toBeGreaterThan(0);
    expect(new Set(urls)).toEqual(new Set([base.link]));
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
});

describe("posting to Resend", () => {
  const message = {
    apiKey: "re_test_key",
    from: "Clove ERP <invitations@cloveerp.com>",
    to: "sam@example.com",
    subject: "s",
    text: "t",
    html: "<p>h</p>",
  };

  function fake(respond: () => Response | Promise<Response>) {
    const calls: { url: string; init: RequestInit }[] = [];
    const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), init: init ?? {} });
      return respond();
    }) as unknown as typeof fetch;
    return { calls, fetchImpl };
  }

  test("an id from Resend is a send, and the request is what Resend expects", async () => {
    const { calls, fetchImpl } = fake(() => Response.json({ id: "email_123" }));
    const result = await sendWithResend({ ...message, fetchImpl });
    expect(result).toEqual({ ok: true, id: "email_123" });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(RESEND_ENDPOINT);
    expect(calls[0]!.init.method).toBe("POST");
    const headers = new Headers(calls[0]!.init.headers);
    expect(headers.get("authorization")).toBe("Bearer re_test_key");
    expect(JSON.parse(String(calls[0]!.init.body))).toEqual({
      from: message.from,
      to: ["sam@example.com"],
      subject: "s",
      text: "t",
      html: "<p>h</p>",
    });
  });

  test("a refusal says the status and Resend's message, never the key", async () => {
    const { fetchImpl } = fake(() =>
      Response.json(
        { statusCode: 403, message: "The cloveerp.com domain is not verified." },
        { status: 403 },
      ),
    );
    const result = await sendWithResend({ ...message, fetchImpl });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toContain("403");
    expect(result.reason).toContain("The cloveerp.com domain is not verified.");
    expect(result.reason).not.toContain("re_test_key");
  });

  test("a body that is not JSON is bounded, not echoed whole", async () => {
    const { fetchImpl } = fake(() => new Response("x".repeat(5000), { status: 500 }));
    const result = await sendWithResend({ ...message, fetchImpl });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toContain("500");
    expect(result.reason.length).toBeLessThan(300);
  });

  test("accepted without an id is not recorded as sent", async () => {
    const { fetchImpl } = fake(() => Response.json({}));
    expect((await sendWithResend({ ...message, fetchImpl })).ok).toBe(false);
  });

  test("a network failure is an answer, not a throw", async () => {
    const { fetchImpl } = fake(() => {
      throw new TypeError("fetch failed");
    });
    const result = await sendWithResend({ ...message, fetchImpl });
    expect(result).toEqual({
      ok: false,
      reason: "The email service could not be reached (fetch failed)",
    });
  });
});
