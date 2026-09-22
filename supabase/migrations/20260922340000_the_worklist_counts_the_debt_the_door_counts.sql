set lock_timeout = '30s';

-- =============================================================================
-- 20260922340000  The worklist counts the debt the door counts
-- -----------------------------------------------------------------------------
-- A review of PR3 after it was green found that the ladder and the door still
-- disagreed about real customers, after 20260922260000 had made them agree
-- about day counts. Reproduced on the demonstration's own ledger: a customer
-- who had PAID an invoice two hundred days old and owed a small one ten days
-- late was put on the stop level by erp.dunning_worklist() — "account stopped
-- and passed to collection", blocks_trading true — while erp.credit_position()
-- said the same customer was within terms.
--
-- The ladder arithmetic was right. What was wrong is that the two were not
-- measuring the same debt:
--
--   erp.credit_position(), which erp.create_document() and
--   erp.check_release_to_fulfilment() read, counts an item overdue only while
--   something is still owing on it (debit less credit less settled) and ages it
--   by its due date;
--
--   erp.dunning_worklist() took the oldest date of EVERY receivable item past
--   its date — settled invoices and cash receipts included — and aged it by
--   coalesce(due_date, posting_date).
--
-- On the seeded demonstration every row the worklist returned was overstated,
-- by thirty to forty-five days. So the chasing screen was writing to customers
-- about invoices they had paid, which is a defect in its own right and older
-- than PR3 — PR3 made it matter by claiming the ladder and the door agree.
--
-- The worklist now counts what the door counts: items still owing, with a due
-- date, aged by it, and the amount it reports is what is still owing on them.
-- The door is unchanged; it is the reference.
--
-- erp_test.dunning_ladder_suite()'s case 4 proved the agreement over an
-- abstract day count and built no ledger, so it could not see this. The new
-- case builds one, both ways round: a customer whose only old debt is paid is
-- neither stopped by the ladder nor held by the door; a customer whose old debt
-- is still owed is both.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The worklist reads the debt that is still owed
-- ═════════════════════════════════════════════════════════════════════════════

do $worklist$
declare
  v_sig constant text := 'erp.dunning_worklist(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  overdue as (\n'
    || E'    select si.party_id,\n'
    || E'           max(current_date - coalesce(si.due_date, si.posting_date))::integer as days,\n'
    || E'           sum(si.debit_minor - si.credit_minor)::bigint as amt\n'
    || E'      from erp.subledger_item si\n'
    || E'     where si.tenant_id = erp.current_tenant_id()\n'
    || E'       and si.control_kind = ''receivable''\n'
    || E'       and coalesce(si.due_date, si.posting_date) < current_date\n'
    || E'     group by si.party_id\n'
    || E'    having sum(si.debit_minor - si.credit_minor) > 0\n'
    || E'  )\n';
  v_new constant text :=
       E'  overdue as (\n'
    || E'    -- The debt the door counts (20260922340000): an item still owing, with a\n'
    || E'    -- due date, aged by it — what erp.credit_position() reads. This used to\n'
    || E'    -- take the oldest date of every receivable item past its date, settled\n'
    || E'    -- invoices and receipts included, so it chased customers for invoices they\n'
    || E'    -- had paid and called them stopped while the door let them trade.\n'
    || E'    select si.party_id,\n'
    || E'           max(current_date - si.due_date)::integer as days,\n'
    || E'           sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0))::bigint as amt\n'
    || E'      from erp.subledger_item si\n'
    || E'     where si.tenant_id = erp.current_tenant_id()\n'
    || E'       and si.control_kind = ''receivable''\n'
    || E'       and si.due_date is not null\n'
    || E'       and si.due_date < current_date\n'
    || E'       and si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0) > 0\n'
    || E'     group by si.party_id\n'
    || E'  )\n';
  v_hits integer;
begin
  if position('20260922340000' in v_def) > 0 then
    raise exception 'CLOVEERP_WORKLIST_UNRECOGNISED: % already counts the debt the door counts', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_WORKLIST_UNRECOGNISED: % measures overdue debt % time(s) in the shape this replaces, not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$worklist$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And the suite builds a ledger
-- ═════════════════════════════════════════════════════════════════════════════

do $suite$
declare
  v_sig constant text := 'erp_test.dunning_ladder_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_dec constant text := E'  v_fixture text;\n';
  v_new_dec constant text :=
       E'  v_fixture text;\n'
    || E'  -- A ledger to compare the two against (20260922340000).\n'
    || E'  v_ledger uuid; v_entity uuid; v_ccy char(3); v_ar uuid;\n'
    || E'  v_paid uuid; v_paid_role uuid; v_owes uuid; v_owes_role uuid;\n'
    || E'  w_paid record; w_owes record; c_paid record; c_owes record;\n';
  v_old_case constant text := E'\n  raise exception ''CLOVEERP_SUITE_UNDO'';\n';
  v_new_case constant text :=
       E'\n'
    || E'  -- ── On a real ledger the worklist and the door agree (20260922340000) ──\n'
    || E'  -- Case 4 proved it over an abstract day count, which is how it missed\n'
    || E'  -- the worklist ageing PAID invoices. Two customers on the window of 180\n'
    || E'  -- case 6 left: one paid an invoice two hundred days old and owes a small\n'
    || E'  -- one ten days late; the other still owes the old one.\n'
    || E'  select l.id, l.entity_id, l.currency into v_ledger, v_entity, v_ccy\n'
    || E'    from erp.ledger l where l.tenant_id = r.tenant_id and l.is_primary order by l.code limit 1;\n'
    || E'  select a.id into v_ar from erp.account a\n'
    || E'   where a.tenant_id = r.tenant_id and a.control_kind = ''receivable'' order by a.code limit 1;\n'
    || E'  insert into erp.party (tenant_id, code, name, status)\n'
    || E'  values (r.tenant_id, ''C-PAID'', ''Paid its old invoice'', ''active'') returning id into v_paid;\n'
    || E'  insert into erp.party_role (tenant_id, party_id, role_kind, status)\n'
    || E'  values (r.tenant_id, v_paid, ''customer'', ''active'') returning id into v_paid_role;\n'
    || E'  insert into erp.party (tenant_id, code, name, status)\n'
    || E'  values (r.tenant_id, ''C-OWES'', ''Still owes its old invoice'', ''active'') returning id into v_owes;\n'
    || E'  insert into erp.party_role (tenant_id, party_id, role_kind, status)\n'
    || E'  values (r.tenant_id, v_owes, ''customer'', ''active'') returning id into v_owes_role;\n'
    || E'  insert into erp.party_role_terms (tenant_id, party_role_id, entity_id, currency, payment_terms_code,\n'
    || E'                                    payment_days, credit_limit_minor, credit_status, is_blocked, valid_from)\n'
    || E'  values (r.tenant_id, v_paid_role, v_entity, v_ccy, ''NET30'', 30, 500000000, ''ok'', false, current_date - 400),\n'
    || E'         (r.tenant_id, v_owes_role, v_entity, v_ccy, ''NET30'', 30, 500000000, ''ok'', false, current_date - 400);\n'
    || E'  insert into erp.subledger_item (tenant_id, entity_id, ledger_id, control_kind, control_account_id,\n'
    || E'                                  party_id, currency, debit_minor, credit_minor, due_date, settled_minor, posting_date)\n'
    || E'  values (r.tenant_id, v_entity, v_ledger, ''receivable'', v_ar, v_paid, v_ccy, 1000, 0, current_date - 200, 1000, current_date - 230),\n'
    || E'         (r.tenant_id, v_entity, v_ledger, ''receivable'', v_ar, v_paid, v_ccy, 0, 1000, null, 0, current_date - 195),\n'
    || E'         (r.tenant_id, v_entity, v_ledger, ''receivable'', v_ar, v_paid, v_ccy, 500, 0, current_date - 10, 0, current_date - 40),\n'
    || E'         (r.tenant_id, v_entity, v_ledger, ''receivable'', v_ar, v_owes, v_ccy, 1000, 0, current_date - 200, 0, current_date - 230);\n'
    || E'  select * into w_paid from erp.dunning_worklist() w where w.party_id = v_paid;\n'
    || E'  select * into w_owes from erp.dunning_worklist() w where w.party_id = v_owes;\n'
    || E'  select * into c_paid from erp.credit_position(v_paid);\n'
    || E'  select * into c_owes from erp.credit_position(v_owes);\n'
    || E'\n'
    || E'  v_cases := v_cases + 1;\n'
    || E'  case_name := ''on a real ledger the worklist and the door agree: a paid invoice stops nobody, an unpaid one stops them in both'';\n'
    || E'  passed := w_paid.oldest_days = 10 and not w_paid.blocks_trading and not coalesce(c_paid.on_hold, false)\n'
    || E'        and w_owes.oldest_days = 200 and w_owes.blocks_trading and coalesce(c_owes.on_hold, false)\n'
    || E'        and w_paid.overdue_minor = 500 and w_owes.overdue_minor = 1000;\n'
    || E'  detail := format(''paid: %s days, %s, blocks %s, door holds %s; owes: %s days, %s, blocks %s, door holds %s'',\n'
    || E'                   w_paid.oldest_days, w_paid.level_code, w_paid.blocks_trading, coalesce(c_paid.on_hold, false),\n'
    || E'                   w_owes.oldest_days, w_owes.level_code, w_owes.blocks_trading, coalesce(c_owes.on_hold, false));\n'
    || E'  return next;\n'
    || E'\n'
    || E'  raise exception ''CLOVEERP_SUITE_UNDO'';\n';
  v_old_pin constant text :=
       E'  if v_cases <> 7 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: dunning_ladder_suite ran % cases, expected 7 — %'',\n';
  v_new_pin constant text :=
       E'  if v_cases <> 8 then\n'
    || E'    raise exception ''CLOVEERP_SUITE_SHRANK: dunning_ladder_suite ran % cases, expected 8 — %'',\n';
  v_hits integer;
begin
  if position('20260922340000' in v_def) > 0 then
    raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % already builds a ledger', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_dec, ''))) / length(v_old_dec);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % declares v_fixture % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_case, ''))) / length(v_old_case);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % raises its undo % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_pin, ''))) / length(v_old_pin);
  if v_hits <> 1 then raise exception 'CLOVEERP_SUITE_UNRECOGNISED: % pins seven cases % time(s)', v_sig, v_hits; end if;
  execute replace(replace(replace(v_def, v_old_dec, v_new_dec), v_old_case, v_new_case), v_old_pin, v_new_pin);
end
$suite$;

do $pin$
declare
  v_sig constant text := 'erp_test.assert_dunning_ladder_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  if v_total <> 7 then\n'
    || E'    raise exception ''CLOVEERP_DUNNING_LADDER_SUITE_SHRANK: % case(s), expected 7'', v_total\n';
  v_new constant text :=
       E'  if v_total <> 8 then\n'
    || E'    raise exception ''CLOVEERP_DUNNING_LADDER_SUITE_SHRANK: % case(s), expected 8'', v_total\n';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_WRAPPER_UNRECOGNISED: % pins seven cases % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body. If the count has moved since, re-anchor on what it is now.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$pin$;

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
