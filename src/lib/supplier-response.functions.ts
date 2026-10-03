/**
 * A supplier's answer to a purchase order, asked and given on the server
 * (20261004990000).
 *
 * The supplier is no principal and has no organisation: the link in the PO
 * email is their authority, and anon may execute no erp_* door. So the browser
 * does not ask. These server functions do, with the service client, and only
 * service_role may execute public.erp_supplier_response_peek and
 * public.erp_supplier_respond. Both are POST, so the token travels in a body
 * and never in a query string a log would keep.
 */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";

import { supplierOrder, type SupplierOrder } from "./supplier-confirmation";

const token = z.string().regex(/^[0-9a-f]{64}$/);

const answer = z.object({
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

type Rpc = (
  name: string,
  args?: Record<string, unknown>,
) => Promise<{ data: unknown; error: { message: string } | null }>;

async function rpc(): Promise<Rpc> {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  return (supabaseAdmin.rpc as unknown as Rpc).bind(supabaseAdmin);
}

/** The order a link names, or null: a wrong or old link learns nothing. */
export const supplierOrderByLink = createServerFn({ method: "POST" })
  .inputValidator((data: unknown) => z.object({ token }).parse(data))
  .handler(async ({ data }): Promise<SupplierOrder | null> => {
    const call = await rpc();
    const { data: order, error } = await call("erp_supplier_response_peek", {
      p_token: data.token,
    });
    if (error) return null;
    return supplierOrder(order);
  });

export type SupplierRespondResult = { ok: true } | { ok: false; message: string };

/** The supplier's answer, recorded; a refusal comes back in its own words. */
export const respondToOrder = createServerFn({ method: "POST" })
  .inputValidator((data: unknown) => z.object({ token, answer }).parse(data))
  .handler(async ({ data }): Promise<SupplierRespondResult> => {
    const call = await rpc();
    const { error } = await call("erp_supplier_respond", {
      p_token: data.token,
      p_response: data.answer,
    });
    if (!error) return { ok: true };
    // The refusal's own sentence, without its code: CLOVEERP_X: words.
    const words = error.message.replace(/^CLOVEERP_[A-Z_]+:\s*/, "");
    return { ok: false, message: words || "The answer could not be recorded." };
  });

const quantityOfLine = z.object({
  order_line_id: z.string().uuid(),
  quantity: z.number().positive(),
});

const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

const notice = z.object({
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

/**
 * What the supplier says is on its way, once the order is confirmed
 * (20261005000000); a refusal comes back in its own words.
 */
export const notifyShipment = createServerFn({ method: "POST" })
  .inputValidator((data: unknown) => z.object({ token, notice }).parse(data))
  .handler(async ({ data }): Promise<SupplierRespondResult> => {
    const call = await rpc();
    const { error } = await call("erp_supplier_notify_shipment", {
      p_token: data.token,
      p_notice: data.notice,
    });
    if (!error) return { ok: true };
    const words = error.message.replace(/^CLOVEERP_[A-Z_]+:\s*/, "");
    return { ok: false, message: words || "The notice could not be recorded." };
  });
