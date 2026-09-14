/**
 * A permission, as a person reads it.
 *
 * A permission code — `administration.configure`, `inventory.write_off` — is
 * the database's name for a thing somebody may do. It is exact, and nobody
 * outside this codebase says it out loud. Every code already has a name a
 * person can read: `erp_ref.permission.name_key` is `permission.<code>`, and
 * erp.assert_resource_coverage() refuses a build where that key has no string.
 * The dictionary the desk loads carries every one of them, renamed where an
 * organisation has renamed it.
 *
 * So a screen that has to say which permission is missing says its name. The
 * humanised code is the fallback of last resort — a dictionary still loading,
 * or a permission added after the strings the screen has — and it is still
 * words rather than a dotted identifier.
 *
 * Pure: no React, no Supabase client, so it can be tested on its own.
 */

/** The resource key a permission's name is held under. */
export function permissionNameKey(code: string): string {
  return `permission.${code}`;
}

const MODULE_WORDS: Record<string, string> = {
  master_data: "Common data",
  inventory: "Stock",
  procurement: "Purchasing",
  production: "Manufacturing",
  logistics: "Despatch",
  quality: "Quality control",
  finance: "Financials",
  reporting: "Reports",
};

function words(identifier: string): string {
  return identifier.replace(/_+/g, " ").trim();
}

function capitalise(text: string): string {
  return text.length === 0 ? text : text.charAt(0).toUpperCase() + text.slice(1);
}

/**
 * `module.action` as words: `inventory.write_off` is "Stock: write off",
 * `administration.configure` is "Administration: configure". The module takes
 * the name the navigation gives it. Anything that is not a dotted code is
 * returned as words, never as an empty string.
 */
export function humanisePermission(code: string): string {
  const trimmed = code.trim();
  const dot = trimmed.indexOf(".");
  if (dot <= 0 || dot === trimmed.length - 1) return capitalise(words(trimmed));
  const module = trimmed.slice(0, dot);
  const action = words(trimmed.slice(dot + 1));
  return `${MODULE_WORDS[module] ?? capitalise(words(module))}: ${action}`;
}

/** The name the dictionary gives a permission, or its code as words. */
export function permissionName(code: string, resources: Record<string, string>): string {
  const named = resources[permissionNameKey(code)];
  return named !== undefined && named.trim() !== "" ? named : humanisePermission(code);
}
