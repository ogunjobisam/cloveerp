set lock_timeout = '30s';

-- =============================================================================
-- 20261005100000  An install brings the accounts it posts to
-- -----------------------------------------------------------------------------
-- The demonstration stopped trading on 2 October. Since 1 October every
-- deploy's catch-up has said:
--
--   Logistics was not installed, so the demonstration does not ship:
--   CLOVEERP_PROMOTION_BREAKS_DETERMINATION: logistics introduces a way for a
--   posting to fail
--
-- and then that the day would not build for the same reason. The detail,
-- which the deploy's report does not carry, is:
--
--   carrier_bill on MAIN wants account 7200
--
-- 20261004600000 taught the catch-up to install logistics on a
-- demonstration built before it shipped, and 20261004700000 put the carrier
-- bill into that install, posting its net to 7200 carriage outwards. A
-- company configured since then has 7200, because the finance installer
-- creates it. The demonstration's finance was installed in April, so it has
-- not, and erp.promote_change_set()'s determination guard refused the
-- install, rightly, rather than promote a rule its company cannot post.
--
-- The upgrade path already knew this. erp.plan_module_upgrade() adds the
-- account a purpose names to a company that lacks it (20260921090000), and
-- 20261004700000 registered carriage_outwards for logistics version 4 for
-- exactly that reason. An install had no such step: it assumed finance had
-- made every account any later module would want. That holds only for a
-- company configured after the module was written.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.accounts_an_install_needs(items): for each posting rule the install
--      carries, each account it names by code that the companies its document
--      types post on do not hold, when the code is one a chart purpose
--      gives. Only a company that keeps a ledger: one with no books posts
--      nothing, and an account would not make it. The account comes as the upgrade planner makes it: the
--      purpose's name and type, the company's currency.
--   B. erp.install_module_config() adds those accounts ahead of the module's
--      own items. A code no purpose gives is not invented; the guard still
--      refuses it.
--
-- Proved by erp_test.install_brings_its_accounts_suite, which builds the
-- demonstration's shape (finance before 7200, logistics never installed) and
-- installs logistics on it.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What an install needs that the company lacks
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.accounts_an_install_needs(p_items jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The accounts a module's install would post to and its companies lack
  -- (20261005100000), as change-set items. A posting rule's line names an
  -- account by code; a document type in the same install names the rule, and
  -- its company, or every company that keeps books when it names none. Only
  -- a code a chart purpose gives is added, made as erp.plan_module_upgrade()
  -- makes one.
  with items as (
    select i.value as item from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
  ),
  rule_accounts as (
    select it.item ->> 'key' as rule_code, l.value ->> 'account' as code
      from items it
     cross join lateral jsonb_array_elements(coalesce(it.item -> 'payload' -> 'posting_lines', '[]'::jsonb)) l
     where it.item ->> 'kind' = 'posting_rule'
       and jsonb_typeof(l.value -> 'account') = 'string'
  ),
  types as (
    select it.item -> 'payload' ->> 'posting_rule' as rule_code,
           it.item -> 'payload' ->> 'entity' as entity_code
      from items it
     where it.item ->> 'kind' = 'document_type'
       and (it.item -> 'payload' ->> 'posting_rule') is not null
  ),
  needs as (
    select distinct ra.code, e.id as entity_id, e.code as entity_code, e.base_currency
      from rule_accounts ra
      join types t on t.rule_code = ra.rule_code
      join erp.entity e
        on e.tenant_id = erp.current_tenant_id() and e.status = 'active'
       and (t.entity_code is null or e.code = t.entity_code)
     -- A company that keeps books: one with no ledger posts nothing, and an
     -- account would not make it.
     where exists (
         select 1 from erp.ledger lg
          where lg.tenant_id = e.tenant_id and lg.entity_id = e.id
            and lg.is_primary and lg.status = 'active')
       and not exists (
         select 1 from erp.account a
          where a.tenant_id = e.tenant_id and a.entity_id = e.id
            and a.code = ra.code and a.status = 'active')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'account',
           'key', n.entity_code || '|' || n.code,
           'payload', jsonb_build_object(
             'entity', n.entity_code,
             'code', n.code,
             'name', cap.name,
             'account_type', cap.account_type::text,
             'is_postable', true,
             'currency', n.base_currency))
           order by n.entity_code, n.code), '[]'::jsonb)
    from needs n
    cross join lateral (
      select c.name, c.account_type
        from erp_ref.chart_account_purpose c
       where erp.chart_account_code(c.purpose) = n.code
       order by c.purpose
       limit 1) cap
$$;

revoke all on function erp.accounts_an_install_needs(jsonb) from public, anon;

comment on function erp.accounts_an_install_needs(jsonb) is
  'The accounts a module install''s posting rules name that its companies lack, as change-set items '
  '(20261005100000). Read by erp.install_module_config(); a code no chart purpose gives is left out.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The install adds them first
-- ═════════════════════════════════════════════════════════════════════════════

do $install$
declare
  v_sig  constant text := 'erp.install_module_config(text,text,text,jsonb)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  for v_item in select * from jsonb_array_elements(p_items)
$o$;
  v_new  constant text := $n$  -- The accounts its rules post to that a company configured before the
  -- module was written lacks, ahead of the rules (20261005100000).
  for v_item in select * from jsonb_array_elements(erp.accounts_an_install_needs(p_items) || p_items)
$n$;
begin
  if strpos(v_src, '20261005100000') > 0 then
    raise notice '% already brings its accounts; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6c0f11859558a4cc575571f05e405667' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261005100000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$install$;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.install_brings_its_accounts_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  v_main   uuid;
  v_need   jsonb;
  v_res    text;
begin
  begin
    -- ── The fixture: the demonstration's shape ──────────────────────────────
    v_step := 'a company configured before logistics shipped and before 7200 existed';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzacc-' || v_tag, 'Install Accounts Suite',
      'admin@zzacc-' || v_tag || '.test', 'Accounts Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzacc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    -- Logistics is held by a placeholder while the rest is configured, as it
    -- was not yet a module the demonstration installed, then taken away.
    insert into erp.module_installation (tenant_id, install_code, module_code, installer_version)
    select rb.tenant_id, 'logistics', mi.module_code, 1
      from erp_ref.module_installer mi where mi.install_code = 'logistics';
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    delete from erp.module_installation where tenant_id = rb.tenant_id and install_code = 'logistics';
    delete from erp.account where tenant_id = rb.tenant_id and code = erp.chart_account_code('carriage_outwards');
    select e.id into v_main from erp.entity e
      join erp.document_type dt on dt.tenant_id = e.tenant_id and dt.entity_id = e.id
     where e.tenant_id = rb.tenant_id and dt.code = 'purchase_invoice' limit 1;

    -- ── 1. What the install needs ───────────────────────────────────────────
    v_step := 'reading what logistics would post to';
    v_need := erp.accounts_an_install_needs(erp.carrier_bill_pack_items());
    v_cases := v_cases + 1;
    case_name := 'logistics'' carrier bill needs carriage outwards on the company its bills belong to, and nothing else, when that company was configured before it existed';
    passed := v_state is null
          and jsonb_array_length(v_need) = 1
          and v_need #>> '{0,kind}' = 'account'
          and v_need #>> '{0,payload,code}' = erp.chart_account_code('carriage_outwards')
          and v_need #>> '{0,payload,account_type}' = 'expense'
          and v_need #>> '{0,payload,entity}' = (select e.code from erp.entity e where e.id = v_main);
    detail := coalesce(v_state, v_need::text);
    return next;

    -- ── 2. The install the demonstration could not make ─────────────────────
    v_step := 'installing logistics';
    begin
      perform erp.configure_logistics();
      v_res := 'installed';
    exception when others then
      v_res := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'logistics installs on that company, which gains carriage outwards, and the carrier bill posts there';
    passed := v_state is null
          and v_res = 'installed'
          and exists (select 1 from erp.module_installation i
                       where i.tenant_id = rb.tenant_id and i.install_code = 'logistics')
          and exists (select 1 from erp.account a
                       where a.tenant_id = rb.tenant_id and a.entity_id = v_main and a.status = 'active'
                         and a.code = erp.chart_account_code('carriage_outwards'))
          and not exists (select 1 from erp.determination_coverage_report(rb.tenant_id) c
                           where c.reference like 'carrier_bill%');
    detail := coalesce(v_state, v_res);
    return next;

    -- ── 3. Nothing invented ─────────────────────────────────────────────────
    v_step := 'an install whose rule names a code no purpose gives, and one the company holds';
    v_need := erp.accounts_an_install_needs(jsonb_build_array(
      jsonb_build_object('kind', 'posting_rule', 'key', 'zz_rule', 'payload',
        jsonb_build_object('code', 'zz_rule', 'posting_lines', jsonb_build_array(
          jsonb_build_object('account', '9999', 'side', 'debit'),
          jsonb_build_object('account', erp.chart_account_code('trade_payable'), 'side', 'credit')))),
      jsonb_build_object('kind', 'document_type', 'key', 'zz_type', 'payload',
        jsonb_build_object('code', 'zz_type', 'posting_rule', 'zz_rule'))));
    v_cases := v_cases + 1;
    case_name := 'an account no chart purpose gives is not invented, and one every company holds is not added again';
    passed := v_state is null and v_need = '[]'::jsonb
          and erp.accounts_an_install_needs(erp.carrier_bill_pack_items()) = '[]'::jsonb;
    detail := coalesce(v_state, v_need::text);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzacc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzacc rolled back');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_INSTALL_ACCOUNTS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.install_brings_its_accounts_suite() from public, anon;

comment on function erp_test.install_brings_its_accounts_suite() is
  'An install brings the accounts it posts to (20261005100000): logistics installs on a company configured '
  'before carriage outwards existed, and gains it; nothing a chart purpose does not give is invented.';

create or replace function erp_test.assert_install_brings_its_accounts_suite()
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
    from erp_test.install_brings_its_accounts_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_INSTALL_ACCOUNTS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A module installed on an older company would promote a rule it cannot post, or be refused. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_INSTALL_ACCOUNTS_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('install accounts: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_install_brings_its_accounts_suite() from public, anon;

comment on function erp_test.assert_install_brings_its_accounts_suite() is
  'A module install adds the accounts its rules post to that an older company lacks (20261005100000).';

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
