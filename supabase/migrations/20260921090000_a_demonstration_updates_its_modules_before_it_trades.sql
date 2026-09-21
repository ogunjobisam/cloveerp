set lock_timeout = '30s';

-- =============================================================================
-- 20260921090000  A demonstration updates its modules before it trades
-- -----------------------------------------------------------------------------
-- R0 was reported merged and it is not: the live deploy still refuses on the
-- first day the catch-up tries to build.
--
--   erp.catch_up_demonstrations() took 4.9 s
--   - demo-cbb10384: traded 2026-04-15 to 2026-09-20, 0 document(s); 0 supplier
--     bill(s); 0 month(s) closed, 0 left open
--   - demo-cbb10384: It traded as far as it could and then stopped. 2026-04-15
--     would not build: CLOVEERP_PROMOTION_BREAKS_DETERMINATION...
--
-- ── WHAT IS ACTUALLY WRONG ───────────────────────────────────────────────────
--
-- demo-cbb10384 was configured before 17-18 September, when the transfer
-- order (20260917130000), the customer and supplier credit note
-- (20260918170000, 20260918220000) and the stock adjustment document
-- (20260918810000) shipped. erp.seed_demo_history() gained a block for each of
-- them — every Tuesday a supplier credit note, every Wednesday a transfer to
-- the second site, every Friday a customer credit note, every Saturday a
-- stock count — and every block calls the door directly
-- (erp.raise_transfer_order(), erp.raise_supplier_credit_note(),
-- erp.raise_customer_credit_note(), erp.raise_stock_adjustment()), which is
-- right: the seeder is meant to use the product's own doors, not a shortcut.
--
-- What is missing is what brings an EXISTING organisation's modules up to the
-- version those doors need. The product already ships the machinery for
-- exactly this — erp.plan_module_upgrade() reports what a later installer
-- version added that an organisation does not hold, and
-- erp.upgrade_module_configuration() authors it as a change set and, before
-- go-live, promotes it at once. Both are proved in isolation
-- (erp_test.module_upgrade_suite(), 20260917130000) and both are called from
-- erp.ensure_demo_configuration() when it is re-run on an organisation that
-- already exists. But nothing in the deploy path ever re-runs it. The only
-- production caller of erp.ensure_demo_configuration() is
-- public.erp_seed_demo(), at first provisioning; erp.demonstration_catch_up()
-- trades an existing organisation forward through erp.seed_demo_history()
-- alone. Every call to erp.upgrade_module_configuration() outside that one
-- installer arm is inside a test fixture that provisions and rolls a version
-- number back by hand to prove the upgrade works — none of them wire it into
-- the routine the deploy actually runs. `git grep -n
-- 'upgrade_module_configuration('` over supabase/migrations shows every real
-- call site; none of them is erp.demonstration_catch_up() or
-- erp.seed_demo_history().
--
-- So demo-cbb10384 still has none of the three mechanisms installed. Its first
-- Wednesday is a silent no-op (the second site it would move stock to does not
-- exist, and the query that finds one returns nothing), but its first Friday
-- — 2026-04-17, inside the same five-day slice the first call to
-- erp.seed_demo_history(2026-04-15, null, 1) tries to build — reaches
-- erp.raise_customer_credit_note(), which opens a 'sales_credit_note'
-- document. Fixed as a wiring gap alone, that call would simply refuse
-- CLOVEERP_UNKNOWN_DOCUMENT_TYPE, which is not what the deploy log shows.
--
-- Wiring erp.ensure_demo_configuration()'s own upgrade arms into the catch-up
-- turns up the second, genuine defect underneath the first. Promoting
-- sales-lifecycle's upgrade installs the sales_credit_note posting rule and,
-- in the same change set, whatever account erp_ref.module_upgrade_account
-- separately says that version needs — but nobody registered one for it,
-- because every account its posting_lines name (revenue, tax_control,
-- inventory, cost_of_sales, trade_receivable) is a purpose the base
-- finance-posting installer already gives every organisation. That is true on
-- the default chart. It is not proved true in general, and this organisation
-- is exactly the one the product already knows is not general:
-- 20260905020000 found that the live demonstration has every feature switched
-- on, statutory_chart_8_1 among them, specifically because a chart pack's
-- accounts are the pack's own list and can fall behind a purpose a later
-- posting rule starts asking for. erp.plan_module_upgrade() has no way to
-- notice that, because its account arm reads only
-- erp_ref.module_upgrade_account — a second list a module's author must
-- remember to keep in step with every posting rule the same upgrade installs.
-- When the two fall out of step, erp.upgrade_module_configuration() promotes
-- a posting rule this organisation cannot actually post, and
-- erp.promote_change_set()'s determination guard is right to refuse it:
-- CLOVEERP_PROMOTION_BREAKS_DETERMINATION is the guard doing its job on a real
-- gap, not a defect in the guard. The gap is that the planner under-counts
-- what an upgrade needs.
--
-- ── THE FIX, IN TWO PARTS ─────────────────────────────────────────────────────
--
-- 1. erp.demonstration_catch_up() brings every module with an outstanding
--    plan_module_upgrade() current before it calls erp.seed_demo_history(),
--    in the same finance-first order 20260916610000 and 20260919500000 fixed
--    for the promotion loops that share this hazard: a module promoted before
--    finance-posting can name a rule with no version yet in force. This is not
--    scoped to demo-cbb10384 — it runs for every organisation
--    erp.catch_up_demonstrations() finds, which is every demonstration on the
--    database, so every demonstration that predates a module version gets the
--    same catch-up, not just this one.
--
-- 2. erp.plan_module_upgrade() derives a required account from the posting
--    rule the SAME upgrade is about to install, in addition to (not instead
--    of) erp_ref.module_upgrade_account. A purpose is planned once whichever
--    list names it, so an upgrade whose author forgot to register the account
--    a new posting rule needs is still planned completely. This is a planner
--    fix, not a data patch for this one pack: it closes the class of gap for
--    every module upgrade this product ever ships, not the one credit note
--    that happened to expose it.
--
-- Neither change weakens erp.promote_change_set()'s determination guard. It
-- still refuses a promotion that genuinely leaves a posting unable to
-- determine an account; what changes is that the plan it is asked to promote
-- now actually contains everything the rule needs, on any chart.
--
-- ── PROOF ─────────────────────────────────────────────────────────────────────
--
-- erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite(): an
-- organisation on a chart with every standard account EXCEPT the one a
-- registered-but-unaccounted-for posting rule needs. Before this migration's
-- fix erp.plan_module_upgrade() would not see the gap; after it, the plan
-- names the account, erp.upgrade_module_configuration() creates it in the
-- same change set, the promotion succeeds, and
-- erp.determination_coverage_report() carries no finding for the new rule.
--
-- erp_test.demonstration_module_catch_up_suite(): a fixture shaped like
-- demo-cbb10384 — a demonstration that has traded for months on modules
-- predating the transfer order, both credit notes and the stock adjustment,
-- AND missing the one account the credit note upgrade needs, the same way an
-- unregistered chart can be missing it live. erp.demonstration_catch_up() is
-- run across a span that crosses a Tuesday, a Wednesday, a Friday and a
-- Saturday. It is held to: no day refuses, every module reaches its current
-- version, a transfer order, a customer credit note, a supplier credit note
-- and a stock adjustment all actually post, and the five reconciliation ties
-- still hold afterward. Both suites are pinned at both ends and undone by
-- CLOVEERP_SUITE_UNDO.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The planner also reads what the posting rule itself needs
-- ═════════════════════════════════════════════════════════════════════════════

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

    -- An account the same upgrade needs, from either of the two places that
    -- say so: a purpose somebody registered separately against this version
    -- (erp_ref.module_upgrade_account), and a purpose named only inside a
    -- posting rule this same upgrade is about to install
    -- (20260921090000). The second source exists because the first is a list
    -- a module's author must remember to keep in step with every posting
    -- rule's own payload; where the two fall out of step, the account this
    -- upgrade actually needs went unplanned, erp.upgrade_module_configuration()
    -- promoted a rule the organisation could not post, and
    -- erp.promote_change_set()'s determination guard refused the whole
    -- upgrade rather than guess at an account. Reading the requirement from
    -- the rule itself as well closes that gap for every future posting rule
    -- an upgrade installs, not only the one that first exposed it.
    select 'account', e.code || '|' || erp.chart_account_code(req.purpose),
           jsonb_build_object(
             'entity', e.code,
             'code', erp.chart_account_code(req.purpose),
             'name', cap.name,
             'account_type', cap.account_type::text,
             'is_postable', true,
             'currency', e.base_currency),
           req.to_version,
           format('an account the company %s lacks', e.code),
           10
      from (
        select ua.purpose, ua.to_version
          from erp_ref.module_upgrade_account ua
         where ua.install_code = p_install_code and ua.to_version > inst.installer_version
        union
        select l.value -> 'account' ->> 'purpose', ui.to_version
          from erp_ref.module_upgrade_item ui
          cross join lateral jsonb_array_elements(coalesce(ui.payload -> 'posting_lines', '[]'::jsonb)) l
         where ui.install_code = p_install_code
           and ui.object_kind = 'posting_rule'
           and ui.to_version > inst.installer_version
           and jsonb_typeof(l.value -> 'account') = 'object'
           and (l.value -> 'account' ->> 'purpose') is not null
      ) req(purpose, to_version)
      join erp_ref.chart_account_purpose cap on cap.purpose = req.purpose
      join erp.entity e on e.tenant_id = v_tenant and e.status = 'active'
     where not exists (
         select 1 from erp.account a
          where a.tenant_id = v_tenant and a.entity_id = e.id
            and a.code = erp.chart_account_code(req.purpose) and a.status = 'active')
     order by 6, 4, 1, 2;
end;
$$;

revoke all on function erp.plan_module_upgrade(text) from public, anon;

comment on function erp.plan_module_upgrade(text) is
  'What the current version of a module installer would add to this '
  'organisation and it does not hold: the posting rules and configuration a '
  'later version brought, and the accounts each company lacks — read from '
  'erp_ref.module_upgrade_account and from every posting rule the same '
  'upgrade installs (20260921090000), so an account nobody remembered to '
  'register separately is still planned. Empty when the organisation is '
  'current.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The catch-up brings the tenant's modules current before it trades
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.demonstration_catch_up()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_code     text;
  v_why      text;
  v_last     date;
  v_cursor   date;
  v_today    date;
  v_res      jsonb;
  v_built    integer := 0;
  v_calls    integer := 0;
  v_billed   integer := 0;
  v_unbilled integer := 0;
  v_closed   integer := 0;
  v_stuck    integer := 0;
  v_stopped  text;
  v_notes    jsonb := '[]'::jsonb;
  v_upgraded jsonb := '[]'::jsonb;
  g          record;
  p          record;
  k          record;
  m          record;
begin
  select t.code into v_code from erp.tenant t where t.id = v_tenant;

  v_why := case
             when v_code is null or v_code not like 'demo-%'
               then 'its name does not begin with demo-'
             when erp.environment_is_live()
               then 'its environment is a live one'
           end;

  if v_why is not null then
    raise exception
      'CLOVEERP_NOT_A_DEMONSTRATION: % is not a demonstration organisation, because %',
      coalesce(v_code, 'this organisation'), v_why
      using errcode = '42501',
            hint = 'Open a demonstration organisation and run it there. Made-up '
                   'trading, made-up supplier bills and months closed on nobody''s '
                   'say-so do not belong in a real company''s books.';
  end if;

  -- ── Brought current before it trades (20260921090000) ─────────────────────
  --
  -- A demonstration is configured once, at provisioning, by
  -- public.erp_seed_demo(). Every module version this product ships after
  -- that day is a gap nothing ever closes on an organisation that already
  -- exists: erp.ensure_demo_configuration() carries the arm that would close
  -- it, and nothing calls erp.ensure_demo_configuration() again. Trading
  -- forward through erp.seed_demo_history() then reaches whatever document a
  -- newer weekday block raises — a transfer order, either credit note, a
  -- stock adjustment — against a tenant that was never given it.
  --
  -- The installers' own order, named, for the same reason 20260916610000 and
  -- 20260919500000 name it for a promotion loop: a module upgrade promoted
  -- before finance-posting can name a posting rule with no version yet in
  -- force, which erp.promote_change_set()'s determination guard refuses. A
  -- module this list does not name goes after the named ones, by code, so the
  -- order is decided either way and not left to whichever order
  -- erp.module_installation happened to be scanned in.
  begin
    for m in
      select i.install_code from erp.module_installation i
       where i.tenant_id = v_tenant
         and exists (select 1 from erp.plan_module_upgrade(i.install_code))
       order by array_position(array['finance-posting', 'procurement-lifecycle', 'sales-lifecycle',
                                     'inventory-operations', 'procurement-controls', 'quality',
                                     'logistics', 'period-close'], i.install_code) nulls last,
                i.install_code
    loop
      perform erp.upgrade_module_configuration(m.install_code);
      v_upgraded := v_upgraded || to_jsonb(m.install_code);
    end loop;

    if jsonb_array_length(v_upgraded) > 0 then
      v_notes := v_notes || to_jsonb(
        format('Brought current before trading: %s.', array_to_string(
                 array(select jsonb_array_elements_text(v_upgraded)), ', ')));
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(
      format('Its modules were left as they were, because bringing one current refused. %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs ───────────────────────────────────────
  --
  -- current_date and not erp.local_today(): the builder clamps its own end to
  -- current_date, so a bound past that one would only buy a call that builds
  -- nothing.
  begin
    select max(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD'))
      into v_last
      from erp.document d
     where d.tenant_id = v_tenant
       and d.their_reference ~ '^DEMO-[0-9]{8}-';

    if v_last is null then
      v_notes := v_notes || to_jsonb(
        'It has no history the builder made, so there is no day to carry on from.'::text);
    else
      v_cursor := v_last + 1;

      <<catching_up>>
      while v_cursor <= current_date loop
        -- A slice that refuses stops the catching up where it stopped. The days
        -- already built are days of trading that happened and each one was a
        -- call of its own; throwing them away because the day after them would
        -- not build would be giving ground at the wrong end.
        begin
          v_res := erp.seed_demo_history(v_cursor, null, 1);
        exception when others then
          v_stopped := format('%s would not build: %s', v_cursor, sqlerrm);
        end;
        exit catching_up when v_stopped is not null;

        v_built := v_built + coalesce((v_res ->> 'built')::integer, 0);
        v_calls := v_calls + 1;
        exit catching_up when coalesce((v_res ->> 'done')::boolean, true);
        v_cursor := (v_res ->> 'next_from')::date;
        -- A call always advances, so this cannot spin; it is here because a
        -- loop driving a routine on that routine's own answer should not be
        -- able to run a deploy out of its hour if that ever stops being true.
        exit catching_up when v_calls > 500;
      end loop catching_up;

      if v_stopped is not null then
        v_notes := v_notes || to_jsonb(
          format('It traded as far as it could and then stopped. %s', v_stopped));
      end if;

      -- The books after the catching up, or none of it.
      perform erp.assert_stock_reconciles();
      perform erp.assert_inventory_reconciles();
      perform erp.assert_subledger_reconciles();
      perform erp.assert_ageing_equals_control();
      perform erp.assert_trial_balance_balances();
    end if;
  exception when others then
    -- Variables are not rolled back with the rows, so the count of what was
    -- built has to be put back by hand or it would report work that no longer
    -- exists.
    v_built := 0; v_calls := 0;
    v_notes := v_notes || to_jsonb(
      format('Its trading was left where it was, because carrying on refused. %s', sqlerrm));
  end;

  -- ── The supplier bills the builder never raised ────────────────────────────
  begin
    for g in
      select d.id, d.document_number, d.document_date, d.site_id
        from erp.document d
        join erp.document_type dt
          on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
       where d.tenant_id = v_tenant
         and dt.code = 'goods_receipt'
         and not d.is_cancelled
         and erp.object_current_state('document', d.id) = 'posted'
         and exists (select 1 from erp.document_relation fr
                      where fr.tenant_id = d.tenant_id
                        and fr.from_document_id = d.id
                        and fr.relation_kind = 'fulfils'
                        and fr.to_line_id is not null)
         -- Nothing billed against the order lines it arrived against, so the
         -- accrual it raised is the whole of what this bill clears. It is also
         -- what makes a second run find nothing: a bill leaves none.
         and not exists (select 1 from erp.document_relation fr
                           join erp.document_line ol
                             on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                          where fr.tenant_id = d.tenant_id
                            and fr.from_document_id = d.id
                            and fr.relation_kind = 'fulfils'
                            and coalesce(ol.quantity_invoiced, 0) > 0)
         -- Nothing on its way back to the supplier: billing for goods that were
         -- returned is how a demonstration acquires a credit balance nobody can
         -- explain.
         and not exists (select 1 from erp.document_line gl
                           join erp.document_relation rr
                             on rr.tenant_id = gl.tenant_id
                            and rr.to_line_id = gl.id
                            and rr.relation_kind = 'returns'
                          where gl.tenant_id = d.tenant_id
                            and gl.document_id = d.id)
       order by d.document_date, d.document_number
    loop
      begin
        -- Dated where the goods arrived rather than where the database is
        -- standing (20260920110000).
        v_today := erp.local_today(g.site_id);
        perform erp.bill_from_receipt(
                  g.id, 'INV/' || g.document_number, v_today, v_today + 30, true);
        v_billed := v_billed + 1;
      exception when others then
        v_unbilled := v_unbilled + 1;
        v_notes := v_notes || to_jsonb(
          format('%s of %s is still waiting for its bill. %s',
                 g.document_number, g.document_date, sqlerrm));
      end;
    end loop;

    -- The accrual has moved to the creditors, or none of it has.
    perform erp.assert_subledger_reconciles();
    perform erp.assert_ageing_equals_control();
    perform erp.assert_trial_balance_balances();
  exception when others then
    v_billed := 0; v_unbilled := 0;
    v_notes := v_notes || to_jsonb(
      format('Its goods received not invoiced were left as they were, because billing refused. %s',
             sqlerrm));
  end;

  -- ── The months that were never closed ──────────────────────────────────────
  begin
    if not exists (select 1 from erp.change_set c
                    where c.tenant_id = v_tenant and c.code = 'period-close') then
      perform erp.configure_period_close();
    end if;

    -- The month is the organisation's own, not the one the database is standing
    -- in: at a month boundary those are different months, and this would
    -- otherwise close the month the organisation is still working in.
    v_today := erp.local_today();

    for p in select fp.id, fp.code, l.code as ledger
               from erp.fiscal_period fp
               join erp.ledger l
                 on l.tenant_id = fp.tenant_id and l.id = fp.ledger_id
              where fp.tenant_id = v_tenant
                and fp.status = 'open'::erp.period_status
                and fp.ends_on < date_trunc('month', v_today)::date
              order by fp.ends_on, l.code
    loop
      begin
        -- erp.open_period_close() refuses a period whose tasks are already
        -- raised, because its insert conflicts away to nothing and it reads
        -- that as an organisation with no template. Raise them once.
        if not exists (select 1 from erp.close_task ct
                        where ct.tenant_id = v_tenant
                          and ct.fiscal_period_id = p.id) then
          perform erp.open_period_close(p.id);
        end if;

        -- In the order the dependencies allow, and with no waiver reason: four
        -- of the six are unwaivable ties and each runs its check inside
        -- erp.complete_close_task(), where it cannot be ticked past, so a month
        -- passes on its own figures or says which figure it failed on.
        for k in select ct.id
                   from erp.close_task ct
                  where ct.tenant_id = v_tenant
                    and ct.fiscal_period_id = p.id
                    and ct.status not in ('complete', 'waived')
                  order by ct.seq, ct.code
        loop
          perform erp.complete_close_task(k.id, null);
        end loop;

        perform erp.close_period(p.id);
        v_closed := v_closed + 1;
      exception when others then
        v_stuck := v_stuck + 1;
        v_notes := v_notes || to_jsonb(
          format('%s of the %s ledger stays open. %s', p.code, p.ledger, sqlerrm));
      end;
    end loop;
  exception when others then
    v_closed := 0; v_stuck := 0;
    v_notes := v_notes || to_jsonb(
      format('Its months were left open, because the close refused. %s', sqlerrm));
  end;

  return jsonb_build_object(
    'organisation',     v_code,
    'modules_upgraded', v_upgraded,
    'traded_from',      v_last + 1,
    'traded_to',        current_date,
    'documents_built',  v_built,
    'calls',            v_calls,
    'bills_raised',     v_billed,
    'receipts_unbilled', v_unbilled,
    'periods_closed',   v_closed,
    'periods_left_open', v_stuck,
    'notes',            v_notes);
end;
$$;

comment on function erp.demonstration_catch_up() is
  'Brings one demonstration organisation up to today: upgrades every module '
  'with an outstanding plan (20260921090000), trades forward from the last day '
  'its builder built, bills the goods it received and never billed, and '
  'closes every month before this one with nothing waived. Refuses any '
  'organisation that is not a demonstration. Safe to run twice.';

revoke all on function erp.demonstration_catch_up() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proof — the planner finds an account a posting rule needs but nobody
--    registered separately
-- ═════════════════════════════════════════════════════════════════════════════
--
-- sales-lifecycle's credit note is used because it is the clean negative case:
-- its posting rule (sales_credit_note, version 2) names five accounts by
-- purpose in its own payload — revenue, tax_control, inventory, cost_of_sales,
-- trade_receivable — and erp_ref.module_upgrade_account registers NONE of
-- them, on the assumption that every organisation configured through
-- erp.configure_finance() already holds all five. Before this migration's fix,
-- erp.plan_module_upgrade() had no way to notice when that assumption did not
-- hold for one company; the credit note upgrade would promote and
-- erp.promote_change_set()'s determination guard would refuse it, correctly,
-- for a gap the planner never named. Deactivating the revenue account and
-- rolling the version back reproduces that gap without needing a chart pack.

create or replace function erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth   constant uuid := '00000000-0000-4000-8000-00000000acc0';
  v_entity uuid;
  v_code   text;
  v_planned_before integer;
  v_planned_after  integer;
  v_upgraded jsonb;
  v_ok boolean; v_msg text; v_fixture text;
  v_findings integer;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-upgrade-accts', 'Upgrade accounts suite',
                              'admin@zz-upgrade-accts.test', 'Upgrade Accounts Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email) values (v_auth, 'admin@zz-upgrade-accts.test');
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- Read only after the organisation's context is in force: erp.chart_account_code()
  -- needs erp.require_tenant_id(), which is not resolvable before erp.claim_invitation().
  v_code := erp.chart_account_code('revenue');

  -- ── 1. Current, so there is nothing to plan ────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a freshly configured organisation has nothing outstanding for sales-lifecycle';
  passed := not exists (select 1 from erp.plan_module_upgrade('sales-lifecycle'));
  detail := 'plan_module_upgrade(''sales-lifecycle'') is empty before anything is rolled back';
  return next;

  -- ── 2. Roll it back, and take away an account the credit note needs ───────
  -- erp_ref.module_upgrade_account carries nothing for sales-lifecycle at all
  -- — this reproduces exactly the case it cannot describe.
  v_cases := v_cases + 1;
  update erp.module_installation i set installer_version = 1
   where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle';
  delete from erp.posting_rule r where r.tenant_id = v_tenant and r.code = 'sales_credit_note';
  update erp.account a set status = 'inactive'
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_code;

  select count(*) into v_planned_before
    from erp.plan_module_upgrade('sales-lifecycle') p
   where p.object_kind = 'account' and p.object_key = (
     select e.code || '|' || v_code from erp.entity e where e.id = v_entity);
  case_name := 'with the posting rule gone and its revenue account inactive, the plan names the account the rule needs, from the rule''s own payload rather than a separate register';
  passed := v_planned_before = 1;
  detail := format('%s account item(s) planned for %s under sales-lifecycle, which registers no module_upgrade_account row at all',
                   v_planned_before, v_code);
  return next;

  -- ── 3. The upgrade promotes cleanly and creates it ─────────────────────────
  v_cases := v_cases + 1;
  begin
    v_upgraded := erp.upgrade_module_configuration('sales-lifecycle');
    v_ok := true; v_msg := 'promoted';
  exception when others then
    v_ok := false; v_msg := sqlerrm;
  end;
  case_name := 'the upgrade promotes without erp.promote_change_set() refusing, and the account exists again';
  passed := v_ok
        and (v_upgraded ->> 'promoted')::boolean
        and exists (select 1 from erp.account a
                     where a.tenant_id = v_tenant and a.entity_id = v_entity
                       and a.code = v_code and a.status = 'active')
        and exists (select 1 from erp.posting_rule r
                     where r.tenant_id = v_tenant and r.code = 'sales_credit_note' and r.status = 'active')
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 2;
  detail := v_msg;
  return next;

  -- ── 4. Nothing left outstanding, and no new determination finding ─────────
  v_cases := v_cases + 1;
  select count(*) into v_planned_after from erp.plan_module_upgrade('sales-lifecycle');
  select count(*) into v_findings
    from erp.determination_coverage_report(v_tenant) c
   where c.reference like '%sales_credit_note%';
  case_name := 'the plan is empty again and the posting rule the upgrade installed determines an account cleanly';
  passed := v_planned_after = 0 and v_findings = 0;
  detail := format('%s item(s) still planned, %s determination finding(s) naming sales_credit_note',
                   v_planned_after, v_findings);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-upgrade-accts')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'zz-upgrade-accts rolled back with everything it did');
  return next;

  if v_cases <> 5 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: plan_module_upgrade_finds_posting_rule_accounts_suite ran % cases, expected 5%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite() from public, anon;

create or replace function erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _plan_upgrade_accts on commit drop as
    select * from erp_test.plan_module_upgrade_finds_posting_rule_accounts_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _plan_upgrade_accts;
  drop table _plan_upgrade_accts;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PLAN_UPGRADE_ACCOUNTS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: plan_module_upgrade_finds_posting_rule_accounts_suite ran % cases, expected 5', v_all;
  end if;
  return format('a module upgrade plans the account its own posting rule needs even when nobody registered it separately: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Proof — a demonstration shaped like demo-cbb10384 catches up
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Configured on the default chart (this is about the wiring and the planner,
-- not about statutory_chart_8_1, which 20260905020000 already covers), rolled
-- back to before the transfer order, both credit notes and the stock
-- adjustment existed — before a single document is built, so there is nothing
-- yet to conflict with deleting their configuration — with the sales-lifecycle
-- credit note's revenue account made inactive to reproduce the account gap
-- the previous suite proves the planner now closes. One Monday is then built
-- so there is a day to carry on from (erp.demonstration_catch_up() does
-- nothing when there is no DEMO- history at all), and the catch-up is run
-- across the three weeks since, which holds a Tuesday, a Wednesday, a Friday
-- and a Saturday several times over — this is what demo-cbb10384 actually is:
-- an organisation that traded for months on a version of erp.seed_demo_history()
-- that had none of these blocks, now asked to trade forward through the
-- version that does.

create or replace function erp_test.demonstration_module_catch_up_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_auth    constant uuid := '00000000-0000-4000-8000-00000000dccb';
  v_entity  uuid;
  v_revenue text;
  -- The Monday of three weeks ago. date_trunc('week', …) is ISO: it lands on
  -- a Monday, which none of the four new blocks (Tuesday, Wednesday, Friday,
  -- Saturday) fire on, so building it does not need any of the configuration
  -- this fixture is about to take away.
  v_from    date;
  v_report  jsonb;
  v_stopped_notes text;
  v_transfers integer; v_scn integer; v_ccn integer; v_adj integer;
  v_ok boolean; v_msg text; v_fixture text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('demo-zzmodup', 'Module catch-up suite',
                              'admin@demo-zzmodup.test', 'Module Catch-up Admin') t;
  insert into auth.users (id, email) values (v_auth, 'admin@demo-zzmodup.test');
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  perform erp.claim_invitation(v_token);
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- Read only after the organisation's context is in force, the same reason
  -- the isolated planner suite above reads it there and not in the declare
  -- block.
  v_revenue := erp.chart_account_code('revenue');
  v_from := date_trunc('week', (current_date - 20)::timestamp)::date;

  -- ── 1. Rolled back before anything is built, so there is nothing yet for
  --      the deleted configuration to conflict with ─────────────────────────
  v_cases := v_cases + 1;
  update erp.module_installation i set installer_version = 3
   where i.tenant_id = v_tenant and i.install_code = 'inventory-operations';
  update erp.module_installation i set installer_version = 1
   where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle';
  update erp.module_installation i set installer_version = 2
   where i.tenant_id = v_tenant and i.install_code = 'procurement-controls';
  delete from erp.document_type dt where dt.tenant_id = v_tenant
   and dt.code in ('transfer_order', 'stock_adjustment', 'sales_credit_note', 'purchase_credit_note');
  delete from erp.posting_rule r where r.tenant_id = v_tenant
   and r.code in ('stock_adjustment', 'sales_credit_note', 'purchase_credit_note');
  -- The account gap the previous suite proves the planner now closes,
  -- reproduced here on the mechanism that actually reached it live: the
  -- credit note's own revenue line, not a purpose anything separately
  -- registers.
  update erp.account a set status = 'inactive'
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = v_revenue;

  -- One day, Monday, so the catch-up has a day to carry on from without
  -- touching any of the four blocks the deleted configuration would refuse.
  -- p_to = p_from limits erp.seed_demo_history() to that single day
  -- (v_end := least(v_from + 4, v_to), and v_to = v_from when the two agree).
  perform erp.seed_demo_history(v_from, v_from, 1);
  set constraints all immediate;

  case_name := 'the organisation is rolled back to before the transfer order, either credit note or the stock adjustment existed, one account the credit note needs is gone, and one Monday of history exists for the catch-up to carry on from';
  passed := (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'sales-lifecycle') = 1
        and not exists (select 1 from erp.document_type dt
                         where dt.tenant_id = v_tenant and dt.code = 'sales_credit_note')
        and not exists (select 1 from erp.account a
                         where a.tenant_id = v_tenant and a.entity_id = v_entity
                           and a.code = v_revenue and a.status = 'active')
        and exists (select 1 from erp.plan_module_upgrade('sales-lifecycle'))
        and exists (select 1 from erp.document d
                     where d.tenant_id = v_tenant and d.their_reference like 'DEMO-%');
  detail := format('sales-lifecycle at version 1, sales_credit_note absent, revenue account inactive, history built from %s (a Monday)', v_from);
  return next;

  -- ── 2. The catch-up brings it current and trades through the gap ──────────
  v_report := erp.demonstration_catch_up();
  v_stopped_notes := (select string_agg(n, ' | ') from jsonb_array_elements_text(v_report -> 'notes') n
                        where n ilike '%would not build%' or n ilike '%refused%');

  v_cases := v_cases + 1;
  case_name := 'no day refuses, and every module the demonstration needs reaches its current version before it trades';
  passed := v_stopped_notes is null
        and (v_report -> 'modules_upgraded') ? 'sales-lifecycle'
        and (v_report -> 'modules_upgraded') ? 'procurement-controls'
        and (v_report -> 'modules_upgraded') ? 'inventory-operations'
        and (v_report ->> 'traded_to')::date = current_date
        and (v_report ->> 'documents_built')::integer > 0
        and exists (select 1 from erp.account a
                     where a.tenant_id = v_tenant and a.entity_id = v_entity
                       and a.code = v_revenue and a.status = 'active');
  detail := format('modules upgraded %s; traded to %s, %s document(s); notes %s',
                   v_report -> 'modules_upgraded', v_report ->> 'traded_to',
                   v_report ->> 'documents_built', coalesce(v_stopped_notes, '(none)'));
  return next;

  -- ── 3. Every newer mechanism actually posted, not merely became available ──
  select count(*) into v_transfers from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'transfer_order' and d.their_reference like 'DEMO-%';
  select count(*) into v_ccn from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'sales_credit_note' and d.their_reference like 'DEMO-%';
  select count(*) into v_scn from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'purchase_credit_note' and d.their_reference like 'DEMO-%';
  select count(*) into v_adj from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.code = 'stock_adjustment' and d.their_reference like 'DEMO-%';

  v_cases := v_cases + 1;
  case_name := 'the span crossed a Tuesday, a Wednesday, a Friday and a Saturday, and each one built the document that day is for';
  passed := v_scn > 0 and v_ccn > 0 and v_adj > 0;
  detail := format('%s transfer order(s) (site-dependent, may be zero), %s supplier credit note(s), %s customer credit note(s), %s stock adjustment(s)',
                   v_transfers, v_scn, v_ccn, v_adj);
  return next;

  -- ── 4. And the books still tie ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_inventory_reconciles()
             || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_ageing_equals_control()
             || '; ' || erp.assert_trial_balance_balances();
    v_ok := true;
  exception when others then
    v_ok := false;
    v_msg := left(sqlerrm, 300);
  end;
  case_name := 'after the upgrade and the trading, stock, inventory, the subledgers, the ageing and the trial balance all still agree';
  passed := v_ok;
  detail := v_msg;
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'demo-zzmodup')
        and not exists (select 1 from auth.users where id = v_auth)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'demo-zzmodup rolled back with its trading and its upgrade');
  return next;

  if v_cases <> 5 then
    raise exception
      'CLOVEERP_SUITE_SHRANK: demonstration_module_catch_up_suite ran % cases, expected 5%',
      v_cases, coalesce(' — the fixture stopped early: ' || v_fixture, '');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_module_catch_up_suite() from public, anon;

create or replace function erp_test.assert_demonstration_module_catch_up_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _demo_module_catch_up on commit drop as
    select * from erp_test.demonstration_module_catch_up_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _demo_module_catch_up;
  drop table _demo_module_catch_up;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DEMONSTRATION_MODULE_CATCH_UP_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> 5 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demonstration_module_catch_up_suite ran % cases, expected 5', v_all;
  end if;
  return format('a demonstration configured before a module''s later version ships still catches up: %s/%s cases passed',
                v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_demonstration_module_catch_up_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_plan_module_upgrade_finds_posting_rule_accounts_suite();
select erp_test.assert_demonstration_module_catch_up_suite();
select erp_test.assert_demonstration_catch_up_suite();

select erp.assert_whole_database_reconciles();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
