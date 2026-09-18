import { useQuery } from "@tanstack/react-query";
import { useNavigate, useRouterState } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { GROUP_LABELS, allTiles } from "../../lib/modules";
import { documentIdInPath } from "../../lib/plain-words";
import { useConfirmLeave } from "./unsaved";

/**
 * Where you are, and the way back.
 *
 * The trail is derived from the module registry rather than from the URL's
 * spelling, so a screen is named here exactly as it is named on the rail and
 * the launchpad. Anything below a registered screen keeps its own segment,
 * titled from the path, because a deep screen with no crumb is a dead end.
 *
 * Every crumb asks before it leaves: if the screen is holding something
 * half-typed, the person is asked whether to discard it, and "no" keeps them
 * exactly where they were.
 */

/** Screens outside the tile registry that still deserve a name. */
const EXTRA_NAMES: Record<string, string> = {
  "/settings": "Settings",
  "/profile": "Your profile",
  "/notifications": "Notifications",
  "/help": "Help and guides",
  "/device": "This device",
  "/platform": "Platform",
};

function titleise(segment: string): string {
  const words = segment.replace(/[-_]/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/**
 * One crumb. A crumb with no destination is a heading in the trail rather than
 * a place: the group a screen sits in — Move, Source, Sell — which is how the
 * rail files it and has no screen of its own to go to.
 */
type Crumb = { to: string | null; label: string };

/**
 * `names` labels a segment the path spells as an identifier: a document's page
 * is /documents/<uuid>, and its crumb is the document's number, not the first
 * eight characters of a UUID titled like a word.
 */
function trailFor(pathname: string, names: Readonly<Record<string, string>> = {}): Crumb[] {
  const crumbs: Crumb[] = [];
  const tiles = allTiles();
  const settings = pathname === "/settings" || pathname.startsWith("/settings/");

  crumbs.push(settings ? { to: "/settings", label: "Settings" } : { to: "/", label: "Home" });

  // Every registered screen that this path sits on or under, outermost first.
  const onPath = tiles
    .filter((t) => pathname === t.path || pathname.startsWith(`${t.path}/`))
    .sort((a, b) => a.path.length - b.path.length);

  // The group the outermost screen is filed under, said once, where the rail
  // says it. The trail used to be two trails: this one, Home > Stock, above
  // the page, and the module page's own, Home / Move / Stock, inside it. Two
  // trails that disagree about depth is one too many, and Purchasing — which
  // has no module page — showed only Home / Purchasing, one level shallower
  // than Stock for no reason a person could see. One trail, every screen, the
  // same depth.
  const outermost = onPath.find((t) => t.path !== crumbs[0]?.to);
  if (outermost) crumbs.push({ to: null, label: GROUP_LABELS[outermost.group] });

  for (const tile of onPath) {
    if (tile.path === crumbs[0]?.to) continue;
    crumbs.push({ to: tile.path, label: tile.title });
  }

  // Whatever is left of the path below the deepest registered screen.
  const covered = crumbs[crumbs.length - 1]?.to ?? "/";
  const rest = pathname
    .slice(covered === "/" ? 0 : covered.length)
    .split("/")
    .filter(Boolean);

  let walked = covered === "/" ? "" : covered;
  for (const segment of rest) {
    walked = `${walked}/${segment}`;
    const named = names[walked] ?? EXTRA_NAMES[walked];
    crumbs.push({ to: walked, label: named ?? titleise(segment) });
  }

  return crumbs;
}

export function Breadcrumbs() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const navigate = useNavigate();
  const confirmLeave = useConfirmLeave();
  const { ui } = useT();

  // The document page's own read, shared through its query key, so the crumb
  // costs nothing the page does not already ask for.
  const documentId = documentIdInPath(pathname);
  const { data: opened } = useQuery({
    queryKey: ["erp_document", { p_document_id: documentId ?? "" }],
    queryFn: () =>
      callErp<{ document: { document_number?: string } | null }>("erp_document", {
        p_document_id: documentId,
      }),
    enabled: documentId !== null,
  });
  const documentNumber = opened?.document?.document_number;
  const names: Record<string, string> = documentId
    ? { [`/documents/${documentId}`]: documentNumber ?? "Document" }
    : {};

  const crumbs = trailFor(pathname, names);
  if (crumbs.length < 2) return null;

  const go = async (to: string) => {
    if (to === pathname) return;
    if (!(await confirmLeave())) return;
    void navigate({ to });
  };

  return (
    <nav aria-label="Breadcrumb" className="mb-4">
      <ol className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
        {crumbs.map((crumb, i) => {
          const last = i === crumbs.length - 1;
          const to = crumb.to;
          return (
            <li key={to ?? `group-${crumb.label}`} className="flex items-center gap-1">
              {i > 0 ? <ChevronRight aria-hidden className="size-3.5 shrink-0 opacity-60" /> : null}
              {last ? (
                <span aria-current="page" className="font-medium text-foreground">
                  {ui(crumb.label)}
                </span>
              ) : to === null ? (
                <span className="px-1 py-0.5">{ui(crumb.label)}</span>
              ) : (
                <button
                  type="button"
                  onClick={() => void go(to)}
                  className="rounded-sm px-1 py-0.5 underline-offset-2 hover:text-foreground hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
                >
                  {ui(crumb.label)}
                </button>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
