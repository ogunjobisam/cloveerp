-- =============================================================================
-- The superadmin console, part D — what is actually deployed
--
-- Reconciling this repository against the live database was done by hand
-- earlier in this project: thirteen chunks of catalogue comparison to establish
-- that live was five migrations behind and that eight routines differed only by
-- their comments. That work produced an answer and no way to ask the question
-- again.
--
-- This is the question, asked in one call. It deliberately reports raw counts
-- rather than a verdict: the repository half of the comparison lives in the
-- repository, and the screen holds it at build time. A database that tried to
-- tell you whether it matched the repo would be guessing about a thing it
-- cannot see.
-- =============================================================================

create or replace function public.erp_platform_deployment_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v          erp_meta.platform_staff;
  v_migs     jsonb := '[]'::jsonb;
  v_has_migs boolean;
begin
  v := erp_meta.require_platform('support');

  -- The Supabase CLI owns this table, so it is absent on a database built by
  -- replaying the files directly — as CI does. Saying so beats reporting an
  -- empty list, which would read as "nothing is applied".
  v_has_migs := to_regclass('supabase_migrations.schema_migrations') is not null;

  if v_has_migs then
    execute $q$
      select coalesce(jsonb_agg(jsonb_build_object('version', m.version, 'name', m.name)
                      order by m.version), '[]'::jsonb)
        from supabase_migrations.schema_migrations m
    $q$ into v_migs;
  end if;

  return jsonb_build_object(
    'migrations_known', v_has_migs,
    'migrations', v_migs,
    'counts', jsonb_build_object(
      'tables', (select count(*) from pg_catalog.pg_class c
                  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                 where c.relkind = 'r'
                   and n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')),
      'functions', (select count(*) from pg_catalog.pg_proc p
                     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')),
      'public_doors', (select count(*) from pg_catalog.pg_proc p
                        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname like 'erp\_%'),
      'write_doors', (select count(*) from pg_catalog.pg_proc p
                       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname like 'erp\_%'
                        and p.provolatile = 'v'),
      'policies', (select count(*) from pg_catalog.pg_policy),
      'triggers', (select count(*) from pg_catalog.pg_trigger where not tgisinternal),
      'suites', (select count(*) from pg_catalog.pg_proc p
                  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'erp_test' and p.proname like 'assert\_%\_suite'),
      'organisations', (select count(*) from erp.tenant where status <> 'deleted')),
    -- Every register, with its size. A register that has gone empty is a
    -- governance failure that looks like nothing at all.
    'registers', jsonb_build_object(
      'table_policy', (select count(*) from erp_meta.table_policy),
      'audit_exemption', (select count(*) from erp_meta.audit_exemption),
      'attribution_exemption', (select count(*) from erp_meta.attribution_exemption),
      'public_write_allowance', (select count(*) from erp_meta.public_write_allowance),
      'security_definer_allowance', (select count(*) from erp_meta.security_definer_allowance),
      'promotable_surface', (select count(*) from erp_meta.promotable_surface),
      'policy_decision', (select count(*) from erp_meta.policy_decision),
      'diagnostic_check', (select count(*) from erp_meta.diagnostic_check),
      'diagnostic_exemption', (select count(*) from erp_meta.diagnostic_exemption),
      'job_handler', (select count(*) from erp_ref.job_handler)),
    'generated_at', now());
end;
$$;

comment on function public.erp_platform_deployment_state is
  'What this database actually holds: applied migrations where the CLI recorded '
  'them, catalogue counts, and the size of every register. The repository half '
  'of the comparison is held by the screen at build time, because a database '
  'cannot see the repository it was built from.';

revoke all on function public.erp_platform_deployment_state() from public, anon;
grant execute on function public.erp_platform_deployment_state() to authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_platform_deployment_state',
        'Reads the catalogue and erp_meta across every organisation. erp_meta is '
        'platform_internal, so no session reaches it without a definer; gated on '
        'erp_meta.require_platform().')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_platform_deployment_state', 'erp_meta.require_platform',
        'Platform staff read, volatile only because its gate binds the caller''s '
        'identity on first use.')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
