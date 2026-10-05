set lock_timeout = '30s';

-- =============================================================================
-- 20261007050000  A related document is named by its own type
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (R-07). A document's
-- "Related documents" captioned every supplier bill and every sales invoice
-- "Carrier bill", and listed one requisition twice.
--
-- public.erp_document answered each related document with only its base type
-- (erp.document_lineage returns dt.base_type_code). The page named it with the
-- first of the organisation's types on that base, by code. carrier_bill,
-- landed_cost_bill, purchase_invoice and sales_invoice all share the base
-- invoice_reference, so once logistics put carrier_bill into the demonstration
-- every invoice read "Carrier bill".
--
-- erp.document_lineage walks the relations recursively and keeps one row per
-- depth, document and relation. A document reached by two paths of different
-- length (a requisition behind the order a bill invoices, and behind the
-- receipt the bill also invoices) came back once for each length.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_document's lineage answers each related document's own
--      type (document_type, the organisation's code for it) beside its base
--      type, and keeps one row for each way a document relates (direction
--      and relation) at its nearest depth. A document that relates two ways
--      (an order a bill both invoices and fulfils) still comes back once for
--      each. erp.document_lineage is unchanged: matching and the other
--      readers that walk it read what they read today.
--      The page captions a related document by its own type's name, and
--      keys each row by direction, document and relation.
--   B. erp_test.document_lineage_names_suite.
--
-- Production: one read door is patched. No table is altered and no row is
-- changed, in any organisation.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Each related document once a way, by its own type
-- ─────────────────────────────────────────────────────────────────────────────

do $document$
declare
  v_sig  constant text := 'public.erp_document(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', depth, 'direction', direction, 'document_id', document_id,
        'document_number', document_number, 'base_type', base_type,
        'relation', relation_kind) order by depth)
        from erp.document_lineage(p_document_id)), '[]'::jsonb),$o$;
  v_new  constant text := $n$    -- Each related document by its own type, and once for each way it
    -- relates, at its nearest (20261007050000, R-07). The base type alone
    -- named every invoice by whichever type on that base came first, and a
    -- document two paths reach came back once for each path's length.
    'lineage', coalesce((
      select jsonb_agg(jsonb_build_object(
        'depth', g.depth, 'direction', g.direction, 'document_id', g.document_id,
        'document_number', g.document_number, 'base_type', g.base_type,
        'document_type', dt.code,
        'relation', g.relation_kind) order by g.depth, g.direction, g.document_number, g.relation_kind)
        from (select distinct on (l.direction, l.document_id, l.relation_kind) l.*
                from erp.document_lineage(p_document_id) l
               order by l.direction, l.document_id, l.relation_kind, l.depth) g
        join erp.document rd on rd.tenant_id = erp.current_tenant_id() and rd.id = g.document_id
        join erp.document_type dt on dt.tenant_id = rd.tenant_id and dt.id = rd.document_type_id), '[]'::jsonb),$n$;
begin
  if strpos(v_src, '20261007050000') > 0 then
    raise notice '% already names a related document by its own type; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7d543b1f101aa46609a1525f7c4f63fe' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007050000 expects (md5 %)', v_sig, md5(v_src);
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
  '(20261007040000)), its lines, whether it can be amended, its lineage (each related document by its own type, '
  'once for each way it relates, at its nearest (20261007050000)), its posting reversals and the moves open to '
  'it. Reads under row security as the caller, and authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.document_lineage_names_suite()
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
  v_entity uuid; v_site uuid; v_sa uuid;
  v_req    uuid; v_po uuid; v_grn uuid; v_pinv uuid; v_cbill uuid; v_sinv uuid;
  v_hub    jsonb; v_bill jsonb;
  v_wrong  integer; v_types integer; v_bases integer; v_rows integer;
  v_req_rows integer; v_req_walk integer; v_req_depth integer; v_po_rels text;
  v_lost   integer; v_extra integer; v_docs integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with a requisition, its order, a receipt, and three bills on one base type';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzdln-' || v_tag, 'Document Lineage Names Suite',
      'admin@zzdln-' || v_tag || '.test', 'Lineage Names Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzdln-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    v_sa := erp_test.cash_payment_supplier('ZDLNA');
    v_req   := erp.open_document('requisition', null, v_entity, v_site);
    v_po    := erp.open_document('purchase_order', v_sa, v_entity, v_site);
    v_grn   := erp.open_document('goods_receipt', v_sa, v_entity, v_site);
    v_pinv  := erp.open_document('purchase_invoice', v_sa, v_entity, v_site);
    v_cbill := erp.open_document('carrier_bill', v_sa, v_entity, v_site);
    v_sinv  := erp.open_document('sales_invoice', v_sa, v_entity, v_site);
    -- The requisition becomes the order, which the receipt fulfils; the bill
    -- invoices both the receipt and the order, so the requisition is two
    -- paths behind it, one longer than the other. The carrier's bill and a
    -- sales invoice hang off the order too: four invoices on one base.
    perform erp.link_documents(v_req, v_po, 'converts');
    perform erp.link_documents(v_po, v_grn, 'fulfils');
    perform erp.link_documents(v_grn, v_pinv, 'invoices');
    perform erp.link_documents(v_po, v_pinv, 'invoices');
    perform erp.link_documents(v_po, v_cbill, 'consumes');
    perform erp.link_documents(v_po, v_sinv, 'mirrors');

    -- ── 1. Each related document by its own type ────────────────────────────
    v_step := 'reading the order''s related documents';
    v_hub := public.erp_document(v_po) -> 'lineage';
    select count(*) filter (where (r ->> 'document_type') is distinct from dt.code),
           count(distinct dt.code) filter (where dt.base_type_code = 'invoice_reference'),
           count(distinct dt.base_type_code) filter (where dt.base_type_code = 'invoice_reference'),
           count(*)
      into v_wrong, v_types, v_bases, v_rows
      from jsonb_array_elements(v_hub) r
      join erp.document d on d.tenant_id = rb.tenant_id and d.id = (r ->> 'document_id')::uuid
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id;
    v_cases := v_cases + 1;
    case_name := 'a purchase invoice, a carrier''s bill and a sales invoice share one base type, and each related document, the order itself included, is answered by its own type';
    passed := coalesce(v_state is null
          and v_wrong = 0
          and v_types = 3 and v_bases = 1
          and v_rows = jsonb_array_length(v_hub)
          and v_rows >= 6, false);
    detail := coalesce(v_state, left(format('%s row(s) of %s name another type; %s invoice type(s) on %s base(s): %s',
                                            v_wrong, v_rows, v_types, v_bases, v_hub), 500));
    return next;

    -- ── 2. Two paths, one row; two relations, two rows ──────────────────────
    v_step := 'reading the bill''s related documents';
    v_bill := public.erp_document(v_pinv) -> 'lineage';
    select count(*), min((r ->> 'depth')::integer) into v_req_rows, v_req_depth
      from jsonb_array_elements(v_bill) r
     where (r ->> 'document_id')::uuid = v_req;
    select count(*) into v_req_walk
      from erp.document_lineage(v_pinv) l where l.document_id = v_req;
    select string_agg(r ->> 'relation', ',' order by r ->> 'relation') into v_po_rels
      from jsonb_array_elements(v_bill) r
     where (r ->> 'document_id')::uuid = v_po;
    v_cases := v_cases + 1;
    case_name := 'a requisition two paths of different length behind a bill is listed once, at its nearest, and the order the bill both invoices and stands behind by its receipt is listed once for each relation';
    passed := coalesce(v_state is null
          and v_req_walk = 2
          and v_req_rows = 1 and v_req_depth = 2
          and v_po_rels = 'fulfils,invoices', false);
    detail := coalesce(v_state, left(format('requisition walked %s time(s), listed %s time(s) at depth %s; order listed as %s',
                                            v_req_walk, v_req_rows, v_req_depth, v_po_rels), 500));
    return next;

    -- ── 3. Nothing the walk finds is lost ────────────────────────────────────
    v_step := 'comparing every document''s page with the walk';
    select count(*) into v_docs from erp.document d where d.tenant_id = rb.tenant_id;
    select count(*) into v_lost
      from erp.document d
      cross join lateral (
        select l.direction, l.document_id, l.relation_kind, min(l.depth) as depth
          from erp.document_lineage(d.id) l
         group by 1, 2, 3) w
     where d.tenant_id = rb.tenant_id
       and not exists (
         select 1 from jsonb_array_elements(public.erp_document(d.id) -> 'lineage') r
          where r ->> 'direction' = w.direction
            and (r ->> 'document_id')::uuid = w.document_id
            and (r ->> 'relation') is not distinct from w.relation_kind
            and (r ->> 'depth')::integer = w.depth);
    select count(*) into v_extra
      from erp.document d
      cross join lateral (
        select r ->> 'direction' as direction, r ->> 'document_id' as document_id, r ->> 'relation' as relation,
               count(*) as n
          from jsonb_array_elements(public.erp_document(d.id) -> 'lineage') r
         group by 1, 2, 3) p
     where d.tenant_id = rb.tenant_id and p.n > 1;
    v_cases := v_cases + 1;
    case_name := 'on every document of the organisation, each document and relation the walk finds is on the page once, at the least depth the walk found it';
    passed := coalesce(v_state is null
          and v_docs >= 6
          and v_lost = 0
          and v_extra = 0, false);
    detail := coalesce(v_state, left(format('%s document(s): %s walked relation(s) missing, %s listed more than once',
                                            v_docs, v_lost, v_extra), 500));
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
    raise exception 'CLOVEERP_DOCUMENT_LINEAGE_NAMES_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.document_lineage_names_suite() from public, anon;

comment on function erp_test.document_lineage_names_suite() is
  'A related document is named by its own type (20261007050000, R-07): erp_document answers each related '
  'document''s own type beside its base, so three invoices on one base are told apart; a document two paths '
  'reach is listed once at its nearest, one that relates two ways once for each; and on every document nothing '
  'erp.document_lineage walks is lost.';

create or replace function erp_test.assert_document_lineage_names_suite()
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
    from erp_test.document_lineage_names_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DOCUMENT_LINEAGE_NAMES_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A document''s related documents are named by another type, listed twice, or missing. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DOCUMENT_LINEAGE_NAMES_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a related document is named by its own type: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_document_lineage_names_suite() from public, anon;

comment on function erp_test.assert_document_lineage_names_suite() is
  'erp_document names each related document by its own type, once for each way it relates (20261007050000).';

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
