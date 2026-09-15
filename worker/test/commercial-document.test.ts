import { describe, expect, test } from "bun:test";

import type { ClaimedCommercialEmail } from "../../src/lib/email/commercial-email.ts";
import {
  keepCommercialDocument,
  loadCommercialDocumentRenderer,
  sendCommercialEmail,
} from "../src/core/commercial.ts";
import { PermanentSendFailure, type EmailRow } from "../src/core/resend.ts";

const EMAIL_ID = "0b5a1e3c-5d6f-4a7b-8c9d-0e1f2a3b4c5d";

function invoiceRow(over: Record<string, unknown> = {}): ClaimedCommercialEmail {
  return {
    email_id: EMAIL_ID,
    email_kind: "contract_invoice",
    recipient_address: "accounts@example.com",
    recipient_name: "Accounts Team",
    sender_address: "Clove ERP <billing@cloveerp.com>",
    reply_address: "billing@cloveerp.com",
    send_key: `clove-contract-invoice-${EMAIL_ID}`,
    attempt: 1,
    payload: {
      kind: "contract_invoice",
      reference: "INV-EXAMPLE-202609-001",
      customer_name: "Example Customer Ltd",
      supplier_name: "Clove ERP Ltd",
      currency: "GBP",
      period_start: "2026-09-14",
      period_end: "2026-10-14",
      issued_on: "2026-09-14",
      due_on: "2026-09-28",
      lines: [{ kind: "subscription", description: "standard plan", net_minor: 145100 }],
      total_minor: 145100,
      tax_statement: "Clove ERP Ltd is not registered for VAT; no VAT is charged.",
      payment_details: null,
      letterhead: null,
      filename: "Invoice-INV-EXAMPLE-202609-001.pdf",
      ...over,
    },
  };
}

const CFG = {
  appOrigin: "https://cloveerp.com",
  supabaseUrl: "https://project.supabase.co/",
  supabaseServiceRoleKey: "service-role-test",
  httpTimeoutMs: 5_000,
};

type Call = { url: string; init: RequestInit };

function recorder(status = 200) {
  const calls: Call[] = [];
  const fetchImpl = async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(JSON.stringify({ Key: "document-output/x" }), { status });
  };
  return { calls, fetchImpl };
}

function sender(refuseAttachments = false) {
  const rows: EmailRow[] = [];
  const send = async (_key: string, row: EmailRow) => {
    rows.push(row);
    if (refuseAttachments && row.attachments?.length) {
      throw new PermanentSendFailure("resend responded 422: attachment rejected");
    }
    return `re_${rows.length}`;
  };
  return { rows, send };
}

describe("an invoice email and its PDF", () => {
  test("goes with the PDF attached, keeps the copy under its own path, and reports what the settle records", async () => {
    const { rows, send } = sender();
    const { calls, fetchImpl } = recorder();
    const sent = await sendCommercialEmail(invoiceRow(), CFG, "re_test", { send, fetch: fetchImpl });

    expect(rows).toHaveLength(1);
    const attachment = rows[0]?.attachments?.[0];
    expect(attachment?.filename).toBe("Invoice-INV-EXAMPLE-202609-001.pdf");
    const bytes = Uint8Array.from(atob(attachment?.content ?? ""), (c) => c.charCodeAt(0));
    expect(new TextDecoder().decode(bytes.slice(0, 5))).toBe("%PDF-");
    expect(rows[0]?.body).toContain("The invoice is attached as a PDF, Invoice-INV-EXAMPLE-202609-001.pdf.");
    expect(rows[0]?.idempotency_key).toBe(`clove-contract-invoice-${EMAIL_ID}`);

    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe(
      `https://project.supabase.co/storage/v1/object/document-output/commercial/contract-invoice/${EMAIL_ID}.pdf`,
    );
    const headers = calls[0]?.init.headers as Record<string, string>;
    expect(headers["content-type"]).toBe("application/pdf");
    expect(headers["x-upsert"]).toBe("true");

    expect(sent.providerId).toBe("re_1");
    expect(sent.documentPath).toBe(`commercial/contract-invoice/${EMAIL_ID}.pdf`);
    expect(sent.documentBytes).toBe(bytes.byteLength);
    expect(sent.documentSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(sent.documentProblem).toBeNull();
  });

  test("a document that cannot be made never stops the email, and says why", async () => {
    const { rows, send } = sender();
    const { calls, fetchImpl } = recorder();
    const sent = await sendCommercialEmail(invoiceRow(), CFG, "re_test", {
      send,
      fetch: fetchImpl,
      load: () => Promise.reject(new Error("Cannot find package 'pdf-lib'")),
    });
    expect(rows).toHaveLength(1);
    expect(rows[0]?.attachments ?? null).toBeNull();
    expect(rows[0]?.body).not.toContain("PDF");
    expect(calls).toHaveLength(0);
    expect(sent.providerId).toBe("re_1");
    expect(sent.documentPath).toBeNull();
    expect(sent.documentProblem).toBe(
      "no PDF could be made, so the email went without one: Cannot find package 'pdf-lib'",
    );
  });

  test("a provider that refuses the attachment gets the email once more without it, under a key of its own", async () => {
    const { rows, send } = sender(true);
    const { fetchImpl } = recorder();
    const sent = await sendCommercialEmail(invoiceRow(), CFG, "re_test", { send, fetch: fetchImpl });
    expect(rows).toHaveLength(2);
    expect(rows[1]?.attachments ?? null).toBeNull();
    expect(rows[1]?.body).not.toContain("attached as a PDF");
    expect(rows[1]?.idempotency_key).toBe(`clove-contract-invoice-${EMAIL_ID}-without-attachment`);
    expect(sent.providerId).toBe("re_2");
    expect(sent.documentPath).toBe(`commercial/contract-invoice/${EMAIL_ID}.pdf`);
    expect(sent.documentProblem).toContain("the provider refused the PDF, so the email went without it");
  });

  test("a copy that cannot be kept is a reason, not a failure", async () => {
    const { send } = sender();
    const refused = await sendCommercialEmail(invoiceRow(), CFG, "re_test", {
      send,
      fetch: recorder(403).fetchImpl,
    });
    expect(refused.providerId).toBe("re_1");
    expect(refused.documentPath).toBeNull();
    expect(refused.documentBytes).toBeNull();
    expect(refused.documentProblem).toBe("the copy could not be kept: storage responded 403");

    expect(
      await keepCommercialDocument(
        { supabaseUrl: null, supabaseServiceRoleKey: null, httpTimeoutMs: 1000 },
        "commercial/order-form/x.pdf",
        new Uint8Array([1]),
      ),
    ).toBe("no storage is configured for the drain, so no copy was kept");
  });

  test("an email that cannot be written still fails as it did, before any document is made", async () => {
    const { rows, send } = sender();
    const { calls, fetchImpl } = recorder();
    await expect(
      sendCommercialEmail(invoiceRow({ due_on: null }), CFG, "re_test", { send, fetch: fetchImpl }),
    ).rejects.toThrow("the invoice has no due date");
    expect(rows).toHaveLength(0);
    expect(calls).toHaveLength(0);
  });

  test("a provider's never for the message itself still fails it", async () => {
    const send = async () => {
      throw new PermanentSendFailure("resend responded 422: invalid to");
    };
    await expect(
      sendCommercialEmail(invoiceRow(), CFG, "re_test", {
        send,
        fetch: recorder().fetchImpl,
        load: () => Promise.reject(new Error("no renderer")),
      }),
    ).rejects.toBeInstanceOf(PermanentSendFailure);
  });

  test("the renderer loads by the literal path the Edge Function bundles", async () => {
    const renderer = await loadCommercialDocumentRenderer();
    expect(typeof renderer.renderCommercialDocumentPdf).toBe("function");
  });
});
