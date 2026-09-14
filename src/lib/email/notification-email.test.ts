import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import {
  DEFAULT_APP_ORIGIN,
  actionLink,
  appOrigin,
  composeNotificationEmail,
  fill,
  formatInstant,
  formatMinor,
  renderNotificationEmail,
  type ClaimedNotification,
} from "./notification-email.ts";

/*
 * The words, as the migrations that introduced them write them. Reading them
 * from the files rather than copying them here is what proves that every
 * {placeholder} the database's words ask for is one this sender fills.
 */
const MIGRATION = [
  "20260914094000_every_email_says_what_is_asked.sql",
  "20260914096000_an_approval_can_be_given_from_the_email.sql",
]
  .map((file) =>
    readFileSync(new URL(`../../../supabase/migrations/${file}`, import.meta.url), "utf8"),
  )
  .join("\n");

function wordsFromMigration(locale: "en" | "de"): Map<string, string> {
  const out = new Map<string, string>();
  const tuple = /\(\s*'(email\.[a-z_.]+)',\s*'((?:[^']|'')*)',\s*'((?:[^']|'')*)'/g;
  for (const m of MIGRATION.matchAll(tuple)) {
    const [, key, en, de] = m;
    if (key && en !== undefined && de !== undefined) {
      out.set(key, (locale === "en" ? en : de).replaceAll("''", "'"));
    }
  }
  return out;
}

const EN = wordsFromMigration("en");
const DE = wordsFromMigration("de");

/** What erp.email_words(part, locale) returns: the keys directly under the part. */
function part(words: Map<string, string>, name: string): Record<string, string> {
  const prefix = `email.${name}.`;
  const out: Record<string, string> = {};
  for (const [key, value] of words) {
    if (key.startsWith(prefix) && !key.slice(prefix.length).includes(".")) {
      out[key.slice(prefix.length)] = value;
    }
  }
  return out;
}

function word(words: Map<string, string>, key: string): string {
  const value = words.get(key);
  if (value === undefined) throw new Error(`the migration has no ${key}`);
  return value;
}

/** A context shaped as erp.notification_email_context() writes one for an approval task. */
function approvalContext(
  words: Map<string, string>,
  opts: { escalated?: boolean; document?: boolean; locale?: string } = {},
) {
  const esc = opts.escalated === true;
  const doc = opts.document !== false;
  const w = part(words, "approval");
  const pick = (key: string) => word(new Map(Object.entries(w)), key);
  return {
    version: 1,
    kind: "approval",
    locale: opts.locale ?? "en",
    time_zone: "Europe/London",
    mandatory: false,
    words: {
      ...part(words, "common"),
      subject: word(
        words,
        `email.approval.subject${esc ? "_escalated" : ""}${doc ? "" : "_plain"}`,
      ),
      preheader: pick(doc ? "preheader_document" : "preheader"),
      heading: pick(esc ? "heading_escalated" : "heading"),
      intro: pick(`intro${esc ? "_escalated" : ""}${doc ? "_document" : ""}`),
      primary: pick("primary"),
      ...(doc ? { secondary: pick("secondary") } : {}),
      note: pick("note"),
      approve: pick("approve"),
      reject: pick("reject"),
      open_task: pick("open_task"),
      note_actions: pick("note_actions"),
      reason: pick(esc ? "reason_escalated" : "reason"),
    },
    labels: part(words, "approval.label"),
    links: {
      preferences: "/notifications",
      primary: "/governance?task=11111111-1111-4111-8111-111111111111",
      ...(doc ? { secondary: "/documents/22222222-2222-4222-8222-222222222222" } : {}),
    },
    fields: {
      task_id: "11111111-1111-4111-8111-111111111111",
      approval_request_id: "33333333-3333-4333-8333-333333333333",
      object_type: doc ? "document" : "zz_thing",
      object_id: "22222222-2222-4222-8222-222222222222",
      step_code: "finance_review",
      step: "Finance review",
      escalated: esc,
      ...(doc
        ? {
            document_id: "22222222-2222-4222-8222-222222222222",
            document_number: "PO-000123",
            document_type: "Purchase order",
            partner: "Acme Supplies",
            value_minor: 420000,
            currency: "GBP",
            minor_units: 2,
          }
        : {}),
      requested_at: "2026-09-14T09:05:00Z",
      due_at: "2026-09-16T09:05:00Z",
    },
    people: { requested_by: "44444444-4444-4444-8444-444444444444" },
    names: { requested_by: "Ada Lovelace", ...(esc ? { escalated_from: "Grace Hopper" } : {}) },
  };
}

function claimed(context: unknown, extra: Partial<ClaimedNotification> = {}): ClaimedNotification {
  return {
    id: "55555555-5555-4555-8555-555555555555",
    subject: "Approval requested",
    body: "A document is waiting for your approval.\n\nhttps://cloveerp.com/governance",
    context,
    organisation_name: "Northwind Foods",
    recipient_name: "Sam Carter",
    ...extra,
  };
}

const ORIGIN = "https://cloveerp.com";

describe("the module both runtimes read", () => {
  const source = readFileSync(new URL("./notification-email.ts", import.meta.url), "utf8");

  test("imports only the layout, with its extension", () => {
    const imports = (source.match(/^import\s.*$/gm) ?? []).map((l) => l.trim());
    expect(imports).toEqual([
      'import { oneLine, renderEmail, type EmailDetail, type EmailInput } from "./layout.ts";',
    ]);
  });

  test("reaches for no runtime of its own", () => {
    const code = source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    for (const global of ["process.", "window.", "Deno.", "import.meta", "document."]) {
      expect(code).not.toContain(global);
    }
  });

  test("the migration's words were found, in both languages", () => {
    expect(EN.size).toBeGreaterThan(90);
    expect(DE.size).toBe(EN.size);
  });
});

describe("an approval email", () => {
  const email = renderNotificationEmail(claimed(approvalContext(EN)), ORIGIN);

  test("has a subject of product words and identifiers", () => {
    expect(email.subject).toBe("Approval needed: PO-000123 · £4,200.00");
  });

  test("states the ask and says exactly what is being asked", () => {
    expect(email.text.startsWith("Your approval is needed\n\nHello Sam Carter,\n\n")).toBe(true);
    expect(email.text).toContain(
      "Purchase order PO-000123 has reached the approval step “Finance review”, which names you as its approver.",
    );
  });

  test("lists the document, partner, value, step, who asked, when, and when it is due", () => {
    for (const line of [
      "Document: Purchase order",
      "Number: PO-000123",
      "Business partner: Acme Supplies",
      "Value: £4,200.00",
      "Approval step: Finance review",
      "Requested by: Ada Lovelace",
      "Requested: 14 September 2026, 10:05 BST",
      "Decision due by: 16 September 2026, 10:05 BST",
    ]) {
      expect(email.text).toContain(line);
    }
  });

  test("leads with Review and approve on the task, then the document, as buttons and as addresses", () => {
    const task = `${ORIGIN}/governance?task=11111111-1111-4111-8111-111111111111`;
    const doc = `${ORIGIN}/documents/22222222-2222-4222-8222-222222222222`;
    expect(email.text).toContain(`Review and approve: ${task}\nOpen the document: ${doc}`);
    expect(email.html).toMatch(
      /class="ce-button"[^>]*><a class="ce-button-text" href="https:\/\/cloveerp\.com\/governance\?task=/,
    );
    expect(email.html).toContain(`>Open the document</a>`);
  });

  test("says why they got it and links to their email choices", () => {
    expect(email.text).toContain(
      "You are receiving this because an approval step in Northwind Foods names you as its approver.",
    );
    expect(email.text).toContain(`Choose which emails you receive: ${ORIGIN}/notifications`);
    expect(email.text).toContain("Sent by Clove ERP for Northwind Foods.");
    expect(email.html).toContain(">Northwind Foods</td>");
  });

  test("an escalation says so, and names who it came from", () => {
    const m = renderNotificationEmail(claimed(approvalContext(EN, { escalated: true })), ORIGIN);
    expect(m.subject).toBe("Approval escalated to you: PO-000123 · £4,200.00");
    expect(m.text).toContain("An approval has been escalated to you");
    expect(m.text).toContain("was not decided in time");
    expect(m.text).toContain("Escalated from: Grace Hopper");
  });

  test("a request that is not a document has no document button and no figures in its subject", () => {
    const m = renderNotificationEmail(claimed(approvalContext(EN, { document: false })), ORIGIN);
    expect(m.subject).toBe("Approval needed");
    expect(m.text).not.toContain("Open the document");
    expect(m.text).toContain("A request in Northwind Foods has reached the approval step");
  });

  test("reads in German when the reader does", () => {
    const m = renderNotificationEmail(claimed(approvalContext(DE, { locale: "de" })), ORIGIN);
    expect(m.subject).toBe("Genehmigung erforderlich: PO-000123 · 4.200,00 £");
    expect(m.text).toContain("Prüfen und genehmigen: https://cloveerp.com/governance?task=");
    expect(m.text).toContain("Hallo Sam Carter,");
    expect(m.html).toContain('<html lang="de">');
  });

  test("puts nothing a tenant typed in the subject", () => {
    const ctx = approvalContext(EN);
    ctx.fields.partner = "Payment failed, call +1 800 555 0100";
    ctx.fields.step = "Urgent: verify your account";
    const m = renderNotificationEmail(
      claimed(ctx, {
        organisation_name: "Your bank's security team",
        recipient_name: "<b>Sam</b>",
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("Approval needed: PO-000123 · £4,200.00");
    expect(m.html).not.toContain("<b>Sam");
    expect(m.html).toContain("&lt;b&gt;Sam&lt;/b&gt;");
    expect(m.text).toContain("Business partner: Payment failed, call +1 800 555 0100");
  });
});

describe("the other kinds", () => {
  const common = part(EN, "common");

  test("a configuration change links to that change and names who submitted it", () => {
    const w = part(EN, "change_set");
    const m = renderNotificationEmail(
      claimed({
        kind: "change_set",
        locale: "en",
        time_zone: "UTC",
        mandatory: false,
        words: { ...common, ...w, subject: word(EN, "email.change_set.subject") },
        labels: part(EN, "change_set.label"),
        links: {
          primary: "/administration/configuration?change=abc",
          preferences: "/notifications",
        },
        fields: {
          change_set_id: "abc",
          code: "zz-live",
          name: "Rename Home",
          item_count: 3,
          submitted_at: "2026-09-14T09:00:00Z",
        },
        names: { submitted_by: "Ada Lovelace" },
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("Approval needed: configuration change");
    expect(m.text).toContain("A configuration change needs your approval");
    expect(m.text).toContain("Entries in the change: 3\nSubmitted by: Ada Lovelace");
    expect(m.text).toContain(
      `Review the change: ${ORIGIN}/administration/configuration?change=abc`,
    );
  });

  test("a failed job shows its error as written and says it cannot be switched off", () => {
    const w = part(EN, "job_failed");
    const m = renderNotificationEmail(
      claimed({
        kind: "job_failed",
        locale: "en",
        time_zone: "UTC",
        mandatory: true,
        words: { ...common, ...w, subject: word(EN, "email.job_failed.subject") },
        labels: part(EN, "job_failed.label"),
        links: { primary: "/operations/jobs", preferences: "/notifications" },
        fields: {
          job_code: "route_notifications",
          job_name: "Route notifications",
          handler: "notifications.route_events",
          consecutive_failures: 3,
          error: 'relation "zz_missing" does not exist\nCONTEXT: PL/pgSQL function',
          failed_at: "2026-09-14T09:00:00Z",
        },
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("Scheduled job failed: route_notifications");
    expect(m.text).toContain("failed 3 times in a row");
    expect(m.text).toContain("Job: Route notifications (route_notifications)");
    expect(m.text).toContain(
      'Error:\n  relation "zz_missing" does not exist\n  CONTEXT: PL/pgSQL function',
    );
    expect(m.html).toContain("white-space:pre-wrap");
    expect(m.text).toContain(word(EN, "email.common.mandatory"));
    expect(m.text).not.toContain("Choose which emails you receive");
  });

  test("support access names the member of staff, the reason and when it ends", () => {
    const w = part(EN, "support_access");
    const m = renderNotificationEmail(
      claimed({
        kind: "support_access",
        locale: "en",
        time_zone: "UTC",
        mandatory: true,
        words: {
          ...common,
          ...w,
          subject: word(EN, "email.support_access.subject"),
          access: w["access_write"],
        },
        labels: part(EN, "support_access.label"),
        links: { primary: "/operations/continuity", preferences: "/notifications" },
        fields: {
          access_id: "x",
          staff_role: "support",
          reason: "Investigating the invoice totals reported in ticket 42",
          write_access: true,
          granted_at: "2026-09-14T09:00:00Z",
          expires_at: "2026-09-14T13:00:00Z",
        },
        names: { staff: "helper@cloveerp.com" },
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("Support access granted to your organisation");
    expect(m.text).toContain("until 14 September 2026, 13:00 UTC");
    expect(m.text).toContain("Support staff member: helper@cloveerp.com");
    expect(m.text).toContain("Access: Can make changes, as an administrator");
    expect(m.text).toContain(`Review the support session: ${ORIGIN}/operations/continuity`);
  });

  test("an incident update quotes the update and gives severity, services and the next update", () => {
    const w = part(EN, "incident");
    const m = renderNotificationEmail(
      claimed({
        kind: "incident",
        locale: "en",
        time_zone: "UTC",
        mandatory: true,
        words: {
          ...common,
          subject: word(EN, "email.incident.subject_update"),
          preheader: w["preheader_update"],
          heading: w["heading_update"],
          intro: w["intro_update"],
          primary: w["primary"],
          reason: w["reason"],
          mandatory: w["mandatory"],
        },
        labels: part(EN, "incident.label"),
        links: { primary: "/operations/continuity", preferences: "/notifications" },
        fields: {
          code: "INC-2026-007",
          severity: "SEV2",
          title: "Allocation failing",
          is_update: true,
          declared_at: "2026-09-14T08:00:00Z",
          next_update_at: "2026-09-14T09:30:00Z",
          components: ["Allocation", "Order intake"],
          body: "Affected: allocation.\n\nBeing done: rolling back.",
        },
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("Service incident update INC-2026-007 · SEV2");
    expect(m.text).toContain("Severity: SEV2\nAffected services: Allocation, Order intake");
    expect(m.text).toContain("Next update by: 14 September 2026, 09:30 UTC");
    expect(m.text).toContain("Affected: allocation.\n\nBeing done: rolling back.");
    expect(m.text).toContain(w["mandatory"] ?? "missing");
  });

  test("a digest counts its updates and lists each", () => {
    const w = part(EN, "digest");
    const m = renderNotificationEmail(
      claimed({
        kind: "digest",
        locale: "en",
        time_zone: "UTC",
        mandatory: false,
        words: {
          ...common,
          subject: word(EN, "email.digest.subject"),
          preheader: w["preheader"],
          heading: w["heading"],
          intro: w["intro"],
          primary: w["primary"],
          reason: w["reason"],
          note: w["more"],
        },
        labels: {},
        links: { primary: "/notifications", preferences: "/notifications" },
        fields: {
          count: 23,
          more: 3,
          items: [
            { at: "2026-09-14T08:00:00Z", subject: "Receipt outside tolerance" },
            { at: "2026-09-14T08:30:00Z", subject: "Stock short on release" },
          ],
        },
      }),
      ORIGIN,
    );
    expect(m.subject).toBe("23 updates");
    expect(m.text).toContain("14 September 2026, 08:00 UTC: Receipt outside tolerance");
    expect(m.text).toContain("And 3 more in Clove ERP.");
    expect(m.text).toContain(`Open notifications: ${ORIGIN}/notifications`);
  });
});

describe("an approval email with a decision link", () => {
  const TOKEN = "ab".repeat(32);
  const task = `${ORIGIN}/governance?task=11111111-1111-4111-8111-111111111111`;
  const doc = `${ORIGIN}/documents/22222222-2222-4222-8222-222222222222`;
  const email = renderNotificationEmail(
    claimed(approvalContext(EN), { action_token: TOKEN }),
    ORIGIN,
  );

  test("leads with Approve and Reject, each opening the decision page with the token in the fragment", () => {
    const approve = actionLink(ORIGIN, TOKEN, "approve");
    const reject = actionLink(ORIGIN, TOKEN, "reject");
    expect(approve).toBe(`${ORIGIN}/act#t=${TOKEN}&d=approve`);
    expect(new URL(approve).search).toBe("");
    expect(email.text).toContain(`Approve: ${approve}\nReject: ${reject}`);
    expect(email.html).toMatch(
      /class="ce-button"[^>]*><a class="ce-button-text" href="https:\/\/cloveerp\.com\/act#t=/,
    );
    expect(email.html).toContain('class="ce-button-outline"');
    expect(email.html).toContain(">Reject</a>");
  });

  test("keeps the task and the document as plain links below", () => {
    expect(email.text).toContain(`Review in Clove ERP: ${task}\nOpen the document: ${doc}`);
    expect(email.html).toContain(`>Review in Clove ERP</a>`);
    expect(email.html).not.toContain(">Review and approve</a>");
  });

  test("says that nothing is decided until they sign in and confirm", () => {
    expect(email.text).toContain("where you sign in and confirm");
    expect(email.text).not.toContain("Nothing is approved until you decide in Clove ERP");
  });

  test("puts the token in the links and nowhere else, and never in the subject", () => {
    expect(email.subject).not.toContain(TOKEN);
    const outsideLinks = email.text.replace(/https:\/\/\S+/g, "");
    expect(outsideLinks).not.toContain(TOKEN);
  });

  test("reads in German too", () => {
    const m = renderNotificationEmail(
      claimed(approvalContext(DE, { locale: "de" }), { action_token: TOKEN }),
      ORIGIN,
    );
    expect(m.text).toContain(`Genehmigen: ${ORIGIN}/act#t=${TOKEN}&d=approve`);
    expect(m.text).toContain(`Ablehnen: ${ORIGIN}/act#t=${TOKEN}&d=reject`);
  });

  test("without a token, or with one that is not a token, it stays Review and approve", () => {
    for (const action_token of [null, undefined, "not-a-token", `${TOKEN}0`, TOKEN.toUpperCase()]) {
      const m = renderNotificationEmail(
        claimed(approvalContext(EN), { action_token: action_token ?? null }),
        ORIGIN,
      );
      expect(m.text).toContain(`Review and approve: ${task}`);
      expect(m.text).not.toContain("/act#");
    }
  });

  test("a context from before the decision words still sends Review and approve", () => {
    const old = approvalContext(EN) as { words: Record<string, string> };
    delete old.words["approve"];
    delete old.words["reject"];
    const m = renderNotificationEmail(claimed(old, { action_token: TOKEN }), ORIGIN);
    expect(m.text).toContain(`Review and approve: ${task}`);
    expect(m.text).not.toContain(TOKEN);
  });

  test("a token on any other kind of email is ignored", () => {
    const w = part(EN, "digest");
    const m = renderNotificationEmail(
      claimed(
        {
          kind: "digest",
          locale: "en",
          time_zone: "UTC",
          words: {
            ...part(EN, "common"),
            subject: word(EN, "email.digest.subject_one"),
            preheader: w["preheader_one"],
            heading: w["heading_one"],
            intro: w["intro"],
            primary: w["primary"],
            reason: w["reason"],
            approve: "Approve",
            reject: "Reject",
          },
          labels: {},
          links: { primary: "/notifications", preferences: "/notifications" },
          fields: { count: 1, more: 0, items: [] },
        },
        { action_token: TOKEN },
      ),
      ORIGIN,
    );
    expect(m.text).not.toContain(TOKEN);
    expect(m.text).toContain(`Open notifications: ${ORIGIN}/notifications`);
  });

  test("a fallback reason never carries the token", () => {
    const broken = approvalContext(EN);
    delete (broken.fields as Record<string, unknown>)["document_number"];
    const out = composeNotificationEmail(claimed(broken, { action_token: TOKEN }), ORIGIN);
    expect(out.html).toBeNull();
    expect(out.fallback).not.toContain(TOKEN);
    expect(out.body).not.toContain(TOKEN);
  });
});

describe("falling back to the plain body", () => {
  test("a notification with no context goes as its subject and body", () => {
    const row = claimed(null);
    expect(composeNotificationEmail(row, ORIGIN)).toEqual({
      subject: "Approval requested",
      body: row.body ?? "",
      html: null,
      fallback: null,
    });
  });

  test("a context that cannot be rendered goes as the body, and says why", () => {
    const broken = approvalContext(EN);
    delete (broken.fields as Record<string, unknown>)["document_number"];
    const out = composeNotificationEmail(claimed(broken), ORIGIN);
    expect(out.html).toBeNull();
    expect(out.subject).toBe("Approval requested");
    expect(out.fallback).toContain("{number}");

    for (const bad of [{ kind: "nonsense" }, "not json", 42, { kind: "approval", links: {} }]) {
      const r = composeNotificationEmail(claimed(bad), ORIGIN);
      expect(r.html).toBeNull();
      expect(r.fallback).not.toBeNull();
    }
  });

  test("a link that is not a path on the site is refused rather than followed", () => {
    for (const path of [
      "https://evil.example/x",
      "//evil.example",
      "/\\evil.example",
      "javascript:alert(1)",
    ]) {
      const ctx = approvalContext(EN);
      ctx.links.primary = path;
      expect(composeNotificationEmail(claimed(ctx), ORIGIN).fallback).toContain("not a path");
    }
  });

  test("a context delivered as JSON text renders the same", () => {
    const ctx = approvalContext(EN);
    const a = composeNotificationEmail(claimed(ctx), ORIGIN);
    const b = composeNotificationEmail(claimed(JSON.stringify(ctx)), ORIGIN);
    expect(b.html).toBe(a.html);
    expect(a.fallback).toBeNull();
  });
});

describe("the small helpers", () => {
  test("appOrigin takes CLOVEERP_APP_URL's origin, or the product's address", () => {
    expect(appOrigin("https://staging.cloveerp.com/join")).toBe("https://staging.cloveerp.com");
    expect(appOrigin(" ")).toBe(DEFAULT_APP_ORIGIN);
    expect(appOrigin("not a url")).toBe(DEFAULT_APP_ORIGIN);
    expect(appOrigin("javascript:alert(1)")).toBe(DEFAULT_APP_ORIGIN);
    expect(appOrigin(undefined)).toBe(DEFAULT_APP_ORIGIN);
  });

  test("formatMinor honours a currency's minor units", () => {
    expect(formatMinor(420000, "GBP", 2, "en")).toBe("£4,200.00");
    expect(formatMinor(4200, "JPY", 0, "en")).toBe("JP¥4,200");
    expect(formatMinor("12345", "EUR", 2, "de")).toBe("123,45\u00a0€");
    expect(formatMinor(null, "GBP", 2, "en")).toBeNull();
    expect(formatMinor(1, "pounds", 2, "en")).toBeNull();
  });

  test("formatInstant reads Postgres's microseconds and falls back to UTC for an unknown zone", () => {
    expect(formatInstant("2026-09-14T09:05:00.123456+00:00", "en", "Europe/London")).toBe(
      "14 September 2026, 10:05 BST",
    );
    expect(formatInstant("2026-01-14T09:05:00Z", "en", "Nowhere/Special")).toBe(
      "14 January 2026, 09:05 UTC",
    );
    expect(formatInstant("soon", "en", "UTC")).toBeNull();
  });

  test("fill refuses a placeholder nothing supplies", () => {
    expect(fill("Hello {name},", { name: "Sam" })).toBe("Hello Sam,");
    expect(() => fill("Hello {name},", { name: null })).toThrow("{name}");
  });
});
