-- =============================================================================
-- 20260906141000  A window is opened by the promoter, and a module knows
--                 its version
-- -----------------------------------------------------------------------------
-- Specification v1.6 Part 3 (change promotion) and Part 13 (modules). Phase 9
-- of the outstanding-work programme, closing deferred findings 4 and 7.
--
-- Finding 4. The live-configuration guard stood down whenever the custom
-- setting erp.promotion_id was non-empty. Only erp.promote_change_set() sets
-- it in the product, but any session can set a custom setting, and two of the
-- product's own suites did exactly that to write a role on a live organisation
-- — the exploit written as a fixture. A window keyed on a setting is a token;
-- a window keyed on the promoter's own act is a window.
--
--   * erp_meta.promotion_window: one row per window, platform-internal —
--     unreachable by any session — written only by erp.open_promotion_window()
--     (SECURITY DEFINER, registered), which authorises administration.promote
--     on the change set, requires the promotion row to be this organisation's,
--     running, and started in this transaction, and records the transaction
--     id. The promoter calls it where it used to set the setting by hand.
--   * The guard asks erp.promotion_window_is_open(): the setting must name a
--     promotion of this organisation opened by the promoter in this very
--     transaction. A setting set by hand is refused by name
--     (CLOVEERP_PROMOTION_WINDOW_NOT_OPEN). The two fixtures now reopen the
--     bootstrap window instead, which is what they meant.
--
-- Finding 7. 20260906050000 taught the inventory installer to ship the stock
-- adjustments account and the stock_adjustment posting rule, and nothing
-- could give them to an organisation that had installed inventory before that
-- day: an installer's change set has a fixed code the organisation may hold
-- only once, and the demonstration's ensure step skips an installer whose
-- change set exists. A count variance or write-off there refuses, and the
-- hint told the administrator to promote a change set by hand.
--
--   * erp_ref.module_installer: every installer's change-set code with its
--     current version; erp_ref.module_upgrade_item and _account: what each
--     version added, as the payloads the installer writes, accounts by
--     purpose so the chart the organisation chose is honoured.
--   * erp.module_installation: which version of each installer configured
--     this organisation; written by erp.install_module_config() from now on,
--     backfilled from the change sets that exist.
--   * erp.plan_module_upgrade(code) says what the current version would add
--     that the organisation lacks; erp.upgrade_module_configuration(code)
--     authors it as one change set (a suffixed code, as a pack does), promotes
--     it before go-live and leaves it ready for a second administrator after,
--     and stamps the register. The demonstration's ensure step upgrades an
--     installed module whose plan is not empty. Three doors on the
--     configuration screen.
--
-- Proof: erp_test.promotion_window_suite() (6 cases) and
-- erp_test.module_upgrade_suite() (8 cases), both pinned; the two re-pinned
-- fixtures (28 and 13, unchanged); the standard assertions and the console.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The window is a row the promoter writes
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.promotion_window (
  promotion_id uuid primary key,
  tenant_id    uuid not null,
  xact_id      bigint not null,
  opened_by    uuid,
  opened_at    timestamptz not null default now()
);

select erp_meta.register_table('erp_meta', 'promotion_window', 'platform_internal',
  'Which promotion opened a live-configuration window, in which transaction. Written only by erp.open_promotion_window() from inside erp.promote_change_set(); read only by the live-configuration guard through erp.promotion_window_is_open(). A row from an earlier transaction is inert.');

comment on table erp_meta.promotion_window is
  'A live-configuration window is the promoter''s act, recorded here with the '
  'transaction it happened in. The guard accepts a write only while the '
  'setting erp.promotion_id names a promotion this table shows was opened in '
  'the current transaction; a setting set by hand names nothing here.';

create or replace function erp.open_promotion_window(p_promotion_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pr       erp.promotion%rowtype;
begin
  select * into pr from erp.promotion p
   where p.id = p_promotion_id and p.tenant_id = v_tenant;

  if not found or pr.status <> 'running' or pr.started_at <> now() then
    raise exception 'CLOVEERP_PROMOTION_NOT_RUNNING: % is not a promotion of this organisation begun in this transaction', p_promotion_id
      using errcode = '42501',
            hint = 'erp.promote_change_set() opens the window for the promotion it has just begun; nothing else does.';
  end if;

  perform erp.authorise('administration.promote', null, null, null, 'change_set', pr.change_set_id);

  insert into erp_meta.promotion_window (promotion_id, tenant_id, xact_id, opened_by)
  values (p_promotion_id, v_tenant, pg_current_xact_id()::text::bigint, erp.current_principal_id())
  on conflict (promotion_id) do update
    set xact_id = excluded.xact_id, opened_by = excluded.opened_by, opened_at = now();

  perform set_config('erp.promotion_id', p_promotion_id::text, true);
end;
$$;

revoke all on function erp.open_promotion_window(uuid) from public, anon, authenticated;

comment on function erp.open_promotion_window(uuid) is
  'Opens the window in which the live-configuration guard lets a promotion '
  'write. Definer, because the window table is platform-internal; gated on '
  'administration.promote for the change set and on the promotion row being '
  'this organisation''s, running, and begun in this transaction.';

create or replace function erp.promotion_window_is_open(p_setting text, p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_setting !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then false
     else exists (
       select 1
         from erp.promotion p
         join erp_meta.promotion_window w on w.promotion_id = p.id
        where p.id = p_setting::uuid
          and p.tenant_id = p_tenant_id
          and w.tenant_id = p_tenant_id
          and p.status = 'running'
          and p.started_at = now()
          and w.xact_id = pg_current_xact_id()::text::bigint) end
$$;

revoke all on function erp.promotion_window_is_open(text, uuid) from public, anon;

comment on function erp.promotion_window_is_open(text, uuid) is
  'Whether the setting erp.promotion_id names a promotion of this organisation '
  'that erp.open_promotion_window() opened in the current transaction. The '
  'live-configuration guard''s only question.';

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'open_promotion_window',
   'Writes erp_meta.promotion_window, which is platform-internal, after erp.authorise(administration.promote) on the change set and after verifying the promotion row is this organisation''s, running and begun in this transaction; the one route that opens a live-configuration window.'),
  ('erp', 'promotion_window_is_open',
   'Reads erp_meta.promotion_window on behalf of the live-configuration guard, which runs as the writer; answers only whether the named promotion of the named organisation was opened in the current transaction.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- The guard: the setting alone no longer stands it down.
do $guard$
declare
  v_def text;
  v_n   text := E'  if nullif(current_setting(''erp.promotion_id'', true), '''') is not null then\n    return coalesce(new, old);\n  end if;';
  v_r   text := E'  if nullif(current_setting(''erp.promotion_id'', true), '''') is not null then\n'
             || E'    if erp.promotion_window_is_open(current_setting(''erp.promotion_id'', true), v_tenant) then\n'
             || E'      return coalesce(new, old);\n'
             || E'    end if;\n'
             || E'    raise exception ''CLOVEERP_PROMOTION_WINDOW_NOT_OPEN: erp.promotion_id names % which is not a promotion of this organisation opened by the promoter in this transaction'', current_setting(''erp.promotion_id'', true)\n'
             || E'      using errcode = ''42501'',\n'
             || E'            hint = ''Configuration on a live environment is written by erp.promote_change_set(); a session that sets the promotion id by hand is refused.'';\n'
             || E'  end if;';
begin
  v_def := pg_get_functiondef('erp.guard_live_configuration()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_LIVE_GUARD_UNRECOGNISED: erp.guard_live_configuration() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$guard$;

-- The promoter opens the window through the door that records it.
do $promoter$
declare
  v_def text;
  v_n   text := E'  perform set_config(''erp.promotion_id'', v_promo::text, true);';
  v_r   text := E'  perform erp.open_promotion_window(v_promo);';
begin
  v_def := pg_get_functiondef('erp.promote_change_set(uuid,text[],boolean)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: erp.promote_change_set() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$promoter$;

-- The two fixtures that set the setting by hand reopen the bootstrap window
-- instead: every refusal they test is raised by the function under test, and
-- the fake window only ever placated the guard.
do $fixtures$
declare
  v_def text;
  v_n1  text := E'  perform set_config(''erp.promotion_id'', gen_random_uuid()::text, true);';
  v_n2  text := E'  perform set_config(''erp.promotion_id'', '''', true);';
begin
  v_def := pg_get_functiondef('erp_test.promotion_completeness_suite()'::regprocedure);
  if position(v_n1 in v_def) = 0 or position(v_n2 in v_def) = 0 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.promotion_completeness_suite() does not set the promotion id by hand where this migration expects';
  end if;
  execute replace(replace(v_def,
    v_n1, E'  perform erp_test.reopen_bootstrap_window(v_tenant);'),
    v_n2, E'  perform erp_test.close_bootstrap_window(v_tenant);');

  v_def := pg_get_functiondef('erp_test.purchase_pricing_suite()'::regprocedure);
  if position('  ' || v_n1 in v_def) = 0 or position('  ' || v_n2 in v_def) = 0 then
    raise exception 'CLOVEERP_FIXTURE_UNRECOGNISED: erp_test.purchase_pricing_suite() does not set the promotion id by hand where this migration expects';
  end if;
  execute replace(replace(v_def,
    '  ' || v_n1, E'    perform erp_test.reopen_bootstrap_window(r.tenant_id);'),
    '  ' || v_n2, E'    perform erp_test.close_bootstrap_window(r.tenant_id);');
end
$fixtures$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A module knows its version
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.module_installer (
  install_code    text primary key,
  module_code     text not null references erp_ref.module (code),
  current_version integer not null default 1 check (current_version >= 1),
  description     text not null
);

select erp_meta.register_table('erp_ref', 'module_installer', 'product_content',
  'Every module installer by the change-set code it writes, with the version the product currently ships; erp.plan_module_upgrade() reads it against erp.module_installation.');

insert into erp_ref.module_installer (install_code, module_code, current_version, description) values
  ('master-data-governance', 'master_data',    1, 'Master data governance: scoring, duplicates, change requests, import.'),
  ('procurement-lifecycle',  'procurement',    1, 'The purchase order lifecycle, numbering and approval.'),
  ('procurement-controls',   'procurement',    1, 'Receipt and match tolerances, landed cost.'),
  ('sales-lifecycle',        'sales',          1, 'The sales order lifecycle, numbering and approval.'),
  ('sales-controls',         'sales',          1, 'Pricing, credit, allocation and returns.'),
  ('finance-posting',        'finance',        1, 'The ledger, the chart, the posting rules for every document.'),
  ('inventory-operations',   'inventory',      2, 'Version 2 (20260906050000) added the stock adjustments account and the stock_adjustment posting rule, so a count variance or write-off posts.'),
  ('planning',               'planning',       1, 'Forecasting, policy, planning runs.'),
  ('production',             'production',     1, 'Works orders, execution, batch records.'),
  ('quality',                'quality',        1, 'Inspection plans, release, the regulatory clock.'),
  ('logistics',              'logistics',      1, 'Carriers, shipments, despatch.'),
  ('period-close',           'finance',        1, 'Close tasks and the calendar.'),
  ('receivables',            'finance',        1, 'Dunning, cash application, ageing.'),
  ('tax',                    'finance',        1, 'Tax determination.'),
  ('reporting-services',     'reporting',      1, 'Subscriptions, packs and extracts.'),
  ('notification-services',  'administration', 1, 'Notification routes and templates.'),
  ('commercial',             'commercial',     1, 'Price book, quotes, contracts.')
on conflict (install_code) do update
  set module_code = excluded.module_code, current_version = excluded.current_version, description = excluded.description;

create table if not exists erp_ref.module_upgrade_item (
  install_code text not null references erp_ref.module_installer (install_code),
  to_version   integer not null,
  object_kind  text not null,
  object_key   text not null,
  payload      jsonb not null,
  seq          integer not null default 100,
  primary key (install_code, to_version, object_kind, object_key)
);

select erp_meta.register_table('erp_ref', 'module_upgrade_item', 'product_content',
  'What each installer version added, as the change-set items the installer writes; an account named inside a payload as {"purpose": ...} is resolved to the code the organisation''s chart gives that purpose when the upgrade is planned.');

create table if not exists erp_ref.module_upgrade_account (
  install_code text not null references erp_ref.module_installer (install_code),
  to_version   integer not null,
  purpose      text not null references erp_ref.chart_account_purpose (purpose),
  primary key (install_code, to_version, purpose)
);

select erp_meta.register_table('erp_ref', 'module_upgrade_account', 'product_content',
  'The accounts each installer version creates outside the change set (an account is master data, not configuration), by purpose; the upgrade plans one per active company that lacks it.');

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq) values
  ('inventory-operations', 2, 'posting_rule', 'stock_adjustment',
   jsonb_build_object(
     'code', 'stock_adjustment', 'name', 'Stock adjustment', 'ledger', 'GL',
     'event_type', 'stock.adjusted',
     'posting_lines', jsonb_build_array(
       jsonb_build_object('account', jsonb_build_object('purpose', 'inventory'), 'side', 'debit', 'basis', 'stock_cost', 'rate', 1,
                          'description', 'Inventory adjusted, at cost'),
       jsonb_build_object('account', jsonb_build_object('purpose', 'stock_adjustment'), 'side', 'credit', 'balancing', true,
                          'description', 'Stock adjustment'))),
   100)
on conflict (install_code, to_version, object_kind, object_key) do update set payload = excluded.payload, seq = excluded.seq;

insert into erp_ref.module_upgrade_account (install_code, to_version, purpose) values
  ('inventory-operations', 2, 'stock_adjustment')
on conflict do nothing;

create table if not exists erp.module_installation (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references erp.tenant (id) on delete cascade,
  install_code          text not null,
  module_code           text references erp_ref.module (code),
  installer_version     integer not null default 1,
  change_set_id         uuid,
  pending_change_set_id uuid,
  installed_at          timestamptz not null default now(),
  upgraded_at           timestamptz,
  created_at            timestamptz not null default now(),
  created_by            uuid,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  unique (tenant_id, install_code)
);

select erp_meta.register_table('erp', 'module_installation', 'tenant_scoped',
  'Which version of each module installer configured this organisation, and the change set that did it; the upgrade planner compares it with erp_ref.module_installer.');

comment on table erp.module_installation is
  'The record an installer''s change set used to be. A change-set code says '
  'that a module was installed; this says at which version, so the product '
  'can say what a later version would add.';

-- Backfill: every organisation holding an installer''s change set installed
-- that module; inventory is at version 2 where the rule the version brought
-- is in force.
insert into erp.module_installation (tenant_id, install_code, module_code, installer_version, change_set_id, installed_at)
select cs.tenant_id, cs.code, mi.module_code,
       case when mi.install_code = 'inventory-operations'
                 and exists (select 1 from erp.posting_rule r
                              where r.tenant_id = cs.tenant_id and r.code = 'stock_adjustment' and r.status = 'active')
            then 2 else 1 end,
       cs.id, cs.created_at
  from erp.change_set cs
  join erp_ref.module_installer mi on mi.install_code = cs.code
  join erp.tenant t on t.id = cs.tenant_id
 where t.status not in ('deleting', 'deleted')
on conflict (tenant_id, install_code) do nothing;

-- An account inside a payload is named by purpose; the organisation''s chart
-- says which code that is.
create or replace function erp.resolve_account_purposes(p_payload jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_lines jsonb := '[]'::jsonb;
  l       jsonb;
begin
  if p_payload -> 'posting_lines' is null then
    return p_payload;
  end if;
  for l in select * from jsonb_array_elements(p_payload -> 'posting_lines') loop
    if jsonb_typeof(l -> 'account') = 'object' and (l -> 'account' ->> 'purpose') is not null then
      l := l || jsonb_build_object('account', erp.chart_account_code(l -> 'account' ->> 'purpose'));
    end if;
    v_lines := v_lines || jsonb_build_array(l);
  end loop;
  return p_payload || jsonb_build_object('posting_lines', v_lines);
end;
$$;

revoke all on function erp.resolve_account_purposes(jsonb) from public, anon, authenticated;

create or replace function erp.plan_module_upgrade(p_install_code text)
returns table (object_kind text, object_key text, payload jsonb, to_version integer, effect text, seq integer)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  inst     erp.module_installation%rowtype;
  mi       erp_ref.module_installer%rowtype;
begin
  select * into mi from erp_ref.module_installer m where m.install_code = p_install_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INSTALLER: % is not a module installer this product ships', p_install_code
      using errcode = '23503',
            hint = 'erp_module_installations() lists the installers and their versions.';
  end if;

  select * into inst from erp.module_installation i
   where i.tenant_id = v_tenant and i.install_code = p_install_code;
  if not found then
    raise exception 'CLOVEERP_MODULE_NOT_INSTALLED: this organisation has not installed %', p_install_code
      using errcode = '23503',
            hint = 'Install the module first from /administration/configuration; an upgrade only applies to a module the organisation has.';
  end if;

  return query
    -- Items a later version added that the organisation does not hold. A
    -- posting rule is present when a version of that code is in force; an
    -- account when the company has it; anything else by containment in the
    -- configuration manifest, as the pack planner decides.
    select ui.object_kind, ui.object_key, erp.resolve_account_purposes(ui.payload), ui.to_version,
           case when ui.object_kind = 'posting_rule' then 'a posting rule the organisation lacks'
                else 'configuration the organisation lacks' end,
           ui.seq
      from erp_ref.module_upgrade_item ui
     where ui.install_code = p_install_code
       and ui.to_version > inst.installer_version
       and not (
         case ui.object_kind
           when 'posting_rule' then exists (
             select 1 from erp.posting_rule r
              where r.tenant_id = v_tenant and r.code = ui.object_key and r.status = 'active')
           else coalesce((select m.content from erp.configuration_manifest(array[ui.object_kind]) m
                            where m.object_key = ui.object_key), '{}'::jsonb)
                @> erp.resolve_account_purposes(ui.payload)
         end)
    union all
    select 'account', e.code || '|' || erp.chart_account_code(ua.purpose),
           jsonb_build_object(
             'entity', e.code,
             'code', erp.chart_account_code(ua.purpose),
             'name', cap.name,
             'account_type', cap.account_type::text,
             'is_postable', true,
             'currency', e.base_currency),
           ua.to_version,
           format('an account the company %s lacks', e.code),
           10
      from erp_ref.module_upgrade_account ua
      join erp_ref.chart_account_purpose cap on cap.purpose = ua.purpose
      join erp.entity e on e.tenant_id = v_tenant and e.status = 'active'
     where ua.install_code = p_install_code
       and ua.to_version > inst.installer_version
       and not exists (
         select 1 from erp.account a
          where a.tenant_id = v_tenant and a.entity_id = e.id
            and a.code = erp.chart_account_code(ua.purpose) and a.status = 'active')
     order by 6, 4, 1, 2;
end;
$$;

revoke all on function erp.plan_module_upgrade(text) from public, anon;

comment on function erp.plan_module_upgrade(text) is
  'What the current version of a module installer would add to this '
  'organisation and it does not hold: the posting rules and configuration a '
  'later version brought, and the accounts each company lacks. Empty when the '
  'organisation is current.';

create or replace function erp.upgrade_module_configuration(p_install_code text)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  mi       erp_ref.module_installer%rowtype;
  v_cs     uuid;
  v_n      integer := 0;
  v_live   boolean;
  p        record;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', null);

  select * into mi from erp_ref.module_installer m where m.install_code = p_install_code;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INSTALLER: % is not a module installer this product ships', p_install_code
      using errcode = '23503',
            hint = 'erp_module_installations() lists the installers and their versions.';
  end if;

  if not exists (select 1 from erp.plan_module_upgrade(p_install_code)) then
    raise exception 'CLOVEERP_NOTHING_TO_UPGRADE: the organisation already holds everything version % of % brings', mi.current_version, p_install_code
      using errcode = '23514',
            hint = 'erp_module_installations() shows each module''s installed and current version.';
  end if;

  v_cs := erp.create_change_set(
    format('%s-upgrade-v%s-%s', p_install_code, mi.current_version, substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
    format('%s upgrade to version %s', mi.install_code, mi.current_version),
    format('What version %s of the %s installer brings that this organisation lacked.', mi.current_version, mi.install_code));

  for p in select * from erp.plan_module_upgrade(p_install_code) loop
    perform erp.add_change_set_item(v_cs, p.object_kind, p.object_key, p.payload, 'upsert', null,
                                    format('%s version %s', p_install_code, p.to_version));
    v_n := v_n + 1;
  end loop;

  perform erp.submit_change_set(v_cs);

  v_live := erp.tenant_is_live();
  if not v_live then
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    update erp.module_installation i
       set installer_version = mi.current_version, change_set_id = v_cs, pending_change_set_id = null,
           upgraded_at = now(), updated_at = now()
     where i.tenant_id = v_tenant and i.install_code = p_install_code;
  else
    update erp.module_installation i
       set pending_change_set_id = v_cs, updated_at = now()
     where i.tenant_id = v_tenant and i.install_code = p_install_code;
  end if;

  return jsonb_build_object('change_set_id', v_cs, 'items', v_n, 'promoted', not v_live, 'to_version', mi.current_version);
end;
$$;

revoke all on function erp.upgrade_module_configuration(text) from public, anon;

comment on function erp.upgrade_module_configuration(text) is
  'Authors what the current installer version adds as one change set, coded '
  'with a suffix so the organisation may upgrade more than once. Before '
  'go-live it is approved and promoted at once and the register stamped; after, '
  'it is left ready for a second administrator and the register remembers '
  'which change set is pending.';

-- A promotion of a pending upgrade stamps the register when it lands.
create or replace function erp.stamp_module_upgrade_promoted()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'promoted' and old.status is distinct from 'promoted' then
    update erp.module_installation i
       set installer_version = mi.current_version, change_set_id = new.id, pending_change_set_id = null,
           upgraded_at = now(), updated_at = now()
      from erp_ref.module_installer mi
     where i.tenant_id = new.tenant_id and i.pending_change_set_id = new.id
       and mi.install_code = i.install_code;
  end if;
  return new;
end;
$$;

drop trigger if exists t_change_set_module_upgrade on erp.change_set;
create trigger t_change_set_module_upgrade
  after update of status on erp.change_set
  for each row execute function erp.stamp_module_upgrade_promoted();

create or replace function erp.module_installations()
returns table (install_code text, module_code text, installer_version integer, current_version integer,
               upgrade_available boolean, change_set_id uuid, pending_change_set_id uuid,
               installed_at timestamptz, upgraded_at timestamptz)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  return query
    select i.install_code, i.module_code, i.installer_version, mi.current_version,
           mi.current_version > i.installer_version
             and exists (select 1 from erp.plan_module_upgrade(i.install_code)),
           i.change_set_id, i.pending_change_set_id, i.installed_at, i.upgraded_at
      from erp.module_installation i
      join erp_ref.module_installer mi on mi.install_code = i.install_code
     where i.tenant_id = v_tenant
     order by i.install_code;
end;
$$;

revoke all on function erp.module_installations() from public, anon;

-- The installer records the version it installs.
do $installer$
declare
  v_def text;
  v_n   text := E'  perform erp.submit_change_set(v_cs);\n';
  v_r   text := E'  perform erp.submit_change_set(v_cs);\n\n'
             || E'  insert into erp.module_installation (tenant_id, install_code, module_code, installer_version, change_set_id)\n'
             || E'  select erp.require_tenant_id(), p_code, mi.module_code, coalesce(mi.current_version, 1), v_cs\n'
             || E'    from (select 1) one left join erp_ref.module_installer mi on mi.install_code = p_code\n'
             || E'  on conflict (tenant_id, install_code) do update\n'
             || E'    set installer_version = excluded.installer_version, change_set_id = excluded.change_set_id,\n'
             || E'        upgraded_at = now(), updated_at = now();\n';
begin
  v_def := pg_get_functiondef('erp.install_module_config(text,text,text,jsonb)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_MODULE_INSTALLER_UNRECOGNISED: erp.install_module_config() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$installer$;

-- The demonstration''s ensure step upgrades inventory when a later version has
-- something to add; a fresh demonstration never takes that arm.
do $demo$
declare
  v_def text;
  v_n   text := E'  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = ''inventory-operations'') then\n'
             || E'    perform erp.configure_inventory(''average'', ''administrator'', 2, 1.5);\n'
             || E'    v_did := v_did || ''"inventory"''::jsonb;\n'
             || E'  end if;';
  v_r   text := E'  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = ''inventory-operations'') then\n'
             || E'    perform erp.configure_inventory(''average'', ''administrator'', 2, 1.5);\n'
             || E'    v_did := v_did || ''"inventory"''::jsonb;\n'
             || E'  elsif exists (select 1 from erp.module_installation i where i.tenant_id = p_tenant_id and i.install_code = ''inventory-operations'')\n'
             || E'        and exists (select 1 from erp.plan_module_upgrade(''inventory-operations'')) then\n'
             || E'    perform erp.upgrade_module_configuration(''inventory-operations'');\n'
             || E'    v_did := v_did || ''"inventory upgraded"''::jsonb;\n'
             || E'  end if;';
begin
  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: erp.ensure_demo_configuration() is not the body this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);
end
$demo$;

-- ── Doors ────────────────────────────────────────────────────────────────────

create or replace function public.erp_module_installations()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(i) order by i.install_code), '[]'::jsonb)
    from erp.module_installations() i
$$;

create or replace function public.erp_module_upgrade_plan(p_install_code text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.seq, p.object_kind, p.object_key), '[]'::jsonb)
    from erp.plan_module_upgrade(p_install_code) p
$$;

create or replace function public.erp_upgrade_module_configuration(p_install_code text)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.upgrade_module_configuration(p_install_code)
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp_module_installations()',
    'erp_module_upgrade_plan(text)',
    'erp_upgrade_module_configuration(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upgrade_module_configuration', 'erp.upgrade_module_configuration',
   'Authors the current installer version''s additions as one change set and promotes it before go-live; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/configuration',
  array['erp_module_installations', 'erp_module_upgrade_plan', 'erp_upgrade_module_configuration']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proof
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.promotion_window_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record; a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  v_second uuid; v_tok text; res jsonb;
  v_cs uuid; v_fake uuid; v_promo uuid;
  v_ok boolean; v_msg text; v_by uuid;
begin
  begin
    select * into r from erp.provision_tenant('zzpromo', 'Promotion window', 'a@zzpromo.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zzpromo.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 1. The setting alone opens nothing.
    v_ok := false; v_msg := null;
    begin
      perform set_config('erp.promotion_id', gen_random_uuid()::text, true);
      insert into erp.role (tenant_id, code, name, status) values (r.tenant_id, 'zz-by-hand', 'By hand', 'active');
      v_msg := 'the role was written';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PROMOTION_WINDOW_NOT_OPEN%'; v_msg := left(sqlerrm, 90);
    end;
    perform set_config('erp.promotion_id', '', true);
    return query select 'a promotion id set by hand does not open the window', v_ok, v_msg;

    -- 2. Nor does a promotion row written by hand.
    v_cs := erp.create_change_set('zzp-fake', 'A fake', 'A promotion row nobody opened.');
    insert into erp.promotion (tenant_id, change_set_id, environment_id, actor_id)
    values (r.tenant_id, v_cs, erp.self_environment_id(r.tenant_id), erp.current_principal_id()) returning id into v_fake;
    v_ok := false; v_msg := null;
    begin
      perform set_config('erp.promotion_id', v_fake::text, true);
      insert into erp.role (tenant_id, code, name, status) values (r.tenant_id, 'zz-by-row', 'By row', 'active');
      v_msg := 'the role was written';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PROMOTION_WINDOW_NOT_OPEN%'; v_msg := left(sqlerrm, 90);
    end;
    perform set_config('erp.promotion_id', '', true);
    return query select 'a running promotion row nobody opened does not open it either', v_ok, v_msg;

    -- 3. The promoter does, and the window says who.
    v_cs := erp.create_change_set('zzp-real', 'A real one', 'One role, promoted properly.');
    perform erp.add_change_set_item(v_cs, 'role', 'zz-promoted', jsonb_build_object(
      'code', 'zz-promoted', 'name', 'Promoted role',
      'permissions', jsonb_build_array(jsonb_build_object('permission', 'master_data.read'))));
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    v_promo := erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select w.opened_by into v_by from erp_meta.promotion_window w where w.promotion_id = v_promo;
    return query select 'the promoter opens the window and the window records who',
      exists (select 1 from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz-promoted' and ro.status = 'active')
      and v_by = v_second
      and (select p.status from erp.promotion p where p.id = v_promo) = 'succeeded',
      format('role promoted; window opened by the second administrator: %s', v_by = v_second);

    -- 4. Once the promoter is done the window is shut.
    v_ok := false; v_msg := null;
    begin
      insert into erp.role (tenant_id, code, name, status) values (r.tenant_id, 'zz-after', 'After', 'active');
      v_msg := 'the role was written';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_LIVE_CONFIG_EDIT%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'after the promotion the setting is empty and a bare write is refused as before',
      v_ok and coalesce(current_setting('erp.promotion_id', true), '') = '', v_msg;

    -- 5. The opener refuses a promotion that is not running here.
    v_ok := false; v_msg := null;
    begin
      perform erp.open_promotion_window(gen_random_uuid());
      v_msg := 'it opened';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PROMOTION_NOT_RUNNING%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'the opener refuses a promotion that is not this organisation''s, running, in this transaction', v_ok, v_msg;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzpromo'),
    'the organisation and its promotions rolled back';
end;
$$;

create or replace function erp_test.assert_promotion_window_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _promotion_window on commit drop as
    select * from erp_test.promotion_window_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _promotion_window;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_PROMOTION_WINDOW_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_PROMOTION_WINDOW_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('promotion window: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_promotion_window_suite() from public, anon, authenticated;
revoke all on function erp_test.promotion_window_suite() from public, anon, authenticated;

create or replace function erp_test.module_upgrade_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_ccy char(3); v_supplier uuid; v_recv uuid; v_item uuid;
  v_grn uuid; v_code text; res jsonb; v_cs uuid;
  v_ok boolean; v_msg text; v_n integer; v_acc text; v_cur integer;
begin
  begin
    select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzmodu', 'Module upgrade suite', 'admin@zzmodu.test', 'Upgrade Admin') t;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000f1', 'admin@zzmodu.test');
    perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000000f1')::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id, e.base_currency into v_entity, v_ccy from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
    select l.id into v_recv from erp.location l where l.tenant_id = v_tenant and l.site_id = v_site and l.location_type = 'receiving' limit 1;
    select pr.party_id into v_supplier from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-UPG', 'Upgrade item', 'RAW', u.id, 'active' from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_item;
    v_acc := erp.chart_account_code('stock_adjustment');

    -- Make the organisation one configured at version 1: nothing a later
    -- version of the installer brought is left standing.
    delete from erp.posting_rule r where r.tenant_id = v_tenant
       and r.code in (select ui.object_key from erp_ref.module_upgrade_item ui where ui.install_code = 'inventory-operations' and ui.object_kind = 'posting_rule');
    delete from erp.account a where a.tenant_id = v_tenant
       and a.code in (select erp.chart_account_code(ua.purpose) from erp_ref.module_upgrade_account ua where ua.install_code = 'inventory-operations');
    update erp.module_installation i set installer_version = 1 where i.tenant_id = v_tenant and i.install_code = 'inventory-operations';

    select mi.current_version into v_cur from erp_ref.module_installer mi where mi.install_code = 'inventory-operations';

    -- 1. The register.
    return query select 'the register reads the installed version behind the current one, with an upgrade available',
      exists (select 1 from erp.module_installations() m
               where m.install_code = 'inventory-operations' and m.installer_version = 1 and m.current_version = v_cur and v_cur > 1 and m.upgrade_available),
      (select format('installed %s, current %s, available %s', m.installer_version, m.current_version, m.upgrade_available)
         from erp.module_installations() m where m.install_code = 'inventory-operations');

    -- 2. The plan: every rule a later version brought, and one account per company.
    select count(*) into v_n from erp.plan_module_upgrade('inventory-operations');
    return query select 'the plan names the posting rules and one account per company',
      v_n = (select count(*) from erp_ref.module_upgrade_item ui where ui.install_code = 'inventory-operations' and ui.to_version > 1)
          + (select count(*) from erp_ref.module_upgrade_account ua where ua.install_code = 'inventory-operations' and ua.to_version > 1)
            * (select count(*) from erp.entity e where e.tenant_id = v_tenant and e.status = 'active')
      and exists (select 1 from erp.plan_module_upgrade('inventory-operations') p where p.object_kind = 'posting_rule' and p.object_key = 'stock_adjustment'
                   and p.payload -> 'posting_lines' -> 1 ->> 'account' = v_acc)
      and exists (select 1 from erp.plan_module_upgrade('inventory-operations') p where p.object_kind = 'account' and p.payload ->> 'code' = v_acc),
      format('%s item(s) planned', v_n);

    -- 3. Before the upgrade a write-off refuses by name.
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supplier, current_date, v_ccy, 'ZZ-GRN-UPG', '{}'::jsonb);
    perform erp.add_document_line(v_grn, v_item, 10, 1000, 'ten at ten', current_date);
    perform erp.transition_document(v_grn, 'post', 'upgrade suite');
    set constraints all immediate;
    v_ok := false; v_msg := null;
    begin
      perform erp.write_off_stock(v_item, v_site, v_recv, 1, 'upgrade suite, before');
      v_msg := 'it posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NO_POSTING_RULE_IN_FORCE%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'before the upgrade a write-off refuses for want of the rule', v_ok, v_msg;

    -- 4. The door upgrades and, before go-live, promotes.
    res := public.erp_upgrade_module_configuration('inventory-operations');
    select cs.code into v_code from erp.change_set cs where cs.id = (res ->> 'change_set_id')::uuid;
    return query select 'the upgrade lands as one promoted change set and the register moves to the current version',
      (res ->> 'promoted')::boolean and (res ->> 'to_version')::int = v_cur
      and v_code like 'inventory-operations-upgrade-v' || v_cur || '-%'
      and exists (select 1 from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'stock_adjustment' and r.status = 'active')
      and exists (select 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_acc and a.status = 'active')
      and exists (select 1 from erp.module_installation i where i.tenant_id = v_tenant and i.install_code = 'inventory-operations'
                   and i.installer_version = v_cur and i.change_set_id = (res ->> 'change_set_id')::uuid and i.pending_change_set_id is null),
      format('%s: %s item(s), promoted %s', v_code, res ->> 'items', res ->> 'promoted');

    -- 5. Now the write-off posts.
    perform erp.write_off_stock(v_item, v_site, v_recv, 1, 'upgrade suite, after');
    set constraints all immediate;
    return query select 'after the upgrade the write-off posts a balanced adjustment journal',
      exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.source_code = 'stock.adjusted' and j.status = 'posted'
               and (select sum(l.debit_minor) - sum(l.credit_minor) from erp.journal_line l where l.journal_id = j.id) = 0
               and (select sum(l.debit_minor) from erp.journal_line l where l.journal_id = j.id) = 1000),
      'one stock.adjusted journal of 1000, balanced';

    -- 6. Nothing twice.
    v_ok := false; v_msg := null;
    begin
      perform erp.upgrade_module_configuration('inventory-operations');
      v_msg := 'it upgraded again';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOTHING_TO_UPGRADE%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a second upgrade has nothing to add and says so', v_ok, v_msg;

    -- 7. On a live organisation the change set waits for a second administrator.
    -- The rule is withdrawn rather than deleted: a journal already names it.
    update erp.posting_rule r set status = 'withdrawn', updated_at = now()
     where r.tenant_id = v_tenant and r.code = 'stock_adjustment' and r.status = 'active';
    update erp.module_installation i set installer_version = 1 where i.tenant_id = v_tenant and i.install_code = 'inventory-operations';
    perform erp_test.close_bootstrap_window(v_tenant);
    res := public.erp_upgrade_module_configuration('inventory-operations');
    v_cs := (res ->> 'change_set_id')::uuid;
    return query select 'on a live organisation the upgrade is authored and left ready, not promoted',
      not (res ->> 'promoted')::boolean
      and (select cs.status from erp.change_set cs where cs.id = v_cs) = 'ready'
      and not exists (select 1 from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'stock_adjustment' and r.status = 'active')
      and exists (select 1 from erp.module_installation i where i.tenant_id = v_tenant and i.install_code = 'inventory-operations'
                   and i.installer_version = 1 and i.pending_change_set_id = v_cs),
      format('change set %s, promoted %s', (select cs.status from erp.change_set cs where cs.id = v_cs), res ->> 'promoted');
    perform erp_test.reopen_bootstrap_window(v_tenant);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zzmodu'),
    'the organisation and its upgrade rolled back';
end;
$$;

create or replace function erp_test.assert_module_upgrade_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _module_upgrade on commit drop as
    select * from erp_test.module_upgrade_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _module_upgrade;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_MODULE_UPGRADE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_MODULE_UPGRADE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('module upgrade: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_module_upgrade_suite() from public, anon, authenticated;
revoke all on function erp_test.module_upgrade_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_promotion_window_suite();
select erp_test.assert_module_upgrade_suite();
select erp_test.assert_promotion_completeness_suite();
select erp_test.assert_purchase_pricing_suite();
select erp_test.assert_bootstrap_window_suite();
select erp_test.assert_costing_suite();
select erp_test.assert_demo_history_suite();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_product_decisions_enforced();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_linter_clean();
select erp.assert_session_context_hygiene();

do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
