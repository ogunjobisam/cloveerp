set lock_timeout = '30s';

-- =============================================================================
-- 20261012070000  A client is built from a template
-- -----------------------------------------------------------------------------
-- A client's database is built today by replaying every migration into its
-- empty project, which took three hours and twenty-five minutes for the
-- demonstration and grows with every migration. The build will restore a
-- template instead: a dump of the product's schemas, made once per train in
-- CI from the migrations before any organisation exists, proved there and
-- registered on the control plane. The replay stays as the fallback. This is
-- the database's half: what proves a restored template is the build it was
-- made from, where the templates are registered, and how each client was
-- built. The scripts that make and restore a template, the workflow that
-- makes, proves, keeps and registers one, the build's new method and the
-- Fleet view's column come in the same pull request.
--
--   A. The fingerprint. erp_meta.schema_fingerprint() answers a sha256 for
--      each part of the product's schema: its columns, constraints, indexes,
--      routines (what they take and give, how they run, their settings,
--      whether they run as their owner, and their bodies), views, policies,
--      row security, grants, triggers, types and sequences, and the rows the
--      migrations write (the reference tables in erp_ref, and the registers
--      and generated rows in erp_meta). It leaves out what is the database's
--      own and not the product's: every organisation's rows, the control
--      plane's register, contracts, incidents and operations (the schedule,
--      the audit, the settings, the staff, the releases), the address the
--      deployment's email links to, and every time anything was written. A
--      template restored and the build it was made from answer the same;
--      one body changed anywhere does not. erp_meta.schema_fingerprint_detail()
--      lists what it hashed, object by object, so two databases that differ
--      can be compared and the difference named.
--
--   B. The register of templates. erp_meta.provisioning_template, on the
--      control plane, keeps each template made: the commit, the newest
--      migration and how many there were, the dump's sha256, its fingerprint,
--      where it is kept and the run that proved it. A build restores only a
--      dump whose sha256 is registered. erp_meta.record_provisioning_template
--      records one, once by its dump (the same dump again is a replay, or
--      renews where it is kept), and erp_meta.provisioning_template_for finds
--      the newest for a build's migrations.
--
--   C. How each client was built. erp_meta.deployment.build_method is
--      'from_empty' or 'template', set by the build through
--      erp_meta.record_deployment_build_method while the deployment is being
--      built, which records a step naming the template; a template must be
--      registered. Every client built before this was built from empty, and
--      says so. The Fleet view carries it, and a build finished says which.
--
--   D. The proof: erp_test.a_client_is_built_from_a_template_suite
--      (seventeen cases) and its assertion. The fingerprint's falsification
--      is in it: each part of the schema changed alone changes its own part
--      and nothing else, a body put back gives the fingerprint back, and only
--      a database's own rows and times changed leave it as it was. The Fleet
--      view has forty-two keys now, which erp_test.deployment_lifecycle_suite,
--      erp_test.register_house_suite and
--      erp_test.a_client_holds_its_contract_suite count.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code, no public door's signature, and nothing an
-- organisation's people see. A build from empty is as it was, and stays the
-- default until a template build has been rehearsed live. Nothing here makes,
-- keeps or restores a dump: the scripts and workflows do, as the trusted
-- build role.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_TEMPLATE_INVALID',
  'Registering a template for building client databases in a form the register does not keep, or a dump '
  'registered already as the template of other migrations.',
  'A client''s database is restored from a registered template as the platform''s most trusted role, so the '
  'register keeps exactly what proves it: the commit it was made at, its newest migration and how many there were, '
  'the dump''s sha256, its fingerprint, where it is kept and the run that proved it. A dump known as one template '
  'is never recorded as another.',
  'Nothing was recorded. Record the template as template.yml made and proved it, with every one of those; if the '
  'dump was recorded already, read the register for what it was recorded as.');

select erp.register_refusal(
  'CLOVEERP_TEMPLATE_UNKNOWN',
  'Building a client deployment from a template whose dump is not in the register.',
  'A template is restored into a client''s database as the platform''s most trusted role. Only a dump the register '
  'holds was made from the migrations and proved before it was kept, so only one of those is built from.',
  'Build from empty instead, or wait for template.yml to make, prove and register the template for this train, '
  'then build again.');

select erp.register_refusal(
  'CLOVEERP_BUILD_METHOD_INVALID',
  'Recording that a client deployment is built in a way the register does not know.',
  'A client deployment is built from empty, replaying every migration, or from a registered template, and the '
  'Fleet view says which. A build from empty is made from no template, so naming one would record something that '
  'did not happen.',
  'Record that the client is built from empty, or from a template with the sha256 of the registered dump the '
  'build restores.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The fingerprint
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.schema_fingerprint_detail()
returns table(part text, object text, detail text)
language plpgsql
stable
set search_path = ''
as $$
declare
  -- The product's schemas, as the template dumps them; in public, only the
  -- product's own doors and objects (erp_*).
  c_schemas  constant text[] := array['erp', 'erp_ai', 'erp_ingress', 'erp_meta', 'erp_ref', 'erp_test', 'public'];
  -- The registers in erp_meta whose rows are this database's own: written
  -- while it runs, by its people, its console, its workflows or its jobs,
  -- never by a migration. Every other table in erp_meta, and every table in
  -- erp_ref, holds what the migrations wrote (20261012070000).
  c_own      constant text[] := array[
    'applied_push', 'commercial_email', 'company_owner', 'dependency_observation', 'drain_pass',
    'email_delivery_event', 'enquiry', 'fleet_request', 'index_rate', 'ownership_transfer', 'platform_audit',
    'platform_billing_details', 'platform_organisation', 'platform_schedule', 'platform_setting', 'platform_staff',
    'principal_preference', 'promotion_window', 'provisioning_template', 'release', 'renewal', 'restore_drill',
    'retired_tenant_code', 'usage_meter'];
  -- And whole families of them: the control plane's register of client
  -- deployments, contracts, incidents and maintenance, and the contract a
  -- client holds.
  c_own_family constant text := '^(contract|deployment|incident|maintenance_window|subscription)(_|$)';
  tb         record;
  v_left     text[];
  v_filter   text;
  v_n        bigint;
  v_digest   text;
begin
  -- The parts, object by object. Names, never internal ids: a template
  -- restored has other ids than the build it was made from. Every list is
  -- ordered byte by byte, whatever the database's collation.
  return query
  with rel as (
    select c.oid, n.nspname, c.relname, c.relkind, c.relowner, c.relacl, c.relrowsecurity, c.relforcerowsecurity,
           c.reloptions
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = any(c_schemas)
       and (n.nspname <> 'public' or c.relname like 'erp\_%')
       and c.relkind in ('r', 'p', 'v', 'm', 'f', 'S', 'c')
       and not exists (select 1 from pg_catalog.pg_depend d
                        where d.classid = 'pg_catalog.pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
  ),
  fn as (
    select p.oid, n.nspname, p.proname, p.prokind, p.prosecdef, p.provolatile, p.proisstrict, p.proleakproof,
           p.proparallel, p.procost, p.prorows, p.proconfig, p.prosrc, p.prosqlbody is not null as sql_body,
           p.proowner, p.proacl, l.lanname
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_language l on l.oid = p.prolang
     where n.nspname = any(c_schemas)
       and (n.nspname <> 'public' or p.proname like 'erp\_%')
       and not exists (select 1 from pg_catalog.pg_depend d
                        where d.classid = 'pg_catalog.pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  ),
  acl as (
    -- The schema public is the host's; the product's own schemas are not.
    select 'schema ' || n.nspname as object, n.nspacl as acl, 'n'::"char" as kind, n.nspowner as owner
      from pg_catalog.pg_namespace n
     where n.nspname = any(c_schemas) and n.nspname <> 'public'
    union all
    select case r.relkind when 'S' then 'sequence ' else 'relation ' end || r.nspname || '.' || r.relname,
           r.relacl, case r.relkind when 'S' then 's' else 'r' end::"char", r.relowner
      from rel r
     where r.relkind <> 'c'
    union all
    select 'column ' || r.nspname || '.' || r.relname || '.' || a.attname, a.attacl, 'c'::"char", r.relowner
      from rel r
      join pg_catalog.pg_attribute a on a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped
     where a.attacl is not null
    union all
    select 'function ' || f.nspname || '.' || f.proname || '(' || pg_catalog.pg_get_function_identity_arguments(f.oid) || ')',
           f.proacl, 'f'::"char", f.proowner
      from fn f
  )
  -- Columns, in their order, with their type, nullability, identity,
  -- generation, default and collation.
  select 'columns'::text, x.nspname || '.' || x.relname || '.' || x.attname,
         concat_ws(' ', 'at', x.position, x.type,
                   case when x.attnotnull then 'not null' end,
                   case when x.attidentity <> '' then 'identity ' || x.attidentity::text end,
                   case when x.attgenerated <> '' then 'generated ' || x.attgenerated::text end,
                   'default ' || x.def, 'collate ' || x.coll)
    from (select r.nspname, r.relname, a.attname, a.attnotnull, a.attidentity, a.attgenerated,
                 row_number() over (partition by r.oid order by a.attnum) as position,
                 pg_catalog.format_type(a.atttypid, a.atttypmod) as type,
                 pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) as def,
                 case when a.attcollation <> t.typcollation then co.collname::text end as coll
            from rel r
            join pg_catalog.pg_attribute a on a.attrelid = r.oid and a.attnum > 0 and not a.attisdropped
            join pg_catalog.pg_type t on t.oid = a.atttypid
            left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
            left join pg_catalog.pg_collation co on co.oid = a.attcollation
           where r.relkind in ('r', 'p', 'v', 'm', 'f')) x
  union all
  -- Constraints, on tables and on domains.
  select 'constraints', n.nspname || '.' || coalesce(c.relname, t.typname) || '.' || con.conname,
         pg_catalog.pg_get_constraintdef(con.oid)
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_namespace n on n.oid = con.connamespace
    left join pg_catalog.pg_class c on c.oid = con.conrelid
    left join pg_catalog.pg_type t on t.oid = con.contypid
   where n.nspname = any(c_schemas)
     and (n.nspname <> 'public' or coalesce(c.relname, t.typname) like 'erp\_%')
  union all
  select 'indexes', r.nspname || '.' || ic.relname, pg_catalog.pg_get_indexdef(i.indexrelid)
    from pg_catalog.pg_index i
    join rel r on r.oid = i.indrelid
    join pg_catalog.pg_class ic on ic.oid = i.indexrelid
  union all
  -- Routines: what they take and give, how they run, their settings,
  -- whether they run as their owner, and their bodies.
  select 'functions', f.nspname || '.' || f.proname || '(' || pg_catalog.pg_get_function_identity_arguments(f.oid) || ')',
         concat_ws(' ', 'kind', f.prokind, 'language', f.lanname,
                   'arguments', pg_catalog.pg_get_function_arguments(f.oid),
                   'returns', pg_catalog.pg_get_function_result(f.oid),
                   case when f.prosecdef then 'security definer' else 'security invoker' end,
                   'volatility', f.provolatile, case when f.proisstrict then 'strict' end,
                   case when f.proleakproof then 'leakproof' end, 'parallel', f.proparallel,
                   'cost', f.procost, 'rows', f.prorows,
                   'set', (select string_agg(s, ',' order by s collate "C") from unnest(f.proconfig) s),
                   'body', encode(sha256(convert_to(
                             case when f.sql_body then pg_catalog.pg_get_functiondef(f.oid) else f.prosrc end,
                             'UTF8')), 'hex'))
    from fn f
  union all
  select 'views', r.nspname || '.' || r.relname,
         concat_ws(' ', case r.relkind when 'v' then 'view' else 'materialized view' end,
                   'options', (select string_agg(o, ',' order by o collate "C") from unnest(r.reloptions) o),
                   'definition', encode(sha256(convert_to(pg_catalog.pg_get_viewdef(r.oid), 'UTF8')), 'hex'))
    from rel r
   where r.relkind in ('v', 'm')
  union all
  select 'policies', r.nspname || '.' || r.relname || '.' || pol.polname,
         concat_ws(' ', case when pol.polpermissive then 'permissive' else 'restrictive' end,
                   'for', pol.polcmd,
                   'to', (select string_agg(g.name, ',' order by g.name collate "C")
                            from (select case when x.oid = 0 then 'public' else ro.rolname::text end as name
                                    from unnest(pol.polroles) x(oid)
                                    left join pg_catalog.pg_roles ro on ro.oid = x.oid) g),
                   'using', pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),
                   'check', pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid))
    from pg_catalog.pg_policy pol
    join rel r on r.oid = pol.polrelid
  union all
  select 'row_security', r.nspname || '.' || r.relname,
         case when r.relrowsecurity then 'enabled' else 'disabled' end || ' '
         || case when r.relforcerowsecurity then 'forced' else 'not forced' end
    from rel r
   where r.relkind in ('r', 'p')
  union all
  -- Who may do what, by name; the owner as "owner", whoever it is, and no
  -- grantor, since a template is restored by another role than built it.
  select 'grants', a.object,
         coalesce((select string_agg(g.privilege, ',' order by g.privilege collate "C")
                     from (select case when x.grantee = 0 then 'public'
                                       when x.grantee = a.owner then 'owner'
                                       else coalesce(ro.rolname::text, x.grantee::text) end
                                  || '=' || x.privilege_type || case when x.is_grantable then '+' else '' end as privilege
                             from pg_catalog.aclexplode(coalesce(a.acl, pg_catalog.acldefault(a.kind, a.owner))) x
                             left join pg_catalog.pg_roles ro on ro.oid = x.grantee) g), 'none')
    from acl a
  union all
  select 'triggers', r.nspname || '.' || r.relname || '.' || t.tgname,
         pg_catalog.pg_get_triggerdef(t.oid) || ' enabled ' || t.tgenabled::text
    from pg_catalog.pg_trigger t
    join rel r on r.oid = t.tgrelid
   where not t.tgisinternal
  union all
  -- Enumerations by their labels in order (not their sort positions, which
  -- a dump renumbers), domains, and composite types.
  select 'types', n.nspname || '.' || t.typname,
         case t.typtype
           when 'e' then 'enum ' || coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder)
                                                from pg_catalog.pg_enum e where e.enumtypid = t.oid), '')
           when 'd' then concat_ws(' ', 'domain', pg_catalog.format_type(t.typbasetype, t.typtypmod),
                                   case when t.typnotnull then 'not null' end, 'default ' || t.typdefault)
           when 'c' then 'composite ' || coalesce((select string_agg(a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod),
                                                                     ',' order by a.attnum)
                                                     from pg_catalog.pg_attribute a
                                                    where a.attrelid = t.typrelid and a.attnum > 0 and not a.attisdropped), '')
           else 'type ' || t.typtype::text
         end
    from pg_catalog.pg_type t
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
   where n.nspname = any(c_schemas)
     and (n.nspname <> 'public' or t.typname like 'erp\_%')
     and t.typtype in ('e', 'd', 'c', 'r', 'm')
     and (t.typtype <> 'c' or exists (select 1 from rel r where r.oid = t.typrelid and r.relkind = 'c'))
     and not exists (select 1 from pg_catalog.pg_depend d
                      where d.classid = 'pg_catalog.pg_type'::regclass and d.objid = t.oid and d.deptype = 'e')
  union all
  -- Sequences as they are declared, never how far they have counted.
  select 'sequences', r.nspname || '.' || r.relname,
         concat_ws(' ', pg_catalog.format_type(s.seqtypid, null), 'start', s.seqstart, 'by', s.seqincrement,
                   'min', s.seqmin, 'max', s.seqmax, 'cache', s.seqcache, case when s.seqcycle then 'cycle' end)
    from rel r
    join pg_catalog.pg_sequence s on s.seqrelid = r.oid;

  -- The rows the migrations write, table by table: every table in erp_ref and
  -- in erp_meta but the database's own. Each row as its values by name, less
  -- every time and date-time, every identity, and every column whose default
  -- is not fixed (a time, a fresh id, a sequence, today): those say when or
  -- in which build a row was written, not what it says. The address the
  -- deployment's email links to (erp_ref.resource app.base_url) is the
  -- deployment's own, written by erp_meta.set_deployment_identity.
  for tb in
    select c.oid, n.nspname, c.relname
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('erp_meta', 'erp_ref')
       and c.relkind in ('r', 'p')
       and not (n.nspname = 'erp_meta' and (c.relname = any(c_own) or c.relname ~ c_own_family))
     order by n.nspname collate "C", c.relname collate "C"
  loop
    select array_agg(a.attname::text order by a.attname collate "C")
      into v_left
      from pg_catalog.pg_attribute a
      left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
     where a.attrelid = tb.oid and a.attnum > 0 and not a.attisdropped
       and (a.atttypid in ('timestamp'::regtype, 'timestamptz'::regtype, 'time'::regtype, 'timetz'::regtype)
            or a.attidentity <> ''
            or (ad.oid is not null
                and (pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)
                       ~* '\m(current_date|current_time|current_timestamp|localtime|localtimestamp|current_user|session_user|current_role|user)\M'
                     or exists (select 1
                                  from regexp_matches(pg_catalog.pg_get_expr(ad.adbin, ad.adrelid),
                                                      '([a-z_][a-z0-9_]*)\(', 'gi') m(x)
                                  join pg_catalog.pg_proc pp on pp.proname = lower(m.x[1])
                                 where pp.provolatile <> 'i'))));
    v_filter := case when tb.nspname = 'erp_ref' and tb.relname = 'resource'
                     then 'where t.key <> ''app.base_url''' else '' end;
    execute format(
      'select count(*), encode(sha256(convert_to(coalesce(string_agg(s.x, E''\n'' order by s.x collate "C"), ''''), '
      '''UTF8'')), ''hex'') from (select (to_jsonb(t) - $1)::text as x from %I.%I t %s) s',
      tb.nspname, tb.relname, v_filter)
      into v_n, v_digest
      using coalesce(v_left, array[]::text[]);
    part := 'rows';
    object := tb.nspname || '.' || tb.relname;
    detail := concat_ws(' ', v_n, 'rows', v_digest, 'leaving out',
                        coalesce(array_to_string(v_left, ','), 'nothing'));
    return next;
  end loop;
end;
$$;

create or replace function erp_meta.schema_fingerprint()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- One sha256 for each part, over its objects and what each is, in byte
  -- order; a part with nothing in it is the hash of nothing, so every part is
  -- always named. The version says how it was computed (20261012070000).
  select jsonb_build_object('version', 1)
         || jsonb_object_agg(p.part, encode(sha256(convert_to(coalesce(x.listing, ''), 'UTF8')), 'hex'))
    from unnest(array['columns', 'constraints', 'indexes', 'functions', 'views', 'policies', 'row_security',
                      'grants', 'triggers', 'types', 'sequences', 'rows']) as p(part)
    left join (select d.part, string_agg(d.object || E'\t' || d.detail, E'\n' order by d.object collate "C") as listing
                 from erp_meta.schema_fingerprint_detail() d
                group by d.part) x on x.part = p.part
$$;

revoke all on function erp_meta.schema_fingerprint_detail() from public, anon, authenticated, service_role;
revoke all on function erp_meta.schema_fingerprint() from public, anon, authenticated, service_role;

comment on function erp_meta.schema_fingerprint_detail() is
  'What erp_meta.schema_fingerprint() hashes, object by object: {part, object, detail}, for comparing two databases '
  'and naming what differs. The product''s schemas only (erp, erp_ai, erp_ingress, erp_meta, erp_ref, erp_test, and '
  'public''s erp_* objects); by name, never internal id; the rows of erp_ref and erp_meta but the database''s own '
  'registers, less every time and every value a build or its day decides. Trusted build role only (20261012070000).';
comment on function erp_meta.schema_fingerprint() is
  'A sha256 for each part of the product''s schema (columns, constraints, indexes, functions with their settings '
  'and security mode, views, policies, row_security, grants, triggers, types, sequences, and the rows the migrations '
  'write), with the version of how it was computed. A template restored answers what the build it was made from '
  'answered; it leaves out every organisation''s rows, the control plane''s register, the schedule, the audit, the '
  'settings, the staff, the releases, the deployment''s address and every time. Trusted build role only '
  '(20261012070000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The register of templates, on the control plane
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp_meta.provisioning_template (
  id               uuid primary key default gen_random_uuid(),
  git_sha          text not null check (git_sha ~ '^[0-9a-f]{40}$'),
  newest_migration text not null check (newest_migration ~ '^[0-9]{14}$'),
  migration_count  integer not null check (migration_count > 0),
  dump_sha256      text not null unique check (dump_sha256 ~ '^[0-9a-f]{64}$'),
  fingerprint      jsonb not null check (jsonb_typeof(fingerprint) = 'object'),
  storage_key      text not null check (length(storage_key) between 1 and 500
                                        and storage_key !~ '[[:space:][:cntrl:]]'),
  proving_run_id   text not null check (proving_run_id ~ '^[0-9]{1,20}$'),
  recorded_at      timestamptz not null default clock_timestamp()
);

-- The newest template for a build's migrations.
create index if not exists provisioning_template_migrations
  on erp_meta.provisioning_template (newest_migration, migration_count, recorded_at desc);

comment on table erp_meta.provisioning_template is
  'On the control plane, every template a client''s database may be built from: a dump of the product''s schemas made '
  'in CI from the migrations before any organisation existed, restored and proved there, and kept. The commit it was '
  'made at, its newest migration and how many there were, the dump''s sha256 (a build restores no other), its '
  'fingerprint (erp_meta.schema_fingerprint() of the build it was made from), where it is kept and the run that '
  'proved it. Written only by erp_meta.record_provisioning_template (20261012070000).';
comment on column erp_meta.provisioning_template.storage_key is
  'Where the dump is kept: its key in the offsite bucket, or the Actions artifact that holds it, as template.yml '
  'wrote it. A dump recorded again from a later run renews it.';
comment on column erp_meta.provisioning_template.recorded_at is
  'When the template was recorded, or recorded again where it is kept now.';

select erp_meta.register_table('erp_meta', 'provisioning_template', 'platform_internal',
  'The templates a client''s database may be built from, registered on the control plane by template.yml.');

revoke all on table erp_meta.provisioning_template from public, anon, authenticated;

create or replace function erp_meta.record_provisioning_template(
  p_git_sha text, p_newest_migration text, p_migration_count integer, p_dump_sha256 text,
  p_fingerprint jsonb, p_storage_key text, p_proving_run_id text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_sha     text := lower(btrim(coalesce(p_git_sha, '')));
  v_newest  text := btrim(coalesce(p_newest_migration, ''));
  v_dump    text := lower(btrim(coalesce(p_dump_sha256, '')));
  v_key     text := btrim(coalesce(p_storage_key, ''));
  v_run     text := btrim(coalesce(p_proving_run_id, ''));
  v_part    text;
  v_fault   text;
  v_held    erp_meta.provisioning_template;
  v_row     erp_meta.provisioning_template;
  v_outcome text;
begin
  -- The register is the control plane's: a client and the demonstration are
  -- built from it and never keep one (20261012070000).
  perform erp.require_control_plane();

  -- Each particular in its form; one that is not refuses the lot.
  if v_sha !~ '^[0-9a-f]{40}$' then
    v_fault := 'the commit is not a forty-character git sha';
  elsif v_newest !~ '^[0-9]{14}$' then
    v_fault := 'the newest migration is not a fourteen-digit version';
  elsif p_migration_count is null or p_migration_count < 1 then
    v_fault := 'the number of migrations is not one or more';
  elsif v_dump !~ '^[0-9a-f]{64}$' then
    v_fault := 'the dump''s sha256 is not sixty-four hexadecimal characters';
  elsif p_fingerprint is null or jsonb_typeof(p_fingerprint) <> 'object' then
    v_fault := 'the fingerprint is not a set of named hashes';
  elsif jsonb_typeof(p_fingerprint -> 'version') is distinct from 'number' then
    v_fault := 'the fingerprint does not say its version';
  elsif not exists (select 1 from jsonb_each(p_fingerprint) e where e.key <> 'version') then
    v_fault := 'the fingerprint has no part';
  else
    select min(e.key) into v_part
      from jsonb_each(p_fingerprint) e
     where e.key <> 'version'
       and (e.key !~ '^[a-z][a-z_]*$' or jsonb_typeof(e.value) <> 'string' or e.value #>> '{}' !~ '^[0-9a-f]{64}$');
    if v_part is not null then
      v_fault := format('the fingerprint''s part %s is not a sha256', v_part);
    elsif length(v_key) not between 1 and 500 or v_key ~ '[[:space:][:cntrl:]]' then
      v_fault := 'where it is kept is blank, longer than five hundred characters, or holds a space';
    elsif v_run !~ '^[0-9]{1,20}$' then
      v_fault := 'the run that proved it is not a workflow run id';
    end if;
  end if;

  -- A dump is one template: recorded again as the same is a replay, or
  -- renews where it is kept and which run proved it; recorded as another is
  -- refused.
  if v_fault is null then
    select * into v_held from erp_meta.provisioning_template t where t.dump_sha256 = v_dump;
    if v_held.id is not null
       and (v_held.newest_migration <> v_newest or v_held.migration_count <> p_migration_count
            or v_held.fingerprint <> p_fingerprint) then
      v_fault := format('a dump with this sha256 is recorded already as the template of %s migrations to %s, '
                        'with its own fingerprint', v_held.migration_count, v_held.newest_migration);
    end if;
  end if;

  if v_fault is not null then
    raise exception 'CLOVEERP_TEMPLATE_INVALID: the template is not recorded: %', v_fault
      using errcode = '22023',
            hint = 'Record the template as template.yml made and proved it: the commit, its newest migration and how '
                   'many there were, the dump''s sha256, its fingerprint, where it is kept and the run that proved it.';
  end if;

  if v_held.id is null then
    insert into erp_meta.provisioning_template
      (git_sha, newest_migration, migration_count, dump_sha256, fingerprint, storage_key, proving_run_id, recorded_at)
    values (v_sha, v_newest, p_migration_count, v_dump, p_fingerprint, v_key, v_run, clock_timestamp())
    returning * into v_row;
    v_outcome := 'recorded';
  elsif v_held.git_sha = v_sha and v_held.storage_key = v_key and v_held.proving_run_id = v_run then
    v_row := v_held;
    v_outcome := 'replay';
  else
    update erp_meta.provisioning_template t
       set git_sha = v_sha, storage_key = v_key, proving_run_id = v_run, recorded_at = clock_timestamp()
     where t.id = v_held.id
    returning * into v_row;
    v_outcome := 'renewed';
  end if;

  return to_jsonb(v_row) || jsonb_build_object('outcome', v_outcome);
end;
$$;

create or replace function erp_meta.provisioning_template_for(p_newest_migration text, p_migration_count integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The newest template made from exactly these migrations, or null
  -- (20261012070000).
  select to_jsonb(t)
    from erp_meta.provisioning_template t
   where t.newest_migration = btrim(coalesce(p_newest_migration, ''))
     and t.migration_count = p_migration_count
   order by t.recorded_at desc, t.dump_sha256
   limit 1
$$;

revoke all on function erp_meta.record_provisioning_template(text, text, integer, text, jsonb, text, text)
  from public, anon, authenticated, service_role;
revoke all on function erp_meta.provisioning_template_for(text, integer) from public, anon, authenticated, service_role;

comment on function erp_meta.record_provisioning_template(text, text, integer, text, jsonb, text, text) is
  'Called by template.yml on the control plane once a template is made, restored, proved and kept: the commit, the '
  'newest migration, how many migrations, the dump''s sha256, its fingerprint ({version, part: sha256, ...}), where '
  'it is kept and the run that proved it. One row per dump: the same again is answered replay, from a later run or '
  'kept elsewhere renewed. Answers the row with its outcome; refuses CLOVEERP_TEMPLATE_INVALID for particulars not in '
  'their form or a dump recorded as another template, and CLOVEERP_NOT_THE_CONTROL_PLANE anywhere else. Trusted '
  'build role only (20261012070000).';
comment on function erp_meta.provisioning_template_for(text, integer) is
  'The newest registered template made from exactly these migrations (the newest version and how many), as the row, '
  'or null when none is: what a build from a template restores and checks the dump and fingerprint against. Trusted '
  'build role only (20261012070000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. How each client was built
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.deployment add column if not exists build_method text;

do $$
begin
  if not exists (select 1 from pg_catalog.pg_constraint
                  where conrelid = 'erp_meta.deployment'::regclass and conname = 'deployment_build_method_is_known') then
    alter table erp_meta.deployment
      add constraint deployment_build_method_is_known check (build_method in ('from_empty', 'template'));
  end if;
end
$$;

comment on column erp_meta.deployment.build_method is
  'How the client''s database was built: from_empty (every migration replayed) or template (a registered template '
  'restored). Set by the build through erp_meta.record_deployment_build_method while it is being built; null until '
  'it says. Every client built before 20261012070000 was built from empty.';

-- Every client built until now was built from empty: no other way existed.
update erp_meta.deployment d
   set build_method = 'from_empty'
 where d.build_method is null and d.built_at is not null;

create or replace function erp_meta.record_deployment_build_method(p_code text, p_method text, p_dump_sha256 text default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  d        erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_dump   text := nullif(lower(btrim(coalesce(p_dump_sha256, ''))), '');
  t        erp_meta.provisioning_template;
  v_said   text;
begin
  -- From empty, or from a registered template, said once the build knows
  -- which and again if a retry builds the other way (20261012070000).
  if v_method not in ('from_empty', 'template') then
    raise exception 'CLOVEERP_BUILD_METHOD_INVALID: "%" is not how a client deployment is built', p_method
      using errcode = '22023',
            hint = 'Record from_empty, or template with the sha256 of the registered dump the build restores.';
  end if;
  if v_method = 'from_empty' and v_dump is not null then
    raise exception 'CLOVEERP_BUILD_METHOD_INVALID: a build from empty replays every migration and restores no template, and % was named', v_dump
      using errcode = '22023',
            hint = 'Record from_empty alone, or template with the sha256 of the registered dump the build restores.';
  end if;
  if v_method = 'template' then
    select * into t from erp_meta.provisioning_template x where x.dump_sha256 = v_dump;
    if t.id is null then
      raise exception 'CLOVEERP_TEMPLATE_UNKNOWN: no template whose dump has the sha256 % is registered', coalesce(v_dump, '(none given)')
        using errcode = '23503',
              hint = 'Build from empty instead, or wait for template.yml to make, prove and register the template for this train.';
    end if;
  end if;
  if d.status not in ('requested', 'creating', 'building', 'failed') then
    raise exception 'CLOVEERP_DEPLOYMENT_STATE: % is %, and only a deployment being built says how it is built', d.code, d.status
      using errcode = '55000',
            hint = 'Read the deployment''s events in the Fleet view; the workflow run that recorded the step says what it did.';
  end if;

  update erp_meta.deployment x set build_method = v_method, updated_at = now() where x.code = d.code;
  v_said := case v_method
              when 'template' then format('building from the template of %s migrations to %s, made at %s and proved by run %s',
                                          t.migration_count, t.newest_migration, left(t.git_sha, 12), t.proving_run_id)
              else 'building from empty, replaying every migration'
            end;
  perform erp_meta.record_deployment_event(d.code, 'build', 'note', v_said);
  return format('%s: %s', d.code, v_said);
end;
$$;

revoke all on function erp_meta.record_deployment_build_method(text, text, text) from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_build_method(text, text, text) is
  'Called by the build (deployment_from_empty.yml) on the control plane once it knows how a client is built: '
  'from_empty, or template with the sha256 of the registered dump it restores. Sets erp_meta.deployment.build_method '
  'and records a step naming the template, while the deployment is requested, being made or built, or failed; a '
  'retry may build the other way. Refuses CLOVEERP_BUILD_METHOD_INVALID, CLOVEERP_TEMPLATE_UNKNOWN for a dump not '
  'registered, and CLOVEERP_DEPLOYMENT_STATE once built. Trusted build role only (20261012070000).';

-- The Fleet view, the build's last word, and the suites that count the
-- Fleet view's keys, as this migration was written against them.
do $do$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select x.sig, x.anchor,
           array_agg(x.old order by x.ord) as olds,
           array_agg(x.new order by x.ord) as news
      from (values
        -- The Fleet view: how each client was built.
        ('public.erp_platform_deployments()', '84b188eef9a3332cd0185244585da1d1', 1,
$o$             'built_at', d.built_at,
$o$,
$n$             'built_at', d.built_at,
             -- How it was built: from_empty (every migration replayed) or
             -- template (a registered template restored); null until the
             -- build says (20261012070000).
             'build_method', d.build_method,
$n$),
        -- A build finished says how it was built.
        ('erp_meta.deployment_built(text)', 'e4c4630df41473f5d82645af3394b57f', 1,
$o$  perform erp_meta.record_deployment_event(d.code, 'build', 'done', 'built from empty and proved');
$o$,
$n$  -- As it was built: from a registered template, or from empty
  -- (20261012070000).
  perform erp_meta.record_deployment_event(d.code, 'build', 'done',
    case when d.build_method = 'template' then 'built from a template and proved' else 'built from empty and proved' end);
$n$),
        -- The Fleet view's keys, counted.
        ('erp_test.register_house_suite()', '987c1807503677a25905c14b03e33a8d', 1,
$o$                 'commercial']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 41
$o$,
$n$                 'commercial',
                 -- How it was built (20261012070000).
                 'build_method']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 42
$n$),
        ('erp_test.deployment_lifecycle_suite()', '36a8015296da837625e15322fb3e6871', 1,
$o$          -- Forty-one with the commercial key (20261012040000).
          and (select count(*) from jsonb_object_keys(v_row)) = 41
$o$,
$n$          -- Forty-two with the build method (20261012070000).
          and (select count(*) from jsonb_object_keys(v_row)) = 42
$n$),
        ('erp_test.a_client_holds_its_contract_suite()', '2293736fd2b3e6ff3f9d418777056a9f', 1,
$o$          and (select count(*) from jsonb_object_keys(v_row)) = 41
$o$,
$n$          -- Forty-two with the build method (20261012070000).
          and (select count(*) from jsonb_object_keys(v_row)) = 42
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012070000') > 0 then
      raise notice '% already carries 20261012070000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    for i in 1 .. cardinality(r.olds) loop
      if (length(v_def) - length(replace(v_def, r.olds[i], ''))) / length(r.olds[i]) <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor % exactly once', r.sig, i;
      end if;
      v_def := replace(v_def, r.olds[i], r.news[i]);
    end loop;
    execute v_def;
  end loop;
end
$do$;

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, how it was built (from empty or from a '
  'template), its last release, its health as the poll last read it, when, and whether one that is up has gone '
  'silent (unread for twenty-six hours), where it is served and the newest address it was moved from that still '
  'leads there, when its offboarding began and the day it may be purged, why it is suspended and since when, its '
  'last export, when that copy''s dump began and whether its service was stopped by then, and what it is owed and '
  'holds of its contract with its usage by meter, for the Fleet view. Platform support and above, on the control '
  'plane only (20261011020000, 20261011110000, 20261012010000, 20261012030000, 20261012040000, 20261012070000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.a_client_is_built_from_a_template_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  c_parts    constant text[] := array['columns', 'constraints', 'functions', 'grants', 'indexes', 'policies',
                                      'row_security', 'rows', 'sequences', 'triggers', 'types', 'version', 'views'];
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step     text := 'reading the fingerprint';
  v_state    text;
  v_kind     text := erp.deployment_kind();
  v_settings jsonb := (select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb)
                         from erp_meta.platform_setting s where s.key like 'deployment.%');
  v_base_url jsonb := (select coalesce(jsonb_object_agg(r.locale, r.value), '{}'::jsonb)
                         from erp_ref.resource r where r.key = 'app.base_url');
  v_held0    bigint := (select count(*) from erp_meta.provisioning_template);
  ow         uuid := gen_random_uuid();
  rp         record;
  v_table    text;
  v_view     text;
  v_fn       text;
  v_trg      text;
  v_dom      text;
  v_ocode    text;
  v_acode    text;
  v_bcode    text;
  v_ccode    text;
  v_sha      text;
  v_sha2     text;
  v_dump     text;
  v_dump2    text;
  v_newest   text := '20261012070000';
  v_count    integer := 805;
  v_f0       jsonb;
  v_f1       jsonb;
  v_f2       jsonb;
  v_f3       jsonb;
  v_f4       jsonb;
  v_f5       jsonb;
  v_f6       jsonb;
  v_fa       jsonb;
  v_fb       jsonb;
  v_fc       jsonb;
  v_fd       jsonb;
  v_t1       jsonb;
  v_t2       jsonb;
  v_t3       jsonb;
  v_t4       jsonb;
  v_t5       jsonb;
  v_row      jsonb;
  v_row2     jsonb;
  v_d1       text;
  v_d2       text;
  v_d3       text;
  v_d4       text;
  v_d5       text;
  v_d6       text;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_got4     text;
  v_got5     text;
  v_got6     text;
  v_said     text;
  v_said2    text;
  v_faults   text[] := array[]::text[];
  v_ok       boolean;
  v_n        integer;
  v_n2       integer;
  v_n3       integer;
  f          record;
begin
  begin
    v_table := 'zzfp_' || v_tag;
    v_view := 'zzfpv_' || v_tag;
    v_fn := 'zzfpf_' || v_tag;
    v_trg := 'zzfpt_' || v_tag;
    v_dom := 'zzfpd_' || v_tag;
    v_ocode := 'zzfp-' || v_tag;
    v_acode := 'zzfpa-' || v_tag;
    v_bcode := 'zzfpb-' || v_tag;
    v_ccode := 'zzfpc-' || v_tag;
    v_sha := md5('a' || v_tag) || substr(md5('b' || v_tag), 1, 8);
    v_sha2 := md5('c' || v_tag) || substr(md5('d' || v_tag), 1, 8);
    v_dump := md5('e' || v_tag) || md5('f' || v_tag);
    v_dump2 := md5('g' || v_tag) || md5('h' || v_tag);

    -- The control plane's marker, undone at the end with everything else.
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'a_client_is_built_from_a_template_suite');

    -- ── 1. Its shape ───────────────────────────────────────────────────────
    v_f0 := erp_meta.schema_fingerprint();
    v_f1 := erp_meta.schema_fingerprint();
    v_cases := v_cases + 1;
    case_name := 'the fingerprint is a sha256 for each part of the schema and its version, the same each time it is read';
    passed := (select array_agg(k order by k collate "C") from jsonb_object_keys(v_f0) k) = c_parts
          and v_f0 -> 'version' = '1'::jsonb
          and (select bool_and(v_f0 ->> k ~ '^[0-9a-f]{64}$') from unnest(c_parts) k where k <> 'version')
          and v_f0 = v_f1
          and (select count(distinct d.part) from erp_meta.schema_fingerprint_detail() d) = 12;
    detail := format('%s part(s), the same twice: %s', (select count(*) from jsonb_object_keys(v_f0)) - 1, v_f0 = v_f1);
    return next;

    -- ── 2. What it reads and leaves out ────────────────────────────────────
    v_step := 'reading what the fingerprint hashed';
    select count(*) filter (where d.part = 'rows' and d.object in ('erp_ref.refusal', 'erp_meta.invoker_reach',
                                                                   'erp_meta.table_policy', 'erp_meta.security_definer_allowance',
                                                                   'erp_meta.plan', 'erp_ref.resource')),
           count(*) filter (where d.part = 'rows' and (d.object like 'erp.%' or d.object like 'erp_ai.%'
                                                       or d.object in ('erp_meta.platform_audit', 'erp_meta.platform_schedule',
                                                                       'erp_meta.platform_setting', 'erp_meta.platform_staff',
                                                                       'erp_meta.release', 'erp_meta.deployment',
                                                                       'erp_meta.deployment_event', 'erp_meta.contract',
                                                                       'erp_meta.incident', 'erp_meta.provisioning_template',
                                                                       'erp_meta.subscription_position', 'erp_meta.usage_meter'))),
           count(*) filter (where d.part = 'functions' and d.object = 'erp_meta.schema_fingerprint()'
                              and d.detail like '% security invoker %' and d.detail like '% set search_path=""%'),
           max(d.detail) filter (where d.part = 'rows' and d.object = 'erp_ref.refusal'),
           max(d.detail) filter (where d.part = 'rows' and d.object = 'erp_ref.resource'),
           max(d.detail) filter (where d.part = 'grants' and d.object = 'function erp_meta.schema_fingerprint()')
      into v_n, v_n2, v_n3, v_got, v_got2, v_got3
      from erp_meta.schema_fingerprint_detail() d;
    v_cases := v_cases + 1;
    case_name := 'it reads the product''s reference and generated rows, routines and grants, and leaves out organisations, the register, operations, the deployment''s address and every time';
    passed := v_n = 6 and v_n2 = 0 and v_n3 = 1
          and v_got like '% rows % leaving out registered_at'
          and split_part(v_got2, ' ', 1)::integer
              = (select count(*) from erp_ref.resource r where r.key <> 'app.base_url')
          and v_got3 = 'owner=EXECUTE';
    detail := format('%s of 6 read, %s left out read, %s routine; %s / %s / %s', v_n, v_n2, v_n3,
                     left(v_got, 30), left(v_got2, 20), v_got3);
    return next;

    -- The objects the next cases change, one part at a time.
    v_step := 'standing up the objects the suite changes';
    -- A time with no default, and an id each build makes afresh: what a row
    -- says is its code and its number, not these.
    execute format('create table erp_meta.%I (code text primary key, n integer not null default 0, at timestamptz, '
                   'made uuid not null default gen_random_uuid())', v_table);
    execute format('create view erp_meta.%I as select t.code from erp_meta.%I t', v_view, v_table);
    execute format('create function erp_test.%I() returns integer language sql as $b$ select 1 $b$', v_fn);
    execute format('create function erp_test.%I() returns trigger language plpgsql as $b$ begin return new; end $b$', v_trg);
    execute format('create domain erp_meta.%I as text', v_dom);
    v_f1 := erp_meta.schema_fingerprint();

    -- ── 3. One body ────────────────────────────────────────────────────────
    v_step := 'changing one routine''s body and putting it back';
    execute format('create or replace function erp_test.%I() returns integer language sql as $b$ select 2 $b$', v_fn);
    v_f2 := erp_meta.schema_fingerprint();
    execute format('create or replace function erp_test.%I() returns integer language sql as $b$ select 1 $b$', v_fn);
    v_f3 := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_f1) k where v_f1 -> k is distinct from v_f2 -> k);
    v_cases := v_cases + 1;
    case_name := 'one routine''s body changed changes the functions part and nothing else, and the body put back gives the fingerprint back';
    passed := v_d1 = 'functions' and v_f3 = v_f1 and v_f1 <> v_f0;
    detail := format('changed: %s; put back, the same: %s', v_d1, v_f3 = v_f1);
    return next;

    -- ── 4. Settings and security mode ──────────────────────────────────────
    v_step := 'changing one routine''s settings and security mode';
    execute format('alter function erp_test.%I() set search_path = %L', v_fn, '');
    v_f4 := erp_meta.schema_fingerprint();
    execute format('alter function erp_test.%I() security definer', v_fn);
    v_f5 := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_f3) k where v_f3 -> k is distinct from v_f4 -> k);
    v_d2 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_f4) k where v_f4 -> k is distinct from v_f5 -> k);
    v_cases := v_cases + 1;
    case_name := 'a routine''s settings and whether it runs as its owner are each part of it';
    passed := v_d1 = 'functions' and v_d2 = 'functions';
    detail := format('a setting: %s; security definer: %s', v_d1, v_d2);
    return next;

    -- ── 5. Column, constraint, index ───────────────────────────────────────
    v_step := 'changing a column, a constraint and an index';
    execute format('alter table erp_meta.%I add column note text', v_table);
    v_fa := erp_meta.schema_fingerprint();
    execute format('alter table erp_meta.%I add constraint %I check (n >= 0)', v_table, v_table || '_n_check');
    v_fb := erp_meta.schema_fingerprint();
    execute format('create index %I on erp_meta.%I (n)', v_table || '_n', v_table);
    v_fc := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_f5) k where v_f5 -> k is distinct from v_fa -> k);
    v_d2 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fa) k where v_fa -> k is distinct from v_fb -> k);
    v_d3 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fb) k where v_fb -> k is distinct from v_fc -> k);
    v_cases := v_cases + 1;
    case_name := 'a column, a constraint and an index each change their own part and nothing else';
    passed := v_d1 = 'columns' and v_d2 = 'constraints' and v_d3 = 'indexes';
    detail := format('a column: %s; a constraint: %s; an index: %s', v_d1, v_d2, v_d3);
    return next;

    -- ── 6. View, policy, row security ──────────────────────────────────────
    v_step := 'changing a view, a policy and row security';
    execute format('create or replace view erp_meta.%I as select t.code from erp_meta.%I t where t.n > 0', v_view, v_table);
    v_fa := erp_meta.schema_fingerprint();
    execute format('create policy %I on erp_meta.%I for select to authenticated using (n > 0)', v_table || '_read', v_table);
    v_fb := erp_meta.schema_fingerprint();
    execute format('alter table erp_meta.%I enable row level security', v_table);
    v_fd := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fc) k where v_fc -> k is distinct from v_fa -> k);
    v_d2 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fa) k where v_fa -> k is distinct from v_fb -> k);
    v_d3 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fb) k where v_fb -> k is distinct from v_fd -> k);
    v_cases := v_cases + 1;
    case_name := 'a view''s definition, a policy and row security each change their own part and nothing else';
    passed := v_d1 = 'views' and v_d2 = 'policies' and v_d3 = 'row_security';
    detail := format('a view: %s; a policy: %s; row security: %s', v_d1, v_d2, v_d3);
    return next;

    -- ── 7. Grant, trigger, type ────────────────────────────────────────────
    v_step := 'changing a grant, a trigger and a type';
    execute format('grant select on erp_meta.%I to authenticated', v_table);
    v_fa := erp_meta.schema_fingerprint();
    execute format('create trigger %I before insert on erp_meta.%I for each row execute function erp_test.%I()',
                   v_table || '_insert', v_table, v_trg);
    v_fb := erp_meta.schema_fingerprint();
    execute format('alter domain erp_meta.%I set default %L', v_dom, 'none');
    v_fc := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fd) k where v_fd -> k is distinct from v_fa -> k);
    v_d2 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fa) k where v_fa -> k is distinct from v_fb -> k);
    v_d3 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fb) k where v_fb -> k is distinct from v_fc -> k);
    v_cases := v_cases + 1;
    case_name := 'a grant, a trigger and a type each change their own part and nothing else';
    passed := v_d1 = 'grants' and v_d2 = 'triggers' and v_d3 = 'types';
    detail := format('a grant: %s; a trigger: %s; a type: %s', v_d1, v_d2, v_d3);
    return next;

    -- ── 8. Reference rows ──────────────────────────────────────────────────
    v_step := 'changing reference and register rows';
    execute format('insert into erp_meta.%I (code, n) values (%L, 1)', v_table, 'a');
    v_fa := erp_meta.schema_fingerprint();
    update erp_ref.refusal r set why = r.why || ' (changed by a suite)' where r.code = 'CLOVEERP_TEMPLATE_UNKNOWN';
    v_fb := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fc) k where v_fc -> k is distinct from v_fa -> k);
    v_d2 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fa) k where v_fa -> k is distinct from v_fb -> k);
    v_cases := v_cases + 1;
    case_name := 'a row in a register or a reference table changes the rows part and nothing else';
    passed := v_d1 = 'rows' and v_d2 = 'rows';
    detail := format('a register row: %s; a refusal''s words: %s', v_d1, v_d2);
    return next;

    -- ── 9. Only this database's own ────────────────────────────────────────
    -- What a restore writes (the owner, the schedule, the deployment's
    -- identity and address), what a release writes, an organisation, the
    -- audit, the register, and the times rows were written.
    v_step := 'changing only what is this database''s own';
    insert into auth.users (id, email) values (ow, 'owner@' || v_ocode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@' || v_ocode || '.test', ow, 'Template Suite Owner', 'owner');
    insert into erp_meta.platform_schedule (code, cron_expression, command, reason)
    values (v_ocode, '* * * * *', 'select 1', 'a_client_is_built_from_a_template_suite');
    perform erp.record_release(v_sha, now(), null, 'a_client_is_built_from_a_template_suite');
    select * into rp from erp.provision_tenant(v_ocode, 'Template Suite Ltd', 'admin@' || v_ocode || '.test', 'Suite Admin');
    insert into erp_meta.platform_audit (action, reason) values ('a_client_is_built_from_a_template_suite', 'a suite');
    insert into erp_meta.deployment (code, client_name, status, note)
    values (v_acode, 'Template Client Ltd', 'requested', 'a_client_is_built_from_a_template_suite'),
           (v_ccode, 'Empty Client Ltd', 'building', 'a_client_is_built_from_a_template_suite');
    insert into erp_meta.deployment (code, client_name, status, project_ref, note)
    values (v_bcode, 'Restored Client Ltd', 'building', substr(md5('i' || v_tag), 1, 20), 'a_client_is_built_from_a_template_suite');
    update erp_meta.deployment d set project_ref = substr(md5('j' || v_tag), 1, 20) where d.code = v_ccode;
    perform erp_meta.record_deployment_event(v_acode, 'request', 'done', 'a_client_is_built_from_a_template_suite');
    execute format('update erp_meta.%I t set at = now() - interval ''3 days'', made = gen_random_uuid() where true', v_table);
    update erp_meta.policy_decision p set decided_at = p.decided_at - interval '1 day' where true;
    update erp_meta.invoker_reach i set granted_at = i.granted_at - interval '1 day' where i.schema_name = 'erp_meta';
    update erp_ref.refusal r set registered_at = r.registered_at - interval '1 year' where r.code like 'CLOVEERP_TEMPLATE%';
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.ref', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"client"'::jsonb, 'a_client_is_built_from_a_template_suite');
    perform erp_meta.set_deployment_identity(substr(md5('k' || v_tag), 1, 20), 'https://' || v_ocode || '.example.com');
    v_fd := erp_meta.schema_fingerprint();
    v_d1 := (select coalesce(string_agg(k, ',' order by k), '') from jsonb_object_keys(v_fb) k where v_fb -> k is distinct from v_fd -> k);
    v_cases := v_cases + 1;
    case_name := 'only this database''s own rows and the times rows were written changed: the owner, the schedule, the deployment''s identity and address, a release, an organisation, the audit and the register leave the fingerprint as it was';
    passed := v_fd = v_fb
          and (select r.value from erp_ref.resource r where r.key = 'app.base_url' and r.locale = 'en')
              = 'https://' || v_ocode || '.example.com'
          and exists (select 1 from erp.tenant t where t.id = rp.tenant_id);
    detail := format('changed: %s', coalesce(nullif(v_d1, ''), 'nothing'));
    return next;

    -- ── 10. The control plane's ────────────────────────────────────────────
    v_step := 'recording a template off the control plane';
    begin
      perform erp_meta.record_provisioning_template(v_sha, v_newest, v_count, v_dump, v_fd, 'templates/' || v_sha || '.dump', '1');
      v_got := 'recorded on a client';
    exception when others then
      v_got := sqlerrm;
    end;
    update erp_meta.platform_setting s set value = '"demonstration"'::jsonb where s.key = 'deployment.kind';
    begin
      perform erp_meta.record_provisioning_template(v_sha, v_newest, v_count, v_dump, v_fd, 'templates/' || v_sha || '.dump', '1');
      v_got2 := 'recorded on the demonstration';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.platform_setting s set value = '"production"'::jsonb where s.key = 'deployment.kind';
    v_cases := v_cases + 1;
    case_name := 'the register of templates is the control plane''s: a client and the demonstration refuse to record one';
    passed := v_got like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a client deployment%'
          and v_got2 like 'CLOVEERP_NOT_THE_CONTROL_PLANE: this is a demonstration deployment%'
          and (select count(*) from erp_meta.provisioning_template) = v_held0;
    detail := left(v_got, 80) || ' / ' || left(v_got2, 80);
    return next;

    -- ── 11. Recorded, found, replayed, renewed ─────────────────────────────
    v_step := 'recording a template';
    v_t1 := erp_meta.record_provisioning_template(upper(v_sha), v_newest, v_count, upper(v_dump), v_fd,
                                                  'templates/' || v_sha || '.dump', '101');
    v_t2 := erp_meta.record_provisioning_template(v_sha, v_newest, v_count, v_dump, v_fd,
                                                  'templates/' || v_sha || '.dump', '101');
    v_row := erp_meta.provisioning_template_for(v_newest, v_count);
    v_t3 := erp_meta.record_provisioning_template(v_sha2, v_newest, v_count, v_dump, v_fd,
                                                  'actions-artifact:102/template', '102');
    v_n := (select count(*) from erp_meta.provisioning_template t where t.dump_sha256 = v_dump);
    v_t4 := erp_meta.record_provisioning_template(v_sha2, v_newest, v_count, v_dump2, v_fd,
                                                  'templates/' || v_sha2 || '.dump', '103');
    v_row2 := erp_meta.provisioning_template_for(v_newest, v_count);
    v_cases := v_cases + 1;
    case_name := 'a template is recorded once by its dump and found by its migrations; the same again is a replay, from a later run renews where it is kept, and the newest is found';
    passed := v_t1 ->> 'outcome' = 'recorded' and v_t1 ->> 'git_sha' = v_sha and v_t1 ->> 'dump_sha256' = v_dump
          and v_t1 ->> 'newest_migration' = v_newest and (v_t1 ->> 'migration_count')::integer = v_count
          and v_t1 -> 'fingerprint' = v_fd and v_t1 ->> 'proving_run_id' = '101'
          and v_t2 ->> 'outcome' = 'replay' and v_t2 ->> 'id' = v_t1 ->> 'id'
          and v_row ->> 'id' = v_t1 ->> 'id' and not (v_row ? 'outcome')
          and v_t3 ->> 'outcome' = 'renewed' and v_t3 ->> 'id' = v_t1 ->> 'id'
          and v_t3 ->> 'storage_key' = 'actions-artifact:102/template' and v_t3 ->> 'git_sha' = v_sha2
          and v_t3 ->> 'proving_run_id' = '102'
          and (v_t3 ->> 'recorded_at')::timestamptz > (v_t1 ->> 'recorded_at')::timestamptz
          and v_n = 1
          and v_t4 ->> 'outcome' = 'recorded' and v_row2 ->> 'dump_sha256' = v_dump2
          and erp_meta.provisioning_template_for(v_newest, v_count - 1) is null
          and erp_meta.provisioning_template_for('20261012060000', v_count) is null
          and (select count(*) from erp_meta.provisioning_template) = v_held0 + 2;
    detail := format('%s, %s, %s, %s; found %s then %s', v_t1 ->> 'outcome', v_t2 ->> 'outcome', v_t3 ->> 'outcome',
                     v_t4 ->> 'outcome', left(v_row ->> 'dump_sha256', 8), left(v_row2 ->> 'dump_sha256', 8));
    return next;

    -- ── 12. Not in its form ────────────────────────────────────────────────
    v_step := 'recording templates not in the register''s form';
    for f in
      select x.git_sha, x.newest, x.n, x.dump, x.fingerprint, x.storage_key, x.run, x.fault
        from (values
          ('abc123', v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd, 'k', '1',
           'the commit is not a forty-character git sha'),
          (v_sha, '2026101207', v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd, 'k', '1',
           'the newest migration is not a fourteen-digit version'),
          (v_sha, v_newest, 0, md5('l' || v_tag) || md5('m' || v_tag), v_fd, 'k', '1',
           'the number of migrations is not one or more'),
          (v_sha, v_newest, v_count, md5('l' || v_tag), v_fd, 'k', '1',
           'the dump''s sha256 is not sixty-four hexadecimal characters'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), '[]'::jsonb, 'k', '1',
           'the fingerprint is not a set of named hashes'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd - 'version', 'k', '1',
           'the fingerprint does not say its version'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), '{"version": 1}'::jsonb, 'k', '1',
           'the fingerprint has no part'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag),
           v_fd || '{"rows": "not a hash"}'::jsonb, 'k', '1',
           'the fingerprint''s part rows is not a sha256'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd, 'templates/a dump', '1',
           'where it is kept is blank, longer than five hundred characters, or holds a space'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd, '', '1',
           'where it is kept is blank, longer than five hundred characters, or holds a space'),
          (v_sha, v_newest, v_count, md5('l' || v_tag) || md5('m' || v_tag), v_fd, 'k', 'run-1',
           'the run that proved it is not a workflow run id'),
          (v_sha, v_newest, v_count + 1, v_dump, v_fd, 'k', '1',
           'a dump with this sha256 is recorded already as the template of ' || v_count || ' migrations to ' || v_newest
           || ', with its own fingerprint')
        ) as x(git_sha, newest, n, dump, fingerprint, storage_key, run, fault)
    loop
      begin
        perform erp_meta.record_provisioning_template(f.git_sha, f.newest, f.n, f.dump, f.fingerprint, f.storage_key, f.run);
        v_faults := v_faults || ('recorded, and should have said: ' || f.fault);
      exception when others then
        if sqlerrm <> 'CLOVEERP_TEMPLATE_INVALID: the template is not recorded: ' || f.fault then
          v_faults := v_faults || left(sqlerrm, 160);
        end if;
      end;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'a template whose commit, migrations, dump, fingerprint, keeping or proving run is not in its form, or a dump recorded already as another template, is refused and nothing is recorded';
    passed := cardinality(v_faults) = 0
          and (select count(*) from erp_meta.provisioning_template) = v_held0 + 2;
    detail := coalesce(nullif(array_to_string(v_faults, ' / '), ''), 'twelve refused, each saying why');
    return next;

    -- ── 13. How a client is built ──────────────────────────────────────────
    v_step := 'recording how client deployments are built';
    v_said := erp_meta.record_deployment_build_method(upper(v_acode), 'Template', upper(v_dump2));
    v_got := (select d.build_method from erp_meta.deployment d where d.code = v_acode);
    v_got2 := (select e.detail from erp_meta.deployment_event e where e.code = v_acode order by e.at desc, e.id desc limit 1);
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_acode);
    v_row2 := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_ccode);
    perform set_config('request.jwt.claims', '', true);
    -- A retry builds the other way.
    v_said2 := erp_meta.record_deployment_build_method(v_acode, 'from_empty');
    v_got3 := (select d.build_method from erp_meta.deployment d where d.code = v_acode);
    v_got4 := (select e.detail from erp_meta.deployment_event e where e.code = v_acode order by e.at desc, e.id desc limit 1);
    v_cases := v_cases + 1;
    case_name := 'a client deployment being built records that it is built from a registered template, naming it, or from empty on a retry, and the Fleet view shows how, or nothing until the build says';
    passed := v_said = v_acode || ': building from the template of ' || v_count || ' migrations to ' || v_newest
                       || ', made at ' || left(v_sha2, 12) || ' and proved by run 103'
          and v_got = 'template'
          and v_got2 = 'building from the template of ' || v_count || ' migrations to ' || v_newest || ', made at '
                       || left(v_sha2, 12) || ' and proved by run 103'
          and v_row ->> 'build_method' = 'template'
          and (select count(*) from jsonb_object_keys(v_row)) = 42
          and v_row2 ? 'build_method' and jsonb_typeof(v_row2 -> 'build_method') = 'null'
          and v_said2 = v_acode || ': building from empty, replaying every migration'
          and v_got3 = 'from_empty'
          and v_got4 = 'building from empty, replaying every migration';
    detail := left(v_said, 120) || ' / ' || coalesce(v_row ->> 'build_method', 'no key') || ' / '
              || (select count(*) from jsonb_object_keys(coalesce(v_row, '{}'::jsonb))) || ' keys / ' || v_said2;
    return next;

    -- ── 14. Refused ────────────────────────────────────────────────────────
    v_step := 'recording build methods that are not one';
    begin
      perform erp_meta.record_deployment_build_method(v_acode, 'copy');
      v_got := 'copy was recorded';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.record_deployment_build_method(v_acode, 'template', md5('n' || v_tag) || md5('o' || v_tag));
      v_got2 := 'an unregistered template was recorded';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform erp_meta.record_deployment_build_method(v_acode, 'template');
      v_got3 := 'a template with no dump was recorded';
    exception when others then
      v_got3 := sqlerrm;
    end;
    begin
      perform erp_meta.record_deployment_build_method(v_acode, 'from_empty', v_dump);
      v_got4 := 'from empty with a template was recorded';
    exception when others then
      v_got4 := sqlerrm;
    end;
    begin
      perform erp_meta.record_deployment_build_method('zzfpx-' || v_tag, 'from_empty');
      v_got5 := 'an unknown deployment was recorded';
    exception when others then
      v_got5 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a build method that is not one, a template not registered or not named, a template named for a build from empty, and a deployment not in the register are refused, and nothing changes';
    passed := v_got = 'CLOVEERP_BUILD_METHOD_INVALID: "copy" is not how a client deployment is built'
          and v_got2 = 'CLOVEERP_TEMPLATE_UNKNOWN: no template whose dump has the sha256 ' || md5('n' || v_tag) || md5('o' || v_tag) || ' is registered'
          and v_got3 = 'CLOVEERP_TEMPLATE_UNKNOWN: no template whose dump has the sha256 (none given) is registered'
          and v_got4 = 'CLOVEERP_BUILD_METHOD_INVALID: a build from empty replays every migration and restores no template, and ' || v_dump || ' was named'
          and v_got5 like 'CLOVEERP_DEPLOYMENT_UNKNOWN:%'
          and (select d.build_method from erp_meta.deployment d where d.code = v_acode) = 'from_empty';
    detail := left(v_got, 60) || ' / ' || left(v_got2, 60) || ' / ' || left(v_got4, 60) || ' / ' || left(v_got5, 50);
    return next;

    -- ── 15. Built ──────────────────────────────────────────────────────────
    v_step := 'finishing the builds';
    perform erp_meta.record_deployment_build_method(v_bcode, 'template', v_dump);
    perform erp_meta.deployment_built(v_bcode);
    perform erp_meta.deployment_built(v_ccode);
    v_got := (select e.detail from erp_meta.deployment_event e
               where e.code = v_bcode and e.phase = 'build' and e.status = 'done' order by e.at desc, e.id desc limit 1);
    v_got2 := (select e.detail from erp_meta.deployment_event e
                where e.code = v_ccode and e.phase = 'build' and e.status = 'done' order by e.at desc, e.id desc limit 1);
    begin
      perform erp_meta.record_deployment_build_method(v_bcode, 'from_empty');
      v_got3 := 'a built deployment was said to be building';
    exception when others then
      v_got3 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a build finished says how it was built, and a deployment built is not said to be building again';
    passed := v_got = 'built from a template and proved'
          and v_got2 = 'built from empty and proved'
          and (select d.status || '/' || d.build_method from erp_meta.deployment d where d.code = v_bcode) = 'built/template'
          and (select d.status from erp_meta.deployment d where d.code = v_ccode) = 'built'
          and (select d.build_method from erp_meta.deployment d where d.code = v_ccode) is null
          and v_got3 = 'CLOVEERP_DEPLOYMENT_STATE: ' || v_bcode || ' is built, and only a deployment being built says how it is built';
    detail := v_got || ' / ' || v_got2 || ' / ' || left(v_got3, 100);
    return next;

    -- ── 16. Standing ───────────────────────────────────────────────────────
    v_step := 'reading the routines'' standing';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.schema_fingerprint()'::regprocedure,
                     'erp_meta.schema_fingerprint_detail()'::regprocedure,
                     'erp_meta.record_provisioning_template(text,text,integer,text,jsonb,text,text)'::regprocedure,
                     'erp_meta.provisioning_template_for(text,integer)'::regprocedure,
                     'erp_meta.record_deployment_build_method(text,text,text)'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    select count(*) into v_n2
      from pg_catalog.pg_class c
     where c.oid = 'erp_meta.provisioning_template'::regclass
       and c.relrowsecurity and c.relforcerowsecurity
       and not pg_catalog.has_table_privilege('anon', c.oid, 'select')
       and not pg_catalog.has_table_privilege('authenticated', c.oid, 'select')
       and not pg_catalog.has_table_privilege('service_role', c.oid, 'select')
       and exists (select 1 from erp_meta.table_policy t
                    where t.schema_name = 'erp_meta' and t.table_name = c.relname
                      and t.table_class = 'platform_internal');
    v_cases := v_cases + 1;
    case_name := 'the five routines run as their caller and reach no session role, the Fleet view still runs as its owner, and the register of templates is sealed';
    passed := v_n = 5 and v_n2 = 1
          and (select p.prosecdef and pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                 from pg_catalog.pg_proc p where p.oid = 'public.erp_platform_deployments()'::regprocedure);
    detail := format('%s of 5 routines, %s of 1 table', v_n, v_n2);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 17. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind: no object, template, deployment or organisation of its own, and the deployment''s marker, identity and address as they were';
  passed := to_regclass('erp_meta.' || v_table) is null
        and to_regclass('erp_meta.' || v_view) is null
        and to_regprocedure('erp_test.' || v_fn || '()') is null
        and to_regtype('erp_meta.' || v_dom) is null
        and (select count(*) from erp_meta.provisioning_template) = v_held0
        and not exists (select 1 from erp_meta.deployment d where d.code in (v_acode, v_bcode, v_ccode))
        and not exists (select 1 from erp.tenant t where t.code = v_ocode)
        and not exists (select 1 from erp_meta.platform_schedule s where s.code = v_ocode)
        and erp.deployment_kind() = v_kind
        and (select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb)
               from erp_meta.platform_setting s where s.key like 'deployment.%') = v_settings
        and (select coalesce(jsonb_object_agg(r.locale, r.value), '{}'::jsonb)
               from erp_ref.resource r where r.key = 'app.base_url') = v_base_url;
  detail := format('deployment kind %s, as before; %s template(s), as before', erp.deployment_kind(), v_held0);
  return next;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_A_CLIENT_IS_BUILT_FROM_A_TEMPLATE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_a_client_is_built_from_a_template_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.a_client_is_built_from_a_template_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_A_CLIENT_IS_BUILT_FROM_A_TEMPLATE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The fingerprint does not tell a template from the build it was made from, or tells them apart over '
                   'what is a database''s own, or the register of templates or how a client was built does not hold: '
                   'read the case that failed.';
  end if;
  if v_total <> 17 then
    raise exception 'CLOVEERP_A_CLIENT_IS_BUILT_FROM_A_TEMPLATE_SUITE_SHRANK: % case(s), expected 17', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a client is built from a template: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.a_client_is_built_from_a_template_suite() from public, anon;
revoke all on function erp_test.assert_a_client_is_built_from_a_template_suite() from public, anon;

comment on function erp_test.assert_a_client_is_built_from_a_template_suite() is
  'The schema fingerprint is a sha256 for each part and its version, the same each time; it reads the product''s '
  'reference and generated rows and leaves out organisations, the register, operations, the deployment''s address '
  'and every time; one routine''s body, its settings, its security mode, a column, a constraint, an index, a view, '
  'a policy, row security, a grant, a trigger, a type and a row each change their own part and nothing else, and a '
  'body put back gives the fingerprint back; only a database''s own rows and times leave it as it was. The register '
  'of templates is the control plane''s, keeps a dump once, replays and renews it, finds the newest by migrations and '
  'refuses particulars not in their form; a client being built records how, from a registered template or from '
  'empty, the Fleet view shows it, a finished build says it, and nothing is left behind (20261012070000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
