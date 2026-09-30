-- ═════════════════════════════════════════════════════════════════════════════
-- The platform takes its own name, and the console changes an address
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20261003200000 reserved words that would read as the product's own address —
-- clove, cloveerp, support, www — so that no customer could hold
-- cloveerp.com/clove. The product's own organisation is the one organisation
-- that should: the owner asked for cloveerp.com/clove on the day it shipped and
-- was refused.
--
--   1. A reserved word says whether the platform's own organisation may hold it
--      (reserved_tenant_code.platform_may_hold). The product's words may; the
--      application's routes may not, for anybody, because a route would hide
--      the address. demo- stays refused for everybody.
--   2. The exception needs the organisation named. Onboarding a new
--      organisation names none, so a new organisation made from a session
--      inside the platform's own cannot borrow its exception.
--   3. Platform operators may change any organisation's address from the
--      console (erp_platform_set_tenant_address), with a reason, under the
--      same rules as an organisation's own administrator. The old address
--      keeps opening the new one.
--   4. erp_meta.platform_organisation keeps a copy of its organisation's code,
--      which the selling screen compares against; a rename now carries it.

set lock_timeout = '30s';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Which reserved words the platform may hold
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_meta.reserved_tenant_code
  add column if not exists platform_may_hold boolean not null default false;

comment on column erp_meta.reserved_tenant_code.platform_may_hold is
  'Whether the platform''s own organisation may take this code: true for the '
  'product''s own words, false for the application''s routes (20261003500000).';

update erp_meta.reserved_tenant_code
   set platform_may_hold = true
 where reason = 'would read as the product''s own address';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The rule, with the exception
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.tenant_code_refusal(p_code text, p_tenant uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_code is null or p_code !~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' then
      'CLOVEERP_ADDRESS_SHAPE: ' || coalesce('"' || p_code || '"', 'nothing')
      || ' is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit'
    when exists (select 1 from erp_meta.reserved_tenant_code r
                  where r.code = p_code
                    and not (r.platform_may_hold
                             and p_tenant is not null
                             and exists (select 1 from erp_meta.platform_organisation po
                                          where po.tenant_id = p_tenant))) then
      'CLOVEERP_ADDRESS_RESERVED: "' || p_code || '" is reserved and cannot be an organisation''s address'
    when exists (select 1 from erp.tenant t
                  where t.code = p_code and t.id is distinct from p_tenant) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" is another organisation''s address'
    when exists (select 1 from erp_meta.retired_tenant_code x
                  where x.code = p_code and x.owner_tenant_id is distinct from p_tenant) then
      'CLOVEERP_ADDRESS_TAKEN: "' || p_code || '" was another organisation''s address and still opens theirs'
  end
$$;

comment on function erp.tenant_code_refusal(text, uuid) is
  'Why a code may not be an organisation''s address, or null when it may; the '
  'platform''s own organisation may hold the product''s own words (20261003500000).';

create or replace function erp.refuse_unchosen_address(p_code text, p_tenant uuid default null)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_code    text := lower(btrim(coalesce(p_code, '')));
  v_refusal text;
begin
  if v_code like 'demo-%' then
    raise exception 'CLOVEERP_ADDRESS_RESERVED: an address may not start with "demo-", which marks the product''s own demonstration organisations'
      using errcode = '23514',
            hint = 'Choose an address that starts with the organisation''s name.';
  end if;
  v_refusal := erp.tenant_code_refusal(v_code, p_tenant);
  if v_refusal is not null then
    raise exception '%', v_refusal
      using errcode = '23514',
            hint = 'Choose another address; the organisation''s name is usually the one people remember.';
  end if;
end;
$$;

-- The trigger, carrying the platform organisation's copy of its code along.
create or replace function erp.tenant_code_is_an_address()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_refusal text;
begin
  if tg_op = 'UPDATE' and new.code is not distinct from old.code then
    return new;
  end if;

  v_refusal := erp.tenant_code_refusal(new.code, new.id);
  if v_refusal is not null then
    raise exception '%', v_refusal
      using errcode = '23514',
            hint = 'Choose another address. erp_tenant_by_address says whether a code is held.';
  end if;

  if tg_op = 'UPDATE' then
    insert into erp_meta.retired_tenant_code (code, owner_tenant_id)
    values (old.code, new.id)
    on conflict (code) do update set retired_at = now()
      where erp_meta.retired_tenant_code.owner_tenant_id = excluded.owner_tenant_id;
    delete from erp_meta.retired_tenant_code x
     where x.code = new.code and x.owner_tenant_id = new.id;
    update erp_meta.platform_organisation po
       set tenant_code = new.code
     where po.tenant_id = new.id;
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The console's door
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_platform_set_tenant_address(
  p_tenant_id uuid, p_code text, p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v      erp_meta.platform_staff;
  v_t    erp.tenant;
  v_code text := lower(btrim(coalesce(p_code, '')));
begin
  v := erp_meta.require_platform('operator');

  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception 'CLOVEERP_REASON_REQUIRED: changing an organisation''s address needs a reason, not a word'
      using errcode = '22023',
            hint = 'Say who asked and why — the old address keeps working, and this is kept in the platform''s activity log. At least twenty characters.';
  end if;

  select * into v_t from erp.tenant t where t.id = p_tenant_id and t.deleted_at is null;
  if v_t.id is null then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: no organisation has that id'
      using errcode = '23503',
            hint = 'Choose the organisation from the console''s list.';
  end if;

  if v_t.code = v_code then
    return jsonb_build_object('tenant_id', v_t.id, 'code', v_code, 'previous', null, 'changed', false);
  end if;

  perform erp.refuse_unchosen_address(v_code, v_t.id);

  perform set_config('erp.job_tenant_id', v_t.id::text, true);
  update erp.tenant t set code = v_code where t.id = v_t.id;
  perform set_config('erp.job_tenant_id', '', true);

  perform erp_meta.platform_log(v, 'platform.tenant_address_changed', v_t.id, v_code, p_reason,
                                jsonb_build_object('previous', v_t.code, 'code', v_code));

  return jsonb_build_object('tenant_id', v_t.id, 'code', v_code, 'previous', v_t.code, 'changed', true);
end;
$$;

revoke all on function public.erp_platform_set_tenant_address(uuid, text, text) from public, anon;
grant execute on function public.erp_platform_set_tenant_address(uuid, text, text) to authenticated, service_role;

comment on function public.erp_platform_set_tenant_address(uuid, text, text) is
  'Changes an organisation''s address from the platform console, for operators and '
  'above, with a reason; the old address keeps opening the new (20261003500000).';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_set_tenant_address',
   'Runs as its owner because erp.tenant is not writable by a session role and the '
   'organisation is not the caller''s. Gates on erp_meta.require_platform(''operator'') '
   'on its first line, requires a reason, and changes one organisation''s code under '
   'erp.refuse_unchosen_address, the rule an organisation''s own administrator meets.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_set_tenant_address', 'erp_meta.require_platform',
   'Changes an organisation''s address from the console; platform operators and above, with a reason kept in the activity log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.platform_address_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  op      uuid := gen_random_uuid();
  sp      uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  rp record; rc record;
  v_answer jsonb;
  v_err text;
  c_reason constant text := 'suite: the owner asked for this address';
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    insert into auth.users (id, email) values
      (op, 'operator@zzpa-' || v_tag || '.test'), (sp, 'support@zzpa-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('operator@zzpa-' || v_tag || '.test', op, 'Address Suite Operator', 'operator'),
      ('support@zzpa-' || v_tag || '.test', sp, 'Address Suite Support', 'support');
    select * into rp from erp.provision_tenant('zzpa-p-' || v_tag, 'Address Suite Platform', 'p@zzpa-' || v_tag || '.test', 'P Admin');
    select * into rc from erp.provision_tenant('zzpa-c-' || v_tag, 'Address Suite Customer', 'c@zzpa-' || v_tag || '.test', 'C Admin');
    -- This organisation is the platform's own, for the length of the suite.
    delete from erp_meta.platform_organisation;
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_by, reason)
    values (rp.tenant_id, 'zzpa-p-' || v_tag, 'operator@zzpa-' || v_tag || '.test', 'suite: the platform organisation');
    perform set_config('erp.job_tenant_id', '', true);

    -- 1. A customer cannot take the product's name.
    v_step := 'a customer asking for the product''s name';
    perform set_config('request.jwt.claims', json_build_object('sub', op, 'role', 'authenticated')::text, true);
    v_err := null;
    begin
      perform public.erp_platform_set_tenant_address(rc.tenant_id, 'clove', c_reason);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a customer cannot take the product''s own name';
    passed := v_err like 'CLOVEERP_ADDRESS_RESERVED:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    -- 2. The platform's own organisation can, and its copy of its code follows.
    v_step := 'the platform organisation taking the product''s name';
    v_answer := public.erp_platform_set_tenant_address(rp.tenant_id, 'clove', c_reason);
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'the platform''s own organisation takes the product''s name, and its record follows';
    passed := (select t.code from erp.tenant t where t.id = rp.tenant_id) = 'clove'
          and (select po.tenant_code from erp_meta.platform_organisation po where po.tenant_id = rp.tenant_id) = 'clove';
    detail := coalesce(v_answer::text, 'no answer');
    return next;

    -- 3. The old address opens the new.
    v_cases := v_cases + 1;
    case_name := 'the address it had still opens it';
    passed := (public.erp_tenant_by_address('zzpa-p-' || v_tag) ->> 'code') = 'clove';
    detail := coalesce(public.erp_tenant_by_address('zzpa-p-' || v_tag)::text, 'nothing');
    return next;

    -- 4. Not a route, even for the platform.
    v_err := null;
    begin
      perform public.erp_platform_set_tenant_address(rp.tenant_id, 'sales', c_reason);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'not even the platform''s organisation may hold a route name';
    passed := v_err like 'CLOVEERP_ADDRESS_RESERVED:%';
    detail := coalesce(v_err, 'it was taken');
    return next;

    -- 5. A new organisation names none, so borrows no exception.
    v_err := null;
    begin
      perform erp.refuse_unchosen_address('cloveerp', null);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'a new organisation cannot borrow the platform''s exception';
    passed := v_err like 'CLOVEERP_ADDRESS_RESERVED:%';
    detail := coalesce(v_err, 'it was admitted');
    return next;

    -- 6. Support staff do not change addresses; nobody does without a reason.
    v_err := null;
    perform set_config('request.jwt.claims', json_build_object('sub', sp, 'role', 'authenticated')::text, true);
    begin
      perform public.erp_platform_set_tenant_address(rc.tenant_id, 'zzpa-x-' || v_tag, c_reason);
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'support staff cannot change an organisation''s address';
    passed := v_err is not null
          and (select t.code from erp.tenant t where t.id = rc.tenant_id) = 'zzpa-c-' || v_tag;
    detail := coalesce(v_err, 'it was changed');
    return next;

    v_err := null;
    perform set_config('request.jwt.claims', json_build_object('sub', op, 'role', 'authenticated')::text, true);
    begin
      perform public.erp_platform_set_tenant_address(rc.tenant_id, 'zzpa-x-' || v_tag, 'because');
    exception when others then v_err := left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'an address is not changed without a reason';
    passed := v_err like 'CLOVEERP_REASON_REQUIRED:%';
    detail := coalesce(v_err, 'it was changed');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PLATFORM_ADDRESS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code in ('zzpa-p-' || v_tag, 'zzpa-c-' || v_tag))
     or exists (select 1 from auth.users u where u.id in (op, sp)) then
    raise exception 'CLOVEERP_PLATFORM_ADDRESS_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.platform_address_suite() from public, anon, authenticated;

create or replace function erp_test.assert_platform_address_suite()
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
    from erp_test.platform_address_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PLATFORM_ADDRESS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A customer could hold the product''s name, the platform could not, or the console could change an address it should not. Read the case that failed.';
  end if;
  if v_total <> 7 then
    raise exception 'CLOVEERP_PLATFORM_ADDRESS_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('platform address: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_platform_address_suite() from public, anon;

comment on function erp_test.assert_platform_address_suite() is
  'The platform takes its own name, and the console changes an address (20261003500000).';

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
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
