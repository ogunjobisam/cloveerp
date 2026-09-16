-- =============================================================================
-- A posting asks the matrix, and an override is one
--
-- /finance/account-determination says it is "the determination matrix that
-- decides which account and analysis a posting lands on". It decides nothing.
--
-- The repository has known this since 20260901150000, which says so in capitals:
-- "THERE ARE TWO ACCOUNT-SELECTION MECHANISMS, AND POSTINGS USE THE OTHER ONE."
-- erp.post_document_finance() resolves a posting-rule line to an account by its
-- literal code. erp.account_determination — the matrix the screen writes, with
-- its item classes, party classes, sites, companies, ledgers and reason codes —
-- is reachable from one caller: erp.posting_line_account_code(), and only when
-- a rule line spells its account as the word `determined`. No rule does, and no
-- screen can author one, so the matrix has never chosen an account.
--
-- Beside it, "Record a deliberate override" writes erp.posting_account_override
-- and nothing reads that table at all. The empty state underneath reads "Every
-- posting so far has followed the matrix above", which is true only in the sense
-- that no posting has ever followed anything else either.
--
-- The owner's decision is to wire it, so:
--
--   1. An override for this document wins. That is what recording a deliberate
--      departure means, and it is the narrowest statement anybody can make.
--   2. Otherwise the matrix answers, if it has a rule that covers this supply.
--   3. Otherwise the account the posting rule names, exactly as today.
--
-- An organisation with no overrides and no determination rules posts precisely
-- what it posted yesterday: nothing matches, and the rule's own account stands.
-- The change is inert until somebody configures the screen that has always
-- claimed to configure it.
--
-- A line that spells its account `determined` still refuses when nothing
-- matches, because that line asked the matrix by name and a silent fallback
-- would be the matrix deciding nothing all over again.
--
-- Worth knowing before configuring it: a determination rule is written against
-- an item's CLASS, never the item, and erp.determine_account() refuses outright
-- for an item that carries no class. So a company that writes rules without
-- classifying its items gets no answer from the matrix and keeps posting by its
-- posting rules. That is the safe direction, and it is silent — which is why it
-- is said here rather than found later.
-- =============================================================================

create or replace function erp.posting_line_account_code(
  p_line jsonb, p_document_id uuid, p_ledger_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  v_type   text;
  v_item   uuid;
  v_code   text;
  res      jsonb;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;

  v_type := coalesce(p_line ->> 'transaction_type', dt.base_type_code);
  select dl.item_id into v_item
    from erp.document_line dl
   where dl.tenant_id = v_tenant and dl.document_id = d.id
     and not coalesce(dl.is_cancelled, false)
   order by dl.line_no limit 1;

  -- 1. A deliberate departure, recorded against this document. The narrowest
  --    thing anybody can say about where a posting goes, so it is asked first.
  select a.code into v_code
    from erp.posting_account_override o
    join erp.account a on a.tenant_id = o.tenant_id and a.id = o.account_id
   where o.tenant_id = v_tenant
     and o.object_type = 'document'
     and o.object_id = p_document_id
     and (o.transaction_type is null or o.transaction_type = v_type)
     and (o.line_ref is null or o.line_ref = p_line ->> 'description')
   order by (o.line_ref is not null)::int + (o.transaction_type is not null)::int desc,
            o.applied_at desc
   limit 1;

  if v_code is not null then
    return v_code;
  end if;

  -- 2. The matrix. Asked without raising, because an organisation that has
  --    written no rule has not made a mistake — it has said nothing, and the
  --    posting rule is what it said instead.
  res := erp.determine_account(v_type, v_item, d.party_id, d.site_id, d.entity_id,
                               p_ledger_id, p_line ->> 'reason_code', d.document_date,
                               false);

  if coalesce((res ->> 'matched')::boolean, false) then
    return res ->> 'account_code';
  end if;

  -- 3. A line that named the matrix by name and got no answer is a fault worth
  --    refusing: falling back here would be the matrix deciding nothing again,
  --    which is the whole defect this migration exists to end.
  if coalesce(p_line ->> 'account', '') = 'determined' then
    perform erp.determine_account(v_type, v_item, d.party_id, d.site_id, d.entity_id,
                                  p_ledger_id, p_line ->> 'reason_code', d.document_date,
                                  true);
  end if;

  -- 4. Otherwise the account the rule names, exactly as before.
  return p_line ->> 'account';
end;
$$;

revoke all on function erp.posting_line_account_code(jsonb, uuid, uuid) from public, anon, authenticated;

comment on function erp.posting_line_account_code(jsonb, uuid, uuid) is
  'Which account a posting-rule line reaches: a deliberate override recorded '
  'against this document, else the determination matrix where a rule covers '
  'the supply, else the account the rule itself names. An organisation with '
  'neither posts what its posting rule says, as it always did.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.determination_posts_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_cust uuid; v_doc uuid;
  v_ledger uuid; v_rev uuid; v_other uuid; v_third uuid;
  v_line jsonb; v_class uuid;
  v_got text; v_base text;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-determination', 'Determination posts suite',
                              'admin@zz-determination.test', 'Determination Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ed', 'admin@zz-determination.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ed')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.id, l.entity_id, l.currency into v_ledger, v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  select a.id into v_rev from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.account_type = 'income'
     and a.status = 'active' order by a.code limit 1;
  select a.id into v_other from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.account_type = 'expense'
     and a.status = 'active' order by a.code limit 1;
  select a.id into v_third from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.account_type = 'expense'
     and a.status = 'active' and a.id <> v_other order by a.code desc limit 1;

  -- Determination is written against an item's CLASS, never the item, and
  -- refuses outright for an item that has none. The demonstration classifies
  -- nothing, so the fixture does.
  insert into erp.posting_class (tenant_id, kind, code, name, status)
  values (v_tenant, 'item', 'ZZCLASS', 'Suite class', 'active')
  returning id into v_class;
  insert into erp.item_posting_class (tenant_id, item_id, posting_class_id,
                                      valid_from, status)
  values (v_tenant, v_item, v_class, current_date - 1, 'active');

  v_doc := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                               current_date, v_ccy, 'ZZDET-1', '{}'::jsonb);
  perform erp.add_document_line(v_doc, v_item, 1, 10000, 'a line to post');

  select dt.base_type_code into v_base
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.id = v_doc;

  select a.code into v_got from erp.account a where a.id = v_rev;
  v_line := jsonb_build_object('account', v_got, 'side', 'credit', 'rate', 1);

  -- ── 1. No rules, no overrides: the rule's own account ────────────────────
  v_cases := v_cases + 1;
  case_name := 'with no rule and no override a line reaches the account its posting rule names';
  passed := erp.posting_line_account_code(v_line, v_doc, v_ledger) = v_got;
  detail := format('the rule named %s and the line reached %s',
                   v_got, erp.posting_line_account_code(v_line, v_doc, v_ledger));
  return next;

  -- ── 2. A matrix rule decides instead ─────────────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.account_determination (tenant_id, transaction_type, account_id,
                                         entity_id, valid_from, status)
  values (v_tenant, v_base, v_other, v_entity, current_date - 1, 'active');
  case_name := 'a determination rule covering the supply chooses the account instead of the rule''s';
  passed := erp.posting_line_account_code(v_line, v_doc, v_ledger)
            = (select a.code from erp.account a where a.id = v_other);
  detail := format('the line reached %s, the matrix names %s',
                   erp.posting_line_account_code(v_line, v_doc, v_ledger),
                   (select a.code from erp.account a where a.id = v_other));
  return next;

  -- ── 3. And an override beats the matrix ──────────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.posting_account_override (tenant_id, object_type, object_id,
                                            account_id, reason, applied_by)
  values (v_tenant, 'document', v_doc, v_third, 'suite: a deliberate departure', v_admin);
  case_name := 'a deliberate override recorded on the document beats the matrix and the rule alike';
  passed := erp.posting_line_account_code(v_line, v_doc, v_ledger)
            = (select a.code from erp.account a where a.id = v_third);
  detail := format('the line reached %s, the override names %s',
                   erp.posting_line_account_code(v_line, v_doc, v_ledger),
                   (select a.code from erp.account a where a.id = v_third));
  return next;

  -- ── 4. A line that asks the matrix by name and gets no answer refuses ────
  v_cases := v_cases + 1;
  delete from erp.posting_account_override o where o.tenant_id = v_tenant and o.object_id = v_doc;
  update erp.account_determination set status = 'inactive'
   where tenant_id = v_tenant and transaction_type = v_base;
  begin
    perform erp.posting_line_account_code(
      jsonb_build_object('account', 'determined', 'side', 'credit', 'rate', 1),
      v_doc, v_ledger);
    v_ok := false; v_msg := 'it was allowed';
  exception when others then
    -- Which refusal arrives first is the matrix's business: no rule covers
    -- the supply, or the item carries no class to write a rule against. The
    -- case is that it refuses rather than posting something plausible.
    -- The current prefix, not the one the defining migration spells:
    -- 20260904980000 rewrote every refusal in the live bodies, so the code in
    -- that file has not been the code raised since. Naming the retired prefix
    -- here, even to explain it, is what erp.assert_no_legacy_refusal_prefix()
    -- exists to refuse — which it duly did.
    v_ok := sqlerrm like 'CLOVEERP_DETERMINATION_FAILED%'
         or sqlerrm like 'CLOVEERP_POSTING_CLASS_MISSING%';
    v_msg := left(sqlerrm, 80);
  end;
  case_name := 'a line that names the matrix and finds no rule is refused rather than quietly posted';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 5. And a line naming a real account is not ───────────────────────────
  v_cases := v_cases + 1;
  case_name := 'while a line naming its own account still reaches it, with the matrix silent';
  passed := erp.posting_line_account_code(v_line, v_doc, v_ledger) = v_got;
  detail := format('the line reached %s', erp.posting_line_account_code(v_line, v_doc, v_ledger));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 6. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-determination')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ed');
  detail := 'zz-determination rolled back with its rule and its override';
  return next;

  if v_cases <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: determination_posts_suite ran % cases, expected 6', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.determination_posts_suite() from public, anon;

create or replace function erp_test.assert_determination_posts_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _determination_posts on commit drop as
    select * from erp_test.determination_posts_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _determination_posts;
  drop table _determination_posts;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DETERMINATION_POSTS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: determination_posts_suite ran % cases, expected 6', v_all;
  end if;
  return format('a posting asks the matrix: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_determination_posts_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp_test.assert_determination_posts_suite();

-- ═════════════════════════════════════════════════════════════════════════════
-- The case that asserted a named account always won
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.policy_closure_suite() asserted that a posting line naming an
-- account passes through untouched. That was true while the matrix answered
-- only a line spelling `determined`, and it is the thing this migration
-- deliberately ends: a rule that covers the supply now decides, whatever the
-- line names. The case keeps its subject and asserts the new rule — including
-- that a line the matrix does NOT cover still keeps its own account, which is
-- what makes this safe for an organisation that has configured nothing.
do $closure$
declare
  v_sig constant text := 'erp_test.policy_closure_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
       E'  passed := v_code = ''5900''\n'
    || E'        and erp.posting_line_account_code(jsonb_build_object(''account'', ''1200''), v_doc, v_gl) = ''1200'';\n'
    || E'  detail := format(''determined → %s (expected 5900); a named account passes through'', coalesce(v_code, ''null''));';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_CLOSURE_SUITE_UNRECOGNISED: the case about a named account in % is not the one this migration turns round', v_sig;
  end if;

  v_new := replace(v_def, v_needle,
       E'  passed := v_code = ''5900''\n'
    || E'        and erp.posting_line_account_code(\n'
    || E'              jsonb_build_object(''account'', ''1200'', ''transaction_type'', ''zz_uncovered''),\n'
    || E'              v_doc, v_gl) = ''1200'';\n'
    || E'  detail := format(''determined → %s (expected 5900); an account the matrix does not cover keeps its own'', coalesce(v_code, ''null''));');

  execute v_new;
end
$closure$;

select erp_test.assert_policy_closure_suite();
