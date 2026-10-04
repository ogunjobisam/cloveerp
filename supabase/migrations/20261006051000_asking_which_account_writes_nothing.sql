set lock_timeout = '30s';

-- =============================================================================
-- 20261006051000  Asking which account a posting takes writes nothing
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-26). On Which
-- accounts things post to, "Where would this post?" failed for a product
-- with no accounting code, and the screen called it a missing required field.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- public.erp_determine_account() asks erp.determine_account() without
-- raising, and then wrote an event about the answer. With no match it wrote
-- 'posting.determination_failed' with no aggregate, and erp.event's
-- aggregate_id is not null, so the question raised 23502 whenever nothing
-- matched: always for a product with no accounting code, and always in an
-- organisation with no rule here, which is every organisation that posts by
-- its posting rules alone (the demonstration among them). A match wrote
-- 'posting.rule_resolved' for every question asked. Nothing reads either
-- event: no posting rule, webhook or routine names them, and posting itself
-- (erp.posting_line_determination) writes neither. erp_test.door_runs_suite
-- asked erp.determine_account, never the door.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_determine_account(): a question writes nothing. It still
--      authorises finance.read, which records the access as before, and it
--      answers what erp.determine_account answers. An unmatched answer also
--      says in words what the posting takes instead: a product with no
--      accounting code, or a question no rule here covers, takes the account
--      its posting rule names (erp.posting_line_determination, step 4). The
--      sentence calls it an accounting rule, the screen's word for one.
--   B. erp_test.door_runs_suite asks the door about a product with no
--      accounting code and about a transaction type no rule covers, and
--      requires an answer, not a refusal; asked where a rule does cover, it
--      names that rule's account; and no question leaves an event behind.
--
-- On production: one door is replaced and a suite extended. No table is
-- altered and no row of any organisation is changed. Events the door wrote
-- before stay where they are.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A question answers, and writes nothing
-- ─────────────────────────────────────────────────────────────────────────────

do $door$
declare
  v_sig  constant text := 'public.erp_determine_account(text,uuid,uuid,uuid,uuid,uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if coalesce((v_out->>'matched')::boolean, false) then
    perform erp.append_event('posting.rule_resolved', 'posting',
      nullif(v_out->>'rule_id','')::uuid, v_out);
  else
    perform erp.append_event('posting.determination_failed', 'posting', null,
      v_out || jsonb_build_object('item_id', p_item_id, 'party_id', p_party_id));
  end if;
$o$;
  v_new  constant text := $n$  -- A question writes nothing (20261006051000). Unmatched, it wrote an event
  -- with no aggregate and raised 23502; matched, an event nothing reads. With
  -- no match the answer says what the posting takes instead, as
  -- erp.posting_line_determination does when it posts.
  if not coalesce((v_out->>'matched')::boolean, false) then
    v_out := v_out || jsonb_build_object('answer',
      case v_out->>'why'
        when 'item_posting_class_missing' then
          'This product has no accounting code, so no rule here applies to it. It takes the account its accounting rule names.'
        else
          'No rule here covers this. It takes the account its accounting rule names.'
      end);
  end if;
$n$;
begin
  if strpos(v_src, '20261006051000') > 0 then
    raise notice '% already writes nothing; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '534c5b5580060a093019524d7e44d049' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006051000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$door$;

comment on function public.erp_determine_account(text, uuid, uuid, uuid, uuid, uuid, text) is
  'Where would this post: the account and analysis the determination rules give, and the rule that gave them, or, '
  'with no match, why and what the posting takes instead. Authorises finance.read and writes nothing else (20261006051000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof: the door is asked, and answers
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.door_runs_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    -- What the fixture adds.
    $o1$  v_pack  uuid;
begin
$o1$,
    $n1$  v_pack  uuid;
  v_uom   uuid;
  v_item  uuid;
  v_out2  jsonb;
begin
$n1$,
    -- The cases, after what is not covered yet.
    $o2$  return query select 'what is not covered yet is answered: four combinations, and the one with no rule'::text,
    v_ok, v_msg;
$o2$,
    $n2$  return query select 'what is not covered yet is answered: four combinations, and the one with no rule'::text,
    v_ok, v_msg;

  -- Where would this post? (20261006051000). Asked about a product with no
  -- accounting code, or where no rule covers, the door wrote an event with
  -- no aggregate and raised 23502. A question answers and writes nothing.
  insert into erp.uom (tenant_id, code, name, uom_class)
  values (r.tenant_id, 'EA', 'Each', 'quantity') returning id into v_uom;
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'ZDOORITEM', 'A product with no accounting code', v_uom, 'active')
  returning id into v_item;

  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'did not return';
  begin
    v_out := public.erp_determine_account('customer_invoice', v_item, null, null, v_ent, null, null);
    v_out2 := public.erp_determine_account('goods_receipt', null, null, null, v_ent, null, null);
    v_ok := (v_out ->> 'matched')::boolean is false
        and v_out ->> 'why' = 'item_posting_class_missing'
        and coalesce(v_out ->> 'answer', '') like '%accounting rule names%'
        and (v_out2 ->> 'matched')::boolean is false
        and v_out2 ->> 'why' = 'no_rule'
        and coalesce(v_out2 ->> 'answer', '') like '%accounting rule names%';
    v_msg := concat_ws(' / ', v_out ->> 'answer', v_out2 ->> 'answer');
  exception when others then
    v_msg := left(sqlerrm, 90);
  end;
  return query select 'where would this post is answered in words for a product with no accounting code, and where no rule covers'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  v_ok := false; v_msg := 'did not return';
  begin
    v_out := public.erp_determine_account('supplier_invoice', null, null, null, v_ent, null, null);
    v_ok := (v_out ->> 'matched')::boolean
        and v_out ->> 'account_code' = '4000'
        and not (v_out ? 'answer')
        and not exists (select 1 from erp.event ev
                         where ev.tenant_id = r.tenant_id
                           and ev.event_type in ('posting.rule_resolved', 'posting.determination_failed'));
    v_msg := format('account %s; %s posting event(s) written', v_out ->> 'account_code',
      (select count(*) from erp.event ev
        where ev.tenant_id = r.tenant_id
          and ev.event_type in ('posting.rule_resolved', 'posting.determination_failed')));
  exception when others then
    v_msg := left(sqlerrm, 90);
  end;
  return query select 'where a rule covers, the answer names its account, and no question writes an event'::text,
    v_ok, v_msg;
$n2$,
    -- The count.
    $o3$  if v_cases <> 4 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_runs_suite ran % cases, expected 4', v_cases;$o3$,
    $n3$  if v_cases <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_runs_suite ran % cases, expected 6', v_cases;$n3$];
  v_i integer;
begin
  if strpos(v_src, '20261006051000') > 0 then
    raise notice '% already asks where a posting would go; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '97dbff54e28e99884e42b4e4b8911fe1' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006051000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, v_i;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$suite$;

comment on function erp_test.door_runs_suite() is
  'Doors that must answer rather than raise: the export, determination, what is not covered yet (20261006050000) and '
  'where would this post (20261006051000), asked as an administrator in a throwaway organisation.';

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
select erp.assert_invoker_doors_executable();
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
