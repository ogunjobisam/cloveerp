set lock_timeout = '30s';

-- =============================================================================
-- 20261006121000  A quotation is not sent at no price
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-74).
-- A tester raised a quotation with a line nobody priced. The line form only
-- notes an unpriced line and submits anyway; erp.add_document_line() takes a
-- sales line the customer's prices say nothing about at nought; and nothing
-- in the quotation's Send, in erp.transition_document() or in the menu's
-- erp.transition_refusal(), looks at prices. So a quotation offering the
-- goods for £0.00 was sent to the customer.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.unpriced_line_count(): the live lines of a document that carry no
--      price, read in one place.
--   B. erp.transition_document() refuses Send on a quotation with a live
--      line at no price, CLOVEERP_QUOTATION_NOT_PRICED, and says what to do:
--      give the line its price with Change while the quotation is a draft,
--      or remove it. A draft is still raised unpriced, because the price may
--      not be known when the quotation is started (lines change on a draft
--      since 20261006101000); it is sending it that is refused.
--   C. erp.transition_refusal() holds Send with the same code, so the
--      document page draws it held with its reason, not offered and refused
--      on press. The refusal is registered with its next step, and the
--      screen says why Send is held.
--   D. erp_test.quotation_transform_suite: Send held and refused on an
--      unpriced line; priced with Change, or with the line removed, it sends.
--
-- A line priced at nothing on purpose, an item given away, is not what a
-- quotation offers a customer: it says so in the line's words on a priced
-- line, or goes on the order. Only quotations are held: a sales order is
-- approved on its value before it is confirmed, and its lines are its
-- approver's to read.
--
-- Production: no row is changed, and no quotation already sent moves. A draft
-- quotation with an unpriced line, of which the demonstration's trading
-- raises none (it prices every line from its list), is held at Send until
-- the line is priced.
--
-- Proof: erp_test.quotation_transform_suite, two cases more.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What carries no price
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.unpriced_line_count(p_document_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  -- The lines of a document still on it that carry no price
  -- (20261006121000). A line removed from a draft is cancelled, not deleted,
  -- and offers nothing, so it is not counted. Read by Send in
  -- erp.transition_document() and by the menu in erp.transition_refusal(),
  -- so the two cannot disagree.
  select count(*)::integer
    from erp.document_line l
   where l.tenant_id = erp.current_tenant_id()
     and l.document_id = p_document_id
     and not l.is_cancelled
     and coalesce(l.unit_price_minor, 0) = 0
$$;

revoke all on function erp.unpriced_line_count(uuid) from public, anon;

comment on function erp.unpriced_line_count(uuid) is
  'The live lines of a document that carry no price (20261006121000): read by Send on a quotation and by the menu that holds it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. Send refuses a quotation at no price
-- ═════════════════════════════════════════════════════════════════════════════

-- Edited, not rewritten: one anchor over the body 20261006111000 left.

do $transition$
declare
  v_sig  constant text := 'erp.transition_document(uuid,text,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- A transfer advances on stock moving, not on somebody clicking
  -- (20260922200000).$o$;
  v_new  constant text := $n$  -- A quotation is sent at the prices it offers (20261006121000): a live
  -- line at no price would offer the goods for nothing. erp.transition_refusal()
  -- holds Send on the same count.
  if dt.base_type_code = 'quotation' and p_transition_code = 'send'
     and erp.unpriced_line_count(p_document_id) > 0 then
    raise exception
      'CLOVEERP_QUOTATION_NOT_PRICED: % has % line(s) with no price, so it cannot be sent',
      coalesce(d.document_number, p_document_id::text), erp.unpriced_line_count(p_document_id)
      using errcode = '23514',
            hint = 'Give each line its price with Change while the quotation is a draft, or remove the line, then send it.';
  end if;

  -- A transfer advances on stock moving, not on somebody clicking
  -- (20260922200000).$n$;
begin
  if strpos(v_src, '20261006121000') > 0 then
    raise notice '% already refuses a quotation at no price; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ac7e1f988a636bbaf3f767acd8f4da9c' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006121000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The menu holds Send with the refusal the door would give
-- ═════════════════════════════════════════════════════════════════════════════

-- Edited, not rewritten: one anchor over the body 20261006111000 left.

do $refusal$
declare
  v_sig  constant text := 'erp.transition_refusal(uuid,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Reopen, of a requisition, is its order's (20261006111000): the same
  -- read erp.transition_document() makes.$o$;
  v_new  constant text := $n$  -- Send, of a quotation with a line at no price (20261006121000): the
  -- same count erp.transition_document() reads, so Send is held with its
  -- reason rather than refused on press (J-74).
  if p_transition_code = 'send' and v_tenant is not null
     and exists (select 1 from erp.document d
                   join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                  where d.tenant_id = v_tenant and d.id = p_document_id
                    and dt.base_type_code = 'quotation')
     and erp.unpriced_line_count(p_document_id) > 0 then
    return 'CLOVEERP_QUOTATION_NOT_PRICED';
  end if;

  -- Reopen, of a requisition, is its order's (20261006111000): the same
  -- read erp.transition_document() makes.$n$;
begin
  if strpos(v_src, '20261006121000') > 0 then
    raise notice '% already holds a quotation at no price at Send; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7fde97c486e0c0cb86da87e7299fdfe4' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006121000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$refusal$;

select erp.register_refusal('CLOVEERP_QUOTATION_NOT_PRICED',
  'Sending a quotation with a line that has no price.',
  'A customer reads a quotation as what they will be charged. A line at no price offers the goods for nothing, or leaves the customer to guess.',
  'Give each line its price with Change while the quotation is a draft, or remove the line, then send it.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Said on a quotation instead of Send, while a line on it has no price (20261006121000).'
  from (values
    ('A line has no price yet. Give it one with Change, then send it.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- Two cases more in the quotation suite, before its undo. Edited, not
-- rewritten: two anchors over the body 20261006120000 left.

do $suite$
declare
  v_sig  constant text := 'erp_test.quotation_transform_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_d_old constant text := $o$  v_q5 uuid; v_q6 uuid; v_moves jsonb; v_x3 text;
begin$o$;
  v_d_new constant text := $n$  v_q5 uuid; v_q6 uuid; v_moves jsonb; v_x3 text;
  -- No price (20261006121000).
  v_q7 uuid; v_q7l uuid; v_q8 uuid; v_q8l uuid; v_hint text; v_held text; v_held2 text;
begin$n$;
  v_old  constant text := $o$    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then$o$;
  v_new  constant text := $n$    -- 12. A quotation with a line nobody priced is held at Send, with the
    --     refusal Send gives (20261006121000).
    v_q7 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q7, v_i1, 2, 1000, 'Two widgets', null);
    v_q7l := erp.add_document_line(v_q7, v_i2, 1, null, 'One gadget, price to follow', null);
    select e ->> 'refused' into v_held
      from jsonb_array_elements(public.erp_available_transitions(v_q7)) e
     where e ->> 'code' = 'send';
    v_x := null; v_hint := null;
    begin
      perform public.erp_transition_document(v_q7, 'send', null);
      v_x := 'sent';
    exception when others then
      v_x := left(sqlerrm, 160);
      get stacked diagnostics v_hint = pg_exception_hint;
    end;
    return query select 'a quotation with a line at no price is held at Send with the refusal Send gives, and stays a draft',
      v_held = 'CLOVEERP_QUOTATION_NOT_PRICED'
      and v_x like 'CLOVEERP_QUOTATION_NOT_PRICED:%'
      and v_hint = 'Give each line its price with Change while the quotation is a draft, or remove the line, then send it.'
      and erp.object_current_state('document', v_q7) = 'draft'
      and exists (select 1 from erp_ref.refusal r where r.code = 'CLOVEERP_QUOTATION_NOT_PRICED'),
      format('menu %s; send %s (hint %s); state %s', coalesce(v_held, 'offered'), v_x,
             coalesce(v_hint, 'none'), erp.object_current_state('document', v_q7));

    -- 13. Priced with Change, it sends; and so does one whose unpriced line
    --     is removed.
    perform public.erp_change_document_line(v_q7l, 1, 2500, null);
    select e ->> 'refused' into v_held
      from jsonb_array_elements(public.erp_available_transitions(v_q7)) e
     where e ->> 'code' = 'send';
    v_x := null;
    begin
      v_st := public.erp_transition_document(v_q7, 'send', null) ->> 'state';
    exception when others then v_x := left(sqlerrm, 160); end;
    v_q8 := erp.open_document('quotation', v_cust, v_entity, v_site, null, null, 'GBP');
    perform erp.add_document_line(v_q8, v_i1, 3, 1000, 'Three widgets', null);
    v_q8l := erp.add_document_line(v_q8, v_i2, 1, 0, 'One gadget', null);
    perform public.erp_remove_document_line(v_q8l);
    select e ->> 'refused' into v_held2
      from jsonb_array_elements(public.erp_available_transitions(v_q8)) e
     where e ->> 'code' = 'send';
    v_x3 := null;
    begin
      v_st2 := public.erp_transition_document(v_q8, 'send', null) ->> 'state';
    exception when others then v_x3 := left(sqlerrm, 160); end;
    return query select 'priced with Change, the quotation is offered Send and sends; with its unpriced line removed, so does another',
      v_held is null and v_x is null and v_st = 'sent'
      and v_held2 is null and v_x3 is null and v_st2 = 'sent',
      format('priced: menu %s, send %s; removed: menu %s, send %s',
             coalesce(v_held, 'offered'), coalesce(v_x, v_st), coalesce(v_held2, 'offered'), coalesce(v_x3, v_st2));

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then$n$;
begin
  if strpos(v_src, '20261006121000') > 0 then
    raise notice '% already proves a quotation at no price; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd5aeb97cddab64c97141c007e055bf7e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006121000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or (length(v_def) - length(replace(v_def, v_d_old, ''))) / length(v_d_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchors found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_d_old, v_d_new), v_old, v_new);
end
$suite$;

-- Its count, twelve cases to fourteen.

do $assert$
declare
  v_sig  constant text := 'erp_test.assert_quotation_transform_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- Twelve since 20261006120000: a draft is cancelled.
  if v_total <> 12 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_SHRANK: % case(s), expected 12', v_total$o$;
  v_new  constant text := $n$  -- Fourteen since 20261006121000: a quotation is not sent at no price.
  if v_total <> 14 then
    raise exception 'CLOVEERP_QUOTATION_TRANSFORM_SUITE_SHRANK: % case(s), expected 14', v_total$n$;
begin
  if strpos(v_src, '20261006121000') > 0 then
    raise notice '% already re-pinned; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '13b9e89c96c47587a16aecb38777fabf' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006121000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
