-- =============================================================================
-- An order form shows the customer its price
--
-- The order form a customer signs is the quote rendered through the order_form
-- template when it is issued. Reading it end to end on 14 September found
-- three things wrong with what it and the invoice after it tell a customer.
--
--   1. It told the customer what the quote cost us and what we make on it.
--      erp.issue_quote() added `erp.quote_margin(...) - 'lines'` to the render:
--      the totals of the margin reader, with cost_minor, margin_minor,
--      margin_pct, below_cost_lines and the discount approval threshold in
--      them. erp.create_contract_from_quote() copies that render into
--      erp_meta.contract_document, and a customer's administrators read it in
--      full through erp_my_contract_document on Your agreement. Removing
--      'lines' was meant to keep the internal figures back; every figure that
--      mattered was in 'totals'.
--
--      A new render names what it shows instead of subtracting what it should
--      not: erp.order_form_pricing() builds each line's list price, discount
--      and net, and the totals, field by field from the margin reader, so a
--      field added to the margin reader later cannot ride along.
--
--      The order forms already issued stay as they are. erp.output_render is
--      append-only (erp.forbid_mutation refuses an update outside an erasure),
--      and the contract's copy is what both parties signed, held with the
--      checksum of exactly that text, so rewriting either would falsify the
--      record the signature stands on. A one-off redaction is therefore not
--      right. erp.my_contract_document() strips instead: when it reads an
--      order form it drops every key naming a cost or a margin, at any depth,
--      and the discount threshold. A document with nothing to drop is returned
--      exactly as stored, so its checksum still matches. The platform console
--      still reads the archive whole.
--
--   2. Its lines ignored discounts. erp.add_document_line() writes net_minor
--      as quantity times price, and nothing on a commercial quote wrote it
--      again: not a discount (add_quote_line, set_quote_line_discount,
--      revise_quote) and not a repricing (Priority support, reprice_quote).
--      Elsewhere in the product net_minor is after the line's discount, so the
--      template drew a list price as the net and totalled the list. Now
--      erp.net_quote_lines() writes each line's net after its discount, rounded
--      as erp.quote_margin() rounds it, whenever a quote is repriced and once
--      more when it is issued, and the lines block shows the discount beside
--      the price. The order form's totals are the quote's.
--
--   3. A contract invoice fell due on the first day of its period, which it was
--      usually issued on or after. The owner decided on 14 September: payment
--      is due fourteen days from issue, and Clove ERP Ltd is not registered for
--      VAT, so no VAT is charged and the invoice says so. Both terms live in
--      erp.contract_invoice_terms() and nowhere else. erp.issue_contract_invoice()
--      sets due_on from it and records the statement on the invoice, and the
--      customer's own view of its invoices carries it. There is no VAT line.
--      Invoices issued before this keep the due date and wording they were
--      issued with.
--
-- erp_test.order_form_shows_the_price_suite proves each of these from a quote
-- built on the list, through a contract, to the customer's own reading of the
-- order form and the invoice.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1–2. What a new order form shows
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.net_quote_lines(p_document_id uuid)
returns integer
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  -- A line's net is its price after its discount, rounded the way
  -- erp.quote_margin() rounds it: the unit price after discount, then times
  -- the quantity. Only a commercial quote's lines, and only where the net
  -- differs, so a quote nobody changed is not touched.
  update erp.document_line l
     set net_minor = round(round(l.unit_price_minor * (1 - coalesce(l.discount_pct, 0) / 100.0)) * l.quantity)::bigint,
         updated_at = now()
   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
     and l.net_minor is distinct from round(round(l.unit_price_minor * (1 - coalesce(l.discount_pct, 0) / 100.0)) * l.quantity)::bigint
     and exists (select 1 from erp.commercial_quote cq where cq.tenant_id = v_tenant and cq.document_id = p_document_id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function erp.net_quote_lines(uuid) is
  'Writes each live line of a commercial quote''s net after its discount, '
  'rounded as erp.quote_margin() rounds it, so the order form''s lines add up to '
  'the quote''s total. Run when a quote is repriced and when it is issued.';

create or replace function erp.order_form_pricing(p_document_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What an order form tells the customer about price, named field by field
  -- from erp.quote_margin(): each line's list price, discount and net after
  -- that discount, and the totals. Cost and margin are never named here, so a
  -- field the margin reader gains later does not reach a customer.
  with m as (select erp.quote_margin(p_document_id) as v)
  select jsonb_build_object(
    'currency', m.v -> 'currency',
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line_no', x -> 'line_no',
               'item_code', x -> 'item_code',
               'description', x -> 'name',
               'quantity', x -> 'quantity',
               'unit_price_minor', x -> 'list_minor',
               'discount_pct', to_jsonb(coalesce((x ->> 'discount_pct')::numeric, 0)),
               'unit_net_minor', x -> 'quoted_unit_minor',
               'net_minor', x -> 'quoted_minor',
               'charge', to_jsonb(coalesce(x ->> 'charge', 'recurring')))
             order by (x ->> 'line_no')::integer)
        from jsonb_array_elements(m.v -> 'lines') x), '[]'::jsonb),
    'totals', jsonb_build_object(
      'list_minor', m.v -> 'totals' -> 'list_minor',
      'discount_minor', to_jsonb(coalesce((m.v -> 'totals' ->> 'list_minor')::bigint, 0)
                                 - coalesce((m.v -> 'totals' ->> 'quoted_minor')::bigint, 0)),
      'net_minor', m.v -> 'totals' -> 'quoted_minor',
      'recurring_minor', m.v -> 'totals' -> 'recurring_minor',
      'one_off_minor', m.v -> 'totals' -> 'one_off_minor'))
    from m
$$;

comment on function erp.order_form_pricing(uuid) is
  'The price an order form shows its customer: every line''s list price, '
  'discount and net after discount, and the totals, projected by name from '
  'erp.quote_margin(). Carries no cost and no margin.';

create or replace function erp.order_form_shows_discounts(p_render jsonb, p_document_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The order_form template's lines block draws each line's price and net, and
  -- the net is after the line's discount. The block shows that discount too,
  -- as a column just before the net, so price times quantity is not left to
  -- disagree with the net on the page.
  select case
    when coalesce(jsonb_typeof(p_render -> 'blocks'), '') <> 'array' then p_render
    else jsonb_set(p_render, '{blocks}', coalesce((
      select jsonb_agg(
               case when b.block ->> 'kind' = 'lines' then
                 b.block || jsonb_build_object(
                   'rows', coalesce((
                     select jsonb_agg(r.row_obj || jsonb_build_object('discount_pct', coalesce(l.discount_pct, 0)) order by r.n)
                       from jsonb_array_elements(coalesce(b.block -> 'rows', '[]'::jsonb)) with ordinality as r(row_obj, n)
                       left join erp.document_line l
                         on l.tenant_id = erp.require_tenant_id() and l.document_id = p_document_id
                        and not l.is_cancelled and l.line_no = (r.row_obj ->> 'line_no')::integer), '[]'::jsonb),
                   'columns', coalesce((
                     select jsonb_agg(c.col order by c.pos)
                       from (select x.col, x.n::numeric as pos
                               from jsonb_array_elements(coalesce(b.block -> 'columns', '[]'::jsonb)) with ordinality as x(col, n)
                             union all
                             select jsonb_build_object('field', 'discount_pct', 'label', 'Discount %'),
                                    coalesce((select y.n - 0.5
                                                from jsonb_array_elements(coalesce(b.block -> 'columns', '[]'::jsonb)) with ordinality as y(col, n)
                                               where y.col ->> 'field' = 'net_amount'
                                               limit 1), 1000000::numeric)) c), '[]'::jsonb))
               else b.block end
               order by b.n)
        from jsonb_array_elements(p_render -> 'blocks') with ordinality as b(block, n)), '[]'::jsonb))
  end
$$;

comment on function erp.order_form_shows_discounts(jsonb, uuid) is
  'Adds each line''s discount to the lines block of a rendered order form, as '
  'a value on every row and a column before the net.';

-- A repriced quote's nets are after discount.
do $reprice$
declare
  v_sig    constant text := 'erp.reprice_quote(uuid)';
  v_def    text := pg_get_functiondef('erp.reprice_quote(uuid)'::regprocedure);
  v_needle constant text := E'  end loop;\nend;';
  v_new    constant text := E'  end loop;\n  -- Every line''s net is after its discount (20260914093000).\n  perform erp.net_quote_lines(p_document_id);\nend;';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not end its one loop exactly once, so it is not the 20260914079000 body', v_sig
      using hint = 'A later migration changed how a quote is repriced. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('perform erp.net_quote_lines(p_document_id);' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$reprice$;

-- An issued order form carries the price, and never the margin.
do $issue$
declare
  v_sig    constant text := 'erp.issue_quote(uuid)';
  v_def    text := pg_get_functiondef('erp.issue_quote(uuid)'::regprocedure);
  v_needle constant text := $n$  v_render := erp.render_output_template('order_form', p_document_id, 'en')
              || jsonb_build_object('quote_version', q.version, 'price_book', q.price_book_code || ' v' || q.price_book_version,
                                    'term_kind', q.term_kind, 'term_months', q.term_months, 'valid_until', q.valid_until,
                                    'margin', erp.quote_margin(p_document_id) - 'lines');$n$;
  v_new    constant text := $n$  -- The customer is shown the price, never what it costs us or what we make
  -- (20260914093000). Each line's net is after its discount before the form is
  -- drawn, the lines block shows that discount, and the pricing is named field
  -- by field rather than the margin reader with its lines taken off.
  perform erp.net_quote_lines(p_document_id);
  v_render := erp.order_form_shows_discounts(erp.render_output_template('order_form', p_document_id, 'en'), p_document_id)
              || jsonb_build_object('quote_version', q.version, 'price_book', q.price_book_code || ' v' || q.price_book_version,
                                    'term_kind', q.term_kind, 'term_months', q.term_months, 'valid_until', q.valid_until,
                                    'pricing', erp.order_form_pricing(p_document_id));$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not render the order form with the margin exactly once, so it is not the 20260904600000 body', v_sig
      using hint = 'A later migration changed how the order form is rendered. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('erp.quote_margin' in pg_get_functiondef(v_sig::regprocedure)) > 0
     or position('erp.order_form_pricing(p_document_id)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$issue$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What a customer reads of an order form already issued
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.without_cost_or_margin(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
begin
  -- Every key naming a cost or a margin, at any depth, and the discount
  -- threshold our approvals route on, is dropped. Everything else is returned
  -- as it was, in the order it was.
  case jsonb_typeof(p_value)
    when 'object' then
      return coalesce((select jsonb_object_agg(e.key, erp.without_cost_or_margin(e.value))
                         from jsonb_each(p_value) e
                        where e.key !~* '(cost|margin)' and e.key <> 'threshold_pct'), '{}'::jsonb);
    when 'array' then
      return coalesce((select jsonb_agg(erp.without_cost_or_margin(a.item) order by a.n)
                         from jsonb_array_elements(p_value) with ordinality as a(item, n)), '[]'::jsonb);
    else
      return p_value;
  end case;
end;
$$;

comment on function erp.without_cost_or_margin(jsonb) is
  'A JSON value with every key naming a cost or a margin, at any depth, and '
  'threshold_pct removed.';

create or replace function erp.order_form_as_shown(p_kind text, p_content text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_held  jsonb;
  v_shown jsonb;
begin
  -- An order form is its render as JSON. Until 20260914093000 the render
  -- carried the quote's cost and margin. The archive is append-only and the
  -- contract's copy is what was signed, with its checksum, so neither is
  -- rewritten; what a customer is shown drops those keys instead. A document
  -- with nothing to drop is returned exactly as it was stored.
  if p_kind is distinct from 'order_form' or p_content is null or not pg_input_is_valid(p_content, 'jsonb') then
    return p_content;
  end if;
  v_held := p_content::jsonb;
  v_shown := erp.without_cost_or_margin(v_held);
  if v_shown = v_held then
    return p_content;
  end if;
  return v_shown::text;
end;
$$;

comment on function erp.order_form_as_shown(text, text) is
  'The text of a contract document as its customer is shown it: an order form '
  'without any cost or margin an older render carried, anything else as stored.';

do $customer_reads$
declare
  v_sig    constant text := 'erp.my_contract_document(uuid)';
  v_def    text := pg_get_functiondef('erp.my_contract_document(uuid)'::regprocedure);
  v_needle constant text := $n$'content', d.content,$n$;
  v_new    constant text := $n$'content', erp.order_form_as_shown(d.kind, d.content),$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not return the content exactly once, so it is not the 20260904620000 body', v_sig
      using hint = 'A later migration changed what the customer reads of a contract document. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('erp.order_form_as_shown(d.kind, d.content)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$customer_reads$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The terms on a contract invoice
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.contract_invoice add column if not exists tax_statement text;

comment on column erp_meta.contract_invoice.tax_statement is
  'What the invoice says about VAT, from erp.contract_invoice_terms() when it '
  'was issued. Null on an invoice not yet issued, and on one issued before '
  '20260914093000.';

create or replace function erp.contract_invoice_terms(p_supplier_legal_name text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The platform's terms on a contract invoice, held here and nowhere else.
  -- The owner, 14 September 2026: payment is due fourteen days from issue, and
  -- Clove ERP Ltd is not registered for VAT, so no VAT is charged and the
  -- invoice says so. When either changes, this changes.
  select jsonb_build_object(
    'payment_days', 14,
    'vat_registered', false,
    'tax_statement', coalesce(nullif(btrim(p_supplier_legal_name), ''), 'Clove ERP Ltd')
                     || ' is not registered for VAT; no VAT is charged.')
$$;

comment on function erp.contract_invoice_terms(text) is
  'The terms a contract invoice is issued on: the days from issue until payment '
  'is due, and the statement it makes about VAT, naming the supplier.';

do $invoice$
declare
  v_sig   constant text := 'erp.issue_contract_invoice(uuid)';
  v_def   text := pg_get_functiondef('erp.issue_contract_invoice(uuid)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$v_one_off jsonb; v_one_off_minor bigint := 0;$n$,
          $n$v_one_off jsonb; v_one_off_minor bigint := 0; v_terms jsonb; v_due date;$n$],
    array[$n$  select * into c from erp_meta.contract where id = i.contract_id;$n$,
          $n$  select * into c from erp_meta.contract where id = i.contract_id;
  -- Due fourteen days from issue, and what the invoice says about VAT, from the
  -- one place those terms are held (20260914093000).
  v_terms := erp.contract_invoice_terms(c.platform_legal_name);
  v_due := current_date + (v_terms ->> 'payment_days')::integer;$n$],
    array[$n$set status = 'issued', issued_at = now(), lines = v_lines,$n$,
          $n$set status = 'issued', issued_at = now(), due_on = v_due, tax_statement = v_terms ->> 'tax_statement', lines = v_lines,$n$],
    array[$n$'overage_minor', v_over_minor, 'lines', v_lines);$n$,
          $n$'overage_minor', v_over_minor, 'lines', v_lines,
                            'due_on', v_due, 'tax_statement', v_terms ->> 'tax_statement');$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 80)
        using hint = 'A later migration changed how an invoice is issued. Read pg_get_functiondef() of it and patch that body.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('due_on = v_due' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
end
$invoice$;

-- The customer's own view of its invoices says it too.
do $agreement$
declare
  v_sig    constant text := 'erp.my_agreement()';
  v_def    text := pg_get_functiondef('erp.my_agreement()'::regprocedure);
  v_needle constant text := $n$'issued_at', i.issued_at, 'paid_at', i.paid_at,$n$;
  v_new    constant text := $n$'issued_at', i.issued_at, 'paid_at', i.paid_at, 'tax_statement', i.tax_statement,$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not list an invoice''s dates exactly once, so it is not the 20260904620000 body', v_sig
      using hint = 'A later migration changed what the customer reads of its invoices. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('''tax_statement'', i.tax_statement' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$agreement$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.keys_naming_cost_or_margin(p_value jsonb)
returns text
language sql
stable
set search_path = ''
as $$
  -- Every key at any depth that names a cost or a margin, found by a JSON path
  -- walk rather than by the function whose work it checks.
  select string_agg(distinct k.key, ', ' order by k.key)
    from jsonb_path_query(coalesce(p_value, '{}'::jsonb), 'strict $.**') as w(item)
    cross join lateral jsonb_object_keys(case when jsonb_typeof(w.item) = 'object' then w.item else '{}'::jsonb end) as k(key)
   where k.key ~* '(cost|margin)'
$$;

create or replace function erp_test.order_form_shows_the_price_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record; rc record; ro record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_platform uuid; v_pcode text := 'zzofp-' || substr(md5(random()::text), 1, 6);
  v_customer uuid; v_ccode text := 'zzofc-' || substr(md5(random()::text), 1, 6);
  v_own uuid;      v_ocode text := 'zzofo-' || substr(md5(random()::text), 1, 6);
  v_prior erp_meta.platform_organisation;
  c_statement constant text := 'Clove ERP Ltd is not registered for VAT; no VAT is charged.';
  v_q uuid; v_contract uuid; v_form uuid; v_legacy uuid; v_inv uuid;
  m jsonb; res jsonb; v_render jsonb; v_legacy_text text; v_keys text; v_ok boolean; v_n integer;
begin
  select po.* into v_prior from erp_meta.platform_organisation po;

  select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Order Forms', 'admin@zzofp.test', 'Platform Admin');
  v_platform := rp.tenant_id;
  select * into rc from erp.provision_tenant(v_ccode, 'Order Form Customer Ltd', 'admin@zzofc.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  select * into ro from erp.provision_tenant(v_ocode, 'Order Form Owner''s Company', 'owner@zzofp.test', 'Platform Owner');
  v_own := ro.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzofp.test'), (ow, 'owner@zzofp.test'), (ca, 'admin@zzofc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzofp.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rp.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.claim_invitation(ro.admin_token);
  perform erp.designate_platform_organisation(v_pcode, 'the order form shows the price suite');

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_platform);
  perform erp.set_up_selling();
  perform erp_test.close_bootstrap_window(v_platform);

  -- ── A quote with discounts ───────────────────────────────────────────────

  v_q := erp.open_commercial_quote('OFC', 'Order Form Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_ccode);
  perform erp.add_quote_line(v_q, 'PLAN-STANDARD', 1, 10);
  perform erp.add_quote_line(v_q, 'USER-STANDARD', 10, 5);
  perform erp.add_quote_line(v_q, 'ONBOARD-GUIDED');
  m := erp.quote_margin(v_q);
  return query select 'a discounted line''s net is after its discount, as the quote totals it',
    not exists (select 1 from jsonb_array_elements(m -> 'lines') x
                  join erp.document_line l on l.id = (x ->> 'line_id')::uuid
                 where l.net_minor is distinct from (x ->> 'quoted_minor')::bigint)
    and (select l.net_minor from erp.document_line l join erp.item i on i.id = l.item_id
          where l.document_id = v_q and i.code = 'PLAN-STANDARD' and not l.is_cancelled) = 1182600
    and (select sum(l.net_minor) from erp.document_line l where l.document_id = v_q and not l.is_cancelled)
        = (m -> 'totals' ->> 'quoted_minor')::bigint,
    format('Standard at 10%% off is %s; the lines total %s against the quote''s %s',
      (select l.net_minor from erp.document_line l join erp.item i on i.id = l.item_id
        where l.document_id = v_q and i.code = 'PLAN-STANDARD' and not l.is_cancelled),
      (select sum(l.net_minor) from erp.document_line l where l.document_id = v_q and not l.is_cancelled),
      m -> 'totals' ->> 'quoted_minor');

  perform erp.submit_quote(v_q);
  res := erp.issue_quote(v_q);
  perform erp.quote_transition(v_q, 'accept', 'order form returned signed');
  m := erp.quote_margin(v_q);
  select o.content::jsonb into v_render from erp.output_render o where o.id = (res ->> 'render_id')::uuid;

  -- ── The order form as issued ─────────────────────────────────────────────

  return query select 'the order form shows each line''s price, its discount and its net after discount',
    jsonb_array_length(m -> 'lines') = 3
    and jsonb_array_length(v_render -> 'pricing' -> 'lines') = 3
    and not exists (
      select 1 from jsonb_array_elements(m -> 'lines') ml
       where not exists (select 1 from jsonb_array_elements(v_render -> 'pricing' -> 'lines') pl
                          where (pl ->> 'line_no')::integer = (ml ->> 'line_no')::integer
                            and (pl ->> 'unit_price_minor')::bigint = (ml ->> 'list_minor')::bigint
                            and (pl ->> 'discount_pct')::numeric = coalesce((ml ->> 'discount_pct')::numeric, 0)
                            and (pl ->> 'net_minor')::bigint = (ml ->> 'quoted_minor')::bigint)
          or not exists (select 1 from jsonb_array_elements(v_render -> 'blocks') b
                           cross join lateral jsonb_array_elements(b -> 'rows') r
                          where b ->> 'kind' = 'lines'
                            and (r ->> 'line_no')::integer = (ml ->> 'line_no')::integer
                            and (r ->> 'discount_pct')::numeric = coalesce((ml ->> 'discount_pct')::numeric, 0)
                            and (r ->> 'net_amount')::bigint = (ml ->> 'quoted_minor')::bigint))
    and exists (select 1 from jsonb_array_elements(v_render -> 'pricing' -> 'lines') pl
                 where pl ->> 'item_code' = 'PLAN-STANDARD'
                   and (pl ->> 'unit_price_minor')::bigint = 1314000 and (pl ->> 'discount_pct')::numeric = 10
                   and (pl ->> 'net_minor')::bigint = 1182600)
    and exists (select 1 from jsonb_array_elements(v_render -> 'blocks') b
                  cross join lateral jsonb_array_elements(b -> 'columns') col
                 where b ->> 'kind' = 'lines' and col ->> 'field' = 'discount_pct'),
    'Standard 1,314,000 at 10% is 1,182,600, and every line agrees with the quote';

  return query select 'the order form''s totals are the quote''s totals',
    (v_render -> 'pricing' -> 'totals' ->> 'net_minor')::bigint = (m -> 'totals' ->> 'quoted_minor')::bigint
    and (v_render -> 'pricing' -> 'totals' ->> 'list_minor')::bigint = (m -> 'totals' ->> 'list_minor')::bigint
    and (v_render -> 'pricing' -> 'totals' ->> 'discount_minor')::bigint
        = (m -> 'totals' ->> 'list_minor')::bigint - (m -> 'totals' ->> 'quoted_minor')::bigint
    and (v_render -> 'pricing' -> 'totals' ->> 'recurring_minor')::bigint = (m -> 'totals' ->> 'recurring_minor')::bigint
    and (v_render -> 'pricing' -> 'totals' ->> 'one_off_minor')::bigint = (m -> 'totals' ->> 'one_off_minor')::bigint
    and (select (f ->> 'value')::bigint from jsonb_array_elements(v_render -> 'blocks') b
           cross join lateral jsonb_array_elements(b -> 'fields') f
          where f ->> 'field' = 'total_net' limit 1) = (m -> 'totals' ->> 'quoted_minor')::bigint
    and (m -> 'totals' ->> 'quoted_minor')::bigint = 1182600 + 558600 + 250000,
    format('net %s, recurring %s, one-off %s; the quote says %s',
      v_render -> 'pricing' -> 'totals' ->> 'net_minor', v_render -> 'pricing' -> 'totals' ->> 'recurring_minor',
      v_render -> 'pricing' -> 'totals' ->> 'one_off_minor', m -> 'totals' ->> 'quoted_minor');

  v_keys := erp_test.keys_naming_cost_or_margin(v_render);
  return query select 'the order form as issued names no cost and no margin at any depth',
    v_render is not null and v_keys is null and not (v_render ? 'margin'),
    coalesce('found ' || v_keys, 'none');

  -- ── The contract, and a form issued before this migration ───────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  v_contract := erp.create_contract_from_quote(v_q, v_ccode, 'Order Form Customer Ltd', 'Clove ERP Ltd', current_date,
                                               12, 'automatic', 90, 'England and Wales', 'annual');
  perform erp.sign_contract(v_contract, 'A. Customer, director', 'Platform Owner, director', 'agreement to the order form');
  select d.id into v_form from erp_meta.contract_document d where d.contract_id = v_contract and d.kind = 'order_form' and d.version = 1;

  -- What issue_quote wrote until now: the render with the margin reader's totals.
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  v_legacy_text := (((select d.content from erp_meta.contract_document d where d.id = v_form)::jsonb - 'pricing')
                    || jsonb_build_object('margin', erp.quote_margin(v_q) - 'lines'))::text;
  insert into erp_meta.contract_document (contract_id, kind, version, title, content, checksum)
  values (v_contract, 'order_form', 2, 'Order form as issued before 20260914093000', v_legacy_text, md5(v_legacy_text))
  returning id into v_legacy;

  -- ── What the customer's administrator reads ──────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  res := erp.my_contract_document(v_form);
  v_keys := erp_test.keys_naming_cost_or_margin((res ->> 'content')::jsonb);
  return query select 'a customer administrator reads the order form with its price and no cost or margin at any depth',
    res is not null
    and v_keys is null
    and (res ->> 'content') !~* '"[a-z_]*(cost|margin)[a-z_]*"\s*:'
    and ((res ->> 'content')::jsonb -> 'pricing' -> 'totals' ->> 'net_minor')::bigint = 1182600 + 558600 + 250000
    and res ->> 'checksum' = md5(res ->> 'content'),
    coalesce('found ' || v_keys, 'the price, and the checksum of what was signed');

  res := erp.my_contract_document(v_legacy);
  v_keys := erp_test.keys_naming_cost_or_margin((res ->> 'content')::jsonb);
  return query select 'an order form issued before this is read without its cost and margin, and the archive is not rewritten',
    res is not null
    and v_keys is null
    and not ((res ->> 'content')::jsonb ? 'margin')
    and (res ->> 'content')::jsonb ? 'blocks'
    and ((res ->> 'content')::jsonb ->> 'quote_version')::integer = 1
    and erp_test.keys_naming_cost_or_margin(v_legacy_text::jsonb) is not null
    and (select d.content = v_legacy_text and d.checksum = md5(v_legacy_text)
           from erp_meta.contract_document d where d.id = v_legacy),
    coalesce('found ' || v_keys, format('held with %s; shown without them', erp_test.keys_naming_cost_or_margin(v_legacy_text::jsonb)));

  -- ── The invoice ──────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  v_n := erp.generate_invoice_schedule(v_contract);
  select i.id into v_inv from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq limit 1;
  res := erp.issue_contract_invoice(v_inv);
  return query select 'an issued invoice is due fourteen days after it is issued',
    v_n >= 1
    and (select i.due_on = current_date + 14 and i.issued_at::date = current_date
           from erp_meta.contract_invoice i where i.id = v_inv)
    and (res ->> 'due_on')::date = current_date + 14,
    format('issued %s, due %s', current_date,
      (select i.due_on from erp_meta.contract_invoice i where i.id = v_inv));

  return query select 'the invoice says Clove ERP Ltd is not registered for VAT, and carries no VAT line',
    (select i.tax_statement from erp_meta.contract_invoice i where i.id = v_inv) = c_statement
    and res ->> 'tax_statement' = c_statement
    and erp.contract_invoice_terms('Clove ERP Ltd') ->> 'tax_statement' = c_statement
    and not exists (select 1 from jsonb_array_elements(res -> 'lines') x
                     where x ->> 'kind' ~* '(vat|tax)'
                        or exists (select 1 from jsonb_object_keys(x) k where k ~* '(vat|tax)'))
    and (select i.total_minor = i.subscription_minor + i.overage_minor + i.one_off_minor
           from erp_meta.contract_invoice i where i.id = v_inv),
    coalesce(res ->> 'tax_statement', 'no statement');

  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  res := erp.my_agreement();
  return query select 'and the customer sees the same due date and statement on its own invoice',
    exists (select 1 from jsonb_array_elements(res -> 'invoices') x
             where (x ->> 'id')::uuid = v_inv and x ->> 'status' = 'issued'
               and (x ->> 'due_on')::date = current_date + 14
               and x ->> 'tax_statement' = c_statement),
    'Your agreement, What you will pay next';

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.contract where id = v_contract;
  delete from erp_meta.subscription where tenant_id = v_customer;
  delete from erp_meta.platform_organisation where tenant_id = v_platform;
  perform erp.begin_tenant_purge(v_platform);
  delete from erp.tenant where id = v_platform;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_own);
  delete from erp.tenant where id = v_own;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzofp.test';
  delete from auth.users where id in (ad, ow, ca);
  if v_prior.tenant_id is not null then
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_platform, v_customer, v_own))
    and not exists (select 1 from erp_meta.contract c where c.tenant_id = v_customer)
    and not exists (select 1 from erp_meta.contract_document d where d.id in (v_form, v_legacy))
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'organisations, contract, documents and staff gone, and any designation that was there before is back';
end;
$$;

create or replace function erp_test.assert_order_form_shows_the_price_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _order_form_shows_the_price_result on commit drop as
    select * from erp_test.order_form_shows_the_price_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _order_form_shows_the_price_result s;
  if v_total < c_expected then
    raise exception 'CLOVEERP_ORDER_FORM_SUITE_SHRANK: % case(s) ran, and % are expected', v_total, c_expected
      using errcode = 'P0001';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_ORDER_FORM_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('an order form shows the customer its price: %s/%s', v_passed, v_total);
end;
$$;

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

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_suite_verdicts_strict();
select erp_test.assert_order_form_shows_the_price_suite();
