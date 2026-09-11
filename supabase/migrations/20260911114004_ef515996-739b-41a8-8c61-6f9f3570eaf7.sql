create or replace function erp_test.assert_document_issue_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 13;
  v_total integer; v_failed integer; v_detail text;
begin
  select count(*), count(*) filter (where not r.passed),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n')
           filter (where not r.passed)
    into v_total, v_failed, v_detail
    from erp_test.document_issue_suite() r;

  if v_failed > 0 then
    raise exception E'ERPWARE_DOCUMENT_ISSUE_SUITE_FAILED: %/% case(s) failed\n%',
      v_failed, v_total, v_detail;
  end if;
  if v_total <> c_expected then
    raise exception 'ERPWARE_DOCUMENT_ISSUE_SUITE_INCOMPLETE: expected % cases, ran %',
      c_expected, v_total
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('document issue: %s/%s cases passed', v_total, v_total);
end;
$$;

do $do$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp_test' and p.proname = 'document_issue_suite';

  -- The isolation case must read as an ordinary signed-in user. Run as the
  -- owner it proves nothing: the owner bypasses row security.
  v_src := replace(v_src,
$old$  return query select 'another organisation cannot see this organisation''s issues',
    public.erp_document_issues(null, 100) = '[]'::jsonb
      and not exists (select 1 from erp.document_issue di where di.id = v_issue2),
    'read as the administrator of a different organisation';$old$,
$new$  v_owner := current_user;
  execute 'set local role authenticated';
  v_ok := public.erp_document_issues(null, 100) = '[]'::jsonb
      and not exists (select 1 from erp.document_issue di where di.id = v_issue2);
  execute format('set local role %I', v_owner);
  return query select 'another organisation cannot see this organisation''s issues',
    v_ok, 'read as the administrator of a different organisation';

  return query select 'an issue cannot be read without the organisation behind it',
    (select count(*) from erp.document_issue di where di.tenant_id = r.tenant_id) > 0,
    'the issues are still there for the organisation that owns them';$new$);

  v_src := replace(v_src,
    'v_env uuid; v_c jsonb; v_v jsonb; v_ok boolean; v_msg text; v_before integer;',
    'v_env uuid; v_c jsonb; v_v jsonb; v_ok boolean; v_msg text; v_before integer; v_owner text;');

  execute v_src;
end $do$;

select erp_test.assert_document_issue_suite();
