import postgres from "postgres";

import type { TenantBinding } from "./config.ts";

export type Sql = ReturnType<typeof postgres>;

export function connect(databaseUrl: string): Sql {
  return postgres(databaseUrl, {
    // One unit of work is one transaction, and they are short. A big pool buys
    // nothing and makes lease expiry harder to reason about.
    max: 4,
    idle_timeout: 30,
    // Errors from these functions are the product speaking (CLOVEERP_*), so they
    // must arrive intact rather than as a generic driver failure.
    onnotice: () => {},
  });
}

/**
 * One unit of work, as one transaction, acting as a service principal.
 *
 * The handshake is two calls and the order is enforced, not conventional:
 * set_job_principal() raises CLOVEERP_NO_TENANT_CONTEXT if no tenant has been
 * declared yet. That is deliberate — it then checks the principal actually
 * belongs to the tenant that was declared, which it could not do the other way
 * round. A worker cannot name a principal and have the tenant inferred from
 * it, which is what would let one tenant's job run as another's principal.
 *
 * Both write transaction-local GUCs, and that is not incidental either. B1 has
 * an assertion (erp.assert_session_context_hygiene) that fails the build if any
 * function sets one of these at session scope, because a pooled connection
 * would carry the context to whoever it served next. Wrapping every call in a
 * transaction is what makes transaction-local sufficient.
 *
 * The principal must be kind = 'service'. set_job_principal() refuses to adopt
 * a person, so a worker can never act as somebody.
 */
export async function asPrincipal<T>(
  sql: Sql,
  binding: TenantBinding,
  work: (tx: Sql) => Promise<T>,
): Promise<T> {
  return sql.begin(async (tx) => {
    await tx`select erp.set_job_tenant(${binding.tenantId}::uuid)`;
    await tx`select erp.set_job_principal(${binding.principalId}::uuid)`;
    return work(tx as unknown as Sql);
  }) as Promise<T>;
}

/**
 * One unit of work, as one transaction, acting as a named role.
 *
 * The public ingress reaches this database over the project's own postgres
 * connection, because that is the only connection Supabase hands an Edge
 * Function without somebody copying a password into a secret by hand. postgres
 * has BYPASSRLS. So the connection is not the boundary and cannot be made into
 * one; what can be made a boundary is the role the statements actually run as.
 *
 * SET LOCAL rather than SET, and inside an explicit transaction rather than on
 * the connection, for the same reason erp.assert_session_context_hygiene()
 * exists: a pooled connection carries session state to whoever it serves next,
 * and a role left set is a role somebody else inherits. LOCAL is undone at
 * commit and at rollback alike, so there is no path out of this function that
 * leaves the connection changed.
 *
 * This is privilege reduction the caller performs on itself, not a wall around
 * it: code holding a postgres connection can always RESET ROLE. Making it a
 * wall is one deployment step further — give the role LOGIN and a password and
 * point CLOVEERP_DATABASE_URL at it — and needs no change here, because the
 * switch is then a no-op onto the role the connection already is.
 */
export async function asRole<T>(sql: Sql, role: string, work: (tx: Sql) => Promise<T>): Promise<T> {
  // The role name is an identifier, and an identifier cannot be a bound
  // parameter — SET ROLE $1 is not a thing. It is escaped as an identifier
  // below, and checked here as well: this value comes from configuration, and
  // configuration is a place a mistake gets typed.
  if (!/^[a-z_][a-z0-9_]{0,62}$/.test(role)) {
    throw new Error(`${role} is not a role name`);
  }
  return sql.begin(async (tx) => {
    await tx`set local role ${tx(role)}`;
    return work(tx as unknown as Sql);
  }) as Promise<T>;
}
