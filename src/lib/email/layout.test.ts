import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import {
  DEFAULT_LAYOUT_WORDS,
  escapeHtml,
  oneLine,
  renderEmail,
  type EmailInput,
} from "./layout.ts";

const base: EmailInput = {
  organisation: "Northwind Foods",
  title: "Approval needed: PO-000123 · £4,200.00",
  preheader: "Purchase order PO-000123 for £4,200.00 is waiting for your decision.",
  greeting: "Hello Sam,",
  heading: "Your approval is needed",
  intro: "Purchase order PO-000123 has reached the approval step “Finance review”.",
  details: [
    { label: "Number", value: "PO-000123" },
    { label: "Value", value: "£4,200.00" },
    { label: "Business partner", value: "" },
    { label: "Error", value: 'relation "x" does not exist\nat line 4', monospace: true },
  ],
  primary: { label: "Review and approve", url: "https://cloveerp.com/governance?task=t1&x=1" },
  secondary: { label: "Open the document", url: "https://cloveerp.com/documents/d1" },
  note: "Nothing is approved until you decide.",
  reason: "You are receiving this because an approval step names you.",
  preferencesUrl: "https://cloveerp.com/notifications",
  footer: "Sent by Clove ERP for Northwind Foods.",
};

describe("the module every runtime reads", () => {
  const source = readFileSync(new URL("./layout.ts", import.meta.url), "utf8");

  test("imports nothing, so Deno can follow it", () => {
    expect(source).not.toMatch(/^\s*import\s/m);
    expect(source).not.toMatch(/\brequire\(/);
  });

  test("reaches for no runtime of its own", () => {
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    for (const global of ["process.", "window.", "Deno.", "import.meta", "document."]) {
      expect(code).not.toContain(global);
    }
  });
});

describe("the HTML", () => {
  const { html } = renderEmail(base);

  test("is one 600px column with the wordmark and the organisation in the header", () => {
    expect(html).toContain('width="600"');
    expect(html).toContain("max-width:600px");
    expect(html).toContain("Clove&nbsp;ERP");
    expect(html).toContain(">Northwind Foods</td>");
  });

  test("states the ask as the heading and hides the preheader", () => {
    expect(html).toContain(">Your approval is needed</h1>");
    expect(html).toMatch(/display:none[^>]*>Purchase order PO-000123 for £4,200.00/);
    expect(html).toContain("<title>Approval needed: PO-000123 · £4,200.00</title>");
  });

  test("has a filled primary and an outlined secondary button, each at least 44px tall", () => {
    const buttons = html.match(/<td class="ce-button[^"]*"[^>]*>/g) ?? [];
    expect(buttons).toHaveLength(2);
    expect(buttons[0]).toContain('class="ce-button"');
    expect(buttons[0]).toContain("background:#36312B");
    expect(buttons[1]).toContain('class="ce-button-outline"');
    expect(buttons[1]).toContain("background:#FEFDFA");
    expect(buttons[1]).toContain("border:1px solid #36312B");
    for (const b of buttons) expect(b).toContain('height="44"');
    // 12px + 20px + 12px inside a 1px border.
    expect(html).toContain("padding:12px 22px;font-family");
    expect(html).toContain("line-height:20px");
  });

  test("repeats every action as a plain address", () => {
    expect(html).toContain(DEFAULT_LAYOUT_WORDS.fallback);
    const href = escapeHtml(base.primary.url);
    // The button and the plain link.
    expect(html.split(`href="${href}"`).length - 1).toBe(2);
    expect(html).toContain(`Review and approve: <a class="ce-link" href="${href}"`);
    expect(html).toContain("Open the document: <a");
  });

  test("leaves out a row with nothing in it and keeps an error as it was written", () => {
    expect(html).not.toContain("Business partner");
    expect(html).toContain("white-space:pre-wrap");
    expect(html).toContain("relation &quot;x&quot; does not exist\nat line 4");
  });

  test("says why they got it and where to choose, unless it cannot be switched off", () => {
    expect(html).toContain("You are receiving this because an approval step names you.");
    expect(html).toContain('href="https://cloveerp.com/notifications"');
    expect(html).toContain("Choose which emails you receive");

    const mandatory = renderEmail({ ...base, mandatory: true }).html;
    expect(mandatory).toContain(DEFAULT_LAYOUT_WORDS.mandatory);
    expect(mandatory).not.toContain("Choose which emails you receive");

    const said = renderEmail({ ...base, mandatory: "Administrators always receive this." }).html;
    expect(said).toContain("Administrators always receive this.");
  });

  test("reads in dark mode: a dark palette, and no text left white on nothing", () => {
    expect(html).toContain('<meta name="color-scheme" content="light dark" />');
    expect(html).toContain("@media (prefers-color-scheme: dark)");
    expect(html).not.toMatch(/#FFFFFF|#FFF\b|:\s*white\b/i);
    // Every coloured band sets its own background.
    expect(html).toContain('bgcolor="#36312B"');
    expect(html).toContain('bgcolor="#FEFDFA"');
    expect(html).toContain('bgcolor="#F6F4F0"');
  });

  test("carries no images, scripts or remote assets; every address is one the reader opens", () => {
    expect(html).not.toMatch(/<img|<script|<iframe|<link|url\(/i);
    const urls = new Set(
      (html.match(/https?:\/\/[^"<\s]+/g) ?? []).map((u) => u.replaceAll("&amp;", "&")),
    );
    expect(urls).toEqual(
      new Set([base.primary.url, base.secondary?.url ?? "", base.preferencesUrl ?? ""]),
    );
  });

  test("escapes everything it is given, in text and in attributes", () => {
    const m = renderEmail({
      ...base,
      organisation: '<img src=x onerror="alert(1)">',
      heading: "<b>bold</b>",
      details: [{ label: "Partner", value: "Eve & <Co>", url: 'https://x.test/"><script>' }],
      quote: "<script>alert(1)</script>",
      primary: { label: "Go", url: 'https://cloveerp.com/a"><script>' },
    }).html;
    expect(m).not.toContain("<script>");
    expect(m).not.toContain("<img");
    expect(m).not.toContain("<b>bold");
    expect(m).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
    expect(m).toContain("Eve &amp; &lt;Co&gt;");
    expect(m).toContain('href="https://cloveerp.com/a&quot;&gt;&lt;script&gt;"');
  });

  test("a quote keeps its paragraphs and its line breaks", () => {
    const m = renderEmail({ ...base, quote: "First line\nsecond line\r\n\r\nNew paragraph" }).html;
    expect(m).toContain("First line<br />second line</p>");
    expect(m).toContain(">New paragraph</p>");
  });

  test("the header copes with no organisation", () => {
    const m = renderEmail({ ...base, organisation: null }).html;
    expect(m).not.toContain('align="right"');
  });
});

describe("the text", () => {
  const { text } = renderEmail(base);

  test("gives the same ask, the facts as Label: value lines and each action as Action: URL", () => {
    expect(text.startsWith("Your approval is needed\n\nHello Sam,\n\n")).toBe(true);
    expect(text).toContain("Purchase order PO-000123 has reached the approval step");
    expect(text).toContain("Number: PO-000123\nValue: £4,200.00\nError:\n  relation");
    expect(text).not.toContain("Business partner");
    expect(text).toContain(
      "Review and approve: https://cloveerp.com/governance?task=t1&x=1\n" +
        "Open the document: https://cloveerp.com/documents/d1",
    );
  });

  test("ends with why, where to choose and who it was sent for", () => {
    expect(text).toContain(
      "—\nYou are receiving this because an approval step names you.\n" +
        "Choose which emails you receive: https://cloveerp.com/notifications\n" +
        "Sent by Clove ERP for Northwind Foods.\n",
    );
    expect(renderEmail({ ...base, mandatory: true }).text).toContain(
      `names you.\n${DEFAULT_LAYOUT_WORDS.mandatory}\n`,
    );
  });

  test("keeps a name on its line", () => {
    const m = renderEmail({ ...base, greeting: "Hello Sam\r\nBcc: someone@example.com," });
    expect(m.text).toContain("Hello Sam Bcc: someone@example.com,");
  });

  test("uses the sender's words for the layout's own lines when it has them", () => {
    const m = renderEmail({
      ...base,
      words: {
        fallback: "Falls die Schaltfläche nicht funktioniert:",
        preferences: "E-Mails wählen",
      },
    });
    expect(m.html).toContain("Falls die Schaltfläche nicht funktioniert:");
    expect(m.text).toContain("E-Mails wählen: https://cloveerp.com/notifications");
  });
});

describe("the small helpers", () => {
  test("escapeHtml covers the five characters that matter", () => {
    expect(escapeHtml(`&<>"'`)).toBe("&amp;&lt;&gt;&quot;&#39;");
  });

  test("oneLine flattens and bounds", () => {
    expect(oneLine(" a\tb\n\nc ")).toBe("a b c");
    expect(oneLine("x".repeat(10), 5)).toBe("xxxx…");
    expect(oneLine(undefined)).toBe("");
  });
});
