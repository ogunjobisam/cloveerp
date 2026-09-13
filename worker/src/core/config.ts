/**
 * Everything the worker needs, and all of it from the environment.
 *
 * Nothing here is read from the database, and that is the point: B8 stores a
 * credential_ref rather than a credential precisely so the database never
 * holds one. If this file ever grows a query, that guarantee is gone.
 */

export type TenantBinding = {
  tenantId: string;
  /**
   * A kind = 'service' erp.app_user named in CLOVEERP_PRINCIPALS, or null for an
   * organisation erp.dispatch_bindings() listed: a tenant context and no
   * principal, which is how the minute pass (erp.run_due_jobs_all_tenants) has
   * always run, and all any claim or settle the drain calls asks for.
   */
  principalId: string | null;
  /**
   * Listed by the database on this pass rather than named in the environment.
   *
   * Such an organisation has its email and webhooks drained and nothing more
   * that an operator has not chosen to give it: no credential_ref is resolved
   * for it (resolveCredential), and no job, outbox message or command is run for
   * it here (drainOnce). The minute pass already runs every active
   * organisation's SQL jobs and a handler only TypeScript implements is platform
   * work; CLOVEERP_SYSTEMS lists the systems an operator set up for the
   * organisations named beside it, not endpoints any organisation may register
   * under the same code.
   */
  discovered: boolean;
};

export type WorkerConfig = {
  databaseUrl: string;
  /**
   * The organisations named in CLOVEERP_TENANTS, each as the service principal
   * in the same position of CLOVEERP_PRINCIPALS; empty when neither is set.
   *
   * Not the whole of what a pass serves. drainOnce() adds every other active
   * organisation erp.dispatch_bindings() lists, asked afresh each pass, so an
   * organisation created at noon has its email sent at one minute past without
   * anybody editing a list. The query lives there and not here: this file still
   * reads nothing from the database.
   */
  bindings: TenantBinding[];
  systems: string[];
  pollMs: number;
  workerName: string;
  /**
   * How long a claim lasts, in seconds. A worker that dies keeps its claims
   * this long; after it the reclaimer settles them — back to the queue if
   * nothing was sent, ambiguous if something was. Must outlast the HTTP
   * timeout below, or a request could still be answering when its command is
   * declared unknown.
   */
  leaseSeconds: number;
  /** How long one outbound request may take before it counts as no answer. */
  httpTimeoutMs: number;
  /**
   * Absent means this worker sends no email, which is a state to report rather
   * than to fail on: an organisation without a key configured must not stop the
   * drain for every other organisation this process serves.
   */
  resendApiKey: string | null;
  supabaseUrl: string | null;
  supabaseServiceRoleKey: string | null;
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

    // Both or neither. Neither is not "serve nothing": every active organisation
    // is served anyway (see WorkerConfig.bindings). One without the other is a
    // list somebody meant to finish, and guessing which half they meant would
    // run an organisation as nobody or a principal for no organisation.
    const named = ["CLOVEERP_TENANTS", "CLOVEERP_PRINCIPALS"].filter(
      (name) => (env[name] ?? "").trim().length > 0,
    );
    if (named.length === 1) {
      const other = named[0] === "CLOVEERP_TENANTS" ? "CLOVEERP_PRINCIPALS" : "CLOVEERP_TENANTS";
      throw new Error(
        `${named[0]} is set and ${other} is not. Set both to serve named ` +
          `organisations as named service principals, or neither: every active ` +
          `organisation is served either way.`,
      );
    }

    const tenants = named.length === 2 ? list("CLOVEERP_TENANTS") : [];
    const principals = named.length === 2 ? list("CLOVEERP_PRINCIPALS") : [];

    if (tenants.length !== principals.length) {
      throw new Error(
        `CLOVEERP_TENANTS has ${tenants.length} entries and CLOVEERP_PRINCIPALS ` +
          `has ${principals.length}. They are positional, so a mismatch would ` +
          `run one tenant's jobs as another tenant's principal.`,
      );
    }

    const leaseSeconds = Number(env["CLOVEERP_LEASE_SECONDS"] ?? 300);
    const httpTimeoutMs = Number(env["CLOVEERP_HTTP_TIMEOUT_MS"] ?? 30_000);
    if (!(leaseSeconds > 0) || !(httpTimeoutMs > 0)) {
      throw new Error(
        "CLOVEERP_LEASE_SECONDS and CLOVEERP_HTTP_TIMEOUT_MS must be positive numbers.",
      );
    }
    if (httpTimeoutMs >= leaseSeconds * 1000) {
      throw new Error(
        `CLOVEERP_HTTP_TIMEOUT_MS (${httpTimeoutMs}) must be under the lease ` +
          `(CLOVEERP_LEASE_SECONDS ${leaseSeconds}): a request that can outlive its ` +
          `lease would be reclaimed as unknown while it was still answering.`,
      );
    }

    // SUPABASE_DB_URL is the project's own connection, injected into every Edge
    // Function by the platform, so the dispatch function needs no password copied
    // into a secret by hand; enquiry reads it the same way. An explicit
    // CLOVEERP_DATABASE_URL still wins, and with neither set this refuses by name.
    const databaseUrl = env["CLOVEERP_DATABASE_URL"]?.trim() || env["SUPABASE_DB_URL"]?.trim();
    if (!databaseUrl) {
      throw new Error(
        "Neither CLOVEERP_DATABASE_URL nor SUPABASE_DB_URL is set. The worker " +
          "refuses to start half-configured: a scheduler that silently serves no " +
          "tenants looks exactly like one with nothing to do.",
      );
    }

    return {
      databaseUrl,
      bindings: tenants.map((tenantId, i) => ({
        tenantId,
        principalId: principals[i]!,
        discovered: false,
      })),
      systems: env["CLOVEERP_SYSTEMS"]
        ? env["CLOVEERP_SYSTEMS"]
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean)
        : [],
      pollMs: Number(env["CLOVEERP_POLL_MS"] ?? 5000),
      workerName: env["CLOVEERP_WORKER_NAME"] ?? `clove-erp-worker-${process.pid ?? "edge"}`,
      leaseSeconds,
      httpTimeoutMs,
      resendApiKey: env["RESEND_API_KEY"]?.trim() || null,
      supabaseUrl: env["SUPABASE_URL"]?.trim() || null,
      supabaseServiceRoleKey: env["SUPABASE_SERVICE_ROLE_KEY"]?.trim() || null,
    };
  } finally {
    (process as { env: Record<string, string | undefined> }).env = saved;
  }
}

/**
 * The only environment names a credential_ref may point at.
 *
 * One process environment serves every organisation, and it also holds what the
 * process runs on: SUPABASE_SERVICE_ROLE_KEY, SUPABASE_DB_URL with its password,
 * RESEND_API_KEY, CLOVEERP_DISPATCH_SECRET. An administrator writes the
 * reference, so a reference that could name any variable would let a webhook
 * channel post the service key to an address its organisation chose. A name
 * under this prefix is one an operator put there to be handed out, and nothing
 * else is. The database refuses the same rule when the reference is written;
 * this is the half that holds for a row written before it did.
 */
export const CREDENTIAL_NAME = /^CLOVEERP_CREDENTIAL_[A-Z0-9_]{1,100}$/;

/**
 * Resolving a credential_ref.
 *
 * The reference is a URI like `env://CLOVEERP_CREDENTIAL_ACME_API_TOKEN` or
 * `vault://path/to/key`. Only the env scheme is implemented, because that is the
 * only store this process has been given. An unresolvable reference is an error
 * rather than an empty string: sending an unauthenticated request to a supplier
 * and recording the rejection as a business failure is worse than not sending it.
 *
 * Only for an organisation an operator named in CLOVEERP_TENANTS. An organisation
 * erp.dispatch_bindings() listed chose its own references, and nobody decided
 * which of this environment's credentials are its to use: under one shared
 * prefix it could still name another organisation's token. So a listed
 * organisation's reference is refused before the environment is read at all,
 * and its webhooks without one still post.
 *
 * No refusal carries a value. The text goes into a failure column somebody
 * reads on a screen.
 */
export function resolveCredential(ref: string | null, binding: TenantBinding): string | null {
  if (!ref) return null;

  if (binding.discovered) {
    throw new Error("credentials are resolved only for organisations named in CLOVEERP_TENANTS");
  }

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

  if (!CREDENTIAL_NAME.test(rest!)) {
    throw new Error(
      "credential_ref names an environment variable this worker does not hand out: " +
        "an env:// reference must name CLOVEERP_CREDENTIAL_ followed by 1 to 100 " +
        "capital letters, digits or underscores",
    );
  }

  const value = process.env[rest!];
  if (!value) {
    throw new Error(`credential_ref ${ref} resolves to nothing in this environment`);
  }
  return value;
}
