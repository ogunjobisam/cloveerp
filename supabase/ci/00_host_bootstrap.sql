-- =============================================================================
-- ERPWare — everything the product needs from its host, and nothing more
--
-- The migrations in supabase/migrations/ are a Postgres schema. This file is
-- the complete list of things they expect to already exist, which on Supabase
-- are provided by the platform. Applying this to an empty PostgreSQL cluster
-- and then applying the migrations in order gives a working ERPWare.
--
-- It exists for two reasons. It lets CI stand the product up from nothing on
-- every push, which is what makes the assert_* functions in every migration
-- mean anything. And it is the honest answer to "how much of this is locked to
-- Supabase" — the answer is the eighty lines below.
--
-- Three things, in dependency order. The extensions are deliberately NOT here:
-- each migration creates the one it needs (pgcrypto in 0001, pg_jsonschema in
-- 0009, btree_gist in 0010), so a migration carries its own dependency rather
-- than assuming someone else arranged it. All three must be *available* to the
-- cluster; only the `extensions` schema they install into is created here.
--
--   1. The `extensions` schema.
--
--   2. Roles. anon, authenticated and service_role, with the privilege split
--      ERPWare's row security depends on: service_role bypasses RLS, the other
--      two never do. erp.session_is_trusted() reads rolbypassrls and nothing
--      else, so this is the whole of the trust model.
--
--   3. auth.uid(). The single point at which ERPWare touches the identity
--      provider. erp.principal_context() calls it and nothing else does.
--      Replacing your identity provider means replacing this function.
-- =============================================================================

-- 1. The schema the extensions install into ----------------------------------

create schema if not exists extensions;
grant usage on schema extensions to public;

-- 2. Roles -------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- BYPASSRLS is the entire trust model: erp.session_is_trusted() reads
    -- rolbypassrls, so this is what lets a job declare a tenant context.
    create role service_role nologin noinherit bypassrls;
  end if;
end;
$$;

-- 3. The identity boundary ----------------------------------------------------

create schema if not exists auth;

-- The one function that connects ERPWare to an identity provider. It returns
-- the authenticated subject, or null when there is no authenticated session.
-- erp.principal_context() resolves that subject to an erp.app_user row; nothing
-- else in the product reads a claim, a header or a token.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  -- The inner nullif has to come BEFORE the jsonb cast. current_setting() with
  -- missing_ok returns NULL when the GUC was never set, but it returns the
  -- empty string when something has set it and then cleared it — and ''::jsonb
  -- raises rather than yielding NULL. Every test suite clears the claims on its
  -- way out, so the wrong order turns a routine teardown into a hard error.
  select nullif(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
    '')::uuid
$$;

comment on function auth.uid() is
  'The identity boundary. Returns the authenticated subject from the session '
  'JWT claims, or null. Swapping identity providers means swapping this '
  'function and nothing else.';

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- 4. Make the claims GUC settable by unprivileged sessions --------------------
--
-- PostgreSQL allows any session to set a custom GUC in a namespaced parameter,
-- so nothing is required here beyond noting that ERPWare never trusts it
-- directly: request.jwt.claims is read only by auth.uid(), and the subject it
-- yields is resolved against erp.app_user before it means anything. A client
-- that forges a claim names a principal that does not exist.
