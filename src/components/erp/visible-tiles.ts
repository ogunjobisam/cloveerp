import { useMemo } from "react";

import { hasPermission } from "../../lib/erp";
import { allTiles, type TileDef } from "../../lib/modules";
import { usePlatformOrganisation } from "../../lib/platform-organisation";
import { useErpSession } from "./session-context";

/**
 * The screens this account is offered, decided in one place.
 *
 * The rail, the launchpads and the palette each filtered the registry for
 * themselves, and the copies drifted: the palette checked the permission and
 * forgot the platform-only rule, so a customer organisation was offered Price
 * book and Quotes by search — two screens the rail hid and the database
 * refuses. One hook, so the navigators cannot disagree about what exists.
 *
 * A tile is offered when the permission behind it is held and, where it is
 * platform-only, the organisation in session is the platform's own. That is a
 * courtesy and nothing more: the database is what refuses.
 *
 * Tiles marked `offRail` are included. They are still screens the account may
 * open, and search still finds them; the rail and the launchpads leave them
 * out for themselves.
 */
export function useVisibleTiles(): TileDef[] {
  const { session } = useErpSession();
  const platform = usePlatformOrganisation(Boolean(session.tenant_id));
  return useMemo(
    () =>
      allTiles().filter(
        (tile) =>
          (!tile.permission || hasPermission(session, tile.permission)) &&
          (!tile.platformOnly || platform),
      ),
    [session, platform],
  );
}
