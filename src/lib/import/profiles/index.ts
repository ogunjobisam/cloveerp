import type { Profile } from "../types";
import { unleashedProducts } from "./unleashed-products";
import { unleashedStock } from "./unleashed-stock";
import { xeroAgedPayables, xeroAgedReceivables } from "./xero-aged";
import { xeroContacts } from "./xero-contacts";
import { xeroTrialBalance } from "./xero-trial-balance";

/** Every source file Clove reads, in the order the pilot runbook loads them. */
export const PROFILES: readonly Profile[] = [
  xeroContacts,
  unleashedProducts,
  unleashedStock,
  xeroAgedReceivables,
  xeroAgedPayables,
  xeroTrialBalance,
];

export function profileById(id: string): Profile | undefined {
  return PROFILES.find((p) => p.id === id);
}
