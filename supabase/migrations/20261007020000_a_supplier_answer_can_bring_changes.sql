set lock_timeout = '30s';

-- =============================================================================
-- 20261007020000  A supplier's answer can bring changes
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-62). "Record the
-- supplier's answer" on a sent purchase order offered two answers, "They will
-- send it" and "They cannot take it"; an answer with changes was only implied
-- by adding a changed line under the first. erp.record_supplier_response
-- takes a changed line as a proposal, and nothing else: an answer the buyer
-- meant as "with changes" and gave no changed line was taken as the order as
-- it stands, and confirmed it. Once the changes were accepted, the order's
-- page drew the proposal no more (it showed it only while it waited), so the
-- line read "Ordered 8" and the 10 that was ordered was shown nowhere,
-- although erp.purchase_order_confirmation still answers it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.record_supplier_response takes an answer that says it comes with
--      changes ("with_changes": true, beside "decision": "confirm") and
--      refuses it, CLOVEERP_WITH_CHANGES_NEEDS_A_LINE, when no line is
--      changed, rather than confirm the order as it stands. An answer that
--      does not say so is taken exactly as before, from the buyer's form and
--      from the supplier's own page alike.
--   B. The refusal, registered with what was refused, why and the next action.
--   C. The words: the third answer on the form, and the hint on its lines.
--   D. erp_test.supplier_answer_with_changes_suite, which also pins that an
--      accepted proposal is still answered, with what was ordered before it,
--      for the page to keep showing.
--
-- The screen's half is in src/components/erp/supplier-confirmation.tsx (the
-- third answer, and the proposal kept, without its buttons, once accepted) and
-- src/lib/supplier-confirmation.ts (recordedAnswer, proposalShown).
--
-- On production: one routine is patched where it decides an answer's status.
-- No table is altered and no row is changed; every organisation alike, since
-- the form is the same everywhere. No email is sent or changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. An answer with changes changes a line
-- ─────────────────────────────────────────────────────────────────────────────

do $answer$
declare
  v_sig  constant text := 'erp.record_supplier_response(uuid,jsonb,text,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    v_status := case when jsonb_array_length(v_proposal) = 0 then 'confirmed' else 'changes_proposed' end;$o$;
  v_new  constant text := $n$    v_status := case when jsonb_array_length(v_proposal) = 0 then 'confirmed' else 'changes_proposed' end;
    -- An answer said to come with changes changes a line (20261007020000,
    -- J-62): without one it would be taken as the order as it stands.
    if p_response -> 'with_changes' = 'true'::jsonb and jsonb_array_length(v_proposal) = 0 then
      raise exception 'CLOVEERP_WITH_CHANGES_NEEDS_A_LINE: % was answered with changes, but no line was changed', d.document_number
        using errcode = '23514',
              hint = 'Add each line they changed, with what they can send or by when, or record that they will send it as ordered.';
    end if;$n$;
begin
  if strpos(v_src, '20261007020000') > 0 then
    raise notice '% already refuses changes that change nothing; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1520f012974a81893a6929f1b60c2f0e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007020000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$answer$;

comment on function erp.record_supplier_response(uuid, jsonb, text, uuid) is
  'Records an order''s answer, from its supplier''s link or by its buyer: confirmed, changes proposed or declined '
  '(20261004990000). An answer said to come with changes must change a line, or it is refused '
  '(20261007020000, J-62). Called by erp.supplier_respond and erp.record_supplier_confirmation, which authorise.';

comment on function public.erp_record_supplier_confirmation(uuid, jsonb) is
  'Records the supplier''s answer to an order on their behalf (20261004990000): they will send it, they will send '
  'it with changes (a changed line is required, 20261007020000), or they cannot take it. Authorises '
  'procurement.order.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The refusal
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_WITH_CHANGES_NEEDS_A_LINE',
  'Recording that a supplier will send an order with changes, with no line changed.',
  'Changes are proposed line by line, for the buyer to accept or reject, and with no line changed there is nothing to propose.',
  'Add each line they changed, with what they can send or by when. If they will send the order as it stands, record that they will send it.');

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.en), v.locale, v.value,
       'A screen string, rendered through ui(). A supplier''s answer can bring changes (20261007020000).'
  from (values
    ('They will send it, with changes', 'en', 'They will send it, with changes'),
    ('They will send it, with changes', 'de', 'Sie liefern, mit Änderungen'),
    ('Needed when they will send it with changes.', 'en', 'Needed when they will send it with changes.'),
    ('Needed when they will send it with changes.', 'de', 'Nötig, wenn sie mit Änderungen liefern.')
  ) as v(en, locale, value)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.supplier_answer_with_changes_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid;
  v_po     uuid; v_po2 uuid; v_l1 uuid;
  v_conf   jsonb; v_read jsonb;
  v_err    text; v_err2 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, a supplier, and two orders sent to it';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzswc-' || v_tag, 'Answer With Changes Suite',
      'admin@zzswc-' || v_tag || '.test', 'Changes Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzswc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZWCCOAT', 'Changed Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZWCBRAND');
    -- Ten coats on each, approved and issued.
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZWC1');
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZWC2');
    select l.id into v_l1 from erp.document_line l where l.document_id = v_po and not l.is_cancelled;

    -- ── 1. The registers ────────────────────────────────────────────────────
    v_step := 'the refusal and the words';
    v_cases := v_cases + 1;
    case_name := 'the refusal is registered with its next action, and the third answer and its hint are words in English and German';
    passed := v_state is null
          and exists (select 1 from erp_ref.refusal f
                       where f.code = 'CLOVEERP_WITH_CHANGES_NEEDS_A_LINE' and coalesce(f.next_action, '') <> '')
          and (select count(*) from erp_ref.resource x
                where x.key in (erp_ref.ui_key('They will send it, with changes'),
                                erp_ref.ui_key('Needed when they will send it with changes.'))
                  and x.locale in ('en', 'de')) = 4;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. With changes and none given ──────────────────────────────────────
    v_step := 'with changes, and no line or an unchanged one';
    begin
      perform public.erp_record_supplier_confirmation(v_po, '{"decision": "confirm", "with_changes": true}');
      v_err := 'recorded';
    exception when others then v_err := sqlerrm; end;
    begin
      perform public.erp_record_supplier_confirmation(v_po, jsonb_build_object('decision', 'confirm', 'with_changes', true,
                'lines', jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 10))));
      v_err2 := 'recorded';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an answer said to come with changes, with no line or only a line as ordered, is refused by name and the order still awaits';
    passed := v_state is null
          and v_err like 'CLOVEERP_WITH_CHANGES_NEEDS_A_LINE:%'
          and v_err2 like 'CLOVEERP_WITH_CHANGES_NEEDS_A_LINE:%'
          and (select c.status from erp.purchase_order_confirmation c where c.order_id = v_po) = 'awaiting'
          and (select l.confirmed_quantity from erp.document_line l where l.id = v_l1) is null;
    detail := coalesce(v_state, left(format('%s | %s', v_err, v_err2), 500));
    return next;

    -- ── 3. With changes and a changed line ──────────────────────────────────
    v_step := 'with changes: eight coats';
    v_conf := public.erp_record_supplier_confirmation(v_po, jsonb_build_object('decision', 'confirm', 'with_changes', true,
                'supplier_reference', 'SO-88',
                'lines', jsonb_build_array(jsonb_build_object('line_id', v_l1, 'quantity', 8))));
    v_cases := v_cases + 1;
    case_name := 'with changes and a changed line, the answer is a proposal for the buyer, ten ordered and eight they can send, and the order is not yet changed';
    passed := v_state is null
          and v_conf ->> 'status' = 'changes_proposed'
          and v_conf ->> 'responded_via' = 'buyer'
          and jsonb_array_length(v_conf -> 'proposal') = 1
          and (v_conf -> 'proposal' -> 0 ->> 'ordered_quantity')::numeric = 10
          and (v_conf -> 'proposal' -> 0 ->> 'quantity')::numeric = 8
          and (select l.quantity from erp.document_line l where l.id = v_l1) = 10;
    detail := coalesce(v_state, left(coalesce(v_conf::text, 'nothing'), 500));
    return next;

    -- ── 4. Accepted, what was ordered is still answered ─────────────────────
    v_step := 'the changes accepted, read as the order''s page reads them';
    perform public.erp_decide_supplier_changes(v_po, true, null);
    v_read := public.erp_purchase_order_confirmation(v_po);
    v_cases := v_cases + 1;
    case_name := 'accepted, the line reads eight and the answer still carries the proposal with the ten that was ordered, for the page to keep showing';
    passed := v_state is null
          and v_read ->> 'status' = 'confirmed'
          and (v_read -> 'lines' -> 0 ->> 'quantity')::numeric = 8
          and (v_read -> 'lines' -> 0 ->> 'confirmed_quantity')::numeric = 8
          and jsonb_array_length(v_read -> 'proposal') = 1
          and (v_read -> 'proposal' -> 0 ->> 'ordered_quantity')::numeric = 10
          and (v_read -> 'proposal' -> 0 ->> 'quantity')::numeric = 8;
    detail := coalesce(v_state, left(coalesce(v_read::text, 'nothing'), 600));
    return next;

    -- ── 5. An answer that does not say so is taken as before ────────────────
    v_step := 'they will send it, saying nothing of changes';
    v_conf := public.erp_record_supplier_confirmation(v_po2, '{"decision": "confirm"}');
    v_cases := v_cases + 1;
    case_name := 'an answer that does not say it comes with changes, and changes no line, confirms the order as ordered with nothing proposed, as before';
    passed := v_state is null
          and v_conf ->> 'status' = 'confirmed'
          and jsonb_array_length(v_conf -> 'proposal') = 0
          and (v_conf -> 'lines' -> 0 ->> 'confirmed_quantity')::numeric = 10;
    detail := coalesce(v_state, left(coalesce(v_conf::text, 'nothing'), 500));
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
    raise exception 'CLOVEERP_ANSWER_WITH_CHANGES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'zzswc-' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_ANSWER_WITH_CHANGES_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.supplier_answer_with_changes_suite() from public, anon;

comment on function erp_test.supplier_answer_with_changes_suite() is
  'A supplier''s answer can bring changes (20261007020000, J-62): the refusal and the words are registered; an '
  'answer said to come with changes and changing no line is refused by name; with a changed line it is a proposal; '
  'once accepted the order''s answer still carries what was ordered before it; and an answer that does not say so '
  'is taken as before.';

create or replace function erp_test.assert_supplier_answer_with_changes_suite()
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
    from erp_test.supplier_answer_with_changes_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ANSWER_WITH_CHANGES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An answer with changes is taken as the order as it stands, or an accepted proposal is lost. Read the case that failed.';
  end if;
  if v_total <> 5 then
    raise exception 'CLOVEERP_ANSWER_WITH_CHANGES_SUITE_SHRANK: % case(s), expected 5', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a supplier''s answer can bring changes: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_supplier_answer_with_changes_suite() from public, anon;

comment on function erp_test.assert_supplier_answer_with_changes_suite() is
  'An answer said to come with changes must change a line, and an accepted proposal keeps what was ordered '
  '(20261007020000).';

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
