-- ─────────────────────────────────────────────────────────────────────────────
-- Two gates that refuse everybody, and the check that should have said so.
--
-- Opening a document and pressing nothing produced "An action the account holds
-- no permission for — ERPWARE_PERMISSION_DENIED: documents.read", on a screen
-- that was at that moment displaying the document.
--
-- It is not a grant that was missing. `documents.read` is not a permission.
-- erp_ref.permission holds fifty-five codes and not one of them begins
-- `documents.`; the surface is per-module — sales.read, procurement.read — which
-- is what 20260830 "document authorisation follows the module" established.
-- So the gate names a code nobody can hold, has never been holdable, and refuses
-- every caller in every organisation.
--
-- Measured across every erp.authorise() call site in erp and public: forty-eight
-- distinct codes, forty-six real, two dead. Both dead ones are on this surface.
--
--   public.erp_document_approval_chain   -> documents.read
--   public.erp_stamp_document_approval   -> documents.capture
--
-- The second is the button beside the panel, so "Stamp the approval chain" was
-- refused too, for the same reason, and had been all along.
--
-- Reproduced on a fresh build, so it is a schema defect rather than drift.
--
-- The reads on this surface do not gate at all. erp_document, erp_documents and
-- erp_document_lines carry no erp.authorise() call: they are scoped by
-- erp.current_tenant_id() and the row security over it, and a caller who can
-- reach the document can read what is on it. The approval chain is that same
-- data about that same document, so it joins them rather than inventing a
-- fifty-sixth permission for one panel.
--
-- The write is different and keeps its gate, but the gate now follows the
-- module the way every other document verb does: the permission that raises
-- this kind of document is the permission that stamps its approval chain,
-- read from the document type with the base type behind it. A sales clerk
-- stamps a sales order; nobody gets a new blanket capability out of this fix.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_document_approval_chain(p_document_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- No erp.authorise() here, deliberately, and for the same reason
  -- erp_document() has none: row security scopes this to the caller's
  -- organisation, and a caller looking at a document may read what is on it.
  -- The gate that used to be here named a permission that does not exist.
  select coalesce(jsonb_agg(jsonb_build_object(
           'stamp_id', s.id, 'resolved_at', s.resolved_at,
           'value_minor', s.value_minor, 'currency', s.currency,
           'resolved_chain', s.resolved_chain) order by s.resolved_at desc), '[]'::jsonb)
    into v_out
    from erp.approval_routing_stamp s
   where s.tenant_id = erp.current_tenant_id()
     and s.object_type = 'document'
     and s.object_id = p_document_id;
  return v_out;
end;
$$;

revoke all on function public.erp_document_approval_chain(uuid) from public, anon;
grant execute on function public.erp_document_approval_chain(uuid) to authenticated, service_role;

create or replace function public.erp_stamp_document_approval(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        record;
  v_value  bigint;
  v_dept   uuid;
  v_chain  jsonb;
  v_perm   text;
begin
  -- The document is read first, because the permission to demand comes from it.
  select doc.id, doc.entity_id, doc.site_id, doc.currency, doc.created_by,
         dt.code as type_code,
         coalesce(dt.create_permission, bt.create_permission) as create_permission
    into d
    from erp.document doc
    join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
    left join erp_ref.document_type bt on bt.code = dt.base_type_code
   where doc.tenant_id = v_tenant and doc.id = p_document_id;

  if d.id is null then
    raise exception 'ERPWARE_DOCUMENT_UNKNOWN: no such document' using errcode = '23503';
  end if;

  -- Follow the module. The permission that raises this kind of document is the
  -- permission that stamps its approval chain. If a type carries none, that is
  -- a configuration fault worth naming rather than a reason to let anybody
  -- through.
  v_perm := d.create_permission;
  if v_perm is null then
    raise exception
      'ERPWARE_DOCUMENT_TYPE_HAS_NO_PERMISSION: % names no create permission, so nothing can be authorised against it',
      d.type_code
      using errcode = 'P0001',
            hint = 'Set create_permission on the document type, or on the base type behind it.';
  end if;
  perform erp.authorise(v_perm);

  select coalesce(sum(l.net_minor + coalesce(l.tax_minor, 0)), 0)::bigint into v_value
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = p_document_id
     and not l.is_cancelled;

  -- The department in force for whoever raised it, at the date it was raised.
  select pd.department_id into v_dept
    from erp.principal_department pd
   where pd.tenant_id = v_tenant
     and pd.app_user_id = d.created_by
     and pd.is_primary
     and pd.status = 'active'
     and daterange(pd.valid_from, pd.valid_to, '[)') @> current_date
   limit 1;

  v_chain := erp.resolve_approval_chain(
    lower(d.type_code), v_value, coalesce(d.currency, 'GBP')::char(3),
    v_dept, d.created_by, d.entity_id, d.site_id);

  insert into erp.approval_routing_stamp (
    tenant_id, object_type, object_id, department_id, value_minor, currency,
    resolved_chain, resolved_by)
  values (v_tenant, 'document', p_document_id, v_dept, v_value,
          coalesce(d.currency, 'GBP')::char(3), v_chain, erp.current_principal_id());

  perform erp.append_event('approval.chain_resolved', 'approval', p_document_id,
    v_chain || jsonb_build_object('document_id', p_document_id, 'type_code', d.type_code));

  if exists (select 1 from jsonb_array_elements(v_chain->'steps') st
              where (st->>'covered')::boolean) then
    perform erp.append_event('approval.cover_applied', 'approval', p_document_id, v_chain);
  end if;

  return v_chain;
end;
$$;

revoke all on function public.erp_stamp_document_approval(uuid) from public, anon;
grant execute on function public.erp_stamp_document_approval(uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The check that should have caught it in August.
--
-- This exact class was fixed once before, when invoice_reference was found
-- gating on a permission that was not the one granted for that surface. The fix
-- went in; no check followed it, and the class came back on a different door.
-- A gate naming a code that does not exist cannot fail in a test, because no
-- test asserts that a refusal was wrong — a refusal looks like the system
-- working.
--
-- So: every code an erp.authorise() call names must exist in erp_ref.permission.
-- It is a text rule over prosrc, which means it sees the literal calls and not
-- the computed ones — erp_stamp_document_approval above now passes a variable
-- and is invisible to it. That is the honest limit: this catches the mistake
-- that was actually made twice, which is hard-coding a code nobody has.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.authorise_code_report()
returns table (function_name text, permission_code text)
language sql
stable
set search_path = ''
as $$
  select distinct n.nspname || '.' || p.proname || '/' || p.pronargs, m[1]
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, 'erp\.authorise\(\s*''([a-z_]+\.[a-z_]+)''', 'g') m
   where n.nspname in ('erp', 'public')
     and not exists (select 1 from erp_ref.permission r where r.code = m[1])
   order by 1, 2;
$$;

comment on function erp.authorise_code_report() is
  'erp.authorise() calls naming a permission code that is not in the catalogue. '
  'Such a gate refuses every caller in every organisation and always has, and a '
  'refusal looks like the system working, so nothing else reports it.';

revoke all on function erp.authorise_code_report() from public, anon;
grant execute on function erp.authorise_code_report() to authenticated, service_role;

create or replace function erp.assert_authorise_codes_exist()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare n integer; v_detail text; v_codes integer;
begin
  select count(*), string_agg(r.function_name || ' gates on ' || r.permission_code, E'\n  ')
    into n, v_detail
    from erp.authorise_code_report() r;

  if n > 0 then
    raise exception E'ERPWARE_UNKNOWN_PERMISSION_CODE: % gate(s) name a permission that does not exist, so they refuse everybody:\n  %',
      n, v_detail
      using errcode = 'P0001',
            hint = 'Either the code is a typo for one in erp_ref.permission, or the door should '
                   'follow the module and read the permission from what it is acting on.';
  end if;

  select count(distinct m[1]) into v_codes
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace nn on nn.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, 'erp\.authorise\(\s*''([a-z_]+\.[a-z_]+)''', 'g') m
   where nn.nspname in ('erp', 'public');

  return format('permissions: %s codes are named literally by a gate, and every one is in the catalogue of %s',
                v_codes, (select count(*) from erp_ref.permission));
end;
$$;

revoke all on function erp.assert_authorise_codes_exist() from public, anon;
grant execute on function erp.assert_authorise_codes_exist() to authenticated, service_role;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
  values
  ('authorise_codes_exist', 'Every gate names a permission that exists',
   'assertion', 'platform', 'erp', 'assert_authorise_codes_exist', '{}',
   'authorise_code_report', '{}',
   'A gate naming a code that is not in erp_ref.permission refuses every caller in every organisation, and a refusal looks like the system working, so nothing else reports it.',
   true, 78)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- The suite.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.authorise_code_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
as $$
begin
  return query select 'no gate names a permission that does not exist',
    (select count(*) = 0 from erp.authorise_code_report()),
    'erp.authorise_code_report() is empty';

  return query select 'the two that did are the two that were reported',
    not exists (select 1 from erp_ref.permission where code in ('documents.read', 'documents.capture')),
    'neither code was invented to make the old gates pass';

  return query select 'reading a document''s approval chain no longer gates on a dead code',
    (select p.prosrc not like '%documents.read%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_document_approval_chain'),
    'the read joins its ungated siblings and relies on row security';

  return query select 'stamping still gates, and follows the module',
    (select p.prosrc like '%erp.authorise(v_perm)%' and p.prosrc like '%create_permission%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_stamp_document_approval'),
    'the permission comes from the document type, not from a literal';

  return query select 'a document type with no permission is refused, not waved through',
    (select p.prosrc like '%ERPWARE_DOCUMENT_TYPE_HAS_NO_PERMISSION%'
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'erp_stamp_document_approval'),
    'a null create_permission raises rather than skipping the gate';
end;
$$;

create or replace function erp_test.assert_authorise_code_suite()
returns text
language plpgsql
as $$
declare v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not s.passed), count(*),
         string_agg(format('  %s: %s', s.case_name, s.detail), E'\n') filter (where not s.passed)
    into v_failed, v_total, v_detail
    from erp_test.authorise_code_suite() s;

  if v_failed > 0 then
    raise exception E'ERPWARE_AUTHORISE_CODE_SUITE: % of % case(s) failed\n%',
      v_failed, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('authorise codes: %s of %s cases pass', v_total, v_total);
end;
$$;

notify pgrst, 'reload schema';

select erp.assert_authorise_codes_exist();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp_test.assert_authorise_code_suite();
