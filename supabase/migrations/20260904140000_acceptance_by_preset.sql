-- =============================================================================
-- §13 measured against the preset it means
--
-- The acceptance report was written to name a disagreement it could not
-- settle: §13 says an organisation "having chosen the Standard preset" can
-- answer a recall question and store stock under container identity, and §2.3
-- puts both capabilities in Full. So two of the seven clauses read as gaps on
-- an organisation that had done exactly what §13 told it to do, with prose in
-- the `missing` column explaining that the specification argues with itself.
--
-- That is settled now: §13 means Full. §2.3 keeps its tiers and §13 keeps its
-- seven clauses; what changes is that the report says which preset each clause
-- needs instead of treating a Full-tier capability as a fault.
--
-- The way it says so is the point. The clause-to-capability mapping moves out
-- of the function body and into erp_ref.acceptance_clause, and the preset each
-- clause needs is DERIVED from erp_ref.preset_capability rather than asserted
-- in a sentence. Move container identity into Standard tomorrow and the report
-- follows on its own; before this it would have gone on quoting §2.3 at a
-- reader looking at a table that no longer said that.
-- =============================================================================

create table if not exists erp_ref.acceptance_clause (
  clause         integer primary key,
  requirement    text not null,
  -- The capabilities the clause cannot be answered without. Data, so that
  -- erp.assert_acceptance_clauses_sound() can check every one of them exists
  -- and is reachable by choosing some preset — a clause whose capability is in
  -- no preset is a clause no organisation can ever satisfy, and the old
  -- hardcoded version could not have noticed.
  capabilities   text[] not null default '{}',
  spec_reference text not null,
  seq            integer not null default 100
);

-- Product content, like every other erp_ref catalogue: identical for every
-- organisation, readable by all, written only by a migration. Registering it
-- is not paperwork — erp.apply_row_security() generates the policies FROM this
-- register, and erp.assert_isolation() failed the build over the table until
-- it was there, which is the whole arrangement working.
select erp_meta.register_table('erp_ref', 'acceptance_clause', 'product_content',
  '§13''s seven acceptance clauses and the capabilities each needs.');

comment on table erp_ref.acceptance_clause is
  '§13''s seven acceptance clauses, and the capabilities each one needs. Read '
  'by erp.pack_acceptance_report() and policed by '
  'erp.assert_acceptance_clauses_sound(): a clause naming a capability that no '
  'preset carries can never hold, however the organisation is configured.';

insert into erp_ref.acceptance_clause (clause, requirement, capabilities, spec_reference, seq)
values
  (1, 'Raise a requisition, approve it through a band, convert to a '
      'purchase order, receive within tolerance, match an invoice',
      '{}', '§13.1', 10),
  (2, 'Every posting determined by rule, with no suspense fallback',
      '{}', '§13.2', 20),
  (3, 'Receive batch-controlled stock into quarantine, release under '
      'named authority, store under container identity',
      '{batch_control,quarantine_release,container_identity}', '§13.3', 30),
  (4, 'Count without freezing operations, post a variance within tolerance',
      '{cycle_counting}', '§13.4', 40),
  (5, 'Sales order, global then detailed allocation, replenish a '
      'marshalling area, pick, despatch, invoice',
      '{release_areas}', '§13.5', 50),
  (6, 'Answer a recall question for any batch',
      '{recall_management}', '§13.6', 60),
  (7, 'Close a period with suspense empty and every posting traced '
      'to its rule version',
      '{}', '§13.7', 70)
on conflict (clause) do update set
  requirement = excluded.requirement, capabilities = excluded.capabilities,
  spec_reference = excluded.spec_reference, seq = excluded.seq;

-- -----------------------------------------------------------------------------
-- The lowest preset that carries a set of capabilities
-- -----------------------------------------------------------------------------

create or replace function erp.lowest_preset_for(p_capabilities text[])
returns text
language sql
stable
set search_path = ''
as $$
  -- An empty requirement is carried by the lowest preset there is: nothing to
  -- switch on means nothing to choose. A requirement no preset covers returns
  -- null, which is what assert_acceptance_clauses_sound() refuses.
  select p.code
    from erp_ref.preset p
   where not exists (
     select 1 from unnest(coalesce(p_capabilities, '{}')) as need(code)
      where not exists (
        select 1 from erp_ref.preset_capability pc
         where pc.preset_code = p.code and pc.capability_code = need.code))
   order by p.seq
   limit 1;
$$;

comment on function erp.lowest_preset_for is
  'The cheapest preset an organisation could choose that carries every one of '
  'these capabilities, derived from erp_ref.preset_capability rather than '
  'restated. Null when no preset carries them all.';

-- -----------------------------------------------------------------------------
-- The report
--
-- Same seven clauses, one new column, and one changed idea: a capability that
-- is off is reported as a capability that is off, with the preset that would
-- turn it on. §13's last sentence — "anything requiring a value the pack did
-- not provide is a gap in the pack, logged against the product" — still holds
-- for everything else the clause needs, which is where the structural checks
-- below stay. A preset the organisation has not chosen is not a gap in a pack.
-- -----------------------------------------------------------------------------

drop function if exists erp.pack_acceptance_report(uuid);

create or replace function erp.pack_acceptance_report(p_tenant_id uuid default null)
returns table (clause integer, requirement text, needs_preset text,
               ready boolean, missing text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.current_tenant_id());
  v_missing text;
  c         erp_ref.acceptance_clause%rowtype;
  cap       text;
begin
  for c in select * from erp_ref.acceptance_clause order by seq loop
    clause := c.clause;
    requirement := c.requirement;
    needs_preset := erp.lowest_preset_for(c.capabilities);
    v_missing := '';

    -- Capabilities first, and uniformly. Every clause's capability shortfall
    -- is named the same way and carries the preset that would answer it, so a
    -- reader can tell a switch from a gap without knowing §2.3 by heart.
    foreach cap in array c.capabilities loop
      if not erp.capability_on(v_tenant, cap) then
        v_missing := v_missing || format('%s is off (in the %s preset); ',
          coalesce((select cp.title from erp_ref.capability cp where cp.code = cap), cap),
          coalesce(initcap(erp.lowest_preset_for(array[cap])), 'no'));
      end if;
    end loop;

    -- A capability that is off stops the clause here, and this is the second
    -- thing the register made possible. The base pack gates its own items on
    -- capabilities — the recall despatch list is a pack item marked
    -- requires_capability = recall_management — so with the capability off,
    -- those items were deliberately not installed. Listing them as further
    -- shortfalls reports one choice as several problems, and reads as a pack
    -- gap when it is a preset nobody chose. So: name the capability and the
    -- preset that carries it, and measure the rest once it is on.
    if v_missing <> '' then
      ready := false; missing := v_missing;
      return next;
      continue;
    end if;

    -- Then what the pack itself was supposed to provide. These are the checks
    -- §13's last sentence is about.
    if c.clause = 1 then
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

    elsif c.clause = 2 then
      -- C1 already measures this, so the clause reads it rather than inventing
      -- a second answer.
      v_missing := v_missing || coalesce(
        (select string_agg(d.finding || ' (' || d.reference || ')', '; ')
           from erp.determination_coverage_report(v_tenant) d), '');

    elsif c.clause = 3 then
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

    elsif c.clause = 4 then
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

    elsif c.clause = 5 then
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
      if not exists (select 1 from erp.release_area ra
                      where ra.tenant_id = v_tenant and ra.status = 'active') then
        -- Not a pack gap: a marshalling area belongs to a site, and a site is
        -- an organisation's own. §11 lists no site in the pack for the same
        -- reason.
        v_missing := v_missing || 'no marshalling area configured for any site; ';
      end if;

    elsif c.clause = 6 then
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

    elsif c.clause = 7 then
      if not exists (select 1 from erp.close_task_template ct
                      where ct.tenant_id = v_tenant and ct.status = 'active'
                        and ct.code = 'suspense_clear') then
        v_missing := v_missing || 'no suspense clearance task on the close checklist; ';
      end if;
      if (select count(*) from erp.close_task_template ct
           where ct.tenant_id = v_tenant and ct.status = 'active') < 11 then
        v_missing := v_missing || format(
          'the close checklist has %s tasks and §8.4 lists 11; ',
          (select count(*) from erp.close_task_template ct
            where ct.tenant_id = v_tenant and ct.status = 'active'));
      end if;
    end if;

    ready := v_missing = ''; missing := nullif(v_missing, '');
    return next;
  end loop;
end;
$$;

comment on function erp.pack_acceptance_report is
  '§13''s seven clauses, measured against what this organisation actually has, '
  'and against the preset each clause needs rather than against the one §13 '
  'happens to mention. A capability that is off names the preset that carries '
  'it; everything else a clause is short of is a gap in the pack, which is '
  'what §13''s last sentence asks to be logged against the product.';

create or replace function public.erp_pack_acceptance()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'clause', r.clause, 'requirement', r.requirement,
           'needs_preset', r.needs_preset,
           'ready', r.ready, 'missing', r.missing) order by r.clause), '[]'::jsonb)
    from erp.pack_acceptance_report() r;
$$;

comment on function public.erp_pack_acceptance is
  'The acceptance report for the calling organisation. Carries needs_preset so '
  'a clause that is short of a capability reads as a choice not yet made '
  'rather than as a fault.';

-- -----------------------------------------------------------------------------
-- The assertion
-- -----------------------------------------------------------------------------

create or replace function erp.assert_acceptance_clauses_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_detail text := '';
  v_src   text;
  r record;
begin
  v_src := pg_catalog.pg_get_functiondef('erp.pack_acceptance_report(uuid)'::regprocedure);

  -- 1. Seven, because §13 lists seven. A clause that quietly leaves the
  --    register stops being measured and nothing else says so.
  if (select count(*) from erp_ref.acceptance_clause) <> 7 then
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  the register holds %s clauses and §13 lists 7\n',
      (select count(*) from erp_ref.acceptance_clause));
  end if;

  -- 2. Every capability a clause names is in the catalogue. A misspelling here
  --    reads as "switched off" for ever, so the clause never holds and the
  --    reason given is a capability nobody can find.
  for r in
    select ac.clause, need.code
      from erp_ref.acceptance_clause ac,
           unnest(ac.capabilities) as need(code)
     where not exists (select 1 from erp_ref.capability c where c.code = need.code)
     order by 1, 2
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  clause %s needs capability %s, which is not in the catalogue\n',
      r.clause, r.code);
  end loop;

  -- 3. And every clause is reachable by CHOOSING something. This is the check
  --    the hardcoded version could not have made: a capability that belongs to
  --    no preset makes its clause impossible for every organisation, however
  --    configured, and the report would have gone on politely listing it as
  --    switched off.
  for r in
    select ac.clause, ac.capabilities from erp_ref.acceptance_clause ac
     where ac.capabilities <> '{}'
       and erp.lowest_preset_for(ac.capabilities) is null
     order by 1
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  clause %s needs %s, and no preset carries all of them — no '
       'organisation can satisfy it\n', r.clause, array_to_string(r.capabilities, ', '));
  end loop;

  -- 4. The report handles every clause the register holds. Adding a clause to
  --    the register without a branch would produce a row that is ready because
  --    nothing was checked, which is worse than a missing row.
  for r in
    select ac.clause from erp_ref.acceptance_clause ac
     where position(format('c.clause = %s', ac.clause) in v_src) = 0
     order by 1
  loop
    v_count := v_count + 1;
    v_detail := v_detail || format(
      E'  clause %s is registered and erp.pack_acceptance_report() has no '
       'branch for it, so it would report ready without being measured\n', r.clause);
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_ACCEPTANCE_CLAUSES_UNSOUND: % finding(s)\n%',
      v_count, v_detail using errcode = '23514';
  end if;

  return format('acceptance clauses: %s registered, %s needing Standard, %s needing Full',
    (select count(*) from erp_ref.acceptance_clause),
    (select count(*) from erp_ref.acceptance_clause ac
      where erp.lowest_preset_for(ac.capabilities) = 'standard'),
    (select count(*) from erp_ref.acceptance_clause ac
      where erp.lowest_preset_for(ac.capabilities) = 'full'));
end;
$$;

comment on function erp.assert_acceptance_clauses_sound is
  'Seven clauses, every capability they name in the catalogue, every clause '
  'reachable by choosing some preset, and a branch in the report for each. The '
  'third is the one that needed a register: a capability in no preset makes '
  'its clause impossible for everybody and reads exactly like one switched off.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values ('acceptance_clauses', 'Acceptance clauses sound', 'assertion', 'platform',
        'assert_acceptance_clauses_sound', '', null, '',
        '§13''s seven clauses are registered, name capabilities that exist, and '
        'are each reachable by choosing some preset.', true, 31)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind,
  scope = excluded.scope, runs_in_ci = excluded.runs_in_ci;

-- -----------------------------------------------------------------------------
-- The suite
--
-- Both functions are DUMPED from the built schema and patched, not retyped.
-- Two cases change and one is added; everything else is the definition that
-- was already running.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION erp_test.starter_pack_acceptance_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
    -- 326, not the 322 this case was written with: 20260904100000 added
    -- §9.1's four remaining scheduled jobs to the base pack, and they are
    -- gated on nothing, so they plan. The number is hardcoded on purpose —
    -- it is what makes a pack that grows by accident fail the build — so a
    -- deliberate growth updates it and says which four items moved it.
    (res ->> 'items')::integer = 326
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

  -- The two clauses §13 describes after "having chosen the Standard preset"
  -- and §2.3 puts in Full. Settled as: §13 means Full. The report says which
  -- preset each clause needs, derived from erp_ref.preset_capability, so
  -- neither document had to be rewritten and neither is quoted at the reader.
  return query select 'clause 3 needs Full, and says so rather than reading as a fault',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 3) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 3)
      = 'Container identity is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 3), 'nothing missing');

  return query select 'clause 6 needs Full for the same reason, and nothing else',
    (select needs_preset from erp.pack_acceptance_report(r.tenant_id) where clause = 6) = 'full'
    and (select missing from erp.pack_acceptance_report(r.tenant_id) where clause = 6)
      = 'Recall management is off (in the Full preset); ',
    coalesce((select missing from erp.pack_acceptance_report(r.tenant_id)
               where clause = 6), 'nothing missing');

  -- The invariant the whole change is for: nothing a preset can switch on is
  -- ever reported as something the pack failed to provide. §13's last sentence
  -- logs a pack gap against the product, and a preset nobody chose is not one.
  return query select 'no clause blames the pack for a capability a preset carries',
    not exists (
      select 1 from erp.pack_acceptance_report(r.tenant_id) ar
       where ar.missing is not null
         and ar.missing like '%is off%'
         and ar.missing not like '%preset)%'),
    'before this, two clauses answered a reader with a paragraph about §2.3 '
    'disagreeing with §13';

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
$function$;

CREATE OR REPLACE FUNCTION erp_test.assert_starter_pack_acceptance()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- 21, not 20: the two clauses that argued with §2.3 became two that name
  -- the preset they need, and a third case now asserts the invariant behind
  -- them — that nothing a preset can switch on is ever reported as a gap in
  -- the pack.
  c_expected constant integer := 21;
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
end $function$;

-- ── The decision this closes ─────────────────────────────────────────────────

update erp_meta.policy_decision set
  decision =
    'Taken: §13 means Full. Neither document changes. §2.3 keeps container '
    'identity and recall management in the Full preset, §13 keeps its seven '
    'clauses, and erp.pack_acceptance_report() now names the preset each '
    'clause needs instead of treating a Full-tier capability as a fault on an '
    'organisation that chose Standard.',
  rationale =
    'The two readings were: widen Standard to match §13''s narrative, or read '
    '§13''s "having chosen the Standard preset" as scene-setting rather than a '
    'constraint on all seven clauses. Widening loses the thing §2.3 is for — a '
    'tier a mid-sized organisation can take without also taking container '
    'identity and recall, which are real obligations with real work behind '
    'them. Reading §13 as describing a fully capable organisation costs '
    'nothing and is what the clauses themselves say: batch genealogy end to '
    'end and a recall answer for any batch are Full-tier questions whichever '
    'preset the sentence above them mentions. So the acceptance clause is '
    'corrected and the preset is left alone. What made this worth doing '
    'properly rather than by editing a string: the clause-to-capability '
    'mapping is now erp_ref.acceptance_clause, and the preset each clause '
    'needs is derived from erp_ref.preset_capability. Move container identity '
    'into Standard tomorrow and the report follows on its own.',
  evidence =
    'erp.pack_acceptance_report() returns needs_preset; clauses 3 and 6 return '
    '''full'' and clauses 4 and 5 ''standard''. '
    'erp.assert_acceptance_clauses_sound() refuses a clause naming a '
    'capability no preset carries — a clause no organisation could ever '
    'satisfy, which the hardcoded version reported as merely switched off. '
    'The suite asserts that no clause reports a capability shortfall without '
    'naming the preset that answers it.',
  status = 'accepted', decided_at = now()
 where code = 'standard_preset_vs_acceptance';

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_isolation();
select erp.assert_acceptance_clauses_sound();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp_test.assert_starter_pack_acceptance();
