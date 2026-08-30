import { useQuery } from "@tanstack/react-query";

import { callErp } from "../../lib/erp";
import type { Currency } from "../../lib/money";

/**
 * The currency table, and whether we actually have it.
 *
 * Three screens were each writing this query out, and each destructured only
 * `data` — so a failure fell through to `minorUnitsOf`'s documented default of
 * two decimal places. For GBP that is invisible. For JPY it is the bug this
 * whole exercise fixed, quietly restored: a display a hundred times too large,
 * and, far worse, an input that writes a hundred times too much to the ledger.
 *
 * A default is the right answer when the *currency* is unknown. It is the wrong
 * answer when the *table* is missing, because then we do not know that we do
 * not know. So the error comes back with the data and callers are expected to
 * do something about it — which, for anything that takes a price, means
 * refusing rather than guessing.
 *
 * Product content, identical for every tenant and effectively immutable, so it
 * is cached indefinitely and fetched once per session.
 */
export function useCurrencies(enabled: boolean = true): {
  currencies: Currency[] | undefined;
  error: unknown;
  isPending: boolean;
} {
  const { data, error, isPending } = useQuery({
    queryKey: ["erp_currencies", {}],
    queryFn: () => callErp<Currency[]>("erp_currencies"),
    staleTime: Infinity,
    enabled,
  });

  // A disabled query sits in `pending` for ever, which is not the same as
  // waiting for an answer. Callers ask "may I price yet?", so a query nobody
  // asked for reports neither pending nor failed.
  return { currencies: data, error: enabled ? error : null, isPending: enabled && isPending };
}
