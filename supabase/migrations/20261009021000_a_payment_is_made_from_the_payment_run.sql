set lock_timeout = '30s';

-- =============================================================================
-- 20261009021000  A payment is made from the Payment run
-- -----------------------------------------------------------------------------
-- Found building the one payment run step, 5 October (J-176). The Finance
-- screen's strip used to draw a payment run three times, on Payment run,
-- Approve and Pay. Since 20261007190000 it is one step, Payment run, which
-- proposes, approves, pays and withdraws a run, and the strip is Invoice, Cash
-- in, Payment run, Journals and Close. But what the database tells a person to
-- do next still sends them to the step that went: five registered next
-- actions and eight refusal hints say "from Pay", in
--   erp.transition_document, erp.create_document_full, erp.post_cash_document,
--   erp.require_lines_open, erp.protect_posted_cash_document,
--   erp.render_remittance_advice, erp.withdraw_payment_run and
--   public.erp_create_document.
-- A person refused there is told to open a step the screen no longer has.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The eight hints name the Payment run step: "from Pay" becomes "from
--      Payment run", and nothing else in those bodies moves. Each is an
--      anchored edit of the body in force, guarded by its md5.
--   B. The five refusals are registered again with the same words, but for
--      their next action, which names Payment run:
--        CLOVEERP_CASH_DOCUMENT_IS_RAISED, CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH,
--        CLOVEERP_CASH_DOCUMENT_NOT_APPLIED, CLOVEERP_NOT_A_CASH_PAYMENT and
--        CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE.
--      erp.register_refusal rewrites their screen strings too; no key is added.
--   C. erp_test.cash_documents_screens_suite, which pins the money strip,
--      gains a ninth case: no registered refusal, screen string, help topic
--      or routine names Approve or Pay as a step to go to. Its case naming
--      the Pay step names paying a run on the Payment run step.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- Every refusal is raised where and when it was, with the same code and
-- errcode; no door, permission or step is added or removed.
--
-- On production: eight functions are replaced with one sentence changed in
-- each, five rows of erp_ref.refusal and their fifteen strings in
-- erp_ref.resource are rewritten (the five next actions with new words), and a test
-- function and its assertion are replaced. No table is altered and no row of
-- any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The hints name the Payment run step
-- ─────────────────────────────────────────────────────────────────────────────

do $hints$
declare
  c_mark constant text := '-- The money strip''s step is Payment run (20261009021000).';
  r      record;
  v_src  text;
  v_def  text;
  v_old  text;
  v_new  text;
begin
  for r in
    select * from (values
      ('erp.transition_document(uuid,text,text)', 'fd9aa1f11130be1cb819e875e5d94c98', 12,
       $h$Pay an approved run from Pay. Its payments are posted with it.$h$,
       $h$Pay an approved run from Payment run. Its payments are posted with it.$h$),
      ('erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)', '66aa19ab8f7be3353844dfb84479a2a7', 12,
       $h$Pay an approved run from Pay. Its payments are opened and posted with it.$h$,
       $h$Pay an approved run from Payment run. Its payments are opened and posted with it.$h$),
      ('erp.post_cash_document(uuid)', 'c9c5bada663001a73a4549e631a4be8d', 14,
       $h$Pay an approved run from Pay. Its payments are posted with it.$h$,
       $h$Pay an approved run from Payment run. Its payments are posted with it.$h$),
      ('erp.require_lines_open(uuid)', '19f2c42f2aa4d5c8fa5123caa40ca0b6', 12,
       $h$Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.$h$,
       $h$Pay the further bills from Payment run, or correct a misapplied payment with a journal on the Journals screen.$h$),
      ('erp.protect_posted_cash_document()', 'dd85313fa789101ab889c7b24957dfbf', 14,
       $h$Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.$h$,
       $h$Pay the further bills from Payment run, or correct a misapplied payment with a journal on the Journals screen.$h$),
      ('erp.render_remittance_advice(uuid,text)', 'bd8922791aaa9136dd6a648a6b747140', 12,
       $h$Open the payment the run made from Pay, and print its remittance advice from there.$h$,
       $h$Open the payment the run made from Payment run, and print its remittance advice from there.$h$),
      ('erp.withdraw_payment_run(uuid,text)', '5c50b2b7ace3fc1a493bbd275a96a56d', 12,
       $h$Only a run waiting for its approver can be withdrawn. Pay an approved run from Pay, and propose a new run for anything it did not pay.$h$,
       $h$Only a run waiting for its approver can be withdrawn. Pay an approved run from Payment run, and propose a new run for anything it did not pay.$h$),
      ('public.erp_create_document(text,uuid,uuid,text,date,uuid,text,uuid)', '68789509836ade75797cdc06788897b4', 12,
       $h$Pay an approved run from Pay. Its payments are opened and posted with it.$h$,
       $h$Pay an approved run from Payment run. Its payments are opened and posted with it.$h$)
    ) as t(sig, body_md5, indent, old_hint, new_hint)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261009021000') > 0 then
      raise notice '% already names Payment run; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.body_md5 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009021000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    v_old := repeat(' ', r.indent) || 'hint = ''' || r.old_hint || ''';';
    v_new := repeat(' ', r.indent) || c_mark || E'\n'
          || repeat(' ', r.indent) || 'hint = ''' || r.new_hint || ''';';
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$hints$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The registered next actions name the Payment run step
-- ─────────────────────────────────────────────────────────────────────────────

do $refusals$
declare
  r      record;
  v_row  record;
begin
  for r in
    select * from (values
      ('CLOVEERP_CASH_DOCUMENT_IS_RAISED',
       $a$Apply the cash from Cash in, or pay an approved run from Pay. Its document is opened and posted with it.$a$,
       $a$Apply the cash from Cash in, or pay an approved run from Payment run. Its document is opened and posted with it.$a$),
      ('CLOVEERP_CASH_DOCUMENT_LINES_ARE_ITS_CASH',
       $a$Apply the further cash from Cash in or pay the further bills from Pay, or correct a misapplied one with a journal on the Journals screen.$a$,
       $a$Apply the further cash from Cash in or pay the further bills from Payment run, or correct a misapplied one with a journal on the Journals screen.$a$),
      ('CLOVEERP_CASH_DOCUMENT_NOT_APPLIED',
       $a$Apply the cash from Cash in, or pay an approved run from Pay. Its document is posted with it.$a$,
       $a$Apply the cash from Cash in, or pay an approved run from Payment run. Its document is posted with it.$a$),
      ('CLOVEERP_NOT_A_CASH_PAYMENT',
       $a$Open the payment the run made from Pay, and print its remittance advice from there.$a$,
       $a$Open the payment the run made from Payment run, and print its remittance advice from there.$a$),
      ('CLOVEERP_PAYMENT_RUN_NOT_WITHDRAWABLE',
       $a$Only a run waiting for its approver can be withdrawn. Pay an approved run from Pay, and propose a new run for anything it did not pay.$a$,
       $a$Only a run waiting for its approver can be withdrawn. Pay an approved run from Payment run, and propose a new run for anything it did not pay.$a$)
    ) as t(code, old_next, new_next)
  loop
    select f.refused, f.why, f.next_action into v_row from erp_ref.refusal f where f.code = r.code;
    if not found then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not registered; 20261009021000 rewords its next action', r.code;
    end if;
    if v_row.next_action = r.new_next then
      raise notice '% already names Payment run; left as it is', r.code;
      continue;
    end if;
    if v_row.next_action <> r.old_next then
      raise exception 'CLOVEERP_ANCHOR_MOVED: %''s next action is not the one 20261009021000 expects: %', r.code, v_row.next_action;
    end if;
    perform erp.register_refusal(r.code, v_row.refused, v_row.why, r.new_next);
  end loop;
end
$refusals$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The suite that pins the money strip says no step that went is named
-- ─────────────────────────────────────────────────────────────────────────────

do $cash_screens$
declare
  v_sig  constant text := 'erp_test.cash_documents_screens_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  c_expected constant integer := 8;
$o$;
  v_new1 constant text := $n$  c_expected constant integer := 9;
  -- A step the money strip no longer has, named as somewhere to go: the strip
  -- is Invoice, Cash in, Payment run, Journals and Close (src/lib/modules.tsx,
  -- pinned by src/lib/stage-records.test.ts), and Approve and Pay were folded
  -- into Payment run by 20261007190000 (20261009021000).
  c_retired  constant text := '\mfrom (the )?(Pay|Approve)\M|\m(on|at|from) the (Pay|Approve) step\M';
$n$;
  v_old2 constant text := $o$  v_n integer;
begin
$o$;
  v_new2 constant text := $n$  v_n integer;
  v_stale text;
begin
$n$;
  v_old3 constant text := $o$    case_name := 'the Pay step''s answer lists a payment per supplier, each with the number, supplier and total its page reads, Posted, with no move to offer';
$o$;
  v_new3 constant text := $n$    case_name := 'paying a run on the Payment run step answers with a payment per supplier, each with the number, supplier and total its page reads, Posted, with no move to offer';
$n$;
  v_old4 constant text := $o$  detail := coalesce(v_state, 'zzcds rolled back with its receipts, payments and journals');
  return next;
$o$;
  v_new4 constant text := $n$  detail := coalesce(v_state, 'zzcds rolled back with its receipts, payments and journals');
  return next;

  v_cases := v_cases + 1;
  case_name := 'no registered refusal, screen string, help topic or routine sends a person to a money step the strip no longer has';
  select string_agg(x.what, '; ' order by x.what) into v_stale from (
    select 'refusal ' || f.code as what from erp_ref.refusal f
     where concat_ws(' ', f.refused, f.why, f.next_action) ~ c_retired
    union all
    select 'string ' || s.key from erp_ref.resource s
     where s.locale = 'en' and s.value ~ c_retired
    union all
    select 'help ' || h.screen_path from erp_ref.help_topic h
     where concat_ws(' ', h.summary, h.steps::text, h.next_action) ~ c_retired
    union all
    select 'routine ' || p.oid::regprocedure::text from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_meta', 'public') and p.prosrc ~ c_retired) x;
  passed := v_stale is null;
  detail := coalesce('still naming Approve or Pay as a step: ' || v_stale, 'every next action names Payment run');
  return next;
$n$;
begin
  if strpos(v_src, '20261009021000') > 0 then
    raise notice '% already looks for steps that went; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '52a3ad640b59567d14f5802264166d0f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009021000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1
     or (length(v_def) - length(replace(v_def, v_old4, ''))) / length(v_old4) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3), v_old4, v_new4);
end
$cash_screens$;

do $cash_screens_assert$
declare
  v_sig  constant text := 'erp_test.assert_cash_documents_screens_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 8 then
    raise exception 'CLOVEERP_CASH_DOCUMENTS_SCREENS_SUITE_SHRANK: % case(s), expected 8', v_total
$o$;
  v_new  constant text := $n$  -- Nine since no step that went may be named (20261009021000).
  if v_total <> 9 then
    raise exception 'CLOVEERP_CASH_DOCUMENTS_SCREENS_SUITE_SHRANK: % case(s), expected 9', v_total
$n$;
begin
  if strpos(v_src, '20261009021000') > 0 then
    raise notice '% already expects nine cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '25b0c6a19a480367d43b6d1d10d839e0' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009021000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$cash_screens_assert$;

revoke all on function erp_test.cash_documents_screens_suite() from public, anon;
revoke all on function erp_test.assert_cash_documents_screens_suite() from public, anon;

comment on function erp_test.cash_documents_screens_suite() is
  'What the cash documents'' screens read (20260930300000). Apply cash''s rows name the receipt it made, which the '
  'Cash in step lists and whose page reads its number, customer and Posted; paying a run names each supplier''s '
  'payment; a cash document offers no move, and New, Add line and Post are refused by name; the remittance advice '
  'renders for whoever may pay and is refused, and not offered, to somebody who may only read; the strip''s budget '
  'and the door register follow. The strip is five steps since a payment run is proposed, approved and paid on one '
  '(20261007190000), and ten actions since a run is withdrawn there too (20261007192000); nothing registered sends '
  'a person to the Approve or Pay step that went (20261009021000).';

comment on function erp_test.assert_cash_documents_screens_suite() is
  'The Cash in step lists the receipts Apply cash names, paying a run on the Payment run step names its payments, '
  'and a payment''s page prints its remittance advice for whoever may pay (20260930300000); nothing registered '
  'sends a person to a step the strip no longer has, and the suite keeps its nine cases (20261009021000).';

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
