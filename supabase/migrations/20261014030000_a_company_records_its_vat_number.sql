-- A company records its VAT number.
--
-- Found trying HMRC's sandbox on the demonstration (owner, 14 October 2026).
-- A return is filed under the company's VAT number as erp.company_vrn reads
-- it from erp.entity_tax_registration, and no door wrote that table: the
-- demonstration and the suites seed it, and a client could not enter or
-- change its own VAT number, so it could not connect to HMRC or file.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_record_vat_registration(company, VAT number, from): the number as
--      HMRC takes it (the GB and spaces taken off; nine digits, or twelve for
--      a branch), recorded as the company's VAT registration from the day
--      given; the one in force ends the day before. The same number again
--      changes nothing. finance.configure.
--   B. erp_test.vat_registration_suite proves it.

create or replace function erp.record_vat_registration(p_entity_id uuid, p_vat_number text,
                                                       p_valid_from date default null)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_digits text := regexp_replace(regexp_replace(upper(coalesce(p_vat_number, '')), '\s', '', 'g'), '^GB', '');
  v_from   date := coalesce(p_valid_from, current_date);
  v_now    text;
begin
  if not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.id = p_entity_id) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is no company of this organisation', p_entity_id
      using errcode = '23503', hint = 'Choose a company from the list.';
  end if;
  perform erp.authorise('finance.configure', p_entity_id, null, null, 'entity', p_entity_id, null);
  if v_digits !~ '^[0-9]{9}([0-9]{3})?$' then
    raise exception 'CLOVEERP_VAT_NUMBER_INVALID: % is not a UK VAT number', coalesce(p_vat_number, 'nothing')
      using errcode = '23514', hint = 'Give the nine digits on the VAT registration certificate, with or without GB in front.';
  end if;

  v_now := erp.company_vrn(p_entity_id);
  if v_now = v_digits then
    return 'GB' || v_digits;
  end if;

  update erp.entity_tax_registration g
     set valid_to = greatest(v_from - 1, g.valid_from), updated_at = now()
   where g.tenant_id = v_tenant and g.entity_id = p_entity_id and upper(g.registration_type) like 'VAT%'
     and g.valid_from <= v_from and (g.valid_to is null or g.valid_to >= v_from);

  insert into erp.entity_tax_registration (tenant_id, entity_id, jurisdiction, registration_type,
                                           registration_number, valid_from)
  values (v_tenant, p_entity_id, 'GB', 'VAT', 'GB' || v_digits, v_from);
  return 'GB' || v_digits;
end;
$$;
revoke all on function erp.record_vat_registration(uuid, text, date) from public, anon;

create or replace function public.erp_record_vat_registration(p_entity_id uuid, p_vat_number text,
                                                              p_valid_from date default null)
returns text
language sql
set search_path = ''
as $$ select erp.record_vat_registration(p_entity_id, p_vat_number, p_valid_from) $$;
revoke all on function public.erp_record_vat_registration(uuid, text, date) from public, anon;
grant execute on function public.erp_record_vat_registration(uuid, text, date) to authenticated, service_role;
comment on function public.erp_record_vat_registration(uuid, text, date) is
  'Records a company''s VAT number as HMRC takes it, from a day; the registration in force ends the day before '
  '(20261014030000). Authorises finance.configure.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_record_vat_registration', 'erp.record_vat_registration',
   'Records a company''s VAT number, ending the one in force; authorises finance.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_VAT_NUMBER_INVALID',
  'Recording a company''s VAT number that is not nine digits, or twelve for a branch.',
  'Returns are filed with HMRC under it, and HMRC takes nothing else.',
  'Give the nine digits on the VAT registration certificate, with or without GB in front.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Recording a company''s VAT number (20261014030000).'
  from (values
    ('Record the company''s VAT number'),
    ('The number VAT returns are filed with HMRC under, from the day given. The number in force until then ends the day before.'),
    ('VAT number'),
    ('From'),
    ('Nine digits, with or without GB in front, as on the VAT registration certificate.')) v(text)
on conflict do nothing;

create or replace function erp_test.vat_registration_suite()
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
  v_tenant uuid;
  v_entity uuid;
  v_ok     boolean;
  v_msg    text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzvrn' || v_tag, 'VAT Number Suite',
      'admin@demo-zzvrn' || v_tag || '.test', 'VAT Number Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzvrn' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_tenant := rb.tenant_id;
    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant and e.status = 'active' order by e.code limit 1;

    -- ── 1. Recorded as HMRC takes it ────────────────────────────────────────
    v_step := 'a number typed with GB and spaces';
    perform public.erp_record_vat_registration(v_entity, 'gb 664 9625 92', current_date);
    v_cases := v_cases + 1;
    case_name := 'a VAT number typed with GB and spaces is recorded as HMRC takes it, and filed under from today';
    passed := v_state is null and erp.company_vrn(v_entity) = '664962592';
    detail := coalesce(v_state, erp.company_vrn(v_entity));
    return next;

    -- ── 2. Replacing, and the same again ────────────────────────────────────
    v_step := 'a new number from tomorrow';
    perform public.erp_record_vat_registration(v_entity, '123456789', current_date + 1);
    perform public.erp_record_vat_registration(v_entity, 'GB664962592', current_date);
    v_cases := v_cases + 1;
    case_name := 'a new number from tomorrow ends the one in force today, and the same number again changes nothing';
    passed := v_state is null
          and erp.company_vrn(v_entity) = '664962592'
          and exists (select 1 from erp.entity_tax_registration g
                       where g.entity_id = v_entity and g.registration_number = 'GB123456789' and g.valid_from = current_date + 1)
          and (select g.valid_to from erp.entity_tax_registration g
                where g.entity_id = v_entity and g.registration_number = 'GB664962592') = current_date
          and (select count(*) from erp.entity_tax_registration g
                where g.entity_id = v_entity and g.registration_number = 'GB664962592') = 1;
    detail := coalesce(v_state, (select string_agg(format('%s %s..%s', g.registration_number, g.valid_from, g.valid_to), ', ')
                                   from erp.entity_tax_registration g where g.entity_id = v_entity));
    return next;

    -- ── 3. Refused ──────────────────────────────────────────────────────────
    v_step := 'refused';
    begin
      perform public.erp_record_vat_registration(v_entity, 'GB12345');
      v_ok := false; v_msg := 'five digits recorded';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_VAT_NUMBER_INVALID%'; v_msg := left(sqlerrm, 80);
    end;
    v_cases := v_cases + 1;
    case_name := 'a number that is not nine digits is refused';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
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
    raise exception 'CLOVEERP_VAT_REGISTRATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;
revoke all on function erp_test.vat_registration_suite() from public, anon, authenticated;

create or replace function erp_test.assert_vat_registration_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _vat_registration on commit drop as
    select * from erp_test.vat_registration_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _vat_registration;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_VAT_REGISTRATION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_VAT_REGISTRATION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('VAT registration: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_vat_registration_suite() from public, anon, authenticated;

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_write_only_columns();
