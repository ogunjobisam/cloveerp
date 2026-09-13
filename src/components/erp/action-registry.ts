/**
 * Which forms are open for business on the screen right now.
 *
 * An ActionDialog registers the door it drives and a way to open itself while
 * it is mounted. The walkthrough asks by door name: "open the form for
 * erp_create_site". If nothing on the screen answers, the caller is told so
 * and can point at the screen instead of pretending.
 *
 * A module-level store rather than a provider, because the dialogs and the
 * walkthrough live on the same page and neither should have to know where the
 * other sits in the tree.
 */
const openers = new Map<string, Set<() => void>>();

export function registerActionOpener(fn: string, open: () => void): () => void {
  let set = openers.get(fn);
  if (!set) {
    set = new Set();
    openers.set(fn, set);
  }
  set.add(open);
  return () => {
    set.delete(open);
    if (set.size === 0) openers.delete(fn);
  };
}

/** Opens the first form on this screen that drives `fn`; false if there is none. */
export function openAction(fn: string): boolean {
  const set = openers.get(fn);
  const first = set?.values().next().value;
  if (!first) return false;
  first();
  return true;
}

export function hasActionOpener(fn: string): boolean {
  return (openers.get(fn)?.size ?? 0) > 0;
}
