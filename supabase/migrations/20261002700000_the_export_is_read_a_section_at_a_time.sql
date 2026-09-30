set lock_timeout = '30s';

-- ═════════════════════════════════════════════════════════════════════════════
-- The export is read a section at a time
-- ═════════════════════════════════════════════════════════════════════════════
--
-- public.erp_export_tenant() builds everything an organisation holds, every
-- audit entry with its before and after state included, as one jsonb value in
-- one statement. With fifty-five seconds to do it in (20261001910000), four of
-- those at once stopped the live database on 30 September; 20261002600000 put
-- it back under the authenticated role's eight seconds, where an organisation
-- of any size is refused as "took too long" instead. Neither is an export.
--
-- So the file is asked for a page at a time, and assembled by the screen
-- (src/lib/tenant-export.ts):
--
--   * public.erp_export_tenant_manifest() answers what the file opens with —
--     exported_at, the format, the organisation's own row — and the sections
--     that follow, in order. The format is still erpware.tenant-export.v1 and
--     the sections are the single export's own, so the file is the same
--     document.
--
--   * public.erp_export_tenant_section(section, after, limit) answers one page
--     of one section: its rows in id order after the cursor, and the cursor for
--     the next page, or null when the section is done. A page is 500 rows
--     unless asked otherwise, never more than 1,000, and never more than 200 of
--     the audit trail, whose rows carry whole before and after states. The
--     section is one of a fixed list, each branch naming its own table, so no
--     name reaches the query from the caller. Principals leave out
--     auth_user_id, as the single export does.
--
-- Both run as the caller, under the caller's row security and the role's own
-- statement_timeout, after erp.authorise('administration.configure'), and read
-- only the organisation erp.require_tenant_id() resolves: the same gate and
-- the same scope as the export they replace on the screen. Every request now
-- holds at most a page, whatever the organisation's size.
--
-- A page is read by (tenant_id, id). The tables large enough to matter get
-- that index where they have none that leads with it; the loop below checks
-- what exists rather than assuming, so a table that already has one is left
-- alone.
--
-- public.erp_export_tenant() stays, unchanged and no longer called by the
-- screen: erp_test.door_runs_suite calls it, and under eight seconds it can
-- refuse but not harm.
--
-- Pages are read at slightly different moments, so an organisation that keeps
-- working through a long export gets a file that is not one instant's copy.
-- The screen says so; a copy of one instant would need the file built in the
-- background and kept, which is a different change.
-- ═════════════════════════════════════════════════════════════════════════════

-- ── The index a page is read by ──────────────────────────────────────────────

do $idx$
declare
  t      text;
  v_rel  regclass;
  v_tid  smallint;
  v_id   smallint;
begin
  foreach t in array array['audit_entry', 'event', 'stock_movement', 'journal_line',
                           'journal', 'document_line', 'document', 'batch'] loop
    v_rel := ('erp.' || t)::regclass;
    select a.attnum into v_tid from pg_catalog.pg_attribute a where a.attrelid = v_rel and a.attname = 'tenant_id';
    select a.attnum into v_id  from pg_catalog.pg_attribute a where a.attrelid = v_rel and a.attname = 'id';
    if v_tid is null or v_id is null then
      raise exception 'CLOVEERP_EXPORT_TABLE_SHAPE: erp.% has no tenant_id or no id to be paged by', t;
    end if;
    if not exists (select 1 from pg_catalog.pg_index i
                    where i.indrelid = v_rel and i.indnatts >= 2
                      and i.indkey[0] = v_tid and i.indkey[1] = v_id) then
      execute format('create index %I on erp.%I (tenant_id, id)', t || '_tenant_id_id_idx', t);
    end if;
  end loop;
end
$idx$;

-- ── What the file opens with ─────────────────────────────────────────────────

create or replace function public.erp_export_tenant_manifest()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');

  return jsonb_build_object(
    'exported_at', now(),
    'format', 'erpware.tenant-export.v1',
    'tenant', (select to_jsonb(t) from erp.tenant t where t.id = v_tenant),
    'sections', jsonb_build_array(
    'entities',
    'sites',
    'locations',
    'principals',
    'roles',
    'role_permissions',
    'user_roles',
    'items',
    'uoms',
    'parties',
    'party_roles',
    'document_types',
    'documents',
    'document_lines',
    'batches',
    'stock_movements',
    'journals',
    'journal_lines',
    'events',
    'audit',
    'resource_overrides'));
end;
$$;

revoke all on function public.erp_export_tenant_manifest() from public, anon;
grant execute on function public.erp_export_tenant_manifest() to authenticated, service_role;

comment on function public.erp_export_tenant_manifest() is
  'The opening of the organisation''s export — exported_at, the format '
  '(erpware.tenant-export.v1) and the organisation''s own row — and the sections '
  'that follow, in order, each read with erp_export_tenant_section. Under '
  'administration.configure, for the organisation in context (20261002700000).';

-- ── One page of one section ──────────────────────────────────────────────────

create or replace function public.erp_export_tenant_section(
  p_section text,
  p_after   text    default null,
  p_limit   integer default 500)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_limit  integer;
  v_rows   jsonb;
  v_last   text;
  v_n      integer;
begin
  perform erp.authorise('administration.configure');

  v_limit := least(greatest(coalesce(p_limit, 500), 1),
                   case when p_section = 'audit' then 200 else 1000 end);

  if p_section = 'entities' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select e.* from erp.entity e
             where e.tenant_id = v_tenant and (p_after is null or e.id > p_after::uuid)
             order by e.id limit v_limit) x;
  elsif p_section = 'sites' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select s.* from erp.site s
             where s.tenant_id = v_tenant and (p_after is null or s.id > p_after::uuid)
             order by s.id limit v_limit) x;
  elsif p_section = 'locations' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select l.* from erp.location l
             where l.tenant_id = v_tenant and (p_after is null or l.id > p_after::uuid)
             order by l.id limit v_limit) x;
  elsif p_section = 'principals' then
    select coalesce(jsonb_agg(to_jsonb(x) - 'auth_user_id' order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select u.* from erp.app_user u
             where u.tenant_id = v_tenant and (p_after is null or u.id > p_after::uuid)
             order by u.id limit v_limit) x;
  elsif p_section = 'roles' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select r.* from erp.role r
             where r.tenant_id = v_tenant and (p_after is null or r.id > p_after::uuid)
             order by r.id limit v_limit) x;
  elsif p_section = 'role_permissions' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select rp.* from erp.role_permission rp
             where rp.tenant_id = v_tenant and (p_after is null or rp.id > p_after::uuid)
             order by rp.id limit v_limit) x;
  elsif p_section = 'user_roles' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select ur.* from erp.user_role ur
             where ur.tenant_id = v_tenant and (p_after is null or ur.id > p_after::uuid)
             order by ur.id limit v_limit) x;
  elsif p_section = 'items' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select i.* from erp.item i
             where i.tenant_id = v_tenant and (p_after is null or i.id > p_after::uuid)
             order by i.id limit v_limit) x;
  elsif p_section = 'uoms' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select um.* from erp.uom um
             where um.tenant_id = v_tenant and (p_after is null or um.id > p_after::uuid)
             order by um.id limit v_limit) x;
  elsif p_section = 'parties' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select p.* from erp.party p
             where p.tenant_id = v_tenant and (p_after is null or p.id > p_after::uuid)
             order by p.id limit v_limit) x;
  elsif p_section = 'party_roles' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select pr.* from erp.party_role pr
             where pr.tenant_id = v_tenant and (p_after is null or pr.id > p_after::uuid)
             order by pr.id limit v_limit) x;
  elsif p_section = 'document_types' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select dt.* from erp.document_type dt
             where dt.tenant_id = v_tenant and (p_after is null or dt.id > p_after::uuid)
             order by dt.id limit v_limit) x;
  elsif p_section = 'documents' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select d.* from erp.document d
             where d.tenant_id = v_tenant and (p_after is null or d.id > p_after::uuid)
             order by d.id limit v_limit) x;
  elsif p_section = 'document_lines' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select dl.* from erp.document_line dl
             where dl.tenant_id = v_tenant and (p_after is null or dl.id > p_after::uuid)
             order by dl.id limit v_limit) x;
  elsif p_section = 'batches' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select b.* from erp.batch b
             where b.tenant_id = v_tenant and (p_after is null or b.id > p_after::uuid)
             order by b.id limit v_limit) x;
  elsif p_section = 'stock_movements' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select m.* from erp.stock_movement m
             where m.tenant_id = v_tenant and (p_after is null or m.id > p_after::bigint)
             order by m.id limit v_limit) x;
  elsif p_section = 'journals' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select j.* from erp.journal j
             where j.tenant_id = v_tenant and (p_after is null or j.id > p_after::uuid)
             order by j.id limit v_limit) x;
  elsif p_section = 'journal_lines' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select jl.* from erp.journal_line jl
             where jl.tenant_id = v_tenant and (p_after is null or jl.id > p_after::uuid)
             order by jl.id limit v_limit) x;
  elsif p_section = 'events' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select ev.* from erp.event ev
             where ev.tenant_id = v_tenant and (p_after is null or ev.id > p_after::uuid)
             order by ev.id limit v_limit) x;
  elsif p_section = 'audit' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select al.* from erp.audit_entry al
             where al.tenant_id = v_tenant and (p_after is null or al.id > p_after::bigint)
             order by al.id limit v_limit) x;
  elsif p_section = 'resource_overrides' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb),
           (array_agg(x.id::text order by x.id desc))[1], count(*)
      into v_rows, v_last, v_n
      from (select ro.* from erp.resource_override ro
             where ro.tenant_id = v_tenant and (p_after is null or ro.id > p_after::uuid)
             order by ro.id limit v_limit) x;
  else
    raise exception 'CLOVEERP_UNKNOWN_EXPORT_SECTION: % is not a section of the export', coalesce(p_section, '(none)')
      using errcode = '22023',
            hint = 'Ask erp_export_tenant_manifest for the sections, and ask for each by the name it gives.';
  end if;

  return jsonb_build_object(
    'section', p_section,
    'rows', v_rows,
    'next', case when v_n = v_limit then v_last end);
end;
$$;

revoke all on function public.erp_export_tenant_section(text, text, integer) from public, anon;
grant execute on function public.erp_export_tenant_section(text, text, integer) to authenticated, service_role;

comment on function public.erp_export_tenant_section(text, text, integer) is
  'One page of one section of the organisation''s export: its rows in id order '
  'after p_after, and the cursor for the next page (null when the section is '
  'done). 500 rows unless asked, at most 1,000, at most 200 of the audit trail. '
  'Under administration.configure, for the organisation in context (20261002700000).';

-- Both authorise, so both are volatile, so both are declared with their gate.
-- Neither writes anything of its own; erp.authorise records the decision in
-- erp.access_log, as it does for every door.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_export_tenant_manifest', 'erp.authorise',
   'Reads the opening of the organisation''s export under administration.configure. Volatile because it '
   'authorises; writes nothing of its own.'),
  ('erp_export_tenant_section', 'erp.authorise',
   'Reads one bounded page of one section of the organisation''s export under administration.configure. '
   'Volatile because it authorises; writes nothing of its own.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ── The single export keeps a home ───────────────────────────────────────────

-- The screen no longer names it, so it is registered for the one caller it
-- keeps: erp_test.door_runs_suite, and the suite below, which reads it to
-- prove the paged export gives the same document.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_export_tenant', 'suite_evidence', null,
   'The whole organisation as one value in one statement. The screen reads the export a section at a '
   'time instead (erp_export_tenant_manifest, erp_export_tenant_section, 20261002700000), because four '
   'of these at once stopped the live database on 30 September. Kept, under the authenticated role''s own '
   'statement_timeout (20261002600000), for erp_test.door_runs_suite and as the reference '
   'erp_test.tenant_export_sections_suite compares the paged export against.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.tenant_export_sections_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1         uuid := gen_random_uuid();
  v_step     text := 'provisioning';
  v_state    text;
  v_owner    text := current_user;
  r          record;
  rb         record;
  v_manifest jsonb;
  v_whole    jsonb;
  v_page     jsonb;
  v_sections text[];
  v_s        text;
  v_after    text;
  v_all      jsonb;
  v_pages    integer;
  v_max      integer;
  v_rows     integer := 0;
  v_bad      text[] := '{}';
  v_foreign  integer := 0;
  v_err      text;
  v_err2     text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzex-' || v_tag, 'Export Sections Suite', 'admin@zzex-' || v_tag || '.test', 'Export Admin');
    select * into rb from erp.provision_tenant(
      'zzexb-' || v_tag, 'Export Sections Other', 'admin@zzexb-' || v_tag || '.test', 'Other Admin');
    insert into auth.users (id, email) values (a1, 'admin@zzex-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);

    -- ── 1. The manifest opens the same document ─────────────────────────────
    v_step := 'the manifest';
    v_manifest := public.erp_export_tenant_manifest();
    v_whole := public.erp_export_tenant();
    select array_agg(x.value order by x.ordinality) into v_sections
      from jsonb_array_elements_text(v_manifest -> 'sections') with ordinality x;
    v_cases := v_cases + 1;
    case_name := 'the manifest opens the document the single export gives, and names exactly its sections';
    passed := coalesce(
      v_manifest ->> 'format' = 'erpware.tenant-export.v1'
      and v_manifest -> 'tenant' = v_whole -> 'tenant'
      and cardinality(v_sections) = 21
      and (select array_agg(k order by k) from unnest(v_sections) k)
        = (select array_agg(k order by k) from jsonb_object_keys(v_whole) k
            where k not in ('exported_at', 'format', 'tenant')), false);
    detail := format('%s sections: %s', cardinality(v_sections), array_to_string(v_sections, ', '));
    return next;

    -- ── 2. Every section, read whole, is the single export's ────────────────
    v_step := 'every section read to its end';
    foreach v_s in array v_sections loop
      v_all := '[]'::jsonb; v_after := null; v_pages := 0;
      loop
        v_page := public.erp_export_tenant_section(v_s, v_after, 1000);
        v_all := v_all || (v_page -> 'rows');
        v_pages := v_pages + 1;
        v_after := v_page ->> 'next';
        exit when v_after is null or v_pages > 1000;
      end loop;
      v_rows := v_rows + jsonb_array_length(v_all);
      v_foreign := v_foreign + (select count(*) from jsonb_array_elements(v_all) e
                                 where e ->> 'tenant_id' is distinct from r.tenant_id::text);
      if (select coalesce(jsonb_agg(e order by e ->> 'id'), '[]'::jsonb) from jsonb_array_elements(v_all) e)
         is distinct from
         (select coalesce(jsonb_agg(e order by e ->> 'id'), '[]'::jsonb) from jsonb_array_elements(v_whole -> v_s) e) then
        v_bad := v_bad || v_s;
      end if;
    end loop;
    v_cases := v_cases + 1;
    case_name := 'every section read to its end is the section the single export gives, row for row';
    passed := cardinality(v_bad) = 0 and v_rows > 0;
    detail := case when cardinality(v_bad) = 0 then format('%s rows across %s sections', v_rows, cardinality(v_sections))
                   else 'differs: ' || array_to_string(v_bad, ', ') end;
    return next;

    -- ── 3. Only the organisation in context ─────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'every row read carries the organisation in context, and the other organisation has rows of its own to leak';
    passed := v_foreign = 0
      and exists (select 1 from erp.role_permission rp where rp.tenant_id = rb.tenant_id);
    detail := format('%s row(s) from another organisation', v_foreign);
    return next;

    -- ── 4. Small pages give the same rows, once each ────────────────────────
    v_step := 'small pages';
    v_bad := '{}';
    v_cases := v_cases + 1;
    case_name := 'read three rows a page, a uuid-keyed and a number-keyed section give the same rows once each';
    detail := '';
    foreach v_s in array array['role_permissions', 'audit'] loop
      v_all := '[]'::jsonb; v_after := null; v_pages := 0; v_max := 0;
      loop
        v_page := public.erp_export_tenant_section(v_s, v_after, 3);
        v_max := greatest(v_max, jsonb_array_length(v_page -> 'rows'));
        v_all := v_all || (v_page -> 'rows');
        v_pages := v_pages + 1;
        v_after := v_page ->> 'next';
        exit when v_after is null or v_pages > 5000;
      end loop;
      if v_max > 3
         or (select count(*) from jsonb_array_elements(v_all)) <> (select count(distinct e ->> 'id') from jsonb_array_elements(v_all) e)
         or (select coalesce(jsonb_agg(e order by e ->> 'id'), '[]'::jsonb) from jsonb_array_elements(v_all) e)
            is distinct from
            (select coalesce(jsonb_agg(e order by e ->> 'id'), '[]'::jsonb) from jsonb_array_elements(v_whole -> v_s) e)
         or (v_s = 'role_permissions' and v_pages < 2) then
        v_bad := v_bad || v_s;
      end if;
      detail := detail || format('%s: %s rows in %s pages; ', v_s, jsonb_array_length(v_all), v_pages);
    end loop;
    passed := cardinality(v_bad) = 0;
    return next;

    -- ── 5. A page is bounded whatever is asked ──────────────────────────────
    v_step := 'page bounds';
    v_cases := v_cases + 1;
    case_name := 'a page of nought is one row with a cursor, and no page is larger than its bound';
    v_page := public.erp_export_tenant_section('role_permissions', null, 0);
    passed := coalesce(
      jsonb_array_length(v_page -> 'rows') = 1 and (v_page ->> 'next') is not null
      and jsonb_array_length(public.erp_export_tenant_section('role_permissions', null, 100000) -> 'rows') <= 1000
      and jsonb_array_length(public.erp_export_tenant_section('audit', null, 100000) -> 'rows') <= 200, false);
    detail := format('limit 0 gave %s row(s)', jsonb_array_length(v_page -> 'rows'));
    return next;

    -- ── 6. Only the sections the manifest names ─────────────────────────────
    v_step := 'unknown sections';
    begin
      perform public.erp_export_tenant_section('app_user');
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_export_tenant_section(null);
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a table name, or no name, is refused as not a section';
    passed := coalesce(v_err like 'CLOVEERP_UNKNOWN_EXPORT_SECTION:%'
                       and v_err2 like 'CLOVEERP_UNKNOWN_EXPORT_SECTION:%', false);
    detail := coalesce(v_err, 'app_user was answered');
    return next;

    -- ── 7. Nobody signed in, nothing read ───────────────────────────────────
    v_step := 'signed out';
    perform set_config('request.jwt.claims', '', true);
    v_err := null; v_err2 := null;
    begin
      perform public.erp_export_tenant_manifest();
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_export_tenant_section('entities');
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'with no organisation in context, neither door answers';
    passed := v_err is not null and v_err2 is not null;
    detail := coalesce(v_err, 'the manifest answered') || ' / ' || coalesce(v_err2, 'a section answered');
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
    raise exception 'CLOVEERP_TENANT_EXPORT_SECTIONS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzex-' || v_tag, 'zzexb-' || v_tag))
     or exists (select 1 from auth.users u where u.id = a1)
     or current_user <> v_owner then
    raise exception 'CLOVEERP_TENANT_EXPORT_SECTIONS_SUITE_LEAKED: the fixture was not undone';
  end if;
end;
$$;

revoke all on function erp_test.tenant_export_sections_suite() from public, anon;

comment on function erp_test.tenant_export_sections_suite() is
  'The export read a section at a time gives the single export''s document, row for row, '
  'for the organisation in context only, in bounded pages (20261002700000).';

create or replace function erp_test.assert_tenant_export_sections_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.tenant_export_sections_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_TENANT_EXPORT_SECTIONS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The export read in pages no longer gives the single export''s document, or reads another organisation, or a page is no longer bounded. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_TENANT_EXPORT_SECTIONS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('tenant export sections: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_tenant_export_sections_suite() from public, anon;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
select erp.assert_no_missing_relations();
