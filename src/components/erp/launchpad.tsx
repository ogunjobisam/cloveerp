import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";

import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { GROUP_BLURBS, iconFor } from "../../lib/module-icons";
import { GROUP_LABELS, allTiles, type TileDef } from "../../lib/modules";
import { TOUCH } from "./page";
import { useErpSession } from "./session-context";

/**
 * The launchpad.
 *
 * Every screen this account can reach, arranged the way the work actually
 * runs: plan, source, make, move, sell, settle — then the records that govern
 * all of it, then administration on its own. A tile is offered only when the
 * permission behind it is held; the database is what enforces that, the tile
 * is only a courtesy.
 */

const JOURNEY: TileDef["group"][] = ["plan", "source", "make", "move", "sell", "settle"];

function Tile({ tile, dense = false }: { tile: TileDef; dense?: boolean }) {
  const { t } = useT();
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
            {tile.blurb}
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
  index,
  tiles,
  dense = false,
  columns = "sm:grid-cols-2 lg:grid-cols-3",
}: {
  group: TileDef["group"];
  index?: number;
  tiles: TileDef[];
  dense?: boolean;
  columns?: string;
}) {
  return (
    <section className="min-w-0">
      <div className="mb-3 grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-3 sm:flex sm:justify-between">
        <div className="flex min-w-0 items-baseline gap-2">
          {index === undefined ? null : (
            <span className="font-mono text-[11px] font-semibold text-accent">
              {String(index).padStart(2, "0")}
            </span>
          )}
          <h2 className="truncate font-display text-sm font-semibold tracking-tight text-foreground">
            {GROUP_LABELS[group]}
          </h2>
        </div>
        <p className="hidden truncate text-xs text-muted-foreground sm:block">
          {GROUP_BLURBS[group]}
        </p>
      </div>
      <div className={`grid grid-cols-1 gap-3 ${columns}`}>
        {tiles.map((tile) => (
          <Tile key={tile.path} tile={tile} dense={dense} />
        ))}
      </div>
    </section>
  );
}

export function Launchpad() {
  const { session } = useErpSession();
  const tiles = allTiles().filter((x) => !x.permission || hasPermission(session, x.permission));
  const inGroup = (g: TileDef["group"]) => tiles.filter((x) => x.group === g);

  if (tiles.length === 0) return null;

  const journey = JOURNEY.filter((g) => inGroup(g).length > 0);
  const govern = inGroup("govern");
  const administer = inGroup("administer");

  return (
    <div className="flex flex-col gap-8">
      {journey.length > 0 ? (
        <div className="relative overflow-hidden rounded-2xl border border-border bg-card/70 p-4 shadow-[var(--shadow-card)] backdrop-blur-sm sm:p-6">
          <div className="pointer-events-none absolute inset-0 hairline-grid opacity-20" />
          <div className="relative flex flex-col gap-5">
            <div className="min-w-0">
              <h2 className="font-display text-lg font-semibold tracking-tight">The flow</h2>
              <p className="mt-1 text-xs text-muted-foreground">
                Plan → Source → Make → Move → Sell → Settle. Each stage lists only the screens this
                account may open.
              </p>
            </div>
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
              {journey.map((group, i) => (
                <div key={group} className="flex min-w-0 flex-col gap-2">
                  <div className="flex items-baseline gap-2 border-b border-border pb-1.5">
                    <span className="font-mono text-[11px] font-semibold text-accent">
                      {String(i + 1).padStart(2, "0")}
                    </span>
                    <h3 className="truncate font-display text-xs font-semibold uppercase tracking-wide">
                      {GROUP_LABELS[group]}
                    </h3>
                  </div>
                  <p className="text-[11px] leading-snug text-muted-foreground">
                    {GROUP_BLURBS[group]}
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

      {govern.length > 0 ? <Section group="govern" tiles={govern} /> : null}

      {administer.length > 0 ? (
        <div className="rounded-2xl border border-dashed border-border bg-muted/30 p-4 sm:p-6">
          <Section
            group="administer"
            tiles={administer}
            dense
            columns="sm:grid-cols-2 lg:grid-cols-4"
          />
        </div>
      ) : null}
    </div>
  );
}
