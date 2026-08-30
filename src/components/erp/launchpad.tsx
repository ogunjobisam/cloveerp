import { Link } from "@tanstack/react-router";

import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { GROUP_LABELS, allTiles, type TileDef } from "../../lib/modules";
import { TOUCH } from "./page";
import { useErpSession } from "./session-context";

/**
 * The launchpad.
 *
 * One grid of every screen this account can actually reach, grouped by what
 * you are doing rather than by which team built it. It exists because the rail
 * was a flat list of twenty entries in insertion order, and "where do I start"
 * had no answer on it.
 *
 * A tile is offered only when the permission behind it is held. That is the
 * same rule the rail uses and the same rule the database enforces; the tile is
 * a courtesy, the database is the control.
 */
function Tile({ tile }: { tile: TileDef }) {
  const { t } = useT();

  return (
    <Link
      to={tile.path}
      className={`${TOUCH} group flex min-w-0 flex-col justify-between gap-2 rounded-xl border border-border bg-card p-4 transition-colors hover:border-primary/40 hover:bg-muted/40`}
    >
      <span className="text-sm font-semibold group-hover:text-foreground">
        {t(tile.titleKey, tile.title)}
      </span>
      <span className="line-clamp-2 text-xs text-muted-foreground">{tile.blurb}</span>
    </Link>
  );
}

export function Launchpad() {
  const { session } = useErpSession();
  const tiles = allTiles().filter((x) => !x.permission || hasPermission(session, x.permission));
  const groups: TileDef["group"][] = ["operate", "govern", "administer"];

  if (tiles.length === 0) return null;

  return (
    <div className="flex flex-col gap-6">
      {groups.map((group) => {
        const inGroup = tiles.filter((x) => x.group === group);
        if (inGroup.length === 0) return null;
        return (
          <section key={group} className="min-w-0">
            <h2 className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {GROUP_LABELS[group]}
            </h2>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {inGroup.map((tile) => (
                <Tile key={tile.path} tile={tile} />
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}
