set lock_timeout = '30s';

-- =============================================================================
-- 20261010010000  A migration locks only what it changes
-- -----------------------------------------------------------------------------
-- Found in the live re-test of 5 October (B6). Twice a person's write in the
-- demonstration was cancelled while nothing in it was wrong:
--
--   * "New requisition → Create" (15:22 London, 14:22 UTC): "canceling
--     statement due to lock timeout";
--   * "Create a delivery from this order" (15:43 London, 14:43 UTC):
--     "canceling statement due to statement timeout", after about 12 s.
--
-- Both retried and went through in a few seconds. Both fell inside a deploy:
-- #438's ran 14:19:26 to 14:24:05 UTC, #439's 14:42:02 to 14:44:17 UTC
-- (gh run view 37323767447 / 37326811038). What a deploy does to everybody
-- else is in the last lines of every migration. The generators run there, and
-- two of them rebuild what they find already right:
--
--   * erp.apply_row_security() enables and forces row security, drops and
--     re-creates the isolation policy on every table it governs (340 here,
--     erp.document, erp.document_line, erp.numbering_rule, erp.item and
--     erp.tenant among them) and re-sets security_invoker on every view.
--     Each of those statements takes an ACCESS EXCLUSIVE lock, held until the
--     migration commits, so from the first table it reaches until the end of
--     the assertions after it nobody can read or write any of them; and while
--     it waits for a table a person's transaction is using, every later
--     request for that table queues behind it.
--   * erp.apply_live_config_guards() drops and re-creates the live guard
--     trigger on each of 43 configuration tables, erp.numbering_rule among
--     them, every document's numbering.
--
-- Measured on a copy of main: one run of the generator block holds ACCESS
-- EXCLUSIVE on 340 tables when it changes nothing at all.
--
-- And the cost a write pays without any deploy. erp.local_timezone() is asked
-- every time a document is dated (erp.local_today()): opening one, posting
-- one. It checked the name it found against pg_catalog.pg_timezone_names,
-- which reads every file of the server's time zone database from disk on
-- every call. Creating a delivery from an order and posting it asked twice,
-- and those two calls were 90 of its 255 ms on the copy, the largest single
-- cost in the write.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.row_security_drift(): read only, what erp.apply_row_security()
--      would have to change: a governed table whose row security is off or
--      not forced, an isolation policy missing, different from the one its
--      class calls for (command, permissive, role, condition) or not called
--      for at all, a view that is not security_invoker.
--   B. erp.apply_row_security() changes only what erp.row_security_drift()
--      names. A policy somebody edited is still put back by the next
--      migration, so the generator is still the one source of truth; one that
--      is already right is left, and so is its table's lock. The grants and
--      revokes stay as they were: they take no lock on the table.
--   C. erp.apply_live_config_guards() re-creates a table's guard only where
--      it is missing or is not the guard (function, timing, events, enabled),
--      and takes it off a table that left the register, as before.
--   D. erp.local_timezone() asks the server whether it can use the name,
--      which is what the check was for ("a name the server does not know
--      would raise from inside a document being written"), instead of reading
--      the whole zone directory. A name it cannot use still answers UTC, and
--      erp.assert_timezones_are_known() still reports names it does not list.
--   E. erp_test.migration_locks_suite, seven cases.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What row security, policies, grants and guards each table ends with is
-- unchanged: the same statements run where anything differs. No write door's
-- timeout is raised. A migration that does alter a hot table still locks it,
-- and still belongs in a quiet moment.
--
-- On production: three routines are replaced and one is added. No table is
-- altered and no row of any organisation is changed. This migration's own
-- generator block is the last to run the old way on hot tables; from the next
-- migration on, a deploy that changes no policy takes no table's lock.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What row security would change
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  r record;
begin
  for r in
    select * from (values
      ('erp.apply_row_security()', '16936c2c2836ce69f57cbc4e149426b7'),
      ('erp.apply_live_config_guards()', 'd5be704fda27130d76c1a379f3fd90cb'),
      ('erp.local_timezone(uuid)', '70e1b62a6c115d4b5b7b066dae0e4698')) x(sig, md5)
  loop
    if strpos((select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure), '20261010010000') > 0 then
      continue;
    end if;
    if md5((select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure)) <> r.md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010010000 expects (md5 %)', r.sig,
        md5((select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure));
    end if;
  end loop;
end
$guard$;

create or replace function erp.row_security_drift()
returns table(step integer, schema_name text, table_name text, table_class text, change text)
language sql
stable
set search_path = ''
as $$
  -- What erp.apply_row_security() would have to change, and nothing it would
  -- not (20261010010000). Each change is one statement that takes the table's
  -- ACCESS EXCLUSIVE lock, so an empty answer is a generator run that locks
  -- no table. Steps run in order: switch row security on, force it, drop a
  -- policy that is wrong or not called for, create one that is missing.
  with t as (
    select tp.schema_name, tp.table_name, tp.table_class::text as table_class, c.oid,
           c.relrowsecurity, c.relforcerowsecurity
      from erp_meta.table_policy tp
      join pg_catalog.pg_class c
        on c.relname = tp.table_name
       and c.relnamespace::regnamespace::text = tp.schema_name
       and c.relkind = 'r'
  ),
  -- The policy each class calls for, as pg_get_expr prints the condition the
  -- generator writes. Anything else under these three names is drift.
  want(table_class, polname, cmd, qual, chk) as (values
    ('tenant_scoped', 'tenant_isolation', '*',
     '(tenant_id = erp.current_tenant_id())', '(tenant_id = erp.current_tenant_id())'),
    ('tenant_scoped_append_only', 'tenant_isolation', 'r', '(tenant_id = erp.current_tenant_id())', null),
    ('tenant_scoped_append_only', 'tenant_insert', 'a', null, '(tenant_id = erp.current_tenant_id())'),
    ('tenant_root', 'tenant_isolation', 'r', '(id = erp.current_tenant_id())', null),
    ('product_content', 'product_read', 'r', 'true', null)
  ),
  have as (
    select p.polrelid, p.polname::text as polname, p.polcmd::text as cmd, p.polpermissive,
           p.polroles, pg_catalog.pg_get_expr(p.polqual, p.polrelid) as qual,
           pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) as chk
      from pg_catalog.pg_policy p
     where p.polname in ('tenant_isolation', 'tenant_insert', 'product_read')
  ),
  pol as (
    select t.schema_name, t.table_name, t.table_class, n.polname,
           w.polname is not null as wanted, h.polname is not null as present,
           (w.polname is not null and h.polname is not null
            and h.cmd = w.cmd and h.polpermissive
            and h.polroles = array['authenticated'::regrole]::oid[]
            and h.qual is not distinct from w.qual
            and h.chk is not distinct from w.chk) as same
      from t
     cross join (values ('tenant_isolation'), ('tenant_insert'), ('product_read')) n(polname)
      left join want w on w.table_class = t.table_class and w.polname = n.polname
      left join have h on h.polrelid = t.oid and h.polname = n.polname
  )
  select 1, t.schema_name, t.table_name, t.table_class, 'enable row level security'
    from t where not t.relrowsecurity
  union all
  select 2, t.schema_name, t.table_name, t.table_class, 'force row level security'
    from t where not t.relforcerowsecurity
  union all
  select 3, p.schema_name, p.table_name, p.table_class, 'drop policy ' || p.polname
    from pol p where p.present and not p.same
  union all
  select 4, p.schema_name, p.table_name, p.table_class, 'create policy ' || p.polname
    from pol p where p.wanted and not p.same
  union all
  -- A view reads its tables as whoever queries it (security_invoker); a
  -- materialised view cannot, and is revoked instead, which takes no lock.
  select 5, c.relnamespace::regnamespace::text, c.relname::text, 'view', 'security invoker'
    from pg_catalog.pg_class c
   where c.relkind = 'v'
     and c.relnamespace::regnamespace::text in ('erp', 'erp_ref')
     and not coalesce(c.reloptions @> array['security_invoker=true'], false)
  order by 1, 2, 3, 5
$$;

revoke all on function erp.row_security_drift() from public, anon;

comment on function erp.row_security_drift() is
  'What erp.apply_row_security() would change: a governed table with row security off or not forced, an isolation '
  'policy missing, different or not called for, a view that is not security_invoker (20261010010000). Each row is a '
  'statement that locks its table; an empty answer is a generator run that locks none.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Row security changes only what has drifted
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.apply_row_security()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_schemas text[];
  v_tables  text[];
  v_classes text[];
  r         erp_meta.rls_target;
  d         record;
  v_applied integer := 0;
  v_qual    text;
  i         integer;
begin
  perform erp_meta.register_unregistered_tables();

  -- Materialise the target list BEFORE touching anything. A FOR ... IN SELECT
  -- loop would hold an open cursor over erp_meta.table_policy, and this loop
  -- issues ALTER TABLE against that very table.
  select coalesce(array_agg(tp.schema_name order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_name  order by tp.schema_name, tp.table_name), '{}'),
         coalesce(array_agg(tp.table_class::text order by tp.schema_name, tp.table_name), '{}')
    into v_schemas, v_tables, v_classes
    from erp_meta.table_policy tp
    join pg_catalog.pg_class c
      on c.relname = tp.table_name
     and c.relnamespace::regnamespace::text = tp.schema_name
     and c.relkind = 'r';

  -- What has drifted, and only that (20261010010000). Every statement here
  -- takes its table's ACCESS EXCLUSIVE lock until the migration commits, so a
  -- policy already right is left alone. One somebody edited is still dropped
  -- and written again: an edited policy does not survive the next migration.
  for d in select * from erp.row_security_drift() x where x.step < 5 loop
    case
      when d.change = 'enable row level security' then
        execute format('alter table %I.%I enable row level security', d.schema_name, d.table_name);
      when d.change = 'force row level security' then
        -- FORCEd so that even the table owner is subject to it. Only a role
        -- holding BYPASSRLS sees past it.
        execute format('alter table %I.%I force row level security', d.schema_name, d.table_name);
      when d.change like 'drop policy %' then
        execute format('drop policy if exists %I on %I.%I',
                       substr(d.change, 13), d.schema_name, d.table_name);
      when d.change = 'create policy tenant_isolation' and d.table_class = 'tenant_scoped' then
        v_qual := 'tenant_id = erp.current_tenant_id()';
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for all to authenticated
             using (%s) with check (%s)',
          d.schema_name, d.table_name, v_qual, v_qual);
      when d.change = 'create policy tenant_isolation' and d.table_class = 'tenant_scoped_append_only' then
        -- SELECT and INSERT only. There is deliberately no policy for UPDATE
        -- or DELETE: with RLS enabled and no permissive policy for a command,
        -- that command matches zero rows for every caller.
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for select to authenticated using (tenant_id = erp.current_tenant_id())',
          d.schema_name, d.table_name);
      when d.change = 'create policy tenant_insert' then
        execute format(
          'create policy tenant_insert on %I.%I
             as permissive for insert to authenticated with check (tenant_id = erp.current_tenant_id())',
          d.schema_name, d.table_name);
      when d.change = 'create policy tenant_isolation' and d.table_class = 'tenant_root' then
        execute format(
          'create policy tenant_isolation on %I.%I
             as permissive for select to authenticated
             using (id = erp.current_tenant_id())',
          d.schema_name, d.table_name);
      when d.change = 'create policy product_read' then
        execute format(
          'create policy product_read on %I.%I
             as permissive for select to authenticated using (true)',
          d.schema_name, d.table_name);
      else
        raise exception 'CLOVEERP_ROW_SECURITY_UNKNOWN_CHANGE: % on %.% (%)',
          d.change, d.schema_name, d.table_name, d.table_class
          using errcode = '22023',
                hint = 'erp.row_security_drift() named a change erp.apply_row_security() does not make. Teach the generator the change, or the drift what the class calls for.';
    end case;
  end loop;

  -- The grants, every time: a grant or a revoke takes no lock on its table.
  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    r := row(v_schemas[i], v_tables[i], v_classes[i])::erp_meta.rls_target;

    execute format('revoke all on %I.%I from public, anon', r.schema_name, r.table_name);

    case r.table_class
      when 'tenant_scoped' then
        execute format(
          'grant select, insert, update, delete on %I.%I to authenticated',
          r.schema_name, r.table_name);

      when 'tenant_scoped_append_only' then
        execute format(
          'grant select, insert on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'tenant_root' then
        execute format('grant select on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke insert, update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'product_content' then
        execute format('grant select on %I.%I to authenticated', r.schema_name, r.table_name);
        execute format(
          'revoke insert, update, delete, truncate on %I.%I from authenticated',
          r.schema_name, r.table_name);

      when 'platform_internal' then
        execute format(
          'revoke all on %I.%I from authenticated', r.schema_name, r.table_name);
    end case;

    v_applied := v_applied + 1;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Views. security_invoker makes the base tables' policies apply to whoever is
  -- querying, instead of to the view's owner — who bypasses them. Set only on
  -- a view that lacks it (20261010010000): setting it locks the view.
  -- ---------------------------------------------------------------------------
  select coalesce(array_agg(c.relnamespace::regnamespace::text
                            order by c.relnamespace::regnamespace::text, c.relname), '{}'),
         coalesce(array_agg(c.relname
                            order by c.relnamespace::regnamespace::text, c.relname), '{}')
    into v_schemas, v_tables
    from pg_catalog.pg_class c
   where c.relkind in ('v', 'm')
     and c.relnamespace::regnamespace::text in ('erp', 'erp_ref');

  for i in 1 .. coalesce(array_length(v_schemas, 1), 0) loop
    -- Materialised views cannot take security_invoker; they are pre-computed
    -- from the owner's vantage point and so must never be granted to a tenant
    -- role. Reporting snapshots belong behind a tenant-scoped table instead.
    if (select c.relkind
          from pg_catalog.pg_class c
         where c.relname = v_tables[i]
           and c.relnamespace::regnamespace::text = v_schemas[i]) = 'm' then
      execute format('revoke all on %I.%I from public, anon, authenticated',
                     v_schemas[i], v_tables[i]);
    else
      if not coalesce((select c.reloptions @> array['security_invoker=true']
                         from pg_catalog.pg_class c
                        where c.relname = v_tables[i]
                          and c.relnamespace::regnamespace::text = v_schemas[i]), false) then
        execute format('alter view %I.%I set (security_invoker = true)',
                       v_schemas[i], v_tables[i]);
      end if;
      execute format('revoke all on %I.%I from public, anon', v_schemas[i], v_tables[i]);
      execute format('grant select on %I.%I to authenticated', v_schemas[i], v_tables[i]);
    end if;
    v_applied := v_applied + 1;
  end loop;

  return v_applied;
end;
$$;

revoke all on function erp.apply_row_security() from public, anon;

comment on function erp.apply_row_security() is
  'Row security, isolation policies and grants on every governed table, security_invoker on every view. Changes '
  'only what erp.row_security_drift() names, so a run that finds everything right locks no table (20261010010000); '
  'an edited policy is still put back. Idempotent; run at the end of every migration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A live guard is re-created only where it is not the guard
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.apply_live_config_guards()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r       record;
  v_count integer := 0;
begin
  -- The array this replaced listed seventeen tables and was the only statement
  -- of which tables are configuration. Nine more existed and were not in it,
  -- and nothing could have noticed. Now the register says it once, the guard
  -- is generated, and erp.assert_configuration_promotable() reads the same row.
  --
  -- A guard already in place is left (20261010010000): dropping and creating a
  -- trigger locks its table, and erp.numbering_rule, which numbers every
  -- document, is one of them. One missing, or not the guard (its function,
  -- before each row on insert, update and delete, enabled), is put back.
  for r in
    select ps.schema_name, ps.table_name,
           exists (select 1 from pg_catalog.pg_trigger t
                    where t.tgrelid = c.oid
                      and t.tgname = 't_' || ps.table_name || '_live_guard'
                      and t.tgfoid = 'erp.guard_live_configuration()'::regprocedure
                      and t.tgtype = 31
                      and t.tgenabled = 'O'
                      and t.tgnargs = 0
                      and t.tgqual is null
                      and cardinality(t.tgattr::int2[]) = 0) as in_place
      from erp_meta.promotable_surface ps
      join pg_catalog.pg_class c on c.relname = ps.table_name
      join pg_catalog.pg_namespace n
        on n.oid = c.relnamespace and n.nspname = ps.schema_name
     where c.relkind = 'r'
     order by ps.schema_name, ps.table_name
  loop
    if not r.in_place then
      execute format('drop trigger if exists t_%s_live_guard on %I.%I',
                     r.table_name, r.schema_name, r.table_name);
      execute format(
        'create trigger t_%s_live_guard before insert or update or delete on %I.%I
           for each row execute function erp.guard_live_configuration()',
        r.table_name, r.schema_name, r.table_name);
    end if;
    v_count := v_count + 1;
  end loop;

  -- And take the guard off anything that has left the register. The first
  -- version of this function only ever added, which meant deleting a row
  -- changed nothing that was deployed — a generator that does not converge is
  -- a list with extra steps. erp.apply_audit_coverage() removes the trigger
  -- from a table that has since become exempt for the same reason.
  for r in
    select n.nspname as schema_name, c.relname as table_name
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where not t.tgisinternal
       and t.tgname = 't_' || c.relname || '_live_guard'
       and not exists (
         select 1 from erp_meta.promotable_surface ps
          where ps.schema_name = n.nspname and ps.table_name = c.relname)
  loop
    execute format('drop trigger t_%s_live_guard on %I.%I',
                   r.table_name, r.schema_name, r.table_name);
  end loop;

  return v_count;
end;
$$;

revoke all on function erp.apply_live_config_guards() from public, anon;

comment on function erp.apply_live_config_guards() is
  'Attaches erp.guard_live_configuration() to every table in erp_meta.promotable_surface where it is missing or is '
  'not the guard, and takes it off a table that left the register; a guard in place is left, and so is its table''s '
  'lock (20261010010000). Idempotent; called by every migration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A time zone is checked without reading the zone directory
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.local_timezone(p_site_id uuid default null)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_tz     text;
begin
  if v_tenant is null then
    return 'UTC';
  end if;

  if p_site_id is not null then
    select nullif(btrim(s.timezone), '') into v_tz
      from erp.site s
     where s.tenant_id = v_tenant and s.id = p_site_id;
  end if;

  if v_tz is null then
    select nullif(btrim(t.default_timezone), '') into v_tz
      from erp.tenant t where t.id = v_tenant;
  end if;

  if v_tz is null then
    return 'UTC';
  end if;

  -- A name the server does not know would raise from inside a document being
  -- written, which is a bad place to discover a typo in a setting. The setting
  -- is answered here and reported by erp.assert_timezones_are_known().
  --
  -- The server is asked whether it can use the name (20261010010000). This
  -- read pg_catalog.pg_timezone_names, which opens every file of the zone
  -- database on each call, and every document dated was paying for it.
  begin
    perform pg_catalog.now() at time zone v_tz;
  exception when invalid_parameter_value then
    return 'UTC';
  end;

  return v_tz;
end;
$$;

revoke all on function erp.local_timezone(uuid) from public, anon;

comment on function erp.local_timezone(uuid) is
  'The time zone a site, or else its organisation, keeps its days in; UTC where none is set or the server cannot use '
  'the name. Asks the server rather than reading pg_timezone_names, which opens the whole zone directory on every '
  'call (20261010010000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.migration_locks_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'running the generators';
  v_state  text;
  v_before oid[];
  v_after  oid[];
  v_new    text;
  v_drift  text;
  v_qual   text;
  v_forced boolean;
  v_trg    oid;
  v_trg2   oid;
  v_site   uuid;
  v_tz1    text;
  v_tz2    text;
  v_tz3    text;
  v_body   text;
begin
  begin
    perform erp.apply_row_security();
    perform erp.apply_live_config_guards();

    -- ── 1. Once run, nothing has drifted ────────────────────────────────────
    select string_agg(x.schema_name || '.' || x.table_name || ': ' || x.change, '; ')
      into v_drift from erp.row_security_drift() x;
    v_cases := v_cases + 1;
    case_name := 'once the generator has run, no governed table or view differs from what it calls for';
    passed := v_state is null and v_drift is null;
    detail := coalesce(v_state, v_drift, 'none');
    return next;

    -- ── 2. Run again, it locks no table ─────────────────────────────────────
    v_step := 'running the generators again';
    select coalesce(array_agg(l.relation order by l.relation), '{}') into v_before
      from pg_catalog.pg_locks l
     where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'relation'
       and l.mode = 'AccessExclusiveLock';
    perform erp.apply_row_security();
    perform erp.apply_live_config_guards();
    select coalesce(array_agg(l.relation order by l.relation), '{}') into v_after
      from pg_catalog.pg_locks l
     where l.pid = pg_catalog.pg_backend_pid() and l.locktype = 'relation'
       and l.mode = 'AccessExclusiveLock';
    select string_agg(x::regclass::text, ', ' order by x::regclass::text) into v_new
      from unnest(v_after) x
     where not x = any(v_before)
       and (select c.relnamespace::regnamespace::text from pg_catalog.pg_class c where c.oid = x)
           in ('erp', 'erp_meta', 'erp_ref');
    v_cases := v_cases + 1;
    case_name := 'run again with nothing to change, row security and the live guards lock no table';
    passed := v_state is null and v_new is null;
    detail := coalesce(v_state, 'newly locked: ' || v_new, 'none newly locked');
    return next;

    -- ── 3. An edited policy is still put back ───────────────────────────────
    v_step := 'editing a policy';
    execute 'alter policy tenant_isolation on erp.quiet_hours using (true)';
    select string_agg(x.change, '; ' order by x.step) into v_drift
      from erp.row_security_drift() x where x.schema_name = 'erp' and x.table_name = 'quiet_hours';
    perform erp.apply_row_security();
    select pg_catalog.pg_get_expr(p.polqual, p.polrelid) into v_qual
      from pg_catalog.pg_policy p
     where p.polrelid = 'erp.quiet_hours'::regclass and p.polname = 'tenant_isolation';
    v_cases := v_cases + 1;
    case_name := 'a policy somebody edited is named as drift and written again by the next run';
    passed := v_state is null
          and v_drift = 'drop policy tenant_isolation; create policy tenant_isolation'
          and v_qual = '(tenant_id = erp.current_tenant_id())'
          and not exists (select 1 from erp.row_security_drift());
    detail := coalesce(v_state, format('drift %s | now %s', v_drift, v_qual));
    return next;

    -- ── 4. Row security switched off is switched back on ────────────────────
    v_step := 'switching row security off';
    execute 'alter table erp.quiet_hours no force row level security';
    execute 'drop policy tenant_isolation on erp.quiet_hours';
    select string_agg(x.change, '; ' order by x.step) into v_drift
      from erp.row_security_drift() x where x.schema_name = 'erp' and x.table_name = 'quiet_hours';
    perform erp.apply_row_security();
    select c.relforcerowsecurity into v_forced from pg_catalog.pg_class c where c.oid = 'erp.quiet_hours'::regclass;
    v_cases := v_cases + 1;
    case_name := 'a table whose row security is no longer forced, or whose policy was dropped, is set right';
    passed := v_state is null
          and v_drift = 'force row level security; create policy tenant_isolation'
          and v_forced
          and exists (select 1 from pg_catalog.pg_policy p
                       where p.polrelid = 'erp.quiet_hours'::regclass and p.polname = 'tenant_isolation')
          and not exists (select 1 from erp.row_security_drift());
    detail := coalesce(v_state, format('drift %s | forced %s', v_drift, v_forced));
    return next;

    -- ── 5. A live guard in place is left, a missing one put back ────────────
    v_step := 'the live guards';
    select t.oid into v_trg from pg_catalog.pg_trigger t
     where t.tgrelid = 'erp.printer'::regclass and t.tgname = 't_printer_live_guard';
    perform erp.apply_live_config_guards();
    select t.oid into v_trg2 from pg_catalog.pg_trigger t
     where t.tgrelid = 'erp.printer'::regclass and t.tgname = 't_printer_live_guard';
    execute 'drop trigger t_printer_live_guard on erp.printer';
    perform erp.apply_live_config_guards();
    v_cases := v_cases + 1;
    case_name := 'a live guard already in place is left as it is, and one that went is put back';
    passed := v_state is null and v_trg is not null and v_trg2 = v_trg
          and exists (select 1 from pg_catalog.pg_trigger t
                       where t.tgrelid = 'erp.printer'::regclass and t.tgname = 't_printer_live_guard'
                         and t.tgfoid = 'erp.guard_live_configuration()'::regprocedure and t.tgtype = 31);
    detail := coalesce(v_state, format('before %s, after a run %s', v_trg, v_trg2));
    return next;

    -- ── 6. A time zone answers as before ────────────────────────────────────
    v_step := 'an organisation with time zones';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzmlk-' || v_tag, 'Migration Locks Suite', 'admin@zzmlk-' || v_tag || '.test', 'Locks Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzmlk-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id order by s.code limit 1;
    update erp.tenant set default_timezone = 'Europe/Oslo' where id = rb.tenant_id;
    update erp.site set timezone = 'America/New_York' where id = v_site;
    v_tz1 := erp.local_timezone(v_site);
    v_tz2 := erp.local_timezone(null);
    update erp.site set timezone = 'Europe/Londn' where id = v_site;
    update erp.tenant set default_timezone = 'Not/A_Zone' where id = rb.tenant_id;
    v_tz3 := erp.local_timezone(v_site);
    v_cases := v_cases + 1;
    case_name := 'a site''s time zone comes first, then the organisation''s, and a name the server cannot use is UTC';
    passed := v_state is null and v_tz1 = 'America/New_York' and v_tz2 = 'Europe/Oslo' and v_tz3 = 'UTC'
          and erp.local_today(v_site) = (pg_catalog.now() at time zone 'UTC')::date;
    detail := coalesce(v_state, format('%s, %s, %s', v_tz1, v_tz2, v_tz3));
    return next;

    -- ── 7. And without reading the zone directory ───────────────────────────
    select p.prosrc into v_body from pg_catalog.pg_proc p where p.oid = 'erp.local_timezone(uuid)'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'dating a document no longer reads the server''s whole time zone directory';
    passed := v_state is null
          and strpos(regexp_replace(v_body, '--[^\n]*', '', 'g'), 'pg_timezone_names') = 0;
    detail := coalesce(v_state, 'erp.local_timezone reads ' ||
              case when strpos(regexp_replace(v_body, '--[^\n]*', '', 'g'), 'pg_timezone_names') = 0
                   then 'no zone list' else 'pg_timezone_names' end);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_MIGRATION_LOCKS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.migration_locks_suite() from public, anon;

comment on function erp_test.migration_locks_suite() is
  'A migration locks only what it changes (20261010010000): run twice, row security and the live guards lock no '
  'table; an edited or dropped policy, unforced row security and a dropped guard are still put back; a time zone '
  'answers as before without reading the zone directory.';

create or replace function erp_test.assert_migration_locks_suite()
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
    from erp_test.migration_locks_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_MIGRATION_LOCKS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A generator rebuilt what was already right, and so locked tables every deploy, or stopped putting back what drifted. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_MIGRATION_LOCKS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('migration locks: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_migration_locks_suite() from public, anon;

comment on function erp_test.assert_migration_locks_suite() is
  'The generators at the end of every migration lock only what they change, and still put back what drifted (20261010010000).';

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
