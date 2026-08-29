import { useQueryClient } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

/**
 * The pieces every screen inside the shell shares.
 *
 * Three of them exist because of the mobile layout rather than in spite of it:
 * a description that costs one line until somebody asks for more, a refresh
 * control that belongs to the page rather than to each card on it, and a touch
 * target big enough to hit.
 */

/**
 * 44px. The minimum a finger can reliably hit, and the number every platform's
 * guidance converges on. Applied as a minimum rather than a fixed height so a
 * control with more content still grows.
 */
export const TOUCH = "min-h-11";

/**
 * A description that costs one line on a small screen.
 *
 * Below `md` the text is clamped and a toggle reveals the rest; from `md` up
 * the clamp is off and the toggle is not rendered at all, so the desktop
 * reading experience is unchanged and no measurement is involved. The toggle
 * is always offered rather than only when the text overflows: knowing whether
 * it overflows means measuring after layout, and a control that appears and
 * disappears as the text reflows is worse than one that is always there.
 */
export function Prose({
  children,
  className = "text-sm text-muted-foreground",
}: {
  children: ReactNode;
  className?: string;
}) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="min-w-0">
      <p className={`${className} ${expanded ? "" : "line-clamp-1 md:line-clamp-none"}`}>
        {children}
      </p>
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        aria-expanded={expanded}
        className={`${TOUCH} -mb-2 inline-flex items-center text-xs font-medium text-muted-foreground underline underline-offset-2 md:hidden`}
      >
        {expanded ? "Show less" : "Show more"}
      </button>
    </div>
  );
}

/**
 * One refresh for the page, rather than one per card.
 *
 * Every panel polls on its own timer and each carried its own button, which on
 * a narrow screen meant a row of identical controls competing with the titles
 * they sat beside. React Query already knows which queries this page mounted,
 * so refetching the active ones is exactly "refresh what I am looking at" —
 * and it is one control whatever the page happens to contain.
 */
export function RefreshButton() {
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);

  async function refresh() {
    setBusy(true);
    try {
      await queryClient.refetchQueries({ type: "active" });
    } finally {
      setBusy(false);
    }
  }

  return (
    <button
      onClick={refresh}
      disabled={busy}
      className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium disabled:opacity-50`}
    >
      {busy ? "Refreshing…" : "Refresh"}
    </button>
  );
}

export function PageHeader({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-wrap items-start justify-between gap-3">
      <div className="min-w-0 flex-1">
        <h1 className="text-xl font-semibold">{title}</h1>
        {children ? <Prose className="mt-1 text-sm text-muted-foreground">{children}</Prose> : null}
      </div>
      <RefreshButton />
    </div>
  );
}

/**
 * An empty state that offers the thing to do next.
 *
 * "Nothing here" is a fact; it is only useful next to the action that changes
 * it. Where there is genuinely nothing to offer — a report that is empty
 * because the system is healthy — the action is omitted rather than invented.
 */
export function EmptyState({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-sm text-muted-foreground">{message}</p>
      {action}
    </div>
  );
}

export function EmptyAction({
  onClick,
  disabled,
  children,
}: {
  onClick: () => void;
  disabled?: boolean;
  children: ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`${TOUCH} inline-flex items-center justify-center rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
    >
      {children}
    </button>
  );
}
