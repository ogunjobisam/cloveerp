set lock_timeout = '30s';

-- =============================================================================
-- 20261007040000  A purchase order says its freight terms
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-63). Who brings an
-- order's goods, the supplier or us, is set with "Set freight terms" and
-- stored on the order (erp.set_freight_terms, 20261004955000). The order's
-- own page never said which it was, and offered neither "Set freight terms"
-- nor "Book a collection": both lived only in Purchasing's Actions sheet,
-- where the order had to be found again in a list, and the toast said only
-- "Set freight terms — done." without naming the order. public.erp_document
-- did not answer the terms, so the page had nothing to show.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_document answers freight_terms for a purchase order, read
--      through erp.order_freight_terms, the reader erp.ship_inbound already
--      decides with, so the page and the booking cannot disagree:
--      supplier_delivers (the default) or we_collect. Any other document
--      answers none.
--      The order's page shows the terms and offers "Set freight terms" and
--      "Book a collection" on the order itself, with the existing words.
--   B. erp_test.document_freight_terms_suite.
--
-- Production: one read door is patched. No table is altered and no row is
-- changed. Every organisation's orders answer their terms as they are stored.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The order's page reads its terms
-- ─────────────────────────────────────────────────────────────────────────────

do $document$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        'is_sample', erp.is_sample_receipt(d.id))$o$;
  v_new  constant text := $n$        'is_sample', erp.is_sample_receipt(d.id),
        -- Who brings a purchase order's goods (20261007040000, J-63): the
        -- supplier, by default, or us. Read as erp.ship_inbound reads it, so
        -- the page offers a collection on what the booking accepts. Any other
        -- document answers none.
        'freight_terms', case when dt.base_type_code = 'purchase_order'
                              then erp.order_freight_terms(d.id) end)$n$;
begin
  if strpos(v_src, '20261007040000') > 0 then
    raise notice '% already answers a purchase order''s freight terms; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '27dc9600ff0329bbcf6aff07ee6820d2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007040000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$document$;

comment on function public.erp_document(uuid) is
  'One document as its page draws it: its summary (state, value, tax, whether its lines are open, whether it is '
  'a receipt of samples, and for a purchase order its freight terms, read through erp.order_freight_terms '
  '(20261007040000)), its lines, whether it can be amended, its lineage, its posting reversals and the moves '
  'open to it. Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.document_freight_terms_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_sa uuid;
  v_po     uuid; v_po2 uuid; v_grn uuid;
  v_t0     jsonb; v_t1 jsonb; v_t2 jsonb; v_grn_doc jsonb; v_po2_doc jsonb;
  v_bad    integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation that buys, two orders to one supplier and a goods receipt';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdft-' || v_tag, 'Document Freight Terms Suite',
      'admin@zzdft-' || v_tag || '.test', 'Freight Terms Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdft-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZDFTCOAT', 'Freight Terms Coat', v_uom, 'active') returning id into v_item;
    v_sa := erp_test.cash_payment_supplier('ZDFTA');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 10, 9000, 'ZDFT1', true);
    v_po2 := erp_test.prepayment_order(v_entity, v_site, v_item, v_sa, 2, 9000, 'ZDFT2', false);
    v_grn := erp.open_document('goods_receipt', v_sa, v_entity, v_site);

    -- ── 1. The default, and none on another document ────────────────────────
    v_step := 'reading an order whose terms were never set, and a goods receipt';
    v_t0 := public.erp_document(v_po) -> 'document';
    v_grn_doc := public.erp_document(v_grn) -> 'document';
    v_cases := v_cases + 1;
    case_name := 'a purchase order whose terms were never set says the supplier delivers, and a document that is not a purchase order says no terms at all';
    passed := v_state is null
          and v_t0 ->> 'freight_terms' = 'supplier_delivers'
          and v_grn_doc is not null
          and v_grn_doc -> 'freight_terms' = 'null'::jsonb;
    detail := coalesce(v_state, left(format('order %s; receipt %s', v_t0 -> 'freight_terms', v_grn_doc -> 'freight_terms'), 500));
    return next;

    -- ── 2. The terms set are the terms read ─────────────────────────────────
    v_step := 'setting the order''s terms to we collect, then back';
    perform public.erp_set_freight_terms(v_po, 'we_collect');
    v_t1 := public.erp_document(v_po) -> 'document';
    perform public.erp_set_freight_terms(v_po, 'supplier_delivers');
    v_t2 := public.erp_document(v_po) -> 'document';
    v_cases := v_cases + 1;
    case_name := 'the order''s page reads the terms as Set freight terms leaves them: We collect once set, the supplier delivers once set back';
    passed := v_state is null
          and v_t1 ->> 'freight_terms' = 'we_collect'
          and v_t2 ->> 'freight_terms' = 'supplier_delivers'
          and v_t1 ->> 'document_number' = v_t0 ->> 'document_number';
    detail := coalesce(v_state, left(format('after we collect %s; after supplier delivers %s', v_t1 -> 'freight_terms', v_t2 -> 'freight_terms'), 500));
    return next;

    -- ── 3. The page and the booking read the same terms ─────────────────────
    v_step := 'comparing what the page reads with what the booking reads, on every order';
    perform public.erp_set_freight_terms(v_po2, 'we_collect');
    v_po2_doc := public.erp_document(v_po2) -> 'document';
    select count(*) into v_bad
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = rb.tenant_id and dt.base_type_code = 'purchase_order'
       and (public.erp_document(d.id) -> 'document' ->> 'freight_terms') is distinct from erp.order_freight_terms(d.id);
    v_cases := v_cases + 1;
    case_name := 'on every purchase order of the organisation, sent or not, the page reads the terms erp.order_freight_terms gives the booking of a collection';
    passed := v_state is null
          and v_bad = 0
          and v_po2_doc ->> 'freight_terms' = 'we_collect'
          and v_po2_doc ->> 'state' <> 'sent';
    detail := coalesce(v_state, left(format('%s order(s) disagree; unsent order %s in %s', v_bad, v_po2_doc -> 'freight_terms', v_po2_doc -> 'state'), 500));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.job_principal_id', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DOCUMENT_FREIGHT_TERMS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.document_freight_terms_suite() from public, anon;

comment on function erp_test.document_freight_terms_suite() is
  'A purchase order says its freight terms (20261007040000, J-63): erp_document answers supplier_delivers for an '
  'order never set, we_collect once set and back again, none for another document, and on every order what '
  'erp.order_freight_terms gives the booking of a collection.';

create or replace function erp_test.assert_document_freight_terms_suite()
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
    from erp_test.document_freight_terms_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DOCUMENT_FREIGHT_TERMS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An order''s page says freight terms other than those the booking of a collection reads. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DOCUMENT_FREIGHT_TERMS_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a purchase order says its freight terms: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_document_freight_terms_suite() from public, anon;

comment on function erp_test.assert_document_freight_terms_suite() is
  'erp_document answers a purchase order''s freight terms as erp.order_freight_terms reads them (20261007040000).';

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
