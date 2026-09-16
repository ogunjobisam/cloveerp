-- =============================================================================
-- A document knows which side its party is on
--
-- erp.document has carried a party_role_id since the spine was laid, and
-- erp.create_document() has never set it. The column is not decoration: two
-- reads depend on it and both have been wrong for as long as they have
-- existed.
--
--   erp.ageing  decides receivable or payable from the role the document was
--               raised against. With the column null the join finds nothing
--               and every invoice and credit in the product reads 'other', so
--               the Receivables and payables ageing report cannot separate
--               what a company is owed from what it owes.
--
--   the sales-order shortage read shows a customer's credit status per line by
--               joining party_role_terms on that same column. Null there means
--               every line reports 'ok', including the ones that are not.
--
-- Last night's tax work met the same gap and worked around it:
-- erp.document_trade_side() falls back to the party's own roles and says so in
-- its comment. The fallback earns its keep for a party whose role was later
-- withdrawn, but it should not be doing the primary job.
--
--   1. erp.document_type_party_role_kind() answers, for a document type, which
--      role the party is standing in. The answer is already in the data: a
--      type carries the permission raising it requires, and the module that
--      permission belongs to is the side. sales.* is a customer, procurement.*
--      is a supplier. That is what makes purchase_invoice a purchase and
--      sales_invoice a sale though both are base type invoice_reference — the
--      tenant type overrides the permission to procurement.match precisely
--      because it is the other side of the same shape.
--
--   2. erp.create_document() names the role when the party holds it, and
--      leaves the column null when it does not, rather than guessing.
--
--   3. Every document already raised is given the side its party is on, and
--      the migration refuses to finish if any is left that could have been.
--
--   4. erp_test.document_side_suite() raises both invoices against a party
--      that both buys and sells — the case no fallback can answer — and reads
--      the ageing back.
-- =============================================================================

-- ── 1. Which role the party is standing in ───────────────────────────────────

create or replace function erp.document_type_party_role_kind(p_document_type_id uuid)
returns erp.party_role_kind
language sql
stable
security invoker
set search_path = ''
as $$
  -- The permission a type requires already says which side of the trade it is.
  -- Reading it here means a type added tomorrow is placed by the module it
  -- belongs to, with nothing to remember to update.
  select case split_part(coalesce(dt.create_permission, bt.create_permission), '.', 1)
           when 'sales'       then 'customer'::erp.party_role_kind
           when 'procurement' then 'supplier'::erp.party_role_kind
           else null
         end
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = erp.current_tenant_id() and dt.id = p_document_type_id;
$$;

revoke all on function erp.document_type_party_role_kind(uuid) from public, anon, authenticated;

comment on function erp.document_type_party_role_kind(uuid) is
  'Which role a document of this type stands its party in — customer for a '
  'sales type, supplier for a procurement one, null for a type that trades '
  'with nobody. Taken from the permission the type requires, so the two '
  'invoice types built on one base type are told apart by the module that '
  'raises them.';

-- ── 2. The door names it ─────────────────────────────────────────────────────

do $door$
declare
  v_sig  constant text := 'erp.create_document(text, uuid, uuid, uuid, date, character, text, jsonb)';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_new  text;
  v_dec  constant text := E'  v_number text;\n  v_id     uuid;\nbegin';
  v_ins  constant text :=
    E'  insert into erp.document (\n' ||
    E'    tenant_id, entity_id, site_id, document_type_id, document_number,\n' ||
    E'    party_id, document_date, currency, their_reference, attributes)\n' ||
    E'  values (\n' ||
    E'    v_tenant, p_entity_id, p_site_id, dt.id, v_number, p_party_id,';
begin
  if (length(v_def) - length(replace(v_def, v_dec, ''))) / length(v_dec) <> 1 then
    raise exception 'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: the declarations of % are not the ones this migration adds to', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_ins, ''))) / length(v_ins) <> 1 then
    raise exception 'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: the insert in % is not the one this migration adds a column to', v_sig;
  end if;

  v_new := replace(v_def, v_dec, E'  v_number text;\n  v_id     uuid;\n  v_role   uuid;\nbegin');

  v_new := replace(v_new, v_ins,
    E'  -- Which side of the trade this party is on, named on the document\n' ||
    E'  -- rather than guessed at by whoever reads it later. Null when the\n' ||
    E'  -- party does not hold the role the type implies: a document that says\n' ||
    E'  -- nothing is honest, and one that says the wrong thing is not.\n' ||
    E'  if p_party_id is not null then\n' ||
    E'    select pr.id into v_role\n' ||
    E'      from erp.party_role pr\n' ||
    E'     where pr.tenant_id = v_tenant and pr.party_id = p_party_id\n' ||
    E'       and pr.status = ''active''\n' ||
    E'       and pr.role_kind = erp.document_type_party_role_kind(dt.id);\n' ||
    E'  end if;\n' ||
    E'\n' ||
    E'  insert into erp.document (\n' ||
    E'    tenant_id, entity_id, site_id, document_type_id, document_number,\n' ||
    E'    party_id, party_role_id, document_date, currency, their_reference, attributes)\n' ||
    E'  values (\n' ||
    E'    v_tenant, p_entity_id, p_site_id, dt.id, v_number, p_party_id, v_role,');

  execute v_new;
end
$door$;

-- ── 3. And every document already raised ─────────────────────────────────────

do $backfill$
declare
  v_named bigint;
  v_left  bigint;
begin
  with resolved as (
    select d.id, d.tenant_id, pr.id as role_id
      from erp.document d
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp_ref.document_type bt on bt.code = dt.base_type_code
      join erp.party_role pr
        on pr.tenant_id = d.tenant_id and pr.party_id = d.party_id
       and pr.status = 'active'
       and pr.role_kind = case split_part(coalesce(dt.create_permission, bt.create_permission), '.', 1)
                            when 'sales'       then 'customer'::erp.party_role_kind
                            when 'procurement' then 'supplier'::erp.party_role_kind
                          end
     where d.party_id is not null and d.party_role_id is null
  )
  update erp.document d
     set party_role_id = r.role_id
    from resolved r
   where d.tenant_id = r.tenant_id and d.id = r.id;
  get diagnostics v_named = row_count;

  select count(*) into v_left
    from erp.document d
    join erp.document_type dt
      on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
    join erp.party_role pr
      on pr.tenant_id = d.tenant_id and pr.party_id = d.party_id
     and pr.status = 'active'
     and pr.role_kind = case split_part(coalesce(dt.create_permission, bt.create_permission), '.', 1)
                          when 'sales'       then 'customer'::erp.party_role_kind
                          when 'procurement' then 'supplier'::erp.party_role_kind
                        end
   where d.party_id is not null and d.party_role_id is null;

  if v_left > 0 then
    raise exception 'CLOVEERP_DOCUMENTS_WITHOUT_A_SIDE: % document(s) whose party holds the role the type implies are still unnamed', v_left;
  end if;

  raise notice 'documents given the side their party is on: %', v_named;
end
$backfill$;

-- The fallback stays — a party whose role was withdrawn still has documents —
-- but it is no longer what answers first, and the comment should not say it is.
comment on function erp.document_trade_side(uuid) is
  'Whether a document is a sale, a purchase, or something the product cannot '
  'tell. Reads the role the document named, which erp.create_document() sets '
  'from the module the type''s permission belongs to; falls back to the '
  'party''s own roles for a document raised against a role since withdrawn, '
  'and refuses to guess for a party that both buys and sells.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.document_side_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_both   uuid; v_only uuid;
  v_cust   uuid; v_supp uuid;
  v_inv    uuid; v_pinv uuid; v_po uuid; v_wrong uuid;
  v_role   uuid;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-document-side', 'Document side suite',
                              'admin@zz-document-side.test', 'Document Side Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000e8', 'admin@zz-document-side.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000e8')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;

  -- A party that both buys and sells is the case the fallback cannot answer:
  -- with no role named on the document, its side is genuinely unknowable.
  select p.id into v_both from erp.party p
    join erp.party_role c on c.tenant_id = p.tenant_id and c.party_id = p.id
     and c.role_kind = 'customer' and c.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  insert into erp.party_role (tenant_id, party_id, role_kind, status)
  values (v_tenant, v_both, 'supplier', 'active')
  on conflict (tenant_id, party_id, role_kind) do nothing;

  select pr.id into v_cust from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = v_both and pr.role_kind = 'customer';
  select pr.id into v_supp from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = v_both and pr.role_kind = 'supplier';

  -- ── 1. A sales invoice stands its party as the customer ───────────────────
  v_cases := v_cases + 1;
  v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_both,
                               current_date, v_ccy, 'ZZSIDE-SALE', '{}'::jsonb);
  perform erp.add_document_line(v_inv, v_item, 1, 40000, 'a sale to a party that also supplies');
  select d.party_role_id into v_role from erp.document d where d.id = v_inv;
  case_name := 'a sales invoice names the customer role of a party that both buys and sells';
  passed := v_role = v_cust;
  detail := format('named %s, customer role is %s', coalesce(v_role::text, 'nothing'), v_cust);
  return next;

  -- ── 2. And a purchase invoice the supplier, on the same base type ─────────
  v_cases := v_cases + 1;
  v_pinv := erp.create_document('purchase_invoice', v_entity, v_site, v_both,
                                current_date, v_ccy, 'ZZSIDE-PURCHASE', '{}'::jsonb);
  perform erp.add_document_line(v_pinv, v_item, 1, 15000, 'a purchase from the same party');
  select d.party_role_id into v_role from erp.document d where d.id = v_pinv;
  case_name := 'a purchase invoice on the same base type names the supplier role instead';
  passed := v_role = v_supp;
  detail := format('named %s, supplier role is %s', coalesce(v_role::text, 'nothing'), v_supp);
  return next;

  -- ── 3. The trade side stops falling back ──────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the trade side of each is answered from the document, not guessed from the party';
  passed := erp.document_trade_side(v_inv) = 'sale'
        and erp.document_trade_side(v_pinv) = 'purchase';
  detail := format('sales invoice reads %s, purchase invoice reads %s',
                   erp.document_trade_side(v_inv), erp.document_trade_side(v_pinv));
  return next;

  -- ── 4. A purchase order, where the module is the whole answer ─────────────
  v_cases := v_cases + 1;
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_both,
                              current_date, v_ccy, 'ZZSIDE-PO', '{}'::jsonb);
  select d.party_role_id into v_role from erp.document d where d.id = v_po;
  case_name := 'a purchase order stands its party as the supplier';
  passed := v_role = v_supp;
  detail := format('named %s', coalesce(v_role::text, 'nothing'));
  return next;

  -- ── 5. A party that does not hold the role is not given one ───────────────
  v_cases := v_cases + 1;
  select p.id into v_only from erp.party p
   where p.tenant_id = v_tenant
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                    and pr.role_kind = 'supplier' and pr.status = 'active')
     and not exists (select 1 from erp.party_role pr
                      where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                        and pr.role_kind = 'customer' and pr.status = 'active')
   order by p.code limit 1;
  v_wrong := erp.create_document('sales_invoice', v_entity, v_site, v_only,
                                 current_date, v_ccy, 'ZZSIDE-NEITHER', '{}'::jsonb);
  select d.party_role_id into v_role from erp.document d where d.id = v_wrong;
  case_name := 'a sales invoice raised against a party that only supplies names no role rather than the wrong one';
  passed := v_role is null;
  detail := format('named %s', coalesce(v_role::text, 'nothing'));
  return next;

  -- ── 6. Which is what the ageing was reading ───────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the ageing calls one a receivable and the other a payable, where both read other before';
  passed := (select a.direction from erp.ageing a where a.id = v_inv) = 'receivable'
        and (select a.direction from erp.ageing a where a.id = v_pinv) = 'payable';
  detail := format('sales invoice ages as %s, purchase invoice as %s',
                   coalesce((select a.direction from erp.ageing a where a.id = v_inv), 'no row'),
                   coalesce((select a.direction from erp.ageing a where a.id = v_pinv), 'no row'));
  return next;

  -- ── 7. And the demonstration's own history reads the same way ─────────────
  -- Every row but the one deliberately raised against a party that does not
  -- stand on that side, which is meant to read 'other' and does.
  v_cases := v_cases + 1;
  case_name := 'every invoice and credit in the demonstration ages as a receivable or a payable';
  passed := not exists (select 1 from erp.ageing a
                         where a.tenant_id = v_tenant and a.direction = 'other'
                           and a.id <> v_wrong);
  detail := format('%s ageing row(s), %s of them other besides the deliberate one',
                   (select count(*) from erp.ageing a where a.tenant_id = v_tenant),
                   (select count(*) from erp.ageing a
                     where a.tenant_id = v_tenant and a.direction = 'other'
                       and a.id <> v_wrong));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 8. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-document-side')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000e8');
  detail := 'zz-document-side rolled back with its documents and the role it added';
  return next;

  if v_cases <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: document_side_suite ran % cases, expected 8', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.document_side_suite() from public, anon;

create or replace function erp_test.assert_document_side_suite()
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
  create temp table if not exists _document_side on commit drop as
    select * from erp_test.document_side_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _document_side;
  drop table _document_side;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DOCUMENT_SIDE_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 8 then
    raise exception 'CLOVEERP_SUITE_SHRANK: document_side_suite ran % cases, expected 8', v_all;
  end if;
  return format('a document knows its side: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_document_side_suite() from public, anon;

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
select erp.assert_writes_name_their_rows();
select erp.assert_ci_coverage();
select erp_test.assert_document_side_suite();
