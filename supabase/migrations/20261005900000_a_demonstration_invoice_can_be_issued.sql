set lock_timeout = '30s';

-- =============================================================================
-- 20261005900000  A demonstration invoice can be issued
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October. Order to cash ran from
-- a quotation to a delivered shipment and stopped at the invoice:
--
--   "Before it is issued, this invoice needs: Company registration number,
--    Registered office, Customer invoice address"
--
-- The refusal is right: an invoice that cannot name its issuer and its
-- customer is not one (erp.validate_sales_invoice_issue). The demonstration
-- had none of the three. Its companies carry no registration number and no
-- registered office, and none of its customers has an address. Its own
-- history issues invoices by the lifecycle, which does not ask; a person
-- issuing one by hand is asked, and could not answer without rewriting the
-- organisation's settings.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.seed_demo_legal_details(tenant): in a demonstration, each company
--      without a registration number is given one that says what it is
--      (DEMO-0001, ...), each company without a registered office is given
--      one, and each customer without an invoice address is given one, in the
--      country it is already in. Anything somebody wrote is kept. Nothing in
--      an organisation that is not a demonstration.
--   B. erp.ensure_demo_configuration() calls it, so a new demonstration has
--      them and an existing one gains them as it next trades.
--   C. Every demonstration there is today gains them here.
--
-- Proof: erp_test.demo_legal_details_suite.
-- =============================================================================

create or replace function erp.demo_address(p_country character, p_n integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- An address in the country a demonstration company or customer is in
  -- (20261005900000). Made up, and reads as made up.
  select jsonb_build_object(
    'line', (10 + coalesce(p_n, 0))::text || ' Demonstration Way',
    'locality', case upper(coalesce(p_country, 'GB'))
                  when 'GB' then 'Birmingham' when 'IE' then 'Dublin' when 'NL' then 'Rotterdam'
                  when 'DE' then 'Hamburg' when 'FR' then 'Lyon' when 'NO' then 'Bergen'
                  else 'Demonstration Town' end,
    'postcode', case upper(coalesce(p_country, 'GB'))
                  when 'GB' then 'B1 1AA' when 'IE' then 'D01 X2X2' when 'NL' then '3011 AA'
                  when 'DE' then '20095' when 'FR' then '69001' when 'NO' then '5003'
                  else '00000' end,
    'country_code', upper(coalesce(p_country, 'GB')))
$$;

revoke all on function erp.demo_address(character, integer) from public, anon;

create or replace function erp.seed_demo_legal_details(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n     integer := 0;
  v_m     integer := 0;
begin
  -- What a demonstration's invoices need before they can be issued by hand
  -- (20261005900000): each company's registration number and registered
  -- office, and each customer's invoice address. Only in a demonstration, and
  -- never over what somebody wrote.
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

  with numbered as (
    select e.id, row_number() over (order by e.code) as n
      from erp.entity e
     where e.tenant_id = p_tenant_id and e.status = 'active'
  )
  update erp.entity e
     set registration_number = 'DEMO-' || lpad(numbered.n::text, 4, '0'), updated_at = now()
    from numbered
   where e.id = numbered.id
     and coalesce(btrim(e.registration_number), '') = '';
  get diagnostics v_m = row_count;
  v_n := v_n + v_m;

  insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default)
  select p_tenant_id, e.party_id, 'registered', 'Registered office',
         array[a.v ->> 'line'], a.v ->> 'locality', a.v ->> 'postcode', (a.v ->> 'country_code')::character(2), true
    from (select e2.*, row_number() over (order by e2.code)::integer as n
            from erp.entity e2
           where e2.tenant_id = p_tenant_id and e2.status = 'active' and e2.party_id is not null) e
   cross join lateral (select erp.demo_address(e.country_code, e.n) as v) a
   where not exists (select 1 from erp.party_address x
                      where x.tenant_id = p_tenant_id and x.party_id = e.party_id
                        and x.address_kind = 'registered');
  get diagnostics v_m = row_count;
  v_n := v_n + v_m;

  insert into erp.party_address (tenant_id, party_id, address_kind, label, lines, locality, postcode, country_code, is_default)
  select p_tenant_id, c.id, 'billing', 'Invoice address',
         array[a.v ->> 'line'], a.v ->> 'locality', a.v ->> 'postcode', (a.v ->> 'country_code')::character(2), true
    from (select p.id, p.country_code, 20 + row_number() over (order by p.code)::integer as n
            from erp.party p
           where p.tenant_id = p_tenant_id and p.status = 'active'::erp.record_status
             and exists (select 1 from erp.party_role pr
                          where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                            and pr.role_kind = 'customer' and pr.status = 'active')) c
   cross join lateral (select erp.demo_address(c.country_code, c.n) as v) a
   where not exists (select 1 from erp.party_address x
                      where x.tenant_id = p_tenant_id and x.party_id = c.id
                        and x.address_kind = 'billing');
  get diagnostics v_m = row_count;
  v_n := v_n + v_m;

  return v_n;
end;
$$;

revoke all on function erp.seed_demo_legal_details(uuid) from public, anon;

comment on function erp.seed_demo_legal_details(uuid) is
  'A demonstration''s company registration numbers, registered offices and customer invoice addresses, where '
  'it has none, so an invoice can be issued by hand (20261005900000). Called by erp.ensure_demo_configuration().';

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if erp.seed_demo_prices(p_tenant_id) > 0 then
    v_did := v_did || '"price lists"'::jsonb;
  end if;
$o$;
  v_new  constant text := $n$  if erp.seed_demo_prices(p_tenant_id) > 0 then
    v_did := v_did || '"price lists"'::jsonb;
  end if;

  -- What an invoice needs before somebody can issue it by hand: the
  -- companies' registration and registered office, the customers' invoice
  -- addresses (20261005900000).
  if erp.seed_demo_legal_details(p_tenant_id) > 0 then
    v_did := v_did || '"company and customer details"'::jsonb;
  end if;
$n$;
begin
  if strpos(v_src, '20261005900000') > 0 then
    raise notice '% already seeds the legal details; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'd88a4909679e3d1c46145086df73c1a2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005900000 expects (md5 %)', v_sig, md5(v_src);
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

create or replace function erp_test.demo_legal_details_suite()
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
  v_companies integer; v_customers integer; v_bad integer;
  v_kept   text;
begin
  begin
    -- ── The fixture: a demonstration ────────────────────────────────────────
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzld' || v_tag, 'Demo Legal Details Suite',
      'admin@demo-zzld' || v_tag || '.test', 'Details Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzld' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select count(*) into v_companies from erp.entity e where e.tenant_id = rb.tenant_id and e.status = 'active';
    select count(*) into v_customers
      from erp.party p
     where p.tenant_id = rb.tenant_id and p.status = 'active'
       and exists (select 1 from erp.party_role pr where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                      and pr.role_kind = 'customer' and pr.status = 'active');

    -- ── 1. Every company can be named on an invoice ─────────────────────────
    select count(*) into v_bad
      from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active'
       and (coalesce(btrim(e.registration_number), '') = ''
            or not exists (select 1 from erp.party_address x
                            where x.tenant_id = e.tenant_id and x.party_id = e.party_id
                              and x.address_kind = 'registered'));
    v_cases := v_cases + 1;
    case_name := 'every company of a demonstration has a registration number and a registered office';
    passed := v_state is null and v_companies > 0 and v_bad = 0
          and (v_conf -> 'installed') ? 'company and customer details';
    detail := coalesce(v_state, format('%s compan(ies), %s without', v_companies, v_bad));
    return next;

    -- ── 2. Every customer can be invoiced ───────────────────────────────────
    select count(*) into v_bad
      from erp.party p
     where p.tenant_id = rb.tenant_id and p.status = 'active'
       and exists (select 1 from erp.party_role pr where pr.tenant_id = p.tenant_id and pr.party_id = p.id
                      and pr.role_kind = 'customer' and pr.status = 'active')
       and not exists (select 1 from erp.party_address x
                        where x.tenant_id = p.tenant_id and x.party_id = p.id and x.address_kind = 'billing');
    v_cases := v_cases + 1;
    case_name := 'every customer of a demonstration has an invoice address';
    passed := v_state is null and v_customers > 0 and v_bad = 0;
    detail := coalesce(v_state, format('%s customer(s), %s without', v_customers, v_bad));
    return next;

    -- ── 3. Asked again, nothing more, and what somebody wrote is kept ───────
    v_step := 'a company whose number somebody set, configured again';
    update erp.entity set registration_number = '01234567'
     where id = (select e.id from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1);
    v_again := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.registration_number into v_kept from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    v_cases := v_cases + 1;
    case_name := 'configured again nothing is added, and a number somebody set is kept';
    passed := v_state is null and not ((v_again -> 'installed') ? 'company and customer details')
          and erp.seed_demo_legal_details(rb.tenant_id) = 0 and v_kept = '01234567';
    detail := coalesce(v_state, format('%s | kept %s', v_again -> 'installed', v_kept));
    return next;

    -- ── 4. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzld-' || v_tag, 'Not A Demo Details Suite', 'admin@zzld-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzld-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    v_cases := v_cases + 1;
    case_name := 'an organisation that is not a demonstration is given none of them';
    passed := v_state is null and not ((v_conf -> 'installed') ? 'company and customer details')
          and not exists (select 1 from erp.entity e where e.tenant_id = rc.tenant_id and e.registration_number like 'DEMO-%')
          and not exists (select 1 from erp.party_address x where x.tenant_id = rc.tenant_id and x.label in ('Registered office', 'Invoice address'));
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
    raise exception 'CLOVEERP_DEMO_LEGAL_DETAILS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demo_legal_details_suite() from public, anon;

comment on function erp_test.demo_legal_details_suite() is
  'A demonstration invoice can be issued (20261005900000): every demo company has its registration and '
  'registered office and every demo customer an invoice address; nothing twice, nothing overwritten, nothing outside a demonstration.';

create or replace function erp_test.assert_demo_legal_details_suite()
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
    from erp_test.demo_legal_details_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMO_LEGAL_DETAILS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'An invoice raised by hand in the demonstration could not be issued. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_DEMO_LEGAL_DETAILS_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demo legal details: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demo_legal_details_suite() from public, anon;

comment on function erp_test.assert_demo_legal_details_suite() is
  'A demonstration holds what an invoice needs to be issued by hand, and only a demonstration is given it (20261005900000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $seed$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.seed_demo_legal_details(r.id);
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'demo legal details: % detail(s) added to %', v_n, r.code;
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
