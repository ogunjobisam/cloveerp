-- =============================================================================
-- A supplier states its tax, and the product records it
--
-- 20260916090000 put output tax on the ledger and said the input half would
-- follow, transcribed rather than determined. This is that half.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Why input tax is not determined
--
-- The obvious move is to run a purchase invoice through erp.determine_tax()
-- the way a sales invoice goes. It would be wrong, and quietly.
--
-- The rules in the packs are written for supplies a company MAKES: they read
-- supply_type, the item's class, whether the customer is registered, and they
-- end in a residual rule that says "true, standard rate". Put a purchase
-- through that and every import, every reverse-charge service, every exempt and
-- zero-rated purchase is assigned the standard rate of the company's own
-- country, with a plausible number and a citation that does not apply.
--
-- What a supplier charged is a fact about the supplier's supply, under the
-- supplier's obligations, decided by the supplier. It is on their invoice. The
-- product's job is to record it and reclaim it, not to recompute it — and the
-- product already refuses to guess a rate, on the reasoning that "a guessed
-- rate is a filing error with a number on it". A guessed INPUT rate is the same
-- filing error, claimed rather than charged, which is the half HMRC looks at.
--
-- So: erp.state_supplier_tax() takes the tax the supplier's invoice states,
-- apportions it across the lines by their net, and records a determination per
-- line whose rule_code says where the number came from. Nothing is derived.
-- A supplier that charged nothing has nothing recorded and nothing posts.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And the return can tell the two apart
--
-- erp.tax_report() grouped by jurisdiction, code and rate with no direction, so
-- input tax would have been added to output tax and the return would have
-- overstated what was owed by the whole of what was reclaimable. It now carries
-- the direction, read from the side of the trade the document is on — which
-- 20260916042000 made answerable by naming the party's role on the document.
-- =============================================================================

-- ── 1. What the supplier charged ─────────────────────────────────────────────

create or replace function erp.state_supplier_tax(
  p_document_id uuid,
  p_tax_minor   bigint,
  p_tax_code    text default 'S',
  p_note        text default null)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_base   text;
  v_net    bigint;
  v_left   bigint := p_tax_minor;
  v_share  bigint;
  v_n      integer := 0;
  r        record;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  select dt.base_type_code into v_base
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  if coalesce(v_base, '') not in ('invoice_reference', 'credit_reference') then
    raise exception 'CLOVEERP_TAX_NOT_ON_THIS_DOCUMENT: % carries no tax to state', d.document_number
      using errcode = '23514',
            hint = 'The tax a supplier charged is stated on their invoice or credit, not on an order or a receipt.';
  end if;

  if erp.document_trade_side(p_document_id) <> 'purchase' then
    raise exception 'CLOVEERP_TAX_IS_NOT_THEIRS_TO_STATE: % is not a purchase', d.document_number
      using errcode = '23514',
            hint = 'Tax on something you sold is worked out from your own rules, not taken from somebody else''s invoice.';
  end if;

  if coalesce(p_tax_minor, 0) < 0 then
    raise exception 'CLOVEERP_TAX_IS_NOT_NEGATIVE: a supplier charges tax or charges none'
      using errcode = '23514';
  end if;

  select coalesce(sum(l.net_minor), 0) into v_net
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and not coalesce(l.is_cancelled, false);

  if v_net = 0 then
    raise exception 'CLOVEERP_TAX_WITHOUT_A_SUPPLY: % has no value to carry tax', d.document_number
      using errcode = '23514';
  end if;

  -- Stated once, apportioned by what each line is worth. The last line takes
  -- whatever rounding left over, so the lines add to the figure on the
  -- supplier's invoice rather than to something near it.
  for r in
    select l.id, l.net_minor,
           row_number() over (order by l.line_no desc) as from_last
      from erp.document_line l
     where l.tenant_id = v_tenant and l.document_id = p_document_id
       and not coalesce(l.is_cancelled, false)
     order by l.line_no
  loop
    v_share := case when r.from_last = 1
                    then v_left
                    else round(p_tax_minor::numeric * r.net_minor / v_net)::bigint end;
    v_left := v_left - v_share;

    delete from erp.tax_determination td
     where td.tenant_id = v_tenant and td.document_line_id = r.id;

    insert into erp.tax_determination (
      tenant_id, entity_id, document_id, document_line_id, tax_code, rate_pct,
      taxable_minor, tax_minor, currency, jurisdiction, rule_code,
      determination_inputs, determined_at)
    values (
      v_tenant, d.entity_id, p_document_id, r.id, p_tax_code,
      case when r.net_minor = 0 then 0
           else round(v_share::numeric * 100 / r.net_minor, 4) end,
      r.net_minor, v_share, coalesce(d.currency, 'GBP'),
      (select p.country_code from erp.party p
        where p.tenant_id = v_tenant and p.id = d.party_id),
      'supplier_stated',
      jsonb_build_object('stated_minor', p_tax_minor, 'line_net_minor', r.net_minor,
                         'note', p_note),
      now());

    update erp.document_line
       set tax_code = p_tax_code, tax_rate_pct =
             case when r.net_minor = 0 then 0
                  else round(v_share::numeric * 100 / r.net_minor, 4) end,
           tax_minor = v_share, updated_at = now()
     where id = r.id;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function erp.state_supplier_tax(uuid, bigint, text, text) from public, anon, authenticated;

comment on function erp.state_supplier_tax(uuid, bigint, text, text) is
  'Records the tax a supplier''s invoice states, apportioned across its lines by '
  'what each is worth. Not determined: what a supplier charged is a fact about '
  'their supply under their obligations, and recomputing it from our own rules '
  'would assign a plausible wrong rate to every import, reverse charge and '
  'exempt purchase.';

create or replace function public.erp_state_supplier_tax(
  p_document_id uuid,
  p_tax_minor   bigint,
  p_tax_code    text default 'S',
  p_note        text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  v_n      integer;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;

  perform erp.authorise('procurement.match', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  v_n := erp.state_supplier_tax(p_document_id, p_tax_minor, p_tax_code, p_note);

  return jsonb_build_object(
    'document_id', p_document_id,
    'lines', v_n,
    'tax_minor', erp.document_tax_minor(p_document_id),
    'net_minor', erp.document_value_minor(p_document_id));
end;
$$;

revoke all on function public.erp_state_supplier_tax(uuid, bigint, text, text) from public, anon;

comment on function public.erp_state_supplier_tax(uuid, bigint, text, text) is
  'States the tax a supplier charged on their invoice, so it can be reclaimed '
  'and reconciled. Asks procurement.match, the permission that registers a '
  'supplier bill in the first place.';

select erp.assert_public_api_safe();

-- ── 2. The return tells input from output ────────────────────────────────────

-- A returns-table function cannot gain a column by replacement, so it goes and
-- comes back. public.erp_tax_report() reads it with to_jsonb(), so the door
-- carries the new column without being touched.
drop function if exists erp.tax_report(date, date, uuid);

create or replace function erp.tax_report(
  p_from date, p_to date, p_entity_id uuid default null)
returns table (direction text, jurisdiction text, tax_code text, rate_pct numeric,
               taxable_minor bigint, tax_minor bigint, currency char(3),
               transactions bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Statutory reporting: by jurisdiction and code, because that is the shape
  -- of every return, and traceable to the determinations behind it. And by
  -- direction, because tax charged and tax suffered are different boxes and
  -- adding them together overstates what is owed by the whole of what is
  -- reclaimable.
  select case erp.document_trade_side(d.id)
           when 'sale' then 'output'
           when 'purchase' then 'input'
           else 'unknown' end                     as direction,
         td.jurisdiction, td.tax_code, td.rate_pct,
         sum(td.taxable_minor)::bigint, sum(td.tax_minor)::bigint,
         td.currency, count(*)
    from erp.tax_determination td
    join erp.document d on d.id = td.document_id
   where td.tenant_id = erp.current_tenant_id()
     and d.document_date between p_from and p_to
     and (p_entity_id is null or td.entity_id = p_entity_id)
   group by 1, td.jurisdiction, td.tax_code, td.rate_pct, td.currency
   order by 1, 2, 4 desc
$$;

revoke all on function erp.tax_report(date, date, uuid) from public, anon, authenticated;

comment on function erp.tax_report(date, date, uuid) is
  'Tax by direction, jurisdiction, code and rate for a period. Output is what '
  'was charged on supplies made; input is what suppliers charged and stated. '
  'Separate because they are separate boxes on every return.';

-- ── 3. A purchase invoice posts what the supplier charged ────────────────────

do $installer$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text, numeric, numeric, bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
       E'            jsonb_build_object(''account'', v_grni,''side'',''debit'',''rate'',1,\n'
    || E'                               ''description'',''Clearing goods received not invoiced''),\n'
    || E'            jsonb_build_object(''account'', v_ap,''side'',''credit'',''rate'',1,\n'
    || E'                               ''description'',''Trade payable'')))),';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_PROCUREMENT_INSTALLER_UNRECOGNISED: the purchase invoice rule in % is not the one this migration adds a line to. It reads: %',
      v_sig, substr(v_def, greatest(position('purchase_invoice' in v_def), 1), 400);
  end if;

  v_new := replace(v_def, v_needle,
       E'            jsonb_build_object(''account'', v_grni,''side'',''debit'',\n'
    || E'                               ''basis'',''document_value'',''rate'',1,\n'
    || E'                               ''description'',''Clearing goods received not invoiced''),\n'
    || E'            jsonb_build_object(''account'', erp.tenant_account_code(''tax_control''),''side'',''debit'',\n'
    || E'                               ''basis'',''document_tax'',''rate'',1,\n'
    || E'                               ''description'',''Tax the supplier charged''),\n'
    || E'            jsonb_build_object(''account'', v_ap,''side'',''credit'',\n'
    || E'                               ''balancing'',true,\n'
    || E'                               ''description'',''Trade payable'')))),');

  execute v_new;
end
$installer$;

-- And the organisations already configured take it as a change, the same way
-- the sales side did.
update erp_ref.module_installer
   set current_version = 2,
       description = 'The supplier bill, the payment rule and the match tolerances. '
                     'Version 2 (20260916320000) debits the tax a supplier charged to '
                     'the tax control account and makes the payable the gross owed.'
 where install_code = 'procurement-controls';

insert into erp_ref.module_upgrade_item
  (install_code, to_version, object_kind, object_key, payload, seq)
values
  ('procurement-controls', 2, 'posting_rule', 'purchase_invoice',
   jsonb_build_object(
     'code', 'purchase_invoice', 'name', 'Purchase invoice', 'ledger', 'GL',
     'event_type', 'document.purchase_invoice.registered',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'goods_received_not_invoiced'),
                          'side', 'debit', 'basis', 'document_value', 'rate', 1,
                          'description', 'Clearing goods received not invoiced'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'tax_control'),
                          'side', 'debit', 'basis', 'document_tax', 'rate', 1,
                          'description', 'Tax the supplier charged'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'trade_payable'),
                          'side', 'credit', 'balancing', true,
                          'description', 'Trade payable'))),
   120)
on conflict (install_code, to_version, object_kind, object_key) do update
  set payload = excluded.payload, seq = excluded.seq;

-- ── 4. The word the report now says ──────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key('Direction'), 'en', 'Direction',
       'A screen string declared at its call site and rendered through ui(). '
       'The tax report''s column separating what was charged on supplies made '
       'from what suppliers charged, because they are separate boxes on a return.'
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_tax_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_supp uuid; v_cust uuid;
  v_pinv uuid; v_sinv uuid;
  v_n integer; v_tax bigint; v_net bigint;
  v_dr_tax bigint; v_cr_ap bigint;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-supplier-tax', 'Supplier tax suite',
                              'admin@zz-supplier-tax.test', 'Supplier Tax Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ee', 'admin@zz-supplier-tax.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ee')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- ── 1. What they charged is what is recorded, to the penny ───────────────
  v_cases := v_cases + 1;
  v_pinv := erp.create_document('purchase_invoice', v_entity, v_site, v_supp,
                                current_date, v_ccy, 'ZZST-BILL', '{}'::jsonb);
  perform erp.add_document_line(v_pinv, v_item, 1, 3333, 'a third of it');
  perform erp.add_document_line(v_pinv, v_item, 1, 3333, 'another third');
  perform erp.add_document_line(v_pinv, v_item, 1, 3334, 'and the rest');
  v_n := erp.state_supplier_tax(v_pinv, 2000, 'S', 'suite: what the bill says');
  v_tax := erp.document_tax_minor(v_pinv);
  case_name := 'the tax a supplier charged is spread across the lines and still adds to what they charged';
  passed := v_n = 3 and v_tax = 2000;
  detail := format('%s line(s), %s recorded against %s stated', v_n, v_tax, 2000);
  return next;

  -- ── 2. And the rate is theirs, not ours ──────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'every line says the rule that decided it was the supplier, not a rule set of ours';
  passed := (select count(*) from erp.tax_determination td
              where td.document_id = v_pinv and td.rule_code = 'supplier_stated') = 3
        and not exists (select 1 from erp.tax_determination td
                         where td.document_id = v_pinv and td.rule_code <> 'supplier_stated');
  detail := format('%s determination(s), all supplier stated',
                   (select count(*) from erp.tax_determination td where td.document_id = v_pinv));
  return next;

  -- ── 3. A sale is not theirs to state ─────────────────────────────────────
  v_cases := v_cases + 1;
  v_sinv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                current_date, v_ccy, 'ZZST-SALE', '{}'::jsonb);
  perform erp.add_document_line(v_sinv, v_item, 1, 10000, 'something we sold');
  begin
    perform erp.state_supplier_tax(v_sinv, 2000, 'S', 'suite: not theirs');
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_TAX_IS_NOT_THEIRS_TO_STATE%';
    v_msg := left(sqlerrm, 80);
  end;
  case_name := 'tax on something we sold cannot be taken from somebody else''s invoice';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 4. It reaches the ledger as tax suffered ─────────────────────────────
  v_cases := v_cases + 1;
  v_net := erp.document_value_minor(v_pinv);
  perform erp.transition_document(v_pinv, 'register', 'supplier tax suite');
  select coalesce(sum(jl.debit_minor) filter (where a.control_kind = 'tax'), 0),
         coalesce(sum(jl.credit_minor) filter (where a.control_kind = 'payable'), 0)
    into v_dr_tax, v_cr_ap
    from erp.journal j
    join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
    join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
   where j.tenant_id = v_tenant and j.document_id = v_pinv;
  case_name := 'the tax a supplier charged is debited to the tax account and the payable is the gross owed';
  passed := v_dr_tax = v_tax and v_cr_ap = v_net + v_tax;
  detail := format('tax debited %s of %s; payable %s against net %s plus tax',
                   v_dr_tax, v_tax, v_cr_ap, v_net);
  return next;

  -- ── 5. And the return keeps the two apart ────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the return separates what suppliers charged from what was charged on supplies made';
  passed := exists (select 1 from erp.tax_report(current_date - 1, current_date + 1) r
                     where r.direction = 'input' and r.tax_minor = 2000);
  detail := coalesce((select string_agg(format('%s %s', r.direction, r.tax_minor), ', ')
                        from erp.tax_report(current_date - 1, current_date + 1) r),
                     'the return is empty');
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 6. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-supplier-tax')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ee');
  detail := 'zz-supplier-tax rolled back with its bill and its determinations';
  return next;

  if v_cases <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: supplier_tax_suite ran % cases, expected 6', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.supplier_tax_suite() from public, anon;

create or replace function erp_test.assert_supplier_tax_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _supplier_tax on commit drop as
    select * from erp_test.supplier_tax_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _supplier_tax;
  drop table _supplier_tax;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SUPPLIER_TAX_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: supplier_tax_suite ran % cases, expected 6', v_all;
  end if;
  return format('a supplier states its tax: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_supplier_tax_suite() from public, anon;

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
select erp.assert_resource_coverage('en');
select erp.assert_ci_coverage();
select erp_test.assert_supplier_tax_suite();
