import { hasModule, hasPermission, type ErpSession } from "./erp";
import { allTiles, type TileDef } from "./modules";

/**
 * What the desk offers depends on what the organisation has installed.
 *
 * Manufacturing, Planning and Quality work only once their module is
 * installed; before then every verb on them is refused. The demonstration has
 * not installed them, and offering screens that can do nothing was the fault
 * (J-05, J-89). The session names the modules in force, and these decide from
 * it what the rail, the launchpads, the palette, the first steps, the guides
 * and the scanner offer. Hiding is a courtesy: the database refuses
 * regardless.
 */

/**
 * The modules an organisation may or may not have installed, whose screens
 * depend on it. The desk offers their screens only once the session names
 * them (erp_session's `modules`); the database refuses their verbs before then
 * regardless.
 */
export const INSTALLABLE_MODULES = ["production", "planning", "quality"] as const;
export type InstallableModule = (typeof INSTALLABLE_MODULES)[number];

function isInstallable(code: string): code is InstallableModule {
  return (INSTALLABLE_MODULES as readonly string[]).includes(code);
}

/**
 * Whether something belonging to a module is offered. Anything not tied to
 * one of the installable modules always is.
 */
export function moduleOffered(session: ErpSession, code: string | null | undefined): boolean {
  if (!code || !isInstallable(code)) return true;
  return hasModule(session, code);
}

/** The installable module a screen belongs to, by the longest tile path it sits under. */
export function moduleOfPath(path: string): InstallableModule | undefined {
  const tile = allTiles()
    .filter((t) => path === t.path || path.startsWith(`${t.path}/`))
    .sort((a, b) => b.path.length - a.path.length)[0];
  return tile?.module;
}

/**
 * Whether a tile is offered: the permission behind it is held, a platform-only
 * screen is in the platform's own organisation, and its module is installed.
 */
export function tileOffered(tile: TileDef, session: ErpSession, platform: boolean): boolean {
  return (
    (!tile.permission || hasPermission(session, tile.permission)) &&
    (!tile.platformOnly || platform) &&
    (!tile.module || hasModule(session, tile.module))
  );
}
