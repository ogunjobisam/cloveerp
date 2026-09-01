-- =============================================================================
-- Starter Content Packs §13 — acceptance
--
-- "A new organisation, having chosen the Standard preset and bound one
-- legislation pack, can — without further configuration and without
-- engineering involvement — [seven things]."
--
-- And the sentence that decides the shape of this file:
--
--   "Anything requiring a value the pack did not provide and onboarding did not
--    ask for is a GAP IN THE PACK, LOGGED AGAINST THE PRODUCT."
--
-- So this is not only a pass/fail suite. It is a measurement, and its output is
-- a list of what an organisation cannot yet do and precisely what is missing.
-- Two things, therefore:
--
--   erp.pack_acceptance_report() answers "can THIS organisation do §13's seven
--   things, and if not, what is it short of?" — a read anybody can run against
--   a real organisation at any time, not only in a test.
--
--   erp_test.starter_pack_acceptance_suite() builds an organisation exactly as
--   §13 describes it, runs the seven clauses as far as they go, and asserts
--   what the pack claims to deliver.
--
-- The distinction from the twenty-five suites that already exercise these
-- flows is the precondition. Those build whatever configuration they need. This
-- one is forbidden to: Standard preset, base pack, one legislation pack, and
-- nothing else configured by hand.
-- =============================================================================

create or replace function erp.pack_acceptance_report(p_tenant_id uuid default null)
returns table (clause integer, requirement text, ready boolean, missing text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.current_tenant_id());
  v_missing text;
begin
  -- 1. Raise a requisition, route it through an approval band, convert it to a
  --    purchase order, receive goods within tolerance, and match a supplier
  --    invoice.
  v_missing := '';
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'requisition') then
    v_missing := v_missing || 'no requisition lifecycle; ';
  end if;
  if not exists (select 1 from erp.approval_band ab
                  where ab.tenant_id = v_tenant and ab.status = 'active'
                    and ab.object_type = 'requisition') then
    v_missing := v_missing || 'no approval band for a requisition; ';
  end if;
  if not exists (select 1 from erp.numbering_rule nr
                  where nr.tenant_id = v_tenant and nr.status = 'active'
                    and nr.code = 'requisition') then
    v_missing := v_missing || 'no requisition numbering rule; ';
  end if;
  if not exists (select 1 from erp.receipt_tolerance rt
                  where rt.tenant_id = v_tenant and rt.status = 'active') then
    v_missing := v_missing || 'no receipt tolerance; ';
  end if;
  if not exists (select 1 from erp.match_tolerance mt
                  where mt.tenant_id = v_tenant and mt.status = 'active') then
    v_missing := v_missing || 'no three-way match tolerance; ';
  end if;
  clause := 1;
  requirement := 'Raise a requisition, approve it through a band, convert to a '
                 'purchase order, receive within tolerance, match an invoice';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;

  -- 2. Every posting determined by rule with correct dimensions, and no
  --    suspense fallback. C1 already measures this, so this clause reads it
  --    rather than inventing a second answer.
  select string_agg(c.finding || ' (' || c.reference || ')', '; ')
    into v_missing
    from erp.determination_coverage_report(v_tenant) c;
  clause := 2;
  requirement := 'Every posting determined by rule, with no suspense fallback';
  ready := v_missing is null; missing := v_missing;
  return next;

  -- 3. Receive batch-controlled stock into quarantine, release it under named
  --    authority, and store it under container identity.
  v_missing := '';
  if not erp.capability_on(v_tenant, 'batch_control') then
    v_missing := v_missing || 'batch control is off; ';
  end if;
  if not erp.capability_on(v_tenant, 'quarantine_release') then
    v_missing := v_missing || 'quarantine and release is off; ';
  end if;
  -- §13 says "store it under container identity", and the Standard preset does
  -- not include container identity — §2.3 puts it in Full. That is a genuine
  -- disagreement inside the specification, and naming it is the point of this
  -- report rather than something to paper over.
  if not erp.capability_on(v_tenant, 'container_identity') then
    v_missing := v_missing ||
      'container identity is off, and §2.3 puts it in Full rather than Standard '
      'while §13 asks for it after Standard; ';
  end if;
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'batch') then
    v_missing := v_missing || 'no batch lifecycle; ';
  end if;
  if not exists (select 1 from erp.role r
                  join erp.role_permission rp
                    on rp.tenant_id = r.tenant_id and rp.role_id = r.id
                 where r.tenant_id = v_tenant and r.status = 'active'
                   and rp.permission_code = 'quality.release_batch') then
    v_missing := v_missing || 'no role may release a batch; ';
  end if;
  clause := 3;
  requirement := 'Receive batch-controlled stock into quarantine, release under '
                 'named authority, store under container identity';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;

  -- 4. Count without freezing operations, and post a variance within tolerance.
  v_missing := '';
  if not erp.capability_on(v_tenant, 'cycle_counting') then
    v_missing := v_missing || 'cycle counting is off; ';
  end if;
  if not exists (select 1 from erp.count_programme cp
                  where cp.tenant_id = v_tenant and cp.status = 'active') then
    v_missing := v_missing || 'no count programme, so no variance tolerance; ';
  end if;
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'count') then
    v_missing := v_missing || 'no count lifecycle; ';
  end if;
  if not exists (select 1 from erp.reason_code rc
                  where rc.tenant_id = v_tenant and rc.status = 'active'
                    and rc.category_code = 'STOCK_ADJUSTMENT') then
    v_missing := v_missing || 'no stock adjustment reasons; ';
  end if;
  clause := 4;
  requirement := 'Count without freezing operations, post a variance within tolerance';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;

  -- 5. Take a sales order, allocate globally then in detail, replenish a
  --    marshalling area, pick, despatch and invoice.
  v_missing := '';
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'sales_order') then
    v_missing := v_missing || 'no sales order lifecycle; ';
  end if;
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'allocation') then
    v_missing := v_missing || 'no allocation lifecycle; ';
  end if;
  if not erp.capability_on(v_tenant, 'release_areas') then
    v_missing := v_missing || 'marshalling areas are off; ';
  end if;
  if not exists (select 1 from erp.release_area ra
                  where ra.tenant_id = v_tenant and ra.status = 'active') then
    -- Not a pack gap: a marshalling area belongs to a site, and a site is an
    -- organisation's own. §11 lists no site in the pack for the same reason.
    v_missing := v_missing || 'no marshalling area configured for any site; ';
  end if;
  clause := 5;
  requirement := 'Sales order, global then detailed allocation, replenish a '
                 'marshalling area, pick, despatch, invoice';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;

  -- 6. Answer a recall question for any batch.
  v_missing := '';
  if not erp.capability_on(v_tenant, 'recall_management') then
    v_missing := v_missing ||
      'recall management is off, and §2.3 puts it in Full rather than Standard '
      'while §13 asks for it after Standard; ';
  end if;
  if not exists (select 1 from erp.state_machine m
                  where m.tenant_id = v_tenant and m.status = 'active'
                    and m.code = 'recall') then
    v_missing := v_missing || 'no recall lifecycle; ';
  end if;
  if not exists (select 1 from erp.report rp
                  where rp.tenant_id = v_tenant and rp.status = 'active'
                    and rp.code = 'recall_despatch_list') then
    v_missing := v_missing || 'no recall despatch list report; ';
  end if;
  clause := 6;
  requirement := 'Answer a recall question for any batch';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;

  -- 7. Close a period with suspense empty and every posting traced to its rule
  --    version.
  v_missing := '';
  if not exists (select 1 from erp.close_task_template ct
                  where ct.tenant_id = v_tenant and ct.status = 'active'
                    and ct.code = 'suspense_clear') then
    v_missing := v_missing || 'no suspense clearance task on the close checklist; ';
  end if;
  if (select count(*) from erp.close_task_template ct
       where ct.tenant_id = v_tenant and ct.status = 'active') < 11 then
    v_missing := v_missing || format('the close checklist has %s tasks and §8.4 lists 11; ',
      (select count(*) from erp.close_task_template ct
        where ct.tenant_id = v_tenant and ct.status = 'active'));
  end if;
  clause := 7;
  requirement := 'Close a period with suspense empty and every posting traced '
                 'to its rule version';
  ready := v_missing = ''; missing := nullif(v_missing, '');
  return next;
end;
$$;

comment on function erp.pack_acceptance_report is
  '§13''s seven clauses, measured against what this organisation actually has. '
  'Its last sentence — "anything requiring a value the pack did not provide is '
  'a gap in the pack, logged against the product" — is why this exists as a '
  'report rather than only as a test: a gap is a finding, and a finding needs '
  'somewhere to be read.';

create or replace function public.erp_pack_acceptance()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'clause', r.clause, 'requirement', r.requirement,
           'ready', r.ready, 'missing', r.missing) order by r.clause), '[]'::jsonb)
    from erp.pack_acceptance_report() r
$$;

do $$
begin
  execute 'revoke all on function public.erp_pack_acceptance() from public, anon';
  execute 'grant execute on function public.erp_pack_acceptance() to authenticated';
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('pack_acceptance', 'Starter pack acceptance', 'report', 'tenant',
        'pack_acceptance_report', '', null, '',
        '§13''s seven clauses measured against this organisation, naming what '
        'each is short of. A report because §13 says a shortfall is a gap '
        'logged against the product, not a build failure.', false, 28)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

-- ── A route for §2.1's own requirement ───────────────────────────────────────
--
-- Building §13's organisation found this immediately: erp.apply_preset()
-- raised ERPWARE_LIVE_CONFIG_EDIT on erp.tenant_capability.
--
-- The guard is right. §2.1 says capabilities are "switched through a change set
-- like any other configuration", and registering erp.tenant_capability as a
-- promotable surface is what makes that true. What was missing is the other
-- half: erp.provision_tenant() marks the self environment live from the
-- moment an organisation exists, so the guard bites immediately and there was
-- no promotion route to take instead. Every organisation could read the
-- capability catalogue and none could change it.
--
-- So: a proposal. erp.propose_preset() and erp.propose_capability_change()
-- build a change set carrying capability items, which is exactly what §2.1
-- asks for and what erp.apply_change_set_item()'s capability branch already
-- knows how to apply. erp.apply_preset() and erp.set_capability() route
-- through them when the environment is live and write directly when it is not,
-- so onboarding stays one call and a live change is governed.

create or replace function erp.propose_capability_change(
  p_code text, p_enabled boolean, p_reason text default null,
  p_change_set_code text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_cs uuid; v_code text;
begin
  if not exists (select 1 from erp_ref.capability where code = p_code) then
    raise exception 'ERPWARE_UNKNOWN_CAPABILITY: % is not a capability this product has',
      p_code using errcode = '23503';
  end if;
  v_code := coalesce(p_change_set_code,
    format('cap-%s-%s', p_code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));
  v_cs := erp.create_change_set(v_code,
    format('%s %s', case when p_enabled then 'Enable' else 'Disable' end, p_code),
    coalesce(p_reason, 'Capability change'));
  perform erp.add_change_set_item(v_cs, 'capability', p_code,
    jsonb_build_object('code', p_code, 'enabled', p_enabled,
                       'reason', coalesce(p_reason, 'Capability change')),
    'upsert', null, p_reason);
  return v_cs;
end;
$$;

create or replace function erp.propose_preset(
  p_code text, p_reason text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_cs uuid; r record; n integer := 0;
begin
  if not exists (select 1 from erp_ref.preset where code = p_code) then
    raise exception 'ERPWARE_UNKNOWN_PRESET: %', p_code using errcode = '23503';
  end if;

  v_cs := erp.create_change_set(
    format('preset-%s-%s', p_code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')),
    format('Apply the %s preset', p_code),
    coalesce(p_reason, format('Everything the %s preset selects, in dependency '
                              'order so a prerequisite lands before what needs it.',
                              p_code)));

  -- The same recursive ordering erp.apply_preset() uses, for the same reason:
  -- a change set that enables expiry control before batch control is a change
  -- set that fails half way through.
  for r in
    with recursive depth as (
      select pc.capability_code, 0 as d
        from erp_ref.preset_capability pc
       where pc.preset_code = p_code
         and not exists (select 1 from erp_ref.capability_dependency x
                          where x.capability_code = pc.capability_code)
      union all
      select pc.capability_code, depth.d + 1
        from erp_ref.preset_capability pc
        join erp_ref.capability_dependency cd on cd.capability_code = pc.capability_code
        join depth on depth.capability_code = cd.requires_code
       where pc.preset_code = p_code and depth.d < 8
    )
    select capability_code, max(d) as d from depth group by 1 order by 2, 1
  loop
    -- Only what is missing, as §11.7 wants of a pack and as anybody reading a
    -- diff wants of a change set.
    if not erp.capability_enabled(r.capability_code) then
      perform erp.add_change_set_item(v_cs, 'capability', r.capability_code,
        jsonb_build_object('code', r.capability_code, 'enabled', true,
                           'reason', format('Applied with the %s preset', p_code)),
        'upsert', null, p_code);
      n := n + 1;
    end if;
  end loop;

  if n = 0 then
    raise exception 'ERPWARE_PRESET_ALREADY_APPLIED: every capability the % preset selects is already on',
      p_code using errcode = '23505';
  end if;
  return v_cs;
end;
$$;

create or replace function erp.environment_is_live()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select e.is_live from erp.environment e
                    where e.tenant_id = erp.require_tenant_id() and e.is_self), false)
$$;

create or replace function erp.apply_preset(p_code text, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_applied text[] := '{}';
  r record;
begin
  if not exists (select 1 from erp_ref.preset where code = p_code) then
    raise exception 'ERPWARE_UNKNOWN_PRESET: %', p_code using errcode = '23503';
  end if;

  -- Live: §2.1's own route. The caller gets a change set to preview and
  -- promote rather than a refusal from a trigger.
  if erp.environment_is_live() then
    return jsonb_build_object(
      'preset', p_code,
      'change_set_id', erp.propose_preset(p_code, p_reason),
      'route', 'change_set',
      'note', 'This organisation is live, so §2.1 applies: capabilities are '
              'switched through a change set. Preview it, then promote it.');
  end if;

  for r in
    with recursive depth as (
      select pc.capability_code, 0 as d
        from erp_ref.preset_capability pc
       where pc.preset_code = p_code
         and not exists (select 1 from erp_ref.capability_dependency x
                          where x.capability_code = pc.capability_code)
      union all
      select pc.capability_code, depth.d + 1
        from erp_ref.preset_capability pc
        join erp_ref.capability_dependency cd on cd.capability_code = pc.capability_code
        join depth on depth.capability_code = cd.requires_code
       where pc.preset_code = p_code and depth.d < 8
    )
    select capability_code, max(d) as d from depth group by 1 order by 2, 1
  loop
    perform erp.set_capability(r.capability_code, true,
      coalesce(p_reason, format('Applied with the %s preset', p_code)));
    v_applied := v_applied || r.capability_code;
  end loop;

  return jsonb_build_object('preset', p_code, 'enabled', to_jsonb(v_applied),
                            'count', cardinality(v_applied), 'route', 'direct');
end;
$$;

create or replace function public.erp_set_capability(
  p_code text, p_enabled boolean, p_reason text default null,
  p_valid_from date default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  if erp.environment_is_live() then
    return jsonb_build_object(
      'capability', p_code, 'enabled', p_enabled,
      'change_set_id', erp.propose_capability_change(p_code, p_enabled, p_reason),
      'route', 'change_set',
      'note', 'This organisation is live, so §2.1 applies: a capability is '
              'switched through a change set. Preview it, then promote it.');
  end if;
  return erp.set_capability(p_code, p_enabled, p_reason, p_valid_from)
         || jsonb_build_object('route', 'direct');
end;
$$;

create or replace function public.erp_apply_preset(
  p_code text, p_reason text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.apply_preset(p_code, p_reason);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_set_capability(text, boolean, text, date)',
    'public.erp_apply_preset(text, text)',
    'public.erp_pack_acceptance()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

select erp.assert_public_api_safe();
select erp.assert_capabilities_sound();
select erp.assert_diagnostics_registered();

-- ── What the acceptance report found about the specification ─────────────────
--
-- Run against an organisation built exactly as §13 describes — Standard preset,
-- base pack, one legislation pack, nothing else — four of the seven clauses
-- are ready and three are not. One of the three is not a gap at all: clause 5
-- wants a marshalling area, and a marshalling area belongs to a site, which is
-- an organisation's own and not pack content.
--
-- The other two are the specification disagreeing with itself.

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'standard_preset_vs_acceptance',
  '§13 asks the Standard preset for two capabilities §2.3 puts in Full',
  'Starter Content Packs §2.3 and §13',
  'Neither §2.3 nor §13 is changed. erp.pack_acceptance_report() names the '
  'contradiction on any organisation where it bites.',
  '§13 says a new organisation "having chosen the Standard preset" can '
  '"receive batch-controlled stock into quarantine, release it under named '
  'authority, and store it under CONTAINER IDENTITY" and can "answer a RECALL '
  'question for any batch". §2.3 lists container identity and recall under '
  'Full, and Standard as "Minimal plus batch and expiry control, counting, '
  'approval routing, quality inspection, landed cost, release areas". Both '
  'readings are defensible: §13 may be describing Full, or Standard may be '
  'meant to carry both. Choosing silently would either widen a preset the '
  'specification defines or fail an acceptance clause the specification '
  'states, and both are decisions about the product.',
  'open',
  'On an organisation with the Standard preset and the base pack, clauses 1, '
  '2, 4 and 7 are ready; clause 3 is short of container identity only, and '
  'clause 6 of recall management only. Applying the Full preset makes both '
  'ready with no other change, which is what identifies the preset rather than '
  'the pack as the cause.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;

-- ── The suite ────────────────────────────────────────────────────────────────
--
-- Twenty-five suites already exercise these flows. What makes this one
-- different is its precondition: it is forbidden to configure anything by
-- hand. Standard preset, base pack, one legislation pack, and whatever the
-- module installers do — nothing else. That is §13's own sentence, and the
-- only way to find out whether it is true.

create or replace function erp_test.starter_pack_acceptance_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path to ''
as $$
declare
  a1 uuid := gen_random_uuid();   -- the author
  a2 uuid := gen_random_uuid();   -- the approver, because B6 refuses self-approval
  r         record;
  c         record;
  res       jsonb;
  v_cs      uuid;
  v_tok     text;
  v_second  uuid;
  d         record;
  i         integer := 0;
  n         integer;
  v_ok      boolean; v_msg text;
  v_ready   integer;
begin
  select * into r from erp.provision_tenant(
    'zz13', 'Acceptance', 'admin@zz13.test', 'Suite Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  res := public.erp_invite_principal('second@zz13.test', 'Second Admin');
  v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

  -- The modules. Installing one is not "further configuration" in §13's sense
  -- — it is what gives the product a procurement flow to configure at all —
  -- and the pack presupposes them: a requisition lifecycle comes from
  -- erp.configure_procurement(), not from erp_ref.pack_item.
  perform erp.configure_finance();
  perform erp.configure_procurement(1000000);
  perform erp.configure_sales();
  perform erp.configure_inventory();
  perform erp.configure_quality();
  perform erp.configure_logistics();
  perform erp.configure_period_close();
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  for c in select cs.id from erp.change_set cs
            where cs.tenant_id = r.tenant_id and cs.status = 'ready'
            order by cs.created_at loop
    perform erp.approve_change_set(c.id);
    perform erp.promote_change_set(c.id);
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- ── §2.1's route ────────────────────────────────────────────────────────

  res := erp.apply_preset('standard');
  return query select 'a live organisation switches capabilities through a change set',
    (res ->> 'route') = 'change_set' and (res ->> 'change_set_id') is not null,
    'erp.provision_tenant() marks the self environment live immediately, so '
    'the promotable-surface guard bites from the first day — and before this '
    'there was no promotion route to take instead, which left every '
    'organisation able to read the capability catalogue and none able to '
    'change it';

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) into n from erp.tenant_capability tc
   where tc.tenant_id = r.tenant_id and tc.is_enabled and tc.valid_to is null;
  return query select 'and promoting it switches on what the preset selects',
    n = 9, format('%s capabilities on after the Standard preset', n);

  -- ── §11, applied ────────────────────────────────────────────────────────

  res := erp.apply_content_pack('base');
  v_cs := (res ->> 'change_set_id')::uuid;
  return query select 'the base pack plans only what the capabilities allow',
    (res ->> 'items')::integer = 322
      and jsonb_array_length(res -> 'advisories') = 6,
    format('%s of %s items, %s advisories naming the capabilities that held the rest back',
           res ->> 'items',
           (select count(*) from erp_ref.pack_item where pack_code = 'base'),
           jsonb_array_length(res -> 'advisories'));

  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'a pack promoted with twelve decisions unanswered';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_DECISIONS_OUTSTANDING%'; v_msg := left(sqlerrm, 58);
  end;
  return query select 'promotion refuses while a required decision remains', v_ok, v_msg;
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  for d in select * from erp.pack_decisions('base') where not answered loop
    i := i + 1;
    perform erp.answer_pack_decision('base', d.object_kind, d.object_key,
      jsonb_build_object('upper_bound_minor', i * 500000));
  end loop;
  return query select 'and §3.4''s twelve approval bands are all of them',
    i = 12, format('%s decisions, every one an approval threshold', i);

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select 'the answer lands, not the pack''s placeholder',
    (select ab.upper_bound_minor from erp.approval_band ab
      join erp.department dp on dp.id = ab.department_id
     where ab.tenant_id = r.tenant_id and dp.code = 'PROC'
       and ab.object_type = 'requisition' and ab.seq = 1) is not null,
    'a band whose threshold is still null is a chain that approves everything';

  -- ── §13's seven clauses ─────────────────────────────────────────────────

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'four of §13''s seven clauses hold after Standard and the base pack',
    v_ready = 4,
    format('%s of 7 ready with nothing configured by hand', v_ready);

  return query select 'clauses 1, 2, 4 and 7 are the four',
    (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
      where clause in (1, 2, 4, 7)),
    'requisition to invoice; determination with no suspense fallback; count '
    'and variance; period close';

  return query select 'clause 3 is short of container identity and nothing else',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      like 'container identity is off%'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      not like '%batch%',
    '§13 asks the Standard preset for container identity and §2.3 puts it in Full';

  return query select 'clause 6 is short of recall management and the report it gates',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      like 'recall management is off%',
    '§13 asks the Standard preset for a recall answer and §2.3 puts recall in Full';

  return query select 'clause 5''s gap is a site''s, not the pack''s',
    (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 5)
      = 'no marshalling area configured for any site; ',
    'a marshalling area belongs to a site, and a site is an organisation''s own '
    '— §11 lists none in a pack for the same reason';

  -- ── The Full preset closes both, which is what names the cause ──────────

  res := erp.apply_preset('full');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  res := erp.apply_content_pack('base');
  return query select 're-applying the base pack plans exactly what was held back',
    (res ->> 'items')::integer = 13,
    format('%s items — §11.7''s "a tenant that skipped manufacturing at '
           'onboarding can add it later, and the change set contains only what '
           'is missing"', res ->> 'items');

  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select count(*) filter (where ready) into v_ready
    from erp.pack_acceptance_report(r.tenant_id);
  return query select 'the Full preset closes clauses 3 and 6 and nothing else changes',
    v_ready = 6
      and (select bool_and(ready) from erp.pack_acceptance_report(r.tenant_id)
            where clause in (3, 6)),
    format('%s of 7 ready; only clause 5 remains, and it wants a site', v_ready);

  return query select 'and a third application plans nothing at all',
    (select count(*) from erp.plan_content_pack('base')) = 0,
    'additive, per §11.7';

  -- ── §10, over the base ──────────────────────────────────────────────────

  begin
    perform erp.apply_content_pack('outsourced_logistics');
    v_ok := false; v_msg := 'a profile pack applied with its capability off';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PACK_CONFLICT%'
        and sqlerrm like '%third_party_custody%';
    v_msg := left(sqlerrm, 58);
  end;
  return query select 'a profile pack whose capability is off is refused by name',
    v_ok, v_msg;

  res := erp.apply_content_pack('manufacturing');
  return query select 'and one whose capability is on applies over the base',
    (res ->> 'items')::integer = 13, format('%s items', res ->> 'items');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  return query select '§10''s five works order types all land',
    (select count(*) from erp.classification_value cv
       join erp.classification_axis ca on ca.id = cv.axis_id
      where cv.tenant_id = r.tenant_id and ca.code = 'WORKS_ORDER_TYPE'
        and cv.status = 'active') = 5,
    'production, assembly, kitting, rework, repack';

  return query select '§11.6: the organisation records which packs it holds, and at which version',
    (select count(*) from erp.tenant_pack tp
      where tp.tenant_id = r.tenant_id and tp.status = 'applied') = 3
    and (select bool_and(tp.version = '1.0.0') from erp.tenant_pack tp
          where tp.tenant_id = r.tenant_id and tp.status = 'applied'),
    'base twice and manufacturing once, each with its version';

  -- ── §12, checkable rather than trusted ──────────────────────────────────

  return query select 'every pack value states where it came from',
    not exists (select 1 from erp_ref.pack_item where length(provenance) <= 20)
    and not exists (select 1 from erp_ref.content_pack where length(provenance) <= 30),
    '§12: "every value carries a provenance note naming the standard or '
    'practice it derives from, so the review is checkable rather than trusted"';

  -- Cleanup, so the next suite starts from the schema rather than from this.
  perform set_config('erp.purge_tenant_id', r.tenant_id::text, true);
  delete from erp.tenant where id = r.tenant_id;
  perform set_config('erp.purge_tenant_id', '', true);
  delete from auth.users where id in (a1, a2);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'a suite that leaves an organisation makes the next one measure this one';
end;
$$;

-- The suite asserts its own case count, like the twenty-five before it. A suite
-- that loses a case reports success.

-- The suite asserts its own case count, like the twenty-five before it. A suite
-- that loses a case reports success.
--
-- Six on §2.1's route and §11's flow, five on §13's seven clauses, three on the
-- Full preset closing two of them, three on §10 and §11.6, one on §12's
-- provenance, and the cleanup.

create or replace function erp_test.assert_starter_pack_acceptance()
returns text
language plpgsql
set search_path to ''
as $$
declare
  v_pass integer; v_total integer; v_detail text;
  c_expected constant integer := 20;
begin
  create temporary table if not exists zz_acceptance_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_acceptance_result;
  insert into zz_acceptance_result select * from erp_test.starter_pack_acceptance_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_pass, v_total, v_detail from zz_acceptance_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_ACCEPTANCE_SUITE_INCOMPLETE: % cases, expected %',
      v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_ACCEPTANCE_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('starter pack acceptance: %s/%s', v_pass, v_total);
end $$;

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_diagnostics_registered();
select erp.assert_capabilities_sound();
select erp.assert_packs_installable();

select erp_test.assert_starter_pack_acceptance();
