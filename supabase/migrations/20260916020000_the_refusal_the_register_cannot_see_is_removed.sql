-- The refusal the register cannot see is removed where it landed.
--
-- 20260916010000 was edited after it was pushed, which a migration may not be
-- (supabase/ci/migrations_immutable.sh). The edit took out a call to
-- erp.register_refusal for CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION and
-- reworded one case of erp_test.posting_rules_raise_lines_suite() to match.
--
-- The reason it came out: erp.refusal_report() reads the source of every
-- routine that is not an assertion or a suite, and proves that each registered
-- refusal is actually raised by one of them — a registered code nothing raises
-- is a stale row on the terminology screen, offered for renaming and never
-- shown. That token is raised only inside erp.assert_posting_rule_balances(),
-- and it can only ever be met by a check that asked the wrong organisation, so
-- it belongs on the raise with its next action rather than in the register the
-- screens read.
--
-- A build from an empty database sees only the edited file and is right. An
-- environment that had already applied the first version holds the register
-- row, its three resource keys, and the earlier wording of the suite. This is
-- the repair for that environment, and a no-op everywhere else: the row and
-- the keys are removed if they are there, and the suite is re-applied as it
-- now stands. Registered as the repair in supabase/ci/migrations_edited.txt.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The row and its keys, where they landed
-- ═════════════════════════════════════════════════════════════════════════════

delete from erp_ref.resource r
 where r.key in (erp_ref.refusal_key('CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION', 'refused'),
                 erp_ref.refusal_key('CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION', 'why'),
                 erp_ref.refusal_key('CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION', 'next_action'));

delete from erp_ref.refusal f
 where f.code = 'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite, as it now stands
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.posting_rules_raise_lines_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  ra        record;
  a1        uuid := gen_random_uuid();
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_acode   text;
  v_bcode   text;
  v_a       uuid;
  v_b       uuid;
  v_cs      uuid;
  v_words   boolean;
  v_promote text;
  v_direct  text;
  v_empty   text;
  v_rules   integer;
  v_thin    integer;
  v_unbal   integer;
  v_estate  text;
  v_report  integer;
  v_recon   text;
begin
  v_acode := 'zzprl-a-' || v_hex;
  v_bcode := 'zzprl-b-' || v_hex;

  -- Every falsification below is undone by the exception that ends the block,
  -- whichever way the run goes: a suite that leaves an organisation behind on
  -- the live database is a suite nobody may run there.
  begin
    select count(*) = 1 into v_words
      from erp_ref.refusal f
     where f.code = 'CLOVEERP_POSTING_RULE_EMPTY'
       and not erp_test.sounds_internal(f.refused)
       and not erp_test.sounds_internal(f.why)
       and not erp_test.sounds_internal(f.next_action);
    v_words := coalesce(v_words, false)
               and not exists (select 1 from erp.refusal_report() r
                                where r.token = 'CLOVEERP_POSTING_RULE_EMPTY'
                                  and r.finding is not null);

    select * into ra from erp.provision_tenant(
      v_acode, 'Posting rules raise lines', 'admin@' || v_acode || '.test', 'Suite Admin');
    v_a := ra.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);

    -- The books, installed the way the product installs them.
    perform erp_test.reopen_bootstrap_window(v_a);
    perform erp.configure_finance();

    select count(*),
           count(*) filter (where erp.posting_rule_raises_nothing(pr.posting_lines)),
           count(*) filter (where erp.posting_rule_imbalance(pr.posting_lines) <> 0)
      into v_rules, v_thin, v_unbal
      from erp.posting_rule pr
     where pr.tenant_id = v_a and pr.status = 'active';

    -- A change set that names a rule and no lines. Promotion refused this
    -- before today; the table refuses it now, so the refusal arrives whichever
    -- of the two is reached first.
    begin
      v_cs := erp.create_change_set('zzprl-nolines-' || v_hex, 'A rule that raises nothing',
                                    'Proof that a rule in force cannot list nothing.');
      perform erp.add_change_set_item(
        v_cs, 'posting_rule', 'zzprlnothing',
        jsonb_build_object('code', 'zzprlnothing', 'name', 'Raises nothing',
                           'ledger', 'GL', 'event_type', 'stock.adjusted'));
      perform erp.submit_change_set(v_cs);
      perform erp.approve_change_set(v_cs);
      perform erp.promote_change_set(v_cs);
      v_promote := 'the rule was promoted';
    exception when others then v_promote := left(sqlerrm, 200);
    end;

    -- A direct write, which is the path promotion's assertion never sees.
    begin
      insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
      values (v_a, 'zzprldirect', 'stock.adjusted', '[]'::jsonb, 'active', current_date);
      v_direct := 'the rule was written';
    exception when others then v_direct := left(sqlerrm, 200);
    end;

    -- And emptying the one in force.
    begin
      update erp.posting_rule pr
         set posting_lines = '[]'::jsonb
       where pr.tenant_id = v_a and pr.code = 'goods_receipt' and pr.status = 'active';
      v_empty := 'the rule was emptied';
    exception when others then v_empty := left(sqlerrm, 200);
    end;

    perform erp_test.close_bootstrap_window(v_a);

    -- The estate check, and the report it promises.
    begin
      v_estate := erp.assert_every_posting_rule_raises_lines();
    exception when others then v_estate := left(sqlerrm, 300);
    end;
    select count(*) into v_report from erp.posting_rule_without_lines_report();

    -- The finding of 15 September. A second organisation holds a rule that
    -- does not balance, and the person signed in belongs to the first. Before
    -- today the reconciliation looked the rule up in the signed-in person's
    -- organisation, found nothing, and said it raised no lines.
    -- Built with nobody signed in, so the guards that read the session see
    -- what they see when a suite builds an organisation from nothing; then the
    -- person comes back, because the person is the whole point of the case.
    perform set_config('request.jwt.claims', '', true);
    insert into erp.tenant (code, name)
    values (v_bcode, 'Another organisation entirely') returning id into v_b;
    insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
    values (v_b, 'zzprlunbalanced', 'stock.adjusted',
            '[{"side":"debit","account":"1200","basis":"document_value","rate":1}]'::jsonb,
            'active', date '2020-01-01');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    begin
      v_recon := erp.assert_whole_database_reconciles();
    exception when others then v_recon := sqlerrm;
    end;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_recon := coalesce(v_recon, 'the suite stopped: ' || left(sqlerrm, 200));
    end if;
  end;

  case_name := 'the refusal this holds is registered, raised somewhere, and in the words of the people it refuses';
  passed := coalesce(v_words, false);
  detail := 'a rule in force that raises nothing';
  return next;

  case_name := 'a list that is absent, empty or not a list is what raising nothing means';
  passed := coalesce(erp.posting_rule_raises_nothing(null::jsonb)
                     and erp.posting_rule_raises_nothing('[]'::jsonb)
                     and erp.posting_rule_raises_nothing('{}'::jsonb)
                     and erp.posting_rule_raises_nothing('"nothing"'::jsonb)
                     and not erp.posting_rule_raises_nothing(
                           '[{"side":"debit","account":"1200","rate":1}]'::jsonb), false);
  detail := 'one statement, read by the table guard, the estate check and the assertion promotion runs';
  return next;

  case_name := 'the finance installer puts rules in force and every one of them raises balanced lines';
  passed := coalesce(v_rules > 0 and v_thin = 0 and v_unbal = 0, false);
  detail := format('%s rule(s) in force, %s raising nothing, %s out of balance',
                   coalesce(v_rules, -1), coalesce(v_thin, -1), coalesce(v_unbal, -1));
  return next;

  case_name := 'promoting a rule that names no lines is refused by name';
  passed := coalesce(v_promote like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_promote, 'nothing was tried');
  return next;

  case_name := 'nor may a rule in force be written with no lines by any other path';
  passed := coalesce(v_direct like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_direct, 'nothing was tried');
  return next;

  case_name := 'nor emptied once it is in force';
  passed := coalesce(v_empty like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_empty, 'nothing was tried');
  return next;

  case_name := 'every organisation''s rules in force raise lines, and the check says how many';
  passed := coalesce(v_estate like 'posting rules: % in force across % organisation(s), every one raises lines'
                     and v_report = 0, false);
  detail := coalesce(v_estate, 'no answer') || format(' (%s finding(s))', coalesce(v_report, -1));
  return next;

  -- The original finding, falsified. The rule is unbalanced, so the
  -- reconciliation must refuse; what matters is which refusal it names.
  case_name := 'the reconciliation reads a rule in the organisation that holds it, not in the signed-in person''s';
  passed := coalesce(v_recon like '%' || v_bcode || ': posting rule zzprlunbalanced v1 — %'
                     and v_recon like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_UNBALANCED%'
                     and v_recon not like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_EMPTY%'
                     and v_recon not like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION%',
                     false);
  detail := left(coalesce(v_recon, 'no answer'), 300);
  return next;

  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant tn where tn.code in (v_acode, v_bcode));
  detail := 'two organisations, a change set and four rules, all rolled back with the block that made them';
  return next;
end;
$$;


revoke all on function erp_test.posting_rules_raise_lines_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_suite_verdicts_strict();
select erp.assert_ci_coverage();

select erp.assert_every_posting_rule_raises_lines();
select erp_test.assert_posting_rules_raise_lines_suite();
