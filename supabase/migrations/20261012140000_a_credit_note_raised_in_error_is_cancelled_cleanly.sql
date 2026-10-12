-- A credit note raised in error is cancelled cleanly, and stock with a keeper
-- is listed.
--
-- From the v1 known-issues list (the v1 Gate Assessment of 12 October).
--
--   KI-06. A credit note raised in error had no way back. Raised from an
--          invoice, a credit note opens as a draft, and a draft can be
--          cancelled by its lifecycle; the owner decided on 12 October that
--          one not yet issued may be (an issued one stays answered by
--          invoicing the customer again). But cancelling it undid nothing it
--          had done. erp.raise_customer_credit_note counts what is still out
--          on a despatch line by summing every credit note's returns against
--          it, cancelled ones included, so the goods could never be credited
--          again ("only 0 is still out"); and the customer return it had
--          marked credited stayed credited, pointing at a cancelled note.
--   KI-02. Stock's "Pass on" step counted nothing: no door listed stock in a
--          keeper's custody.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.raise_customer_credit_note leaves out the returns of a cancelled
--      credit note when it works out what is still out.
--   B. erp.cancelled_credit_note_gives_back(), on erp.object_state: a credit
--      note that moves to cancelled gives back its customer return, open again
--      and unlinked. A note raised in error does not mean the goods are not
--      coming back; the next, correct note takes the return again.
--   C. public.erp_stock_with_keepers: stock in the custody of a party that is
--      not the site's own company, by product, place and keeper. Reads only.
--   D. erp_test.credit_note_cancelled_cleanly_suite proves A to C.
--
-- On production: one routine edited where it counts, one trigger and two
-- routines added; no table is altered and no row is changed.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What is still out leaves a cancelled credit note out
-- ─────────────────────────────────────────────────────────────────────────────

do $patch$
declare
  v_sig text := 'erp.raise_customer_credit_note';
  v_def text;
  v_old constant text := $o$             select sum(rr.quantity) from erp.document_relation rr
              where rr.tenant_id = v_tenant and rr.to_line_id = gl.id
                and rr.relation_kind = 'returns'), 0)$o$;
  v_new constant text := $n$             select sum(rr.quantity) from erp.document_relation rr
               join erp.document rd on rd.tenant_id = rr.tenant_id and rd.id = rr.from_document_id
              where rr.tenant_id = v_tenant and rr.to_line_id = gl.id
                and rr.relation_kind = 'returns'
                -- A credit note cancelled before it was issued gave nothing
                -- back (20261012140000).
                and not rd.is_cancelled
                and erp.object_current_state('document', rd.id) is distinct from 'cancelled'), 0)$n$;
  n integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'erp' and p.proname = 'raise_customer_credit_note';
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A cancelled credit note gives back its return
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.cancelled_credit_note_gives_back()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.object_type = 'document'
     and new.current_state_id is distinct from old.current_state_id
     and exists (select 1 from erp.state s where s.id = new.current_state_id and s.code = 'cancelled')
     and exists (select 1
                   from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = new.tenant_id and d.id = new.object_id
                    and dt.base_type_code = 'credit_reference') then
    -- The return stands; the credit was what was wrong. Open again, for the
    -- next credit note to take.
    update erp.customer_return cr
       set status = 'open', return_document_id = null, credit_document_id = null, updated_at = now()
     where cr.tenant_id = new.tenant_id and cr.credit_document_id = new.object_id
       and cr.status = 'credited';
  end if;
  return new;
end;
$$;
revoke all on function erp.cancelled_credit_note_gives_back() from public, anon, authenticated;
comment on function erp.cancelled_credit_note_gives_back() is
  'A credit note that moves to cancelled gives back its customer return, open again and unlinked, for the next note '
  'to take (20261012140000).';

drop trigger if exists t_object_state_cancelled_credit_note on erp.object_state;
create trigger t_object_state_cancelled_credit_note
  after update of current_state_id on erp.object_state
  for each row execute function erp.cancelled_credit_note_gives_back();

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Stock with a keeper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_stock_with_keepers(p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Stock in the custody of a party that is not the site's own company: what
  -- "Pass on" handed over and has not had back (20261012140000).
  select coalesce(jsonb_agg(x order by x->>'keeper', x->>'item'), '[]'::jsonb) from (
    select jsonb_build_object(
      'balance_id', b.id,
      'item', i.code, 'item_name', i.name,
      'site', s.code, 'location', l.code,
      'keeper', k.name, 'owner', o.name,
      'batch', bt.batch_number,
      'quantity', b.quantity,
      'status', 'with_keeper') as x
      from erp.stock_balance b
      join erp.item i on i.tenant_id = b.tenant_id and i.id = b.item_id
      join erp.site s on s.tenant_id = b.tenant_id and s.id = b.site_id
      left join erp.location l on l.tenant_id = b.tenant_id and l.id = b.location_id
      join erp.party k on k.tenant_id = b.tenant_id and k.id = b.custody_party_id
      left join erp.party o on o.tenant_id = b.tenant_id and o.id = b.owner_party_id
      left join erp.batch bt on bt.tenant_id = b.tenant_id and bt.id = b.batch_id
     where b.tenant_id = erp.current_tenant_id()
       and b.quantity > 0
       and b.custody_party_id is distinct from erp.entity_party_for_site(b.site_id)
     order by k.name, i.code
     limit greatest(coalesce(p_limit, 200), 1)) t
$$;
revoke all on function public.erp_stock_with_keepers(integer) from public, anon;
grant execute on function public.erp_stock_with_keepers(integer) to authenticated, service_role;
comment on function public.erp_stock_with_keepers(integer) is
  'Stock in the custody of a party that is not the site''s own company, by keeper and product: what Pass on handed '
  'over (20261012140000). Reads under row security as the caller.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.credit_note_cancelled_cleanly_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_tenant uuid;
  v_ent    uuid; v_site uuid; i_fg uuid; p_sup uuid; p_cus uuid; p_keeper uuid; v_loc uuid;
  v_po     uuid; v_so uuid; v_dn uuid; v_inv uuid; v_cn uuid; v_cn2 uuid; v_ret uuid;
  x        jsonb;
  v_msg    text;
  v_ok     boolean;
  v_keep   jsonb;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzccc' || v_tag, 'Credit Note Cancelled Suite',
      'admin@demo-zzccc' || v_tag || '.test', 'Credit Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzccc' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_ent from erp.entity e
     where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.entity_id = v_ent and s.status = 'active'
     order by (s.site_type = 'warehouse') desc, s.code limit 1;
    select i.id into i_fg from erp.item i where i.tenant_id = v_tenant and i.code = 'FG-1000';
    select pt.id into p_sup from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'S-FAST';
    select pt.id into p_cus from erp.party pt where pt.tenant_id = v_tenant and pt.code = 'C-HARBOUR';

    v_step := 'stock to sell, received on an order';
    v_po := erp.open_document('purchase_order', p_sup, v_ent, v_site);
    perform erp.add_document_line(v_po, i_fg, 20, 4000, 'stock to sell');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'fixture');
    perform erp.transition_document(v_po, 'send', null);
    perform erp.create_receipt_from_order(v_po, null, 'post');

    v_step := 'four sold, delivered and invoiced';
    v_so := erp.open_document('sales_order', p_cus, v_ent, v_site, 'CUST-PO-95');
    perform erp.add_document_line(v_so, i_fg, 4, 4950, 'sensor');
    perform erp.transition_document(v_so, 'submit', null);
    if erp.document_state_code(v_so) = 'pending_approval' then
      perform erp_test.approve_document(v_so, 'fixture');
    end if;
    begin
      perform erp.release_credit_hold(v_so, 'released for the fixture');
    exception when others then
      null;
    end;
    x := erp.create_delivery_from_order(v_so, null, 'post');
    v_dn := (x ->> 'document_id')::uuid;
    v_inv := erp.invoice_from_delivery(v_dn, true, 'one person despatches and invoices in the suite');
    perform erp.transition_document(v_inv, erp.transition_code_to(v_inv, 'issued'), 'fixture');

    v_step := 'the customer asks to return all four';
    insert into erp.customer_return (tenant_id, entity_id, site_id, party_id, original_document_id,
                                     reason_code, reason, outcome, status)
    values (v_tenant, v_ent, v_site, p_cus, v_inv, 'DAMAGED_TRANSIT', 'four arrived broken', 'credit', 'open')
    returning id into v_ret;

    v_step := 'a credit note for all four, raised in error and cancelled before it is issued';
    v_cn := erp.raise_customer_credit_note(v_inv, 'DAMAGED_TRANSIT', 'four arrived broken', null);

    -- ── 1. The draft took the return ────────────────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'a credit note raised as a draft takes the return the customer asked for';
    passed := v_state is null
          and (select cr.status = 'credited' and cr.credit_document_id = v_cn
                 from erp.customer_return cr where cr.tenant_id = v_tenant and cr.id = v_ret);
    detail := coalesce(v_state, (select cr.status from erp.customer_return cr where cr.tenant_id = v_tenant and cr.id = v_ret));
    return next;

    -- ── 2. Cancelled, the return opens again ────────────────────────────────
    perform erp.transition_document(v_cn, 'cancel', 'raised against the wrong invoice');
    v_cases := v_cases + 1;
    case_name := 'cancelled before it is issued, the credit note gives the return back, open for the next note';
    passed := v_state is null
          and (select cr.status = 'open' and cr.credit_document_id is null and cr.return_document_id is null
                 from erp.customer_return cr where cr.tenant_id = v_tenant and cr.id = v_ret);
    detail := coalesce(v_state, (select format('%s, credit note %s', cr.status, coalesce(cr.credit_document_id::text, 'none'))
                                   from erp.customer_return cr where cr.tenant_id = v_tenant and cr.id = v_ret));
    return next;

    -- ── 3. The goods can be credited again ──────────────────────────────────
    v_step := 'crediting the four again';
    begin
      v_cn2 := erp.raise_customer_credit_note(v_inv, 'DAMAGED_TRANSIT', 'four arrived broken', null);
      v_ok := v_cn2 is not null; v_msg := 'credited again';
    exception when others then
      v_ok := false; v_msg := left(sqlerrm, 160);
    end;
    v_cases := v_cases + 1;
    case_name := 'the goods a cancelled credit note named can be credited again, and the new note takes the return';
    passed := v_state is null and v_ok
          and (select cr.status = 'credited' and cr.credit_document_id = v_cn2
                 from erp.customer_return cr where cr.tenant_id = v_tenant and cr.id = v_ret);
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 4. A return the note made itself opens again too ────────────────────
    v_step := 'a note with no return asked for, then cancelled';
    perform erp.transition_document(v_cn2, 'cancel', 'fixture');
    update erp.customer_return set status = 'closed', updated_at = now() where tenant_id = v_tenant and id = v_ret;
    v_cn := erp.raise_customer_credit_note(v_inv, 'DAMAGED_TRANSIT', 'four arrived broken', null);
    perform erp.transition_document(v_cn, 'cancel', 'fixture');
    v_cases := v_cases + 1;
    case_name := 'a return the cancelled note made itself opens again, unlinked, and nothing still points at a cancelled note';
    passed := v_state is null
          and (select count(*) from erp.customer_return cr where cr.tenant_id = v_tenant and cr.status = 'open') = 1
          and not exists (select 1 from erp.customer_return cr
                           join erp.document d on d.tenant_id = cr.tenant_id and d.id = cr.credit_document_id
                          where cr.tenant_id = v_tenant and cr.status = 'credited'
                            and erp.object_current_state('document', d.id) = 'cancelled');
    detail := coalesce(v_state, (select string_agg(cr.status, ', ') from erp.customer_return cr where cr.tenant_id = v_tenant));
    return next;

    -- ── 5. Stock with a keeper is listed ────────────────────────────────────
    v_step := 'two handed to a keeper';
    select pt.id into p_keeper from erp.party pt
     where pt.tenant_id = v_tenant and pt.status = 'active' and pt.id <> p_cus
       and pt.id is distinct from erp.entity_party_for_site(v_site)
     order by pt.code limit 1;
    select b.location_id into v_loc from erp.stock_balance b
     where b.tenant_id = v_tenant and b.item_id = i_fg and b.site_id = v_site and b.quantity >= 2
       and b.stock_status = 'available'
     order by b.quantity desc limit 1;
    perform erp.hand_over_custody(i_fg, v_site, v_loc, 2, p_keeper, null, 'sent for repair');
    v_keep := public.erp_stock_with_keepers(500);
    v_cases := v_cases + 1;
    case_name := 'stock handed to a keeper is listed with its keeper, and stock in our own custody is not';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_keep) r
                       where r ->> 'item' = 'FG-1000' and (r ->> 'quantity')::numeric = 2
                         and r ->> 'keeper' = (select pt.name from erp.party pt where pt.tenant_id = v_tenant and pt.id = p_keeper))
          and jsonb_array_length(v_keep) = 1;
    detail := coalesce(v_state, v_keep::text);
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
    raise exception 'CLOVEERP_CREDIT_NOTE_CANCELLED_CLEANLY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.credit_note_cancelled_cleanly_suite() from public, anon, authenticated;

create or replace function erp_test.assert_credit_note_cancelled_cleanly_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 5;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _credit_note_cancelled_cleanly on commit drop as
    select * from erp_test.credit_note_cancelled_cleanly_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _credit_note_cancelled_cleanly;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_CREDIT_NOTE_CANCELLED_CLEANLY_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_CREDIT_NOTE_CANCELLED_CLEANLY_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('credit note cancelled cleanly: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_credit_note_cancelled_cleanly_suite() from public, anon, authenticated;

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_isolation();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
