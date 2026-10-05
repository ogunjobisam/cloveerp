set lock_timeout = '30s';

-- =============================================================================
-- 20261006101000  A draft line is changed and removed
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-31, J-10, J-119).
-- A line typed wrong on a draft order could only be lived with: nothing
-- changed a line's quantity, price or wording before the document was
-- committed, and nothing removed one. A draft goods receipt that came short
-- kept the quantity it was raised with. The document page could not tell a
-- draft from a document past draft, so it offered Add line on a cancelled
-- receipt.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.change_document_line(line, quantity, price, description) and
--      erp.remove_document_line(line), behind public.erp_change_document_line
--      and public.erp_remove_document_line. Each asks the permission the
--      document's own type is raised with, as erp.add_document_line() does,
--      and erp.require_lines_open() (20261006100000): a line changes only on
--      a draft. They keep what hangs off the line true:
--        - a receipt or delivery line raised against an order line moves its
--          relation with it and the order line's progress is read again; such
--          a line may only be lowered, and keeps its price, because more is
--          received through Receive against an order, which applies the
--          tolerance, quarantine and over-receipt approval;
--        - a bill line matched to an order line moves its relation and asks
--          the three-way match again;
--        - a reservation on the line is released, as amending does;
--        - a margin approval waiting on the line is withdrawn;
--        - tax a supplier stated on the bill is taken off, to be stated again.
--      The price stays as it is unless one is typed: a quantity change does
--      not ask the price list, because that would overwrite a price somebody
--      typed. Reprice is the button that asks it. Removing marks the line
--      cancelled, as removing a line of a vendor quote does, and deletes the
--      relations the line itself raised, so what it was raised against is
--      open again. A drop-ship order's lines follow its sale, and are refused.
--   B. public.erp_document(uuid): 'lines' leaves out a cancelled line, and the
--      document says 'lines_open' (erp.document_lines_open) and 'is_terminal',
--      so the page draws its line controls only where the database takes them,
--      and says a cancelled document has finished rather than that it has no
--      lifecycle.
--   C. The words the screens say, and the refusals, registered.
--   D. erp_test.draft_line_suite.
--
-- Production: no row is changed. Tax on a sale is worked out only when it is
-- committed (erp.determine_tax_on_commit), so a draft has none to work out
-- again; and no stored total exists to keep (erp.document_value_minor sums
-- the lines that are not cancelled).
--
-- Proof: erp_test.draft_line_suite.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The two routines and their doors
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_LINE_NEEDS_A_QUANTITY',
  'Changing a line to a quantity of nothing, or less.',
  'A line of nothing is a line that should not be there, and a total read from it would mislead.',
  'Remove the line instead.');

select erp.register_refusal('CLOVEERP_FULFILLING_LINE_ONLY_LOWERED',
  'Raising the quantity, or changing the price, of a line raised against a line of an order.',
  'More against an order goes through the tolerance, quarantine and approval that receiving and delivering apply, and the price is the order''s.',
  'Lower it here, or raise more against the order. A price is changed on the order itself.');

select erp.register_refusal('CLOVEERP_DROP_SHIP_LINE_FOLLOWS_ITS_SALE',
  'Changing or removing a line of an order the supplier delivers straight to the customer.',
  'Its lines are paired with the lines of the customer''s order it was raised for, and a change on one side alone would part them.',
  'Change the customer''s order, and raise the supplier''s order from it again.');

create or replace function erp.change_document_line(
  p_line_id uuid,
  p_quantity numeric,
  p_unit_price_minor bigint default null,
  p_description text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  v_perm   text;
  v_base   text;
  v_price  bigint;
  v_valued boolean;
  v_desc   text;
  r        record;
begin
  -- A cancelled line has been removed: there is nothing to change.
  select * into l from erp.document_line
   where tenant_id = v_tenant and id = p_line_id and not coalesce(is_cancelled, false);
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  -- The permission raising this document required, read from the same place
  -- erp.add_document_line() reads it (20261006101000).
  select coalesce(dt.create_permission, bt.create_permission), bt.code into v_perm, v_base
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  perform erp.authorise(v_perm, d.entity_id, d.site_id, null, 'document_line', p_line_id);

  -- A line changes only on a draft (20261006100000).
  perform erp.require_lines_open(l.document_id);

  -- erp.raise_drop_ship_order() writes the supplier's lines from the sale's
  -- and pairs them; changing one side alone would part them.
  if d.order_behaviour_code = 'drop_ship' then
    raise exception
      'CLOVEERP_DROP_SHIP_LINE_FOLLOWS_ITS_SALE: % is delivered by the supplier to the customer, and its lines are the sale''s',
      d.document_number
      using errcode = '23514',
            hint = 'Change the customer''s order, and raise the supplier''s order from it again.';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_LINE_NEEDS_A_QUANTITY: line % of % would hold %',
      l.line_no, d.document_number, coalesce(p_quantity::text, 'no quantity')
      using errcode = '23514',
            hint = 'Remove the line instead.';
  end if;

  perform erp.require_quantity_fits_uom(l.uom_id, p_quantity);

  -- The price stays unless one is typed. Asking the price list again on a
  -- quantity change would overwrite a price somebody typed; Reprice asks it.
  v_price := coalesce(p_unit_price_minor, l.unit_price_minor, 0);

  -- A line raised against an order line may only come down, at the order's
  -- price. More goes through erp.receive_against(), which applies the
  -- tolerance, quarantine and over-receipt approval, or through the order's
  -- delivery; a second route would drift from them.
  if exists (select 1 from erp.document_relation rel
              where rel.tenant_id = v_tenant and rel.from_line_id = p_line_id
                and rel.relation_kind = 'fulfils')
     and (p_quantity > l.quantity or v_price is distinct from l.unit_price_minor) then
    raise exception
      'CLOVEERP_FULFILLING_LINE_ONLY_LOWERED: line % of % was raised against an order line, and is only lowered, at the order''s price',
      l.line_no, d.document_number
      using errcode = '23514',
            hint = case when v_base = 'receipt'
                        then 'Receive more with Receive against an order. A price is changed on the order itself.'
                        else 'Lower it here, or raise more against the order. A price is changed on the order itself.'
                   end;
  end if;

  -- Stock coming in is valued at the price on its line, as
  -- erp.add_document_line() says; a supplier's samples carry none.
  select bt.flow = 'inbound' and bt.affects_stock into v_valued
    from erp_ref.document_type bt where bt.code = v_base;
  if coalesce(v_valued, false) and v_price = 0 and not erp.is_sample_receipt(l.document_id) then
    raise exception
      'CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE: % on % has no price, and no '
      'agreed price is on record for this supplier and product',
      coalesce((select i.code from erp.item i
                 where i.tenant_id = v_tenant and i.id = l.item_id), 'the product'),
      d.document_number
      using errcode = '23514',
            hint = 'Put the price you are being charged on the line, or agree a '
                   'price with this supplier on the Item suppliers screen so '
                   'every line fills itself.';
  end if;

  -- Wording: none given keeps the line's; an empty one goes back to the
  -- product's own; anything else stands as typed.
  v_desc := case
              when p_description is null then l.description
              when btrim(p_description, E' \t\r\n') = '' then erp.line_description(l.item_id, null)
              else p_description
            end;

  update erp.document_line
     set quantity = p_quantity,
         unit_price_minor = v_price,
         description = v_desc,
         net_minor = round(p_quantity * v_price * (1 - coalesce(discount_pct, 0) / 100.0))::bigint,
         updated_at = now()
   where tenant_id = v_tenant and id = p_line_id;

  -- What the line was raised against follows it: a receipt or delivery line's
  -- order line, and a bill line's order line, with its three-way match asked
  -- again where it is a purchase order's.
  for r in
    select rel.id, rel.relation_kind::text as kind, rel.to_line_id,
           odt.base_type_code as to_base
      from erp.document_relation rel
      left join erp.document_line ol on ol.tenant_id = rel.tenant_id and ol.id = rel.to_line_id
      left join erp.document o on o.tenant_id = ol.tenant_id and o.id = ol.document_id
      left join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where rel.tenant_id = v_tenant and rel.from_line_id = p_line_id
       and rel.relation_kind in ('fulfils', 'invoices')
  loop
    update erp.document_relation set quantity = p_quantity
     where tenant_id = v_tenant and id = r.id;
    if r.to_line_id is not null then
      if r.kind = 'invoices' and r.to_base = 'purchase_order' then
        perform erp.match_three_way(r.to_line_id);
      else
        perform erp.refresh_order_line_progress(r.to_line_id);
      end if;
    end if;
  end loop;

  perform erp.release_what_hangs_off_a_line(p_line_id);

  return jsonb_build_object(
    'line_id', p_line_id,
    'quantity', p_quantity,
    'unit_price_minor', v_price,
    'net_minor', (select x.net_minor from erp.document_line x where x.tenant_id = v_tenant and x.id = p_line_id),
    'document_total_minor', erp.document_value_minor(l.document_id));
end;
$$;

create or replace function erp.remove_document_line(p_line_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  v_perm   text;
  r        record;
begin
  select * into l from erp.document_line
   where tenant_id = v_tenant and id = p_line_id and not coalesce(is_cancelled, false);
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;

  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  select coalesce(dt.create_permission, bt.create_permission) into v_perm
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_tenant and dt.id = d.document_type_id;

  perform erp.authorise(v_perm, d.entity_id, d.site_id, null, 'document_line', p_line_id);

  perform erp.require_lines_open(l.document_id);

  if d.order_behaviour_code = 'drop_ship' then
    raise exception
      'CLOVEERP_DROP_SHIP_LINE_FOLLOWS_ITS_SALE: % is delivered by the supplier to the customer, and its lines are the sale''s',
      d.document_number
      using errcode = '23514',
            hint = 'Change the customer''s order, and raise the supplier''s order from it again.';
  end if;

  -- Removed, not deleted, as a line of a vendor quote is removed
  -- (erp.remove_quote_line): the totals, the fingerprint an approval is
  -- judged against, conversion and posting already pass a cancelled line by.
  update erp.document_line
     set is_cancelled = true, line_state = 'cancelled', updated_at = now()
   where tenant_id = v_tenant and id = p_line_id;

  -- The relations the line itself raised. A draft line nobody committed
  -- fulfils, bills or converts nothing; deleting them keeps every sum over
  -- relations right without teaching each reader about cancelled lines, and
  -- the audit trail keeps what they were. What they pointed at is read again.
  for r in
    with gone as (
      delete from erp.document_relation rel
       where rel.tenant_id = v_tenant and rel.from_line_id = p_line_id
       returning rel.relation_kind::text as kind, rel.to_line_id
    )
    select distinct g.kind, g.to_line_id, odt.base_type_code as to_base
      from gone g
      left join erp.document_line ol on ol.tenant_id = v_tenant and ol.id = g.to_line_id
      left join erp.document o on o.tenant_id = ol.tenant_id and o.id = ol.document_id
      left join erp.document_type odt on odt.tenant_id = o.tenant_id and odt.id = o.document_type_id
     where g.to_line_id is not null and g.kind in ('fulfils', 'invoices')
  loop
    if r.kind = 'invoices' and r.to_base = 'purchase_order' then
      perform erp.match_three_way(r.to_line_id);
    else
      perform erp.refresh_order_line_progress(r.to_line_id);
    end if;
  end loop;

  perform erp.release_what_hangs_off_a_line(p_line_id);

  return jsonb_build_object(
    'line_id', p_line_id,
    'document_id', l.document_id,
    'document_total_minor', erp.document_value_minor(l.document_id));
end;
$$;

create or replace function erp.release_what_hangs_off_a_line(p_line_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_doc    uuid;
begin
  select l.document_id into v_doc
    from erp.document_line l where l.tenant_id = v_tenant and l.id = p_line_id;

  -- The reservation was made for the old line, so it is released rather than
  -- left holding stock the line no longer wants, as erp.amend_document_line()
  -- does. Reserving again is the caller's next step.
  update erp.allocation
     set status = 'cancelled', updated_at = now()
   where tenant_id = v_tenant and document_line_id = p_line_id
     and status in ('reserved', 'committed');

  -- A margin approval asked of the line's old price is for a price it no
  -- longer holds. Repricing asks again where the new one needs it.
  update erp.approval_task t
     set status = 'cancelled', updated_at = now()
    from erp.approval_request q
   where t.tenant_id = v_tenant and q.tenant_id = v_tenant
     and t.approval_request_id = q.id
     and q.object_type = 'document_line' and q.object_id = p_line_id
     and q.status = 'pending' and t.status = 'pending';
  update erp.approval_request
     set status = 'cancelled', decided_at = now(),
         decision_note = 'The line was changed while its document was a draft.',
         updated_at = now()
   where tenant_id = v_tenant and object_type = 'document_line' and object_id = p_line_id
     and status = 'pending';

  -- Tax a supplier stated on their bill is apportioned over its lines by
  -- value (erp.state_supplier_tax); once a line changes the shares are wrong,
  -- so it is taken off every line, to be stated again.
  if exists (select 1 from erp.tax_determination td
              where td.tenant_id = v_tenant and td.document_id = v_doc
                and td.rule_code = 'supplier_stated'
                and td.journal_line_id is null) then
    delete from erp.tax_determination td
     where td.tenant_id = v_tenant and td.document_id = v_doc
       and td.rule_code = 'supplier_stated'
       and td.journal_line_id is null;
    update erp.document_line
       set tax_code = null, tax_rate_pct = null, tax_minor = null, updated_at = now()
     where tenant_id = v_tenant and document_id = v_doc;
  end if;
end;
$$;

revoke all on function erp.change_document_line(uuid, numeric, bigint, text) from public, anon;
revoke all on function erp.remove_document_line(uuid) from public, anon;
revoke all on function erp.release_what_hangs_off_a_line(uuid) from public, anon;

comment on function erp.change_document_line(uuid, numeric, bigint, text) is
  'Changes a draft line''s quantity, price or wording under the permission its document type is raised with, '
  'keeping its order line, three-way match, reservation, margin approval and stated tax true (20261006101000).';
comment on function erp.remove_document_line(uuid) is
  'Removes a draft line under the permission its document type is raised with: marks it cancelled, deletes the '
  'relations it raised and reads again what they pointed at (20261006101000).';
comment on function erp.release_what_hangs_off_a_line(uuid) is
  'After a draft line changes or goes: its reservation released, a margin approval waiting on it withdrawn, and '
  'tax a supplier stated on its document taken off to be stated again (20261006101000).';

create or replace function public.erp_change_document_line(
  p_line_id uuid,
  p_quantity numeric,
  p_unit_price_minor bigint default null,
  p_description text default null)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.change_document_line(p_line_id, p_quantity, p_unit_price_minor, p_description) $$;

create or replace function public.erp_remove_document_line(p_line_id uuid)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.remove_document_line(p_line_id) $$;

revoke all on function public.erp_change_document_line(uuid, numeric, bigint, text) from public, anon;
grant execute on function public.erp_change_document_line(uuid, numeric, bigint, text) to authenticated, service_role;
revoke all on function public.erp_remove_document_line(uuid) from public, anon;
grant execute on function public.erp_remove_document_line(uuid) to authenticated, service_role;

comment on function public.erp_change_document_line(uuid, numeric, bigint, text) is
  'Changes a line of a draft (20261006101000). Authorises the permission the document''s type is raised with.';
comment on function public.erp_remove_document_line(uuid) is
  'Removes a line of a draft (20261006101000). Authorises the permission the document''s type is raised with.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_change_document_line', 'erp.change_document_line',
   'Changes a line of a draft under the permission its type is raised with; refuses past draft, committed, '
   'cancelled, routine-written and drop-ship documents.'),
  ('erp_remove_document_line', 'erp.remove_document_line',
   'Removes a line of a draft under the permission its type is raised with; refuses past draft, committed, '
   'cancelled, routine-written and drop-ship documents.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The document says whether its lines are open
-- ═════════════════════════════════════════════════════════════════════════════

do $document$
declare
  v_sig   constant text := 'public.erp_document(uuid)';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_a_old constant text := $a$        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed)$a$;
  v_a_new constant text := $a$        'state', s.code, 'state_name', s.name, 'is_committed', s.is_committed,
        -- Whether its lines may change, and whether its lifecycle has ended
        -- (20261006101000): the page draws its line controls on the first,
        -- and says a finished document has finished on the second.
        'is_terminal', coalesce(s.is_terminal, false),
        'lines_open', erp.document_lines_open(d.id))$a$;
  v_b_old constant text := $b$       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id), '[]'::jsonb),$b$;
  v_b_new constant text := $b$       where l.tenant_id = erp.current_tenant_id() and l.document_id = p_document_id
         -- A removed line is gone from the document (20261006101000).
         and not coalesce(l.is_cancelled, false)), '[]'::jsonb),$b$;
begin
  if strpos(v_src, '20261006101000') > 0 then
    raise notice '% already says whether its lines are open; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'b730882a690a0ad497cc93d79aed539a' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006101000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_a_old, ''))) / length(v_a_old) <> 1
     or (length(v_def) - length(replace(v_def, v_b_old, ''))) / length(v_b_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_a_old, v_a_new), v_b_old, v_b_new);
end
$document$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The words the screens say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A draft line is changed and removed (20261006101000).'
  from (values
    ('Change this line'),
    ('The price stays as it is unless you type a new one.'),
    ('Remove this line?'),
    ('It comes off the draft, and anything it was raised from is open again.'),
    ('Lines change only on a draft.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.draft_line_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_item2 uuid; v_sa uuid; v_cust uuid;
  v_po     uuid; v_pl1 uuid; v_pl2 uuid;
  v_so     uuid; v_sl uuid;
  v_qt     uuid; v_ql uuid;
  v_spo    uuid; v_spol uuid;
  v_g      uuid; v_gl uuid; v_g2 uuid; v_g3 uuid; v_g3l uuid;
  v_bill   uuid; v_bl uuid;
  v_dpo    uuid; v_dpl uuid;
  v_alloc  uuid;
  v_role   uuid; v_other uuid; v_other_tok text;
  v_val0   bigint; v_val1 bigint; v_val2 bigint;
  v_open   numeric;
  v_err    text; v_err2 text; v_err3 text; v_err4 text;
  v_cancel text;
  v_lines  jsonb;
  v_n      integer;
begin
  begin
    -- ── The fixture ───────────────────────────────────────────────────────────
    v_step := 'an organisation that buys and sells, not yet live';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdln-' || v_tag, 'Draft Line Suite',
      'admin@zzdln-' || v_tag || '.test', 'Line Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdln-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.decimals = 0 order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, description, stock_uom_id, status)
    values (rb.tenant_id, 'ZDLCOAT', 'Draft Coat', 'A coat for the draft line suite', v_uom, 'active')
    returning id into v_item;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZDLSCARF', 'Draft Scarf', v_uom, 'active') returning id into v_item2;
    v_sa := erp_test.cash_payment_supplier('ZDLBRAND');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZDLCUST', 'Draft Line Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');

    -- ── 1. A draft purchase order's line changes ──────────────────────────────
    v_step := 'changing a draft purchase order''s line';
    v_po := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    v_pl1 := erp.add_document_line(v_po, v_item, 10, 9000, 'Ten coats');
    v_pl2 := erp.add_document_line(v_po, v_item2, 4, 1500, 'Four scarves');
    v_val0 := erp.document_value_minor(v_po);
    res := public.erp_change_document_line(v_pl1, 12, 8500, 'Twelve coats');
    v_val1 := erp.document_value_minor(v_po);
    v_cases := v_cases + 1;
    case_name := 'a draft purchase order''s line takes a new quantity, price and wording, and the order''s value follows';
    passed := v_state is null and v_val0 = 96000 and v_val1 = 108000
          and (res ->> 'net_minor')::bigint = 102000
          and (res ->> 'document_total_minor')::bigint = 108000
          and (select l.description from erp.document_line l where l.id = v_pl1) = 'Twelve coats';
    detail := coalesce(v_state, format('value %s then %s; line %s', v_val0, v_val1, res));
    return next;

    -- ── 2. A typed price survives a quantity change ───────────────────────────
    v_step := 'changing only the quantity';
    res := public.erp_change_document_line(v_pl1, 5, null, null);
    v_cases := v_cases + 1;
    case_name := 'a quantity changed alone keeps the price somebody typed and the wording';
    passed := v_state is null
          and (select l.unit_price_minor from erp.document_line l where l.id = v_pl1) = 8500
          and (select l.net_minor from erp.document_line l where l.id = v_pl1) = 42500
          and (select l.description from erp.document_line l where l.id = v_pl1) = 'Twelve coats';
    detail := coalesce(v_state, res::text);
    return next;

    -- ── 3. A draft sales order's wording goes back to the product's ───────────
    v_step := 'changing a draft sales order''s line';
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    v_sl := erp.add_document_line(v_so, v_item, 2, 20000, 'As agreed on the phone');
    res := public.erp_change_document_line(v_sl, 3, null, '');
    v_cases := v_cases + 1;
    case_name := 'a draft sales order''s line changes too, and empty wording goes back to the product''s own';
    passed := v_state is null
          and (select l.description from erp.document_line l where l.id = v_sl) = 'A coat for the draft line suite'
          and erp.document_value_minor(v_so) = 60000;
    detail := coalesce(v_state, format('%s; value %s',
                (select l.description from erp.document_line l where l.id = v_sl), erp.document_value_minor(v_so)));
    return next;

    -- ── 4. A line is removed ──────────────────────────────────────────────────
    v_step := 'removing a draft line';
    res := public.erp_remove_document_line(v_pl2);
    v_lines := public.erp_document(v_po);
    v_cases := v_cases + 1;
    case_name := 'a removed line leaves the draft: the document no longer lists it, and its value drops';
    passed := v_state is null
          and (res ->> 'document_total_minor')::bigint = 42500
          and erp.document_value_minor(v_po) = 42500
          and jsonb_array_length(v_lines -> 'lines') = 1
          and not exists (select 1 from jsonb_array_elements(v_lines -> 'lines') x where (x ->> 'line_id')::uuid = v_pl2)
          and (v_lines -> 'document' ->> 'lines_open')::boolean
          and (select l.is_cancelled from erp.document_line l where l.id = v_pl2);
    detail := coalesce(v_state, format('%s line(s) listed; value %s; open %s', jsonb_array_length(v_lines -> 'lines'),
                erp.document_value_minor(v_po), v_lines -> 'document' ->> 'lines_open'));
    return next;

    -- ── 5. What a change of nothing, or of a part, is refused ─────────────────
    v_step := 'a quantity of nothing, and part of an each';
    begin
      perform public.erp_change_document_line(v_pl1, 0, null, null);
      v_err := 'changed to nothing';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_change_document_line(v_pl1, 1.5, null, null);
      v_err2 := 'changed to a part';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_change_document_line(v_pl2, 3, null, null);
      v_err3 := 'the removed line changed';
    exception when others then v_err3 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'a quantity of nothing, a part of something counted whole, and a removed line are refused by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_LINE_NEEDS_A_QUANTITY%'
          and v_err2 like 'CLOVEERP_QUANTITY_TOO_PRECISE%'
          and v_err3 like 'CLOVEERP_UNKNOWN_LINE%';
    detail := coalesce(v_state, format('nothing: %s; part: %s; removed: %s', v_err, v_err2, v_err3));
    return next;

    -- ── 6. Past draft ─────────────────────────────────────────────────────────
    v_step := 'a quotation sent to its customer';
    v_qt := erp.open_document('quotation', v_cust, v_entity, v_site);
    v_ql := erp.add_document_line(v_qt, v_item, 1, 20000, 'One coat');
    perform erp.transition_document(v_qt, 'send', null);
    v_err := null; v_err2 := null;
    begin
      perform public.erp_change_document_line(v_ql, 2, null, null);
      v_err := 'changed';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_remove_document_line(v_ql);
      v_err2 := 'removed';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'a quotation once sent keeps its lines: changing and removing are refused, and the document says its lines are closed';
    passed := v_state is null
          and v_err like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
          and v_err2 like 'CLOVEERP_LINES_CHANGED_ONLY_AS_A_DRAFT%'
          and not (public.erp_document(v_qt) -> 'document' ->> 'lines_open')::boolean;
    detail := coalesce(v_state, format('change: %s; remove: %s', v_err, v_err2));
    return next;

    -- ── 7. Committed ──────────────────────────────────────────────────────────
    v_step := 'an order sent to the supplier';
    v_spo := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZDLO1', true);
    select l.id into v_spol from erp.document_line l where l.document_id = v_spo order by l.line_no limit 1;
    v_err := null; v_err2 := null;
    begin
      perform public.erp_change_document_line(v_spol, 9, null, null);
      v_err := 'changed';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_remove_document_line(v_spol);
      v_err2 := 'removed';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'an order sent to the supplier is committed: its lines are amended, not changed or removed';
    passed := v_state is null
          and v_err like 'CLOVEERP_DOCUMENT_COMMITTED%'
          and v_err2 like 'CLOVEERP_DOCUMENT_COMMITTED%';
    detail := coalesce(v_state, format('change: %s; remove: %s', v_err, v_err2));
    return next;

    -- ── 8. A receipt line raised against the order comes down only ────────────
    v_step := 'a draft receipt for six of the ten';
    v_g := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    v_gl := erp.receive_against(v_g, v_spol, 6, null);
    res := public.erp_change_document_line(v_gl, 4, null, null);
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_spo)) x;
    v_err := null; v_err2 := null;
    begin
      perform public.erp_change_document_line(v_gl, 7, null, null);
      v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_change_document_line(v_gl, 4, 8000, null);
      v_err2 := 'repriced';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'a draft receipt line lowered takes its order line with it; raising it or changing its price is refused';
    passed := v_state is null
          and (select rel.quantity from erp.document_relation rel
                where rel.from_line_id = v_gl and rel.relation_kind = 'fulfils') = 4
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol) = 4
          and v_open = 6
          and v_err like 'CLOVEERP_FULFILLING_LINE_ONLY_LOWERED%'
          and v_err2 like 'CLOVEERP_FULFILLING_LINE_ONLY_LOWERED%';
    detail := coalesce(v_state, format('relation %s; fulfilled %s; open %s; raise: %s; price: %s',
                (select rel.quantity from erp.document_relation rel
                  where rel.from_line_id = v_gl and rel.relation_kind = 'fulfils'),
                (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol), v_open, v_err, v_err2));
    return next;

    -- ── 9. Removed, the order line is open again ──────────────────────────────
    v_step := 'removing the draft receipt''s line';
    perform public.erp_remove_document_line(v_gl);
    select coalesce(sum((x ->> 'open_quantity')::numeric), 0) into v_open
      from jsonb_array_elements(public.erp_receivable_lines(v_spo)) x;
    v_cases := v_cases + 1;
    case_name := 'removing a draft receipt''s line deletes what it was raised against, and the order line is open again';
    passed := v_state is null and v_open = 10
          and not exists (select 1 from erp.document_relation rel where rel.from_line_id = v_gl)
          and (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol) = 0;
    detail := coalesce(v_state, format('open %s; fulfilled %s', v_open,
                (select l.quantity_fulfilled from erp.document_line l where l.id = v_spol)));
    return next;

    -- ── 10. A cancelled receipt, and a receipt line at nought ─────────────────
    v_step := 'a receipt its lifecycle cancelled, and a received line at nought';
    v_g3 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    v_g3l := erp.add_document_line(v_g3, v_item2, 2, 1500, 'Two scarves');
    v_err := null;
    begin
      perform public.erp_change_document_line(v_g3l, 2, 0, null);
      v_err := 'taken at nought';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    select x ->> 'code' into v_cancel
      from jsonb_array_elements(public.erp_available_transitions(v_g3)) x
     where x ->> 'to_state' = 'cancelled' limit 1;
    perform erp.transition_document(v_g3, v_cancel, 'the lorry was turned away');
    v_err2 := null;
    begin
      perform public.erp_remove_document_line(v_g3l);
      v_err2 := 'removed';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'a received line is not put at nought, and a receipt its lifecycle cancelled keeps its lines, said cancelled';
    passed := v_state is null and v_cancel is not null
          and v_err like 'CLOVEERP_RECEIVED_LINE_HAS_NO_PRICE%'
          and v_err2 like 'CLOVEERP_DOCUMENT_CANCELLED%'
          and not (public.erp_document(v_g3) -> 'document' ->> 'lines_open')::boolean
          and (public.erp_document(v_g3) -> 'document' ->> 'is_terminal')::boolean;
    detail := coalesce(v_state, format('nought: %s; cancelled by %s: %s', v_err, coalesce(v_cancel, 'no move'), v_err2));
    return next;

    -- ── 11. A draft bill line ─────────────────────────────────────────────────
    v_step := 'a draft bill for five received';
    v_g2 := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    perform erp.receive_against(v_g2, v_spol, 5, null);
    perform erp.transition_document(v_g2, 'post', null);
    v_bill := erp.bill_from_receipt(v_g2, 'ZDLB-' || v_tag, current_date, current_date + 30, false);
    select l.id into v_bl from erp.document_line l
     where l.document_id = v_bill and not l.is_cancelled order by l.line_no limit 1;
    perform erp.state_supplier_tax(v_bill, 9000, 'S', 'their invoice');
    v_n := (select count(*) from erp.tax_determination td where td.document_id = v_bill);
    res := public.erp_change_document_line(v_bl, 3, null, null);
    v_cases := v_cases + 1;
    case_name := 'a draft bill line changed moves its match with it and takes off the tax the supplier stated, to be stated again';
    passed := v_state is null and v_n = 1
          and (select rel.quantity from erp.document_relation rel
                where rel.from_line_id = v_bl and rel.relation_kind = 'invoices') = 3
          and (select l.quantity_invoiced from erp.document_line l where l.id = v_spol) = 3
          and not exists (select 1 from erp.tax_determination td where td.document_id = v_bill)
          and (select l.tax_minor from erp.document_line l where l.id = v_bl) is null;
    detail := coalesce(v_state, format('stated on %s line(s); relation %s; invoiced %s; determinations left %s',
                v_n, (select rel.quantity from erp.document_relation rel
                       where rel.from_line_id = v_bl and rel.relation_kind = 'invoices'),
                (select l.quantity_invoiced from erp.document_line l where l.id = v_spol),
                (select count(*) from erp.tax_determination td where td.document_id = v_bill)));
    return next;

    -- ── 12. A reservation on a changed line ───────────────────────────────────
    v_step := 'a reservation on a draft sales line';
    insert into erp.allocation (tenant_id, entity_id, site_id, item_id, document_id, document_line_id,
                                demand_kind, quantity, uom_id, status)
    values (rb.tenant_id, v_entity, v_site, v_item, v_so, v_sl, 'sales_order', 3, v_uom, 'reserved')
    returning id into v_alloc;
    perform public.erp_change_document_line(v_sl, 2, null, null);
    v_cases := v_cases + 1;
    case_name := 'a reservation on a changed line is released, as an amendment releases it';
    passed := v_state is null
          and (select a.status::text from erp.allocation a where a.id = v_alloc) = 'cancelled';
    detail := coalesce(v_state, (select a.status::text from erp.allocation a where a.id = v_alloc));
    return next;

    -- ── 13. A drop-ship order ─────────────────────────────────────────────────
    v_step := 'a draft order the supplier delivers to the customer';
    v_dpo := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    v_dpl := erp.add_document_line(v_dpo, v_item, 1, 9000, 'One coat');
    update erp.document set order_behaviour_code = 'drop_ship' where id = v_dpo;
    v_err := null; v_err2 := null;
    begin
      perform public.erp_change_document_line(v_dpl, 2, null, null);
      v_err := 'changed';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_remove_document_line(v_dpl);
      v_err2 := 'removed';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    v_cases := v_cases + 1;
    case_name := 'a drop-ship order''s lines follow its sale, and are not changed or removed on their own';
    passed := v_state is null
          and v_err like 'CLOVEERP_DROP_SHIP_LINE_FOLLOWS_ITS_SALE%'
          and v_err2 like 'CLOVEERP_DROP_SHIP_LINE_FOLLOWS_ITS_SALE%';
    detail := coalesce(v_state, format('change: %s; remove: %s', v_err, v_err2));
    return next;

    -- ── 14. Somebody who may not raise the order ──────────────────────────────
    v_step := 'a person who reads orders and raises none';
    insert into erp.role (tenant_id, code, name, status)
    values (rb.tenant_id, 'zz_dl_reader', 'Draft line reader', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (rb.tenant_id, v_role, 'procurement.read'),
      (rb.tenant_id, v_role, 'sales.read');
    res := public.erp_invite_principal('reader@zzdln-' || v_tag || '.test', 'Rita Reader');
    v_other := (res ->> 'app_user_id')::uuid;
    v_other_tok := res ->> 'token';
    perform erp.grant_role(v_other, 'zz_dl_reader', null, null, 'reads orders and nothing else');
    insert into auth.users (id, email) values (a2, 'reader@zzdln-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_other_tok);
    v_err := null; v_err2 := null;
    begin
      perform public.erp_change_document_line(v_pl1, 6, null, null);
      v_err := 'changed';
    exception when others then v_err := left(sqlerrm, 200);
    end;
    begin
      perform public.erp_remove_document_line(v_sl);
      v_err2 := 'removed';
    exception when others then v_err2 := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'somebody without the permission the document''s type is raised with may neither change nor remove its lines';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED: procurement.order%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED: sales.order%'
          and (select l.quantity from erp.document_line l where l.id = v_pl1) = 5;
    detail := coalesce(v_state, format('change: %s; remove: %s', v_err, v_err2));
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
    raise exception 'CLOVEERP_DRAFT_LINE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.draft_line_suite() from public, anon;

comment on function erp_test.draft_line_suite() is
  'A draft line is changed and removed (20261006101000): quantity, price and wording on a draft order, what '
  'hangs off a line kept true, and every document past draft, committed, cancelled or drop-ship refused.';

create or replace function erp_test.assert_draft_line_suite()
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
    from erp_test.draft_line_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DRAFT_LINE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A draft line would change without what hangs off it, or a line past draft would change. Read the case that failed.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_DRAFT_LINE_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('draft line: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_draft_line_suite() from public, anon;

comment on function erp_test.assert_draft_line_suite() is
  'A draft line is changed and removed with what hangs off it kept true, and nothing past draft is (20261006101000).';

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
