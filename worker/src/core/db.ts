import postgres from "postgres";

import type { TenantBinding } from "./config.ts";

export type Sql = ReturnType<typeof postgres>;

/**
 * Which way into the database this connection is.
 *
 * erp.audit_entry.source records the entry point behind every change, and for
 * the life of the product it recorded 'api' for all of them, because the
 * session setting it reads was set by nothing (20260919930000). A trigger can
 * only record what the session tells it, so the telling happens here: at the
 * point a process opens its connection, which is the one place that knows what
 * the process is.
 *
 * The word must be one erp_ref.audit_source holds; erp.declare_source()
 * refuses anything else, and erp.audit_entry.source is foreign-keyed to the
 * same table, so a typo cannot become a source nobody can account for.
 */
export type AuditSource = "dispatch_worker" | "edge_function" | "public_door";

// Not a field on the client, because the client is a tagged-template function
// the driver builds. A required parameter on connect() is what makes this
// impossible to forget: a new entry point does not compile until it says what
// it is.
const sourceOfConnection = new WeakMap<object, AuditSource>();

function declaredSource(sql: Sql): AuditSource {
  const source = sourceOfConnection.get(sql);
  if (source === undefined) {
    // Only reachable by building a client without connect(). Loud, because the
    // quiet version of this is an audit trail that says nothing and looks fine.
    throw new Error("this connection never said which entry point it is; open it with connect(url, source)");
  }
  return source;
}

export function connect(databaseUrl: string, source: AuditSource): Sql {
  const sql = postgres(databaseUrl, {
    // One unit of work is one transaction, and they are short. A big pool buys
    // nothing and makes lease expiry harder to reason about.
    max: 4,
    idle_timeout: 30,
    // Errors from these functions are the product speaking (CLOVEERP_*), so they
    // must arrive intact rather than as a generic driver failure.
    onnotice: () => {},
  });
  sourceOfConnection.set(sql, source);
  return sql;
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
 *
 * Or there is no principal at all: an organisation erp.dispatch_bindings()
 * listed rather than one named in CLOVEERP_PRINCIPALS. That is the minute pass's
 * own shape — erp.run_due_jobs_all_tenants() declares a tenant and clears the
 * principal before every organisation — and every claim and settle the drain
 * calls asks for a tenant and reads no principal; the audit trail records the
 * work as the system. Skipping the call is not a weaker handshake: the tenant is
 * still declared first, by a trusted session, for this transaction only.
 */
export async function asPrincipal<T>(
  sql: Sql,
  binding: TenantBinding,
  work: (tx: Sql) => Promise<T>,
): Promise<T> {
  return sql.begin(async (tx) => {
    // First, before anything this transaction does is audited: what this is.
    // Transaction-local like the tenant and the principal below, and for the
    // same reason — a pooled connection carries session state to whoever it
    // serves next, and a source left set mislabels their changes as ours.
    await tx`select erp.declare_source(${declaredSource(sql)})`;
    await tx`select erp.set_job_tenant(${binding.tenantId}::uuid)`;
    if (binding.principalId !== null) {
      await tx`select erp.set_job_principal(${binding.principalId}::uuid)`;
    }
    return work(tx as unknown as Sql);
  }) as Promise<T>;
}

/**
 * One unit of work, as one transaction, saying only which entry point it is.
 *
 * For the calls that declare no tenant and adopt no principal — an Edge
 * Function reading an invitation, recording a delivery event, spending the
 * email budget. Each is a single statement, so a single-statement transaction
 * is what it already was; the transaction is here to give the declaration
 * somewhere to live, since erp.declare_source() is transaction-local like
 * every other context setting this product carries.
 */
export async function declaring<T>(sql: Sql, work: (tx: Sql) => Promise<T>): Promise<T> {
  return sql.begin(async (tx) => {
    await tx`select erp.declare_source(${declaredSource(sql)})`;
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
    // Before the role changes, not after: erp.declare_source() lets an
    // untrusted session call itself the screen and nothing else, and once the
    // role is reduced this session is untrusted by design. Declaring first is
    // also the honest order — this is the public ingress whatever it then
    // reduces itself to.
    await tx`select erp.declare_source(${declaredSource(sql)})`;
    await tx`set local role ${tx(role)}`;
    return work(tx as unknown as Sql);
  }) as Promise<T>;
}
