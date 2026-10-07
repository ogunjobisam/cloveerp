/**
 * What a supplier's page asks on their behalf, and what it is answered.
 *
 * Shared by the browser (src/lib/supplier-response.functions.ts) and the Edge
 * Function that asks the database (supabase/functions/supplier_response).
 * Pure: zod and nothing else, so that Deno can follow it.
 */
import { z } from "zod";

export const SUPPLIER_RESPONSE_FUNCTION = "supplier_response";

export const supplierToken = z.string().regex(/^[0-9a-f]{64}$/);

export const supplierAnswer = z.object({
  decision: z.enum(["confirm", "decline"]),
  supplier_reference: z.string().max(80).optional(),
  note: z.string().max(1000).optional(),
  lines: z
    .array(
      z.object({
        line_id: z.string().uuid(),
        quantity: z.number().positive().optional(),
        date: z
          .string()
          .regex(/^\d{4}-\d{2}-\d{2}$/)
          .optional(),
      }),
    )
    .max(500)
    .optional(),
});

const quantityOfLine = z.object({
  order_line_id: z.string().uuid(),
  quantity: z.number().positive(),
});

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

export const supplierNotice = z.object({
  ship_date: day.optional(),
  expected_arrival: day,
  carrier: z.string().max(80).optional(),
  tracking_reference: z.string().max(120).optional(),
  supplier_reference: z.string().max(80).optional(),
  note: z.string().max(1000).optional(),
  lines: z.array(quantityOfLine).min(1).max(500),
  cartons: z
    .array(
      z.object({
        sscc: z.string().max(40),
        contents: z.array(quantityOfLine).max(500),
      }),
    )
    .max(500)
    .optional(),
});

/** One request: the link's token, and which of the three things is asked. */
export const supplierRequest = z.discriminatedUnion("action", [
  z.object({ action: z.literal("peek"), token: supplierToken }),
  z.object({ action: z.literal("respond"), token: supplierToken, answer: supplierAnswer }),
  z.object({ action: z.literal("notify"), token: supplierToken, notice: supplierNotice }),
]);

export type SupplierRequest = z.infer<typeof supplierRequest>;

export type SupplierRespondResult = { ok: true } | { ok: false; message: string };

/** The refusal's own sentence, without its code: CLOVEERP_X: words. */
export function refusalWords(message: string, fallback: string): string {
  const words = message.replace(/^CLOVEERP_[A-Z_]+:\s*/, "").trim();
  return words || fallback;
}
