import { useQueryClient } from "@tanstack/react-query";
import { useRouterState } from "@tanstack/react-router";
import { useContext, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";

import { useT } from "../../lib/i18n";
import { HelpContext, PageHeaderExtras } from "./page-extras";

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
 * A description that costs one line on a small screen and two on a wide one.
 *
 * The text is clamped at every width — one line below `md`, two from `md` up —
 * and a toggle reveals the rest. The toggle is drawn only where there is a rest
 * to reveal: the paragraph is measured after layout, and again whenever its box
 * or its words change, so a sentence that fits carries no control at all. Text
 * that has been opened keeps its toggle whatever the measurement says, so what
 * was opened can always be closed.
 *
 * It used to be clamped on a phone only, with the toggle always there. A wide
 * screen then paid for every description in full on every visit, and a phone
 * offered "Show more" over sentences that had no more to show.
 */
export function Prose({
  children,
  className = "text-sm text-muted-foreground",
}: {
  children: ReactNode;
  className?: string;
}) {
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const text = useRef<HTMLParagraphElement | null>(null);

  useLayoutEffect(() => {
    const el = text.current;
    // Open text has no clamp to measure against; the last answer stands until
    // it is closed again.
    if (!el || expanded) return;
    let live = true;
    // A pixel of tolerance: both heights are rounded, and at a fractional zoom
    // they can round apart over text that fits.
    const measure = () => {
      if (live) setOverflows(el.scrollHeight > el.clientHeight + 1);
    };
    measure();
    // The web fonts swap in after first paint and can push a line over.
    void document.fonts?.ready.then(measure);
    if (typeof ResizeObserver === "undefined") {
      return () => {
        live = false;
      };
    }
    // Also how a description inside something closed — a folded inquiry, a
    // hidden tab — gets measured: it has no box until it is shown.
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => {
      live = false;
      observer.disconnect();
    };
  }, [expanded, children]);

  return (
    <div className="min-w-0">
      <p ref={text} className={`${className} ${expanded ? "" : "line-clamp-1 md:line-clamp-2"}`}>
        {children}
      </p>
      {overflows || expanded ? (
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          aria-expanded={expanded}
          className={`${TOUCH} -mb-2 inline-flex items-center text-xs font-medium text-muted-foreground underline underline-offset-2`}
        >
          {expanded ? "Show less" : "Show more"}
        </button>
      ) : null}
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
      className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-lg border border-input bg-card px-4 text-sm font-medium shadow-[var(--shadow-card)] transition-colors hover:border-accent/50 hover:text-accent disabled:opacity-50`}
    >
      {busy ? "Refreshing…" : "Refresh"}
    </button>
  );
}

/**
 * What a panel shows while its read is on the way: the shape of what is coming.
 *
 * One page used three treatments at once — panels that said "Loading…", tiles
 * with a label over a blank, and a button that did not exist until its data
 * arrived and then appeared under a moving cursor. A skeleton says something is
 * coming and roughly how much, keeps the page from jumping when it lands, and
 * says "Loading" to a screen reader without saying it to everybody else.
 */
export function LoadingRows({ rows = 3, className = "" }: { rows?: number; className?: string }) {
  return (
    <div role="status" aria-live="polite" className={`flex flex-col gap-2 ${className}`}>
      <span className="sr-only">Loading</span>
      {Array.from({ length: rows }, (_, i) => (
        <div
          key={i}
          aria-hidden="true"
          className="h-4 animate-pulse rounded bg-muted"
          style={{ width: `${92 - i * 14}%` }}
        />
      ))}
    </div>
  );
}

/**
 * Hand a screen's "how this works" to the header's help sheet while the screen
 * is showing, and say how to open it. Returns null when there is nothing to
 * hand, or no shell to hand it to.
 */
export function useHowItWorks(text: string | undefined): (() => void) | null {
  const help = useContext(HelpContext);
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const setDetail = help?.setDetail;
  useEffect(() => {
    if (!setDetail || !text) return;
    setDetail({ path: pathname, paragraphs: [text] });
    return () => setDetail(null);
  }, [setDetail, text, pathname]);
  return help && text ? () => help.setOpen(true) : null;
}

/** The link under a screen's one sentence that opens the rest. */
export function HowItWorksLink({ open }: { open: (() => void) | null }) {
  const { ui } = useT();
  if (!open) return null;
  return (
    <button
      type="button"
      onClick={open}
      className="mt-1 text-xs font-medium text-muted-foreground underline underline-offset-2 hover:text-foreground"
    >
      {ui("How this works")}
    </button>
  );
}

export function PageHeader({
  title,
  children,
  actions,
  howItWorks,
}: {
  title: string;
  /** One sentence: what the screen is for. The rest belongs in howItWorks. */
  children?: ReactNode;
  /**
   * Everything a screen used to say after its first sentence. Shown behind the
   * header's help icon under "How this works", reached from a link here.
   */
  howItWorks?: string;
  /**
   * Controls that belong to the page rather than to any panel on it — the
   * Actions panel, mostly — drawn beside Refresh, where the module pages draw
   * theirs, so a screen built on this header and one built on ModulePage put
   * the same control in the same place.
   */
  actions?: ReactNode;
}) {
  const Extras = useContext(PageHeaderExtras);
  const openHelp = useHowItWorks(howItWorks);
  return (
    <div className="flex min-w-0 flex-wrap items-start justify-between gap-3">
      <div className="min-w-0 flex-1">
        <h1 className="font-display text-2xl font-semibold tracking-tight">{title}</h1>
        {children ? <Prose className="mt-1 text-sm text-muted-foreground">{children}</Prose> : null}
        <HowItWorksLink open={openHelp} />
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {Extras ? <Extras /> : null}
        {actions}
        <RefreshButton />
      </div>
    </div>
  );
}

/**
 * An empty state that offers the thing to do next.
 *
 * "Nothing here" is a fact; it is only useful next to the action that changes
 * it. Where there is genuinely nothing to offer — a report that is empty
 * because the system is healthy — the action is omitted rather than invented.
 *
 * The action itself is an `ActionButton` from ./action. There was an
 * `EmptyAction` here once; it was exported, imported by nothing, and every
 * call site hand-rolled the same classes regardless. One button definition
 * is better than two, and better than two of which one is unused.
 */
export function EmptyState({ message, action }: { message: string; action?: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3">
      <p className="text-sm text-muted-foreground">{message}</p>
      {action}
    </div>
  );
}
