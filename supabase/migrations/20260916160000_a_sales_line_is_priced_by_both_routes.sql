-- =============================================================================
-- A sales line is priced by whichever route added it
--
-- The same item, for the same customer, on the same document, takes a
-- different price depending on which screen the line was added from.
--
--   New document form  →  erp.create_document_full(), which resolves the
--                         customer's agreed price for a sales line before it
--                         writes it (20260910180854: "A sales line nobody
--                         priced takes the customer's agreed price where there
--                         is one")
--
--   Add line, on the   →  erp.add_document_line(), which resolves a price only
--   document page         when the base type is purchase_order
--                         (20260906130000). For a quotation, a sales order, a
--                         delivery or a sales invoice the price stays
--                         coalesce(p_unit_price_minor, 0), and the line is
--                         written at nothing.
--
-- So a person who leaves the price blank on the second route — which the first
-- route teaches them to do — raises a line at £0.00, and the invoice, the
-- journal and the customer all agree that the goods were free. Nothing refuses
-- it, because a zero-priced line is a legitimate thing to be able to write.
--
-- The purchase side was given this in 20260906130000 and the sales side was
-- not, which reads like an oversight rather than a decision: the reasoning in
-- that migration — a line nobody priced takes what the catalogue says — is not
-- a reason that stops at purchase orders.
--
-- The price comes from erp.resolve_price(), the same function
-- erp.create_document_full() asks, so the two routes cannot answer differently
-- again. A price somebody typed still stands, on either route.
-- =============================================================================

do $price$
declare
  v_sig constant text := 'erp.add_document_line(uuid, uuid, numeric, bigint, text, date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text :=
       E'  if v_base = ''purchase_order'' and v_price = 0 then\n'
    || E'    select * into pr from erp.resolve_purchase_price(p_item_id, d.party_id, p_quantity,\n'
    || E'                                                     d.document_date, d.site_id);\n'
    || E'    if found and (pr.currency is null or pr.currency = d.currency) then\n'
    || E'      v_price := pr.amount_minor;\n'
    || E'    end if;\n'
    || E'  end if;';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_ADD_LINE_UNRECOGNISED: the catalogue pricing in % is not the one this migration adds the other side to', v_sig;
  end if;

  v_new := replace(v_def, v_needle, v_needle ||
       E'\n\n'
    || E'  -- And the other side of the same silence. A sales line nobody priced\n'
    || E'  -- takes the customer''s agreed price, which is what the New document\n'
    || E'  -- form has always done through erp.create_document_full(). Two routes\n'
    || E'  -- to one line were pricing it differently, and the quieter of them\n'
    || E'  -- wrote the line at nothing.\n'
    || E'  if v_price = 0 and erp.document_trade_side(p_document_id) = ''sale'' then\n'
    || E'    select * into pr from erp.resolve_price(p_item_id, d.party_id, p_quantity,\n'
    || E'                                            d.document_date, d.site_id);\n'
    || E'    if found and (pr.currency is null or pr.currency = d.currency) then\n'
    || E'      v_price := pr.amount_minor;\n'
    || E'    end if;\n'
    || E'  end if;');

  if v_new = v_def then
    raise exception 'CLOVEERP_ADD_LINE_UNRECOGNISED: % was not changed by this migration', v_sig;
  end if;

  execute v_new;
end
$price$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.line_price_parity_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_cust uuid; v_supp uuid;
  v_listed bigint; v_uom uuid;
  v_doc uuid; v_full uuid; v_po uuid;
  v_added bigint; v_byform bigint; v_typed bigint; v_pline bigint;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-line-price', 'Line price parity suite',
                              'admin@zz-line-price.test', 'Line Price Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000eb', 'admin@zz-line-price.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000eb')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- An item with a selling price on it. The demonstration seeds purchase
  -- prices and not sales ones, so the fixture puts the price there itself
  -- rather than asserting against whatever the demonstration happens to hold.
  select i.id into v_item
    from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
   order by i.code limit 1;
  select coalesce(i.sales_uom_id, i.stock_uom_id) into v_uom
    from erp.item i where i.id = v_item;

  insert into erp.item_price (tenant_id, item_id, price_kind, price_list_code,
                              currency, amount_minor, per_quantity, uom_id,
                              min_quantity, valid_from)
  values (v_tenant, v_item, 'sales_list', 'ZZ-LIST', v_ccy, 4500, 1, v_uom, 0,
          current_date - 10);

  select r.amount_minor into v_listed
    from erp.resolve_price(v_item, v_cust, 1, current_date, v_site) r limit 1;

  -- ── 1. A line added to a sales invoice takes the agreed price ────────────
  v_cases := v_cases + 1;
  v_doc := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                               current_date, v_ccy, 'ZZLP-ADDED', '{}'::jsonb);
  perform erp.add_document_line(v_doc, v_item, 1, null, 'priced by the catalogue');
  select l.unit_price_minor into v_added
    from erp.document_line l where l.document_id = v_doc order by l.line_no limit 1;
  case_name := 'a sales line added with no price takes the price the customer has agreed, not nothing';
  passed := v_added = v_listed and v_added > 0;
  detail := format('the line was written at %s and the catalogue says %s', v_added, v_listed);
  return next;

  -- ── 2. And it is the same price the other route writes ──────────────────
  v_cases := v_cases + 1;
  v_full := (erp.create_document_full('sales_invoice', v_cust, v_site, 'ZZLP-FORM',
                                      current_date, v_ccy,
                                      jsonb_build_array(jsonb_build_object(
                                        'item_id', v_item, 'quantity', 1)),
                                      null) ->> 'document_id')::uuid;
  select l.unit_price_minor into v_byform
    from erp.document_line l where l.document_id = v_full order by l.line_no limit 1;
  case_name := 'the New document form and a line added afterwards price the same item the same way';
  passed := v_byform = v_added;
  detail := format('the form wrote %s and the added line wrote %s', v_byform, v_added);
  return next;

  -- ── 3. A price somebody typed is still theirs ───────────────────────────
  v_cases := v_cases + 1;
  perform erp.add_document_line(v_doc, v_item, 1, 12345, 'priced by a person');
  select l.unit_price_minor into v_typed
    from erp.document_line l where l.document_id = v_doc order by l.line_no desc limit 1;
  case_name := 'a price somebody typed stands, and is not replaced by the catalogue';
  passed := v_typed = 12345;
  detail := format('typed 12345, stored %s', v_typed);
  return next;

  -- ── 4. The purchase side is untouched ───────────────────────────────────
  v_cases := v_cases + 1;
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_supp,
                              current_date, v_ccy, 'ZZLP-PO', '{}'::jsonb);
  perform erp.add_document_line(v_po, v_item, 1, null, 'priced by the supplier catalogue');
  select l.unit_price_minor into v_pline
    from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
  case_name := 'a purchase line is still priced from the supplier catalogue, as it was before';
  passed := v_pline is not null;
  detail := format('the purchase line was written at %s', v_pline);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 5. Undone ───────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-line-price')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000eb');
  detail := 'zz-line-price rolled back with its documents and lines';
  return next;

  if v_cases <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: line_price_parity_suite ran % cases, expected 5', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.line_price_parity_suite() from public, anon;

create or replace function erp_test.assert_line_price_parity_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _line_price on commit drop as
    select * from erp_test.line_price_parity_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _line_price;
  drop table _line_price;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LINE_PRICE_PARITY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: line_price_parity_suite ran % cases, expected 5', v_all;
  end if;
  return format('a sales line is priced by both routes: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_line_price_parity_suite() from public, anon;

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
select erp_test.assert_line_price_parity_suite();
