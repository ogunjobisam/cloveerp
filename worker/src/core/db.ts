import postgres from "postgres";

import type { TenantBinding } from "./config";

export type Sql = ReturnType<typeof postgres>;

export function connect(databaseUrl: string): Sql {
  return postgres(databaseUrl, {
    // One unit of work is one transaction, and they are short. A big pool buys
    // nothing and makes lease expiry harder to reason about.
    max: 4,
    idle_timeout: 30,
    // Errors from these functions are the product speaking (ERPWARE_*), so they
    // must arrive intact rather than as a generic driver failure.
    onnotice: () => {},
  });
}

/**
 * One unit of work, as one transaction, acting as a service principal.
 *
 * The handshake is two calls and the order is enforced, not conventional:
 * set_job_principal() raises ERPWARE_NO_TENANT_CONTEXT if no tenant has been
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
