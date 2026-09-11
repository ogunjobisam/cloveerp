import { Link } from "@tanstack/react-router";
import { ArrowRight, Settings2 } from "lucide-react";

import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { usePlatformOrganisation } from "../../lib/platform-organisation";
import { GROUP_BLURBS, iconFor } from "../../lib/module-icons";
import {
  GROUP_LABELS,
  SETTINGS_GROUPS,
  allTiles,
  type TileDef,
  type TileGroup,
} from "../../lib/modules";
import { TOUCH } from "./page";
import { useErpSession } from "./session-context";

/**
 * The two launchpads.
 *
 * Work lists the operating flow — plan, source, make, move, sell, settle —
 * and the records it runs on. Settings lists the sections that shape the
 * organisation rather than run it. Neither shows the other's tiles: a person
 * opening Work to receive a delivery is not offered the audit log on the way,
 * and the one link between the areas is a single, clearly labelled card.
 *
 * A tile is offered only when the permission behind it is held; the database
 * is what enforces that, the tile is only a courtesy.
 */

const JOURNEY: TileGroup[] = ["plan", "source", "make", "move", "sell", "settle"];

function Tile({ tile, dense = false }: { tile: TileDef; dense?: boolean }) {
  const { t, ui } = useT();
  const Icon = iconFor(tile.path);

  return (
    <Link
      to={tile.path}
      className={`${TOUCH} group relative flex min-w-0 items-start gap-3 overflow-hidden rounded-xl border border-border bg-card p-3.5 shadow-[var(--shadow-card)] transition-all hover:-translate-y-0.5 hover:border-accent/50 hover:shadow-lg`}
    >
      <span className="grid size-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent transition-colors group-hover:bg-accent group-hover:text-accent-foreground">
        <Icon className="size-4" />
      </span>
      <span className="flex min-w-0 flex-col gap-1">
        <span className="text-sm font-semibold leading-snug text-foreground">
          {t(tile.titleKey, tile.title)}
        </span>
        {dense ? null : (
          <span className="line-clamp-2 text-xs leading-relaxed text-muted-foreground">
            {ui(tile.blurb)}
          </span>
        )}
      </span>
      {dense ? null : (
        <ArrowRight className="ml-auto size-4 shrink-0 -translate-x-1 text-muted-foreground opacity-0 transition-all group-hover:translate-x-0 group-hover:opacity-100" />
      )}
    </Link>
  );
}

function Section({
  group,
  tiles,
  columns = "sm:grid-cols-2 lg:grid-cols-3",
}: {
  group: TileGroup;
  tiles: TileDef[];
  columns?: string;
}) {
  const { ui } = useT();
  return (
    <section className="min-w-0">
      <div className="mb-3 flex min-w-0 flex-col gap-0.5 sm:flex-row sm:items-baseline sm:justify-between sm:gap-3">
        <h2 className="truncate font-display text-base font-semibold tracking-tight text-foreground">
          {ui(GROUP_LABELS[group])}
        </h2>
        <p className="truncate text-xs text-muted-foreground">{ui(GROUP_BLURBS[group])}</p>
      </div>
      <div className={`grid grid-cols-1 gap-3 ${columns}`}>
        {tiles.map((tile) => (
          <Tile key={tile.path} tile={tile} />
        ))}
      </div>
    </section>
  );
}

function useTiles() {
  const { session } = useErpSession();
  const platform = usePlatformOrganisation(Boolean(session?.tenant_id));
  const tiles = allTiles().filter(
    (x) => (!x.permission || hasPermission(session, x.permission)) && (!x.platformOnly || platform),
  );
  const inGroup = (g: TileGroup) => tiles.filter((x) => x.group === g);
  return { tiles, inGroup };
}

/** The Work launchpad: the flow, then the records. */
export function Launchpad() {
  const { ui } = useT();
  const { inGroup } = useTiles();

  const journey = JOURNEY.filter((g) => inGroup(g).length > 0);
  const records = inGroup("records");
  const settingsCount = SETTINGS_GROUPS.reduce((n, g) => n + inGroup(g).length, 0);

  if (journey.length === 0 && records.length === 0 && settingsCount === 0) return null;

  return (
    <div className="flex flex-col gap-8">
      {journey.length > 0 ? (
        <div className="relative overflow-hidden rounded-2xl border border-border bg-card/70 p-4 shadow-[var(--shadow-card)] backdrop-blur-sm sm:p-6">
          <div className="pointer-events-none absolute inset-0 hairline-grid opacity-20" />
          <div className="relative flex flex-col gap-5">
            <div className="min-w-0">
              <h2 className="font-display text-lg font-semibold tracking-tight">
                {ui("The flow")}
              </h2>
              <p className="mt-1 text-xs text-muted-foreground">
                {ui(
                  "Plan, source, make, move, sell, settle. Each stage lists only the screens this account may open.",
                )}
              </p>
            </div>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-6">
              {journey.map((group, i) => (
                <div key={group} className="flex min-w-0 flex-col gap-2">
                  <div className="flex items-baseline gap-2 border-b border-border pb-1.5">
                    <span className="font-mono text-xs font-semibold text-accent">
                      {String(i + 1).padStart(2, "0")}
                    </span>
                    <h3 className="truncate font-display text-xs font-semibold uppercase tracking-wide">
                      {ui(GROUP_LABELS[group])}
                    </h3>
                  </div>
                  <p className="text-xs leading-snug text-muted-foreground">
                    {ui(GROUP_BLURBS[group])}
                  </p>
                  <div className="flex flex-col gap-2">
                    {inGroup(group).map((tile) => (
                      <Tile key={tile.path} tile={tile} dense />
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      ) : null}

      {records.length > 0 ? <Section group="records" tiles={records} /> : null}

      {settingsCount > 0 ? (
        <Link
          to="/settings"
          className={`${TOUCH} group flex items-center gap-3 rounded-2xl border border-dashed border-border bg-muted/30 p-4 transition-colors hover:border-accent/50 sm:p-5`}
        >
          <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent transition-colors group-hover:bg-accent group-hover:text-accent-foreground">
            <Settings2 className="size-4.5" />
          </span>
          <span className="min-w-0 flex-1">
            <span className="block text-sm font-semibold">{ui("Settings")}</span>
            <span className="block text-xs text-muted-foreground">
              {ui(
                "People, system setup, products and places, finance setup, connections and compliance — in their own area, out of the way of the work.",
              )}
            </span>
          </span>
          <ArrowRight className="size-4 shrink-0 text-muted-foreground" />
        </Link>
      ) : null}
    </div>
  );
}

/** The Settings launchpad: each section, every tile with its blurb. */
export function SettingsLaunchpad() {
  const { inGroup } = useTiles();
  const groups = SETTINGS_GROUPS.filter((g) => inGroup(g).length > 0);
  if (groups.length === 0) return null;

  return (
    <div className="flex flex-col gap-8">
      {groups.map((group) => (
        <Section key={group} group={group} tiles={inGroup(group)} />
      ))}
    </div>
  );
}
