/**
 * How old a toast is, from the id it was raised with.
 *
 * An outcome stayed on the screen when the page changed under it: it sat over
 * the next screen's process strip and its first form (5 October re-test). A
 * toast showing when the page changes now goes with the page — except one
 * raised a moment before, which is the outcome of the press that changed the
 * page: "PO-000149 created from REQ-000072 and approved." as the order opens.
 *
 * An outcome is raised with an id that carries the time it was raised; any
 * other id says nothing of its age, and its toast goes with the page.
 */

/** How long a toast raised just before the page changed stays with the new page. */
export const RAISED_WITH_THE_PAGE_MS = 1_000;

let raised = 0;

/** An id for a toast raised now, which says when it was raised. */
export function outcomeToastId(now: number = Date.now()): string {
  raised += 1;
  return `outcome:${now}:${raised}`;
}

/** When a toast with this id was raised, or null when its id does not say. */
export function raisedAt(id: unknown): number | null {
  if (typeof id !== "string") return null;
  const m = /^outcome:(\d+):\d+$/.exec(id);
  return m ? Number(m[1]) : null;
}

/** Whether a toast showing when the page changes goes with the page. */
export function goesWithThePage(id: unknown, now: number = Date.now()): boolean {
  const at = raisedAt(id);
  return at === null || now - at >= RAISED_WITH_THE_PAGE_MS;
}
