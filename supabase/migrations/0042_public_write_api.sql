-- =============================================================================
-- ERPWare — the public write surface, and the rule that had to grow to allow it
--
-- 0040 established three rules for public.erp_*: security invoker, never anon,
-- and reads only. The third was expressed as "every function is STABLE", which
-- was right for a surface that only reported, and is exactly wrong now. A
-- product where nothing can be created is not finished; it is unreachable.
--
-- The temptation is to relax the rule. Do not: "no ungated write reaches a
-- table" is the property worth keeping, and STABLE was only ever a proxy for
-- it. So the rule becomes what it always meant, using the mechanism 0006
-- already established for SECURITY DEFINER — an enumerated allow-list with a
-- rationale, rather than a blanket ban:
--
--   A VOLATILE public.erp_* function must appear in
--   erp_meta.public_write_allowance, and its body must call the gate that row
--   names.
--
-- That is strictly stronger than the ban it replaces. Before, a function could
-- not write at all. Now it may, but only if somebody wrote down why and the
-- catalogue can see the gate in its body. An unlisted volatile function fails
-- the build; a listed one that quietly stopped calling its gate also fails.
--
-- What the gate names, and why it is followed one hop. Every function here is
-- a wrapper, so none of them calls erp.authorise() directly — they delegate to
-- the erp.* function that does. Checking the wrapper's own body for
-- erp.authorise() would therefore fail all of them, which is what the first
-- draft of this rule did. So the allow-list names the DELEGATE, the check
-- confirms the wrapper calls it, and a second check confirms the delegate
-- itself either authorises or is an enumerated SECURITY DEFINER exception.
--
-- That last clause is not a loophole, it is the one real case:
-- erp.claim_invitation() runs before the caller has a principal — the state it
-- exists to end — so there is nothing to authorise against and its gate is
-- possession of the token. It is on 0006's definer allow-list with a
-- rationale, which is where that scrutiny already lives.
--
-- Every function below is a thin wrapper. The authorisation, validation and
-- recording all already exist in erp.*; a wrapper that added logic would be a
-- second path to the same table with weaker gates, which is the whole thing
-- this surface exists to prevent.
-- =============================================================================

create table erp_meta.public_write_allowance (
  function_name text primary key,
  -- The erp.* function this wrapper delegates to. Checked against prosrc, so
  -- removing the delegation fails the build rather than the review.
  gate          text not null,
  rationale     text not null check (length(trim(rationale)) >= 20)
);

comment on table erp_meta.public_write_allowance is
  'The public API functions permitted to write, each naming the gate its body '
  'must call. A volatile public.erp_* function absent from here fails '
  'erp.assert_public_api_safe().';

-- -----------------------------------------------------------------------------
-- Becoming a principal
-- -----------------------------------------------------------------------------

create or replace function public.erp_claim_invitation(p_token text)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('app_user_id', erp.claim_invitation(p_token))
$$;

comment on function public.erp_claim_invitation(text) is
  'Redeems an invitation token, binding this sign-in to the principal an '
  'administrator created. The one write reachable without a tenant context.';

-- -----------------------------------------------------------------------------
-- Administering people
-- -----------------------------------------------------------------------------

create or replace function public.erp_invite_principal(
  p_email        text,
  p_display_name text
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  -- The token is returned here and nowhere else, ever: erp.invitation stores
  -- only its digest. Whoever calls this is responsible for delivering it.
  select jsonb_build_object('app_user_id', i.app_user_id, 'token', i.token)
    from erp.invite_principal(p_email, p_display_name) i
$$;

create or replace function public.erp_create_service_principal(
  p_display_name text
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'app_user_id', erp.create_service_principal(p_display_name))
$$;

create or replace function public.erp_grant_role(
  p_app_user_id uuid,
  p_role_code   text,
  p_entity_id   uuid default null,
  p_site_id     uuid default null,
  p_reason      text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'user_role_id',
    erp.grant_role(p_app_user_id, p_role_code, p_entity_id, p_site_id, p_reason))
$$;

-- -----------------------------------------------------------------------------
-- Operating the platform
-- -----------------------------------------------------------------------------

create or replace function public.erp_trigger_job(
  p_job_code text,
  p_reason   text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('job_run_id', erp.trigger_job(p_job_code, p_reason))
$$;

create or replace function public.erp_submit_command(
  p_system_code     text,
  p_operation_code  text,
  p_payload         jsonb default '{}'::jsonb,
  p_dry_run         boolean default false,
  p_idempotency_key text default null
) returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'command_id',
    erp.submit_command(p_system_code, p_operation_code, p_payload, p_dry_run,
                       p_idempotency_key))
$$;

-- -----------------------------------------------------------------------------
-- The allow-list
-- -----------------------------------------------------------------------------

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_claim_invitation', 'erp.claim_invitation',
   'Runs before the caller has a principal, so erp.authorise() has nothing to '
   'scope to. Its gate is possession of a single-use token, checked inside '
   'erp.claim_invitation(), which is itself on the SECURITY DEFINER allow-list.'),
  ('erp_invite_principal', 'erp.invite_principal',
   'Creates a principal and returns its one-time token. Gated on '
   'administration.users inside erp.invite_principal().'),
  ('erp_create_service_principal', 'erp.create_service_principal',
   'Creates the non-human principal a worker runs as. Gated on '
   'administration.users inside erp.create_service_principal().'),
  ('erp_grant_role', 'erp.grant_role',
   'Grants a role, optionally narrowed to an entity or site. Gated on '
   'administration.roles inside erp.grant_role().'),
  ('erp_trigger_job', 'erp.trigger_job',
   'Runs a scheduled job out of band. Gated on administration.jobs inside '
   'erp.trigger_job(), which also refuses a job stopped by a kill switch.'),
  ('erp_submit_command', 'erp.submit_command',
   'Queues an outbound command through the B8 gateway, which authorises, '
   'validates the payload against the operation schema, and records it.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

do $$
declare
  f text;
begin
  foreach f in array array[
    'public.erp_claim_invitation(text)',
    'public.erp_invite_principal(text, text)',
    'public.erp_create_service_principal(text)',
    'public.erp_grant_role(uuid, text, uuid, uuid, text)',
    'public.erp_trigger_job(text, text)',
    'public.erp_submit_command(text, text, jsonb, boolean, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Rule 3, rewritten
-- -----------------------------------------------------------------------------

create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Rule 1. A definer function in public runs as the owner, who bypasses RLS.
  select 'a public API function is SECURITY DEFINER',
         p.oid::regprocedure::text,
         'it would run as the owner, who bypasses row-level security, and '
         'return every tenant''s rows'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.prosecdef
  union all
  -- Rule 2. Execute granted to anon.
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  -- Rule 3. A function that can write must have been declared as one.
  select 'a public API function writes but is not on the write allow-list',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; add it to '
         'erp_meta.public_write_allowance with a rationale, or make it STABLE'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'erp\_%'
     and p.provolatile = 'v'
     and not exists (
       select 1 from erp_meta.public_write_allowance w
        where w.function_name = p.proname)
  union all
  -- Rule 3b. And it must still call the gate it claims to.
  select 'a public API write function does not call its declared gate',
         p.oid::regprocedure::text,
         format('%s is on the allow-list gated by %s, but its body does not '
                'call it', p.proname, w.gate)
    from pg_catalog.pg_proc p
    join erp_meta.public_write_allowance w on w.function_name = p.proname
   where p.pronamespace = 'public'::regnamespace
     and position(w.gate || '(' in p.prosrc) = 0
  union all
  -- Rule 3c. An allow-list entry for a function that does not exist is a rule
  -- covering nothing, and reads as if the surface were still governed.
  select 'a write allow-list entry names no function', w.function_name,
         'nothing is being permitted, and nothing is being checked'
    from erp_meta.public_write_allowance w
   where not exists (
     select 1 from pg_catalog.pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = w.function_name)
  union all
  -- Rule 3d, the one that actually carries the promise. Following the gate one
  -- hop: the delegate must itself authorise, or be an enumerated SECURITY
  -- DEFINER exception whose rationale 0006 already holds. Without this the
  -- allow-list would only prove a wrapper calls something, not that anything
  -- checks permission.
  select 'a public API write function delegates to something that does not authorise',
         w.function_name,
         format('%s neither calls erp.authorise() nor appears in '
                'erp_meta.security_definer_allowance', w.gate)
    from erp_meta.public_write_allowance w
    join pg_catalog.pg_proc d
      on d.pronamespace = split_part(w.gate, '.', 1)::regnamespace
     and d.proname = split_part(w.gate, '.', 2)
   where position('erp.authorise(' in d.prosrc) = 0
     and not exists (
       select 1 from erp_meta.security_definer_allowance a
        where a.schema_name = split_part(w.gate, '.', 1)
          and a.function_name = split_part(w.gate, '.', 2))
$$;

select erp_meta.register_table('erp_meta', 'public_write_allowance', 'platform_internal',
  'The public API functions permitted to write, and the gate each must call.');

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_isolation();
