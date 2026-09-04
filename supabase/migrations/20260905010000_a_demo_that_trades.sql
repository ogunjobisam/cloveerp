-- A demo that trades.
--
-- erp.seed_demo() builds an organisation nobody can use. It creates a tenant,
-- two entities, three sites, a viewer and a role, and stops. No installer has
-- ever run on the organisation it hands back: zero change sets, zero document
-- types, zero ledgers, zero state machines. The launchpad shows every module
-- tile regardless, and every screen behind a tile then says the module is not
-- installed. That reads as being locked out, and was reported as exactly that.
-- Even "Build demo operating history" cannot help it: erp.seed_demo_operations()
-- runs no installer either, so its first create_document('purchase_order', …)
-- raises on an unknown document type and the raise is swallowed into a note.
--
-- And when an organisation is configured, the demonstration it can build is
-- three documents dated today. A dashboard reads movements, an ageing report
-- reads due dates, a margin report reads a year of cost against a year of
-- price; three documents dated today show none of them anything.
--
-- So this migration does two things and fixes two more it found on the way.
--
-- 1. erp.ensure_demo_configuration(): one idempotent path that takes a demo
--    organisation, old or new, from provisioned to trading — sandbox, the six
--    installers, four years of fiscal periods, posting rules in force from two
--    years back, numbering that does not carry the year, and enough master
--    data to trade with (30 items, 12 customers, 8 suppliers, three
--    locations). erp.seed_demo() now creates the sandbox itself, and the
--    public door erp_seed_demo() runs the installers after adopting the
--    organisation, so the demo an "open the demo" click hands back is one
--    that has modules in it. The existing demo is not re-created; the same
--    function brings it to the same state the next time anything asks.
--
-- 2. erp.seed_demo_history(): a year of trading, built a few days per call
--    through the spine — erp.create_document(), erp.add_document_line(),
--    erp.transition_document(), erp.receive_against(),
--    erp.invoice_from_delivery(), erp.apply_cash() — and nothing written
--    around them. Every journal is raised by the posting bridge, every stock
--    movement by the stock bridge, every state by its machine, so the three
--    integrity assertions hold on the demo exactly as they hold for a
--    customer. Nothing is relaxed for it. The builder is self-pacing: it
--    builds five days and says where the next call should start, so a button
--    with an eight-second statement timeout can build a year by looping, and
--    a re-run of days that exist is a no-op.
--
-- The two product findings, both from executing the path rather than reading
-- it:
--
-- 3. The stock ledger did not follow the document date. erp.post_document_stock()
--    never set stock_movement.occurred_at, so it took its default, the wall
--    clock, while the journal the same posting raised took the document's own
--    date. A backdated receipt gave a ledger entry on the right day and a
--    stock movement that happened today. erp.load_opening_stock() already
--    stamps occurred_at from its own date; the bridge now does the same, and
--    only for a document dated before today — a same-day document keeps the
--    clock, so intra-day order is preserved exactly as it was. recorded_at is
--    untouched and still says when the row was written.
--
-- 4. Cash could only arrive today. erp.apply_cash() posted its journal and its
--    subledger items on current_date with no way to say otherwise, so a
--    receipt for an invoice from March could only ever be dated the day the
--    button was pressed. It gains a received-on date; the four-argument form
--    stays and means today, as it always did.
--
-- One rule changes scope. erp.assert_validation_environment_available()
-- required a sandbox of every organisation, live or not. The demo is not live,
-- has nothing to validate a proposal for, and the rule was a finding waiting
-- to happen against an organisation the rule exists to protect a customer
-- from being. It now binds live organisations, which is what it meant, and
-- erp.seed_demo() joins the two provisioning routes it watches for the
-- sandbox row.
--
-- Observed and left alone, so the next reader knows: under average costing
-- the valuation is quantity × the rounded average unit cost, so two receipts
-- of the same item at different prices leave the valuation a few minor units
-- from the ledger. The builder buys each item at one price, which is what a
-- demonstration should do anyway, and is what keeps
-- erp.assert_inventory_reconciles() true. erp.journal.journal_number is still
-- never set.
--
-- Every function this file patches is patched from the definition the
-- database is carrying, by one asserted replacement, and never restated from
-- memory. Restating a body silently reverts whatever a later migration taught
-- it. Where a needle is not found exactly the expected number of times the
-- migration refuses.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The stock ledger follows the document date
-- ═════════════════════════════════════════════════════════════════════════════

do $stock$
declare
  v_def   text;
  v_n1    text := $n$      document_id, document_line_id)
    values ($n$;
  v_r1    text := $r$      document_id, document_line_id, occurred_at)
    values ($r$;
  v_n2    text := $n$      p_document_id, ln.id);$n$;
  v_r2    text := $r$      p_document_id, ln.id,
      -- When it happened, which for a document dated before today is that day
      -- and not the moment somebody pressed post. A same-day document keeps
      -- the clock, so two postings this afternoon still order by the clock.
      -- recorded_at keeps saying when the row was written.
      case when coalesce(d.posting_date, d.document_date) >= current_date
           then clock_timestamp()
           else (coalesce(d.posting_date, d.document_date)::timestamp
                 + interval '12 hours') at time zone 'UTC'
      end);$r$;
  v_hits  integer;
begin
  v_def := pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure);

  v_hits := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: expected the movement column list once '
      'in erp.post_document_stock(), found %. The bridge has been rewritten since '
      'this migration was written and occurred_at would not be stamped.', v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: expected the movement values tail once '
      'in erp.post_document_stock(), found %.', v_hits;
  end if;
  if position('occurred_at' in v_def) > 0 then
    raise exception
      'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: erp.post_document_stock() already '
      'mentions occurred_at; this migration would stamp it twice.';
  end if;

  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  if position('occurred_at' in
        pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure)) = 0 then
    raise exception
      'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: the rewrite did not take.';
  end if;
end
$stock$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Cash arrives on a date
-- ═════════════════════════════════════════════════════════════════════════════

-- The five-argument form is the four-argument body with its three
-- current_date occurrences replaced by the parameter, and one guard in front
-- of the authorisation. The four-argument form then delegates and means today.
-- No default on the new parameter: a defaulted fifth argument would make every
-- existing four-argument call ambiguous.

do $cash$
declare
  v_def   text;
  v_head  text := $n$erp.apply_cash(p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text DEFAULT NULL::text)$n$;
  v_head2 text := $r$erp.apply_cash(p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text, p_received_on date)$r$;
  v_auth  text := $n$  perform erp.authorise('finance.post', null, null, null, 'party', p_party_id);$n$;
  v_auth2 text := $r$  -- A receipt has a date, and it is not in the future. Cash that arrives
  -- tomorrow is a forecast, and a forecast in the bank subledger is a lie the
  -- reconciliation would then have to explain.
  if p_received_on is null or p_received_on > current_date then
    raise exception
      'CLOVEERP_CASH_DATE_INVALID: a receipt is dated the day it arrived, which '
      'is % and not after today', coalesce(p_received_on::text, 'null')
      using errcode = '22007',
      hint = 'Pass the date the money reached the bank, or omit it and today is used.';
  end if;

  perform erp.authorise('finance.post', null, null, null, 'party', p_party_id);$r$;
  v_hits  integer;
begin
  v_def := pg_get_functiondef('erp.apply_cash(uuid,bigint,character,text)'::regprocedure);

  if position(v_head in v_def) = 0 then
    raise exception
      'CLOVEERP_CASH_APPLICATION_UNRECOGNISED: erp.apply_cash() no longer has the '
      'signature this migration expects; the dated form cannot be derived from it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, 'current_date', ''))) / length('current_date');
  if v_hits <> 3 then
    raise exception
      'CLOVEERP_CASH_APPLICATION_UNRECOGNISED: expected current_date three times in '
      'erp.apply_cash() (the journal and two subledger items), found %.', v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_auth, ''))) / length(v_auth);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_CASH_APPLICATION_UNRECOGNISED: expected the authorisation once in '
      'erp.apply_cash(), found %.', v_hits;
  end if;

  execute replace(replace(replace(v_def, v_head, v_head2), 'current_date', 'p_received_on'),
                  v_auth, v_auth2);
end
$cash$;

create or replace function erp.apply_cash(
  p_party_id uuid, p_amount_minor bigint, p_currency character, p_reference text default null)
returns table (subledger_item_id uuid, applied_minor bigint, remaining_minor bigint)
language sql
set search_path = ''
as $$
  select * from erp.apply_cash(p_party_id, p_amount_minor, p_currency, p_reference, current_date);
$$;

comment on function erp.apply_cash(uuid, bigint, character, text, date) is
  'Applies a customer receipt to the oldest open receivable items first, dated '
  'the day it arrived. The journal and both subledger items carry that date, so '
  'a receipt for a March invoice recorded in April sits in April.';
comment on function erp.apply_cash(uuid, bigint, character, text) is
  'erp.apply_cash() dated today. The form every existing caller uses; the dated '
  'form is the one that does the work.';

do $prove_cash$
declare v_src text;
begin
  v_src := pg_get_functiondef('erp.apply_cash(uuid,bigint,character,text,date)'::regprocedure);
  -- Once: the guard compares the date with today. The journal and the two
  -- subledger items no longer read the clock.
  if (length(v_src) - length(replace(v_src, 'current_date', ''))) / length('current_date') <> 1 then
    raise exception 'CLOVEERP_CASH_APPLICATION_UNRECOGNISED: the dated form still posts on current_date';
  end if;
  if position('p_received_on' in v_src) = 0 then
    raise exception 'CLOVEERP_CASH_APPLICATION_UNRECOGNISED: the dated form never reads its date';
  end if;
end
$prove_cash$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The sandbox rule binds live organisations
-- ═════════════════════════════════════════════════════════════════════════════

do $scope$
declare
  v_def  text;
  v_n1   text := $n$                    where e.tenant_id = t.id and e.is_self)
       and not exists$n$;
  v_r1   text := $r$                    where e.tenant_id = t.id and e.is_self and e.is_live)
       and not exists$r$;
  v_n2   text := $n$E'  %s has only its own production environment, so no proposal it '$n$;
  v_r2   text := $r$E'  %s is live and has only its own production environment, so no proposal it '$r$;
  v_n3   text := $n$array['erp.onboard_tenant(text,text)',$n$;
  v_r3   text := $r$array['erp.onboard_tenant(text,text)',
                               'erp.seed_demo()',$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.assert_validation_environment_available()'::regprocedure);
  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1),
    (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2),
    (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_VALIDATION_RULE_UNRECOGNISED: a needle this migration expects once '
        'in erp.assert_validation_environment_available() was found % time(s); the '
        'rule has been rewritten and would not be scoped by is_live.', v_hits;
    end if;
  end loop;
  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);
end
$scope$;

-- The suite that falsifies the rule did so with an onboarded organisation,
-- which is not live. The falsification now makes it live first, and puts it
-- back: an organisation that is not live and has no sandbox is what the demo
-- is, and is not a finding.
do $suite$
declare
  v_def  text;
  v_n1   text := $n$  delete from erp.environment where id = v_sandbox;
  begin
    perform erp.assert_validation_environment_available();
    v_ok := false; v_msg := 'the assertion passed with an organisation that has nowhere to validate';$n$;
  v_r1   text := $r$  delete from erp.environment where id = v_sandbox;
  -- The rule binds live organisations, and an onboarded one is not live yet.
  update erp.environment set is_live = true where tenant_id = v_t and is_self;
  begin
    perform erp.assert_validation_environment_available();
    v_ok := false; v_msg := 'the assertion passed with a live organisation that has nowhere to validate';$r$;
  v_n2   text := $n$  return query select 'removing it fails the assertion', v_ok, v_msg;$n$;
  v_r2   text := $r$  update erp.environment set is_live = false where tenant_id = v_t and is_self;
  return query select 'removing it from a live organisation fails the assertion', v_ok, v_msg;$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp_test.validation_environment_suite()'::regprocedure);
  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1),
    (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_VALIDATION_RULE_UNRECOGNISED: a needle this migration expects once '
        'in erp_test.validation_environment_suite() was found % time(s).', v_hits;
    end if;
  end loop;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$suite$;

update erp_meta.diagnostic_check
   set blurb = 'Spec 3.12 refuses a proposal validated in production. Every live '
               'organisation needs somewhere else to have validated one, and all '
               'three provisioning routes — onboarding, provisioning and the demo — '
               'have to keep creating it.'
 where code = 'validation_environment';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. From provisioned to trading, once, for any demo
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.ensure_demo_configuration(p_tenant_id uuid, p_principal uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_year     integer := extract(year from current_date)::integer;
  v_uom      uuid;
  v_entity   uuid;
  v_ccy      char(3);
  v_site     uuid;
  v_ledgers  integer;
  v_did      jsonb := '[]'::jsonb;
  r          record;
begin
  -- The installers read the organisation from the session, and a function that
  -- installed into whatever organisation happened to be active while being
  -- handed a different one would be a way to configure somebody else's.
  if erp.current_tenant_id() is distinct from p_tenant_id then
    raise exception
      'CLOVEERP_DEMO_TENANT_MISMATCH: the session is in organisation % and this '
      'call names %', coalesce(erp.current_tenant_id()::text, 'nobody'), p_tenant_id
      using errcode = '42501',
      hint = 'Adopt the organisation first: erp.set_active_tenant() for a person, '
             'erp.set_job_tenant() for a worker.';
  end if;

  -- §22.3: demonstration configuration is refused in a live environment by the
  -- platform. The axis is is_live, not a kind of organisation: an organisation
  -- that is live is a customer whatever it is called.
  if erp.environment_is_live() then
    raise exception
      'CLOVEERP_DEMO_IN_LIVE: this organisation is live; demonstration '
      'configuration is not installed over a live one'
      using errcode = '42501',
      hint = 'Seed a demo organisation from the home screen instead.';
  end if;

  -- Somewhere that is not production and is not this database, so a proposal
  -- the organisation raises has somewhere to be validated.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self, description, status)
  values (p_tenant_id, 'sandbox', 'Sandbox', 'sandbox', false, false,
          'Where a change is tried before it is applied.', 'active')
  on conflict (tenant_id, code) do nothing;
  if found then v_did := v_did || '"sandbox"'::jsonb; end if;

  -- Finance first, because every other installer names a ledger. It picks its
  -- entity by code, so the trading company must sort first: the demo's UK
  -- company was coded ACME-UK and its Dutch one ACME-EU, which put the ledger,
  -- and every document after it, in Rotterdam in euros. Renamed once, before
  -- there is a ledger to have chosen wrongly; a demo that already has a ledger
  -- keeps whatever it has.
  select count(*) into v_ledgers from erp.ledger l where l.tenant_id = p_tenant_id;
  if v_ledgers = 0 then
    if exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME-UK')
       and not exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME') then
      update erp.entity set code = 'ACME' where tenant_id = p_tenant_id and code = 'ACME-UK';
      v_did := v_did || '"entity ACME-UK renamed ACME"'::jsonb;
    end if;
    perform erp.configure_finance(v_year, null);
    v_did := v_did || '"finance"'::jsonb;
  end if;

  -- Each installer creates a change set with a fixed code and refuses to create
  -- it twice, so the change set is the record of whether it has run.
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'master-data-governance') then
    perform erp.configure_master_data();
    v_did := v_did || '"master_data"'::jsonb;
  end if;
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'procurement-lifecycle') then
    perform erp.configure_procurement(1000000, 'administrator');
    v_did := v_did || '"procurement"'::jsonb;
  end if;
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'sales-lifecycle') then
    perform erp.configure_sales(15, 'administrator');
    v_did := v_did || '"sales"'::jsonb;
  end if;
  -- Inventory restates the delivery rule at cost. Without it cost of sales is
  -- posted at the selling price, and the inventory account and the valuation
  -- part company on the first despatch.
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'inventory-operations') then
    perform erp.configure_inventory('average', 'administrator', 2, 1.5);
    v_did := v_did || '"inventory"'::jsonb;
  end if;
  -- Receivables is where cash application's posting rule lives.
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'receivables') then
    perform erp.configure_receivables(7, 45, 90);
    v_did := v_did || '"receivables"'::jsonb;
  end if;

  -- Four years of periods: two back for the history, this one, and the next so
  -- a document dated next week has somewhere to post. configure_finance()
  -- creates one year and cannot be asked again, so these are inserted directly,
  -- into the same table it writes.
  insert into erp.fiscal_period (tenant_id, ledger_id, code, fiscal_year, period_number,
                                 starts_on, ends_on, status)
  select p_tenant_id, l.id, format('%s-%s', y, lpad(m::text, 2, '0')), y, m::smallint,
         make_date(y, m, 1), (make_date(y, m, 1) + interval '1 month - 1 day')::date, 'open'
    from erp.ledger l, generate_series(v_year - 2, v_year + 1) y, generate_series(1, 12) m
   where l.tenant_id = p_tenant_id and l.status = 'active'
  on conflict (tenant_id, ledger_id, fiscal_year, period_number) do nothing;

  -- A posting rule is in force from the day it was promoted, which is today.
  -- The bridge refuses a document before that day, rightly. The history is
  -- dated two years back, so the rules are in force from two years back.
  update erp.posting_rule
     set effective_from = least(effective_from, make_date(v_year - 2, 1, 1))
   where tenant_id = p_tenant_id and status = 'active'
     and effective_from > make_date(v_year - 2, 1, 1);

  -- Numbering follows current_date, not the document date, so a document from
  -- last year would be GRN-2026-000001. Without the year in it the number is
  -- just a number, which is all a demonstration needs it to be.
  update erp.numbering_rule
     set reset_period = 'never'
   where tenant_id = p_tenant_id and reset_period <> 'never';

  -- ── Master data ────────────────────────────────────────────────────────────

  v_uom := erp.ensure_base_uom(p_tenant_id, p_principal);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = p_tenant_id and l.is_primary
   order by l.code limit 1;

  select s.id into v_site from erp.site s
   where s.tenant_id = p_tenant_id and s.entity_id = v_entity
     and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
     and s.status = 'active'::erp.record_status
   order by s.code limit 1;
  if v_site is null then
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status, created_by)
    values (p_tenant_id, v_entity, 'MAIN-WH', 'Main warehouse', 'warehouse'::erp.site_type,
            (select e.country_code from erp.entity e where e.id = v_entity), 'active'::erp.record_status, p_principal)
    returning id into v_site;
    v_did := v_did || '"site MAIN-WH"'::jsonb;
  end if;

  -- A receiving location is what makes an inbound movement possible and a
  -- despatch one an outbound. Everything is held in BULK.
  insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status, created_by)
  select p_tenant_id, v_site, x.code, x.name, x.kind::erp.location_type, x.pick, 'active'::erp.record_status, p_principal
    from (values ('RECV', 'Goods in',  'receiving', false),
                 ('BULK', 'Bulk store', 'bulk',      true),
                 ('DESP', 'Despatch',  'despatch',  false)) x(code, name, kind, pick)
  on conflict (tenant_id, site_id, code) do nothing;

  insert into erp.party (tenant_id, code, name, legal_name, country_code, status, created_by)
  select p_tenant_id, x.code, x.name, x.legal, x.cc, 'active'::erp.record_status, p_principal
    from (values
      ('C-NORTH',    'Northgate Retail',        'Northgate Retail Ltd',            'GB'),
      ('C-HARBOUR',  'Harbour Engineering',     'Harbour Engineering BV',          'NL'),
      ('C-VELA',     'Vela Industrial',         'Vela Industrial SA',              'FR'),
      ('C-BRIDGE',   'Bridgewater Automotive',  'Bridgewater Automotive plc',      'GB'),
      ('C-KESTREL',  'Kestrel Rail',            'Kestrel Rail Systems Ltd',        'GB'),
      ('C-ORION',    'Orion Marine',            'Orion Marine AS',                 'NO'),
      ('C-ASHCOMBE', 'Ashcombe Farm Machinery', 'Ashcombe Farm Machinery Ltd',     'GB'),
      ('C-MERIDIAN', 'Meridian Pumps',          'Meridian Pumps Ltd',              'IE'),
      ('C-TALLOW',   'Tallow & Sons',           'Tallow & Sons Ltd',               'GB'),
      ('C-LUMEN',    'Lumen Lighting',          'Lumen Lighting GmbH',             'DE'),
      ('C-CALDER',   'Calder Construction',     'Calder Construction Ltd',         'GB'),
      ('C-SILVER',   'Silverline Kitchens',     'Silverline Kitchens Ltd',         'GB'),
      ('S-STEEL',    'Midland Steel',           'Midland Steel Ltd',               'GB'),
      ('S-BEAR',     'Rheinbearing',            'Rheinbearing GmbH',               'DE'),
      ('S-PACK',     'Packwell',                'Packwell Ltd',                    'GB'),
      ('S-FAST',     'Anchor Fasteners',        'Anchor Fasteners Ltd',            'GB'),
      ('S-ELEC',     'Voltaic Components',      'Voltaic Components BV',           'NL'),
      ('S-POLY',     'Polymark Plastics',       'Polymark Plastics Ltd',           'GB'),
      ('S-TOOL',     'Hartmann Tooling',        'Hartmann Werkzeug GmbH',          'DE'),
      ('S-CHEM',     'Clearwater Chemicals',    'Clearwater Chemicals Ltd',        'IE')
    ) x(code, name, legal, cc)
  on conflict (tenant_id, code) do nothing;

  insert into erp.party_role (tenant_id, party_id, role_kind, status, created_by)
  select p_tenant_id, p.id,
         case when p.code like 'C-%' then 'customer'::erp.party_role_kind
              else 'supplier'::erp.party_role_kind end,
         'active'::erp.record_status, p_principal
    from erp.party p
   where p.tenant_id = p_tenant_id and (p.code like 'C-%' or p.code like 'S-%')
  on conflict (tenant_id, party_id, role_kind) do nothing;

  -- Thirty things to buy and sell. The demo attributes are what the builder
  -- reads: what each costs, what it lists at, who supplies it and how much of
  -- it moves in a week. One cost per item, deliberately — see the header. An
  -- item the older seed created without these gains them; one that has them
  -- keeps its own.
  insert into erp.item (tenant_id, code, name, item_class, item_group, stock_uom_id,
                        lifecycle, status, attributes, created_by)
  select p_tenant_id, x.code, x.name, x.class, x.grp, v_uom,
         'active'::erp.item_lifecycle, 'active'::erp.record_status,
         jsonb_build_object('demo', jsonb_build_object(
           'cost_minor', x.cost, 'list_minor', x.list, 'supplier', x.supplier,
           'demand_per_week', x.demand)),
         p_principal
    from (values
      ('FG-1000', 'Acme widget, 100mm',          'finished_good', 'widgets',    'S-TOOL',  3200,  4950, 60),
      ('FG-1001', 'Acme widget, 150mm',          'finished_good', 'widgets',    'S-TOOL',  4100,  6250, 45),
      ('FG-1002', 'Acme widget, 200mm',          'finished_good', 'widgets',    'S-TOOL',  5300,  7900, 30),
      ('FG-2000', 'Acme gearbox assembly',       'finished_good', 'drives',     'S-BEAR', 18500, 27900, 12),
      ('FG-2001', 'Acme gearbox, heavy duty',    'finished_good', 'drives',     'S-BEAR', 26400, 39500,  6),
      ('FG-2100', 'Drive coupling, 40mm',        'finished_good', 'drives',     'S-BEAR',  2900,  4450, 40),
      ('FG-3000', 'Control panel, 12-way',       'finished_good', 'controls',   'S-ELEC', 12800, 19900, 10),
      ('FG-3001', 'Control panel, 24-way',       'finished_good', 'controls',   'S-ELEC', 19600, 29900,  6),
      ('FG-3100', 'Sensor kit, inductive',       'finished_good', 'controls',   'S-ELEC',  4600,  6990, 25),
      ('FG-4000', 'Pump housing, cast',          'finished_good', 'pumps',      'S-STEEL', 8900, 13500, 15),
      ('FG-4001', 'Impeller, bronze',            'finished_good', 'pumps',      'S-STEEL', 5400,  8250, 20),
      ('FG-4002', 'Seal kit, pump',              'finished_good', 'pumps',      'S-POLY',  1450,  2350, 55),
      ('RM-100',  'Steel bar, 20mm',             'raw_material',  'metals',     'S-STEEL', 1275,  1950, 120),
      ('RM-101',  'Steel bar, 30mm',             'raw_material',  'metals',     'S-STEEL', 1980,  2990, 80),
      ('RM-110',  'Steel plate, 6mm',            'raw_material',  'metals',     'S-STEEL', 4200,  6300, 40),
      ('RM-120',  'Aluminium extrusion, 2m',     'raw_material',  'metals',     'S-STEEL', 2650,  3990, 50),
      ('RM-200',  'Bearing, 30mm bore',          'raw_material',  'components', 'S-BEAR',   850,  1350, 150),
      ('RM-201',  'Bearing, 50mm bore',          'raw_material',  'components', 'S-BEAR',  1450,  2250, 90),
      ('RM-210',  'Shaft seal, 30mm',            'raw_material',  'components', 'S-POLY',   240,   420, 200),
      ('RM-300',  'Hex bolt M10, box of 100',    'raw_material',  'fasteners',  'S-FAST',  1100,  1750, 70),
      ('RM-301',  'Hex bolt M12, box of 100',    'raw_material',  'fasteners',  'S-FAST',  1500,  2350, 55),
      ('RM-310',  'Washer M10, box of 500',      'raw_material',  'fasteners',  'S-FAST',   900,  1450, 40),
      ('RM-400',  'Cable, 2.5mm, 100m drum',     'raw_material',  'electrical', 'S-ELEC',  3900,  5900, 35),
      ('RM-401',  'Terminal block, 12-way',      'raw_material',  'electrical', 'S-ELEC',   320,   550, 120),
      ('RM-500',  'Polymer granulate, 25kg',     'raw_material',  'polymers',   'S-POLY',  3100,  4700, 30),
      ('RM-600',  'Cutting fluid, 20L',          'consumable',    'chemicals',  'S-CHEM',  2400,  3650, 25),
      ('RM-601',  'Degreaser, 5L',               'consumable',    'chemicals',  'S-CHEM',  1150,  1790, 45),
      ('PK-010',  'Carton, 400x300x200',         'packaging',     'packaging',  'S-PACK',    85,   140, 400),
      ('PK-011',  'Carton, 600x400x400',         'packaging',     'packaging',  'S-PACK',   140,   230, 250),
      ('PK-020',  'Pallet wrap, 300m',           'packaging',     'packaging',  'S-PACK',   650,   990, 60)
    ) x(code, name, class, grp, supplier, cost, list, demand)
  on conflict (tenant_id, code) do update
    set attributes = coalesce(erp.item.attributes, '{}'::jsonb) || excluded.attributes
    where erp.item.attributes -> 'demo' is null;

  return jsonb_build_object(
    'tenant_id', p_tenant_id,
    'entity_id', v_entity,
    'currency', v_ccy,
    'site_id', v_site,
    'installed', v_did,
    'ledgers', (select count(*) from erp.ledger l where l.tenant_id = p_tenant_id),
    'document_types', (select count(*) from erp.document_type t where t.tenant_id = p_tenant_id),
    'fiscal_periods', (select count(*) from erp.fiscal_period f where f.tenant_id = p_tenant_id),
    'items', (select count(*) from erp.item i where i.tenant_id = p_tenant_id),
    'parties', (select count(*) from erp.party p where p.tenant_id = p_tenant_id));
end;
$$;

comment on function erp.ensure_demo_configuration(uuid, uuid) is
  'Takes a demonstration organisation from provisioned to able to trade, once: '
  'sandbox, the six installers, four years of periods, posting rules in force '
  'from two years back, numbering without the year, and master data to trade '
  'with. Idempotent; refused in a live environment.';

revoke all on function erp.ensure_demo_configuration(uuid, uuid) from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. erp.seed_demo() creates the sandbox, and codes the trading company first
-- ═════════════════════════════════════════════════════════════════════════════

do $demo$
declare
  v_def  text;
  v_n1   text := $n$values (v_tenant_id, 'ACME-UK', 'Acme United Kingdom'$n$;
  v_r1   text := $r$values (v_tenant_id, 'ACME', 'Acme United Kingdom'$r$;
  v_n2   text := $n$          'This database.', 'active')
  returning id into v_env_id;$n$;
  v_r2   text := $r$          'This database.', 'active')
  returning id into v_env_id;

  -- Somewhere that is not production and is not this database, which every
  -- organisation needs before a proposal it raises can be applied.
  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
                               description, status)
  values (v_tenant_id, 'sandbox', 'Sandbox', 'sandbox', false, false,
          'Where a change is tried before it is applied.', 'active');$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.seed_demo()'::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SEED_DEMO_UNRECOGNISED: expected the UK entity once in erp.seed_demo(), '
      'found %.', v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SEED_DEMO_UNRECOGNISED: expected the production environment insert '
      'once in erp.seed_demo(), found %.', v_hits;
  end if;
  if position('''sandbox''' in v_def) > 0 then
    raise exception 'CLOVEERP_SEED_DEMO_UNRECOGNISED: erp.seed_demo() already creates a sandbox';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);
end
$demo$;

-- The public door adopts the organisation and then configures it. Inside
-- erp.seed_demo() the new organisation is not yet the session's, and the
-- installers read the organisation from the session, so the order here is the
-- whole point. Configuration runs before the older master-data seed so the
-- items it would create already carry what the builder reads.
create or replace function public.erp_seed_demo()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_base jsonb;
  v_tenant uuid;
  v_principal uuid;
begin
  v_base := erp.seed_demo();
  v_tenant := (v_base ->> 'tenant_id')::uuid;
  v_principal := (v_base ->> 'principal_id')::uuid;

  -- Adopting it first means everything below sees the right organisation.
  perform erp.set_active_tenant(v_tenant);

  return v_base || jsonb_build_object(
    'configured', erp.ensure_demo_configuration(v_tenant, v_principal),
    'seeded', erp.seed_demo_master_data(v_tenant, v_principal));
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. A year of trading, five days per call
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.seed_demo_history(
  p_from date default null, p_to date default null, p_scale numeric default 1)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_actor    uuid := erp.current_principal_id();
  v_scale    numeric := coalesce(p_scale, 1);
  v_from     date;
  v_to       date;
  v_end      date;
  v_floor    date;
  v_season   numeric;
  v_recent   boolean;
  v_entity   uuid;
  v_ccy      char(3);
  v_site     uuid;
  v_bulk     uuid;
  v_seq      integer := 0;
  v_built    integer := 0;
  v_notes    jsonb := '[]'::jsonb;
  v_prefix   text;
  v_span     integer;
  -- documents
  v_doc      uuid;
  v_line     uuid;
  v_grn      uuid;
  v_dn       uuid;
  v_inv      uuid;
  v_party    uuid;
  v_date     date;
  v_date2    date;
  v_qty      numeric;
  v_total    numeric;
  v_value    bigint;
  v_paid     bigint;
  v_roll     numeric;
  v_n        integer;
  v_i        integer;
  v_lines    integer;
  v_onhand   numeric;
  v_state    text;
  r          record;
  ln         record;

begin
  -- §22.3: demonstration history is refused in a live environment by the
  -- platform. The axis is is_live and nothing else.
  if erp.environment_is_live() then
    raise exception
      'CLOVEERP_DEMO_IN_LIVE: this organisation is live; demonstration history is '
      'not written into a live ledger'
      using errcode = '42501',
      hint = 'Seed a demo organisation from the home screen instead.';
  end if;

  perform erp.authorise('master_data.write', null, null, null, 'tenant', v_tenant);

  if v_scale <= 0 or v_scale > 4 then
    raise exception
      'CLOVEERP_DEMO_SCALE_OUT_OF_RANGE: % is not a scale between 0 and 4', v_scale
      using errcode = '22003',
      hint = '1 is a year of a few thousand documents; 2 is twice that. Above 4 '
             'the platform assurance budget is spent on a demonstration.';
  end if;

  v_from := coalesce(p_from, (date_trunc('month', current_date) - interval '12 months')::date);
  v_to   := least(coalesce(p_to, current_date), current_date);
  v_floor := make_date(extract(year from current_date)::integer - 2, 1, 1);

  if v_from < v_floor then
    raise exception
      'CLOVEERP_DEMO_BEFORE_THE_BOOKS: % is before %, the first day the '
      'demonstration has periods and posting rules for', v_from, v_floor
      using errcode = '22008',
      hint = 'Start on or after the first of January two years ago.';
  end if;

  if v_from > v_to then
    return jsonb_build_object('done', true, 'from', v_from, 'to', v_to,
                              'built_through', v_to, 'next_from', null,
                              'built', 0, 'notes', jsonb_build_array('Nothing to build: the range is empty.'));
  end if;

  -- Whatever the organisation is missing, once.
  perform erp.ensure_demo_configuration(v_tenant, v_actor);

  -- Five days per call. Measured locally a peak-season week is 37 documents in
  -- under two seconds with nothing else running, and six with the check
  -- catalogue running beside it; a signed-in user has eight. Five days keeps
  -- the worst call under half of that.
  v_end := least(v_from + 4, v_to);
  v_span := v_end - v_from + 1;
  v_prefix := 'DEMO-' || to_char(v_from, 'YYYYMMDD') || '-';

  -- Idempotent by reference: a slice that has any of its documents has all of
  -- them, because a call is one transaction.
  if exists (select 1 from erp.document d
              where d.tenant_id = v_tenant and d.their_reference like v_prefix || '%') then
    return jsonb_build_object('done', v_end >= v_to, 'from', v_from, 'to', v_to,
                              'built_through', v_end,
                              'next_from', case when v_end >= v_to then null else v_end + 1 end,
                              'built', 0,
                              'notes', jsonb_build_array(format('The days from %s were already built; nothing was duplicated.',
                                                                to_char(v_from, 'DD Mon YYYY'))));
  end if;

  -- Deterministic for the slice: the same days asked twice give the same
  -- answer, which is what makes a refused or timed-out call safe to repeat.
  perform setseed((abs(hashtext(v_from::text)) % 100000) / 100000.0);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s
   where s.tenant_id = v_tenant and s.entity_id = v_entity
     and s.site_type in ('warehouse'::erp.site_type, 'distribution'::erp.site_type)
     and s.status = 'active'::erp.record_status
   order by s.code limit 1;
  select loc.id into v_bulk from erp.location loc
   where loc.tenant_id = v_tenant and loc.site_id = v_site and loc.code = 'BULK';

  -- Q4 peaks, August dips. Scaled by the caller's appetite.
  v_season := (array[0.85, 0.90, 1.00, 0.95, 1.00, 1.05, 0.95, 0.75, 1.05, 1.15, 1.25, 1.10])
                [extract(month from v_from)::integer] * v_scale;
  -- Documents still in flight belong to the last few weeks. A sales order
  -- awaiting approval since last spring is not history, it is neglect.
  v_recent := v_end >= current_date - 21;

  -- ── Replenishment: buy what is below its reorder point ─────────────────────
  -- One purchase order per supplier for every item of theirs that is short,
  -- received a few days later into BULK. On the first call everything is short,
  -- which is how the shelves get stock before anything is sold.
  for r in
    select p.id as supplier_id, p.code as supplier_code
      from erp.party p
     where p.tenant_id = v_tenant and p.code like 'S-%'
       and exists (
         select 1 from erp.item i
          where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
            and i.attributes -> 'demo' ->> 'supplier' = p.code
            and coalesce((select sum(b.quantity) from erp.stock_balance b
                           where b.tenant_id = v_tenant and b.site_id = v_site
                             and b.item_id = i.id and b.stock_status = 'available'), 0)
                < (i.attributes -> 'demo' ->> 'demand_per_week')::numeric * 2 * v_scale)
     order by p.code
  loop
    v_date := least(v_from + floor(random()::numeric * least(v_span, 3))::integer, v_end);
    v_seq := v_seq + 1;
    v_doc := erp.create_document('purchase_order', v_entity, v_site, r.supplier_id, v_date, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    v_lines := 0;
    for ln in
      select i.id, i.name,
             (i.attributes -> 'demo' ->> 'cost_minor')::bigint as cost,
             (i.attributes -> 'demo' ->> 'demand_per_week')::numeric as demand
        from erp.item i
       where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
         and i.attributes -> 'demo' ->> 'supplier' = r.supplier_code
         and coalesce((select sum(b.quantity) from erp.stock_balance b
                        where b.tenant_id = v_tenant and b.site_id = v_site
                          and b.item_id = i.id and b.stock_status = 'available'), 0)
             < (i.attributes -> 'demo' ->> 'demand_per_week')::numeric * 2 * v_scale
       order by i.code
    loop
      v_qty := ceil(ln.demand * 6 * v_scale / 10) * 10;
      perform erp.add_document_line(v_doc, ln.id, v_qty, ln.cost, ln.name, v_date + 5);
      v_lines := v_lines + 1;
    end loop;
    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    perform erp.transition_document(v_doc, 'send', 'demonstration');
    v_built := v_built + 1;

    -- A recent order may still be on its way. Everything older arrived.
    if v_recent and v_date > v_to - 7 and random()::numeric < 0.4 then
      continue;
    end if;

    v_date2 := least(v_date + 2 + floor(random()::numeric * 4)::integer, v_to);
    v_seq := v_seq + 1;
    v_grn := erp.create_document('goods_receipt', v_entity, v_site, r.supplier_id, v_date2, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    for ln in
      select dl.id, dl.quantity from erp.document_line dl
       where dl.tenant_id = v_tenant and dl.document_id = v_doc order by dl.line_no
    loop
      v_line := erp.receive_against(v_grn, ln.id, ln.quantity);
      update erp.document_line set location_id = v_bulk where id = v_line;
    end loop;
    perform erp.transition_document(v_grn, 'post', 'demonstration');
    perform erp.transition_document(v_doc, 'receive_all', 'demonstration');
    if random()::numeric < 0.75 then
      perform erp.transition_document(v_doc, 'close', 'demonstration');
    end if;
    v_built := v_built + 1;
  end loop;

  -- ── Sales: orders, despatches, invoices, cash ──────────────────────────────
  v_n := greatest(1, round(7.5 * v_season * v_span / 7.0)::integer);
  for v_i in 1 .. v_n loop
    v_date := v_from + floor(random()::numeric * v_span)::integer;
    select p.id into v_party from erp.party p
     where p.tenant_id = v_tenant and p.code like 'C-%' and p.status = 'active'::erp.record_status
     order by random() limit 1;
    v_seq := v_seq + 1;
    v_doc := erp.create_document('sales_order', v_entity, v_site, v_party, v_date, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    v_lines := 1 + floor(random()::numeric * 3)::integer;
    for ln in
      select i.id, i.name,
             (i.attributes -> 'demo' ->> 'list_minor')::bigint as list,
             (i.attributes -> 'demo' ->> 'demand_per_week')::numeric as demand
        from erp.item i
       where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
         and i.attributes ? 'demo'
       order by random() limit v_lines
    loop
      v_qty := greatest(1, round(ln.demand * (0.3 + random()::numeric * 0.9)));
      -- A discount now and then, inside the threshold the sales installer set.
      v_roll := random()::numeric;
      v_value := case when v_roll < 0.15 then round(ln.list * 0.90)
                      when v_roll < 0.35 then round(ln.list * 0.95)
                      else ln.list end;
      perform erp.add_document_line(v_doc, ln.id, v_qty, v_value, ln.name,
                                    v_date + 3 + floor(random()::numeric * 7)::integer);
    end loop;
    v_built := v_built + 1;

    v_roll := random()::numeric;
    if v_roll < 0.03 then
      perform erp.transition_document(v_doc, 'cancel', 'Customer withdrew the order');
      continue;
    end if;
    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    if v_recent and v_date > v_to - 10 and v_roll < 0.10 then
      continue;                                   -- awaiting approval
    end if;
    perform erp.transition_document(v_doc, 'approve', 'demonstration');
    if v_recent and v_date > v_to - 10 and v_roll < 0.22 then
      continue;                                   -- confirmed, not yet despatched
    end if;

    -- Despatch what is on the shelf. A line with nothing to ship stays open on
    -- the order, which is what a back order is.
    v_date2 := least(v_date + 1 + floor(random()::numeric * 4)::integer, v_to);
    v_dn := null; v_total := 0;
    for ln in
      select dl.id, dl.item_id, dl.quantity, dl.unit_price_minor, dl.description
        from erp.document_line dl
       where dl.tenant_id = v_tenant and dl.document_id = v_doc order by dl.line_no
    loop
      select coalesce(sum(b.quantity), 0) into v_onhand from erp.stock_balance b
       where b.tenant_id = v_tenant and b.site_id = v_site and b.location_id = v_bulk
         and b.item_id = ln.item_id and b.stock_status = 'available';
      v_qty := least(ln.quantity, v_onhand);
      if v_qty <= 0 then continue; end if;
      if v_dn is null then
        v_seq := v_seq + 1;
        v_dn := erp.create_document('delivery', v_entity, v_site, v_party, v_date2, v_ccy,
                                    v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
      end if;
      v_line := erp.add_document_line(v_dn, ln.item_id, v_qty, ln.unit_price_minor, ln.description, v_date2);
      update erp.document_line set location_id = v_bulk where id = v_line;
      v_total := v_total + v_qty;
    end loop;
    if v_dn is null then
      v_notes := v_notes || to_jsonb(format('%s is on back order: nothing it asks for is in stock yet.',
                                            (select d.document_number from erp.document d where d.id = v_doc)));
      continue;
    end if;
    perform erp.link_documents(v_doc, v_dn, 'fulfils', v_total);
    perform erp.transition_document(v_dn, 'post', 'demonstration');
    perform erp.transition_document(v_doc, 'pick', 'demonstration');
    perform erp.transition_document(v_doc, 'despatch', 'demonstration');
    v_built := v_built + 1;

    -- The invoice is derived from what moved, and opened today; it is then
    -- dated the day of the despatch, as it would have been.
    v_inv := erp.invoice_from_delivery(v_dn, true);
    v_seq := v_seq + 1;
    update erp.document
       set document_date = v_date2, due_date = v_date2 + 30,
           their_reference = v_prefix || lpad(v_seq::text, 3, '0')
     where id = v_inv;
    perform erp.transition_document(v_inv, 'issue', 'demonstration');
    perform erp.transition_document(v_doc, 'invoice', 'demonstration');
    v_built := v_built + 1;
    v_value := erp.document_value_minor(v_inv);

    -- Most invoices are paid, some in part, some not at all: a demonstration in
    -- which everything is settled shows no ageing, no dunning and no
    -- collections work. Cash lands on the day it arrived and goes to the
    -- oldest open item first, so it may settle an older invoice of the same
    -- customer rather than this one; whichever is settled is marked paid.
    v_date := v_date2 + 5 + floor(random()::numeric * 40)::integer;
    v_roll := random()::numeric;
    if v_date <= current_date and v_roll < 0.80 then
      v_paid := case when v_roll < 0.65 then v_value
                     else greatest(1, round(v_value * (0.4 + random()::numeric * 0.3))::bigint) end;
      perform erp.apply_cash(v_party, v_paid, v_ccy, 'Remittance ' || to_char(v_date, 'DDMMYY'), v_date);
      for r in
        select si.document_id from erp.subledger_item si
         where si.tenant_id = v_tenant and si.party_id = v_party
           and si.control_kind = 'receivable' and si.document_id is not null
           and si.debit_minor - si.credit_minor > 0
           and coalesce(si.settled_minor, 0) >= si.debit_minor - si.credit_minor
           and erp.object_current_state('document', si.document_id) = 'issued'
      loop
        perform erp.transition_document(r.document_id, 'settle', 'demonstration');
        -- And most orders whose invoice is paid are closed: the order that the
        -- settled invoice's delivery fulfilled, found through the relations
        -- rather than assumed to be this one.
        if random()::numeric < 0.7 then
          for ln in
            select so.from_document_id as so_id
              from erp.document_relation inv
              join erp.document_relation so
                on so.tenant_id = inv.tenant_id and so.to_document_id = inv.to_document_id
               and so.relation_kind = 'fulfils'
             where inv.tenant_id = v_tenant and inv.from_document_id = r.document_id
               and inv.relation_kind = 'invoices'
          loop
            if erp.object_current_state('document', ln.so_id) = 'invoiced' then
              perform erp.transition_document(ln.so_id, 'close', 'demonstration');
            end if;
          end loop;
        end if;
      end loop;
    end if;
  end loop;

  -- ── Quotations ────────────────────────────────────────────────────────────
  v_n := greatest(1, round(2 * v_season * v_span / 7.0)::integer);
  for v_i in 1 .. v_n loop
    v_date := v_from + floor(random()::numeric * v_span)::integer;
    select p.id into v_party from erp.party p
     where p.tenant_id = v_tenant and p.code like 'C-%' and p.status = 'active'::erp.record_status
     order by random() limit 1;
    v_seq := v_seq + 1;
    v_doc := erp.create_document('quotation', v_entity, v_site, v_party, v_date, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    for ln in
      select i.id, i.name, (i.attributes -> 'demo' ->> 'list_minor')::bigint as list,
             (i.attributes -> 'demo' ->> 'demand_per_week')::numeric as demand
        from erp.item i
       where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status and i.attributes ? 'demo'
       order by random() limit 1 + floor(random()::numeric * 2)::integer
    loop
      perform erp.add_document_line(v_doc, ln.id, greatest(1, round(ln.demand * (0.5 + random()::numeric))), ln.list, ln.name,
                                    v_date + 14);
    end loop;
    perform erp.transition_document(v_doc, 'send', 'demonstration');
    v_roll := random()::numeric;
    if v_roll < 0.45 and v_date < current_date - 7 then
      perform erp.transition_document(v_doc, 'accept', 'demonstration');
    elsif v_roll < 0.70 and v_date < current_date - 7 then
      perform erp.transition_document(v_doc, 'decline', 'Went with another supplier');
    elsif v_roll < 0.85 and v_date < current_date - 30 then
      perform erp.transition_document(v_doc, 'expire', 'demonstration');
    end if;
    v_built := v_built + 1;
  end loop;

  -- ── Requisitions ──────────────────────────────────────────────────────────
  v_n := greatest(1, round(1 * v_scale * v_span / 7.0)::integer);
  for v_i in 1 .. v_n loop
    v_date := v_from + floor(random()::numeric * v_span)::integer;
    v_seq := v_seq + 1;
    v_doc := erp.create_document('requisition', v_entity, v_site, null, v_date, v_ccy,
                                 v_prefix || lpad(v_seq::text, 3, '0'), '{}'::jsonb);
    for ln in
      select i.id, i.name, (i.attributes -> 'demo' ->> 'cost_minor')::bigint as cost,
             (i.attributes -> 'demo' ->> 'demand_per_week')::numeric as demand
        from erp.item i
       where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status and i.attributes ? 'demo'
       order by random() limit 1 + floor(random()::numeric * 2)::integer
    loop
      perform erp.add_document_line(v_doc, ln.id, greatest(1, round(ln.demand * (0.5 + random()::numeric))), ln.cost, ln.name,
                                    v_date + 10);
    end loop;
    perform erp.transition_document(v_doc, 'submit', 'demonstration');
    v_roll := random()::numeric;
    if v_recent and v_date > v_to - 10 and v_roll < 0.3 then
      null;                                       -- submitted, awaiting approval
    elsif v_roll < 0.1 then
      perform erp.transition_document(v_doc, 'reject', 'Not in this quarter''s budget');
    else
      perform erp.transition_document(v_doc, 'approve', 'demonstration');
      perform erp.transition_document(v_doc, 'order', 'demonstration');
    end if;
    v_built := v_built + 1;
  end loop;

  return jsonb_build_object(
    'done', v_end >= v_to,
    'from', v_from,
    'to', v_to,
    'built_through', v_end,
    'next_from', case when v_end >= v_to then null else v_end + 1 end,
    'built', v_built,
    'notes', v_notes);
end;
$$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds a few days of demonstration trading through the spine — purchase orders '
  'and receipts, sales orders, despatches, invoices and cash, quotations and '
  'requisitions — and says where the next call should start. Idempotent by '
  'slice; refused in a live environment; every journal and movement is raised by '
  'the same bridges a person''s document goes through.';

revoke all on function erp.seed_demo_history(date, date, numeric) from public, anon;

-- The door. Same shape as erp_seed_demo_operations(): definer so the tables
-- the bridges write are reachable, the permission still checked against the
-- caller inside.
create or replace function public.erp_seed_demo_history(
  p_from date default null, p_to date default null, p_scale numeric default 1)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select erp.seed_demo_history(p_from, p_to, p_scale); $$;

revoke all on function public.erp_seed_demo_history(date, date, numeric) from public, anon;
grant execute on function public.erp_seed_demo_history(date, date, numeric) to authenticated, service_role;

comment on function public.erp_seed_demo_history(date, date, numeric) is
  'Builds a few days of demonstration trading history and returns {done, next_from, '
  'built, notes}. Call again with next_from until done. Refused in a live '
  'environment.';

-- Argued for, in the two registers erp.assert_public_api_safe() reads.
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('public', 'erp_seed_demo_history',
        'Demonstration history builder; gated by erp.authorise(master_data.write) '
        'inside, refused in a live environment, and confined to the calling '
        'organisation by erp.require_tenant_id(). Definer for the same reason as '
        'erp_seed_demo_operations: the bridges it drives write tables the caller '
        'cannot reach directly.')
on conflict do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values ('erp_seed_demo_history', 'erp.seed_demo_history',
        'Writes a few days of demonstration documents through the spine. Every write '
        'is one a person could make from a screen, made by the same functions, '
        'and none of it is possible in a live environment.')
on conflict do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.demo_history_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  d        record;
  a1       uuid := gen_random_uuid();
  v_tenant uuid;
  v_conf   jsonb;
  v_res    jsonb;
  v_res2   jsonb;
  v_ok     boolean;
  v_msg    text;
  v_n      integer;
  v_m      integer;
  v_cases  integer := 0;
  -- Fourteen months back, so every receipt the slice's cash could be dated on
  -- is in the past and nothing it builds waits on today.
  v_slice  date := (date_trunc('month', current_date) - interval '14 months')::date;
  v_entity uuid; v_site uuid; v_ccy char(3); v_supp uuid; v_item uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_gl uuid;
  v_old_at timestamptz; v_old_on date; v_new_at timestamptz;
begin
  select * into d from erp.provision_tenant('zzdemo', 'Demo History Suite', 'a@zzdemo.test', 'Suite Admin');
  v_tenant := d.tenant_id;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(d.admin_token);

  -- ── 1. Live is refused ─────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    perform erp.ensure_demo_configuration(v_tenant, d.admin_user_id);
    v_ok := false; v_msg := 'configured a live organisation';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DEMO_IN_LIVE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a live organisation is refused demonstration configuration'::text, v_ok, v_msg;

  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;

  -- ── 2. Provisioned to trading ──────────────────────────────────────────────
  v_cases := v_cases + 1;
  v_conf := erp.ensure_demo_configuration(v_tenant, d.admin_user_id);
  return query select 'ensure_demo_configuration takes a provisioned organisation to trading'::text,
    (select count(*) from erp.ledger l where l.tenant_id = v_tenant) = 2
    and (select count(*) from erp.document_type t where t.tenant_id = v_tenant and t.status = 'active') >= 7
    and (select count(*) from erp.fiscal_period f where f.tenant_id = v_tenant) >= 96
    and exists (select 1 from erp.environment e where e.tenant_id = v_tenant and e.code = 'sandbox' and not e.is_self)
    and not exists (select 1 from erp.posting_rule pr where pr.tenant_id = v_tenant and pr.status = 'active'
                       and pr.effective_from > make_date(extract(year from current_date)::integer - 2, 1, 1))
    and exists (select 1 from erp.posting_rule pr where pr.tenant_id = v_tenant and pr.code = 'delivery'
                   and pr.status = 'active' and pr.posting_lines::text like '%stock_cost%')
    and (select count(*) from erp.item i where i.tenant_id = v_tenant and i.attributes ? 'demo') >= 30
    and (select count(*) from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'customer') >= 12
    and (select count(*) from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier') >= 8
    and not exists (select 1 from erp.numbering_rule nr where nr.tenant_id = v_tenant and nr.reset_period <> 'never')
    and exists (select 1 from erp.location loc where loc.tenant_id = v_tenant and loc.code = 'BULK'),
    left(v_conf::text, 200);

  -- ── 3. And is idempotent ───────────────────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.change_set c where c.tenant_id = v_tenant;
  v_res := erp.ensure_demo_configuration(v_tenant, d.admin_user_id);
  select count(*) into v_m from erp.change_set c where c.tenant_id = v_tenant;
  return query select 'a second ensure_demo_configuration installs nothing'::text,
    v_n = v_m and jsonb_array_length(v_res -> 'installed') = 0
    and (v_res ->> 'items')::integer = (v_conf ->> 'items')::integer,
    format('%s change sets before, %s after; installed %s', v_n, v_m, v_res -> 'installed');

  -- ── 4. A slice builds through the spine ────────────────────────────────────
  v_cases := v_cases + 1;
  v_res := erp.seed_demo_history(v_slice, v_slice + 4, 1);
  select count(*) into v_n from erp.document x where x.tenant_id = v_tenant and x.their_reference like 'DEMO-%';
  return query select 'five days build a working set of documents, each in the state its flow ends in'::text,
    (v_res ->> 'done')::boolean and v_res ->> 'next_from' is null
    and (v_res ->> 'built')::integer >= 20 and v_n >= 20
    and not exists (
      select 1 from erp.document x
      join erp.document_type dt on dt.id = x.document_type_id
      where x.tenant_id = v_tenant and x.their_reference like 'DEMO-%'
        and (   (dt.code = 'goods_receipt' and erp.object_current_state('document', x.id) <> 'posted')
             or (dt.code = 'delivery'      and erp.object_current_state('document', x.id) <> 'posted')
             or (dt.code = 'sales_invoice' and erp.object_current_state('document', x.id) not in ('issued', 'paid'))
             or (dt.code = 'purchase_order' and erp.object_current_state('document', x.id) not in ('sent', 'received', 'closed'))
             or (dt.code = 'sales_order'   and erp.object_current_state('document', x.id)
                                               not in ('cancelled', 'pending_approval', 'confirmed', 'despatched', 'invoiced', 'closed'))
             or (dt.code = 'quotation'     and erp.object_current_state('document', x.id) not in ('sent', 'accepted', 'declined', 'expired'))
             or (dt.code = 'requisition'   and erp.object_current_state('document', x.id) not in ('submitted', 'draft', 'ordered'))))
    and exists (select 1 from erp.document x join erp.document_type dt on dt.id = x.document_type_id
                 where x.tenant_id = v_tenant and dt.code = 'sales_invoice'
                   and erp.object_current_state('document', x.id) = 'paid')
    and not exists (select 1 from erp.document x where x.tenant_id = v_tenant
                     and x.their_reference like 'DEMO-%' and x.document_date > v_slice + 4 + 60),
    format('%s documents, result %s', v_n, left(v_res::text, 160));

  -- ── 5. Every journal balances ──────────────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.journal j where j.tenant_id = v_tenant and j.status = 'posted';
  return query select 'every journal the slice raised balances and sits on the document''s date'::text,
    v_n >= 20
    and not exists (
      select 1 from erp.journal j
       where j.tenant_id = v_tenant and j.status = 'posted'
       group by j.id
      having sum((select sum(l.debit_minor - l.credit_minor) from erp.journal_line l where l.journal_id = j.id)) <> 0)
    and not exists (
      select 1 from erp.journal j join erp.document x on x.id = j.document_id
       where j.tenant_id = v_tenant and j.posting_date <> coalesce(x.posting_date, x.document_date))
    and not exists (select 1 from erp.journal j where j.tenant_id = v_tenant and j.fiscal_period_id is null),
    format('%s journals', v_n);

  -- ── 6. Nothing is relaxed ──────────────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_inventory_reconciles();
    v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 200);
  end;
  return query select 'stock, subledger and inventory reconcile on the demonstration exactly as for a customer'::text,
    v_ok, v_msg;

  -- ── 7. The stock ledger follows the document date ──────────────────────────
  v_cases := v_cases + 1;
  select m.occurred_at, x.document_date into v_old_at, v_old_on
    from erp.stock_movement m join erp.document x on x.id = m.document_id
   where m.tenant_id = v_tenant order by x.document_date limit 1;
  -- And a document dated today keeps the clock: one receipt, through the spine.
  select l.entity_id, l.currency into v_entity, v_ccy from erp.ledger l where l.tenant_id = v_tenant and l.is_primary;
  select (v_conf ->> 'site_id')::uuid into v_site;
  select p.id into v_supp from erp.party p where p.tenant_id = v_tenant and p.code = 'S-STEEL';
  select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.code = 'RM-100';
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_supp, current_date, v_ccy, 'SUITE-TODAY', '{}'::jsonb);
  v_pol := erp.add_document_line(v_po, v_item, 10, 1275, 'Steel bar, 20mm', current_date + 3);
  perform erp.transition_document(v_po, 'submit'); perform erp.transition_document(v_po, 'approve');
  perform erp.transition_document(v_po, 'send');
  v_grn := erp.create_document('goods_receipt', v_entity, v_site, v_supp, current_date, v_ccy, 'SUITE-TODAY', '{}'::jsonb);
  v_gl := erp.receive_against(v_grn, v_pol, 10);
  perform erp.transition_document(v_grn, 'post');
  select m.occurred_at into v_new_at from erp.stock_movement m where m.document_id = v_grn;
  return query select 'a backdated movement happened on its document''s day; one dated today keeps the clock'::text,
    v_old_at::date = v_old_on and v_old_on < current_date
    and v_new_at between now() - interval '60 seconds' and clock_timestamp() + interval '1 second',
    format('oldest %s on %s; today %s', v_old_at, v_old_on, v_new_at);

  -- ── 8. Days asked twice are built once ─────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.document x where x.tenant_id = v_tenant;
  v_res2 := erp.seed_demo_history(v_slice, v_slice + 4, 1);
  select count(*) into v_m from erp.document x where x.tenant_id = v_tenant;
  return query select 'building the same days again creates nothing'::text,
    v_n = v_m and (v_res2 ->> 'built')::integer = 0 and (v_res2 ->> 'done')::boolean,
    format('%s documents before, %s after; %s', v_n, v_m, v_res2 -> 'notes');

  -- ── 9. The sandbox rule binds live organisations ───────────────────────────
  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
  begin
    v_msg := erp.assert_validation_environment_available();
    v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  update erp.environment set is_live = true where tenant_id = v_tenant and is_self;
  begin
    perform erp.assert_validation_environment_available();
    v_ok := false; v_msg := v_msg || ' — and the live one was not found';
  exception when others then
    v_ok := v_ok and sqlerrm like 'CLOVEERP_NO_VALIDATION_ENVIRONMENT%' and sqlerrm like '%zzdemo%';
    v_msg := v_msg || ' — live: ' || left(sqlerrm, 80);
  end;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  return query select 'a non-live organisation without a sandbox is not a finding; a live one is'::text, v_ok, v_msg;

  -- ── 10. Numbers, the sandbox in seed_demo, and nothing left behind ─────────
  v_cases := v_cases + 1;
  v_ok := not exists (select 1 from erp.document x where x.tenant_id = v_tenant
                        and x.document_number ~ '-20[0-9]{2}-')
          and position('''sandbox''' in pg_get_functiondef('erp.seed_demo()'::regprocedure)) > 0
          and position('ensure_demo_configuration' in pg_get_functiondef('public.erp_seed_demo()'::regprocedure)) > 0;
  -- The journal balance trigger is deferred to commit, and at commit the
  -- organisation is gone. Settle it now, while its lines still exist.
  set constraints all immediate;
  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  return query select 'numbers carry no year, seed_demo creates the sandbox, and the suite leaves nothing behind'::text,
    v_ok and not exists (select 1 from erp.tenant t where t.id = v_tenant)
    and not exists (select 1 from erp.document x where x.tenant_id = v_tenant)
    and not exists (select 1 from erp.stock_movement m where m.tenant_id = v_tenant),
    'and the assertion is quiet again: ' || erp.assert_validation_environment_available();

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.demo_history_suite() from public, anon, authenticated;

create or replace function erp_test.assert_demo_history_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _demo_history on commit drop as
    select * from erp_test.demo_history_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail from _demo_history;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMO_HISTORY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001',
      hint = 'The demonstration either cannot be configured and built through the '
             'spine, or what it builds does not reconcile.';
  end if;
  return format('demo history: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_demo_history_suite() from public, anon, authenticated;

-- Not registered in erp_meta.diagnostic_check, like every other suite:
-- supabase/ci/run_checks.sh finds every zero-argument assert_* in erp_test from
-- the catalogue, and the workflow's explicit list names it as well.

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Proved here, not later
-- ═════════════════════════════════════════════════════════════════════════════

select erp_test.assert_demo_history_suite();

select erp.assert_validation_environment_available();
select erp.assert_public_api_safe();
select erp.assert_intelligence_boundary();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_diagnostics_registered();
