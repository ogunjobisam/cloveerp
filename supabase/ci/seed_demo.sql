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
-- Run by psql as the trusted build role, after every migration has applied
-- and before supabase/ci/run_checks.sh. Six five-day slices: a month of
-- trading, in a few seconds.
--
-- Run twice, it builds nothing the second time (Definition of Done DEM-01,
-- "repeatable, idempotent"; 20261010130000): the organisation is found, not
-- provisioned again, and every slice it has already built builds nothing.
-- The build runs it twice to prove that. It is plain SQL apart from the two
-- settings below, so it can be run by anything that speaks to Postgres.
\set ON_ERROR_STOP on
\set QUIET on

-- This database is a demonstration deployment, said the way deploy.yml says it
-- of the Clove ERP Demo project (20261010060000). Unmarked, it would be
-- production, and production makes no demonstrations (20261010061000), so the
-- seed below and every suite that makes one would be refused. First, and in
-- its own statement: a database holding a live organisation refuses the mark.
select erp_meta.mark_deployment('demonstration');

begin;

-- What wrote the seeded month (Definition of Done DAT-04, 20261010130000).
-- Declared first, before anything is written, so every row of the trail says
-- a seed script wrote it rather than that nothing declared anything. A trusted
-- connection may declare it; erp.authorise() leaves a declaration alone.
select erp.declare_source('seed');

-- Found on a second run rather than provisioned again, which refused.
do $seed$
declare
  r        record;
  v_tenant uuid;
  v_admin  uuid;
begin
  select t.id into v_tenant from erp.tenant t where t.code = 'ci-demo';

  -- Impersonate the invited administrator: the demo builders run as a
  -- principal, not as the build role. Transaction-local, like every context.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-00000000c1de')::text, true);

  if v_tenant is null then
    select * into r from erp.provision_tenant('ci-demo', 'CI demonstration', 'admin@ci-demo.test', 'CI Admin');
    v_tenant := r.tenant_id;
    v_admin  := r.admin_user_id;
    perform erp.claim_invitation(r.admin_token);
    perform set_config('ci_seed.first_run', 'true', true);
  else
    select u.id into v_admin from erp.app_user u
     where u.tenant_id = v_tenant and u.email = 'admin@ci-demo.test';
    perform set_config('ci_seed.first_run', 'false', true);
  end if;

  -- provision_tenant leaves the organisation live; the demo builder refuses a
  -- live environment, as it should. Reopen the bootstrap window.
  update erp.environment set is_live = false
   where tenant_id = v_tenant and is_self;

  perform set_config('ci_seed.tenant', v_tenant::text, true);
  perform set_config('ci_seed.admin', v_admin::text, true);
end
$seed$;

select left(erp.ensure_demo_configuration(current_setting('ci_seed.tenant')::uuid,
                                          current_setting('ci_seed.admin')::uuid)::text, 200) as configured;

create temp table ci_seed_slices (slice integer, built integer) on commit drop;
insert into ci_seed_slices
select n, coalesce((erp.seed_demo_history(
         (date_trunc('month', current_date) - interval '12 months')::date + (n - 1) * 5, null, 1) ->> 'built')::integer, 0)
  from generate_series(1, 6) n
 order by n;

select 'ci-demo: ' || count(*) || ' documents, '
       || count(*) filter (where dt.base_type_code = 'transfer_order')
       || ' of them transfers between sites, '
       || count(*) filter (where dt.code = 'sales_credit_note')
       || ' credit notes to customers, '
       || count(*) filter (where dt.code = 'purchase_credit_note')
       || ' returns to suppliers, '
       || count(*) filter (where dt.code = 'purchase_order'
                             and erp.object_current_state('document', d.id) = 'partially_received')
       || ' orders received in part, '
       || count(*) filter (where dt.code = 'purchase_invoice')
       || ' supplier bills, '
       || count(*) filter (where dt.code = 'sales_order'
                             and erp.object_current_state('document', d.id) = 'confirmed'
                             and exists (select 1 from erp.document_relation r
                                          where r.tenant_id = d.tenant_id and r.to_document_id = d.id
                                            and r.relation_kind = 'fulfils' and r.to_line_id is not null))
       || ' orders delivered in part, '
       || count(*) filter (where dt.base_type_code = 'adjustment')
       || ' weekend counts' as seeded
  from erp.document d
  join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
 where d.tenant_id = current_setting('ci_seed.tenant')::uuid;

-- Who, when and from what source, on every document of the seeded month
-- (DAT-04), and on a second run nothing built (DEM-01).
do $proved$
declare
  v_tenant uuid := current_setting('ci_seed.tenant')::uuid;
  v_docs bigint; v_unattributed bigint; v_undeclared bigint; v_built bigint;
begin
  select count(*), count(*) filter (where d.created_by is null or d.created_at is null)
    into v_docs, v_unattributed
    from erp.document d where d.tenant_id = v_tenant;
  select count(*) into v_undeclared
    from erp.audit_entry a where a.tenant_id = v_tenant and a.source = 'undeclared';
  select coalesce(sum(s.built), 0) into v_built from ci_seed_slices s;

  if v_docs = 0 or v_unattributed > 0 or v_undeclared > 0 then
    raise exception 'CLOVEERP_SEED_UNATTRIBUTED: ci-demo holds % document(s), % without who or when, and % audit row(s) with no source',
      v_docs, v_unattributed, v_undeclared;
  end if;
  if current_setting('ci_seed.first_run') = 'false' and v_built > 0 then
    raise exception 'CLOVEERP_SEED_NOT_IDEMPOTENT: the second run built % record(s) the first had built', v_built;
  end if;
  raise notice 'ci-demo: % documents, every one attributed and every audit row declared; % built this run',
    v_docs, v_built;
end
$proved$;

commit;
