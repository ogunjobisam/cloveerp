set lock_timeout = '30s';

-- =============================================================================
-- 20261002300000  An upgrade replaces the rule it ships
-- -----------------------------------------------------------------------------
-- Every deploy since the demonstration caught up has failed its proof:
--
--   demo-cbb10384: erp.assert_vat_agrees_with_ledger() — CLOVEERP_VAT_DISAGREES_WITH_LEDGER
--   INV-000432 determined 49773 and journal GL-2026-001049 moved tax control by 0
--
-- The deploy log said why (20261002200000 and the proof step): the journal is
-- two lines, receivable and revenue at 248863, and the demonstration's only
-- sales_invoice posting rule is version 1, those same two lines. Its
-- finance-posting installation says version 3. Version 2 of that installer
-- is the one that put the tax line on the sales invoice (20260916090000), and
-- the demonstration never received it.
--
-- ── WHY ──────────────────────────────────────────────────────────────────────
--
-- erp.plan_module_upgrade() counted a posting rule as held when ANY version
-- of its code was in force. An upgrade that ships a new shape of a rule the
-- organisation already has — sales_invoice with its tax line, purchase_invoice
-- matched to the receipt — was therefore planned as nothing, and
-- erp.upgrade_module_configuration() stamped the installation with the new
-- version all the same. An organisation that installed finance before
-- 16 September and upgraded after it posts its invoices net while its tax is
-- determined: the customer is charged the net, and the return says tax.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   * erp.plan_module_upgrade(): a posting rule is held when a version in force
--     carries every line the installer's item carries, by side and basis —
--     the account a line names, and what it is called, stay the
--     organisation's. Only the latest item for a rule is asked about: an
--     earlier one is a shape the later one replaced.
--   * erp.posting_rules_behind_their_installer(): the rules in force that
--     lack a line the latest item for them carries, for an installation the
--     organisation holds at or past that item's version — what the planner
--     skipped.
--   * erp.carry_skipped_posting_rules(): in an organisation that is not live,
--     promotes those items through a change set, as the upgrade would have.
--     A live organisation is left for its own administrator: nothing in
--     production changes configuration underneath it.
--   * erp.demonstration_catch_up() calls it before it trades.
--   * erp.assert_sales_rules_carry_tax(): a company registered for VAT posts
--     the tax its sales and credits are determined at. Registered in the
--     tenant diagnostics, so the whole-database proof runs it everywhere.
--   * INV-000432: posted net, and the customer owes the net. Its
--     determinations are withdrawn by erp.withdraw_tax_nobody_charged()
--     (20261001500000), in every organisation that is not live.
--
-- Proof: erp_test.upgrade_replaces_the_rule_suite (6 cases).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The planner asks whether the rule in force has the lines, not whether
--    there is one
-- ─────────────────────────────────────────────────────────────────────────────

do $plan$
declare
  v_src  text := pg_get_functiondef('erp.plan_module_upgrade(text)'::regprocedure);
  v_old  text :=
      E'           when ''posting_rule'' then exists (\n'
   || E'             select 1 from erp.posting_rule r\n'
   || E'              where r.tenant_id = v_tenant and r.code = ui.object_key and r.status = ''active'')\n';
  v_new  text :=
      E'           -- Held when a version in force carries every line the item carries,\n'
   || E'           -- by side and basis, and not merely when one exists: an upgrade that\n'
   || E'           -- ships a new shape of a rule the organisation has was planned as\n'
   || E'           -- nothing, and the installation stamped past it (20261002300000).\n'
   || E'           -- Only the latest item for a rule is asked: an earlier one is a shape\n'
   || E'           -- the later one replaced.\n'
   || E'           when ''posting_rule'' then\n'
   || E'             exists (select 1 from erp_ref.module_upgrade_item u2\n'
   || E'                      where u2.install_code = ui.install_code and u2.object_kind = ''posting_rule''\n'
   || E'                        and u2.object_key = ui.object_key and u2.to_version > ui.to_version)\n'
   || E'             or erp.posting_rule_carries(v_tenant, ui.object_key, ui.payload)\n';
begin
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.plan_module_upgrade''s posting rule test is not where 20261002300000 expects it';
  end if;
  -- The helper the new test reads, first.
  execute $fn$
    create or replace function erp.posting_rule_carries(p_tenant_id uuid, p_code text, p_item jsonb)
    returns boolean
    language sql
    stable
    set search_path = ''
    as $body$
      -- A version of the rule in force carries every line the item carries, by
      -- side and basis (20261002300000). The account and the description are
      -- the organisation's own.
      select exists (
        select 1 from erp.posting_rule r
         where r.tenant_id = p_tenant_id and r.code = p_code and r.status = 'active'
           and not exists (
             select 1 from jsonb_array_elements(coalesce(p_item -> 'posting_lines', '[]'::jsonb)) l
              where not exists (
                select 1 from jsonb_array_elements(r.posting_lines) h
                 where h ->> 'side' = l ->> 'side'
                   and coalesce(h ->> 'basis', '') = coalesce(l ->> 'basis', ''))));
    $body$
  $fn$;
  execute replace(v_src, v_old, v_new);
end
$plan$;

revoke all on function erp.posting_rule_carries(uuid, text, jsonb) from public, anon, authenticated;

comment on function erp.posting_rule_carries(uuid, text, jsonb) is
  'Whether a version in force of the posting rule carries every line an installer item carries, by side '
  'and basis (20261002300000). What erp.plan_module_upgrade() calls a posting rule the organisation holds.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. What the planner skipped
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.posting_rules_behind_their_installer()
returns table(install_code text, installer_version integer, rule_code text, item_version integer,
              missing text, payload jsonb)
language sql
stable
set search_path = ''
as $$
  -- The rules in force that lack a line the latest item for them carries, for
  -- an installation the organisation holds at or past that item's version
  -- (20261002300000): what erp.plan_module_upgrade() skipped while it counted
  -- a rule as held because a version of it existed.
  select i.install_code, i.installer_version, ui.object_key, ui.to_version,
         (select string_agg(format('%s %s', l ->> 'side', coalesce(l ->> 'basis', 'balancing')), ', ')
            from jsonb_array_elements(coalesce(ui.payload -> 'posting_lines', '[]'::jsonb)) l
           where not exists (
             select 1 from erp.posting_rule r
              cross join lateral jsonb_array_elements(r.posting_lines) h
              where r.tenant_id = i.tenant_id and r.code = ui.object_key and r.status = 'active'
                and h ->> 'side' = l ->> 'side'
                and coalesce(h ->> 'basis', '') = coalesce(l ->> 'basis', ''))),
         erp.resolve_account_purposes(ui.payload)
    from erp.module_installation i
    join erp_ref.module_upgrade_item ui
      on ui.install_code = i.install_code and ui.object_kind = 'posting_rule'
     and ui.to_version <= i.installer_version
   where i.tenant_id = erp.require_tenant_id()
     and not exists (select 1 from erp_ref.module_upgrade_item u2
                      where u2.install_code = ui.install_code and u2.object_kind = 'posting_rule'
                        and u2.object_key = ui.object_key and u2.to_version > ui.to_version)
     and exists (select 1 from erp.posting_rule r
                  where r.tenant_id = i.tenant_id and r.code = ui.object_key and r.status = 'active')
     and not erp.posting_rule_carries(i.tenant_id, ui.object_key, ui.payload)
   order by i.install_code, ui.object_key;
$$;

revoke all on function erp.posting_rules_behind_their_installer() from public, anon, authenticated;

comment on function erp.posting_rules_behind_their_installer() is
  'The posting rules in force that lack a line the latest installer item for them carries, where the '
  'organisation''s installation is at or past that item (20261002300000). What the upgrade planner skipped.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Carried, where nobody's production changes underneath them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.carry_skipped_posting_rules()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_cs uuid;
  v_n  integer := 0;
  p    record;
begin
  -- What erp.upgrade_module_configuration() would have promoted, had the
  -- planner not counted the rule as held (20261002300000). Not in a live
  -- organisation: its administrator upgrades it, and approves what changes.
  if erp.tenant_is_live() then
    return 0;
  end if;
  if not exists (select 1 from erp.posting_rules_behind_their_installer()) then
    return 0;
  end if;

  v_cs := erp.create_change_set(
    format('posting-rules-carried-%s', substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    'Posting rules an upgrade skipped',
    'The shape of each rule the installer shipped and the organisation never received (20261002300000).');
  for p in select * from erp.posting_rules_behind_their_installer() loop
    perform erp.add_change_set_item(v_cs, 'posting_rule', p.rule_code, p.payload, 'upsert', null,
                                    format('%s version %s, which lacked: %s', p.install_code, p.item_version, p.missing));
    v_n := v_n + 1;
  end loop;
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  return v_n;
end;
$$;

revoke all on function erp.carry_skipped_posting_rules() from public, anon, authenticated;

comment on function erp.carry_skipped_posting_rules() is
  'Promotes, through a change set, each posting rule an upgrade skipped (20261002300000). Nothing in a '
  'live organisation. Returns the rules carried.';

-- The demonstration carries them before it trades, as it takes its upgrades.
do $catch_up$
declare
  v_src  text := pg_get_functiondef('erp.demonstration_catch_up()'::regprocedure);
  v_old  text := E'  -- The returns there are before this run, so that what it finalises, the\n';
  v_new  text :=
      E'  -- ── The rules an upgrade skipped (20261002300000) ─────────────────────────\n'
   || E'  --\n'
   || E'  -- A demonstration that installed finance before its sales invoice carried\n'
   || E'  -- tax holds version 1 of that rule under a later installation: its invoices\n'
   || E'  -- posted net while their tax was determined.\n'
   || E'  begin\n'
   || E'    if erp.carry_skipped_posting_rules() > 0 then\n'
   || E'      v_notes := v_notes || to_jsonb(''Posting rules an upgrade had skipped were brought up to their installers.''::text);\n'
   || E'    end if;\n'
   || E'  exception when others then\n'
   || E'    v_notes := v_notes || to_jsonb(format(\n'
   || E'      ''Posting rules an upgrade skipped were not carried, so they post as they did: %s'', sqlerrm));\n'
   || E'  end;\n'
   || E'\n'
   || v_old;
begin
  if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: erp.demonstration_catch_up''s VAT return marker is not where 20261002300000 expects it';
  end if;
  execute replace(v_src, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. A company registered for VAT posts the tax it determines
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_rules_without_tax()
returns table(rule_code text, install_code text, installer_version integer, item_version integer)
language sql
stable
set search_path = ''
as $$
  -- In an organisation with a company registered for VAT today, the rules in
  -- force that post a sale or its credit and carry no tax line where their
  -- installer's latest item carries one (20261002300000).
  select ui.object_key, i.install_code, i.installer_version, ui.to_version
    from erp.module_installation i
    join erp_ref.module_upgrade_item ui
      on ui.install_code = i.install_code and ui.object_kind = 'posting_rule'
   where i.tenant_id = erp.require_tenant_id()
     and exists (select 1 from erp.entity e
                  where e.tenant_id = i.tenant_id and e.status = 'active'
                    and erp.entity_is_tax_registered(e.id, current_date))
     and not exists (select 1 from erp_ref.module_upgrade_item u2
                      where u2.install_code = ui.install_code and u2.object_kind = 'posting_rule'
                        and u2.object_key = ui.object_key and u2.to_version > ui.to_version)
     and exists (select 1 from erp.document_type dt
                  where dt.tenant_id = i.tenant_id and dt.posting_rule_code = ui.object_key
                    and dt.base_type_code in ('invoice_reference', 'credit_reference'))
     and exists (select 1 from jsonb_array_elements(coalesce(ui.payload -> 'posting_lines', '[]'::jsonb)) l
                  where l ->> 'basis' = 'document_tax')
     and exists (select 1 from erp.posting_rule r
                  where r.tenant_id = i.tenant_id and r.code = ui.object_key and r.status = 'active'
                    and not exists (select 1 from jsonb_array_elements(r.posting_lines) h
                                     where h ->> 'basis' = 'document_tax'))
   order by 1;
$$;

revoke all on function erp.sales_rules_without_tax() from public, anon, authenticated;

comment on function erp.sales_rules_without_tax() is
  'Where a company is registered for VAT, the rules in force for invoices and credits that carry no tax '
  'line while their installer''s latest item does (20261002300000).';

create or replace function erp.assert_sales_rules_carry_tax()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n     integer;
  v_rules text;
begin
  select count(*), string_agg(format('%s (%s v%s; the line arrived in v%s)',
                                     s.rule_code, s.install_code, s.installer_version, s.item_version), ', ')
    into v_n, v_rules
    from erp.sales_rules_without_tax() s;
  if v_n > 0 then
    raise exception 'CLOVEERP_SALES_RULE_CARRIES_NO_TAX: % rule(s) post a registered company''s sales net: %', v_n, v_rules
      using errcode = '23514',
            hint = 'Promote the rule''s current version from Configuration: its invoices post without the tax they are determined at, so the customer is charged the net and the return says tax.';
  end if;
  return 'sales rules: every one a registered company posts by carries its tax';
end;
$$;

revoke all on function erp.assert_sales_rules_carry_tax() from public, anon;

comment on function erp.assert_sales_rules_carry_tax() is
  'A company registered for VAT posts its invoices and credits by rules that carry the tax line their '
  'installer ships (20261002300000). Run for every organisation by the whole-database reconciliation.';

-- The ageing and trial balance ties' suites count the tenant assertions the
-- reconciliation drives; this is the fourteenth.
do $pin$
declare
  v_fn  regprocedure;
  v_src text;
  v_old text := '= 13 /* thirteen since 20261001000000: the VAT return agrees with the ledger */';
  v_new text := '= 14 /* fourteen since 20261002300000: a registered company''s sales post their tax */';
begin
  foreach v_fn in array array['erp_test.ageing_tie_suite()'::regprocedure,
                              'erp_test.trial_balance_tie_suite()'::regprocedure] loop
    v_src := pg_get_functiondef(v_fn);
    if (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: %''s tenant assertion count is not where 20261002300000 expects it', v_fn;
    end if;
    execute replace(v_src, v_old, v_new);
  end loop;
end
$pin$;

-- CLOVEERP_SALES_RULE_CARRIES_NO_TAX is raised only by an assert_ routine and
-- so is not registered in erp_ref.refusal (20260920200000); its next action
-- travels as the hint.

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('sales_rules_carry_tax', 'A registered company''s sales post their tax', 'assertion', 'tenant', 'erp',
   'assert_sales_rules_carry_tax', '', 'sales_rules_without_tax', '',
   'Where a company is registered for VAT, the posting rules its invoices and credit notes use carry the '
   'tax line their installer ships. A rule without it posts the net while the tax is determined: the '
   'customer is charged less than the return declares.',
   true, 914)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. INV-000432, which posted net: the ledger is what the customer owes
-- ─────────────────────────────────────────────────────────────────────────────

do $withdraw$
declare
  r       record;
  v_n     integer;
  v_total integer := 0;
begin
  for r in select tn.id, tn.code from erp.tenant tn where tn.deleted_at is null order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    v_n := erp.withdraw_tax_nobody_charged();
    if v_n > 0 then
      raise warning 'tax nobody charged: % document(s) in % had their determinations withdrawn', v_n, r.code;
      v_total := v_total + v_n;
    end if;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
  raise warning 'tax nobody charged: % document(s) in all', v_total;
end
$withdraw$;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.upgrade_replaces_the_rule_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  v_owner  text := current_user;
  rb       record;
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid; v_inv uuid;
  v_net_lines jsonb;
  v_planned integer; v_behind integer; v_carried integer; v_after integer; v_live integer;
  v_tax bigint; v_err text; v_err2 text; v_msg text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzur-' || v_tag, 'Upgrade Replaces The Rule Suite',
      'admin@zzur-' || v_tag || '.test', 'Upgrade Replaces Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzur-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZURCUST', 'Upgrade replaces customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');

    -- ── The demonstration's state: version 1 of the rule, the installer at 3 ─
    v_step := 'the sales invoice rule put back to the two lines it had before tax reached the ledger';
    select jsonb_agg(l order by o) into v_net_lines
      from erp.posting_rule r
      cross join lateral jsonb_array_elements(r.posting_lines) with ordinality x(l, o)
     where r.tenant_id = rb.tenant_id and r.code = 'sales_invoice' and r.status = 'active'
       and coalesce(l ->> 'basis', '') <> 'document_tax';
    update erp.posting_rule r
       set posting_lines = v_net_lines
     where r.tenant_id = rb.tenant_id and r.code = 'sales_invoice' and r.status = 'active';

    -- ── 1. The assertion refuses it ──────────────────────────────────────────
    v_step := 'the assertion asked of a registered company posting its sales net';
    v_err := null;
    begin
      perform erp.assert_sales_rules_carry_tax();
    exception when others then v_err := left(sqlerrm, 240); end;
    v_cases := v_cases + 1;
    case_name := 'a registered company whose sales invoice rule carries no tax line is refused, by the rule';
    passed := v_state is null and v_err like 'CLOVEERP_SALES_RULE_CARRIES_NO_TAX:%sales_invoice (finance-posting%';
    detail := coalesce(v_state, coalesce(v_err, 'not refused'));
    return next;

    -- ── 2. The planner offers the rule to an installation below its item ────
    v_step := 'the installation put back to version 1 and the upgrade planned';
    v_planned := null;
    begin
      update erp.module_installation i set installer_version = 1
       where i.tenant_id = rb.tenant_id and i.install_code = 'finance-posting';
      select count(*) into v_planned from erp.plan_module_upgrade('finance-posting') p
       where p.object_kind = 'posting_rule' and p.object_key = 'sales_invoice';
      raise exception 'CLOVEERP_PLAN_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_PLAN_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'an upgrade plans the rule it ships when the rule in force lacks its lines, though a version of it exists';
    passed := v_state is null and v_planned = 1;
    detail := coalesce(v_state, format('%s sales_invoice item(s) planned', v_planned));
    return next;

    -- ── 3. Nothing in a live organisation ────────────────────────────────────
    v_step := 'the same organisation made live and the rules carried';
    v_live := null;
    begin
      update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
      v_live := erp.carry_skipped_posting_rules();
      raise exception 'CLOVEERP_LIVE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_LIVE_UNDO' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'nothing is carried in a live organisation';
    passed := v_state is null and v_live = 0
          and not erp.posting_rule_carries(rb.tenant_id, 'sales_invoice',
                (select ui.payload from erp_ref.module_upgrade_item ui
                  where ui.install_code = 'finance-posting' and ui.object_key = 'sales_invoice'
                  order by ui.to_version desc limit 1));
    detail := coalesce(v_state, format('%s carried', v_live));
    return next;

    -- ── 4. Carried where it is not ───────────────────────────────────────────
    v_step := 'the rules an upgrade skipped carried';
    select count(*) into v_behind from erp.posting_rules_behind_their_installer() b
     where b.rule_code = 'sales_invoice';
    v_carried := erp.carry_skipped_posting_rules();
    select count(*) into v_after from erp.posting_rules_behind_their_installer();
    v_err := null;
    begin
      v_msg := erp.assert_sales_rules_carry_tax();
    exception when others then v_err := left(sqlerrm, 240); end;
    v_cases := v_cases + 1;
    case_name := 'the skipped rule is promoted through a change set, and the assertion then passes';
    passed := v_state is null and v_behind = 1 and v_carried >= 1 and v_after = 0 and v_err is null
          and exists (select 1 from erp.posting_rule r
                       cross join lateral jsonb_array_elements(r.posting_lines) h
                       where r.tenant_id = rb.tenant_id and r.code = 'sales_invoice' and r.status = 'active'
                         and h ->> 'basis' = 'document_tax');
    detail := coalesce(v_state, format('%s behind; %s carried; %s left; %s', v_behind, v_carried, v_after,
                                       coalesce(v_err, v_msg)));
    return next;

    -- ── 5. And an invoice then posts its tax ────────────────────────────────
    v_step := 'an invoice issued after the rule was carried';
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZUR-INV', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 10000, 'sold after the carry');
    perform erp.set_invoice_tax_point(v_inv, current_date);
    perform erp.transition_document(v_inv, 'issue', 'upgrade replaces the rule suite');
    select coalesce(sum(e.tax_minor), 0) into v_tax from erp.vat_entries(v_entity, null, null) e
     where e.document_id = v_inv;
    v_err2 := null;
    begin
      perform erp.assert_vat_agrees_with_ledger();
    exception when others then v_err2 := left(sqlerrm, 240); end;
    v_cases := v_cases + 1;
    case_name := 'an invoice issued after the carry moves tax control by the tax it is determined at';
    passed := v_state is null and v_tax > 0 and v_tax = erp.document_tax_minor(v_inv) and v_err2 is null;
    detail := coalesce(v_state, format('tax control moved %s, determined %s; %s', v_tax,
                                       erp.document_tax_minor(v_inv), coalesce(v_err2, 'the ledger agrees')));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 6. Undone ──────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzur-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzur rolled back with its rules and invoice');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_UPGRADE_REPLACES_THE_RULE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.upgrade_replaces_the_rule_suite() from public, anon;

comment on function erp_test.upgrade_replaces_the_rule_suite() is
  'An upgrade plans the shape of a rule it ships, a skipped one is carried where nothing live changes, and '
  'a registered company posting its sales net is refused (20261002300000).';

create or replace function erp_test.assert_upgrade_replaces_the_rule_suite()
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
    from erp_test.upgrade_replaces_the_rule_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_UPGRADE_REPLACES_THE_RULE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An upgrade would skip the shape of a rule it ships, or a company would post its sales net. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_UPGRADE_REPLACES_THE_RULE_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('upgrade replaces the rule: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_upgrade_replaces_the_rule_suite() from public, anon;

comment on function erp_test.assert_upgrade_replaces_the_rule_suite() is
  'An upgrade replaces the rule it ships, and a registered company posts its tax (20261002300000).';

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
