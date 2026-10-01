#!/usr/bin/env bash
#
# The Xero + Unleashed pilot, start to finish, on every build.
#
# Every importer has a suite of its own, and each suite builds the records the
# next importer would have made. Nothing loaded one organisation's exports
# through all of them in the order the runbook gives, so nothing could see the
# two halves disagree: the browser's profiles turning a file into rows, and the
# doors those rows meet. The first time they were put together, the trial
# balance could not reach zero on migration clearing, because the stock
# difference decision D7 had never been built.
#
# So this is the pilot as a regression guard:
#
#   1. Setup, as the runbook's step 1 does it with the customer: an
#      organisation (ci-pilot), its loader and a second administrator, finance
#      and inventory configured through change sets the second administrator
#      approves, and the units, warehouses and bins Unleashed uses — through the
#      doors the setup screens call.
#   2. supabase/ci/pilot.ts: the nine files in src/lib/import/fixtures/pilot
#      through the import profiles and the doors, as the loader — the chart,
#      the contacts, the Unleashed customers and suppliers, the products, then
#      stock, receivables, payables and the trial balance. Contacts and
#      products are activated as they load.
#   3. Proof, as the loader: migration clearing is zero; every opening batch is
#      loaded, keeps its working and passes every reconciliation check; stock,
#      receivables and payables stand at the figures the reports print less
#      what was held back; the D7 line is on stock adjustment; each party the
#      two systems share is one party; every contacts and products batch is
#      live and no longer rolls back.
#   4. Cutover, as the second administrator (D32: not the person who loaded):
#      each domain's parallel-run figure recorded, and all four cut over.
#   5. The whole-database reconciliation, once more, now over the pilot too.
#
# Reads PSQL from the environment like run_checks.sh. Needs bun on the path.
set -euo pipefail

PSQL_CMD="${PSQL:-psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER='c1a0e000-0000-4000-8000-00000000a001'
SECOND='c1a0e000-0000-4000-8000-00000000a002'
AS_AT="$(date -u +%Y-%m-01)"

started=$(date +%s)

# ── 1. Setup ────────────────────────────────────────────────────────────────
$PSQL_CMD -v loader="$LOADER" -v second="$SECOND" <<'SQL'
\set ON_ERROR_STOP on
begin;
select set_config('pilot.loader', :'loader', true) as l,
       set_config('pilot.second', :'second', true) as s \gset

do $setup$
declare
  r     record;
  a1    uuid := current_setting('pilot.loader')::uuid;
  a2    uuid := current_setting('pilot.second')::uuid;
  res   jsonb;
  csf   uuid;
  csi   uuid;
  v_main uuid;
  v_north uuid;
begin
  if exists (select 1 from erp.tenant t where t.code = 'ci-pilot') then
    raise exception 'CLOVEERP_CI_PILOT_EXISTS: ci-pilot is already in this database'
      using hint = 'The pilot builds its organisation once per database; rebuild the database or drop the organisation.';
  end if;

  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'ci-pilot', 'Harbour Fixings Ltd', 'loader@ci-pilot.test', 'Pilot Loader');
  insert into auth.users (id, email) values
    (a1, 'loader@ci-pilot.test'), (a2, 'second@ci-pilot.test');

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@ci-pilot.test', 'Second Administrator');
  perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'cutover, D32');

  csf := erp.configure_finance();
  csi := erp.configure_inventory('average');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(res ->> 'token');
  perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
  perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);

  -- The units, warehouses and bins Unleashed uses.
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform public.erp_create_uom(p_code => 'EA', p_name => 'Each', p_uom_class => 'quantity', p_decimals => 0, p_is_base => true);
  perform public.erp_create_uom(p_code => 'BOX', p_name => 'Box', p_uom_class => 'quantity', p_decimals => 0, p_is_base => false);
  v_main := (public.erp_create_site(p_code => 'MAIN', p_name => 'Main warehouse', p_site_type => 'warehouse',
                                    p_entity_id => null, p_country_code => 'GB', p_timezone => null,
                                    p_operator_party_id => null) ->> 'site_id')::uuid;
  v_north := (public.erp_create_site(p_code => 'NORTH', p_name => 'North depot', p_site_type => 'warehouse',
                                     p_entity_id => null, p_country_code => 'GB', p_timezone => null,
                                     p_operator_party_id => null) ->> 'site_id')::uuid;
  perform public.erp_create_location(p_site_id => v_main, p_code => 'DEFAULT', p_name => 'Main default', p_location_type => 'bulk');
  perform public.erp_create_location(p_site_id => v_main, p_code => 'A-01', p_name => 'Aisle A bin 1', p_location_type => 'bulk');
  perform public.erp_create_location(p_site_id => v_north, p_code => 'DEFAULT', p_name => 'North default', p_location_type => 'bulk');
end
$setup$;
commit;
SQL
echo "── ci-pilot set up as at $AS_AT"

# ── 2. The files ────────────────────────────────────────────────────────────
command -v bun >/dev/null 2>&1 || npm install -g bun >/dev/null
bun "$HERE/pilot.ts" "$LOADER" "$AS_AT"

# ── 3–5. Proof, cutover, reconciliation ─────────────────────────────────────
$PSQL_CMD -v loader="$LOADER" -v second="$SECOND" -v as_at="$AS_AT" <<'SQL'
\set ON_ERROR_STOP on
begin;
select set_config('pilot.loader', :'loader', true) as l,
       set_config('pilot.second', :'second', true) as s,
       set_config('pilot.as_at', :'as_at', true) as a \gset

do $proof$
declare
  a1      uuid := current_setting('pilot.loader')::uuid;
  v_as_at date := current_setting('pilot.as_at')::date;
  v_bad   text;
  v_n     bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_n := erp.migration_clearing_balance();
  if v_n <> 0 then
    raise exception 'CLOVEERP_CI_PILOT_CLEARING: migration clearing carries % after all four domains loaded', v_n
      using hint = 'The stock, ledgers and trial balance do not agree; read the batches'' reconciliation checks.';
  end if;

  select string_agg(format('%s: %s', b.code, c.detail), '; ') into v_bad
    from erp.import_batch b
    join erp_ref.migration_domain d on d.object_type = b.object_type
    cross join lateral erp.opening_balance_reconciliation(b.id) c
   where b.tenant_id = erp.require_tenant_id() and not c.passes;
  if v_bad is not null then
    raise exception 'CLOVEERP_CI_PILOT_RECONCILIATION: %', v_bad
      using hint = 'An opening batch loaded and does not reconcile; the check names the difference.';
  end if;

  select string_agg(b.code || ' is ' || b.status::text
                    || case when b.control_evidence is null then ', without its working' else '' end, '; ')
    into v_bad
    from erp.import_batch b
    join erp_ref.migration_domain d on d.object_type = b.object_type
   where b.tenant_id = erp.require_tenant_id()
     and (b.status <> 'loaded' or b.control_evidence is null);
  if v_bad is not null or (select count(*) from erp.import_batch b
                            join erp_ref.migration_domain d on d.object_type = b.object_type
                           where b.tenant_id = erp.require_tenant_id()) <> 4 then
    raise exception 'CLOVEERP_CI_PILOT_OPENING: %', coalesce(v_bad, 'not one batch per domain')
      using hint = 'Every domain loads one batch, and each keeps the printed total and what was held back.';
  end if;

  if erp.migration_figure_stock(v_as_at) <> 417320
     or erp.migration_figure_sales_ledger(v_as_at) <> 422550
     or erp.migration_figure_purchase_ledger(v_as_at) <> 193925 then
    raise exception 'CLOVEERP_CI_PILOT_FIGURES: stock %, receivables %, payables %; the reports say 417320, 422550 and 193925 less nothing held back',
      erp.migration_figure_stock(v_as_at), erp.migration_figure_sales_ledger(v_as_at),
      erp.migration_figure_purchase_ledger(v_as_at)
      using hint = 'A figure moved: read which domain, then its batch.';
  end if;

  if not exists (select 1 from erp.journal_line l join erp.account a on a.id = l.account_id
                  where l.tenant_id = erp.require_tenant_id()
                    and a.code = erp.chart_account_code('stock_adjustment') and l.debit_minor = 2680) then
    raise exception 'CLOVEERP_CI_PILOT_D7: no 26.80 debit on stock adjustment'
      using hint = 'Xero''s Inventory is 4,200.00 and Unleashed''s stock 4,173.20; the trial balance writes off the difference.';
  end if;

  select string_agg(p.name || ' x' || n, ', ') into v_bad
    from (select p.name, count(*) as n from erp.party p
           where p.tenant_id = erp.require_tenant_id() group by p.name having count(*) > 1) p;
  if v_bad is not null
     or not exists (select 1 from erp.party p where p.tenant_id = erp.require_tenant_id() and p.code = 'HOLLIS' and p.status = 'active')
     or exists (select 1 from erp.party p where p.tenant_id = erp.require_tenant_id() and p.code = 'OLDCO') then
    raise exception 'CLOVEERP_CI_PILOT_PARTIES: %', coalesce(v_bad, 'HOLLIS is not a live party, or the obsolete OLDCO loaded')
      using hint = 'Xero and Unleashed name one customer twice; the crosswalk must land both on one party.';
  end if;

  select string_agg(b.code, ', ') into v_bad
    from erp.import_batch b
   where b.tenant_id = erp.require_tenant_id()
     and b.object_type in ('party_profile', 'item_profile') and b.activated_at is null;
  if v_bad is not null or exists (select 1 from erp.item i where i.tenant_id = erp.require_tenant_id() and i.status = 'draft')
     or exists (select 1 from erp.party p where p.tenant_id = erp.require_tenant_id() and p.status = 'draft') then
    raise exception 'CLOVEERP_CI_PILOT_DRAFTS: % not activated, or a record is still a draft', coalesce(v_bad, 'every batch activated, yet')
      using hint = 'Contacts and products go live together once loaded.';
  end if;

  -- The parallel run: what the legacy reports said, less what was held back.
  perform erp.record_parallel_run_figure('stock', v_as_at, 417320, 0, 'Unleashed stock on hand, less the negative line held back');
  perform erp.record_parallel_run_figure('sales_ledger', v_as_at, 422550, 0, 'Xero aged receivables');
  perform erp.record_parallel_run_figure('purchase_ledger', v_as_at, 193925, 0, 'Xero aged payables');
  perform erp.record_parallel_run_figure('nominal', v_as_at, erp.migration_figure_nominal(v_as_at), 0,
                                         'Xero trial balance, agreed with clearing at zero');
end
$proof$;
commit;

-- Cutover, by the second administrator.
begin;
do $cutover$
declare
  d text;
  res jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('pilot.second'))::text, true);
  foreach d in array array['stock', 'sales_ledger', 'purchase_ledger', 'nominal'] loop
    res := public.erp_cut_over_domain(d, 'pilot rehearsal');
    if res ->> 'status' is distinct from 'cut_over' then
      raise exception 'CLOVEERP_CI_PILOT_CUTOVER: % answered %', d, res
        using hint = 'Every domain reconciled; read what the cutover refused.';
    end if;
  end loop;
  if (select count(*) from erp.migration_reconciliation_report() m where m.cutover_status = 'cut_over') <> 4 then
    raise exception 'CLOVEERP_CI_PILOT_CUTOVER: not every domain reads cut over'
      using hint = 'Read erp.migration_reconciliation_report() for the pilot.';
  end if;
end
$cutover$;
commit;

select erp.assert_whole_database_reconciles() as reconciles;
SQL

echo "── the pilot loaded, reconciled and cut over in $(( $(date +%s) - started ))s"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Xero + Unleashed pilot"
    echo "Nine files loaded into ci-pilot as at $AS_AT; clearing at zero, every reconciliation check passing, all four domains cut over by a second administrator."
  } >> "$GITHUB_STEP_SUMMARY"
fi
