-- =============================================================================
-- Tax reaches the ledger
--
-- 20260916030000 made an invoice say its tax and deliberately stopped short of
-- the ledger, naming the decision as the owner's. The owner has taken it: tax
-- posts. This is the output half — what the company charges. Input tax, what a
-- supplier charged us, is the migration after this one, and is transcribed from
-- the supplier's invoice rather than determined, because the treatment of
-- another company's supply is that company's to state and ours to record.
--
-- Until now the two halves disagreed in the open. The customer was billed £120
-- on a PDF the product froze at issue; the receivable said £100; a £120 receipt
-- met CLOVEERP_CASH_EXCEEDS_OWING; and erp.ageing (gross) and
-- erp.receivables_ageing (the subledger, net) answered differently about the
-- same invoice on the same screen. Posting the tax closes that.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Tax applies when the company is registered, and not before
--
-- A company charges tax because it is registered to, not because a rule set
-- exists. erp.tax_rules_in_force() asks whether there is anything to determine
-- by; it does not ask whether this company may charge at all. Both questions
-- now have to answer yes.
--
-- erp.entity_tax_registration has carried the answer since 0002 and nothing
-- outside erp.sales_invoice_contract() has ever read it. The test is that
-- contract's own, lifted out whole so the invoice header and the determination
-- cannot come to different views of the same company on the same day.
--
-- The effect is that an organisation which has not set tax up determines
-- nothing and posts exactly what it posted yesterday: with no tax on a line the
-- tax posting line is worth nothing, and a line worth nothing is not written
-- (20260910165931). Two lines in, two lines out. This migration is inert until
-- somebody is registered.
-- ─────────────────────────────────────────────────────────────────────────────
-- Three lines on two bases, and why the receivable is the balancing one
--
-- The bridge apportions one number across a rule's lines by a rate. A tax
-- posting needs the revenue at net, the tax control at tax and the receivable
-- at gross, which is three lines on three different measures, and
-- erp.posting_rule_imbalance() requires every basis to balance within itself —
-- unless the rule names exactly one balancing line, in which case the rule is
-- balanced by construction and the bridge computes that line as whatever is
-- left over.
--
-- So the receivable is the balancing line. That is not a way around the check;
-- it is the truer statement. What the customer owes is not a third measurement
-- of the supply, it is the sum of what was earned and what was collected on the
-- state's behalf, and saying so as "the difference" keeps one number out of the
-- configuration that could have been typed wrong.
--
--   CR revenue      basis document_value   the supply, net
--   CR tax control  basis document_tax     the tax on it
--   DR receivable   balancing              what the customer owes
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What this does not do
--
-- erp.tax_report() reads erp.tax_determination and never the ledger, so not one
-- figure on the return changes here. The ledger becomes a second and
-- independent account of the same tax, which is worth having only if the two
-- are held to each other: erp.tax_outside_the_ledger_report() stops asking
-- whether a tax line exists and starts asking whether it is the right amount.
--
-- Posted journals are not restated. An invoice posted net stays posted net, as
-- its determination was never backfilled either. This is a change with a date.
-- =============================================================================

-- ── 1. Registered is registered ──────────────────────────────────────────────

create or replace function erp.entity_is_tax_registered(
  p_entity_id uuid, p_on date default null)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- erp.sales_invoice_contract()'s own test, lifted out so the invoice header
  -- and the determination cannot disagree about the same company on a date.
  -- Registered is registered; whether the number was filled in is a separate
  -- question, and erp.validate_sales_invoice_issue() is where it is asked.
  select exists (
    select 1
      from erp.entity_tax_registration r
     where r.tenant_id = erp.current_tenant_id()
       and r.entity_id = p_entity_id
       and upper(r.registration_type) like 'VAT%'
       and r.valid_from <= coalesce(p_on, current_date)
       and (r.valid_to is null or r.valid_to >= coalesce(p_on, current_date)));
$$;

revoke all on function erp.entity_is_tax_registered(uuid, date) from public, anon, authenticated;

comment on function erp.entity_is_tax_registered(uuid, date) is
  'Whether a company held a tax registration on a date. A company charges tax '
  'because it is registered to, not because a rule set exists, so this is asked '
  'beside erp.tax_rules_in_force() and both have to answer yes.';

-- The determination asks it. An organisation that has bound a pack but never
-- registered determines nothing, which is the same answer the law gives.
do $gate$
declare
  v_sig constant text := 'erp.determine_document_tax(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    E'  if not erp.tax_rules_in_force(d.entity_id, v_on) then\n    return 0;\n  end if;';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_DETERMINATION_UNRECOGNISED: the rules-in-force gate in % is not the one this migration adds to', v_sig;
  end if;

  v_new := replace(v_def, v_needle, v_needle ||
    E'\n\n' ||
    E'  -- And registered to charge it. A rule set says what the rate would be;\n' ||
    E'  -- the registration says whether this company charges at all.\n' ||
    E'  if not erp.entity_is_tax_registered(d.entity_id, v_on) then\n' ||
    E'    return 0;\n' ||
    E'  end if;');

  execute v_new;
end
$gate$;

-- ── 2. The tax on a document, as a measure the bridge can apportion ──────────

create or replace function erp.document_tax_minor(p_document_id uuid)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  -- Beside erp.document_value_minor(), and read the same way: the lines, not a
  -- second opinion about the lines.
  select coalesce(sum(l.tax_minor), 0)::bigint
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id()
     and l.document_id = p_document_id
     and not coalesce(l.is_cancelled, false);
$$;

revoke all on function erp.document_tax_minor(uuid) from public, anon, authenticated;

comment on function erp.document_tax_minor(uuid) is
  'The tax on a document, summed from its lines. The measure a posting line '
  'names as basis document_tax, so the tax control account is reached by the '
  'same route as every other account and not by arithmetic in the bridge.';

-- ── 3. The bridge learns the measure ─────────────────────────────────────────

-- Anchored on the one line that names the other basis. The body is needled
-- rather than re-emitted because 20260906135000 put erp.derive_dimensions()
-- into it and 20260910165931 put the zero-line skip into it; re-emitting from
-- any file would drop both.
do $bridge$
declare
  v_sig constant text := 'erp.post_document_finance(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := E'          when ''stock_cost'' then v_cost\n';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: the basis of an amount in % is not the one this migration adds to. It reads: %',
      v_sig, substr(v_def, greatest(position('v_amount := round(' in v_def), 1), 300);
  end if;

  v_new := replace(v_def, v_needle, v_needle ||
    E'          when ''document_tax'' then erp.document_tax_minor(p_document_id)\n');

  if v_new = v_def then
    raise exception 'CLOVEERP_BRIDGE_UNRECOGNISED: % was not changed by this migration', v_sig;
  end if;

  execute v_new;
end
$bridge$;

-- ── 4. A basis the bridge does not know is a wrong number, quietly ───────────

-- side is checked and basis is not, and the difference matters: an unknown
-- side would read as a credit and an unknown basis reads as the document value.
-- One is caught at promotion and the other posts.
create or replace function erp.assert_posting_rule_balances(
  p_code text, p_version integer)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_found  boolean;
  v_lines  jsonb;
  v_out    numeric;
  v_bad    text;
begin
  select true, pr.posting_lines into v_found, v_lines
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = p_code and pr.version = p_version;

  -- Not the same fault, and saying so is the whole of 20260916010000. A rule
  -- of another organisation is unreadable from here; a rule of this one that
  -- lists nothing is configuration that looks like behaviour.
  if not coalesce(v_found, false) then
    raise exception 'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION: % v% is not a rule of this organisation', p_code, p_version
      using errcode = '23503',
            hint = 'Ask again from inside the organisation that holds the rule.';
  end if;

  if erp.posting_rule_raises_nothing(v_lines) then
    raise exception 'CLOVEERP_POSTING_RULE_EMPTY: % v% raises no lines', p_code, p_version
      using errcode = '23514',
            hint = 'A rule that posts nothing is configuration that looks like behaviour.';
  end if;

  -- Every side must be one of two words. A typo here would otherwise read as a
  -- credit, because the interpreter has to treat "not debit" as something.
  select string_agg(distinct l.value ->> 'side', ', ') into v_bad
    from jsonb_array_elements(v_lines) l
   where coalesce(l.value ->> 'side', '') not in ('debit', 'credit');

  if v_bad is not null then
    raise exception 'CLOVEERP_POSTING_RULE_SIDE: % v% has line side(s) %',
      p_code, p_version, v_bad using errcode = '23514';
  end if;

  -- And every basis one of three. The bridge reads an unrecognised basis as the
  -- document value, so a rule that named one would post a plausible wrong
  -- number for ever without anything saying so.
  select string_agg(distinct l.value ->> 'basis', ', ') into v_bad
    from jsonb_array_elements(v_lines) l
   where l.value ->> 'basis' is not null
     and l.value ->> 'basis' not in ('document_value', 'stock_cost', 'document_tax');

  if v_bad is not null then
    raise exception 'CLOVEERP_POSTING_RULE_BASIS: % v% measures a line on %',
      p_code, p_version, v_bad using errcode = '23514',
      hint = 'A line is measured on the document value, the stock cost or the tax on the document.';
  end if;

  v_out := erp.posting_rule_imbalance(v_lines);

  if v_out <> 0 then
    raise exception
      'CLOVEERP_POSTING_RULE_UNBALANCED: % v% is out by % per unit of document value',
      p_code, p_version, v_out
      using errcode = '23514',
            hint = 'Debit rates must sum to credit rates, or every journal this '
                   'rule raises will fail its balance check at commit.';
  end if;
end;
$$;

revoke all on function erp.assert_posting_rule_balances(text, integer) from public, anon, authenticated;

comment on function erp.assert_posting_rule_balances(text, integer) is
  'The rule named, read in the organisation in context: it has to be a rule of '
  'that organisation, it has to raise lines, every line has to take a side and '
  'a measure the bridge knows, and the debit rates have to sum to the credit '
  'rates. All five are answerable from the rule alone, which is why promotion '
  'can ask them before anything posts.';

-- ── 5. The rule an organisation is given from now on ─────────────────────────

do $installer$
declare
  v_sig constant text := 'erp.configure_finance(integer, character, uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    E'            jsonb_build_object(''account'', erp.chart_account_code(''trade_receivable''),''side'',''debit'',''rate'',1,\n'
    || E'                               ''description'',''Trade receivable''),\n'
    || E'            jsonb_build_object(''account'', erp.chart_account_code(''revenue''),''side'',''credit'',''rate'',1,\n'
    || E'                               ''description'',''Revenue'')))),';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_FINANCE_INSTALLER_UNRECOGNISED: the sales invoice rule in % is not the one this migration replaces', v_sig;
  end if;

  v_new := replace(v_def, v_needle,
       E'            jsonb_build_object(''account'', erp.chart_account_code(''revenue''),''side'',''credit'',\n'
    || E'                               ''basis'',''document_value'',''rate'',1,\n'
    || E'                               ''description'',''Revenue''),\n'
    || E'            jsonb_build_object(''account'', erp.chart_account_code(''tax_control''),''side'',''credit'',\n'
    || E'                               ''basis'',''document_tax'',''rate'',1,\n'
    || E'                               ''description'',''Tax on the supply''),\n'
    || E'            jsonb_build_object(''account'', erp.chart_account_code(''trade_receivable''),''side'',''debit'',\n'
    || E'                               ''balancing'',true,\n'
    || E'                               ''description'',''Trade receivable'')))),');

  execute v_new;
end
$installer$;

-- ── 6. And the one an organisation already configured is offered ─────────────

-- A purpose is resolved to the code this organisation's chart actually gives
-- it, not the code the register would have chosen. On the demonstration 2100 is
-- the bank and not goods received not invoiced, which is the whole reason
-- erp.tenant_account_code() was written (20260910094351).
create or replace function erp.resolve_account_purposes(p_payload jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_lines jsonb := '[]'::jsonb;
  l       jsonb;
begin
  if p_payload -> 'posting_lines' is null then
    return p_payload;
  end if;
  for l in select * from jsonb_array_elements(p_payload -> 'posting_lines') loop
    if jsonb_typeof(l -> 'account') = 'object' and (l -> 'account' ->> 'purpose') is not null then
      l := l || jsonb_build_object('account', erp.tenant_account_code(l -> 'account' ->> 'purpose'));
    end if;
    v_lines := v_lines || jsonb_build_array(l);
  end loop;
  return p_payload || jsonb_build_object('posting_lines', v_lines);
end;
$$;

revoke all on function erp.resolve_account_purposes(jsonb) from public, anon, authenticated;

-- Every upgrade so far added a posting rule the organisation did not have, and
-- "does it hold this code" was the same question as "is it up to date". This is
-- the first that revises a rule the organisation already holds, and by code
-- alone it would be read as already applied and silently dropped from the plan.
do $planner$
declare
  v_sig constant text := 'erp.plan_module_upgrade(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    E'           when ''posting_rule'' then exists (\n'
    || E'             select 1 from erp.posting_rule r\n'
    || E'              where r.tenant_id = v_tenant and r.code = ui.object_key and r.status = ''active'')';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_PLANNER_UNRECOGNISED: the posting-rule test in % is not the one this migration replaces', v_sig;
  end if;

  v_new := replace(v_def, v_needle,
       E'           when ''posting_rule'' then exists (\n'
    || E'             select 1 from erp.posting_rule r\n'
    || E'              where r.tenant_id = v_tenant and r.code = ui.object_key and r.status = ''active''\n'
    || E'                and r.posting_lines\n'
    || E'                    = (erp.resolve_account_purposes(ui.payload) -> ''posting_lines''))');

  execute v_new;
end
$planner$;

update erp_ref.module_installer
   set current_version = 2,
       description = 'The ledger, the chart, the posting rules for every document. '
                     'Version 2 (20260916070000) puts the tax a sales invoice '
                     'determined on to the tax control account, and makes the '
                     'receivable the gross the customer owes.'
 where install_code = 'finance-posting';

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('finance-posting', 2, 'posting_rule', 'sales_invoice',
   jsonb_build_object(
     'code', 'sales_invoice', 'name', 'Sales invoice', 'ledger', 'GL',
     'event_type', 'document.invoice.posted',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'revenue'),
                          'side', 'credit', 'basis', 'document_value', 'rate', 1,
                          'description', 'Revenue'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'credit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax on the supply'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_receivable'),
                          'side', 'debit', 'balancing', true,
                          'description', 'Trade receivable'))),
   120)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- ── 7. A demonstration is a registered company, and takes the upgrade ────────

do $demo$
declare
  v_src text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  v_needle constant text := '  -- Receivables is where cash application''s posting rule lives.';
begin
  if position(v_needle in v_src) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.ensure_demo_configuration is not the deployed body';
  end if;
  if position('entity_tax_registration' in v_src) > 0 then
    return;
  end if;

  execute replace(v_src, v_needle,
       E'  -- A demonstration of a British manufacturer is a registered company:\n'
    || E'  -- unregistered, it would determine no tax and show a prospect a product\n'
    || E'  -- that cannot do VAT. The number is a demonstration''s number.\n'
    || E'  if not exists (select 1 from erp.entity_tax_registration etr\n'
    || E'                  where etr.tenant_id = p_tenant_id\n'
    || E'                    and upper(etr.registration_type) like ''VAT%'') then\n'
    || E'    insert into erp.entity_tax_registration (\n'
    || E'      tenant_id, entity_id, jurisdiction, registration_type,\n'
    || E'      registration_number, valid_from)\n'
    || E'    select p_tenant_id, e.id, coalesce(e.country_code, ''GB''), ''VAT'',\n'
    || E'           ''GB123456789'', current_date - 400\n'
    || E'      from erp.entity e\n'
    || E'     where e.tenant_id = p_tenant_id and e.status = ''active''::erp.record_status;\n'
    || E'    v_did := v_did || ''"tax registration"''::jsonb;\n'
    || E'  end if;\n\n'
    || E'  -- The ledger learned to carry tax. An organisation configured before\n'
    || E'  -- that takes the new rule the way it takes any other change.\n'
    || E'  if exists (select 1 from erp.module_installation i\n'
    || E'              where i.tenant_id = p_tenant_id and i.install_code = ''finance-posting'') \n'
    || E'     and exists (select 1 from erp.plan_module_upgrade(''finance-posting'')) then\n'
    || E'    perform erp.upgrade_module_configuration(''finance-posting'');\n'
    || E'    v_did := v_did || ''"tax posting"''::jsonb;\n'
    || E'  end if;\n\n' || v_needle);
end
$demo$;

-- ── 8. The two accounts of the same tax, held to each other ──────────────────

create or replace function erp.tax_outside_the_ledger_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  -- What each posted document determined, and what its journal actually put on
  -- a tax control account. A credit to tax control is tax charged, so the
  -- ledger's figure is the credit less the debit.
  posted as (
    select doc.id, doc.document_number,
           sum(td.tax_minor)                                   as determined_minor,
           coalesce((select sum(jl.credit_minor - jl.debit_minor)
                       from erp.journal j
                       join erp.journal_line jl
                         on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
                       join erp.account a
                         on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                      where j.tenant_id = t.tenant_id and j.document_id = doc.id
                        and a.control_kind = 'tax'), 0)         as posted_minor,
           (select j.journal_number from erp.journal j
             where j.tenant_id = t.tenant_id and j.document_id = doc.id
             order by j.posting_date limit 1)                   as journal_number
      from t
      join erp.tax_determination td on td.tenant_id = t.tenant_id
      join erp.document doc on doc.tenant_id = t.tenant_id and doc.id = td.document_id
     where td.tax_minor <> 0
       and exists (select 1 from erp.journal j
                    where j.tenant_id = t.tenant_id and j.document_id = doc.id)
     group by t.tenant_id, doc.id, doc.document_number
  )
  -- 1. The return and the ledger are two accounts of one tax, and this is the
  --    only thing holding them to each other.
  select 'the tax on a posted document is not the tax its journal carries',
         p.document_number,
         format('%s was determined and %s reached a tax control account on journal %s',
                p.determined_minor, p.posted_minor, coalesce(p.journal_number, 'none'))
    from posted p
   where p.determined_minor <> p.posted_minor
  union all
  -- 2. An invoice the product cannot tell the direction of, so it determined
  --    nothing. A party that both buys and sells, on a document naming neither.
  select 'an invoice was left undetermined because the product cannot tell a sale from a purchase',
         doc.document_number,
         format('%s is raised against %s, which holds both a customer and a supplier role, and the document names neither',
                doc.document_number, p.code)
    from t
    join erp.document doc on doc.tenant_id = t.tenant_id
    join erp.document_type dt on dt.tenant_id = t.tenant_id and dt.id = doc.document_type_id
    join erp.party p on p.tenant_id = t.tenant_id and p.id = doc.party_id
    join erp.object_state os on os.tenant_id = doc.tenant_id
     and os.object_type = 'document' and os.object_id = doc.id
    join erp.state s on s.id = os.current_state_id
   where dt.base_type_code in ('invoice_reference', 'credit_reference')
     and s.is_committed
     and not coalesce(doc.is_cancelled, false)
     and doc.party_role_id is null
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = t.tenant_id and pr.party_id = doc.party_id
                    and pr.role_kind = 'customer' and pr.status = 'active')
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = t.tenant_id and pr.party_id = doc.party_id
                    and pr.role_kind = 'supplier' and pr.status = 'active')
     and erp.tax_rules_in_force(doc.entity_id, coalesce(doc.document_date, current_date))
$$;

revoke all on function erp.tax_outside_the_ledger_report() from public, anon, authenticated;

comment on function erp.tax_outside_the_ledger_report is
  'Every posted document whose determined tax is not the tax its journal '
  'carries, and every invoice left undetermined because the product could not '
  'tell a sale from a purchase. The return is built from determinations and the '
  'ledger from postings; this is what holds the two accounts of the same tax to '
  'each other.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.tax_reaches_the_ledger_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_cust   uuid;
  v_plain  uuid; v_inv uuid;
  v_net bigint; v_tax bigint;
  v_dr_recv bigint; v_cr_rev bigint; v_cr_tax bigint;
  v_debits bigint; v_credits bigint;
  v_owing bigint; v_owing0 bigint; v_left bigint;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-tax-ledger', 'Tax ledger suite',
                              'admin@zz-tax-ledger.test', 'Tax Ledger Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000e9', 'admin@zz-tax-ledger.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e9')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant and p.country_code = 'GB' order by p.code limit 1;

  -- ── 1. A demonstration is registered, and that is what the demo seeds ─────
  v_cases := v_cases + 1;
  case_name := 'a demonstration organisation holds a tax registration, so it may charge tax at all';
  passed := erp.entity_is_tax_registered(v_entity, current_date)
        and erp.tax_rules_in_force(v_entity, current_date);
  detail := format('registered %s, rules in force %s',
                   erp.entity_is_tax_registered(v_entity, current_date),
                   erp.tax_rules_in_force(v_entity, current_date));
  return next;

  -- What this customer already owed before the suite raised anything. The
  -- demonstration trades before the suite arrives, so the reading that means
  -- something is the movement, not the total.
  select coalesce(sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0)), 0)
    into v_owing0
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.party_id = v_cust
     and si.control_kind = 'receivable';

  -- ── 2. Without the registration nothing is determined, rules or no rules ──
  v_cases := v_cases + 1;
  delete from erp.entity_tax_registration etr where etr.tenant_id = v_tenant;
  v_plain := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                 current_date, v_ccy, 'ZZTL-UNREGISTERED', '{}'::jsonb);
  perform erp.add_document_line(v_plain, v_item, 1, 10000, 'a supply by a company that is not registered');
  perform erp.transition_document(v_plain, 'issue', 'tax ledger suite');
  case_name := 'a company with tax rules but no registration charges nothing, and its receivable is the net';
  passed := erp.document_tax_minor(v_plain) = 0
        and not exists (select 1 from erp.tax_determination td where td.document_id = v_plain);
  detail := format('tax on the document %s', erp.document_tax_minor(v_plain));
  return next;

  -- Registered again, for everything that follows.
  insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction,
                                           registration_type, registration_number, valid_from)
  select v_tenant, e.id, coalesce(e.country_code, 'GB'), 'VAT', 'GB123456789', current_date - 400
    from erp.entity e where e.tenant_id = v_tenant and e.status = 'active'::erp.record_status;

  -- ── 3. The journal carries three lines, and the right three ──────────────
  v_cases := v_cases + 1;
  v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                               current_date, v_ccy, 'ZZTL-REGISTERED', '{}'::jsonb);
  perform erp.add_document_line(v_inv, v_item, 1, 10000, 'a supply by a registered company');
  perform erp.transition_document(v_inv, 'issue', 'tax ledger suite');

  v_net := erp.document_value_minor(v_inv);
  v_tax := erp.document_tax_minor(v_inv);

  select coalesce(sum(jl.debit_minor) filter (where a.control_kind = 'receivable'), 0),
         coalesce(sum(jl.credit_minor) filter (where a.account_type = 'income'), 0),
         coalesce(sum(jl.credit_minor) filter (where a.control_kind = 'tax'), 0),
         coalesce(sum(jl.debit_minor), 0), coalesce(sum(jl.credit_minor), 0)
    into v_dr_recv, v_cr_rev, v_cr_tax, v_debits, v_credits
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.document_id = v_inv;

  case_name := 'the journal debits the receivable the gross, credits revenue the net and credits tax control the tax';
  passed := v_tax > 0
        and v_cr_rev = v_net
        and v_cr_tax = v_tax
        and v_dr_recv = v_net + v_tax;
  detail := format('net %s, tax %s; receivable %s, revenue %s, tax control %s',
                   v_net, v_tax, v_dr_recv, v_cr_rev, v_cr_tax);
  return next;

  -- ── 4. And balances ──────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the journal balances';
  passed := v_debits = v_credits and v_debits > 0;
  detail := format('%s debit, %s credit', v_debits, v_credits);
  return next;

  -- ── 5. The receivable is what the customer was billed ────────────────────
  -- This is the break the change closes: the PDF said the gross and the
  -- subledger said the net, so the customer's own payment would not apply.
  v_cases := v_cases + 1;
  select coalesce(sum(si.debit_minor - si.credit_minor - coalesce(si.settled_minor, 0)), 0)
    into v_owing
    from erp.subledger_item si
   where si.tenant_id = v_tenant and si.party_id = v_cust
     and si.control_kind = 'receivable';
  case_name := 'what the customer owes in the subledger is the gross on the invoice they were sent';
  passed := v_owing - v_owing0 = (v_net + v_tax) + 10000;
  detail := format('owed %s more than before, and the two invoices were %s and %s',
                   v_owing - v_owing0, 10000, v_net + v_tax);
  return next;

  -- ── 6. So the gross applies in full ──────────────────────────────────────
  v_cases := v_cases + 1;
  select coalesce(min(c.remaining_minor), 0) into v_left
    from erp.apply_cash(v_cust, v_net + v_tax, v_ccy, 'ZZTL-RECEIPT', current_date) c;
  case_name := 'a receipt for the gross the customer was billed applies in full and leaves nothing over';
  passed := coalesce(v_left, 0) = 0;
  detail := format('%s received, %s unapplied', v_net + v_tax, coalesce(v_left, 0));
  return next;

  -- ── 7. The return and the ledger agree ───────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'no posted document has determined tax its journal does not carry';
  passed := not exists (select 1 from erp.tax_outside_the_ledger_report() tl
                         where tl.finding like 'the tax on a posted document%');
  detail := coalesce((select string_agg(tl.reference, ', ')
                        from erp.tax_outside_the_ledger_report() tl
                       where tl.finding like 'the tax on a posted document%'),
                     'nothing outside the ledger');
  return next;

  -- ── 8. A measure the bridge does not know is refused, not guessed ────────
  v_cases := v_cases + 1;
  insert into erp.posting_rule (tenant_id, code, name, entity_id, ledger_id,
                                event_type, condition, posting_lines, version,
                                status, effective_from)
  select v_tenant, 'zz_bad_basis', 'A rule measured on nothing', v_entity, l.id,
         'document.invoice.posted', 'true'::jsonb,
         jsonb_build_array(
           jsonb_build_object('account', a.code, 'side', 'debit', 'basis', 'the_moon', 'rate', 1),
           jsonb_build_object('account', a.code, 'side', 'credit', 'rate', 1)),
         1, 'active', current_date
    from erp.ledger l
    join erp.account a on a.tenant_id = v_tenant and a.entity_id = v_entity
                      and a.control_kind = 'receivable' and a.status = 'active'
   where l.tenant_id = v_tenant and l.is_primary
   order by l.code limit 1;

  begin
    perform erp.assert_posting_rule_balances('zz_bad_basis', 1);
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_POSTING_RULE_BASIS%';
    v_msg := left(sqlerrm, 90);
  end;
  case_name := 'a posting line measured on something the bridge cannot measure is refused by name';
  passed := v_ok;
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 9. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-tax-ledger')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e9');
  detail := 'zz-tax-ledger rolled back with its invoices, journals and receipt';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: tax_reaches_the_ledger_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.tax_reaches_the_ledger_suite() from public, anon;

create or replace function erp_test.assert_tax_reaches_the_ledger_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all    integer;
  v_fail   integer;
  v_detail text;
begin
  create temp table if not exists _tax_ledger on commit drop as
    select * from erp_test.tax_reaches_the_ledger_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _tax_ledger;
  drop table _tax_ledger;
  if v_fail > 0 then
    raise exception E'CLOVEERP_TAX_LEDGER_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: tax_reaches_the_ledger_suite ran % cases, expected 9', v_all;
  end if;
  return format('tax reaches the ledger: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_tax_reaches_the_ledger_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_writes_name_their_rows();
select erp.assert_ci_coverage();
select erp_test.assert_tax_reaches_the_ledger_suite();

-- ═════════════════════════════════════════════════════════════════════════════
-- The case that asserted the gap
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.invoice_tax_suite() case 9 proved the gap was named rather than
-- hidden: it asserted that a posted invoice with determined tax DID appear in
-- erp.tax_outside_the_ledger_report(). That was true and worth asserting while
-- the tax stayed out of the ledger. It is false now, and a suite that asserts
-- the absence of a fix is a suite that fails the moment the fix lands. The case
-- keeps its number and asserts the same subject from the other side.
do $case9$
declare
  v_sig constant text := 'erp_test.invoice_tax_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
    E'  case_name := ''the product names every document whose determined tax reached no tax account, rather than hiding it'';\n'
    || E'  passed := exists (select 1 from erp.tax_outside_the_ledger_report() r\n'
    || E'                     where r.finding like ''tax was determined on a posted document%''\n'
    || E'                       and r.reference = (select d.document_number from erp.document d where d.id = v_inv2));';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_TAX_SUITE_UNRECOGNISED: the case that asserted the gap in % is not the one this migration turns round', v_sig;
  end if;

  v_new := replace(v_def, v_needle,
       E'  case_name := ''the tax determined on an issued invoice reaches a tax control account, and none is left outside the ledger'';\n'
    || E'  passed := not exists (select 1 from erp.tax_outside_the_ledger_report() tl\n'
    || E'                         where tl.finding like ''the tax on a posted document%'')\n'
    || E'        and (select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)\n'
    || E'               from erp.journal j\n'
    || E'               join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id\n'
    || E'               join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id\n'
    || E'              where j.tenant_id = v_tenant and j.document_id = v_inv2\n'
    || E'                and a.control_kind = ''tax'') = erp.document_tax_minor(v_inv2);');

  execute v_new;
end
$case9$;

select erp_test.assert_invoice_tax_suite();
