/**
 * A supplier's answer to a purchase order, asked and given on their behalf
 * (20261004990000), from the browser.
 *
 * The supplier is no principal and has no organisation: the link in the PO
 * email is their authority, and anon may execute no erp_* door. So the page
 * asks the Edge Function supabase/functions/supplier_response, which asks the
 * database with the service client of the project this page talks to — the
 * client's own, since every client has a project of its own. Three TanStack
 * server functions until 7 October; what each answers is unchanged: the order
 * or null for a wrong or old link, and a refusal in its own words.
 */
import { callFunction } from "./erp";
import { supplierOrder, type SupplierOrder } from "./supplier-confirmation";
import {
  SUPPLIER_RESPONSE_FUNCTION,
  type SupplierRequest,
  type SupplierRespondResult,
} from "./supplier-response-contract";

export type { SupplierRespondResult } from "./supplier-response-contract";

type Answer = Extract<SupplierRequest, { action: "respond" }>["answer"];
type Notice = Extract<SupplierRequest, { action: "notify" }>["notice"];

/** The order a link names, or null: a wrong or old link learns nothing. */
export async function supplierOrderByLink({
  data,
}: {
  data: { token: string };
}): Promise<SupplierOrder | null> {
  try {
    const answer = await callFunction<{ order: unknown }>(SUPPLIER_RESPONSE_FUNCTION, {
      action: "peek",
      token: data.token,
    });
    return supplierOrder(answer.order);
  } catch {
    return null;
  }
}

/** The supplier's answer, recorded; a refusal comes back in its own words. */
export async function respondToOrder({
  data,
}: {
  data: { token: string; answer: Answer };
}): Promise<SupplierRespondResult> {
  try {
    return await callFunction<SupplierRespondResult>(SUPPLIER_RESPONSE_FUNCTION, {
      action: "respond",
      token: data.token,
      answer: data.answer,
    });
  } catch (error) {
    return { ok: false, message: couldNotReach(error, "The answer could not be recorded.") };
  }
}

/**
 * What the supplier says is on its way, once the order is confirmed
 * (20261005000000); a refusal comes back in its own words.
 */
export async function notifyShipment({
  data,
}: {
  data: { token: string; notice: Notice };
}): Promise<SupplierRespondResult> {
  try {
    return await callFunction<SupplierRespondResult>(SUPPLIER_RESPONSE_FUNCTION, {
      action: "notify",
      token: data.token,
      notice: data.notice,
    });
  } catch (error) {
    return { ok: false, message: couldNotReach(error, "The notice could not be recorded.") };
  }
}

function couldNotReach(error: unknown, fallback: string): string {
  const message = error instanceof Error ? error.message.trim() : "";
  return message === "" ? fallback : message;
}
