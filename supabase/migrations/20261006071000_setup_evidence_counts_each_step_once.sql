set lock_timeout = '30s';

-- =============================================================================
-- 20261006071000  Setup evidence counts each step once
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-38). The setup
-- progress (public.erp_setup_progress(), through erp.setup_progress_by_screen())
-- timed out under load, and every Work page an administrator opens reads it.
--
-- erp.setup_evidence() answers 53 steps, each written as
-- '(select (select count(*) ...) as n) x' and then reading n up to four times
-- (n >= 1, n = 0, n = 1, n || ...). The planner pulls that subquery up and
-- copies the count into every place n is read: a plain EXPLAIN shows 218
-- counts for 53 steps. Each count joined its table to the organisation
-- through a CTE, so the row policy 'tenant_id = erp.current_tenant_id()'
-- stayed a filter on every row it scanned: 440 places in the plan that ask
-- who is signed in row by row. On the fixtures one read as a signed-in
-- administrator asked erp.principal_context() 1,496 times.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp_test.setup_evidence_reference(): today's body, word for word, kept
--      as the answer the new one must give.
--   B. erp.setup_evidence(), edited in place: the organisation is looked up
--      once ('with t as materialized'), each count compares the organisation
--      with that one value ('(select t.id from t)'), and each step's count is
--      fenced ('offset 0') so it is counted once however many times the
--      sentence reads it. The plan has 109 sub-plans instead of 218, and the
--      row policy becomes one test per count instead of one per row: 55 calls
--      of erp.principal_context() where there were 1,496. The steps, the
--      tests and the sentences are unchanged.
--   C. erp_test.setup_evidence_counts_once_suite: the evidence is the same as
--      the reference for every organisation in the database, for a
--      demonstration read by its administrator, and with nobody in context;
--      and the plan filters no row on who is asking.
--
-- On production: one function is edited in place. No table is altered and no
-- row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Today's body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.setup_evidence_reference()
returns table(step_code text, satisfied boolean, evidence text)
language sql
stable
set search_path = ''
as $reference$
  with t as (select erp.current_tenant_id() as id)
  select 'onboarding.start'::text, (n >= 1), (case when n = 0 then 'the interview has not been started' when n = 1 then 'the interview has been started' else n || ' interview sessions exist' end)
    from (select (select count(*) from erp.interview_session i, t where i.tenant_id = t.id) as n) x
  union all
  select 'onboarding.answer'::text, (n >= 1), (case when n = 0 then 'no question has been answered yet' when n = 1 then 'one question has been answered' else n || ' questions have been answered' end)
    from (select (select count(*) from erp.interview_answer a, t where a.tenant_id = t.id) as n) x
  union all
  select 'onboarding.propose'::text, (n >= 1), (case when n = 0 then 'nothing has been proposed from the interview yet' when n = 1 then 'the interview has proposed its configuration' else n || ' proposals have been made from the interview' end)
    from (select (select count(*) from erp.interview_session i, t where i.tenant_id = t.id and i.proposed_at is not null) as n) x
  union all
  select 'permissions.invite'::text, (n >= 2), (case when n = 0 then 'nobody has an account yet' when n = 1 then 'only you have an account' else n || ' people have accounts' end)
    from (select (select count(*) from erp.app_user u, t where u.tenant_id = t.id and u.kind = 'person') as n) x
  union all
  select 'permissions.roles'::text, (n >= 2), (case when n = 0 then 'nobody holds a role yet' when n = 1 then 'only one person holds a role' else n || ' people hold a role' end)
    from (select (select count(distinct ur.app_user_id) from erp.user_role ur, t where ur.tenant_id = t.id and (ur.valid_to is null or ur.valid_to >= current_date)) as n) x
  union all
  select 'permissions.second_admin'::text, (n >= 2), (case when n = 0 then 'nobody can promote a change yet' when n = 1 then 'only one person can promote a change' else n || ' people can promote a change' end)
    from (select (select count(distinct ur.app_user_id) from erp.user_role ur join erp.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id, t where ur.tenant_id = t.id and rp.permission_code = 'administration.promote' and (ur.valid_to is null or ur.valid_to >= current_date)) as n) x
  union all
  select 'permissions.service'::text, (n >= 1), (case when n = 0 then 'no service user yet' when n = 1 then 'one service user' else n || ' service users' end)
    from (select (select count(*) from erp.app_user u, t where u.tenant_id = t.id and u.kind = 'service') as n) x
  union all
  select 'organisation.company'::text, (n >= 1), (case when n = 0 then 'no company yet' when n = 1 then 'one company' else n || ' companies' end)
    from (select (select count(*) from erp.entity e, t where e.tenant_id = t.id and e.status = 'active') as n) x
  union all
  select 'organisation.department'::text, (n >= 1), (case when n = 0 then 'no department yet' when n = 1 then 'one department' else n || ' departments' end)
    from (select (select count(*) from erp.department d, t where d.tenant_id = t.id and d.status = 'active') as n) x
  union all
  select 'organisation.membership'::text, (n >= 1), (case when n = 0 then 'nobody is in a department yet' when n = 1 then 'one person is in a department' else n || ' memberships' end)
    from (select (select count(*) from erp.principal_department m, t where m.tenant_id = t.id and m.status = 'active') as n) x
  union all
  select 'organisation.band'::text, (n >= 1), (case when n = 0 then 'no approval band yet' when n = 1 then 'one approval band' else n || ' approval bands' end)
    from (select (select count(*) from erp.approval_band b, t where b.tenant_id = t.id and b.status = 'active') as n) x
  union all
  select 'organisation.site'::text, (n >= 1), (case when n = 0 then 'no site yet' when n = 1 then 'one site' else n || ' sites' end)
    from (select (select count(*) from erp.site s, t where s.tenant_id = t.id and s.status = 'active') as n) x
  union all
  select 'organisation.location'::text, (n >= 1), (case when n = 0 then 'no location yet' when n = 1 then 'one location' else n || ' locations' end)
    from (select (select count(*) from erp.location l, t where l.tenant_id = t.id) as n) x
  union all
  select 'packs.features'::text, (n >= 1), (case when n = 0 then 'no feature is switched on yet' when n = 1 then 'one feature is on' else n || ' features are on' end)
    from (select (select count(*) from erp.tenant_capability c, t where c.tenant_id = t.id and c.is_enabled) as n) x
  union all
  select 'packs.base'::text, (n >= 1), (case when n = 0 then 'no pack has been applied yet' when n = 1 then 'one pack has been applied' else n || ' packs have been applied' end)
    from (select (select count(*) from erp.tenant_pack p, t where p.tenant_id = t.id and p.status = 'applied') as n) x
  union all
  select 'packs.decide'::text, (n >= 1), (case when n = 0 then 'no pack decision has been answered' when n = 1 then 'one pack decision has been answered' else n || ' pack decisions have been answered' end)
    from (select (select count(*) from erp.pack_decision d, t where d.tenant_id = t.id) as n) x
  union all
  select 'configuration.finance'::text, (n >= 1), (case when n = 0 then 'finance is not installed yet' when n = 1 then 'finance is installed' else n || ' finance installations' end)
    from (select (select count(*) from erp.module_installation m, t where m.tenant_id = t.id and m.module_code = 'finance') as n) x
  union all
  select 'configuration.modules'::text, (n >= 2), (case when n = 0 then 'no module is installed yet' when n = 1 then 'only one module is installed' else n || ' modules are installed' end)
    from (select (select count(*) from erp.module_installation m, t where m.tenant_id = t.id) as n) x
  union all
  select 'configuration.promote'::text, (n >= 1), (case when n = 0 then 'nothing has been promoted yet' when n = 1 then 'one change has been promoted' else n || ' changes have been promoted' end)
    from (select (select count(*) from erp.change_set c, t where c.tenant_id = t.id and c.status = 'promoted') as n) x
  union all
  select 'configuration.reason_codes'::text, (n >= 1), (case when n = 0 then 'no reason code yet' when n = 1 then 'one reason code' else n || ' reason codes' end)
    from (select (select count(*) from erp.reason_code r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'master_data.uom'::text, (n >= 1), (case when n = 0 then 'no unit of measure yet' when n = 1 then 'one unit of measure' else n || ' units of measure' end)
    from (select (select count(*) from erp.uom u, t where u.tenant_id = t.id and u.status = 'active') as n) x
  union all
  select 'master_data.partner'::text, (n >= 1), (case when n = 0 then 'no business partner yet' when n = 1 then 'one business partner' else n || ' business partners' end)
    from (select (select count(*) from erp.party p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'classification.axis'::text, (n >= 1), (case when n = 0 then 'no axis yet' when n = 1 then 'one axis' else n || ' axes' end)
    from (select (select count(*) from erp.classification_axis a, t where a.tenant_id = t.id and a.status = 'active') as n) x
  union all
  select 'classification.value'::text, (n >= 1), (case when n = 0 then 'no value yet' when n = 1 then 'one value' else n || ' values' end)
    from (select (select count(*) from erp.classification_value v, t where v.tenant_id = t.id and v.status = 'active') as n) x
  union all
  select 'classification.template'::text, (n >= 1), (case when n = 0 then 'no code template yet' when n = 1 then 'one code template' else n || ' code templates' end)
    from (select (select count(*) from erp.code_template c, t where c.tenant_id = t.id and c.status = 'active') as n) x
  union all
  select 'classification.product'::text, (n >= 1), (case when n = 0 then 'no product yet' when n = 1 then 'one product' else n || ' products' end)
    from (select (select count(*) from erp.item i, t where i.tenant_id = t.id) as n) x
  union all
  select 'item_supply.supplier'::text, (n >= 1), (case when n = 0 then 'no product has a supplier yet' when n = 1 then 'one product has a supplier' else n || ' product-supplier relationships' end)
    from (select (select count(*) from erp.item_supplier s, t where s.tenant_id = t.id) as n) x
  union all
  select 'warehouse.layout'::text, (n = 3), (case when n = 0 then 'no goods-in, bulk or pick location yet' when n = 3 then 'goods-in, bulk and pick locations exist' else n || ' of the three location kinds exist' end)
    from (select (select count(distinct l.location_type::text) from erp.location l, t where l.tenant_id = t.id and l.location_type::text in ('receiving', 'bulk', 'pick')) as n) x
  union all
  select 'warehouse.rules'::text, (n >= 1), (case when n = 0 then 'no storage rule yet' when n = 1 then 'one storage rule' else n || ' storage rules' end)
    from (select (select count(*) from erp.storage_rule r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'release_areas.area'::text, (n >= 1), (case when n = 0 then 'no marshalling area yet' when n = 1 then 'one marshalling area' else n || ' marshalling areas' end)
    from (select (select count(*) from erp.release_area a, t where a.tenant_id = t.id and a.status = 'active') as n) x
  union all
  select 'cost_centres.add'::text, (n >= 1), (case when n = 0 then 'no cost centre yet' when n = 1 then 'one cost centre' else n || ' cost centres' end)
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code = 'COST_CENTRE' and v.status = 'active') as n) x
  union all
  select 'dimensions.declare'::text, (n >= 1), (case when n = 0 then 'no dimension beyond cost centre yet' when n = 1 then 'one dimension beyond cost centre' else n || ' dimensions beyond cost centre' end)
    from (select (select count(*) from erp.dimension d, t where d.tenant_id = t.id and d.status = 'active' and d.code <> 'COST_CENTRE') as n) x
  union all
  select 'dimensions.values'::text, (n >= 1), (case when n = 0 then 'no dimension value yet' when n = 1 then 'one dimension value' else n || ' dimension values' end)
    from (select (select count(*) from erp.dimension_value v join erp.dimension d on d.tenant_id = v.tenant_id and d.id = v.dimension_id, t where v.tenant_id = t.id and d.code <> 'COST_CENTRE' and v.status = 'active') as n) x
  union all
  select 'dimensions.require'::text, (n >= 1), (case when n = 0 then 'no account requires a dimension yet' when n = 1 then 'one account requires a dimension' else n || ' accounts require a dimension' end)
    from (select (select count(*) from erp.account a, t where a.tenant_id = t.id and coalesce(cardinality(a.requires_dimensions), 0) > 0) as n) x
  union all
  select 'account_determination.codes'::text, (n >= 1), (case when n = 0 then 'no accounting code yet' when n = 1 then 'one accounting code' else n || ' accounting codes' end)
    from (select (select count(*) from erp.posting_class p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'account_determination.assign'::text, (n >= 1), (case when n = 0 then 'no product or partner has an accounting code yet' when n = 1 then 'one product or partner has an accounting code' else n || ' products and partners have an accounting code' end)
    from (select (select (select count(*) from erp.item_posting_class x, t where x.tenant_id = t.id) + (select count(*) from erp.party_posting_class y, t where y.tenant_id = t.id)) as n) x
  union all
  select 'account_determination.rules'::text, (n >= 1), (case when n = 0 then 'no determination rule yet' when n = 1 then 'one determination rule' else n || ' determination rules' end)
    from (select (select count(*) from erp.account_determination r, t where r.tenant_id = t.id) as n) x
  union all
  select 'output.printer'::text, (n >= 1), (case when n = 0 then 'no printer yet' when n = 1 then 'one printer' else n || ' printers' end)
    from (select (select count(*) from erp.printer p, t where p.tenant_id = t.id and p.status = 'active') as n) x
  union all
  select 'output.route'::text, (n >= 1), (case when n = 0 then 'no print route yet' when n = 1 then 'one print route' else n || ' print routes' end)
    from (select (select count(*) from erp.print_route r, t where r.tenant_id = t.id and r.status = 'active') as n) x
  union all
  select 'output.sender'::text, (n >= 1), (case when n = 0 then 'no sending domain yet' when n = 1 then 'one sending domain' else n || ' sending domains' end)
    from (select (select count(*) from erp.sender_identity s, t where s.tenant_id = t.id) as n) x
  union all
  select 'output.verify'::text, (n >= 1), (case when n = 0 then 'no sending domain is verified yet' when n = 1 then 'one sending domain is verified' else n || ' sending domains are verified' end)
    from (select (select count(*) from erp.sender_identity s, t where s.tenant_id = t.id and s.verified_at is not null) as n) x
  union all
  select 'devices.register'::text, (n >= 1), (case when n = 0 then 'no device yet' when n = 1 then 'one device' else n || ' devices' end)
    from (select (select count(*) from erp.device d, t where d.tenant_id = t.id and d.status = 'active') as n) x
  union all
  select 'devices.rules'::text, (n >= 1), (case when n = 0 then 'no scan rule yet' when n = 1 then 'one scan rule' else n || ' scan rules' end)
    from (select (select count(*) from erp.scan_rule r, t where r.tenant_id = t.id) as n) x
  union all
  select 'integrations.key'::text, (n >= 1), (case when n = 0 then 'no API key yet' when n = 1 then 'one API key' else n || ' API keys' end)
    from (select (select count(*) from erp.api_key k, t where k.tenant_id = t.id and k.revoked_at is null) as n) x
  union all
  select 'integrations.webhook'::text, (n >= 1), (case when n = 0 then 'no webhook yet' when n = 1 then 'one webhook' else n || ' webhooks' end)
    from (select (select count(*) from erp.webhook_subscription w, t where w.tenant_id = t.id) as n) x
  union all
  select 'jobs.define'::text, (n >= 1), (case when n = 0 then 'no recurring task yet' when n = 1 then 'one recurring task' else n || ' recurring tasks' end)
    from (select (select count(*) from erp.job j, t where j.tenant_id = t.id and j.handler_code not like 'notifications.%') as n) x
  union all
  select 'cutover.parallel'::text, (n >= 1), (case when n = 0 then 'no parallel-run figure yet' when n = 1 then 'one parallel-run figure' else n || ' parallel-run figures' end)
    from (select (select count(*) from erp.parallel_run_figure f, t where f.tenant_id = t.id) as n) x
  union all
  select 'cutover.cut'::text, (n >= 1), (case when n = 0 then 'no domain has been cut over yet' when n = 1 then 'one domain has been cut over' else n || ' domains have been cut over' end)
    from (select (select count(*) from erp.domain_cutover c, t where c.tenant_id = t.id and c.status = 'cut_over') as n) x
  union all
  select 'tenant.go_live'::text, (n >= 1), (case when n = 0 then 'not live yet: still in the setup window' else 'live' end)
    from (select (select count(*) from erp.environment e, t where e.tenant_id = t.id and e.is_self and e.is_live) as n) x
  union all
  select 'continuity.subscribe'::text, (n >= 1), (case when n = 0 then 'nobody is subscribed to incident notices' when n = 1 then 'one person is subscribed to incident notices' else n || ' people are subscribed to incident notices' end)
    from (select (select count(*) from erp.incident_subscription s, t where s.tenant_id = t.id and s.is_subscribed) as n) x
  union all
  select 'adoption.scenario'::text, (n >= 1), (case when n = 0 then 'no training scenario yet' when n = 1 then 'one training scenario' else n || ' training scenarios' end)
    from (select (select count(*) from erp.training_scenario s, t where s.tenant_id = t.id and s.status = 'active') as n) x
  union all
  select 'terminology.override'::text, (n >= 1), (case when n = 0 then 'no wording has been changed' when n = 1 then 'one word has been changed' else n || ' words have been changed' end)
    from (select (select count(*) from erp.resource_override o, t where o.tenant_id = t.id and o.status = 'active') as n) x
  union all
  select 'erasure.request'::text, (n >= 1), (case when n = 0 then 'no erasure has been requested' when n = 1 then 'one erasure has been requested' else n || ' erasures have been requested' end)
    from (select (select count(*) from erp.erasure_request r, t where r.tenant_id = t.id) as n) x
$reference$;

revoke all on function erp_test.setup_evidence_reference() from public, anon;

comment on function erp_test.setup_evidence_reference() is
  'erp.setup_evidence() as it was before 20261006071000, word for word: the evidence the setup progress must '
  'still give (J-38). Read only by erp_test.setup_evidence_counts_once_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Each step counted once, the organisation looked up once
-- ─────────────────────────────────────────────────────────────────────────────

do $evidence$
declare
  v_sig  constant text := 'erp.setup_evidence()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_head constant text := '  with t as (select erp.current_tenant_id() as id)';
  v_new_head constant text := $n$  -- The organisation is looked up once, each count compares with that one
  -- value, and each step is fenced so its count runs once however often its
  -- sentence reads it (20261006071000, J-38).
  with t as materialized (select erp.current_tenant_id() as id)$n$;
  v_join constant text := ', t where ([a-z_]+)\.tenant_id = t\.id';
  v_fence constant text := ' as n) x';
  v_joins  integer;
  v_fences integer;
begin
  if strpos(v_src, '20261006071000') > 0 then
    raise notice '% already counts each step once; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4b0a876e2ab441a957fecefdd81daa55' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006071000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_head, ''))) / length(v_head) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % organisation anchor found other than once', v_sig;
  end if;
  v_joins := regexp_count(v_def, v_join);
  v_fences := (length(v_def) - length(replace(v_def, v_fence, ''))) / length(v_fence);
  if v_joins <> 54 or v_fences <> 53 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % has % organisation join(s) and % step(s); 20261006071000 expects 54 and 53',
      v_sig, v_joins, v_fences;
  end if;
  v_def := replace(v_def, v_head, v_new_head);
  v_def := regexp_replace(v_def, v_join, ' where \1.tenant_id = (select t.id from t)', 'g');
  v_def := replace(v_def, v_fence, ' as n offset 0) x');
  execute v_def;
end
$evidence$;

comment on function erp.setup_evidence() is
  'Part 22. For every observable setup step, whether the organisation''s own tables say it was done, and a sentence '
  'saying what was looked at. With no organisation in context every branch reads nothing and says so. Each step is '
  'counted once and the organisation looked up once (20261006071000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.setup_evidence_counts_once_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 4;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  v_owner  text := current_user;
  rb       record;
  tn       record;
  v_step   text := 'every organisation in the database';
  v_state  text;
  v_orgs   integer := 0;
  v_differ text := '';
  v_done   integer := 0;
  v_n      integer;
  v_new    jsonb;
  v_ref    jsonb;
  v_src    text;
  v_line   text;
  v_initplans integer := 0;
  v_per_row   integer := 0;
  v_once      integer := 0;
begin
  begin
    -- ── 1. Every organisation already in the database ───────────────────────
    perform set_config('request.jwt.claims', '', true);
    for tn in select t.id, t.code from erp.tenant t where t.deleted_at is null order by t.code loop
      perform erp.set_job_tenant(tn.id);
      select count(*) into v_n
        from ((select * from erp.setup_evidence() except all select * from erp_test.setup_evidence_reference())
              union all
              (select * from erp_test.setup_evidence_reference() except all select * from erp.setup_evidence())) z;
      v_orgs := v_orgs + 1;
      v_done := v_done + (select count(*) from erp.setup_evidence() e where e.satisfied)::integer;
      if v_n > 0 then
        v_differ := v_differ || tn.code || ' (' || v_n || '); ';
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'every organisation in the database has the same setup evidence as before';
    passed := v_orgs >= 1 and v_differ = '';
    detail := format('%s organisation(s), %s step(s) done between them; differing: %s',
                     v_orgs, v_done, coalesce(nullif(v_differ, ''), 'none'));
    return next;

    -- ── 2. A demonstration, read by its administrator ──────────────────────
    v_step := 'a demonstration configured from nothing';
    select * into rb from erp.provision_tenant(
      'demo-zzse' || v_tag, 'Setup Evidence Suite', 'admin@demo-zzse' || v_tag || '.test', 'Evidence Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzse' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'the demonstration''s evidence read as the data API reads it';
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select jsonb_agg(to_jsonb(e) order by e.step_code) into v_new from erp.setup_evidence() e;
    execute format('set local role %I', v_owner);
    select jsonb_agg(to_jsonb(e) order by e.step_code) into v_ref from erp_test.setup_evidence_reference() e;
    select count(*) into v_n from jsonb_array_elements(v_new) x where (x ->> 'satisfied')::boolean;
    v_cases := v_cases + 1;
    case_name := 'a demonstration read by its administrator has the same evidence as before, done and not done';
    passed := v_new = v_ref and jsonb_array_length(v_new) = 53 and v_n between 1 and 52;
    detail := format('%s step(s), %s done%s', jsonb_array_length(v_new), v_n,
                     case when v_new = v_ref then '' else '; differs from before' end);
    return next;

    -- ── 3. Nobody in context ────────────────────────────────────────────────
    v_step := 'nobody in context';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    select jsonb_agg(to_jsonb(e) order by e.step_code) into v_new from erp.setup_evidence() e;
    select jsonb_agg(to_jsonb(e) order by e.step_code) into v_ref from erp_test.setup_evidence_reference() e;
    v_cases := v_cases + 1;
    case_name := 'with no organisation in context every step reads nothing, as before';
    passed := v_new = v_ref
          and not exists (select 1 from jsonb_array_elements(v_new) x where (x ->> 'satisfied')::boolean);
    detail := format('%s step(s), %s done%s', jsonb_array_length(v_new),
                     (select count(*) from jsonb_array_elements(v_new) x where (x ->> 'satisfied')::boolean),
                     case when v_new = v_ref then '' else '; differs from before' end);
    return next;

    -- ── 4. The plan, as the administrator ───────────────────────────────────
    v_step := 'planning the evidence as the administrator';
    select p.prosrc into v_src from pg_catalog.pg_proc p where p.oid = 'erp.setup_evidence()'::regprocedure;
    perform set_config('request.jwt.claims',
      json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    for v_line in execute 'explain ' || v_src loop
      if v_line ~ '^\s*InitPlan \d+' then
        v_initplans := v_initplans + 1;
      end if;
      if v_line ~ '(Filter|Index Cond|Recheck Cond):' and v_line !~ 'One-Time Filter'
         and v_line like '%erp.current_tenant_id()%' then
        v_per_row := v_per_row + 1;
      end if;
      if v_line ~ 'One-Time Filter' and v_line like '%erp.current_tenant_id()%' then
        v_once := v_once + 1;
      end if;
    end loop;
    execute format('set local role %I', v_owner);
    v_cases := v_cases + 1;
    case_name := 'each step is counted once and no row is filtered on who is asking';
    passed := v_per_row = 0 and v_once between 1 and 54 and v_initplans <= 110;
    detail := format('%s sub-plan(s) (218 before), %s row filter(s) on who is asking, %s one-time test(s)',
                     v_initplans, v_per_row, v_once);
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
    raise exception 'CLOVEERP_SETUP_EVIDENCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
end;
$$;

revoke all on function erp_test.setup_evidence_counts_once_suite() from public, anon;

comment on function erp_test.setup_evidence_counts_once_suite() is
  'Setup evidence counts each step once (20261006071000, J-38): the same evidence as the body it replaced for every '
  'organisation, for a demonstration read by its administrator and for nobody, and no row filtered on who is asking.';

create or replace function erp_test.assert_setup_evidence_counts_once_suite()
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
    from erp_test.setup_evidence_counts_once_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SETUP_EVIDENCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The setup progress would say otherwise than before, or ask who is signed in for every row again. Read the case that failed.';
  end if;
  if v_total <> 4 then
    raise exception 'CLOVEERP_SETUP_EVIDENCE_SUITE_SHRANK: % case(s), expected 4', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('setup evidence counts once: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_setup_evidence_counts_once_suite() from public, anon;

comment on function erp_test.assert_setup_evidence_counts_once_suite() is
  'The setup evidence is what it was, counted once (20261006071000).';

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
