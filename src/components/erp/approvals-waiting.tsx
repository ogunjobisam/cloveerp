import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { ArrowRight, Stamp } from "lucide-react";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { TOUCH } from "./page";

/**
 * What is waiting on this person, said where they already are.
 *
 * My approvals has been on the governance screen since approvals existed, and
 * it is the right panel: it lists the tasks assigned to you and carries the
 * two buttons that decide them. What it could not do is be found. A buyer
 * whose order is held, or a manager asked to approve a discount, does not
 * think "governance" — they think "somebody said this needs approving", and
 * then they look at the screen they are already on.
 *
 * So the count travels to them. The header carries it on every screen, and
 * Home carries the same count as a card, and both are one link to the panel
 * that already exists. Neither of them decides anything: a second place to
 * approve would be a second place for the wording, the permissions and the
 * refusals to drift apart from the first.
 *
 * The count is the length of erp_my_approvals under the key the panel itself
 * queries, so the header, Home and the panel are one call and one cache. Decide
 * a task on governance and the header drops by one without being told.
 */

/** How many tasks are waiting on the caller. Zero while it loads, or on error:
 *  a badge is an offer to look, and nothing here is worth an alarm. */
function useWaiting(): number {
  const { data } = useQuery({
    queryKey: ["erp_my_approvals", {}],
    queryFn: () => callErp<unknown[]>("erp_my_approvals", {}),
    refetchInterval: (q) => (q.state.error ? false : 60_000),
  });
  return data?.length ?? 0;
}

/**
 * The count, in a whole sentence.
 *
 * Two sentences rather than one with a plural rule in it: English needs "one
 * approval is" and "four approvals are", and a translator handed a fragment
 * and a number cannot put either right.
 */
function waitingWords(count: number, ui: (text: string) => string): string {
  return count === 1
    ? ui("One approval is waiting on your decision.")
    : fill(ui("{count} approvals are waiting on your decision."), { count });
}

/**
 * The header badge, on every screen behind the gate.
 *
 * Nothing is rendered when nothing is waiting, so the header a person sees on
 * an ordinary day is exactly the header they saw before this existed. The
 * words are hidden rather than dropped on a narrow screen, so the link is
 * still announced as "Waiting on you" where it shows only a numeral.
 */
export function ApprovalsWaitingBadge() {
  const { ui } = useT();
  const count = useWaiting();
  if (count === 0) return null;

  return (
    <Link
      to="/governance"
      className={`${TOUCH} inline-flex shrink-0 items-center gap-1.5 rounded-md border border-accent/40 bg-accent/5 px-2.5 text-sm font-medium text-foreground`}
    >
      <Stamp className="size-4 shrink-0 text-accent" aria-hidden="true" />
      <span className="sr-only sm:not-sr-only">{ui("Waiting on you")}</span>
      <span className="rounded-full bg-accent px-1.5 text-xs font-semibold tabular-nums text-accent-foreground">
        {count}
      </span>
    </Link>
  );
}

/**
 * The same thing on Home, where there is room to say it in words.
 *
 * Above the first-run guidance on purpose: a step somebody else is waiting on
 * outranks a step of your own setup.
 */
export function ApprovalsWaiting() {
  const { t, ui } = useT();
  const count = useWaiting();
  if (count === 0) return null;

  return (
    <Link
      to="/governance"
      className={`${TOUCH} group flex items-center gap-3 rounded-2xl border border-accent/40 bg-accent/5 p-4 transition-colors hover:border-accent sm:p-5`}
    >
      <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent transition-colors group-hover:bg-accent group-hover:text-accent-foreground">
        <Stamp className="size-4.5" aria-hidden="true" />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block font-display text-sm font-semibold">{ui("Waiting on you")}</span>
        <span className="mt-0.5 block text-xs text-muted-foreground">
          {waitingWords(count, ui)}
        </span>
      </span>
      <span className="hidden shrink-0 text-xs font-medium text-muted-foreground sm:block">
        {t("module.governance", "Change requests and approvals")}
      </span>
      <ArrowRight className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
    </Link>
  );
}
