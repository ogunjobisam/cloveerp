-- =============================================================================
-- Starter Content Packs §10, §11 and §12 — the machinery
--
-- §11 is a sequence of seven statements about applying a pack, and each one is
-- a thing that has to exist for the sentence to be true:
--
--   1. Select a preset, then adjust capabilities        erp.apply_preset (§2)
--   2. The system generates a change set containing
--      everything the selection implies, and only that  erp.apply_content_pack
--   3. Conflicts surface before anything lands          erp.pack_conflicts
--   4. Required decisions are listed and PROMOTION
--      REFUSES while any remain                         erp.pack_decisions,
--                                                       and a gate inside
--                                                       erp.promote_change_set
--   5. Preview the diff, promote                        erp.preview_change_set
--   6. The tenant records pack identifiers and versions erp.tenant_pack
--   7. Re-application is additive: the change set
--      contains only what is missing                    the manifest join in
--                                                       erp.plan_content_pack
--
-- Two of those are load-bearing in a way worth naming.
--
-- "AND ONLY THAT" (§11.2) and "only what is missing" (§11.7) are the same
-- requirement seen twice, and both are answered by joining the pack's items
-- against erp.configuration_manifest() — the function that already says what
-- an organisation holds. A pack that emitted everything every time would make
-- every re-application a diff of hundreds of no-ops, and nobody reads a diff
-- like that, which is the same as not previewing it.
--
-- "PROMOTION REFUSES WHILE ANY REMAIN" (§11.4) is a gate inside
-- erp.promote_change_set, not a check in the door that builds the change set.
-- The distinction is the whole point: the change set is built and previewed
-- with decisions outstanding — that is how somebody sees what the decisions
-- are for — and only landing it is refused.
-- =============================================================================

create table if not exists erp_ref.content_pack (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name        text not null,
  description text not null,
  kind        text not null check (kind in ('base', 'profile')),
  -- §12: pack updates ship as new versions; existing tenants are unaffected.
  version     text not null,
  -- A profile pack applies over the base and "adds only what its capabilities
  -- need", so it names the capability that makes it meaningful at all.
  requires_capability text references erp_ref.capability(code),
  -- §12: "every value carries a provenance note naming the standard or
  -- practice it derives from, so the review is checkable rather than trusted".
  -- Length-checked so that "standard practice" is not an available answer.
  provenance  text not null check (length(provenance) > 30),
  seq         integer not null default 100,
  unique (code, version)
);

create table if not exists erp_ref.pack_item (
  pack_code   text not null references erp_ref.content_pack(code) on delete cascade,
  object_kind text not null,
  object_key  text not null,
  payload     jsonb not null,
  operation   erp.change_operation not null default 'upsert',
  -- An item that only makes sense when a capability is on. The pack carries
  -- it either way; erp.plan_content_pack() leaves it out when the capability
  -- is off, which is §2's "content that arrives switched off until wanted"
  -- applied to the pack rather than to the engine.
  requires_capability text references erp_ref.capability(code),
  -- §11.4. A decision item is one the pack cannot answer for an organisation:
  -- an approval threshold, a sequence prefix, a costing method per class.
  is_decision     boolean not null default false,
  decision_prompt text,
  provenance      text not null check (length(provenance) > 20),
  seq             integer not null default 100,
  primary key (pack_code, object_kind, object_key),
  check (not is_decision or decision_prompt is not null)
);

comment on table erp_ref.pack_item is
  'What a pack installs, as change-set items rather than as inserts. A pack '
  'that wrote rows directly would bypass promotion, preview, rollback and the '
  'live-configuration guard — every mechanism this product has for saying what '
  'changed and undoing it.';

-- §11.6: the tenant records pack identifiers and versions.
create table if not exists erp.tenant_pack (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  pack_code     text not null references erp_ref.content_pack(code),
  version       text not null,
  status        text not null default 'planned'
                  check (status in ('planned', 'applied', 'abandoned')),
  change_set_id uuid references erp.change_set(id) on delete set null,
  item_count    integer not null default 0,
  applied_at    timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

create index if not exists tenant_pack_change_set_idx
  on erp.tenant_pack (tenant_id, change_set_id);

-- The answers to §11.4's required decisions, per organisation. Separate from
-- the change set because a decision outlives the change set that first asked
-- for it: re-applying a pack next year must not ask again.
create table if not exists erp.pack_decision (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  pack_code     text not null references erp_ref.content_pack(code),
  object_kind   text not null,
  object_key    text not null,
  answer        jsonb not null,
  answered_by   uuid,
  answered_at   timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  unique (tenant_id, pack_code, object_kind, object_key)
);

select erp_meta.register_table('erp_ref', 'content_pack', 'product_content',
  'The packs this product ships.');
select erp_meta.register_table('erp_ref', 'pack_item', 'product_content',
  'What each pack installs.');
select erp_meta.register_table('erp', 'tenant_pack', 'tenant_scoped',
  'Which packs an organisation has applied, and at which version.');
select erp_meta.register_table('erp', 'pack_decision', 'tenant_scoped',
  'The answers to the decisions a pack could not make for an organisation.');

-- ── §11.3 Conflicts surface before anything lands ────────────────────────────

create or replace function erp.pack_conflicts(p_pack_code text)
returns table (severity text, conflict text, reference text)
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if not exists (select 1 from erp_ref.content_pack where code = p_pack_code) then
    raise exception 'ERPWARE_UNKNOWN_PACK: %', p_pack_code using errcode = '23503';
  end if;

  return query
  -- §11.3, first named conflict: "account ranges colliding with a legislation
  -- pack". §8.1 says that where a bound legislation pack defines a statutory
  -- structure, it wins — so a pack account whose code already exists with a
  -- different name is the collision, and the existing row is the winner.
  select 'blocking',
         format('account %s already exists as %L and the pack would call it %L',
                pi.payload ->> 'code', a.name, pi.payload ->> 'name'),
         p_pack_code || ' / ' || pi.object_key
    from erp_ref.pack_item pi
    join erp.account a
      on a.tenant_id = v_tenant and a.code = (pi.payload ->> 'code')
     and a.status = 'active'
   where pi.pack_code = p_pack_code and pi.object_kind = 'account'
     and a.name is distinct from (pi.payload ->> 'name')

  union all

  -- Second: duplicate codes. Two items in one pack claiming the same object
  -- differ only in which lands last, which is not a decision anybody made.
  select 'blocking',
         format('%s items in this pack claim %s %L',
                count(*), pi.object_kind, pi.payload ->> 'code'),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code and pi.payload ? 'code'
   group by pi.object_kind, pi.payload ->> 'code'
  having count(*) > 1

  union all

  -- Third: unmet capability dependencies. An item gated on a capability that
  -- is off is skipped rather than blocked — that is §2 working as intended —
  -- but a PACK gated on a capability that is off has nothing to say at all.
  select 'blocking',
         format('this pack needs the %s capability, which is off for this organisation',
                cp.requires_capability),
         p_pack_code
    from erp_ref.content_pack cp
   where cp.code = p_pack_code
     and cp.requires_capability is not null
     and not erp.capability_enabled(cp.requires_capability)

  union all

  -- And advisory: items this organisation will not receive because their own
  -- capability is off. Not a conflict — a consequence — but somebody reading
  -- a diff of forty items when the pack has ninety deserves to know why.
  select 'advisory',
         format('%s item(s) are held back because the %s capability is off',
                count(*), pi.requires_capability),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.requires_capability is not null
     and not erp.capability_enabled(pi.requires_capability)
   group by pi.requires_capability;
end;
$$;

-- ── §11.4 Required decisions ─────────────────────────────────────────────────

create or replace function erp.pack_decisions(p_pack_code text default null)
returns table (pack_code text, object_kind text, object_key text,
               prompt text, answered boolean, answer jsonb)
language sql
stable
set search_path = ''
as $$
  select pi.pack_code, pi.object_kind, pi.object_key, pi.decision_prompt,
         d.id is not null, d.answer
    from erp_ref.pack_item pi
    left join erp.pack_decision d
      on d.tenant_id = erp.require_tenant_id()
     and d.pack_code = pi.pack_code
     and d.object_kind = pi.object_kind
     and d.object_key = pi.object_key
   where pi.is_decision
     and (p_pack_code is null or pi.pack_code = p_pack_code)
     -- A decision about something the organisation will not receive is not a
     -- decision it has to make.
     and (pi.requires_capability is null
          or erp.capability_enabled(pi.requires_capability))
   order by pi.pack_code, pi.seq, pi.object_kind, pi.object_key
$$;

create or replace function erp.answer_pack_decision(
  p_pack_code text, p_object_kind text, p_object_key text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); pi erp_ref.pack_item%rowtype;
begin
  select * into pi from erp_ref.pack_item
   where pack_code = p_pack_code and object_kind = p_object_kind
     and object_key = p_object_key;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PACK_ITEM: %/%/%',
      p_pack_code, p_object_kind, p_object_key using errcode = '23503';
  end if;
  if not pi.is_decision then
    raise exception 'ERPWARE_NOT_A_DECISION: %/%/% is not one of the pack''s open questions',
      p_pack_code, p_object_kind, p_object_key using errcode = '23514';
  end if;
  if p_answer is null or p_answer = 'null'::jsonb then
    raise exception 'ERPWARE_EMPTY_DECISION: % needs an answer, and null is not one',
      pi.decision_prompt using errcode = '23514';
  end if;

  insert into erp.pack_decision
    (tenant_id, pack_code, object_kind, object_key, answer, answered_by)
  values (v_tenant, p_pack_code, p_object_kind, p_object_key, p_answer,
          erp.current_principal_id())
  on conflict (tenant_id, pack_code, object_kind, object_key) do update set
    answer = excluded.answer, answered_by = excluded.answered_by,
    answered_at = now(), updated_at = now();

  return jsonb_build_object('pack', p_pack_code, 'object', p_object_key,
                            'answer', p_answer);
end;
$$;

-- ── §11.2 and §11.7 — everything the selection implies, and only that ────────

create or replace function erp.plan_content_pack(p_pack_code text)
returns table (object_kind text, object_key text, operation erp.change_operation,
               payload jsonb, effect text, is_decision boolean, seq integer)
language sql
stable
set search_path = ''
as $$
  -- The decision's answer replaces the pack's placeholder, so what lands is
  -- what the organisation chose rather than a value the pack invented.
  with item as (
    select pi.*,
           case when pi.is_decision and d.answer is not null
                then pi.payload || d.answer
                else pi.payload end as effective_payload
      from erp_ref.pack_item pi
      left join erp.pack_decision d
        on d.tenant_id = erp.require_tenant_id()
       and d.pack_code = pi.pack_code
       and d.object_kind = pi.object_kind
       and d.object_key = pi.object_key
     where pi.pack_code = p_pack_code
       and (pi.requires_capability is null
            or erp.capability_enabled(pi.requires_capability))
  )
  select i.object_kind, i.object_key, i.operation, i.effective_payload,
         case when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
   -- §11.7: "the change set contains only what is missing". An item the
   -- organisation already holds identically is left out entirely rather than
   -- carried as a no-op — a diff of two hundred no-ops is not a diff anybody
   -- reads, which is the same as not previewing it at all.
   where m.object_key is null
      or md5(i.effective_payload::text) is distinct from m.content_hash
   order by i.seq, i.object_kind, i.object_key
$$;

comment on function erp.plan_content_pack is
  'What applying this pack would add to this organisation, and nothing it '
  'already holds. Capability-gated items are left out when their capability is '
  'off; a decision that has been answered carries the answer.';

create or replace function erp.apply_content_pack(
  p_pack_code text, p_change_set_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  cp        erp_ref.content_pack%rowtype;
  v_cs      uuid;
  v_code    text;
  r         record;
  n         integer := 0;
  v_block   text := '';
  v_open    integer;
begin
  select * into cp from erp_ref.content_pack where code = p_pack_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PACK: %', p_pack_code using errcode = '23503';
  end if;

  -- §11.3: conflicts surface BEFORE anything lands, which means before the
  -- change set exists rather than at promotion. A blocking conflict is one
  -- nothing downstream can resolve.
  for r in select * from erp.pack_conflicts(p_pack_code) where severity = 'blocking' loop
    v_block := v_block || format(E'  %s (%s)\n', r.conflict, r.reference);
  end loop;
  if v_block <> '' then
    raise exception E'ERPWARE_PACK_CONFLICT: % cannot be applied as it stands\n%',
      p_pack_code, v_block using errcode = '23514';
  end if;

  v_code := coalesce(p_change_set_code,
    format('pack-%s-%s', p_pack_code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));

  v_cs := erp.create_change_set(v_code,
    format('%s (%s)', cp.name, cp.version),
    format('%s Generated by erp.apply_content_pack; %s',
           cp.description, cp.provenance));

  for r in select * from erp.plan_content_pack(p_pack_code) loop
    perform erp.add_change_set_item(v_cs, r.object_kind, r.object_key,
                                    r.payload, r.operation, null,
                                    format('%s %s', p_pack_code, cp.version));
    n := n + 1;
  end loop;

  insert into erp.tenant_pack
    (tenant_id, pack_code, version, status, change_set_id, item_count)
  values (v_tenant, p_pack_code, cp.version, 'planned', v_cs, n);

  select count(*) into v_open
    from erp.pack_decisions(p_pack_code) where not answered;

  return jsonb_build_object(
    'pack', p_pack_code,
    'version', cp.version,
    'change_set_id', v_cs,
    'change_set_code', v_code,
    'items', n,
    -- Reported rather than refused. §11.4 refuses at promotion, and it refuses
    -- there so that somebody can preview the change set and see what the
    -- decisions are actually about before answering them.
    'open_decisions', v_open,
    'advisories', coalesce((select jsonb_agg(c.conflict)
                              from erp.pack_conflicts(p_pack_code) c
                             where c.severity = 'advisory'), '[]'::jsonb));
end;
$$;

comment on function erp.apply_content_pack is
  'Generates a change set containing everything the pack implies for this '
  'organisation and only that, per §11.2. It does not promote: conflicts are '
  'refused here, decisions are refused at promotion, and the diff is looked at '
  'in between.';

-- ── The gate, and the record ─────────────────────────────────────────────────
--
-- erp.promote_change_set() replaced whole rather than patched: two things go
-- into it, and both belong where promotion already is. §11.4's refusal goes
-- before the snapshot, so a refused promotion writes nothing. §11.6's record
-- goes after the items land, because a pack that was planned and never
-- promoted is not a pack the organisation has.

create or replace function erp.promote_change_set(p_change_set_id uuid, p_scope_kinds text[] DEFAULT NULL::text[], p_ignore_schedule boolean DEFAULT false)

returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  cs         erp.change_set%rowtype;
  v_promo    uuid;
  v_snapshot uuid;
  v_applied  integer := 0;
  v_env      uuid;
  r          record;
  v_entity   record;
  v_before   text[];
  v_new      text;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  -- Before the snapshot, so a tenant with no environment fails without having
  -- written anything.
  v_env := erp.self_environment_id(v_tenant);

  select * into cs from erp.change_set
   where tenant_id = v_tenant and id = p_change_set_id for update;

  if cs.status <> 'approved' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_APPROVED: % is %', cs.code, cs.status
      using errcode = '42501';
  end if;

  if cs.scheduled_for is not null and not p_ignore_schedule and now() < cs.scheduled_for then
    raise exception 'ERPWARE_CHANGE_SET_NOT_DUE: % is scheduled for %', cs.code, cs.scheduled_for
      using errcode = '23514';
  end if;


  -- Starter Content Packs 11.4: "Required decisions are listed and PROMOTION
  -- REFUSES while any remain."
  --
  -- Here rather than in erp.apply_content_pack(), and the difference is the
  -- whole design. The change set is built and previewed with decisions
  -- outstanding, because looking at the diff is how somebody works out what
  -- the decisions are for. Only landing it is refused.
  --
  -- Placed before the snapshot for the same reason the environment lookup is:
  -- a refusal that has already written a snapshot leaves a row nobody asked
  -- for.
  declare
    v_pack   record;
    v_undone text := '';
    d        record;
  begin
    for v_pack in
      select tp.pack_code from erp.tenant_pack tp
       where tp.tenant_id = v_tenant and tp.change_set_id = p_change_set_id
         and tp.status = 'planned'
    loop
      for d in
        select * from erp.pack_decisions(v_pack.pack_code) where not answered
      loop
        v_undone := v_undone || format(E'  %s: %s\n', d.object_key, d.prompt);
      end loop;
    end loop;

    if v_undone <> '' then
      raise exception
        E'ERPWARE_PACK_DECISIONS_OUTSTANDING: this change set installs a pack '
        'whose required decisions have not been made\n%', v_undone
        using errcode = '23514',
              hint = 'erp.answer_pack_decision() records each one. A pack that '
                     'guessed an approval threshold or a costing method would '
                     'be inventing policy on an organisation''s behalf.';
    end if;
  end;
  -- Snapshot first. Rollback is only "one action" if the previous state was
  -- captured before anything moved.
  v_snapshot := erp.take_config_snapshot(
    format('before promotion of %s', cs.code),
    format('pre-%s-%s', cs.code, to_char(clock_timestamp(), 'YYYYMMDDHH24MISS')));

  insert into erp.promotion (
    tenant_id, change_set_id, environment_id, snapshot_id, scope_kinds, actor_id)
  values (
    v_tenant, p_change_set_id, v_env,
    v_snapshot, p_scope_kinds, erp.current_principal_id())
  returning id into v_promo;

  update erp.change_set
     set status = 'promoting', rollback_snapshot_id = v_snapshot, updated_at = now()
   where id = p_change_set_id;

  -- Opens the window in which configuration may be written in a live
  -- environment. Transaction-scoped, so it closes whatever happens next.
  perform set_config('erp.promotion_id', v_promo::text, true);

  -- C1, Addendum B §5: "run before promotion, not after month-end".
  --
  -- Stated as a delta rather than as an absolute, and the difference matters.
  -- An absolute check fires on states that are merely intermediate: an
  -- organisation part-way through installing its modules has document types
  -- naming posting rules a later change set will supply, and failing that
  -- promotion would turn the installation order into a hidden precondition.
  -- What a promotion must never do is make determination WORSE — introduce a
  -- way for a posting to fail that did not exist a moment ago. The whole
  -- promotion rolls back with it.
  select coalesce(array_agg(c.finding || ' | ' || c.reference), '{}')
    into v_before
    from erp.determination_coverage_report(v_tenant) c;

  for r in
    select i.id from erp.change_set_item i
     where i.tenant_id = v_tenant
       and i.change_set_id = p_change_set_id
       and (p_scope_kinds is null or i.object_kind = any (p_scope_kinds))
     order by
       -- Roles and terminology before the things that reference them.
       case i.object_kind
         when 'role' then 1 when 'terminology' then 2 when 'config' then 3
         when 'legislation_binding' then 4 when 'event_subscription' then 5
         when 'rule_set' then 6 when 'state_machine' then 7
         when 'approval_chain' then 8 else 9 end,
       i.seq
  loop
    perform erp.apply_change_set_item(r.id);
    v_applied := v_applied + 1;
  end loop;

  -- Spec 3.11: "validated by tests". The pack conformance suite is the test
  -- that matters most here, because a promotion that quietly changes a tax
  -- answer is the expensive kind.
  for v_entity in
    select distinct b.entity_id from erp.entity_legislation_binding b
     where b.tenant_id = v_tenant and b.status = 'active'
  loop
    perform erp.assert_legislation_conformance(v_entity.entity_id);
  end loop;

  select string_agg(format('  %s — %s: %s', c.finding, c.reference, c.detail), E'\n')
    into v_new
    from erp.determination_coverage_report(v_tenant) c
   where (c.finding || ' | ' || c.reference) <> all (v_before);

  if v_new is not null then
    raise exception
      'ERPWARE_PROMOTION_BREAKS_DETERMINATION: % introduces a way for a posting to fail',
      cs.code
      using errcode = 'P0001', detail = v_new,
            hint = '§5 refuses a default-to-suspense, so each of these is a '
                   'refusal at posting time rather than a suspense entry. '
                   'erp.determination_coverage_report() lists what was already '
                   'outstanding before this promotion.';
  end if;

  update erp.promotion
     set status = 'succeeded', finished_at = now(), applied_count = v_applied
   where id = v_promo;

  update erp.change_set
     set status = 'promoted', promoted_at = now(), updated_at = now()
   where id = p_change_set_id;

  -- 11.6: "The tenant records pack identifiers and versions." Recorded on
  -- promotion rather than on planning, because a pack that was planned and
  -- never landed is not a pack the organisation has.
  update erp.tenant_pack
     set status = 'applied', applied_at = now(), updated_at = now()
   where tenant_id = v_tenant and change_set_id = p_change_set_id
     and status = 'planned';

  perform set_config('erp.promotion_id', '', true);

  return v_promo;
end;
$$;

-- ── Doors ────────────────────────────────────────────────────────────────────

create or replace function public.erp_content_packs()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', cp.code, 'name', cp.name, 'description', cp.description,
           'kind', cp.kind, 'version', cp.version,
           'requires_capability', cp.requires_capability,
           'provenance', cp.provenance,
           'items', (select count(*) from erp_ref.pack_item pi
                      where pi.pack_code = cp.code),
           'decisions', (select count(*) from erp_ref.pack_item pi
                          where pi.pack_code = cp.code and pi.is_decision),
           'applied', (select jsonb_agg(jsonb_build_object(
                          'version', tp.version, 'status', tp.status,
                          'items', tp.item_count, 'applied_at', tp.applied_at)
                        order by tp.created_at desc)
                         from erp.tenant_pack tp
                        where tp.tenant_id = erp.current_tenant_id()
                          and tp.pack_code = cp.code))
         order by cp.kind desc, cp.seq, cp.code), '[]'::jsonb)
    from erp_ref.content_pack cp
$$;

create or replace function public.erp_pack_plan(p_pack_code text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('administration.read');
  return jsonb_build_object(
    'pack', p_pack_code,
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object(
        'severity', c.severity, 'conflict', c.conflict, 'reference', c.reference))
      from erp.pack_conflicts(p_pack_code) c), '[]'::jsonb),
    'decisions', coalesce((select jsonb_agg(jsonb_build_object(
        'object_kind', d.object_kind, 'object_key', d.object_key,
        'prompt', d.prompt, 'answered', d.answered, 'answer', d.answer)
        order by d.object_key)
      from erp.pack_decisions(p_pack_code) d), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'object_kind', p.object_kind, 'object_key', p.object_key,
        'effect', p.effect, 'is_decision', p.is_decision)
        order by p.seq, p.object_key)
      from erp.plan_content_pack(p_pack_code) p), '[]'::jsonb));
end;
$$;

comment on function public.erp_pack_plan is
  'What applying this pack would do, before it does it: the conflicts, the '
  'decisions still open, and the items that would land. §11 steps 3, 4 and 7 '
  'in one read.';

create or replace function public.erp_apply_content_pack(
  p_pack_code text, p_change_set_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.apply_content_pack(p_pack_code, p_change_set_code);
end;
$$;

create or replace function public.erp_answer_pack_decision(
  p_pack_code text, p_object_kind text, p_object_key text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.answer_pack_decision(p_pack_code, p_object_kind, p_object_key, p_answer);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_content_packs()',
    'public.erp_pack_plan(text)',
    'public.erp_apply_content_pack(text, text)',
    'public.erp_answer_pack_decision(text, text, text, jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_apply_content_pack', 'erp.authorise',
   'Builds the change set a pack implies. Volatile because it writes one, and '
   'gated on administration.configure because what it writes is configuration '
   '— but it promotes nothing, so the authority to look is not the authority '
   'to land.'),
  ('erp_answer_pack_decision', 'erp.authorise',
   'Records an answer to a decision the pack could not make for this '
   'organisation. Until every one is answered, promotion refuses.'),
  ('erp_pack_plan', 'erp.authorise',
   'Volatile only because erp.pack_decisions() and erp.plan_content_pack() '
   'call erp.require_tenant_id(), which binds identity on first use.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── §12 Neutrality review, as something checkable rather than trusted ────────
--
-- "Before any pack version ships it is checked for content traceable to a
-- specific organisation — no customer, site, product, account, department or
-- threshold taken from a live tenant."
--
-- A release gate stated as a promise is a promise. Stated as a query it is a
-- gate. This is computable because the deployment holds both halves: the pack
-- content and every organisation's own data. A pack code that matches a code
-- some organisation actually uses is not proof of anything on its own — 'BULK'
-- is a warehouse location everywhere — so the test is deliberately narrow: a
-- code that appears in exactly ONE organisation and nowhere in the vocabulary
-- catalogues is the shape of a value lifted from a live tenant.
--
-- A REPORT, because on a deployment with one organisation every pack value
-- looks tenant-specific by that measure, and a build that fails there would be
-- failing on arithmetic rather than on evidence.

create or replace function erp.pack_neutrality_report()
returns table (pack_code text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  with tenants as (select count(*) as n from erp.tenant where status = 'active'),
  pack_code as (
    select pi.pack_code, pi.object_kind, pi.object_key,
           upper(pi.payload ->> 'code') as code
      from erp_ref.pack_item pi
     where pi.payload ? 'code'
  ),
  -- Every code any organisation uses, across the surfaces a pack can write.
  tenant_code as (
    select upper(a.code) as code, a.tenant_id from erp.account a
    union all select upper(l.code), l.tenant_id from erp.location l
    union all select upper(d.code), d.tenant_id from erp.department d
    union all select upper(i.code), i.tenant_id from erp.item i
    union all select upper(p.code), p.tenant_id from erp.party p
    union all select upper(s.code), s.tenant_id from erp.site s
  )
  select pc.pack_code,
         format('%s %s uses a code only one organisation has, which is what '
                'content lifted from a live tenant looks like',
                pc.object_kind, pc.object_key),
         pc.code
    from pack_code pc
    join tenants t on t.n > 1
   where exists (select 1 from tenant_code tc where tc.code = pc.code)
     and (select count(distinct tc.tenant_id) from tenant_code tc
           where tc.code = pc.code) = 1
   order by 1, 3
$$;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.assert_packs_installable()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_detail text := ''; v_count integer := 0; r record; v_kinds text;
begin
  v_kinds := pg_catalog.pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);

  -- 1. A pack item naming a kind no change set can carry is an item that
  --    raises the moment somebody applies the pack — and the pack that
  --    contains it looks perfectly fine until then.
  for r in
    select distinct pi.pack_code, pi.object_kind from erp_ref.pack_item pi
     where position('when ''' || pi.object_kind || '''' in v_kinds) = 0
     order by 1, 2
  loop
    v_detail := v_detail || format(
      E'  %s carries kind %L, which erp.apply_change_set_item cannot promote\n',
      r.pack_code, r.object_kind);
    v_count := v_count + 1;
  end loop;

  -- 2. A decision item with no prompt is a question nobody can answer. The
  --    table check catches a null; this catches a prompt that says nothing.
  for r in
    select pi.pack_code, pi.object_key from erp_ref.pack_item pi
     where pi.is_decision and length(coalesce(pi.decision_prompt, '')) < 15
     order by 1, 2
  loop
    v_detail := v_detail || format(
      E'  %s / %s is a decision with no usable prompt\n', r.pack_code, r.object_key);
    v_count := v_count + 1;
  end loop;

  -- 3. A profile pack gated on a capability that has left the catalogue, and
  --    an item gated the same way. The foreign key catches a misspelling; this
  --    catches a capability removed after the pack started naming it.
  for r in
    select cp.code as pack_code, cp.requires_capability as cap
      from erp_ref.content_pack cp
     where cp.requires_capability is not null
       and not exists (select 1 from erp_ref.capability c
                        where c.code = cp.requires_capability)
    union all
    select pi.pack_code, pi.requires_capability
      from erp_ref.pack_item pi
     where pi.requires_capability is not null
       and not exists (select 1 from erp_ref.capability c
                        where c.code = pi.requires_capability)
  loop
    v_detail := v_detail || format(
      E'  %s needs capability %s, which is not in the catalogue\n', r.pack_code, r.cap);
    v_count := v_count + 1;
  end loop;

  -- 4. §10: "Applied over the base, each switchable, each adding only what its
  --    capabilities need." A profile pack that names no capability adds
  --    unconditionally, which makes it a second base pack wearing a label.
  for r in
    select cp.code from erp_ref.content_pack cp
     where cp.kind = 'profile' and cp.requires_capability is null
     order by 1
  loop
    v_detail := v_detail || format(
      E'  profile pack %s names no capability, so it is a second base pack\n', r.code);
    v_count := v_count + 1;
  end loop;

  -- 5. And exactly one base pack, because "applied over the base" needs a
  --    definite article to be true.
  if (select count(*) from erp_ref.content_pack where kind = 'base') > 1 then
    v_detail := v_detail || format(
      E'  there are %s base packs, and §10 says profile packs are applied over THE base\n',
      (select count(*) from erp_ref.content_pack where kind = 'base'));
    v_count := v_count + 1;
  end if;

  if v_count > 0 then
    raise exception E'ERPWARE_PACK_NOT_INSTALLABLE: % finding(s)\n%', v_count, v_detail
      using errcode = '23514';
  end if;

  return format('packs: %s (%s base, %s profile), %s items, %s decisions',
    (select count(*) from erp_ref.content_pack),
    (select count(*) from erp_ref.content_pack where kind = 'base'),
    (select count(*) from erp_ref.content_pack where kind = 'profile'),
    (select count(*) from erp_ref.pack_item),
    (select count(*) from erp_ref.pack_item where is_decision));
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values
  ('packs_installable', 'Content packs', 'assertion', 'platform',
   'assert_packs_installable', '', null, '',
   'Every pack item names a kind a change set can carry, every decision has a '
   'prompt, every capability it gates on still exists, and a profile pack '
   'gates on one at all.', true, 25),
  ('pack_neutrality', 'Pack neutrality', 'report', 'platform',
   'pack_neutrality_report', '', null, '',
   '§12''s release gate: pack values that look traceable to one organisation. '
   'A report rather than an assertion, because on a deployment with a single '
   'organisation every value looks tenant-specific by this measure.', false, 26)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_packs_installable();
select erp.assert_capabilities_sound();
select erp.assert_starter_vocabularies_sound();
select erp.assert_vocabulary_aligned();
select erp.assert_configuration_promotable();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();

-- ── What running §11 end to end found ────────────────────────────────────────
--
-- Exercising the seven steps against a real organisation turned up two places
-- where the sentence was true and the behaviour was not.
--
-- 1. THE ANSWER TO A DECISION NEVER REACHED THE CHANGE SET. The flow is: build
--    the change set, see the decisions, answer them, promote. But the items
--    were built from the pack's placeholder payload at plan time, so answering
--    afterwards changed nothing — the numbering rule landed with the pack's
--    'REQ-' rather than the 'PR-' that was chosen. The gate refused promotion
--    until the question was answered and then ignored the answer, which is
--    worse than not asking.
--
-- 2. RE-APPLICATION WAS NOT ADDITIVE. §11.7 wants a second application to plan
--    nothing when nothing is missing, and it planned all three items again.
--    Two causes. A pack payload is a SUBSET of what the manifest emits — the
--    pack says a calendar's code, name and timezone; the manifest also carries
--    its working days and its exceptions — so comparing md5 hashes could never
--    match. And three of the eleven pack-installable kinds are deliberately
--    not in the manifest at all, so they always read as absent.
--
-- The fix for the first is to write the answer through to any change set still
-- waiting on it. The fix for the second is containment rather than equality,
-- plus the pack's own history for the kinds the manifest does not carry.

create or replace function erp.answer_pack_decision(
  p_pack_code text, p_object_kind text, p_object_key text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  pi erp_ref.pack_item%rowtype;
  v_updated integer := 0;
begin
  select * into pi from erp_ref.pack_item
   where pack_code = p_pack_code and object_kind = p_object_kind
     and object_key = p_object_key;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_PACK_ITEM: %/%/%',
      p_pack_code, p_object_kind, p_object_key using errcode = '23503';
  end if;
  if not pi.is_decision then
    raise exception 'ERPWARE_NOT_A_DECISION: %/%/% is not one of the pack''s open questions',
      p_pack_code, p_object_kind, p_object_key using errcode = '23514';
  end if;
  if p_answer is null or p_answer = 'null'::jsonb then
    raise exception 'ERPWARE_EMPTY_DECISION: % needs an answer, and null is not one',
      pi.decision_prompt using errcode = '23514';
  end if;

  insert into erp.pack_decision
    (tenant_id, pack_code, object_kind, object_key, answer, answered_by)
  values (v_tenant, p_pack_code, p_object_kind, p_object_key, p_answer,
          erp.current_principal_id())
  on conflict (tenant_id, pack_code, object_kind, object_key) do update set
    answer = excluded.answer, answered_by = excluded.answered_by,
    answered_at = now(), updated_at = now();

  -- And through to any change set still waiting on it. Without this the answer
  -- is recorded, the gate opens, and the placeholder promotes.
  update erp.change_set_item csi
     set payload = pi.payload || p_answer, updated_at = now()
    from erp.tenant_pack tp, erp.change_set cs
   where tp.tenant_id = v_tenant and tp.pack_code = p_pack_code
     and tp.status = 'planned'
     and csi.change_set_id = tp.change_set_id
     and cs.id = tp.change_set_id
     -- A promoted change set is history. Rewriting one would change what the
     -- record says happened.
     and cs.status in ('draft', 'ready', 'approved')
     and csi.tenant_id = v_tenant
     and csi.object_kind = p_object_kind
     and csi.object_key = p_object_key;
  get diagnostics v_updated = row_count;

  return jsonb_build_object('pack', p_pack_code, 'object', p_object_key,
                            'answer', p_answer,
                            'change_set_items_updated', v_updated);
end;
$$;

create or replace function erp.plan_content_pack(p_pack_code text)
returns table (object_kind text, object_key text, operation erp.change_operation,
               payload jsonb, effect text, is_decision boolean, seq integer)
language sql
stable
set search_path = ''
as $$
  with item as (
    select pi.*,
           case when pi.is_decision and d.answer is not null
                then pi.payload || d.answer
                else pi.payload end as effective_payload
      from erp_ref.pack_item pi
      left join erp.pack_decision d
        on d.tenant_id = erp.require_tenant_id()
       and d.pack_code = pi.pack_code
       and d.object_kind = pi.object_kind
       and d.object_key = pi.object_key
     where pi.pack_code = p_pack_code
       and (pi.requires_capability is null
            or erp.capability_enabled(pi.requires_capability))
  ),
  -- What a pack it already applied gave this organisation. Needed because
  -- three of the eleven pack-installable kinds — uom, location, account — are
  -- deliberately absent from erp.configuration_manifest(): they are master
  -- data, and putting them in the manifest would put them in every rollback
  -- snapshot, which would make undoing a configuration change undo a
  -- warehouse's bins.
  already as (
    select csi.object_kind, csi.object_key, csi.payload
      from erp.change_set_item csi
      join erp.tenant_pack tp
        on tp.tenant_id = csi.tenant_id and tp.change_set_id = csi.change_set_id
     where csi.tenant_id = erp.require_tenant_id()
       and tp.status = 'applied'
  )
  select i.object_kind, i.object_key, i.operation, i.effective_payload,
         case when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
   -- §11.7: "the change set contains only what is missing". Containment, not
   -- equality: a pack payload is a subset of what the manifest emits, so
   -- comparing hashes would mark everything missing for ever.
   -- coalesced, not bare: m.content is NULL when the organisation holds
   -- nothing of that kind, NULL @> anything is NULL, and `not NULL` is NULL —
   -- so the first version of this line silently planned nothing at all for a
   -- brand new organisation, which is the one case that matters most.
   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)
     and not exists (
       select 1 from already a
        where a.object_kind = i.object_kind and a.object_key = i.object_key
          and a.payload = i.effective_payload)
   order by i.seq, i.object_kind, i.object_key
$$;

comment on function erp.plan_content_pack is
  'What applying this pack would add to this organisation, and nothing it '
  'already holds — by containment against the configuration manifest, and by '
  'the pack history for the master-data kinds the manifest deliberately omits. '
  'Capability-gated items are left out when their capability is off; a '
  'decision that has been answered carries the answer.';
