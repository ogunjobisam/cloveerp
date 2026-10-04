set lock_timeout = '30s';

-- =============================================================================
-- 20261006031000  A VAT return is for a British registration
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-100), and confirmed
-- there: ACME-EU, the demonstration's Dutch company (Acme Manufacturing BV,
-- NL, euros), holds VAT registration number GB123456789 under jurisdiction NL,
-- and VAT returns offered it a UK nine-box return in euros.
--
-- Two causes. erp.ensure_demo_configuration() gave every active company of a
-- demonstration the same British number, GB123456789, whatever its country.
-- And erp.vat_obligations(), which erp_vat_obligations(), finalising and the
-- export all read, made HMRC returns from any registration whose type is
-- VAT, without asking whose: a company registered in the Netherlands has a
-- Dutch return to make, which this product does not make.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.vat_obligations(): only a registration with jurisdiction GB makes
--      UK returns. A company registered only abroad has no obligation here,
--      so VAT returns does not list it and finalising refuses with the
--      refusal a company with no registration already meets. A company with
--      a British registration and a newer one abroad is returned under its
--      British number. Nothing else in it moves.
--   B. erp.ensure_demo_configuration(): the demonstration's British number is
--      given to its British companies only (country GB, or none). A company
--      elsewhere is given no VAT registration: a number for it would be
--      invented, and nothing in the demonstration trades through it.
--   C. erp.end_demo_vat_registrations_abroad(tenant): in a demonstration, a
--      VAT registration held under another jurisdiction with a British
--      number is ended yesterday (valid_to), not deleted, so what it said
--      stays on the record. Nothing in an organisation that is not a
--      demonstration.
--   D. The proofs: erp_test.vat_obligation_suite() gains a case (a Dutch
--      registration makes no UK obligation, and a British one beside a newer
--      Dutch one keeps its own number), eighteen from seventeen;
--      erp_test.demonstration_vat_returns_suite() gains one (a demonstration
--      with a Dutch company gives it no British number, lists only its
--      British company, and the repair ends a British number abroad once),
--      ten from nine.
--   E. DEMONSTRATIONS ONLY (organisations whose code is like 'demo-%'; not
--      clove-foods, not clove-erp, nobody's own data): C is run in each.
--
-- On production: in each demonstration, ACME-EU's registration GB123456789
-- (NL) gains valid_to yesterday, and VAT returns lists only ACME. Returns
-- already finalised for ACME-EU stay as documents; they are history and are
-- not withdrawn. In every organisation, a company whose only VAT
-- registration is outside GB stops being offered UK returns (no organisation
-- but the demonstrations is known to hold one). erp.entity_tax_registration
-- is a quiet table; nothing is altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Only a British registration makes a UK return
-- ─────────────────────────────────────────────────────────────────────────────

do $obligations$
declare
  v_sig  constant text := 'erp.vat_obligations(uuid,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  -- A company with no VAT registration in force has none.
$o$,
    $n$  -- A company with no VAT registration in force has none, and nor has one
  -- registered only outside Britain (20261006031000): its return is not a UK
  -- return. Of a company registered here and abroad, the British number.
$n$,
    $o$           and upper(g.registration_type) like 'VAT%'
           and g.valid_from <= t.on_day
$o$,
    $n$           and upper(g.registration_type) like 'VAT%'
           and upper(g.jurisdiction) = 'GB'
           and g.valid_from <= t.on_day
$n$];
  i integer;
begin
  if strpos(v_src, '20261006031000') > 0 then
    raise notice '% already reads British registrations only; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '41540f5c9fa925d5787c17b0a650abbe' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006031000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for i in 1 .. array_length(v_pairs, 1) by 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[i], ''))) / length(v_pairs[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, (i + 1) / 2;
    end if;
    v_def := replace(v_def, v_pairs[i], v_pairs[i + 1]);
  end loop;
  execute v_def;
end
$obligations$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. A demonstration's British number is for its British companies
-- ─────────────────────────────────────────────────────────────────────────────

do $configure$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    select p_tenant_id, e.id, coalesce(e.country_code, 'GB'), 'VAT',
           'GB123456789', current_date - 400
      from erp.entity e
     where e.tenant_id = p_tenant_id and e.status = 'active'::erp.record_status;
    v_did := v_did || '"tax registration"'::jsonb;
$o$;
  v_new  constant text := $n$    select p_tenant_id, e.id, 'GB', 'VAT',
           'GB123456789', current_date - 400
      from erp.entity e
     where e.tenant_id = p_tenant_id and e.status = 'active'::erp.record_status
       -- A British number for a British company (20261006031000). A company
       -- elsewhere is given none: its number would be invented, and a
       -- British one made it a UK return in euros.
       and coalesce(e.country_code, 'GB') = 'GB';
    if found then
      v_did := v_did || '"tax registration"'::jsonb;
    end if;
$n$;
begin
  if strpos(v_src, '20261006031000') > 0 then
    raise notice '% already registers British companies only; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '7ff0e37da97ff9cf125f42ea389fbdcd' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006031000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. A British number held abroad, in a demonstration, is ended
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.end_demo_vat_registrations_abroad(p_tenant_id uuid)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_n integer := 0;
begin
  -- A demonstration's VAT registrations (20261006031000): one held under a
  -- jurisdiction other than GB with a British number is the demonstration's
  -- number given to a company abroad. It is ended yesterday, not deleted.
  -- Only in a demonstration.
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

  update erp.entity_tax_registration g
     set valid_to = greatest(g.valid_from, current_date - 1)
   where g.tenant_id = p_tenant_id
     and upper(g.registration_type) like 'VAT%'
     and upper(g.jurisdiction) <> 'GB'
     and upper(g.registration_number) like 'GB%'
     and (g.valid_to is null or g.valid_to > greatest(g.valid_from, current_date - 1));
  get diagnostics v_n = row_count;

  return v_n;
end;
$$;

revoke all on function erp.end_demo_vat_registrations_abroad(uuid) from public, anon;

comment on function erp.end_demo_vat_registrations_abroad(uuid) is
  'A demonstration''s VAT registrations held abroad under a British number are ended yesterday, not deleted '
  '(20261006031000). Nothing outside a demonstration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proofs
-- ─────────────────────────────────────────────────────────────────────────────

do $suite_obligations$
declare
  v_sig  constant text := 'erp_test.vat_obligation_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 17;
$o$,
    $n$  c_expected constant integer := 18;
$n$,
    $o$  v_planned text;
begin
$o$,
    $n$  v_planned text;
  -- A registration abroad (20261006031000).
  v_abroad_n integer; v_abroad_n2 integer; v_abroad_ended integer; v_beside integer; v_vrns text; v_gb_vrn text;
begin
$n$,
    $o$    -- ── 15. Not reversed ────────────────────────────────────────────────────
$o$,
    $n$    -- ── 18. A registration abroad makes no UK return (20261006031000) ────────
    v_step := 'the company''s VAT registration made a Dutch one, then a Dutch one beside the British';
    begin
      select g.registration_number into v_gb_vrn from erp.entity_tax_registration g
       where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
      update erp.entity_tax_registration g set jurisdiction = 'NL'
       where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
      select count(*) into v_abroad_n from erp.vat_obligations(v_entity);
      select count(*) into v_abroad_n2 from erp.vat_obligations(null) o where o.entity_id = v_entity;
      begin
        perform public.erp_finalise_vat_return(v_entity, v_q_to);
        v_err := 'finalised';
      exception when others then v_err := left(sqlerrm, 160); end;
      -- Not a demonstration, so the repair leaves it alone.
      v_abroad_ended := erp.end_demo_vat_registrations_abroad(rb.tenant_id);
      update erp.entity_tax_registration g set jurisdiction = 'GB'
       where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
      insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction, registration_type,
                                               registration_number, valid_from)
      values (rb.tenant_id, v_entity, 'NL', 'VAT', 'NL123456789B01', current_date - 10);
      select count(*), string_agg(distinct o.vrn, ',') into v_beside, v_vrns from erp.vat_obligations(v_entity) o;
      raise exception 'CLOVEERP_REGISTRATION_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_REGISTRATION_ROLLED_BACK' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a company registered for VAT only in the Netherlands has no UK obligation and nothing to finalise, and one registered here with a newer Dutch registration beside it is returned under its British number';
    passed := v_state is null
          and v_abroad_n = 0 and v_abroad_n2 = 0
          and v_err like 'CLOVEERP_NO_VAT_OBLIGATION:%'
          and v_abroad_ended = 0
          and v_beside = 3 and v_vrns = v_gb_vrn
          and (select count(*) from erp.vat_obligations(v_entity)) = 3;
    detail := coalesce(v_state, format('abroad: %s and %s obligation(s), %s; %s ended; beside: %s obligation(s) under %s (British %s)',
                                       v_abroad_n, v_abroad_n2, v_err, v_abroad_ended, v_beside, v_vrns, v_gb_vrn));
    return next;

    -- ── 15. Not reversed ────────────────────────────────────────────────────
$n$];
  i integer;
begin
  if strpos(v_src, '20261006031000') > 0 then
    raise notice '% already proves a registration abroad; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '286cabf45ce39bd596cfedfafe28c8bd' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006031000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for i in 1 .. array_length(v_pairs, 1) by 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[i], ''))) / length(v_pairs[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, (i + 1) / 2;
    end if;
    v_def := replace(v_def, v_pairs[i], v_pairs[i + 1]);
  end loop;
  execute v_def;
end
$suite_obligations$;

create or replace function erp_test.assert_vat_obligation_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.vat_obligation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_OBLIGATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A VAT return would be made for the wrong period, from the wrong entries, or changed after it was final. Read the case that failed.';
  end if;
  -- Eighteen since a registration abroad (20261006031000).
  if v_total <> 18 then
    raise exception 'CLOVEERP_VAT_OBLIGATION_SUITE_SHRANK: % case(s), expected 18', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat obligation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_obligation_suite() from public, anon;

comment on function erp_test.assert_vat_obligation_suite() is
  'erp_test.vat_obligation_suite(), eighteen cases: a registration abroad makes no UK return (20261006031000).';

do $suite_demonstration$
declare
  v_sig  constant text := 'erp_test.demonstration_vat_returns_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 9;
$o$,
    $n$  c_expected constant integer := 10;
$n$,
    $o$  v_input bigint; v_home integer; v_abroad integer; v_wrong integer;
begin
$o$,
    $n$  v_input bigint; v_home integer; v_abroad integer; v_wrong integer;
  -- A demonstration with a Dutch company (20261006031000).
  a4       uuid := '00000000-0000-4000-8000-00000000dc0d';
  v_td     uuid; v_nl uuid; v_gb uuid; v_conf jsonb;
  v_nl_regs integer; v_gb_reg text; v_ended integer; v_ended_again integer;
begin
$n$,
    $o$    values (a1, 'admin@demo-zzvata.test'), (a2, 'admin@demo-zzvatb.test'), (a3, 'admin@demo-zzvatc.test');
$o$,
    $n$    values (a1, 'admin@demo-zzvata.test'), (a2, 'admin@demo-zzvatb.test'), (a3, 'admin@demo-zzvatc.test'),
           (a4, 'admin@demo-zzvatd.test');
$n$,
    $o$    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$,
    $n$    -- ── 10. A Dutch company is given no British number (20261006031000) ─────
    v_step := 'a fourth demonstration, with a Dutch company beside its British one';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('demo-zzvatd', 'VAT returns, two companies',
                                                'admin@demo-zzvatd.test', 'VAT Two Companies Admin');
    v_td := rb.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    update erp.environment set is_live = false where tenant_id = v_td and is_self;
    select e.id into v_gb from erp.entity e where e.tenant_id = v_td order by e.code limit 1;
    insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code)
    values (v_td, 'ZZ-NL', 'Demo Europe', 'Demo Europe BV', 'EUR', 'NL')
    returning id into v_nl;
    v_conf := erp.ensure_demo_configuration(v_td, rb.admin_user_id);
    select count(*) into v_nl_regs from erp.entity_tax_registration g
     where g.tenant_id = v_td and g.entity_id = v_nl;
    select g.jurisdiction || ' ' || g.registration_number into v_gb_reg from erp.entity_tax_registration g
     where g.tenant_id = v_td and g.entity_id = v_gb and g.valid_to is null;
    v_rows := public.erp_vat_obligations(null);

    v_step := 'the British number given to the Dutch company, as the demonstration once did, and repaired';
    insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction, registration_type,
                                             registration_number, valid_from)
    values (v_td, v_nl, 'NL', 'VAT', 'GB123456789', current_date - 400);
    v_ended := erp.end_demo_vat_registrations_abroad(v_td);
    v_ended_again := erp.end_demo_vat_registrations_abroad(v_td);
    v_cases := v_cases + 1;
    case_name := 'a demonstration gives its British company the British number and its Dutch company none, VAT returns lists the British company only, and a British number held abroad is ended once, not deleted';
    passed := v_state is null
          and v_nl_regs = 0
          and v_gb_reg = 'GB GB123456789'
          and (v_conf -> 'installed') ? 'tax registration'
          and jsonb_array_length(v_rows) > 0
          and not exists (select 1 from jsonb_array_elements(v_rows) o where (o ->> 'entity_id')::uuid = v_nl)
          and not exists (select 1 from jsonb_array_elements(v_rows) o where (o ->> 'entity_id')::uuid <> v_gb)
          and v_ended = 1 and v_ended_again = 0
          and not erp.entity_is_tax_registered(v_nl)
          and exists (select 1 from erp.entity_tax_registration g
                       where g.tenant_id = v_td and g.entity_id = v_nl and g.valid_to = current_date - 1)
          and not exists (select 1 from erp.vat_obligations(v_nl));
    detail := coalesce(v_state, format('%s Dutch registration(s); British %s; %s obligation(s); ended %s then %s; installed %s',
                                       v_nl_regs, v_gb_reg, jsonb_array_length(v_rows), v_ended, v_ended_again,
                                       v_conf -> 'installed'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
$n$,
    $o$        and not exists (select 1 from erp.tenant t where t.code in ('demo-zzvata', 'demo-zzvatb', 'demo-zzvatc'))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, a3));
  detail := coalesce(v_state, 'the three demonstrations rolled back with their trading, returns and upgrade');$o$,
    $n$        and not exists (select 1 from erp.tenant t where t.code in ('demo-zzvata', 'demo-zzvatb', 'demo-zzvatc', 'demo-zzvatd'))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, a3, a4));
  detail := coalesce(v_state, 'the four demonstrations rolled back with their trading, returns and upgrade');$n$];
  i integer;
begin
  if strpos(v_src, '20261006031000') > 0 then
    raise notice '% already proves a demonstration''s Dutch company; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '9bd7a62020aee6a16ea7b7c238035bcb' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006031000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  for i in 1 .. array_length(v_pairs, 1) by 2 loop
    if (length(v_def) - length(replace(v_def, v_pairs[i], ''))) / length(v_pairs[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, (i + 1) / 2;
    end if;
    v_def := replace(v_def, v_pairs[i], v_pairs[i + 1]);
  end loop;
  execute v_def;
end
$suite_demonstration$;

create or replace function erp_test.assert_demonstration_vat_returns_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.demonstration_vat_returns_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A demonstration would show no finalised quarter, return one it never traded, or leave none to finalise. Read the case that failed.';
  end if;
  -- Ten since a demonstration's Dutch company (20261006031000).
  if v_total <> 10 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration vat returns: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_vat_returns_suite() from public, anon;

comment on function erp_test.assert_demonstration_vat_returns_suite() is
  'erp_test.demonstration_vat_returns_suite(), ten cases: a demonstration''s Dutch company is given no British number '
  '(20261006031000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Every demonstration there is today, and said
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  r   record;
  v_n integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.end_demo_vat_registrations_abroad(r.id);
    -- The checks the writes left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    if v_n > 0 then
      raise warning 'vat registrations: % British number(s) held abroad ended in %', v_n, r.code;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
