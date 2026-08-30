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
-- Supabase" — the answer is the hundred lines below.
--
-- Four things, in dependency order. The extensions are deliberately NOT here:
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
--   3. auth.uid(). The point at which ERPWare learns WHO is calling.
--      erp.principal_context() calls it and nothing else does.
--
--   4. auth.users, in the three columns the product actually reads. This was
--      missing, and its absence was hiding something: the identity boundary is
--      two things rather than one. erp.onboard_tenant() and erp.seed_demo()
--      create a principal for a caller who has none, and erp.app_user requires
--      an email of every person — which has to come from the verified identity
--      rather than from the client, or anyone could claim to be anyone. So the
--      product reads the subject's email back from the provider.
--
--      Replacing your identity provider means replacing both.
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
  'Half the identity boundary. Returns the authenticated subject from the '
  'session JWT claims, or null. The other half is auth.users, which the two '
  'self-service doors read the subject''s verified email back from.';

-- The subject's verified identity, read back by the two self-service doors.
-- On Supabase this table is the platform's and has forty columns; ERPWare
-- reads three, and listing them here is the point of this file. Nothing in the
-- product writes to it: an identity is created by signing up, not by ERPWare.
create table if not exists auth.users (
  id                 uuid primary key,
  email              text,
  raw_user_meta_data jsonb
);

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;

-- Supabase's default privileges on the public schema, which are the reason
-- every wrapper in this repository says `revoke ... from public, anon` rather
-- than `from public`.
--
-- Without this line a new function is reachable by nobody until it is granted,
-- so a migration that forgets to revoke from anon still passes. On a real
-- project the opposite is true: a function created in the public schema is
-- executable by anon the moment it exists, and revoking from PUBLIC does not
-- take away the explicit grant.
--
-- The rule in erp.public_api_report() that no public function may be
-- executable by anon was therefore unfalsifiable here — it could only ever
-- pass. Found when a Supabase preview branch rejected a function this build
-- had just called safe.
alter default privileges in schema public
  grant execute on functions to anon, authenticated, service_role;

-- A note on the claims GUC, which needs no setup --------------------------
--
-- PostgreSQL allows any session to set a custom GUC in a namespaced parameter,
-- so nothing is required here beyond noting that ERPWare never trusts it
-- directly: request.jwt.claims is read only by auth.uid(), and the subject it
-- yields is resolved against erp.app_user before it means anything. A client
-- that forges a claim names a principal that does not exist.
