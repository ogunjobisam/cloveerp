import { AREA_HOME, GROUP_LABELS, allTiles, areaOf, type Area, type TileDef } from "./modules";

/**
 * Where a screen is filed, said once for the rail and the trail.
 *
 * The Work rail listed every screen at the same depth, so Financials sat
 * beside its own Journals, VAT and Close as if they were five jobs rather
 * than one job and four of its parts. A screen whose path sits under another
 * screen of the same group is now folded under it on the rail, and the trail
 * above the page files a path by the same rule, so the two cannot disagree
 * about where a screen lives (J-130: Warehouse layout is a Settings screen
 * under Products and places, not a part of Stock because its path happens to
 * start /inventory).
 */

/**
 * The screen a path folds under on the rail: the longest other path in
 * `among`, of the same group as the path's own entry, that the path sits
 * under. A screen whose own entry is not in `among`, or which sits under
 * nothing of its own group, folds under nothing and stays at the top of its
 * group.
 */
export function railParent(
  path: string,
  among: readonly { readonly path: string; readonly group: string }[],
): string | null {
  const self = among.find((t) => t.path === path);
  if (!self) return null;
  let parent: string | null = null;
  for (const t of among) {
    if (t.path === path || t.group !== self.group) continue;
    if (!path.startsWith(`${t.path}/`)) continue;
    if (parent === null || t.path.length > parent.length) parent = t.path;
  }
  return parent;
}

/**
 * One crumb. A crumb with no destination is a heading in the trail rather than
 * a place: the group a screen sits in — Move, Source, Sell — which is how the
 * rail files it and has no screen of its own to go to.
 */
export type Crumb = { to: string | null; label: string };

/** Each area's home, as the rail names it. */
const HOME_LABELS: Record<Area, string> = { work: "Home", settings: "Settings" };

/** Screens outside the tile registry that still deserve a name. */
const EXTRA_NAMES: Record<string, string> = {
  "/settings": "Settings",
  "/profile": "Your profile",
  "/help": "Help and guides",
  "/platform": "Platform",
};

function titleise(segment: string): string {
  const words = segment.replace(/[-_]/g, " ").trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** The registered screens a path sits on or under, outermost first. */
function tilesOnPath(pathname: string, tiles: readonly TileDef[]): TileDef[] {
  return tiles
    .filter((t) => pathname === t.path || pathname.startsWith(`${t.path}/`))
    .sort((a, b) => a.path.length - b.path.length);
}

/**
 * The trail above a page, derived from the module registry rather than from
 * the URL's spelling, so a screen is named here exactly as it is named on the
 * rail and the launchpad.
 *
 * A path is filed by the deepest registered screen it sits on that is kept on
 * the rail — the rule the shell uses to decide which area a path is in. The
 * trail is that screen's area home, its group, the screens it folds under on
 * the rail, the screen itself, and then whatever is left of the path below
 * it. A screen kept off the rail is filed nowhere — it is reached from the
 * account menu, like the profile and the help — so its trail starts at Home
 * and names no group.
 *
 * `names` labels a segment the path spells as an identifier: a document's page
 * is /documents/<uuid>, and its crumb is the document's number, not the first
 * eight characters of a UUID titled like a word.
 */
export function trailFor(pathname: string, names: Readonly<Record<string, string>> = {}): Crumb[] {
  const tiles = allTiles();
  const onPath = tilesOnPath(pathname, tiles);
  const filed = onPath.filter((t) => !t.offRail).at(-1);

  // The root is the home of the area the screen is filed in, never the URL's
  // spelling: /administration/permissions is a Settings screen, and a trail
  // that started it at the Work home sent "up" somewhere the rail beside it
  // did not show.
  const area: Area =
    pathname === "/settings" || pathname.startsWith("/settings/")
      ? "settings"
      : filed
        ? areaOf(filed.group)
        : "work";
  const crumbs: Crumb[] = [{ to: AREA_HOME[area], label: HOME_LABELS[area] }];

  // The group the screen is filed under, said once, where the rail says it.
  // One trail, every screen, the same depth.
  if (filed) {
    crumbs.push({ to: null, label: GROUP_LABELS[filed.group] });

    // The screens it folds under on the rail, outermost first.
    const rail = tiles.filter((t) => !t.offRail);
    const above: TileDef[] = [];
    for (let at = railParent(filed.path, rail); at !== null; at = railParent(at, rail)) {
      const parent = rail.find((t) => t.path === at);
      if (!parent) break;
      above.unshift(parent);
    }
    for (const tile of [...above, filed]) crumbs.push({ to: tile.path, label: tile.title });
  }

  // Registered screens below the filed one: those kept off the rail.
  const depth = filed?.path.length ?? 0;
  for (const tile of onPath) {
    if (tile.path.length <= depth || tile.path === crumbs[0]?.to) continue;
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
