import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { Search } from "lucide-react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { GROUP_LABELS, allTiles, type TileDef } from "../../lib/modules";
import { GLOSSARY_DESTINATION } from "../../lib/modules";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";

/**
 * Go anywhere by typing what you call it.
 *
 * Thirty-four screens is more than a rail can make scannable, and the honest
 * problem with a rail is that it only helps somebody who already knows the
 * word the product chose. This product chose UK ERP words deliberately —
 * Stock, not Inventory; Product, not Item; Despatch, not Shipment — and
 * erp_ref.vocabulary records the words other systems use as aliases precisely
 * so that choice does not strand the people it was made for.
 *
 * So the palette searches two things. The screens, by title and description.
 * And the glossary, by term, definition and alias — which means somebody
 * arriving from another system types "inventory" and is offered Stock, with
 * the rename shown rather than silently applied. A search that quietly
 * corrected the word would teach nothing; one that says "Inventory is called
 * Stock here" teaches it once.
 *
 * Permission-filtered like the rail: a screen the account cannot open is not
 * offered, because an entry that leads to a refusal is worse than no entry.
 */

type GlossaryTerm = {
  code: string;
  surface: string;
  term: string | null;
  aliases: string[] | null;
  definition: string | null;
};

type Hit =
  | { kind: "screen"; path: string; title: string; detail: string }
  | { kind: "term"; path: string; title: string; detail: string; matched: string };

/** How well `q` matches `text`: 2 for a prefix, 1 for anywhere, 0 for not. */
function score(text: string, q: string): number {
  const t = text.toLowerCase();
  if (t.startsWith(q)) return 2;
  return t.includes(q) ? 1 : 0;
}

/*
 * One palette, however many buttons open it.
 *
 * The shell mounts this twice — as a field in the header on a wide screen and
 * as an icon on a narrow one — and each instance bound its own Cmd/Ctrl-K
 * listener and portalled its own dialog. Both are in the DOM at every width,
 * because the wrappers that hide one of them are CSS on the trigger and the
 * dialog escapes to the body, so the shortcut opened two modals with the same
 * accessible name stacked on each other. A screen reader was offered two
 * "Search screens" dialogs and the browser suite caught it as a strict-mode
 * violation before a person had to.
 *
 * So the open state lives here, once, and only the icon variant draws the
 * dialog. Both buttons still open it; there is only ever one of it.
 */
let paletteOpen = false;
const paletteListeners = new Set<() => void>();

function subscribePalette(listener: () => void) {
  paletteListeners.add(listener);
  return () => {
    paletteListeners.delete(listener);
  };
}

function readPalette() {
  return paletteOpen;
}

// The server renders nothing open, and hydration must agree with it.
function readPaletteOnServer() {
  return false;
}

function setPaletteOpen(next: boolean | ((previous: boolean) => boolean)) {
  paletteOpen = typeof next === "function" ? next(paletteOpen) : next;
  for (const listener of paletteListeners) listener();
}

export function CommandPalette({ variant = "icon" }: { variant?: "icon" | "field" }) {
  const { session } = useErpSession();
  const { t, ui } = useT();
  const navigate = useNavigate();
  const open = useSyncExternalStore(subscribePalette, readPalette, readPaletteOnServer);
  const setOpen = setPaletteOpen;
  const [q, setQ] = useState("");
  const [cursor, setCursor] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  // The glossary is small, product content, and changes about never, so it is
  // fetched once and kept. It is only read when the palette has been opened.
  const glossary = useQuery({
    queryKey: ["erp_glossary", {}],
    queryFn: () => callErp<GlossaryTerm[]>("erp_glossary"),
    enabled: open,
    staleTime: 30 * 60_000,
  });

  // Bound by the instance that draws the dialog, and only that one.
  //
  // Moving the open state into a module store fixed two dialogs and created a
  // subtler fault in their place: both instances still bound this listener, so
  // one Cmd/Ctrl-K toggled the shared state twice — true, then false — and the
  // palette stopped opening at all. The browser suite caught it as "element(s)
  // not found" where it had previously said "resolved to 2 elements".
  //
  // One owner for the state, one owner for the shortcut. The field variant is
  // a button that opens it, nothing more.
  useEffect(() => {
    if (variant !== "icon") return undefined;
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [variant]);

  useEffect(() => {
    if (open) {
      setQ("");
      setCursor(0);
      // The field has to be focused after the dialog paints, or the first
      // keystroke goes nowhere.
      const id = window.setTimeout(() => inputRef.current?.focus(), 0);
      return () => window.clearTimeout(id);
    }
    return undefined;
  }, [open]);

  const tiles = useMemo(
    () =>
      allTiles().filter(
        (tile: TileDef) => !tile.permission || hasPermission(session, tile.permission),
      ),
    [session],
  );

  const hits = useMemo<Hit[]>(() => {
    const query = q.trim().toLowerCase();
    const paths = new Set(tiles.map((x) => x.path));

    const screens = tiles.map((tile) => {
      const title = t(tile.titleKey, tile.title);
      const group = GROUP_LABELS[tile.group];
      const s = query
        ? Math.max(score(title, query) * 3, score(tile.blurb, query), score(group, query) * 2)
        : 1;
      return { s, hit: { kind: "screen" as const, path: tile.path, title, detail: tile.blurb } };
    });

    // A glossary term earns a row only when it leads somewhere and the word
    // typed is not already the word the product uses — otherwise it would
    // duplicate the screen above it.
    const terms = (glossary.data ?? [])
      .filter((g) => g.term && GLOSSARY_DESTINATION[g.code])
      .flatMap((g) => {
        const dest = GLOSSARY_DESTINATION[g.code]!;
        if (!paths.has(dest) || !query) return [];
        const alias = (g.aliases ?? []).find((a) => score(a, query) > 0);
        const onTerm = score(g.term!, query);
        if (!alias && !onTerm) return [];
        if (alias && score(g.term!, query) === 2) return [];
        return [
          {
            s: alias ? 2 : 1,
            hit: {
              kind: "term" as const,
              path: dest,
              title: g.term!,
              detail: g.definition ?? "",
              matched: alias ?? g.term!,
            },
          },
        ];
      });

    return [...screens, ...terms]
      .filter((r) => r.s > 0)
      .sort((a, b) => b.s - a.s || a.hit.title.localeCompare(b.hit.title))
      .slice(0, 12)
      .map((r) => r.hit);
  }, [tiles, glossary.data, q, t]);

  function go(hit: Hit) {
    setOpen(false);
    void navigate({ to: hit.path });
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label={ui("Search screens")}
        // Two shapes, one control. In the header it reads as a search field,
        // which is what people look for; anywhere else it stays the compact
        // icon it always was. The shortcut is the only place anyone learns the
        // palette has one at all.
        className={
          variant === "field"
            ? `${TOUCH} flex w-full items-center gap-2 rounded-lg border border-border bg-soft px-3 text-sm text-muted-foreground transition-colors hover:border-input`
            : `${TOUCH} inline-flex shrink-0 items-center gap-1.5 rounded-l-md px-2.5 text-sm text-muted-foreground hover:bg-muted hover:text-foreground`
        }
      >
        <Search className="size-4 shrink-0" aria-hidden="true" />
        {variant === "field" ? (
          <span className="min-w-0 flex-1 truncate text-left">{ui("Search Clove ERP…")}</span>
        ) : null}
        <kbd className="hidden rounded border border-border px-1 font-mono text-[10px] lg:inline">
          ⌘K
        </kbd>
      </button>

      {open && variant === "icon" && typeof document !== "undefined"
        ? createPortal(
            /*
             * Into the body, for the same reason the main menu is.
             *
             * This button lives in the shell's header, and that header carries
             * backdrop-blur. A backdrop filter makes an element a containing
             * block for position: fixed, so inset-0 resolved to the header's
             * own 116px strip rather than the viewport. The palette looked
             * right — the panel overflows the header and draws over the page —
             * but the scrim dimmed only the strip, and clicking the page below
             * it did not close anything. A dialog whose backdrop does not cover
             * what it is covering is the same class of fault as a screen
             * stating a condition it is not in.
             */
            <div
              className="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[10vh]"
              onClick={() => setOpen(false)}
            >
              <div
                role="dialog"
                aria-modal="true"
                aria-label={ui("Search screens")}
                className="w-full max-w-lg overflow-hidden rounded-xl border border-border bg-card shadow-lg"
                onClick={(e) => e.stopPropagation()}
              >
                <div className="flex items-center gap-2 border-b border-border px-3">
                  <Search className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                  <input
                    id="command-palette-query"
                    ref={inputRef}
                    value={q}
                    onChange={(e) => {
                      setQ(e.target.value);
                      setCursor(0);
                    }}
                    onKeyDown={(e) => {
                      if (e.key === "ArrowDown") {
                        e.preventDefault();
                        setCursor((c) => Math.min(c + 1, hits.length - 1));
                      } else if (e.key === "ArrowUp") {
                        e.preventDefault();
                        setCursor((c) => Math.max(c - 1, 0));
                      } else if (e.key === "Enter" && hits[cursor]) {
                        e.preventDefault();
                        go(hits[cursor]);
                      }
                    }}
                    aria-label={ui("Search screens")}
                    placeholder={ui("Go to a screen, or type what you call it")}
                    className="h-12 w-full bg-transparent text-sm placeholder:text-muted-foreground"
                  />
                </div>

                <ul className="max-h-[50vh] overflow-y-auto py-1">
                  {hits.length === 0 ? (
                    <li className="px-4 py-6 text-sm text-muted-foreground">
                      {ui("Nothing matches that. Try the word another system would use for it.")}
                    </li>
                  ) : (
                    hits.map((hit, i) => (
                      <li key={`${hit.kind}-${hit.path}-${hit.title}`}>
                        <button
                          type="button"
                          onClick={() => go(hit)}
                          onMouseEnter={() => setCursor(i)}
                          className={`flex w-full flex-col items-start gap-0.5 px-4 py-2 text-left ${
                            i === cursor ? "bg-muted" : ""
                          }`}
                        >
                          <span className="flex min-w-0 items-baseline gap-2">
                            <span className="truncate text-sm font-medium">{hit.title}</span>
                            {hit.kind === "term" ? (
                              // Say the rename rather than performing it silently.
                              // One whole phrase with the alias beside it, not
                              // "{x} is called {y} here" assembled from fragments a
                              // translator cannot reorder.
                              <span className="shrink-0 text-xs text-muted-foreground">
                                {ui("Also known as")} {hit.matched}
                              </span>
                            ) : null}
                          </span>
                          {hit.detail ? (
                            <span className="line-clamp-1 text-xs text-muted-foreground">
                              {hit.detail}
                            </span>
                          ) : null}
                        </button>
                      </li>
                    ))
                  )}
                </ul>
              </div>
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
