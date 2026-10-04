set lock_timeout = '30s';

-- =============================================================================
-- 20261006021000  A demonstration supplier has an address
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-140). Send to
-- supplier on a purchase order opened with the To box empty, on every
-- order. The address a send goes to is the supplier's purchasing contact
-- (erp.supplier_email_address(), read by erp.purchase_order_sends() and by
-- erp.send_purchase_order()), and no demonstration supplier had a contact:
-- erp.ensure_demo_configuration() creates the eight S- suppliers and no
-- seeder ever wrote an erp.party_contact for them. A demonstrator had to
-- make an address up.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.seed_demo_supplier_contacts(tenant): in a demonstration, each
--      active supplier with no contact holding an email address is given
--      one purchasing contact, the Orders desk, at an address on the
--      reserved example.invalid domain (orders.s-steel@example.invalid),
--      which nothing can deliver to. A demonstration never sends email in
--      any case (erp.claim_document_email_batch() claims nothing for one),
--      so nobody is written to. A supplier with an address keeps it, and
--      nothing is added to it. Nothing in an organisation that is not a
--      demonstration.
--   B. erp.ensure_demo_configuration() calls it, so a new demonstration has
--      them and an existing one gains them as it next trades.
--   C. DEMONSTRATIONS ONLY (organisations whose code is like 'demo-%'; not
--      clove-foods, not clove-erp, nobody's own data): every demonstration
--      there is today gains them here.
--
-- On production: each demonstration supplier without an email address
-- gains one purchasing contact (eight in a demonstration as configured).
-- erp.party_contact is a quiet table; nothing is altered. Every other
-- organisation's rows are untouched.
--
-- Proof: erp_test.demo_supplier_contacts_suite.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. An orders desk for each supplier of a demonstration
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.seed_demo_supplier_contacts(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer := 0;
begin
  -- Where a demonstration's purchase orders go (20261006021000): one
  -- purchasing contact for each active supplier that has no email address,
  -- on the reserved example.invalid domain. Only in a demonstration, which
  -- sends no email, and never beside an address somebody wrote.
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;
  if not erp.tenant_is_demonstration(p_tenant_id) then
    return 0;
  end if;

  insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, role_title, is_default)
  select p_tenant_id, p.id, 'purchasing', 'Orders desk',
         'orders.' || btrim(regexp_replace(lower(p.code), '[^a-z0-9]+', '-', 'g'), '-') || '@example.invalid',
         'Sales order processing',
         not exists (select 1 from erp.party_contact x
                      where x.tenant_id = p_tenant_id and x.party_id = p.id and x.is_default)
    from erp.party p
   where p.tenant_id = p_tenant_id
     and p.status = 'active'::erp.record_status
     and exists (select 1 from erp.party_role pr
                  where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                    and pr.role_kind = 'supplier' and pr.status = 'active')
     and not exists (select 1 from erp.party_contact x
                      where x.tenant_id = p_tenant_id and x.party_id = p.id
                        and nullif(btrim(coalesce(x.email, '')), '') is not null)
   order by p.code;
  get diagnostics v_n = row_count;

  return v_n;
end;
$$;

revoke all on function erp.seed_demo_supplier_contacts(uuid) from public, anon;

comment on function erp.seed_demo_supplier_contacts(uuid) is
  'A demonstration''s supplier order addresses: one purchasing contact on example.invalid for each active supplier with '
  'no email address, so Send to supplier has an address (20261006021000). Called by erp.ensure_demo_configuration().';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A demonstration is configured with them
-- ─────────────────────────────────────────────────────────────────────────────

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if erp.seed_demo_devices(p_tenant_id) > 0 then
    v_did := v_did || '"devices"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if erp.seed_demo_devices(p_tenant_id) > 0 then
    v_did := v_did || '"devices"'::jsonb;
  end if;

  -- Where each supplier's orders go, so Send to supplier has an address
  -- (20261006021000).
  if erp.seed_demo_supplier_contacts(p_tenant_id) > 0 then
    v_did := v_did || '"supplier order addresses"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261006021000') > 0 then
    raise notice '% already seeds the supplier addresses; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e90f050625a1a0eda38257f8c741fb12' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006021000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demo_supplier_contacts_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_conf   jsonb;
  v_again  jsonb;
  v_suppliers integer; v_bad integer; v_refused integer; v_before integer; v_after integer;
  v_pack   integer;
  v_kept   text;
  v_steel  text;
begin
  begin
    -- ── The fixture: a demonstration ────────────────────────────────────────
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzsc' || v_tag, 'Demo Supplier Contacts Suite',
      'admin@demo-zzsc' || v_tag || '.test', 'Contacts Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzsc' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    -- ── 1. Every supplier has an address a send goes to ─────────────────────
    select count(*),
           count(*) filter (where erp.supplier_email_address(p.id) ->> 'address' is null)
      into v_suppliers, v_bad
      from erp.party p
     where p.tenant_id = rb.tenant_id and p.status = 'active'
       and exists (select 1 from erp.party_role pr where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                      and pr.role_kind = 'supplier' and pr.status = 'active');
    select erp.supplier_email_address(p.id) ->> 'address' into v_steel
      from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'S-STEEL';
    v_cases := v_cases + 1;
    case_name := 'every supplier of a demonstration has an order address on example.invalid';
    passed := v_state is null and v_suppliers > 0 and v_bad = 0
          and v_steel = 'orders.s-steel@example.invalid'
          and (v_conf -> 'installed') ? 'supplier order addresses';
    detail := coalesce(v_state, format('%s supplier(s), %s without | S-STEEL %s', v_suppliers, v_bad, v_steel));
    return next;

    -- ── 2. A send would take every one of them ──────────────────────────────
    v_step := 'each address read as a send reads it';
    v_refused := 0;
    declare
      r record;
    begin
      for r in select erp.supplier_email_address(p.id) ->> 'address' as address
                 from erp.party p
                where p.tenant_id = rb.tenant_id
                  and exists (select 1 from erp.party_role pr where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                                 and pr.role_kind = 'supplier' and pr.status = 'active') loop
        begin
          if erp.email_address_or_refuse(r.address) is distinct from r.address then
            v_refused := v_refused + 1;
          end if;
        exception when others then
          v_refused := v_refused + 1;
        end;
      end loop;
    end;
    v_cases := v_cases + 1;
    case_name := 'a send to the supplier takes the address as it stands';
    passed := v_state is null and v_refused = 0;
    detail := coalesce(v_state, format('%s refused', v_refused));
    return next;

    -- ── 3. Asked again, nothing more, and an address somebody wrote stays ───
    v_step := 'addresses somebody wrote, configured again';
    update erp.party_contact c set email = 'buying@midland-steel.test'
      from erp.party p
     where p.tenant_id = rb.tenant_id and p.code = 'S-STEEL'
       and c.tenant_id = p.tenant_id and c.party_id = p.id;
    delete from erp.party_contact c
     using erp.party p
     where p.tenant_id = rb.tenant_id and p.code = 'S-PACK'
       and c.tenant_id = p.tenant_id and c.party_id = p.id;
    insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, is_default)
    select rb.tenant_id, p.id, 'accounts', 'Accounts', 'accounts@packwell.test', true
      from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'S-PACK';
    select count(*) into v_before from erp.party_contact c where c.tenant_id = rb.tenant_id;
    v_again := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select count(*) into v_after from erp.party_contact c where c.tenant_id = rb.tenant_id;
    select erp.supplier_email_address(p.id) ->> 'address' into v_kept
      from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'S-STEEL';
    select count(*) into v_pack
      from erp.party_contact c join erp.party p on p.tenant_id = c.tenant_id and p.id = c.party_id
     where p.tenant_id = rb.tenant_id and p.code = 'S-PACK';
    v_cases := v_cases + 1;
    case_name := 'configured again nothing is added, and an address somebody wrote is kept';
    passed := v_state is null and not ((v_again -> 'installed') ? 'supplier order addresses')
          and erp.seed_demo_supplier_contacts(rb.tenant_id) = 0
          and v_after = v_before and v_kept = 'buying@midland-steel.test' and v_pack = 1;
    detail := coalesce(v_state, format('%s | %s contact(s) then %s | S-STEEL %s | S-PACK %s contact(s)',
                                       v_again -> 'installed', v_before, v_after, v_kept, v_pack));
    return next;

    -- ── 4. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzsc-' || v_tag, 'Not A Demo Contacts Suite', 'admin@zzsc-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzsc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    v_cases := v_cases + 1;
    case_name := 'an organisation that is not a demonstration is given no supplier address';
    passed := v_state is null and not ((v_conf -> 'installed') ? 'supplier order addresses')
          and not exists (select 1 from erp.party_contact c where c.tenant_id = rc.tenant_id);
    detail := coalesce(v_state, (v_conf -> 'installed')::text);
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
    raise exception 'CLOVEERP_DEMO_SUPPLIER_CONTACTS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_supplier_contacts_suite() from public, anon;

comment on function erp_test.demo_supplier_contacts_suite() is
  'A demonstration supplier has an address (20261006021000): every demo supplier has an order address a send takes; '
  'nothing twice, nothing overwritten, nothing outside a demonstration.';

create or replace function erp_test.assert_demo_supplier_contacts_suite()
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
    from erp_test.demo_supplier_contacts_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_SUPPLIER_CONTACTS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Send to supplier in the demonstration would open with no address. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_DEMO_SUPPLIER_CONTACTS_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demo supplier contacts: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_supplier_contacts_suite() from public, anon;

comment on function erp_test.assert_demo_supplier_contacts_suite() is
  'A demonstration''s suppliers have an order address, and only a demonstration is given one (20261006021000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.seed_demo_supplier_contacts(r.id);
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'demo supplier contacts: % address(es) added to %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$seed$;

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
