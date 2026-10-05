set lock_timeout = '30s';

-- =============================================================================
-- 20261007011000  Who approves is named
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-50). "Work out who
-- approves" on a requisition called public.erp_stamp_document_approval, which
-- answers the chain the routing rules resolve to; the screen declared nothing
-- to say about that answer, so it said "Route this requisition for approval —
-- done." and never who would approve. The answer could not have said it: each
-- step carried only approver_user_id, a uuid, and the document's Approval
-- routing card printed that uuid.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_stamp_document_approval answers each step with 'approver'
--      and 'approver_of_record', the people by name, as
--      public.erp_preview_approval_chain already names its approver. The stamp
--      it writes and the event it appends keep the ids alone, as before: they
--      are the evidence, and a name can change.
--   B. public.erp_document_approval_chain names them the same way on every
--      stamp it reads, so stamps written before this are named too.
--   C. erp_test.who_approves_is_named_suite.
--
-- The screen's half is in src/lib/plain-words.ts (the answer said as
-- "Work out who approves: Andy Approver.", or that no value band or named
-- approver applies), src/routes/procurement/index.tsx (the dialog's title is
-- its label) and src/routes/documents/$documentId.tsx (the card shows names).
--
-- On production: two doors are edited where they answer. No table is altered
-- and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Stamping answers the approvers by name
-- ─────────────────────────────────────────────────────────────────────────────

do $stamp$
declare
  v_sig  constant text := 'public.erp_stamp_document_approval(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  return v_chain;
end;$o$;
  v_new  constant text := $n$  -- The chain as stamped, each step's approver by name (20261007011000,
  -- J-50). The stamp and the event above keep the ids alone.
  return v_chain || jsonb_build_object('steps', coalesce((
    select jsonb_agg(e.st || jsonb_build_object(
             'approver', (select u.display_name from erp.app_user u
                           where u.tenant_id = v_tenant
                             and u.id = nullif(e.st ->> 'approver_user_id', '')::uuid),
             'approver_of_record', (select u.display_name from erp.app_user u
                           where u.tenant_id = v_tenant
                             and u.id = nullif(e.st ->> 'approver_of_record_user_id', '')::uuid))
           order by e.n)
      from jsonb_array_elements(coalesce(v_chain -> 'steps', '[]'::jsonb)) with ordinality as e(st, n)),
    '[]'::jsonb));
end;$n$;
begin
  if strpos(v_src, '20261007011000') > 0 then
    raise notice '% already names who approves; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '29bfb868942a584e95dd9c3a773967ff' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$stamp$;

comment on function public.erp_stamp_document_approval(uuid) is
  'Work out who approves: stamps the approval chain the routing rules resolve a document to (named approvers, then '
  'department value bands), under the permission that raises its type, and answers the chain with each step''s '
  'approver and approver of record by name (20261007011000, J-50). Asks nobody to approve.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A document's stamps name them too
-- ─────────────────────────────────────────────────────────────────────────────

do $chain$
declare
  v_sig  constant text := 'public.erp_document_approval_chain(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           'resolved_chain', s.resolved_chain) order by s.resolved_at desc), '[]'::jsonb)$o$;
  v_new  constant text := $n$           -- Each step's approver by name, on stamps written before
           -- 20261007011000 too (J-50).
           'resolved_chain', s.resolved_chain || jsonb_build_object('steps', coalesce((
             select jsonb_agg(e.st || jsonb_build_object(
                      'approver', (select u.display_name from erp.app_user u
                                    where u.tenant_id = s.tenant_id
                                      and u.id = nullif(e.st ->> 'approver_user_id', '')::uuid),
                      'approver_of_record', (select u.display_name from erp.app_user u
                                    where u.tenant_id = s.tenant_id
                                      and u.id = nullif(e.st ->> 'approver_of_record_user_id', '')::uuid))
                    order by e.n)
               from jsonb_array_elements(coalesce(s.resolved_chain -> 'steps', '[]'::jsonb))
                    with ordinality as e(st, n)), '[]'::jsonb)))
           order by s.resolved_at desc), '[]'::jsonb)$n$;
begin
  if strpos(v_src, '20261007011000') > 0 then
    raise notice '% already names who approves; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '84820471498d4d2bc3945848b807551d' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$chain$;

comment on function public.erp_document_approval_chain(uuid) is
  'The routing stamps on one document, latest first, each step''s approver and approver of record by name '
  '(20261007011000, J-50). Row security scopes it to the caller''s organisation; it authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.who_approves_is_named_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  a2        uuid := gen_random_uuid();
  a3        uuid := gen_random_uuid();
  v_owner   text := current_user;
  v_step    text := 'provisioning';
  v_state   text;
  rb        record;
  res       jsonb;
  v_entity  uuid; v_site uuid; v_uom uuid; v_item uuid; v_sup uuid;
  v_req     uuid; v_big uuid;
  v_andy    uuid; v_carol uuid;
  v_chain   jsonb;
  v_read    jsonb;
  v_signed  jsonb;
  v_stored  jsonb;
  v_st      jsonb;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzwan-' || v_tag, 'Who Approves Suite',
      'admin@zzwan-' || v_tag || '.test', 'Named Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzwan-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    res := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_entity := (res ->> 'entity_id')::uuid;
    v_site := (res ->> 'site_id')::uuid;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base and u.uom_class = 'quantity' and u.status = 'active'
     order by u.code limit 1;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZWANSUP', 'Who Approves Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZWANWID', 'Who Approves Widget', v_uom, 'active') returning id into v_item;

    v_step := 'two more people';
    res := public.erp_invite_principal('andy@zzwan-' || v_tag || '.test', 'Andy Approver');
    v_andy := (res ->> 'app_user_id')::uuid;
    insert into auth.users (id, email) values (a2, 'andy@zzwan-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('carol@zzwan-' || v_tag || '.test', 'Carol Cover');
    v_carol := (res ->> 'app_user_id')::uuid;
    insert into auth.users (id, email) values (a3, 'carol@zzwan-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- Andy approves the administrator's requisitions up to 500.00.
    v_step := 'a named approver for the administrator';
    insert into erp.approver_assignment (tenant_id, subject_kind, subject_id, object_type,
                                         approver_user_id, upper_bound_minor, reason)
    values (rb.tenant_id, 'principal', rb.admin_user_id, 'requisition', v_andy, 50000,
            'the who approves suite');
    v_req := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_req, v_item, 10, 1000, 'ten widgets');

    -- ── 1. Stamping answers the approver by name ─────────────────────────────
    v_step := 'working out who approves';
    v_chain := public.erp_stamp_document_approval(v_req);
    v_st := v_chain -> 'steps' -> 0;
    select s.resolved_chain into v_stored from erp.approval_routing_stamp s
     where s.tenant_id = rb.tenant_id and s.object_id = v_req order by s.id desc limit 1;
    v_cases := v_cases + 1;
    case_name := 'working out who approves answers each step with its approver by name, and the stamp keeps the ids';
    passed := jsonb_array_length(v_chain -> 'steps') = 1
          and v_st ->> 'approver_user_id' = v_andy::text
          and v_st ->> 'approver' = 'Andy Approver'
          and v_st ->> 'approver_of_record' = 'Andy Approver'
          and v_stored -> 'steps' -> 0 ->> 'approver_user_id' = v_andy::text
          and not (v_stored -> 'steps' -> 0 ? 'approver');
    detail := coalesce(v_state, format('%s step(s); first: %s (of record %s); stamped with a name: %s',
                jsonb_array_length(v_chain -> 'steps'), v_st ->> 'approver', v_st ->> 'approver_of_record',
                v_stored -> 'steps' -> 0 ? 'approver'));
    return next;

    -- ── 2. The document's stamps name them, read as the screen reads them ────
    v_step := 'reading the document''s stamps';
    v_read := public.erp_document_approval_chain(v_req);
    set local role authenticated;
    v_signed := public.erp_document_approval_chain(v_req);
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'the document''s approval routing names the approver, read alike signed in';
    passed := jsonb_array_length(v_read) = 1
          and v_read -> 0 -> 'resolved_chain' -> 'steps' -> 0 ->> 'approver' = 'Andy Approver'
          and v_read -> 0 -> 'resolved_chain' -> 'steps' -> 0 ->> 'approver_user_id' = v_andy::text
          and v_signed = v_read;
    detail := coalesce(v_state, format('%s stamp(s); approver %s; signed in alike %s', jsonb_array_length(v_read),
                v_read -> 0 -> 'resolved_chain' -> 'steps' -> 0 ->> 'approver', v_signed = v_read));
    return next;

    -- ── 3. Cover names who stands in and for whom ────────────────────────────
    v_step := 'Andy away, Carol covering';
    insert into erp.approval_delegation (tenant_id, from_user_id, to_user_id, kind, reason)
    values (rb.tenant_id, v_andy, v_carol, 'delegation', 'the who approves suite');
    v_chain := public.erp_stamp_document_approval(v_req);
    v_st := v_chain -> 'steps' -> 0;
    v_read := public.erp_document_approval_chain(v_req);
    v_cases := v_cases + 1;
    case_name := 'a step covered for names who approves and who they stand in for';
    passed := (v_st ->> 'covered')::boolean
          and v_st ->> 'approver' = 'Carol Cover'
          and v_st ->> 'approver_of_record' = 'Andy Approver'
          -- Both stamps were taken in this one transaction, at one time.
          and jsonb_array_length(v_read) = 2
          and exists (select 1 from jsonb_array_elements(v_read) x
                       where x -> 'resolved_chain' -> 'steps' -> 0 ->> 'approver' = 'Carol Cover'
                         and x -> 'resolved_chain' -> 'steps' -> 0 ->> 'approver_of_record' = 'Andy Approver');
    detail := coalesce(v_state, format('covered %s; approver %s for %s', v_st ->> 'covered',
                v_st ->> 'approver', v_st ->> 'approver_of_record'));
    return next;

    -- ── 4. Where no rule applies, nobody is named ────────────────────────────
    v_step := 'a requisition above the named approver''s limit';
    v_big := erp.open_document('requisition', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_big, v_item, 100, 1000, 'a hundred widgets');
    v_chain := public.erp_stamp_document_approval(v_big);
    v_cases := v_cases + 1;
    case_name := 'where no value band or named approver applies, the answer has no step and names nobody';
    passed := jsonb_typeof(v_chain -> 'steps') = 'array'
          and jsonb_array_length(v_chain -> 'steps') = 0
          and (v_chain ->> 'exhausted')::boolean
          and jsonb_array_length(public.erp_document_approval_chain(v_big) -> 0 -> 'resolved_chain' -> 'steps') = 0;
    detail := coalesce(v_state, format('steps %s, exhausted %s', v_chain -> 'steps', v_chain ->> 'exhausted'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_WHO_APPROVES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzwan-' || v_tag)
     or exists (select 1 from auth.users u where u.id in (a1, a2, a3)) then
    raise exception 'CLOVEERP_WHO_APPROVES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.who_approves_is_named_suite() from public, anon;

comment on function erp_test.who_approves_is_named_suite() is
  'Who approves is named (20261007011000, J-50): stamping answers each step''s approver and approver of record by '
  'name while the stamp keeps the ids; a document''s stamps are read with the names, signed in too; cover names '
  'who stands in and for whom; and where no rule applies the answer names nobody.';

create or replace function erp_test.assert_who_approves_is_named_suite()
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
    from erp_test.who_approves_is_named_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_WHO_APPROVES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Work out who approves would name nobody, or the wrong person. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_WHO_APPROVES_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('who approves is named: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_who_approves_is_named_suite() from public, anon;

comment on function erp_test.assert_who_approves_is_named_suite() is
  'Work out who approves names each approver, and a document''s approval routing shows names, not ids (20261007011000).';

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
