-- The retired refusal prefix came back in with the new work.
--
-- 20260904980000 retired ERPWARE_ across the platform and left an assertion
-- behind to keep it retired. Five routines written since then raise it again:
--
--   erp.assert_api_exposure_sound
--   erp.assert_document_archive_sound
--   erp.assert_document_issue_sound
--   erp_test.assert_document_archive_authenticated_suite
--   erp_test.assert_document_issue_suite
--
-- The client matches a refusal by its CLOVEERP_ token to find what was refused
-- and what to do next. A code under the old prefix resolves to nothing, so the
-- person who trips it gets raw database text. These five are assertions rather
-- than product paths, but the register does not care where a code is raised
-- and neither does the reader who sees one.
--
-- Same sweep as 20260904980000, with the size guard inverted: that migration
-- refused if it rewrote fewer than five hundred routines, because it was
-- renaming the platform. This one refuses if it rewrites none, because it is
-- catching a handful that slipped back.

do $sweep$
declare
  v_oids oid[];
  v_oid  oid;
  v_n    integer := 0;
begin
  select coalesce(array_agg(p.oid order by p.oid), '{}')
    into v_oids
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p')
     and p.prosrc like '%ERPWARE\_%'
     and not exists (select 1 from pg_catalog.pg_depend d
                      where d.classid = 'pg_catalog.pg_proc'::regclass
                        and d.objid = p.oid and d.deptype = 'e');

  foreach v_oid in array v_oids loop
    execute replace(pg_catalog.pg_get_functiondef(v_oid), 'ERPWARE_', 'CLOVEERP_');
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    raise exception 'CLOVEERP_SWEEP_FOUND_NOTHING: no routine holds the retired prefix, so this migration is describing a state that no longer exists';
  end if;

  raise notice 'retired prefix swept from % routine(s)', v_n;
end
$sweep$;

-- Comments carry the codes too, and the same assertion reads them.
do $comments$
declare
  r record;
  v_n integer := 0;
begin
  for r in
    select p.oid::regprocedure as sig, d.description
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      join pg_catalog.pg_description d
        on d.objoid = p.oid and d.classoid = 'pg_catalog.pg_proc'::regclass
     where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_test', 'public')
       and p.prokind = 'f'
       and d.description like '%ERPWARE\_%'
  loop
    execute format('comment on function %s is %L', r.sig,
                   replace(r.description, 'ERPWARE_', 'CLOVEERP_'));
    v_n := v_n + 1;
  end loop;

  raise notice 'retired prefix swept from % routine comment(s)', v_n;
end
$comments$;

select erp.assert_no_legacy_refusal_prefix();
