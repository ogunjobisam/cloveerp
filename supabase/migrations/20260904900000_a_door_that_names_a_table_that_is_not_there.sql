-- ─────────────────────────────────────────────────────────────────────────────
-- A door that names a table that is not there.
--
-- Found by the production-readiness pass, Phase 8, by pressing the button on
-- Settings → Organisation that says "export everything this organisation holds":
--
--   select public.erp_export_tenant();
--     ERROR:  relation "erp.audit_log" does not exist
--
-- The stream is erp.audit_entry, and has been for as long as there has been
-- one. erp_export_tenant names erp.audit_log, so the portability door — the one
-- an organisation uses to take its data away — has never once produced a file.
-- It is wired to a real button in src/routes/administration/tenant.tsx.
--
-- PL/pgSQL plans a statement the first time it runs it, so a table name that
-- does not resolve is not a build failure, a migration failure, or an assertion
-- failure. It is silence until somebody calls the function. Every check this
-- repository runs — the boundary check, the allow-list, assert_public_api_safe,
-- the whole suite catalogue — passed over this for as long as it has existed,
-- because all of them read the register and the ACL and none of them reads the
-- body for names.
--
-- So the second finding was inevitable once the first was found by asking the
-- question of every function rather than of one:
--
--   erp.determine_account  ->  erp.entity_legislation
--
-- The table is erp.entity_legislation_binding, and the column is pack_code, not
-- legislation_pack_code. That statement sits before every determination lookup
-- in the function, so erp.determine_account() — and public.erp_determine_account
-- behind it — raises on every call that reaches it. Account determination is
-- how §5 refuses to guess at a posting account; the door that answers "which
-- account does this go to" has never answered.
--
-- erp_test.chart_alternative_suite has a case named
--
--   'erp.determine_account() has something to answer from'
--
-- and it passes. What it measures is `select count(*) from
-- erp.account_determination` — twenty rules exist. It never calls the function
-- it is named after. That is the same shape as the support finding one
-- migration earlier: a model that is tested, and the path into it that is not.
--
-- Both are repaired below, and then the class is closed rather than the two
-- instances: erp.missing_relation_report() reads every function body in the
-- product's schemas for a schema-qualified name used as a relation, and reports
-- the ones that do not resolve. It found exactly these two and nothing else, so
-- it is not a net thrown over a guess — it is the measurement, kept.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The portability door ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_export_tenant()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb;
begin
  perform erp.authorise('administration.configure');

  select jsonb_build_object(
    'exported_at', now(),
    'format', 'erpware.tenant-export.v1',
    'tenant', (select to_jsonb(t) from erp.tenant t where t.id = v_tenant),
    'entities', coalesce((select jsonb_agg(to_jsonb(e)) from erp.entity e where e.tenant_id = v_tenant), '[]'::jsonb),
    'sites', coalesce((select jsonb_agg(to_jsonb(s)) from erp.site s where s.tenant_id = v_tenant), '[]'::jsonb),
    'locations', coalesce((select jsonb_agg(to_jsonb(l)) from erp.location l where l.tenant_id = v_tenant), '[]'::jsonb),
    'principals', coalesce((select jsonb_agg(to_jsonb(u) - 'auth_user_id') from erp.app_user u where u.tenant_id = v_tenant), '[]'::jsonb),
    'roles', coalesce((select jsonb_agg(to_jsonb(r)) from erp.role r where r.tenant_id = v_tenant), '[]'::jsonb),
    'role_permissions', coalesce((select jsonb_agg(to_jsonb(rp)) from erp.role_permission rp where rp.tenant_id = v_tenant), '[]'::jsonb),
    'user_roles', coalesce((select jsonb_agg(to_jsonb(ur)) from erp.user_role ur where ur.tenant_id = v_tenant), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(to_jsonb(i)) from erp.item i where i.tenant_id = v_tenant), '[]'::jsonb),
    'uoms', coalesce((select jsonb_agg(to_jsonb(u)) from erp.uom u where u.tenant_id = v_tenant), '[]'::jsonb),
    'parties', coalesce((select jsonb_agg(to_jsonb(p)) from erp.party p where p.tenant_id = v_tenant), '[]'::jsonb),
    'party_roles', coalesce((select jsonb_agg(to_jsonb(pr)) from erp.party_role pr where pr.tenant_id = v_tenant), '[]'::jsonb),
    'document_types', coalesce((select jsonb_agg(to_jsonb(dt)) from erp.document_type dt where dt.tenant_id = v_tenant), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(to_jsonb(d)) from erp.document d where d.tenant_id = v_tenant), '[]'::jsonb),
    'document_lines', coalesce((select jsonb_agg(to_jsonb(dl)) from erp.document_line dl where dl.tenant_id = v_tenant), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(to_jsonb(b)) from erp.batch b where b.tenant_id = v_tenant), '[]'::jsonb),
    'stock_movements', coalesce((select jsonb_agg(to_jsonb(m)) from erp.stock_movement m where m.tenant_id = v_tenant), '[]'::jsonb),
    'journals', coalesce((select jsonb_agg(to_jsonb(j)) from erp.journal j where j.tenant_id = v_tenant), '[]'::jsonb),
    'journal_lines', coalesce((select jsonb_agg(to_jsonb(jl)) from erp.journal_line jl where jl.tenant_id = v_tenant), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(ev)) from erp.event ev where ev.tenant_id = v_tenant), '[]'::jsonb),
    -- erp.audit_log has never existed. The audit stream is erp.audit_entry, and
    -- naming the other one is what made this door raise on every call it has
    -- ever received.
    'audit', coalesce((select jsonb_agg(to_jsonb(al)) from erp.audit_entry al where al.tenant_id = v_tenant), '[]'::jsonb),
    'resource_overrides', coalesce((select jsonb_agg(to_jsonb(ro)) from erp.resource_override ro where ro.tenant_id = v_tenant), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$function$;

-- ── The determination lookup ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.determine_account(p_transaction_type text, p_item_id uuid DEFAULT NULL::uuid, p_party_id uuid DEFAULT NULL::uuid, p_site_id uuid DEFAULT NULL::uuid, p_entity_id uuid DEFAULT NULL::uuid, p_ledger_id uuid DEFAULT NULL::uuid, p_reason_code text DEFAULT NULL::text, p_on date DEFAULT NULL::date, p_raise boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_tenant     uuid := erp.require_tenant_id();
  v_on         date := coalesce(p_on, current_date);
  v_item_class uuid;
  v_party_class uuid;
  v_pack       text;
  r            record;
begin
  select ipc.posting_class_id into v_item_class
    from erp.item_posting_class ipc
   where ipc.tenant_id = v_tenant and ipc.item_id = p_item_id
     and ipc.status = 'active'
     and daterange(ipc.valid_from, ipc.valid_to, '[)') @> v_on
   limit 1;

  select ppc.posting_class_id into v_party_class
    from erp.party_posting_class ppc
   where ppc.tenant_id = v_tenant and ppc.party_id = p_party_id
     and ppc.status = 'active'
     and daterange(ppc.valid_from, ppc.valid_to, '[)') @> v_on
   limit 1;

  if p_item_id is not null and v_item_class is null then
    if p_raise then
      raise exception
        'ERPWARE_POSTING_CLASS_MISSING: the item has no posting class in force on %', v_on
        using errcode = '23502';
    end if;
    return jsonb_build_object('matched', false, 'why', 'item_posting_class_missing');
  end if;

  -- The binding is erp.entity_legislation_binding and its column is pack_code.
  -- Named as erp.entity_legislation.legislation_pack_code, this statement
  -- raised on every call that reached it, which is every call that gets past
  -- the posting-class check above. A binding is dated like everything else
  -- here, so the one in force on the date being determined is the one that
  -- decides — reading any row of it would answer with last year's legislation
  -- as readily as this year's.
  select b.pack_code into v_pack
    from erp.entity_legislation_binding b
   where b.tenant_id = v_tenant
     and b.entity_id = p_entity_id
     and b.status = 'active'
     and b.effective_from <= v_on
     and (b.effective_to is null or b.effective_to > v_on)
   order by b.effective_from desc
   limit 1;

  select ad.* into r
    from erp.account_determination ad
   where ad.tenant_id = v_tenant
     and ad.transaction_type = p_transaction_type
     and ad.status = 'active'
     and daterange(ad.valid_from, ad.valid_to, '[)') @> v_on
     and (ad.item_class_id is null or ad.item_class_id = v_item_class)
     and (ad.party_class_id is null or ad.party_class_id = v_party_class)
     and (ad.site_id is null or ad.site_id = p_site_id)
     and (ad.entity_id is null or ad.entity_id = p_entity_id)
     and (ad.ledger_id is null or ad.ledger_id = p_ledger_id)
     and (ad.reason_code is null or ad.reason_code = p_reason_code)
     and (ad.legislation_pack_code is null
          or v_pack is null
          or ad.legislation_pack_code = v_pack)
   order by
     (ad.item_class_id is not null)::int + (ad.party_class_id is not null)::int
   + (ad.site_id is not null)::int + (ad.entity_id is not null)::int
   + (ad.ledger_id is not null)::int + (ad.reason_code is not null)::int
   + (ad.legislation_pack_code is not null)::int desc,
     ad.valid_from desc
   limit 1;

  if r.id is null then
    if p_raise then
      raise exception
        'ERPWARE_DETERMINATION_FAILED: no account rule matches % for this item, party and place',
        p_transaction_type
        using errcode = '23503';
    end if;
    return jsonb_build_object(
      'matched', false, 'why', 'no_rule',
      'transaction_type', p_transaction_type,
      'item_class_id', v_item_class, 'party_class_id', v_party_class);
  end if;

  return jsonb_build_object(
    'matched', true,
    'rule_id', r.id, 'rule_version', r.version,
    'transaction_type', p_transaction_type,
    'account_id', r.account_id,
    'account_code', (select a.code from erp.account a
                      where a.tenant_id = v_tenant and a.id = r.account_id),
    'account_name', (select a.name from erp.account a
                      where a.tenant_id = v_tenant and a.id = r.account_id),
    'dimensions', r.dimensions,
    'item_class_id', v_item_class, 'party_class_id', v_party_class,
    'resolved_on', v_on);
end;
$function$;

-- ── The class, closed ────────────────────────────────────────────────────────

-- An exemption register rather than a list inside the check, so that anything
-- deliberately dynamic is written down with a reason instead of being quietly
-- skipped. It is empty on the day it is created, which is the whole point:
-- there is nothing to excuse.
create table if not exists erp_meta.missing_relation_exemption (
  relation    text primary key,
  rationale   text not null,
  created_at  timestamptz not null default now()
);

comment on table erp_meta.missing_relation_exemption is
  'Names erp.missing_relation_report() must not report. A relation belongs '
  'here only when the name is built at run time or lives in a schema this '
  'build does not create; a name that is simply wrong belongs in a repair, '
  'not in here.';

select erp_meta.register_table('erp_meta', 'missing_relation_exemption',
  'platform_internal',
  'Relation names a function body builds at run time. Not tenant data.');

-- Registering a table is not securing it; the generator is what turns the
-- register into row security, and a new table that skips it is exactly the
-- finding erp.assert_isolation() exists to raise.
select erp.apply_platform_internal_security();

create or replace function erp.missing_relation_report()
returns table (schema_name text, function_name text, relation text)
language sql
stable
set search_path to ''
as $$
  -- A schema-qualified name in the position a relation goes — after FROM, JOIN,
  -- UPDATE, INSERT INTO or DELETE FROM — that does not resolve to one.
  --
  -- \M anchors the end of the name at a word boundary. Without it the regex
  -- engine backtracks a character at a time to satisfy the lookahead below and
  -- reports every table in the product as missing, one letter short of its own
  -- name, which is a check that finds nothing by finding everything.
  --
  -- The lookahead excludes a name followed by "(", because `from erp.foo(...)`
  -- is a set-returning function and not a relation at all. That distinction is
  -- the difference between two findings and five hundred.
  with body as (
    select n.nspname::text as sch, p.proname::text as fn, p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test')
       and p.prokind = 'f'
       and p.prolang = (select oid from pg_catalog.pg_language where lanname = 'plpgsql')
  ), named as (
    select b.sch, b.fn,
           lower((regexp_matches(
             b.prosrc,
             '(?:from|join|update|into|delete\s+from)\s+'
             '((?:erp|erp_ref|erp_meta|erp_ai|erp_test|auth)\.[a-z_][a-z0-9_]*)\M(?!\s*\()',
             'gi'))[1]) as rel
      from body b
  )
  select distinct nm.sch, nm.fn, nm.rel
    from named nm
   where to_regclass(nm.rel) is null
     and not exists (select 1 from erp_meta.missing_relation_exemption x
                      where x.relation = nm.rel)
   order by 1, 2, 3
$$;

revoke all on function erp.missing_relation_report() from public, anon;

create or replace function erp.assert_no_missing_relations()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s.%s reads %s, which does not exist',
                                     r.schema_name, r.function_name, r.relation), E'\n')
    into v_count, v_detail
    from erp.missing_relation_report() r;

  if v_count > 0 then
    raise exception E'ERPWARE_MISSING_RELATION: % finding(s)\n%', v_count, v_detail
      using errcode = '42P01',
      hint = 'PL/pgSQL does not resolve a table name until the statement runs, '
             'so a door naming a table that is not there builds green and '
             'raises in front of somebody. Correct the name, or register a '
             'genuinely dynamic one in erp_meta.missing_relation_exemption.';
  end if;

  return format('relations: every table named by a function body exists (%s bodies read)',
                (select count(*) from pg_catalog.pg_proc p
                   join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                  where n.nspname in ('erp','public','erp_meta','erp_ref','erp_ai','erp_test')
                    and p.prokind = 'f'
                    and p.prolang = (select oid from pg_catalog.pg_language
                                      where lanname = 'plpgsql')));
end;
$$;

revoke all on function erp.assert_no_missing_relations() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('no_missing_relations', 'Every table a function names exists', 'assertion',
   'platform', 'erp', 'assert_no_missing_relations', '',
   'missing_relation_report', '',
   'A PL/pgSQL body naming a table that does not exist builds green and raises '
   'in front of whoever presses the button. Two doors had done so since they '
   'were written.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

select erp.assert_isolation();
select erp.assert_no_missing_relations();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();

-- ── And the two doors, called ────────────────────────────────────────────────
--
-- erp.assert_no_missing_relations() above closes the class and is the stronger
-- guard, because it reads every body rather than the two that were wrong. These
-- two cases are still worth having: a name can resolve while the column behind
-- it does not, and the only way to find that out is to press the button. Both
-- of these doors had a passing test beside them the whole time — one counting
-- rows in a table, one never called at all.

create or replace function erp_test.door_runs_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  r       record;
  v_auth  uuid := gen_random_uuid();
  v_out   jsonb;
  v_ok    boolean;
  v_msg   text;
  v_cases int := 0;
begin
  select * into r from erp.provision_tenant(
    'zzdoor-suite', 'Door Suite', 'admin@zzdoor.test', 'Door Suite Admin');

  insert into auth.users (id, email) values (v_auth, 'admin@zzdoor.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- §9.4 portability: an organisation can take what it holds away.
  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'did not return';
  begin
    v_out := public.erp_export_tenant();
    v_ok := v_out ? 'audit' and v_out ? 'documents' and v_out ? 'principals'
            and (v_out ->> 'format') = 'erpware.tenant-export.v1';
    v_msg := format('%s sections', (select count(*) from jsonb_object_keys(v_out) k));
  exception when others then
    v_msg := left(sqlerrm, 90);
  end;
  return query select 'the export door produces a document'::text, v_ok, v_msg;

  -- §5: determination answers, or refuses by name. What it must not do is
  -- raise about its own tables.
  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'did not return';
  begin
    v_out := erp.determine_account(
      'goods_receipt', null, null, null,
      (select e.id from erp.entity e where e.tenant_id = r.tenant_id limit 1),
      null, null, current_date, false);
    v_ok := v_out ? 'matched';
    v_msg := format('matched=%s, why=%s', v_out ->> 'matched',
                    coalesce(v_out ->> 'why', '-'));
  exception when others then
    v_msg := left(sqlerrm, 90);
  end;
  return query select 'the determination door answers rather than raising'::text,
    v_ok, v_msg;

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id = v_auth;

  v_cases := v_cases + 1;
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp.tenant t where t.code = 'zzdoor-suite'),
    'and the export it made was never written anywhere';

  if v_cases <> 3 then
    raise exception 'ERPWARE_SUITE_SHRANK: door_runs_suite ran % cases, expected 3', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.door_runs_suite() from public, anon;

create or replace function erp_test.assert_door_runs_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _dr on commit drop as
    select * from erp_test.door_runs_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _dr;
  if v_fail > 0 then
    raise exception E'ERPWARE_DOOR_RUNS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'A door raised instead of answering. If it named a table that is '
             'not there, erp.assert_no_missing_relations() will say which.';
  end if;
  return format('doors run: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_door_runs_suite() from public, anon;
