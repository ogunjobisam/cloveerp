/**
 * The line under a person's name in the header: the roles they hold here.
 *
 * There is no access level in this product — roles are the organisation's own
 * data — so this names the roles, administrator first as the session orders
 * them, two at most and a count for the rest. A visit through a support window
 * says so, because "Administrator" alone would read as the organisation's own.
 *
 * Pure, so it can be tested without a browser.
 */

export type SessionRole = {
  code: string;
  name: string;
  name_key?: string | null;
  support: boolean;
};

export function rolesLabel(
  roles: readonly SessionRole[] | undefined,
  nameOf: (role: SessionRole) => string,
  asSupport: string,
): string {
  if (!roles || roles.length === 0) return "";
  const names = roles.map(nameOf).filter((n) => n.trim() !== "");
  if (names.length === 0) return "";
  const shown = names.slice(0, 2).join(" · ");
  const rest = names.length - 2;
  const label = rest > 0 ? `${shown} +${rest}` : shown;
  return roles.every((r) => r.support) ? `${label} · ${asSupport}` : label;
}
