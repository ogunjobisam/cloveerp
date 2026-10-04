set lock_timeout = '30s';

-- =============================================================================
-- 20261005800000  A cancelled receipt gives its quantities back
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October. An order of fifteen
-- units had two received on a posted receipt. A second receipt was raised for
-- the other thirteen and cancelled while still a draft. From then on:
--
--   "Nothing is left to receive on this order: every line has been received
--    or is on a goods receipt already."
--
-- and the order's lines read fully received, 6 of 6, 4 of 4 and 5 of 5, with
-- two units in the warehouse. "Received, not yet billed" carried the
-- cancelled receipt's value from then on, ahead of the ledger, which the
-- close's check (erp.assert_grni_reconciles) reads against it.
--
-- ── WHAT IT IS ───────────────────────────────────────────────────────────────
--
-- erp.refresh_order_line_progress() writes an order line's quantity_fulfilled
-- from every receipt raised against it whose is_cancelled flag is unset. A
-- receipt cancelled by its lifecycle moves to the state cancelled and the
-- flag stays as it was, so it went on counting; and nothing refreshed the
-- order's lines when a receipt was cancelled in any case.
--
-- erp.receivable_lines() and erp.receive_against() already read both, flag
-- and state (20260923100000). This brings the third reader into line.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- A draft receipt still counts towards quantity_fulfilled, as it has since
-- B7: three-way matching reads it there, and erp_test.procurement_controls_suite
-- holds that. (A first version of this change counted posted receipts only,
-- and that suite refused it.) So a draft receipt that is neither posted nor
-- cancelled still puts the received-not-billed report ahead of the ledger
-- until it is one or the other. That is a decision for the owner, and is
-- written up as open.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.refresh_order_line_progress(): a receipt in the state cancelled
--      counts nothing.
--   B. A receipt that moves to cancelled refreshes the order lines it was
--      raised against (a trigger on erp.object_state, beside the ones that
--      number and tax a document as its state moves).
--   C. Every order line a cancelled receipt was raised against is read again
--      here, in every organisation, and the migration says how many changed.
--
-- Proof: erp_test.cancelled_receipt_suite.
-- =============================================================================

do $progress$
declare
  v_sig  constant text := 'erp.refresh_order_line_progress(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled), 0)$o$;
  v_new  constant text := $n$              and rdt.base_type_code = 'receipt'
              and not rd.is_cancelled
              -- Nor one its lifecycle cancelled, whose flag stays as it was
              -- (20261005800000), as erp.receivable_lines() already reads.
              and not exists (select 1
                                from erp.object_state ros
                                join erp.state rs on rs.id = ros.current_state_id
                               where ros.tenant_id = rd.tenant_id
                                 and ros.object_type = 'document'
                                 and ros.object_id = rd.id
                                 and rs.code = 'cancelled')), 0)$n$;
begin
  if strpos(v_src, '20261005800000') > 0 then
    raise notice '% already leaves out a cancelled receipt; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8d0a8a22ac4ffae553838d0b5282af44' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005800000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$progress$;

create or replace function erp.cancelled_receipt_gives_back()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  -- A receipt that moves to cancelled: the order lines it was raised against
  -- are read again, so what it held is open to receive (20261005800000).
  if new.object_type = 'document'
     and new.current_state_id is distinct from old.current_state_id
     and exists (select 1 from erp.state s where s.id = new.current_state_id and s.code = 'cancelled')
     and exists (select 1
                   from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = new.tenant_id and d.id = new.object_id
                    and dt.base_type_code = 'receipt') then
    for r in
      select distinct rel.to_line_id
        from erp.document_relation rel
       where rel.tenant_id = new.tenant_id
         and rel.from_document_id = new.object_id
         and rel.to_line_id is not null
    loop
      perform erp.refresh_order_line_progress(r.to_line_id);
    end loop;
  end if;
  return new;
end;
$$;

revoke all on function erp.cancelled_receipt_gives_back() from public, anon;

comment on function erp.cancelled_receipt_gives_back() is
  'Trigger on erp.object_state: a goods receipt that moves to cancelled refreshes the order lines it was '
  'raised against, so its quantities are open again (20261005800000).';

drop trigger if exists t_object_state_cancelled_receipt on erp.object_state;
create trigger t_object_state_cancelled_receipt
  after update of current_state_id on erp.object_state
  for each row execute function erp.cancelled_receipt_gives_back();

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.cancelled_receipt_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid; v_po uuid; v_line uuid;
  v_g1 uuid; v_g2 uuid; v_g3 uuid;
  v_cancel text;
  v_open   numeric;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an order of ten, sent, two received and posted';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzcrc-' || v_tag, 'Cancelled Receipt Suite',
      'admin@zzcrc-' || v_tag || '.test', 'Receipt Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzcrc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZCCOAT', 'Cancelled Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZCRBRAND');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZCRO1', false);
    perform public.erp_send_purchase_order(v_po, 'orders@zcrbrand-' || v_tag || '.test', null, null, null);
    select l.id into v_line from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
    v_g1 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g1, v_line, 2, null);
    perform erp.transition_document(v_g1, 'post', null);

    -- ── 1. A draft for the rest holds it ────────────────────────────────────
    v_step := 'a draft receipt for the other eight';
    v_g2 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g2, v_line, 8, null);
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_po)) x;
    v_cases := v_cases + 1;
    case_name := 'a draft receipt for the other eight holds them: nothing more is offered to receive';
    passed := v_state is null and v_open = 0;
    detail := coalesce(v_state, format('open %s', v_open));
    return next;

    -- ── 2. Cancelled, it gives them back ────────────────────────────────────
    v_step := 'cancelling the draft receipt';
    select x ->> 'code' into v_cancel
      from jsonb_array_elements(public.erp_available_transitions(v_g2)) x
     where x ->> 'to_state' = 'cancelled' limit 1;
    perform erp.transition_document(v_g2, v_cancel, 'the lorry was turned away');
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_po)) x;
    v_cases := v_cases + 1;
    case_name := 'cancelling the draft gives its eight back: the line reads two received and eight are open to receive';
    passed := v_state is null and v_cancel is not null and v_open = 8
          and erp.object_current_state('document', v_g2) = 'cancelled'
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 2;
    detail := coalesce(v_state, format('cancelled by "%s"; open %s; fulfilled %s', coalesce(v_cancel, 'no move'), v_open,
                (select l.quantity_fulfilled from erp.document_line l where l.id = v_line)));
    return next;

    -- ── 3. The report and the ledger agree again ────────────────────────────
    v_step := 'the close''s check after the cancellation';
    v_cases := v_cases + 1;
    case_name := 'goods received not invoiced reconciles once the draft is cancelled';
    begin
      detail := erp.assert_grni_reconciles();
      passed := v_state is null and detail like 'grni:%reconciles%';
    exception when others then
      detail := left(sqlerrm, 300);
      passed := false;
    end;
    detail := coalesce(v_state, left(detail, 300));
    return next;

    -- ── 4. And the rest arrives ─────────────────────────────────────────────
    v_step := 'receiving the eight on a third receipt';
    v_g3 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g3, v_line, 8, null);
    perform erp.transition_document(v_g3, 'post', null);
    v_cases := v_cases + 1;
    case_name := 'the eight are then received on another receipt, and the order reads received in full';
    passed := v_state is null
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_line) = 10
          and erp.object_current_state('document', v_po) in ('received', 'closed');
    detail := coalesce(v_state, erp.object_current_state('document', v_po));
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
    raise exception 'CLOVEERP_CANCELLED_RECEIPT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.cancelled_receipt_suite() from public, anon;

comment on function erp_test.cancelled_receipt_suite() is
  'A cancelled receipt gives its quantities back (20261005800000): a draft holds, cancelling it reopens the '
  'order line, the received-not-billed report reconciles again, and the goods are then received.';

create or replace function erp_test.assert_cancelled_receipt_suite()
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
    from erp_test.cancelled_receipt_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CANCELLED_RECEIPT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A cancelled receipt would go on reading as goods received. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_CANCELLED_RECEIPT_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('cancelled receipt: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_cancelled_receipt_suite() from public, anon;

comment on function erp_test.assert_cancelled_receipt_suite() is
  'A goods receipt cancelled by its lifecycle stops counting as received and reopens its order lines (20261005800000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Every line a cancelled receipt was raised against, read again
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r       record;
  l       record;
  v_n     integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := 0;
    for l in
      select distinct rel.to_line_id as id,
             (select x.quantity_fulfilled from erp.document_line x where x.id = rel.to_line_id) as was
        from erp.document_relation rel
        join erp.document rd on rd.tenant_id = rel.tenant_id and rd.id = rel.from_document_id
        join erp.document_type rdt on rdt.tenant_id = rd.tenant_id and rdt.id = rd.document_type_id
        join erp.object_state ros
          on ros.tenant_id = rd.tenant_id and ros.object_type = 'document' and ros.object_id = rd.id
        join erp.state rs on rs.id = ros.current_state_id
       where rel.tenant_id = r.id
         and rel.to_line_id is not null
         and rdt.base_type_code = 'receipt'
         and rs.code = 'cancelled'
    loop
      perform erp.refresh_order_line_progress(l.id);
      if (select x.quantity_fulfilled from erp.document_line x where x.id = l.id) is distinct from l.was then
        v_n := v_n + 1;
      end if;
    end loop;
    -- The checks the updates left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the table.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'cancelled receipts: % order line(s) of % read again', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
