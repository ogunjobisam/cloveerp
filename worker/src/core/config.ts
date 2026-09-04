/**
 * Everything the worker needs, and all of it from the environment.
 *
 * Nothing here is read from the database, and that is the point: B8 stores a
 * credential_ref rather than a credential precisely so the database never
 * holds one. If this file ever grows a query, that guarantee is gone.
 */

export type TenantBinding = {
  tenantId: string;
  /** Must be an erp.app_user with kind = 'service'. */
  principalId: string;
};

export type WorkerConfig = {
  databaseUrl: string;
  bindings: TenantBinding[];
  systems: string[];
  pollMs: number;
  workerName: string;
  /**
   * Absent means this worker sends no email, which is a state to report rather
   * than to fail on: an organisation without a key configured must not stop the
   * drain for every other organisation this process serves.
   */
  resendApiKey: string | null;
};

function required(name: string): string {
  const v = process.env[name];
  if (!v || v.trim().length === 0) {
    throw new Error(
      `${name} is not set. The worker refuses to start half-configured: a ` +
        `scheduler that silently serves no tenants looks exactly like one with ` +
        `nothing to do.`,
    );
  }
  return v.trim();
}

function list(name: string): string[] {
  return required(name)
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function loadConfig(env: Record<string, string | undefined> = process.env): WorkerConfig {
  const saved = process.env;
  try {
    // Allows the Edge Function entrypoint to pass Deno.env without duplicating
    // any of the parsing or the refusals below.
    (process as { env: Record<string, string | undefined> }).env = env;

    const tenants = list("CLOVEERP_TENANTS");
    const principals = list("CLOVEERP_PRINCIPALS");

    if (tenants.length !== principals.length) {
      throw new Error(
        `CLOVEERP_TENANTS has ${tenants.length} entries and CLOVEERP_PRINCIPALS ` +
          `has ${principals.length}. They are positional, so a mismatch would ` +
          `run one tenant's jobs as another tenant's principal.`,
      );
    }

    return {
      databaseUrl: required("CLOVEERP_DATABASE_URL"),
      bindings: tenants.map((tenantId, i) => ({ tenantId, principalId: principals[i]! })),
      systems: env["CLOVEERP_SYSTEMS"]
        ? env["CLOVEERP_SYSTEMS"].split(",").map((s) => s.trim()).filter(Boolean)
        : [],
      pollMs: Number(env["CLOVEERP_POLL_MS"] ?? 5000),
      workerName: env["CLOVEERP_WORKER_NAME"] ?? `clove-erp-worker-${process.pid ?? "edge"}`,
      resendApiKey: env["RESEND_API_KEY"]?.trim() || null,
    };
  } finally {
    (process as { env: Record<string, string | undefined> }).env = saved;
  }
}

/**
 * Resolving a credential_ref.
 *
 * The reference is a URI like `env://ACME_API_TOKEN` or `vault://path/to/key`.
 * Only the env scheme is implemented, because that is the only store this
 * process has been given. An unresolvable reference is an error rather than an
 * empty string: sending an unauthenticated request to a supplier and recording
 * the rejection as a business failure is worse than not sending it.
 */
export function resolveCredential(ref: string | null): string | null {
  if (!ref) return null;

  const match = /^([a-z][a-z0-9+.-]*):\/\/(.+)$/i.exec(ref);
  if (!match) {
    throw new Error(`credential_ref is not a URI: ${ref}`);
  }

  const [, scheme, rest] = match;
  if (scheme!.toLowerCase() !== "env") {
    throw new Error(
      `credential_ref scheme "${scheme}" is not supported by this worker. ` +
        `Implement it here, where the secret store is reachable — never by ` +
        `putting the value in the database.`,
    );
  }

  const value = process.env[rest!];
  if (!value) {
    throw new Error(`credential_ref ${ref} resolves to nothing in this environment`);
  }
  return value;
}
