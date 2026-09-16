-- ─────────────────────────────────────────────────────────────────────────────
-- A unit says how finely it is counted
--
-- erp.uom.decimals has been in the schema since the first day, with the
-- intention written beside it:
--
--     -- Decimal places permitted. An item counted in pieces cannot be 2.5 of
--     -- them.
--
-- Nothing ever read it. The unit screen asks for the number and makes it
-- required, so every organisation has answered it; every organisation is
-- seeded with EA, Each, counted in whole ones. And a purchase order line for
-- 2.5 Each has always been accepted, because the only thing standing between
-- the typed number and the column was numeric(20,6).
--
-- The check added on 16 September (supabase/ci/write_only_columns.sh) proved
-- it rather than suspecting it, and registered erp.uom.decimals as a column a
-- screen writes and nothing decides on. This removes that row by making it
-- true again.
--
-- Two things were wrong, not one. erp.add_document_line() never wrote
-- document_line.uom_id either, so a line did not record the unit it was
-- counted in — there was nothing to check a quantity against even if somebody
-- had wanted to. The line now carries its unit, and the quantity has to fit
-- it.
--
-- Which unit: the one the trade is in. A purchase line takes the product's
-- purchase unit, a sales line its sales unit, anything else the stock unit,
-- each falling back to stock. The customer/supplier split is not decided here
-- — erp.document_type_party_role_kind() already reads it off the permission
-- the document type requires, so a type added tomorrow is placed by the
-- module it belongs to.
--
-- WHAT THIS DOES NOT DO. Lines already written are not restated. A quantity
-- that does not fit its unit is refused from now on; the ones already in the
-- ledger stay as they are, and this migration says at the end how many there
-- are so nobody is surprised by the number later. This is the same treatment
-- tax determinations had: a change with a date on it.
--
-- Nor does it reach every place a quantity is captured. It covers the door
-- every document route calls. Stock counts, adjustments and production
-- confirmations each capture a quantity through their own door and are not
-- touched here; erp.quantity_fits_uom() is written so that wiring them is a
-- one-line change when somebody gets to them. Derived quantities — a bill of
-- materials exploded into components, a unit conversion — are deliberately
-- left alone: 1 Each converted to cases is legitimately 0.0833, and refusing
-- that would be refusing arithmetic.
--
-- ALSO IN HERE: a correction to a register entry I wrote yesterday.
-- erp.cost_model.basis was registered as a known gap on the grounds that it is
-- a valuation basis no valuation consults. That is wrong. erp.cost_model is
-- the commercial price book's internal cost per price item, and basis is the
-- caption saying what the money is per — the form's own placeholder is "per
-- user per month" and the price book displays it. It is deliberately free
-- text for a person to read, it is not a valuation input, and
-- erp.stock_valuation_layer has nothing to do with it. Its rationale moves
-- from the known-gap block to the deliberate one and says so.
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What unit a line is counted in, and whether a quantity fits it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.item_line_uom(p_item_id uuid, p_document_type_id uuid)
returns uuid
language sql
stable
security invoker
set search_path = ''
as $$
  -- The side of the trade decides which of the product's units applies, and
  -- the side of the trade is already answered from the permission the type
  -- requires. Each falls back to the stock unit, which every product has.
  select case erp.document_type_party_role_kind(erp.require_tenant_id(), p_document_type_id)
           when 'customer'::erp.party_role_kind then coalesce(i.sales_uom_id, i.stock_uom_id)
           when 'supplier'::erp.party_role_kind then coalesce(i.purchase_uom_id, i.stock_uom_id)
           else i.stock_uom_id
         end
    from erp.item i
   where i.tenant_id = erp.require_tenant_id()
     and i.id = p_item_id;
$$;

comment on function erp.item_line_uom(uuid, uuid) is
  'The unit a document line for this product is counted in: the purchase unit '
  'on a purchase, the sales unit on a sale, the stock unit otherwise, each '
  'falling back to stock. Null when the line names no product.';

create or replace function erp.quantity_fits_uom(p_uom_id uuid, p_quantity numeric)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  -- A quantity fits its unit when rounding it to the places that unit is
  -- counted in does not change it. Nothing to compare against is not a
  -- failure: a line with no product has no unit, and this refuses nobody.
  select case
           when p_quantity is null then true
           else coalesce(
                  (select p_quantity = round(p_quantity, u.decimals::integer)
                     from erp.uom u
                    where u.tenant_id = erp.require_tenant_id()
                      and u.id = p_uom_id),
                  true)
         end;
$$;

comment on function erp.quantity_fits_uom(uuid, numeric) is
  'Whether a quantity can be counted in a unit: true when rounding it to that '
  'unit''s decimal places leaves it unchanged. This is the read that '
  'erp.uom.decimals never had.';

create or replace function erp.require_quantity_fits_uom(p_uom_id uuid, p_quantity numeric)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_code   text;
  v_name   text;
  v_places smallint;
begin
  if erp.quantity_fits_uom(p_uom_id, p_quantity) then
    return;
  end if;

  select u.code, u.name, u.decimals into v_code, v_name, v_places
    from erp.uom u
   where u.tenant_id = erp.require_tenant_id() and u.id = p_uom_id;

  raise exception
    'CLOVEERP_QUANTITY_TOO_PRECISE: % of % — % is counted in % decimal place(s)',
    p_quantity, v_code, v_name, v_places
    using errcode = '23514';
end;
$$;

comment on function erp.require_quantity_fits_uom(uuid, numeric) is
  'Refuses a quantity that cannot be counted in the unit given, naming the '
  'unit and how finely it is counted.';

-- The door refuses what it is asked to write. This reads back what is already
-- written, against the unit the line itself recorded, so a line put there by a
-- route that does not go through the door — a planned order firmed into a
-- purchase, a bill of materials exploded into components — is still answerable.
-- It is also what makes document_line.uom_id worth writing: a unit recorded
-- and never read again would be the same defect one level down.
create or replace function erp.document_line_unit_breaches(p_document_id uuid default null)
-- The output names are prefixed because a language-sql returns-table puts them
-- in scope beside the columns they are selected from, and line_no, quantity and
-- decimals would each shadow one.
returns table(breach_line_id uuid, breach_document_id uuid, breach_line_no integer,
              breach_quantity numeric, breach_uom_code text, breach_decimals smallint)
language sql
stable
security invoker
set search_path = ''
as $$
  select l.id, l.document_id, l.line_no, l.quantity, u.code, u.decimals
    from erp.document_line l
    join erp.uom u on u.tenant_id = l.tenant_id and u.id = l.uom_id
   where l.tenant_id = erp.require_tenant_id()
     and (p_document_id is null or l.document_id = p_document_id)
     and l.quantity is not null
     and l.quantity <> round(l.quantity, u.decimals::integer)
   order by l.document_id, l.line_no;
$$;

comment on function erp.document_line_unit_breaches(uuid) is
  'Document lines whose quantity is finer than the unit the line records. '
  'Empty for one document means every line on it can be counted in the unit it '
  'is written in. Pass nothing to ask the question of the whole organisation.';

-- erp.register_refusal() rather than a raw insert: it writes the register row
-- and mirrors the wording into the resource layer in one call, so the two
-- cannot be written apart and an organisation can override the guidance.
select erp.register_refusal(
  'CLOVEERP_QUANTITY_TOO_PRECISE',
  'Writing a quantity finer than its unit of measure is counted in',
  'Every unit says how many decimal places it is counted in, and Each is counted in whole ones. A line for 2.5 Each says something the warehouse cannot pick and the ledger cannot value.',
  'Round the quantity to whole units, or count the line in a unit that allows the fraction — kilograms rather than each. If the unit itself is wrong, change its decimal places on the units screen.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The door every document route calls
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three needles against the live body, which is the 20260906130000 body as
-- patched by 20260914040000 (erp.line_description). Re-emitting the whole
-- function here would silently drop that patch, so it is not re-emitted.

do $add_line$
declare
  v_sig    constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def    text := pg_get_functiondef('erp.add_document_line(uuid,uuid,numeric,bigint,text,date)'::regprocedure);

  -- (a) the guard, before the line number is taken
  v_guard_old constant text :=
    E'  select coalesce(max(l.line_no), 0) + 10 into v_line\n';
  v_guard_new constant text :=
       E'  -- A unit says how finely it is counted, and Each is counted in whole\n'
    || E'  -- ones. Refusing here is refusing before the line exists.\n'
    || E'  perform erp.require_quantity_fits_uom(\n'
    || E'            erp.item_line_uom(p_item_id, d.document_type_id), p_quantity);\n'
    || E'\n'
    || E'  select coalesce(max(l.line_no), 0) + 10 into v_line\n';

  -- (b) the column list gains uom_id
  v_cols_old constant text :=
       E'    tenant_id, document_id, line_no, item_id, description, quantity,\n'
    || E'    unit_price_minor, net_minor, currency, required_date)\n';
  v_cols_new constant text :=
       E'    tenant_id, document_id, line_no, item_id, description, quantity, uom_id,\n'
    || E'    unit_price_minor, net_minor, currency, required_date)\n';

  -- (c) and the values gain the unit the line was counted in
  v_vals_old constant text :=
    E'    v_tenant, p_document_id, v_line, p_item_id, erp.line_description(p_item_id, p_description), p_quantity,\n';
  v_vals_new constant text :=
       E'    v_tenant, p_document_id, v_line, p_item_id, erp.line_description(p_item_id, p_description), p_quantity,\n'
    || E'    erp.item_line_uom(p_item_id, d.document_type_id),\n';
begin
  if position('erp.require_quantity_fits_uom(' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already refuses a quantity that does not fit its unit', v_sig;
  end if;

  if (length(v_def) - length(replace(v_def, v_guard_old, ''))) / length(v_guard_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not take its line number exactly once the way the 20260906130000 body does', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_cols_old, ''))) / length(v_cols_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not name its line columns exactly once the way the 20260906130000 body does', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_vals_old, ''))) / length(v_vals_old) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not write its line exactly once the way the 20260914040000 patch left it', v_sig;
  end if;

  v_def := replace(v_def, v_guard_old, v_guard_new);
  v_def := replace(v_def, v_cols_old,  v_cols_new);
  v_def := replace(v_def, v_vals_old,  v_vals_new);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp.require_quantity_fits_uom(' in v_def) = 0
     or position('erp.item_line_uom(p_item_id, d.document_type_id),' in v_def) = 0
     or position('quantity, uom_id,' in v_def) = 0
     or position('erp.line_description(p_item_id, p_description)' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without one of the three changes, or without the description patch it already had', v_sig;
  end if;
end
$add_line$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. What is already written, said out loud once
-- ═════════════════════════════════════════════════════════════════════════════

do $existing$
declare
  v_n bigint;
begin
  select count(*) into v_n
    from erp.document_line l
    join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
    join erp.uom u on u.tenant_id = l.tenant_id and u.id = i.stock_uom_id
   where l.quantity is not null
     and l.quantity <> round(l.quantity, u.decimals::integer);

  if v_n > 0 then
    raise notice
      'A unit says how finely it is counted: % document line(s) already carry a quantity finer than the product''s stock unit allows. They are left as they are; the refusal applies to lines written from now on.',
      v_n;
  else
    raise notice
      'A unit says how finely it is counted: no document line already written carries a quantity finer than its unit allows.';
  end if;
end
$existing$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The register
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.uom.decimals is now read by something that decides, so its row must go —
-- erp.assert_write_only_columns() refuses a register entry that has stopped
-- being true, which is the mechanism that makes this list shrink rather than
-- rot.

delete from erp_meta.write_only_column
 where schema_name = 'erp' and table_name = 'uom' and column_name = 'decimals';

-- And the correction. erp.cost_model.basis stays registered — it really is
-- written and never decided on — but for the opposite reason to the one I
-- gave it.

update erp_meta.write_only_column
   set rationale =
     'Deliberate, and a correction to what this row said on 16 September. It was registered as a valuation basis that no valuation consults. It is not a valuation basis. erp.cost_model holds the commercial price book''s internal cost per price item — infrastructure, support load, pass-through — and basis is the caption saying what that money is per: the form''s placeholder is "per user per month" and the price book displays it beside the figures. It is free text for a person to read when they are judging a margin. Nothing should decide on it.'
 where schema_name = 'erp' and table_name = 'cost_model' and column_name = 'basis';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.unit_precision_suite()
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
  v_each uuid; v_kg uuid;
  v_po uuid; v_so uuid; v_line uuid;
  v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-unit-precision', 'Unit precision suite',
                              'admin@zz-unit-precision.test', 'Unit Precision Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ef', 'admin@zz-unit-precision.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ef')::text, true);
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

  -- The suite owns its units rather than borrowing whatever the demonstration
  -- happens to seed: one counted in whole ones, one counted to three places.
  select u.id into v_each from erp.uom u
   where u.tenant_id = v_tenant and u.code = 'EA';
  if v_each is null then
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (v_tenant, 'EA', 'Each', 'quantity'::erp.uom_class, 0, false,
            'active'::erp.record_status)
    returning id into v_each;
  else
    update erp.uom set decimals = 0 where tenant_id = v_tenant and id = v_each;
  end if;
  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
  values (v_tenant, 'ZZKG', 'Suite kilogram', 'quantity'::erp.uom_class, 3, false,
          'active'::erp.record_status)
  returning id into v_kg;

  -- ── 1. The unit the product is stocked in refuses a fraction ─────────────
  v_cases := v_cases + 1;
  update erp.item set stock_uom_id = v_each where tenant_id = v_tenant and id = v_item;
  case_name := 'a quantity finer than the unit allows does not fit it';
  passed := not erp.quantity_fits_uom(v_each, 2.5)
        and erp.quantity_fits_uom(v_each, 2)
        and erp.quantity_fits_uom(v_each, 2.000);
  detail := format('each: 2.5 fits=%s, 2 fits=%s',
                   erp.quantity_fits_uom(v_each, 2.5), erp.quantity_fits_uom(v_each, 2));
  return next;

  -- ── 2. A unit counted more finely allows what the finer figure needs ─────
  v_cases := v_cases + 1;
  case_name := 'a unit counted to three places takes three and refuses four';
  passed := erp.quantity_fits_uom(v_kg, 2.5)
        and erp.quantity_fits_uom(v_kg, 2.555)
        and not erp.quantity_fits_uom(v_kg, 2.5551);
  detail := format('kg: 2.555 fits=%s, 2.5551 fits=%s',
                   erp.quantity_fits_uom(v_kg, 2.555), erp.quantity_fits_uom(v_kg, 2.5551));
  return next;

  -- ── 3. Nothing to compare against refuses nobody ─────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a line with no unit is refused by nobody here';
  passed := erp.quantity_fits_uom(null, 2.5)
        and erp.quantity_fits_uom(v_each, null)
        and erp.item_line_uom(null, null) is null;
  detail := 'a null unit and a null quantity both pass';
  return next;

  -- ── 4. The door refuses it ───────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_supp,
                              current_date, v_ccy, 'ZZUP-ORDER', '{}'::jsonb);
  v_msg := null;
  begin
    perform erp.add_document_line(v_po, v_item, 2.5, 1000, 'two and a half of something countable');
    v_msg := 'a fractional quantity was accepted against a unit counted in whole ones';
  exception when others then v_msg := sqlerrm;
  end;
  case_name := 'the door refuses a quantity that cannot be counted in its unit';
  passed := v_msg like 'CLOVEERP_QUANTITY_TOO_PRECISE%'
        and not exists (select 1 from erp.document_line l
                         where l.document_id = v_po and l.quantity = 2.5);
  detail := left(coalesce(v_msg, 'no verdict'), 180);
  return next;

  -- ── 5. And the refusal says which unit and how finely ────────────────────
  v_cases := v_cases + 1;
  case_name := 'the refusal names the unit and how finely it is counted';
  passed := v_msg like '%EA%' and v_msg like '%0 decimal place(s)%';
  detail := left(coalesce(v_msg, 'no verdict'), 180);
  return next;

  -- ── 6. A whole quantity goes through, and records its unit ───────────────
  v_cases := v_cases + 1;
  v_line := erp.add_document_line(v_po, v_item, 3, 1000, 'three of them');
  case_name := 'a line that fits is written, and records the unit it was counted in';
  passed := exists (select 1 from erp.document_line l
                     where l.id = v_line and l.quantity = 3 and l.uom_id = v_each);
  detail := format('unit recorded: %s, expected %s',
                   coalesce((select l.uom_id::text from erp.document_line l where l.id = v_line), 'none'),
                   v_each::text);
  return next;

  -- ── 7. The side of the trade chooses the unit ────────────────────────────
  v_cases := v_cases + 1;
  update erp.item set sales_uom_id = v_kg where tenant_id = v_tenant and id = v_item;
  v_so := erp.create_document('sales_order', v_entity, v_site, v_cust,
                              current_date, v_ccy, 'ZZUP-SALE', '{}'::jsonb);
  v_line := erp.add_document_line(v_so, v_item, 2.5, 10000, 'sold by weight');
  case_name := 'a sale takes the sales unit, so what a purchase refuses a sale allows';
  passed := exists (select 1 from erp.document_line l
                     where l.id = v_line and l.quantity = 2.5 and l.uom_id = v_kg)
        and erp.item_line_uom(v_item, (select d.document_type_id from erp.document d where d.id = v_po)) = v_each;
  detail := format('the sale was counted in %s',
                   coalesce((select u.code from erp.uom u
                              join erp.document_line l on l.uom_id = u.id
                             where l.id = v_line), 'nothing'));
  return next;

  -- ── 8. A line that got in another way is still answerable ────────────────
  -- Written straight into the table, the way erp.firm_planned_order writes one,
  -- so this proves the read-back and not the door a second time.
  v_cases := v_cases + 1;
  insert into erp.document_line (tenant_id, document_id, line_no, item_id,
                                 description, quantity, uom_id)
  values (v_tenant, v_po, 9990, v_item, 'came in without going through the door',
          0.25, v_each);
  case_name := 'a line written around the door is still found by reading its unit back';
  passed := exists (select 1 from erp.document_line_unit_breaches(v_po) b
                     where b.breach_line_no = 9990 and b.breach_uom_code = 'EA'
                       and b.breach_decimals = 0)
        and not exists (select 1 from erp.document_line_unit_breaches(v_po) b
                         where b.breach_line_no <> 9990);
  detail := format('%s breach(es) on the order',
                   (select count(*) from erp.document_line_unit_breaches(v_po)));
  return next;

  -- ── 9. The register no longer claims nothing reads it ────────────────────
  v_cases := v_cases + 1;
  case_name := 'the register no longer says erp.uom.decimals is written and never read';
  passed := not exists (select 1 from erp_meta.write_only_column g
                         where g.schema_name = 'erp' and g.table_name = 'uom'
                           and g.column_name = 'decimals')
        and exists (select 1 from erp_ref.refusal r
                     where r.code = 'CLOVEERP_QUANTITY_TOO_PRECISE');
  detail := 'the row is gone and the refusal is registered';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 10. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-unit-precision')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ef');
  detail := 'zz-unit-precision rolled back with its units and its lines';
  return next;

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: unit_precision_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.unit_precision_suite() from public, anon;

create or replace function erp_test.assert_unit_precision_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _unit_precision on commit drop as
    select * from erp_test.unit_precision_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _unit_precision;
  drop table _unit_precision;
  if v_fail > 0 then
    raise exception E'CLOVEERP_UNIT_PRECISION_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: unit_precision_suite ran % cases, expected 10', v_all;
  end if;
  return format('a unit says how finely it is counted: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_unit_precision_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_write_only_columns();
select erp_test.assert_unit_precision_suite();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
