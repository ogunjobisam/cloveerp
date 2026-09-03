import { Link } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, LayoutGrid, Search, X } from "lucide-react";

import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { usePlatformOrganisation } from "../../lib/platform-organisation";
import { GROUP_BLURBS, iconFor } from "../../lib/module-icons";
import {
  GROUP_LABELS,
  SETTINGS_GROUPS,
  WORK_GROUPS,
  allTiles,
  areaOf,
  type Area,
  type TileDef,
  type TileGroup,
} from "../../lib/modules";
import { TOUCH } from "./page";
import { useErpSession } from "./session-context";

/**
 * The whole product on one screen.
 *
 * The rail shows the area you are in and the palette takes you somewhere you
 * can already name. Neither answers "what is in here?", which is the question
 * somebody has in their first fortnight and again every time they need a screen
 * they have not opened before. Forty-four screens across eleven groups is more
 * than a rail can hold and more than a person can be expected to have memorised
 * before they are allowed to look.
 *
 * So this is the third device, and it is the one Sage X3 gets right: every
 * function at once, an area column beside a tree, and a search over the whole
 * thing rather than over the branch you happen to have open. What is borrowed
 * is the shape. The words, the warmth and the rust are this product's own.
 *
 * Two rules it keeps from everything else here. A screen the account cannot
 * open is not listed, because an entry that leads to a refusal is worse than no
 * entry. And every visible word goes through ui(), so an organisation that
 * renames Stock to Inventory renames it here too.
 */

type Section = { group: TileGroup; area: Area; tiles: TileDef[] };

/** How well `q` matches `text`: 2 for a prefix, 1 for anywhere, 0 for not. */
function score(text: string, q: string): number {
  const t = text.toLowerCase();
  if (t.startsWith(q)) return 2;
  return t.includes(q) ? 1 : 0;
}

function Screen({ tile, onGo }: { tile: TileDef; onGo: () => void }) {
  const { t, ui } = useT();
  const Icon = iconFor(tile.path);
  return (
    <Link
      to={tile.path}
      onClick={onGo}
      className={`${TOUCH} group flex min-w-0 items-start gap-2.5 rounded-lg border border-transparent px-2.5 py-2 transition-colors hover:border-accent/40 hover:bg-accent/5`}
    >
      <span className="mt-0.5 grid size-6 shrink-0 place-items-center rounded-md bg-accent/10 text-accent transition-colors group-hover:bg-accent group-hover:text-accent-foreground">
        <Icon className="size-3.5" />
      </span>
      <span className="flex min-w-0 flex-col">
        <span className="truncate text-sm font-medium leading-snug text-foreground">
          {t(tile.titleKey, tile.title)}
        </span>
        <span className="line-clamp-1 text-xs leading-relaxed text-muted-foreground">
          {ui(tile.blurb)}
        </span>
      </span>
    </Link>
  );
}

export function MainMenu() {
  const { session } = useErpSession();
  const { t, ui } = useT();
  const platform = usePlatformOrganisation(Boolean(session?.tenant_id));

  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [area, setArea] = useState<Area>("work");
  const [collapsed, setCollapsed] = useState<Set<TileGroup>>(new Set());
  const inputRef = useRef<HTMLInputElement>(null);
  const paneRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (!open) return undefined;
    setQ("");
    setCollapsed(new Set());
    const id = window.setTimeout(() => inputRef.current?.focus(), 0);
    return () => window.clearTimeout(id);
  }, [open]);

  const visible = useMemo(
    () =>
      allTiles().filter(
        (x) =>
          (!x.permission || hasPermission(session, x.permission)) && (!x.platformOnly || platform),
      ),
    [session, platform],
  );

  const query = q.trim().toLowerCase();

  // Searching looks across both areas, because somebody hunting for the audit
  // log should not have to know it lives under Settings first.
  const matches = useMemo(() => {
    if (!query) return null;
    return visible.filter(
      (x) =>
        score(t(x.titleKey, x.title), query) > 0 ||
        score(ui(x.blurb), query) > 0 ||
        score(ui(GROUP_LABELS[x.group]), query) > 0,
    );
  }, [visible, query, t, ui]);

  const sections: Section[] = useMemo(() => {
    const pool = matches ?? visible;
    const groups = matches
      ? [...WORK_GROUPS, ...SETTINGS_GROUPS]
      : area === "work"
        ? WORK_GROUPS
        : SETTINGS_GROUPS;
    return groups
      .map((group) => ({
        group,
        area: areaOf(group),
        tiles: pool.filter((x) => x.group === group),
      }))
      .filter((s) => s.tiles.length > 0);
  }, [matches, visible, area]);

  const counts: Record<Area, number> = {
    work: visible.filter((x) => areaOf(x.group) === "work").length,
    settings: visible.filter((x) => areaOf(x.group) === "settings").length,
  };

  const close = () => setOpen(false);
  const toggle = (group: TileGroup) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(group)) next.delete(group);
      else next.add(group);
      return next;
    });

  const jumpTo = (group: TileGroup) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      next.delete(group);
      return next;
    });
    window.setTimeout(() => {
      paneRef.current
        ?.querySelector(`[data-group="${group}"]`)
        ?.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 0);
  };

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label={ui("Menu")}
        aria-expanded={open}
        className={`${TOUCH} inline-flex shrink-0 items-center gap-1.5 rounded-md px-2 text-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground`}
      >
        <LayoutGrid className="size-4" />
        <span className="hidden lg:inline">{ui("Menu")}</span>
      </button>

      {open && typeof document !== "undefined"
        ? createPortal(
            /*
             * Rendered into the body rather than where it is written.
             *
             * This component lives in the shell's header, and that header
             * carries backdrop-blur. A backdrop filter makes an element a
             * containing block for position: fixed, so an overlay rendered
             * inside it is not pinned to the viewport at all — it is pinned to
             * the header, and inset-0 resolves to a 88px strip. The overlay
             * still opened, still trapped focus and still listed every screen;
             * it was simply drawn inside a box the height of the bar it was
             * launched from. Nothing reports that, which is why it has to be
             * measured rather than reasoned about.
             */
            <div
              role="dialog"
              aria-modal="true"
              aria-label={ui("Menu")}
              className="fixed inset-0 z-50 flex flex-col bg-background/80 pt-14 backdrop-blur-sm"
              onClick={close}
            >
              {/*
                flex-1 and min-h-0 rather than a height: both the area column
                and the tree scroll, so neither contributes to an intrinsic
                height, and a panel sized by its content collapses to the bar
                alone with the whole menu behind it. The pt-14 above leaves the
                product's own header showing through the blur — this is a sheet
                over the product, not a replacement for it.
              */}
              <div
                className="mx-auto flex min-h-0 w-full max-w-6xl flex-1 flex-col overflow-hidden rounded-t-2xl border border-border bg-card shadow-2xl"
                onClick={(e) => e.stopPropagation()}
              >
                {/* ── The bar: search, then the two controls X3 puts beside it ── */}
                <div className="flex flex-wrap items-center gap-2 border-b border-border px-3 py-2.5 sm:gap-3 sm:px-4">
                  <span className="hidden font-display text-sm font-semibold sm:inline">
                    {ui("Menu")}
                  </span>
                  <div className="relative flex min-w-0 flex-1 items-center">
                    <Search className="pointer-events-none absolute left-2.5 size-4 text-muted-foreground" />
                    {/*
                      id and aria-label come before onChange deliberately, as
                      they do on the palette's field. The accessibility check
                      in src/lib/accessibility.test.ts reads the source rather
                      than a rendered tree, and its attribute pattern stops at
                      the first ">" — which, in an inline arrow handler, is the
                      one in "=>". Anything written after the handler is
                      invisible to it, so a labelled field reads as unlabelled.
                    */}
                    <input
                      id="main-menu-query"
                      aria-label={ui("Search the menu")}
                      ref={inputRef}
                      value={q}
                      onChange={(e) => setQ(e.target.value)}
                      placeholder={ui("Search the menu")}
                      className="w-full rounded-md border border-input bg-background py-2 pl-8 pr-3 text-sm"
                    />
                  </div>
                  {query ? (
                    <span className="shrink-0 font-mono text-xs text-muted-foreground">
                      {matches?.length ?? 0}
                    </span>
                  ) : null}
                  <div className="flex shrink-0 items-center gap-1">
                    <button
                      type="button"
                      onClick={() => setCollapsed(new Set(sections.map((s) => s.group)))}
                      className={`${TOUCH} rounded-md border border-input px-2.5 text-xs font-medium hover:border-accent/50`}
                    >
                      {ui("Collapse all")}
                    </button>
                    <button
                      type="button"
                      onClick={() => setCollapsed(new Set())}
                      className={`${TOUCH} rounded-md border border-input px-2.5 text-xs font-medium hover:border-accent/50`}
                    >
                      {ui("Expand all")}
                    </button>
                    <button
                      type="button"
                      onClick={close}
                      aria-label={ui("Close")}
                      className={`${TOUCH} inline-flex w-9 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground`}
                    >
                      <X className="size-4" />
                    </button>
                  </div>
                </div>

                <div className="flex min-h-0 flex-1">
                  {/* ── The area column ─────────────────────────────────────── */}
                  <nav
                    aria-label={ui("Areas")}
                    className="hidden w-56 shrink-0 overflow-y-auto border-r border-border bg-muted/30 py-2 md:block"
                  >
                    {(["work", "settings"] as Area[]).map((a) => (
                      <div key={a} className="mb-1 last:mb-0">
                        <button
                          type="button"
                          onClick={() => {
                            setArea(a);
                            setQ("");
                          }}
                          className={`${TOUCH} flex w-full items-center justify-between gap-2 px-3 text-left text-sm font-semibold transition-colors ${
                            area === a && !query
                              ? "border-l-2 border-accent bg-accent/10 text-foreground"
                              : "border-l-2 border-transparent text-muted-foreground hover:text-foreground"
                          }`}
                        >
                          <span>{a === "work" ? ui("Work") : ui("Settings")}</span>
                          <span className="font-mono text-xs opacity-70">{counts[a]}</span>
                        </button>
                        {area === a && !query
                          ? (a === "work" ? WORK_GROUPS : SETTINGS_GROUPS)
                              .filter((g) => visible.some((x) => x.group === g))
                              .map((g) => (
                                <button
                                  key={g}
                                  type="button"
                                  onClick={() => jumpTo(g)}
                                  className={`${TOUCH} flex w-full items-center justify-between gap-2 py-1.5 pl-6 pr-3 text-left text-xs text-muted-foreground transition-colors hover:text-accent`}
                                >
                                  <span className="truncate">{ui(GROUP_LABELS[g])}</span>
                                  <span className="font-mono opacity-60">
                                    {visible.filter((x) => x.group === g).length}
                                  </span>
                                </button>
                              ))
                          : null}
                      </div>
                    ))}
                  </nav>

                  {/* ── The tree ────────────────────────────────────────────── */}
                  <div ref={paneRef} className="min-w-0 flex-1 overflow-y-auto px-3 py-3 sm:px-5">
                    {sections.length === 0 ? (
                      <p className="px-1 py-8 text-center text-sm text-muted-foreground">
                        {ui("Nothing here matches that. Try the word another system would use.")}
                      </p>
                    ) : (
                      sections.map((section) => {
                        const shut = collapsed.has(section.group);
                        return (
                          <section
                            key={section.group}
                            data-group={section.group}
                            className="mb-4 last:mb-0"
                          >
                            <button
                              type="button"
                              onClick={() => toggle(section.group)}
                              aria-expanded={!shut}
                              className="flex w-full items-baseline gap-2 border-b border-border pb-1.5 text-left"
                            >
                              <ChevronDown
                                className={`size-3.5 shrink-0 text-muted-foreground transition-transform ${shut ? "-rotate-90" : ""}`}
                              />
                              <h2 className="font-display text-sm font-semibold tracking-tight">
                                {ui(GROUP_LABELS[section.group])}
                              </h2>
                              <p className="hidden truncate text-xs text-muted-foreground sm:block">
                                {ui(GROUP_BLURBS[section.group])}
                              </p>
                              <span className="ml-auto shrink-0 font-mono text-xs text-muted-foreground">
                                {section.tiles.length}
                              </span>
                            </button>
                            {shut ? null : (
                              <div className="mt-1.5 grid grid-cols-1 gap-x-4 gap-y-0.5 sm:grid-cols-2 xl:grid-cols-3">
                                {section.tiles.map((tile) => (
                                  <Screen key={tile.path} tile={tile} onGo={close} />
                                ))}
                              </div>
                            )}
                          </section>
                        );
                      })
                    )}
                  </div>
                </div>
              </div>
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
