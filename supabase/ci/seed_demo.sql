-- A demonstration organisation for the build to reconcile.
--
-- The whole-database reconciliation at the end of the build visits every
-- organisation the suites left behind — which, since every suite cleans up,
-- is none. An assertion over an empty database is a green light with nothing
-- behind it (20260904390000 said this about incidents; it is as true here).
-- So the build seeds one organisation the way the product does — the same
-- erp.ensure_demo_configuration() and erp.seed_demo_history() the tenant
-- screen runs — and the reconciliation then has a ledger, a stock ledger, a
-- subledger and a batch genealogy to disagree with.
--
-- Run by psql as the trusted build role, once, after every migration has
-- applied and before supabase/ci/run_checks.sh. Six five-day slices: a
-- month of trading, in a few seconds.
\set ON_ERROR_STOP on
\set QUIET on

begin;

select * from erp.provision_tenant('ci-demo', 'CI demonstration', 'admin@ci-demo.test', 'CI Admin') \gset

-- Impersonate the invited administrator: the demo builders run as a
-- principal, not as the build role. Transaction-local, like every context.
select set_config('request.jwt.claims',
                  json_build_object('sub', '00000000-0000-4000-8000-00000000c1de')::text, true);
select erp.claim_invitation(:'admin_token');

-- provision_tenant leaves the organisation live; the demo builder refuses a
-- live environment, as it should. Reopen the bootstrap window.
update erp.environment set is_live = false
 where tenant_id = :'tenant_id' and is_self;

select left(erp.ensure_demo_configuration(:'tenant_id', :'admin_user_id')::text, 200) as configured;

select (date_trunc('month', current_date) - interval '12 months')::date as from_date \gset

select erp.seed_demo_history(:'from_date'::date, null, 1) ->> 'built' as slice_1;
select erp.seed_demo_history(:'from_date'::date + 5, null, 1) ->> 'built' as slice_2;
select erp.seed_demo_history(:'from_date'::date + 10, null, 1) ->> 'built' as slice_3;
select erp.seed_demo_history(:'from_date'::date + 15, null, 1) ->> 'built' as slice_4;
select erp.seed_demo_history(:'from_date'::date + 20, null, 1) ->> 'built' as slice_5;
select erp.seed_demo_history(:'from_date'::date + 25, null, 1) ->> 'built' as slice_6;

select 'ci-demo: ' || count(*) || ' documents' as seeded
  from erp.document where tenant_id = :'tenant_id';

commit;
