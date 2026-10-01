import type { Json } from "../types";
import type { Door } from "./run";

/**
 * A door over psql, signed in as one person: each call is its own
 * transaction with the person's claims set inside it, as PostgREST makes one
 * per request. Arguments go by name, each as a dollar-quoted literal the
 * function's own parameter types resolve, so nothing is cast by hand here.
 * The answer is read back as JSON.
 *
 * Used by supabase/ci/pilot.ts against the database the build made; nothing in
 * the application imports it.
 */

function literal(value: Json): string {
  if (value === null) return "null";
  const text = typeof value === "object" ? JSON.stringify(value) : String(value);
  let tag = "q";
  while (text.includes(`$${tag}$`)) tag += "q";
  return `$${tag}$${text}$${tag}$`;
}

export function callSql(fn: string, args: Readonly<Record<string, Json>>): string {
  if (!/^erp_[a-z0-9_]+$/.test(fn)) throw new Error(`not a door: ${fn}`);
  const named = Object.entries(args).map(([k, v]) => {
    if (!/^p_[a-z0-9_]+$/.test(k)) throw new Error(`not a parameter: ${k}`);
    return `${k} => ${literal(v)}`;
  });
  return `select coalesce(to_jsonb(public.${fn}(${named.join(", ")}))::text, 'null');`;
}

export function psqlDoor(psql: readonly string[], authUserId: string): Door {
  const claims = JSON.stringify({ sub: authUserId });
  return async (fn, args = {}) => {
    const script = [
      "\\set QUIET on",
      "\\set ON_ERROR_STOP on",
      "begin;",
      `select set_config('request.jwt.claims', ${literal(claims)}, true) \\g /dev/null`,
      callSql(fn, args),
      "commit;",
    ].join("\n");
    const run = Bun.spawnSync([...psql, "-At", "-f", "-"], {
      stdin: new TextEncoder().encode(script),
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = run.stdout.toString().trim();
    if (run.exitCode !== 0) {
      throw new Error(`${fn} refused: ${run.stderr.toString().trim() || out}`);
    }
    const last =
      out
        .split("\n")
        .filter((l) => l.trim() !== "")
        .pop() ?? "null";
    return JSON.parse(last) as Json;
  };
}
