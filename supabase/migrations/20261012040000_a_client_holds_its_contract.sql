set lock_timeout = '30s';

-- =============================================================================
-- 20261012040000  A client holds its contract
-- -----------------------------------------------------------------------------
-- The control plane keeps a client deployment's contract (20261011090000) and
-- queues what the client is owed in erp_meta.deployment_push: its position
-- (the plan, the term, and the bands and add-ons the contract sold, dated)
-- and its notices (signed, amended, renewed, invoiced, the key dates). Until
-- now nothing took them there, so a client ran with no plan at all:
-- erp.tenant_plan_code() was null on it, every limit unlimited and every
-- add-on allowed. This is the database's half of taking them; the workflow
-- that carries them (the third step of fleet_sync.yml), the usage the poll
-- reads, and the Fleet's and Plans' screens come in the same pull request.
--
--   A. A client holds its position. erp_meta.subscription_position holds, for
--      the whole deployment, the newest position applied: the plan, the
--      contract's reference and status, the term, whether it renews, the
--      currency and the subscription's status. Its bands and add-ons are in
--      erp_meta.subscription_position_entitlement and _capability, dated as
--      the contract dates them. It is held before the client's one
--      organisation exists (a contract is signed before its build), and that
--      organisation takes it from the moment it is onboarded. Nothing here
--      writes erp_meta.subscription or an organisation's status.
--
--   B. Enforcement reads it. erp.tenant_plan_code() answers the plan held
--      before any subscription of the organisation's own. A band or add-on
--      held counts, as a contract's does, only while the contract is active
--      or terminating and only on the days it is dated for: that rule is
--      written once, in erp.contract_band_in_force and
--      erp.contract_capabilities_in_force, and erp.entitlement_limit,
--      erp.capability_on_plan, erp_platform_seats and erp.my_agreement read
--      it, and with them every door that asks. Held on the control plane or
--      the demonstration, it is a finding (erp.entitlement_enforcement_report,
--      finding 6). And erp.entitlement_limit no longer tells a signed-in
--      person the limits of an organisation other than the one they work in.
--
--   C. The client applies what it is owed. erp_meta.apply_pushed_position
--      takes the newest position on every run, whatever its state on the
--      control plane, so a client rebuilt or restored heals itself: one held
--      already is a replay, one older than the one held is older, one naming a
--      plan, band or feature this database does not know yet waits for its
--      release, and one that does not read as a position is refused.
--      erp_meta.apply_pushed_notices appends each notice once to the
--      organisation's event stream, dated when it was queued, with its event's
--      version and its push as the correlation, and records no source of its
--      own, as the control plane's own commercial events do. It waits while
--      there is no organisation, keeps the notices in order, and refuses one
--      that is not among the ten a client is told of.
--
--   D. The control plane hands out and settles. erp_meta.deployment_pushes_due
--      gives the workflow the newest position and the notices pending, and
--      erp_meta.settle_deployment_pushes records what the client answered.
--      Nothing is claimed, and a position is never failed by the sync, so the
--      contract provisioning check (D35) is as it was. Queueing stamps a
--      notice with its event's version, records a push to a retired
--      deployment as failed, since it is owed nothing more, and asks for a
--      sync of a deployment that is up: the sweep wakes it in minutes, or the
--      hourly sync carries it. erp_meta.record_deployment_usage keeps the
--      monthly usage the poll reads from each client.
--
--   E. The console sees it. The Fleet view carries a commercial key for each
--      deployment: its contract, whether its position is applied or pending
--      and since when, the notices pending or failed, and its usage by meter,
--      or that a meter was not measured. The Plans view counts the
--      deployments on each plan, and on a client counts the position it holds
--      as a subscriber. Display only: no release assertion reads either, and a
--      client's fault never blocks the control plane's release.
--
--   F. The proof: erp_test.a_client_holds_its_contract_suite (sixteen cases)
--      and its assertion. The Fleet view has forty-one keys now, which
--      erp_test.deployment_lifecycle_suite and erp_test.register_house_suite
--      count.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- No permission code, no public door's signature, and nothing a client's
-- people see but their plan, its bands and its add-ons. Contract terms,
-- documents and invoices stay on the control plane and reach a client by
-- email. Incidents and maintenance are not taken to clients yet. Nothing here
-- schedules the commercial sweeps (expiry, key dates): a client follows what
-- the control plane queued, when it queued it.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals
-- ─────────────────────────────────────────────────────────────────────────────

-- The register's suspension was the first thing a client took from the control
-- plane; its contract's position and notices are the next, and the same words
-- refuse both off a client.
select erp.register_refusal(
  'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT',
  'Applying, on a deployment that is not a client''s own, what only a client''s own deployment takes from the '
  'control plane: the register''s suspension, or its contract''s position and notices.',
  'The register on the control plane says whether a client is suspended and what its contract holds, and the '
  'client''s own deployment follows it. The control plane and the demonstration keep their organisations'' status '
  'and contracts themselves, so nothing from the register is followed there.',
  'Suspend or reinstate a client, or change its contract, on the platform console at cloveerp.com; its own '
  'deployment follows when the fleet''s sync next runs.');

select erp.register_refusal(
  'CLOVEERP_PUSH_MALFORMED',
  'Applying a contract position or notices pushed from the control plane that do not read as one.',
  'A client holds the plan, the term, and the bands and add-ons its contract sold, exactly as the control plane '
  'computed them. A position missing any of them, or with a date that is not a date, would hold something nobody '
  'sold; a notice that names no push could be told twice.',
  'Nothing was changed. The push stays on the control plane and is counted; read its detail in the Fleet view, '
  'mend what computed it there, and the next sync carries it.');

select erp.register_refusal(
  'CLOVEERP_PUSH_SETTLE_UNREADABLE',
  'Recording what a client answered to the control plane''s pushes in a form the register cannot read.',
  'Each push is settled by what the client said of it: applied, held already, older, waiting or refused. An '
  'answer that names no push, no run, or none of those words would settle nothing, or the wrong push.',
  'Settle with the run''s name and the list of the client''s answers, each naming the push it answers and what the '
  'client said of it, as the client''s deployment returned them.');

select erp.register_refusal(
  'CLOVEERP_DEPLOYMENT_USAGE_INVALID',
  'Recording a client deployment''s usage in a form the register does not keep.',
  'The Fleet view shows each client''s usage by meter and month as its own database measured it. A reading with no '
  'meter, no month, or a quantity that is not a number of none or more would be shown as measured when it was not.',
  'Send a list of readings, each with its meter, the first and last day of its month, its quantity and when it was '
  'measured, as the poll reads them from the client.');

select erp.register_refusal(
  'CLOVEERP_ANOTHER_ORGANISATIONS_LIMIT',
  'Reading the limits of an organisation other than the one this sign-in is working in.',
  'What an organisation''s contract sold it is between that organisation and Clove. A person sees the limits of the '
  'organisation they are working in; the platform console reads another''s only through its own doors, which act '
  'inside that organisation.',
  'Switch to that organisation if you belong to it, or read its seats from the platform console.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. What a client holds, and what the control plane keeps of it
-- ─────────────────────────────────────────────────────────────────────────────

-- The newest position applied, for the whole deployment: a client holds one
-- organisation, and the position is held before that organisation exists.
create table if not exists erp_meta.subscription_position (
  only_one              boolean primary key default true check (only_one),
  push_id               uuid not null,
  queued_at             timestamptz not null,
  contract_ref          uuid not null,
  contract_status       text not null
                        check (contract_status in ('active', 'terminating', 'expired', 'terminated')),
  plan_code             text not null references erp_meta.plan (code),
  support_severity_code text,
  term_start            date not null,
  term_end              date,
  renews                boolean not null,
  currency              character(3) not null,
  status                text not null check (status in ('active', 'grace')),
  applied_at            timestamptz not null default now(),
  constraint subscription_position_term_ordered check (term_end is null or term_end >= term_start)
);

-- Its bands and add-ons, dated as the contract dates them. No natural key: a
-- contract may hold the same add-on twice from the same day (an amendment adds
-- without removing), so each apply replaces them all.
create table if not exists erp_meta.subscription_position_entitlement (
  id               uuid primary key default gen_random_uuid(),
  entitlement_code text not null references erp_meta.entitlement_kind (code),
  limit_value      numeric,
  effective_from   date not null,
  effective_to     date,
  constraint subscription_position_entitlement_ordered check (effective_to is null or effective_to > effective_from)
);

create table if not exists erp_meta.subscription_position_capability (
  id              uuid primary key default gen_random_uuid(),
  capability_code text not null references erp_ref.capability (code),
  effective_from  date not null,
  effective_to    date,
  constraint subscription_position_capability_ordered check (effective_to is null or effective_to > effective_from)
);

-- Every push a client applied, by the control plane's id, so none is applied
-- twice; a notice keeps the event it became.
create table if not exists erp_meta.applied_push (
  push_id    uuid primary key,
  kind       text not null check (kind in ('subscription', 'notice')),
  queued_at  timestamptz not null,
  applied_at timestamptz not null default now(),
  result     jsonb not null
);

-- On the control plane: each client's usage by meter and month, as the poll
-- last read it from the client's own database.
create table if not exists erp_meta.deployment_usage (
  code         text not null references erp_meta.deployment (code) on update cascade,
  meter_code   text not null references erp_meta.meter_kind (code),
  period_start date not null,
  period_end   date not null,
  quantity     numeric not null check (quantity >= 0),
  measured_at  timestamptz not null,
  recorded_at  timestamptz not null default now(),
  primary key (code, meter_code, period_start, period_end),
  constraint deployment_usage_period_ordered check (period_end >= period_start)
);

-- What a deployment is owed, newest first, by kind.
create index if not exists deployment_push_code_kind
  on erp_meta.deployment_push (code, kind, created_at desc);

comment on table erp_meta.subscription_position is
  'On a client''s own deployment, the newest contract position applied from the control plane, for the whole '
  'deployment: the plan, the contract''s reference and status, the term, whether it renews, the currency and the '
  'subscription''s status. erp.tenant_plan_code() answers its plan; its bands and add-ons count only while '
  'contract_status is active or terminating. Written only by erp_meta.apply_pushed_position; one row at most, and '
  'none anywhere but on a client (20261012040000).';
comment on column erp_meta.subscription_position.queued_at is
  'When the control plane queued the position held. A position queued earlier is answered older and not applied.';
comment on column erp_meta.subscription_position.contract_ref is
  'The contract on the control plane the position is of. Its terms stay there.';
comment on table erp_meta.subscription_position_entitlement is
  'The bands the contract held on a client''s own deployment sold, dated: a null limit is unlimited by contract. '
  'Replaced whole with each position applied (20261012040000).';
comment on table erp_meta.subscription_position_capability is
  'The add-ons the contract held on a client''s own deployment sold, dated. Replaced whole with each position '
  'applied (20261012040000).';
comment on table erp_meta.applied_push is
  'Every push from the control plane a client''s own deployment applied, by its id: a position, or a notice with '
  'the event it became. A push applied once is answered as a replay ever after (20261012040000).';
comment on table erp_meta.deployment_usage is
  'Each client deployment''s usage by meter and month, summed over its organisations as its own database measured '
  'it, recorded by the poll through erp_meta.record_deployment_usage. A reading replaces the one before for the '
  'same month; none is deleted. A meter with no row was not measured (20261012040000).';

select erp_meta.register_table('erp_meta', 'subscription_position', 'platform_internal',
  'The contract position a client''s own deployment holds, applied from the control plane by the fleet''s sync.');
select erp_meta.register_table('erp_meta', 'subscription_position_entitlement', 'platform_internal',
  'The dated bands of the contract position a client''s own deployment holds.');
select erp_meta.register_table('erp_meta', 'subscription_position_capability', 'platform_internal',
  'The dated add-ons of the contract position a client''s own deployment holds.');
select erp_meta.register_table('erp_meta', 'applied_push', 'platform_internal',
  'Every push from the control plane a client''s own deployment applied, so none is applied twice.');
select erp_meta.register_table('erp_meta', 'deployment_usage', 'platform_internal',
  'Each client deployment''s monthly usage by meter, as the poll reads it from the client.');

revoke all on table erp_meta.subscription_position from public, anon, authenticated;
revoke all on table erp_meta.subscription_position_entitlement from public, anon, authenticated;
revoke all on table erp_meta.subscription_position_capability from public, anon, authenticated;
revoke all on table erp_meta.applied_push from public, anon, authenticated;
revoke all on table erp_meta.deployment_usage from public, anon, authenticated;

-- A notice waiting now is stamped with its event's version, as every notice
-- queued from here on is.
update erp_meta.deployment_push p
   set payload = p.payload || jsonb_build_object('event_version', et.version)
  from erp_ref.event_type et
 where p.kind = 'notice' and p.status in ('pending', 'claimed')
   and jsonb_typeof(p.payload) = 'object' and not (p.payload ? 'event_version')
   and et.code = p.payload ->> 'event_type' and et.is_current;

-- The sync records what nothing declared, as the control plane's own
-- commercial routines do.
insert into erp_meta.audit_source_entry_point (entry_point, records, declares, declared_at, note) values
  ('the fleet''s sync applying the control plane''s pushes', 'undeclared', false, null,
   'Does not declare. supabase/ci/fleet_commercial_sync.sh calls erp_meta.apply_pushed_notices on a client''s own '
   'database through the trusted build role, and the control plane''s own commercial routines that append the same '
   'events never pass erp.authorise(), so both record what nothing declared. Each event names its push as its '
   'correlation (20261012040000).')
on conflict (entry_point) do update
   set records = excluded.records, declares = excluded.declares, declared_at = excluded.declared_at,
       note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Enforcement reads what a client holds
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.contract_band_in_force(p_code text, p_tenant uuid)
returns table(found boolean, limit_value numeric)
language sql
stable
set search_path = ''
as $$
  -- The band in force today for one entitlement: the organisation's own
  -- contract, while it is active or terminating; else, on a client's own
  -- deployment, the position it holds of its contract, on the same terms.
  -- Found with a null limit is unlimited by contract; not found, the plan
  -- speaks. Plain: it opens no read of its own, and only the readers that run
  -- as their owner call it (20261012040000).
  select coalesce(b.found, false), b.limit_value
    from (select 1) as one
    left join lateral (
      select true as found, x.limit_value
        from (select 1 as source, ce.effective_from, ce.limit_value
                from erp_meta.contract_entitlement ce
                join erp_meta.contract c on c.id = ce.contract_id
               where c.tenant_id = p_tenant and c.status in ('active', 'terminating')
                 and ce.entitlement_code = p_code
                 and ce.effective_from <= current_date
                 and (ce.effective_to is null or ce.effective_to > current_date)
              union all
              select 2, pe.effective_from, pe.limit_value
                from erp_meta.subscription_position_entitlement pe
               where pe.entitlement_code = p_code
                 and pe.effective_from <= current_date
                 and (pe.effective_to is null or pe.effective_to > current_date)
                 and exists (select 1 from erp_meta.subscription_position sp
                              where sp.contract_status in ('active', 'terminating'))) x
       order by x.source, x.effective_from desc
       limit 1) b on true
$$;

create or replace function erp.contract_capabilities_in_force(p_tenant uuid)
returns setof text
language sql
stable
set search_path = ''
as $$
  -- The add-ons in force today: the organisation's own contract's, while it is
  -- active or terminating, and on a client's own deployment those of the
  -- position it holds, on the same terms (20261012040000).
  select cc.capability_code
    from erp_meta.contract_capability cc
    join erp_meta.contract c on c.id = cc.contract_id
   where c.tenant_id = p_tenant and c.status in ('active', 'terminating')
     and cc.effective_from <= current_date
     and (cc.effective_to is null or cc.effective_to > current_date)
  union
  select pc.capability_code
    from erp_meta.subscription_position_capability pc
   where pc.effective_from <= current_date
     and (pc.effective_to is null or pc.effective_to > current_date)
     and exists (select 1 from erp_meta.subscription_position sp
                  where sp.contract_status in ('active', 'terminating'))
$$;

revoke all on function erp.contract_band_in_force(text, uuid) from public, anon, authenticated, service_role;
revoke all on function erp.contract_capabilities_in_force(uuid) from public, anon, authenticated, service_role;

comment on function erp.contract_band_in_force(text, uuid) is
  'Whether a band is in force today for an entitlement, and its limit (null when unlimited by contract): the '
  'organisation''s own contract while active or terminating, else on a client''s own deployment the position it '
  'holds, while its contract is active or terminating. The one place that rule is written for limits; plain, and '
  'called only by the readers that run as their owner (20261012040000).';
comment on function erp.contract_capabilities_in_force(uuid) is
  'The add-ons in force today: the organisation''s own contract''s while active or terminating, and on a client''s '
  'own deployment those of the position it holds, on the same terms. The one place that rule is written for '
  'add-ons; plain, and called only by the readers that run as their owner (20261012040000).';

-- The readers this migration was written against.
do $$
declare
  r record;
begin
  for r in
    select x.sig, x.anchor
      from (values
        ('erp.tenant_plan_code(uuid)', '2f94103bd04b19063544a5bbfd967e07'),
        ('erp.entitlement_limit(text,uuid)', 'e3e5c73e8dfc55858fefdab6c3fc447c'),
        ('erp.capability_on_plan(text)', 'd4152dc7c7a4bc38e7614e875e1da57f'),
        ('erp_meta.queue_deployment_push(text,text,uuid,jsonb)', '1fdff89fbb9ef02f5b51806b449c84a4')
      ) as x(sig, anchor)
  loop
    if (select strpos(p.prosrc, '20261012040000') = 0 and md5(p.prosrc) <> r.anchor
          from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure) then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
  end loop;
end
$$;

create or replace function erp.tenant_plan_code(p_tenant_id uuid default null)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- On a client's own deployment, the plan of the contract position it holds
  -- (erp_meta.subscription_position), which its one organisation takes from
  -- the moment it is onboarded. Anywhere else that table is empty, and the
  -- plan is the organisation's subscription's, as before (20261012040000).
  select coalesce(
    (select sp.plan_code from erp_meta.subscription_position sp),
    (select s.plan_code
       from erp_meta.subscription s
      where s.tenant_id = coalesce(p_tenant_id, erp.require_tenant_id())
        and s.status <> 'terminated'
      limit 1))
$$;

create or replace function erp.entitlement_limit(p_code text, p_tenant_id uuid default null)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := coalesce(p_tenant_id, erp.require_tenant_id());
  v_found  boolean;
  v_limit  numeric;
begin
  -- A signed-in person reads the limits of the organisation they are working
  -- in and of no other. The console's doors act inside the organisation they
  -- read, which sets the person aside, and a trusted session carries nobody,
  -- so both still read any. Asked of the request's sign-in, not of
  -- erp.session_is_trusted(), which answers for this routine's owner here
  -- (20261012040000).
  if p_tenant_id is not null and auth.uid() is not null
     and p_tenant_id is distinct from erp.current_tenant_id() then
    raise exception 'CLOVEERP_ANOTHER_ORGANISATIONS_LIMIT: the limits of % are read from inside that organisation, and this sign-in is not working in it', p_tenant_id
      using errcode = '42501',
            hint = 'Switch to that organisation if you belong to it, or read its seats from the platform console.';
  end if;

  -- §17.9: the contract is the source. A band it sold, in force today, is the
  -- limit, including a null band, which is unlimited by contract; on a
  -- client's own deployment, the position it holds of its contract
  -- (erp.contract_band_in_force). Only where the contract is silent does the
  -- plan speak.
  select b.found, b.limit_value into v_found, v_limit
    from erp.contract_band_in_force(p_code, v_tenant) b;
  if coalesce(v_found, false) then
    return v_limit;
  end if;
  return (select pe.limit_value from erp_meta.plan_entitlement pe
           where pe.plan_code = erp.tenant_plan_code(v_tenant) and pe.entitlement_code = p_code);
end;
$$;

create or replace function erp.capability_on_plan(p_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No plan recorded is unmetered; on the plan, or sold as an add-on by the
  -- contract in force, or on a client's own deployment by the position it
  -- holds of its contract, is allowed (20261012040000).
  select erp.tenant_plan_code() is null
      or exists (select 1 from erp_meta.plan_capability pc
                  where pc.plan_code = erp.tenant_plan_code() and pc.capability_code = p_code)
      or p_code in (select erp.contract_capabilities_in_force(erp.require_tenant_id()))
$$;

comment on function erp.tenant_plan_code(uuid) is
  'The plan an organisation is on: on a client''s own deployment the plan of the contract position it holds, '
  'otherwise its subscription''s while not terminated; null when neither is recorded, which is unmetered '
  '(20261012040000).';
comment on function erp.entitlement_limit(text, uuid) is
  'The limit in force today for an entitlement: the band its contract sold (or, on a client''s own deployment, the '
  'band of the position it holds), null when unlimited by contract; else its plan''s. A signed-in person may name '
  'only the organisation they are working in; the console''s doors and trusted sessions may name any '
  '(20261012040000).';
comment on function erp.capability_on_plan(text) is
  'Whether a capability is available to the organisation: no plan recorded, on its plan, or an add-on in force by '
  'its contract or, on a client''s own deployment, by the position it holds (20261012040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- What the readers and the console already did, taught the position held
-- ─────────────────────────────────────────────────────────────────────────────

do $do$
declare
  r      record;
  v_src  text;
  v_def  text;
begin
  for r in
    select x.sig, x.anchor,
           array_agg(x.old order by x.ord) as olds,
           array_agg(x.new order by x.ord) as news
      from (values
        -- The seats the console shows, and where each limit comes from.
        ('public.erp_platform_seats(uuid)', '06047f5b54e586c5ad67a1fff2b8300c', 1,
$o$           'limit_from', case
             when exists (select 1
                            from erp_meta.contract_entitlement ce
                            join erp_meta.contract c on c.id = ce.contract_id
                           where c.tenant_id = p_tenant_id and c.status in ('active', 'terminating')
                             and ce.entitlement_code = k.code
                             and ce.effective_from <= current_date
                             and (ce.effective_to is null or ce.effective_to > current_date)) then 'contract'
$o$,
$n$           'limit_from', case
             -- The contract in force, or on a client's own deployment the
             -- position it holds of its contract (20261012040000).
             when (select b.found from erp.contract_band_in_force(k.code, p_tenant_id) b) then 'contract'
$n$),
        -- An organisation's agreement: where each limit comes from, its
        -- add-ons, and its subscription.
        ('erp.my_agreement()', '6ce9e52de4c60aa5ff8cafcfbeacca17', 1,
$o$                                                                 'source', case when exists (select 1 from erp_meta.contract_entitlement ce join erp_meta.contract ct on ct.id = ce.contract_id
                                                                                              where ct.tenant_id = v_tenant and ct.status in ('active', 'terminating') and ce.entitlement_code = e.entitlement_code
                                                                                                and ce.effective_from <= current_date and (ce.effective_to is null or ce.effective_to > current_date))
                                                                                then 'contract' else 'plan' end)
$o$,
$n$                                                                 -- The contract in force, or on a client's own deployment
                                                                 -- the position it holds of its contract (20261012040000).
                                                                 'source', case when (select b.found from erp.contract_band_in_force(e.entitlement_code, v_tenant) b)
                                                                                then 'contract' else 'plan' end)
$n$),
        ('erp.my_agreement()', '6ce9e52de4c60aa5ff8cafcfbeacca17', 2,
$o$                                union
                                select cc.capability_code from erp_meta.contract_capability cc join erp_meta.contract ct on ct.id = cc.contract_id
                                 where ct.tenant_id = v_tenant and ct.status in ('active', 'terminating')
                                   and cc.effective_from <= current_date and (cc.effective_to is null or cc.effective_to > current_date)) x), '[]'::jsonb),
$o$,
$n$                                union
                                -- Sold by the contract in force, or held of it on a
                                -- client's own deployment (20261012040000).
                                select erp.contract_capabilities_in_force(v_tenant)) x), '[]'::jsonb),
$n$),
        ('erp.my_agreement()', '6ce9e52de4c60aa5ff8cafcfbeacca17', 3,
$o$    'subscription', (select jsonb_build_object('plan_code', s.plan_code, 'term_start', s.term_start, 'term_end', s.term_end,
                                               'renews', s.renews, 'currency', s.currency, 'status', s.status)
                       from erp_meta.subscription s where s.tenant_id = v_tenant and s.status <> 'terminated' limit 1),
$o$,
$n$    -- The organisation's own subscription, or on a client's own deployment
    -- the position it holds of its contract (20261012040000).
    'subscription', coalesce(
                      (select jsonb_build_object('plan_code', s.plan_code, 'term_start', s.term_start, 'term_end', s.term_end,
                                                 'renews', s.renews, 'currency', s.currency, 'status', s.status)
                         from erp_meta.subscription s where s.tenant_id = v_tenant and s.status <> 'terminated' limit 1),
                      (select jsonb_build_object('plan_code', sp.plan_code, 'term_start', sp.term_start, 'term_end', sp.term_end,
                                                 'renews', sp.renews, 'currency', sp.currency, 'status', sp.status)
                         from erp_meta.subscription_position sp)),
$n$),
        -- The plans, each with the deployments on it.
        ('public.erp_platform_plans()', '2a03cc38845f7482ce60b1d3c7f5af34', 1,
$o$               'subscribers', (select count(*) from erp_meta.subscription s
                                where s.plan_code = p.code and s.status <> 'terminated'))
$o$,
$n$               -- On a client's own deployment, the position it holds is
               -- a subscriber too (20261012040000).
               'subscribers', (select count(*) from erp_meta.subscription s
                                where s.plan_code = p.code and s.status <> 'terminated')
                              + (select count(*) from erp_meta.subscription_position sp
                                  where sp.plan_code = p.code),
               -- Client deployments whose contract in force is on this
               -- plan (20261012040000).
               'deployments', (select count(*) from erp_meta.contract c
                                where c.plan_code = p.code and c.deployment_code is not null
                                  and c.status in ('active', 'terminating')))
$n$),
        -- The Fleet view: what each client is owed and holds of its contract.
        ('public.erp_platform_deployments()', 'dc452b159ced30f09c8890f5592154bf', 1,
$o$             'last_event', (select jsonb_build_object('phase', e.phase, 'status', e.status, 'detail', e.detail, 'at', e.at)
$o$,
$n$             -- What the client is owed and holds of its contract: the
             -- newest position queued for it, whether the client applied
             -- it or it is pending and since when, the notices pending or
             -- failed, and its usage by meter as the poll last read it, or
             -- that a meter was not measured. Display only
             -- (20261012040000).
             'commercial', (
               select jsonb_build_object(
                        'contract_ref', np.payload -> 'contract_ref',
                        'contract_status', np.payload ->> 'contract_status',
                        'plan_code', np.payload ->> 'plan_code',
                        'position', case when pp.status = 'applied' then 'applied'
                                         when pp.status is not null then 'pending'
                                         else 'none' end,
                        'position_applied_at', (select ap.settled_at from erp_meta.deployment_push ap
                                                 where ap.code = d.code and ap.kind = 'subscription'
                                                   and ap.status = 'applied'
                                                 order by ap.created_at desc, ap.id desc limit 1),
                        'position_pending_since', case when pp.status <> 'applied' then pp.created_at end,
                        'position_detail', pp.detail,
                        'notices_pending', (select count(*) from erp_meta.deployment_push n
                                             where n.code = d.code and n.kind = 'notice'
                                               and n.status in ('pending', 'claimed')),
                        'notices_failed', (select count(*) from erp_meta.deployment_push n
                                            where n.code = d.code and n.kind = 'notice' and n.status = 'failed'),
                        'usage', coalesce((
                          select jsonb_agg(jsonb_build_object(
                                   'meter_code', k.code, 'title', k.title, 'unit', k.unit,
                                   'measured', u.meter_code is not null,
                                   'period_start', u.period_start, 'period_end', u.period_end,
                                   'quantity', u.quantity, 'measured_at', u.measured_at)
                                 order by k.code)
                            from erp_meta.meter_kind k
                            left join lateral (select x.meter_code, x.period_start, x.period_end, x.quantity, x.measured_at
                                                 from erp_meta.deployment_usage x
                                                where x.code = d.code and x.meter_code = k.code
                                                order by x.period_start desc, x.period_end desc
                                                limit 1) u on true), '[]'::jsonb))
                 from (select 1) as one
                 left join lateral (select x.payload from erp_meta.deployment_push x
                                     where x.code = d.code and x.kind = 'subscription'
                                     order by x.created_at desc, x.id desc limit 1) np on true
                 left join lateral (select x.status, x.created_at, x.detail from erp_meta.deployment_push x
                                     where x.code = d.code and x.kind = 'subscription'
                                       and x.status in ('pending', 'claimed', 'applied')
                                     order by x.created_at desc, x.id desc limit 1) pp on true),
             'last_event', (select jsonb_build_object('phase', e.phase, 'status', e.status, 'detail', e.detail, 'at', e.at)
$n$),
        -- A position held where no client is.
        ('erp.entitlement_enforcement_report()', '9d3c981f52e5e1657562c6019b7be9fc', 1,
$o$     and c.confrelid = 'erp.tenant'::regclass

  order by 1, 2
$o$,
$n$     and c.confrelid = 'erp.tenant'::regclass

  union all

  -- 6. A contract position held on a database that is not a client's own.
  --    Only a client's own deployment takes the position its contract holds
  --    from the control plane (erp_meta.apply_pushed_position); held anywhere
  --    else it would set the plan, the bands and the add-ons of every
  --    organisation there (20261012040000).
  select 'a contract position is held on a database that is not a client''s own',
         h.held || ': ' || h.n || ' row(s) on the ' || erp.deployment_kind() || ' deployment'
    from (select 'erp_meta.subscription_position' as held,
                 (select count(*) from erp_meta.subscription_position) as n
          union all
          select 'erp_meta.subscription_position_entitlement',
                 (select count(*) from erp_meta.subscription_position_entitlement)
          union all
          select 'erp_meta.subscription_position_capability',
                 (select count(*) from erp_meta.subscription_position_capability)
          union all
          select 'erp_meta.applied_push', (select count(*) from erp_meta.applied_push)) h
   where h.n > 0
     and erp.deployment_kind() <> 'client'

  order by 1, 2
$n$),
        -- The Fleet view's keys, counted.
        ('erp_test.register_house_suite()', 'dd76bbd14a4056577e8be3f690130d3e', 1,
$o$                 'last_export_taken_at', 'last_export_service_stopped']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 40
$o$,
$n$                 'last_export_taken_at', 'last_export_service_stopped',
                 -- What the client is owed and holds of its contract
                 -- (20261012040000).
                 'commercial']) k)
          and (select count(*) from jsonb_object_keys(v_row2)) = 41
$n$),
        ('erp_test.deployment_lifecycle_suite()', '3bbb80b86f32dd19fde5f5fdb1fab68a', 1,
$o$          and (select count(*) from jsonb_object_keys(v_row)) = 40
$o$,
$n$          -- Forty-one with the commercial key (20261012040000).
          and (select count(*) from jsonb_object_keys(v_row)) = 41
$n$),
        -- A draft is not signed for a deployment being offboarded or retired:
        -- nothing would hold what it sells, and its position would be owed to
        -- nobody, failed as it is queued, and the drift check would call the
        -- contract unprovisioned for its whole term (20261012040000).
        ('erp.sign_contract(uuid,text,text,text)', '54d5bd0902fb3d3c05e9fb6aae2efa7b', 1,
$o$  if not exists (select 1 from erp_meta.contract_document d where d.contract_id = p_contract_id and d.kind = 'order_form') then
    raise exception 'CLOVEERP_CONTRACT_HAS_NO_ORDER_FORM' using errcode = '23514';
  end if;
$o$,
$n$  if not exists (select 1 from erp_meta.contract_document d where d.contract_id = p_contract_id and d.kind = 'order_form') then
    raise exception 'CLOVEERP_CONTRACT_HAS_NO_ORDER_FORM' using errcode = '23514';
  end if;
  -- A draft made while its client deployment was up is not signed once that
  -- deployment is being offboarded or is retired, as no contract is made with
  -- one (20261012040000).
  if c.deployment_code is not null
     and exists (select 1 from erp_meta.deployment d
                  where d.code = c.deployment_code and d.status in ('retiring', 'retired')) then
    raise exception 'CLOVEERP_CONTRACT_DEPLOYMENT_RETIRED: % is %, and a contract is made with a deployment that will hold it',
      c.deployment_code, (select d.status from erp_meta.deployment d where d.code = c.deployment_code)
      using errcode = '23514',
            hint = 'If the client is staying, cancel its offboarding from the Fleet view first; otherwise make the '
                   'contract with a client deployment that is not retired.';
  end if;
$n$),
        -- On a client's own deployment, the position it holds is its
        -- organisation's subscription in the list the console reads.
        ('public.erp_platform_plans()', '2a03cc38845f7482ce60b1d3c7f5af34', 2,
$o$        from erp_meta.subscription s), '[]'::jsonb),
$o$,
$n$        from (select x.tenant_code, x.plan_code, x.term_start, x.term_end, x.renews, x.currency, x.status, x.note,
                     x.updated_at
                from erp_meta.subscription x
              union all
              -- On a client's own deployment, the position it holds of its
              -- contract, as its organisation's subscription, where it has
              -- none of its own (20261012040000).
              select t.code, sp.plan_code, sp.term_start, sp.term_end, sp.renews, sp.currency, sp.status,
                     'the contract position this deployment holds from the control plane', sp.applied_at
                from erp_meta.subscription_position sp
                join erp.tenant t on t.status not in ('deleting', 'deleted')
               where not exists (select 1 from erp_meta.subscription y
                                  where y.tenant_id = t.id and y.status <> 'terminated')) s), '[]'::jsonb),
$n$)
      ) as x(sig, anchor, ord, old, new)
     group by x.sig, x.anchor
     order by x.sig
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261012040000') > 0 then
      raise notice '% already carries 20261012040000', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.anchor then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body this migration was written against', r.sig;
    end if;
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    for i in 1 .. cardinality(r.olds) loop
      if (length(v_def) - length(replace(v_def, r.olds[i], ''))) / length(r.olds[i]) <> 1 then
        raise exception 'CLOVEERP_ANCHOR_MOVED: % does not hold its anchor % exactly once', r.sig, i;
      end if;
      v_def := replace(v_def, r.olds[i], r.news[i]);
    end loop;
    execute v_def;
  end loop;
end
$do$;

comment on function erp.my_agreement() is
  'The organisation''s own agreement for its Plan and usage screen: its contract and documents (on the control '
  'plane), each entitlement with where its limit comes from, its add-ons, its meters, invoices and renewal, and its '
  'subscription, which on a client''s own deployment is the position it holds of its contract (20261012040000).';

comment on function public.erp_platform_plans() is
  'The plans with their entitlements and add-ons, how many organisations subscribe to each (on a client''s own '
  'deployment, the position it holds counts) and how many client deployments have a contract in force on each, '
  'the subscriptions, the entitlement kinds and the enforcement findings, for the Plans view. Platform support and '
  'above (20261012040000).';

comment on function public.erp_platform_deployments() is
  'Every client deployment in the register, with its build''s last step, its newest build request and when it '
  'was made, claimed and settled, whether Start again would start it now, its last release, its health as the poll '
  'last read it, when, and whether one that is up has gone silent (unread for twenty-six hours), where it is served '
  'and the newest address it was moved from that still leads there, when its offboarding began and the day it may '
  'be purged, why it is suspended and since when, its last export, when that copy''s dump began and whether its '
  'service was stopped by then, and what it is owed and holds of its contract with its usage by meter, for the '
  'Fleet view. Platform support and above, on the control plane only (20261011020000, 20261011110000, '
  '20261012010000, 20261012030000, 20261012040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The client applies what it is owed
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.apply_pushed_position(p_push_id uuid, p_queued_at timestamptz, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_held    erp_meta.subscription_position;
  v_fault   text;
  v_unknown text;
  v_detail  text;
  r         record;
begin
  -- On a client's own deployment only (20261012040000).
  if erp.deployment_kind() <> 'client' then
    raise exception 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the % deployment, not a client''s own, so it holds no contract position from the register', erp.deployment_kind()
      using errcode = '55000',
            hint = 'Change a client''s contract on the platform console at cloveerp.com; its own deployment takes '
                   'the position when the fleet''s sync next runs.';
  end if;

  -- What a position says, each in its own form. A fault is named by its
  -- field and never by its value: the refusal reaches a public workflow log.
  if p_push_id is null then
    v_fault := 'it names no push';
  elsif p_queued_at is null then
    v_fault := 'it does not say when it was queued';
  elsif p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    v_fault := 'it is not a set of named values';
  elsif jsonb_typeof(p_payload -> 'plan_code') is distinct from 'string' or btrim(p_payload ->> 'plan_code') = '' then
    v_fault := 'plan_code is not a plan''s code';
  elsif jsonb_typeof(p_payload -> 'contract_ref') is distinct from 'string'
        or not pg_catalog.pg_input_is_valid(p_payload ->> 'contract_ref', 'uuid') then
    v_fault := 'contract_ref is not a contract''s reference';
  elsif coalesce(p_payload ->> 'contract_status', '') not in ('active', 'terminating', 'expired', 'terminated') then
    v_fault := 'contract_status is not active, terminating, expired or terminated';
  elsif coalesce(p_payload ->> 'status', '') not in ('active', 'grace') then
    v_fault := 'status is not active or grace';
  elsif jsonb_typeof(p_payload -> 'term_start') is distinct from 'string'
        or not pg_catalog.pg_input_is_valid(p_payload ->> 'term_start', 'date') then
    v_fault := 'term_start is not a date';
  elsif jsonb_typeof(coalesce(p_payload -> 'term_end', 'null'::jsonb)) not in ('string', 'null')
        or not coalesce(pg_catalog.pg_input_is_valid(p_payload ->> 'term_end', 'date'), true) then
    v_fault := 'term_end is not a date';
  elsif (p_payload ->> 'term_end')::date < (p_payload ->> 'term_start')::date then
    v_fault := 'term_end is before term_start';
  elsif jsonb_typeof(p_payload -> 'renews') is distinct from 'boolean' then
    v_fault := 'renews is not true or false';
  elsif jsonb_typeof(p_payload -> 'currency') is distinct from 'string'
        or (p_payload ->> 'currency') !~ '^[A-Z]{3}$' then
    v_fault := 'currency is not three capital letters';
  elsif jsonb_typeof(coalesce(p_payload -> 'support_severity_code', 'null'::jsonb)) not in ('string', 'null') then
    v_fault := 'support_severity_code is not a code';
  elsif jsonb_typeof(p_payload -> 'entitlements') is distinct from 'array' then
    v_fault := 'entitlements is not a list';
  elsif jsonb_typeof(p_payload -> 'capabilities') is distinct from 'array' then
    v_fault := 'capabilities is not a list';
  end if;

  if v_fault is null then
    for r in select e.value as x, e.ordinality as i
               from jsonb_array_elements(p_payload -> 'entitlements') with ordinality e
              order by e.ordinality
    loop
      if jsonb_typeof(r.x) <> 'object' then
        v_fault := 'is not a set of named values';
      elsif jsonb_typeof(r.x -> 'code') is distinct from 'string' or btrim(r.x ->> 'code') = '' then
        v_fault := 'names no entitlement';
      elsif jsonb_typeof(coalesce(r.x -> 'limit_value', 'null'::jsonb)) not in ('number', 'null') then
        v_fault := 'limit_value is not a number';
      elsif (r.x ->> 'limit_value')::numeric < 0 then
        v_fault := 'limit_value is below none';
      elsif jsonb_typeof(r.x -> 'effective_from') is distinct from 'string'
            or not pg_catalog.pg_input_is_valid(r.x ->> 'effective_from', 'date') then
        v_fault := 'effective_from is not a date';
      elsif jsonb_typeof(coalesce(r.x -> 'effective_to', 'null'::jsonb)) not in ('string', 'null')
            or not coalesce(pg_catalog.pg_input_is_valid(r.x ->> 'effective_to', 'date'), true) then
        v_fault := 'effective_to is not a date';
      elsif (r.x ->> 'effective_to')::date <= (r.x ->> 'effective_from')::date then
        v_fault := 'effective_to is not after effective_from';
      end if;
      if v_fault is not null then
        v_fault := format('entitlements[%s] %s', r.i, v_fault);
        exit;
      end if;
    end loop;
  end if;

  if v_fault is null then
    for r in select e.value as x, e.ordinality as i
               from jsonb_array_elements(p_payload -> 'capabilities') with ordinality e
              order by e.ordinality
    loop
      if jsonb_typeof(r.x) <> 'object' then
        v_fault := 'is not a set of named values';
      elsif jsonb_typeof(r.x -> 'code') is distinct from 'string' or btrim(r.x ->> 'code') = '' then
        v_fault := 'names no feature';
      elsif jsonb_typeof(r.x -> 'effective_from') is distinct from 'string'
            or not pg_catalog.pg_input_is_valid(r.x ->> 'effective_from', 'date') then
        v_fault := 'effective_from is not a date';
      elsif jsonb_typeof(coalesce(r.x -> 'effective_to', 'null'::jsonb)) not in ('string', 'null')
            or not coalesce(pg_catalog.pg_input_is_valid(r.x ->> 'effective_to', 'date'), true) then
        v_fault := 'effective_to is not a date';
      elsif (r.x ->> 'effective_to')::date <= (r.x ->> 'effective_from')::date then
        v_fault := 'effective_to is not after effective_from';
      end if;
      if v_fault is not null then
        v_fault := format('capabilities[%s] %s', r.i, v_fault);
        exit;
      end if;
    end loop;
  end if;

  if v_fault is not null then
    raise exception 'CLOVEERP_PUSH_MALFORMED: the contract position pushed as % is not applied: %', coalesce(p_push_id::text, 'nothing'), v_fault
      using errcode = '22023',
            hint = 'Nothing was changed. The push stays on the control plane and is counted; read its detail in the '
                   'Fleet view, mend what computed it there, and the next sync carries it.';
  end if;

  -- One position at a time. No organisation is needed, and the onboarding's
  -- lock is not taken: the position is the deployment's.
  perform pg_advisory_xact_lock(hashtext('erp_meta.subscription_position'));
  select * into v_held from erp_meta.subscription_position sp;

  if v_held.push_id = p_push_id then
    return jsonb_build_object('push_id', p_push_id, 'outcome', 'replay',
      'detail', format('held already, since %s',
                       to_char(v_held.applied_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')));
  end if;
  if v_held.queued_at > p_queued_at then
    return jsonb_build_object('push_id', p_push_id, 'outcome', 'older',
      'detail', format('the position held was queued later, at %s, so this one is not applied',
                       to_char(v_held.queued_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"')));
  end if;

  -- A plan, band or feature this database does not know yet: it is behind on
  -- its release, and holds what it held until it catches up.
  select string_agg(u.what, ', ' order by u.what) into v_unknown
    from (select 'plan ' || (p_payload ->> 'plan_code') as what
           where not exists (select 1 from erp_meta.plan p where p.code = p_payload ->> 'plan_code')
          union
          select 'entitlement ' || (e ->> 'code')
            from jsonb_array_elements(p_payload -> 'entitlements') e
           where not exists (select 1 from erp_meta.entitlement_kind k where k.code = e ->> 'code')
          union
          select 'feature ' || (c ->> 'code')
            from jsonb_array_elements(p_payload -> 'capabilities') c
           where not exists (select 1 from erp_ref.capability x where x.code = c ->> 'code')) u;
  if v_unknown is not null then
    return jsonb_build_object('push_id', p_push_id, 'outcome', 'waiting',
      'detail', format('this deployment does not know %s yet: it is behind on its release, and holds what it held',
                       v_unknown));
  end if;

  delete from erp_meta.subscription_position_entitlement x where true;
  delete from erp_meta.subscription_position_capability x where true;
  insert into erp_meta.subscription_position as sp
    (only_one, push_id, queued_at, contract_ref, contract_status, plan_code, support_severity_code,
     term_start, term_end, renews, currency, status, applied_at)
  values (true, p_push_id, p_queued_at, (p_payload ->> 'contract_ref')::uuid, p_payload ->> 'contract_status',
          p_payload ->> 'plan_code', p_payload ->> 'support_severity_code',
          (p_payload ->> 'term_start')::date, (p_payload ->> 'term_end')::date, (p_payload ->> 'renews')::boolean,
          p_payload ->> 'currency', p_payload ->> 'status', clock_timestamp())
  on conflict (only_one) do update
     set push_id = excluded.push_id, queued_at = excluded.queued_at, contract_ref = excluded.contract_ref,
         contract_status = excluded.contract_status, plan_code = excluded.plan_code,
         support_severity_code = excluded.support_severity_code, term_start = excluded.term_start,
         term_end = excluded.term_end, renews = excluded.renews, currency = excluded.currency,
         status = excluded.status, applied_at = excluded.applied_at;
  insert into erp_meta.subscription_position_entitlement (entitlement_code, limit_value, effective_from, effective_to)
  select e ->> 'code', (e ->> 'limit_value')::numeric, (e ->> 'effective_from')::date, (e ->> 'effective_to')::date
    from jsonb_array_elements(p_payload -> 'entitlements') e;
  insert into erp_meta.subscription_position_capability (capability_code, effective_from, effective_to)
  select c ->> 'code', (c ->> 'effective_from')::date, (c ->> 'effective_to')::date
    from jsonb_array_elements(p_payload -> 'capabilities') c;

  v_detail := format('holds the %s plan of contract %s (%s), with %s band(s) and %s feature(s), as queued at %s',
                     p_payload ->> 'plan_code', p_payload ->> 'contract_ref', p_payload ->> 'contract_status',
                     jsonb_array_length(p_payload -> 'entitlements'), jsonb_array_length(p_payload -> 'capabilities'),
                     to_char(p_queued_at at time zone 'UTC', 'FMDD Mon YYYY HH24:MI:SS "UTC"'));
  insert into erp_meta.applied_push as ap (push_id, kind, queued_at, result)
  values (p_push_id, 'subscription', p_queued_at, jsonb_build_object('outcome', 'applied', 'detail', v_detail))
  on conflict (push_id) do update set applied_at = now(), result = excluded.result;

  return jsonb_build_object('push_id', p_push_id, 'outcome', 'applied', 'detail', v_detail);
end;
$$;

revoke all on function erp_meta.apply_pushed_position(uuid, timestamptz, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.apply_pushed_position(uuid, timestamptz, jsonb) is
  'Called by the fleet''s sync on a client''s own deployment with the newest position the control plane queued for '
  'it (its push id, when it was queued, and erp_meta.deployment_subscription_payload''s shape): answers '
  '{push_id, outcome, detail}, the outcome replay when it is held already, older when the one held was queued '
  'later, waiting when it names a plan, band or feature this database does not know yet, and applied otherwise, '
  'when it replaces what is held. Refuses CLOVEERP_PUSH_MALFORMED for one that does not read as a position, and '
  'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT anywhere but a client. Needs no organisation; never writes '
  'erp_meta.subscription or an organisation''s status. Trusted build role only (20261012040000).';

create or replace function erp_meta.apply_pushed_notices(p_notices jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  -- The notices a client is told of: the contract's own events, and nothing a
  -- default route would mail or a screen would act on.
  c_types   constant text[] := array[
    'commercial.contract_signed', 'commercial.contract_amended', 'commercial.contract_renewed',
    'commercial.non_renewal_recorded', 'commercial.term_ended', 'commercial.invoice_issued',
    'commercial.renewal_announced', 'commercial.notice_deadline_announced', 'commercial.review_announced',
    'commercial.uplift_announced'];
  v_out     jsonb := '[]'::jsonb;
  v_org     uuid;
  v_n       integer;
  v_held    text;
  v_wait    text;
  v_fault   text;
  v_push    uuid;
  v_at      timestamptz;
  v_type    text;
  v_version integer;
  v_prior   jsonb;
  v_new     uuid;
  v_event   uuid;
  r         record;
begin
  -- On a client's own deployment only (20261012040000).
  if erp.deployment_kind() <> 'client' then
    raise exception 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the % deployment, not a client''s own, so it is told no notices from the register', erp.deployment_kind()
      using errcode = '55000',
            hint = 'Change a client''s contract on the platform console at cloveerp.com; its own deployment is told '
                   'when the fleet''s sync next runs.';
  end if;
  if p_notices is null or jsonb_typeof(p_notices) <> 'array' then
    v_fault := 'they are not a list';
  elsif exists (select 1 from jsonb_array_elements(p_notices) x
                 where jsonb_typeof(x) <> 'object'
                    or jsonb_typeof(x -> 'push_id') is distinct from 'string'
                    or not pg_catalog.pg_input_is_valid(x ->> 'push_id', 'uuid')) then
    v_fault := 'one of them names no push';
  end if;
  if v_fault is not null then
    raise exception 'CLOVEERP_PUSH_MALFORMED: the notices pushed are not applied: %', v_fault
      using errcode = '22023',
            hint = 'Nothing was changed. Pass the notices due as a list, each with its push_id, queued_at, '
                   'event_type, event_version and payload.';
  end if;
  if jsonb_array_length(p_notices) = 0 then
    return v_out;
  end if;

  -- The one organisation, found under the lock an onboarding takes, without
  -- waiting for it: an onboarding may take most of a minute.
  if not pg_try_advisory_xact_lock(hashtext('erp.require_client_organisation')) then
    v_wait := 'an onboarding is under way, so the organisation to tell is not known yet';
  else
    select count(*), string_agg(t.code, ', ' order by t.code) into v_n, v_held
      from erp.tenant t
     where t.status not in ('deleting', 'deleted');
    if v_n = 0 then
      v_wait := 'no organisation yet: the notice waits for the client to be onboarded';
    elsif v_n > 1 then
      v_wait := format('this deployment holds %s, and a client''s own deployment holds one organisation', v_held);
    else
      select t.id into v_org from erp.tenant t where t.status not in ('deleting', 'deleted');
    end if;
  end if;
  if v_wait is not null then
    return (select jsonb_agg(jsonb_build_object('push_id', x ->> 'push_id', 'outcome', 'waiting', 'detail', v_wait)
                             order by o)
              from jsonb_array_elements(p_notices) with ordinality a(x, o));
  end if;

  perform erp_meta.act_in_tenant(v_org);
  for r in select x as item, o from jsonb_array_elements(p_notices) with ordinality a(x, o) order by o loop
    v_push := (r.item ->> 'push_id')::uuid;
    -- In order: one waiting holds back every notice after it.
    if v_wait is not null then
      v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'waiting',
                 'detail', 'waits behind an earlier notice that is waiting'));
      continue;
    end if;
    begin
      v_fault := null;
      if jsonb_typeof(r.item -> 'queued_at') is distinct from 'string'
         or not pg_catalog.pg_input_is_valid(r.item ->> 'queued_at', 'timestamptz') then
        v_fault := 'it does not say when it was queued';
      elsif jsonb_typeof(r.item -> 'event_type') is distinct from 'string' then
        v_fault := 'it names no event';
      elsif jsonb_typeof(coalesce(r.item -> 'event_version', 'null'::jsonb)) not in ('number', 'null')
            or not coalesce(pg_catalog.pg_input_is_valid(r.item ->> 'event_version', 'integer'), true) then
        v_fault := 'its event_version is not a whole number';
      elsif jsonb_typeof(r.item -> 'payload') is distinct from 'object' then
        v_fault := 'its payload is not a set of named values';
      end if;

      if v_fault is not null then
        v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'refused',
                   'detail', 'CLOVEERP_PUSH_MALFORMED: ' || v_fault));
      else
        v_at := (r.item ->> 'queued_at')::timestamptz;
        v_type := r.item ->> 'event_type';
        -- One queued before notices carried their version is read in the
        -- version current here, so none waits for ever (20261012040000).
        v_version := coalesce((r.item ->> 'event_version')::integer,
                              (select et.version from erp_ref.event_type et
                                where et.code = v_type and et.is_current));
        select ap.result into v_prior from erp_meta.applied_push ap where ap.push_id = v_push;
        if found then
          v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'replay',
                     'detail', 'told already', 'event_id', v_prior -> 'event_id'));
        elsif not (v_type = any (c_types)) then
          v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'refused',
                     'detail', format('%s is not one of the notices a client is told of', v_type)));
        elsif not exists (select 1 from erp_ref.event_type et where et.code = v_type and et.version = v_version) then
          v_wait := format('%s version %s is not known here yet: this deployment is behind on its release',
                           v_type, coalesce(v_version::text, 'current'));
          v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'waiting',
                     'detail', v_wait));
        else
          v_new := null;
          insert into erp_meta.applied_push as ap (push_id, kind, queued_at, result)
          values (v_push, 'notice', v_at, '{}'::jsonb)
          on conflict (push_id) do nothing
          returning ap.push_id into v_new;
          if v_new is null then
            v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'replay',
                       'detail', 'told already',
                       'event_id', (select ap.result -> 'event_id' from erp_meta.applied_push ap
                                     where ap.push_id = v_push)));
          else
            -- Dated when it was queued, in the version it was written in, with
            -- its push as the correlation, and no source of its own.
            perform erp.set_correlation_id(v_push);
            v_event := erp.append_event(v_type, 'tenant', v_org, r.item -> 'payload',
                                        p_occurred_at => v_at, p_event_version => v_version);
            update erp_meta.applied_push ap
               set result = jsonb_build_object('event_id', v_event)
             where ap.push_id = v_push;
            v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'applied',
                       'detail', format('told as %s', v_type), 'event_id', v_event));
          end if;
        end if;
      end if;
    exception when others then
      -- A payload its event refuses is refused for good; anything else waits
      -- for the next run, and holds back the notices after it. The message
      -- only: the payload is in the detail, which goes nowhere.
      if sqlerrm like 'CLOVEERP_EVENT_%' or sqlerrm like 'CLOVEERP_UNKNOWN_EVENT_TYPE%' then
        v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'refused',
                   'detail', left(sqlerrm, 500)));
      else
        v_wait := left(sqlerrm, 500);
        v_out := v_out || jsonb_build_array(jsonb_build_object('push_id', v_push, 'outcome', 'waiting',
                   'detail', v_wait));
      end if;
    end;
  end loop;
  perform erp.set_correlation_id(null);
  perform erp_meta.stop_acting_in_tenant();
  return v_out;
end;
$$;

revoke all on function erp_meta.apply_pushed_notices(jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.apply_pushed_notices(jsonb) is
  'Called by the fleet''s sync on a client''s own deployment with the notices due, in order, each '
  '{push_id, queued_at, event_type, event_version, payload}: appends each once to its one organisation''s event '
  'stream, dated when it was queued, in its version (the version current here when it names none), with its push '
  'as the correlation and no source of its own. '
  'Answers a list of {push_id, outcome, detail, event_id}: applied, replay (told already, with the same event), '
  'refused (not one of the ten notices a client is told of, or a payload its event refuses) or waiting (no '
  'organisation yet, an onboarding under way, a version not known here yet), a waiting notice holding back every '
  'one after it. Trusted build role only (20261012040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The control plane queues, hands out and settles
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_meta.queue_deployment_push(p_code text, p_kind text, p_contract_id uuid, p_payload jsonb)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired constant text := 'retired';
  v_id      uuid;
  v_payload jsonb := p_payload;
  v_status  text;
  v_built   timestamptz;
  v_sync    uuid;
begin
  -- A notice carries its event's version as it was queued, so a client a
  -- release ahead reads it in the version it was written in (20261012040000).
  if p_kind = 'notice' and jsonb_typeof(v_payload) = 'object' and not (v_payload ? 'event_version') then
    v_payload := v_payload || coalesce((select jsonb_build_object('event_version', et.version)
                                          from erp_ref.event_type et
                                         where et.code = v_payload ->> 'event_type' and et.is_current), '{}'::jsonb);
  end if;

  select d.status, d.built_at into v_status, v_built from erp_meta.deployment d where d.code = p_code;

  -- A retired deployment is owed nothing more: the push is kept, as failed
  -- (20261012040000).
  if v_status = c_retired then
    insert into erp_meta.deployment_push (code, kind, contract_id, payload, status, settled_at, detail)
    values (p_code, p_kind, p_contract_id, v_payload, 'failed', clock_timestamp(),
            'the deployment was retired, so it is owed nothing more')
    returning id into v_id;
    return v_id;
  end if;

  -- One position pending per deployment: the newest is what it is owed, so
  -- one not yet applied is superseded rather than applied after it
  -- (20261011090000).
  if p_kind = 'subscription' then
    update erp_meta.deployment_push p
       set status = 'superseded', settled_at = clock_timestamp(), detail = 'a later position was queued'
     where p.code = p_code and p.kind = 'subscription' and p.status = 'pending';
  end if;
  insert into erp_meta.deployment_push (code, kind, contract_id, payload)
  values (p_code, p_kind, p_contract_id, v_payload)
  returning id into v_id;

  -- A deployment that is up is asked to sync, once while one is waiting: the
  -- sweep wakes it in minutes, or the hourly sync carries it. One still being
  -- built is synced by its build's last step. Never allowed to stop the sweep
  -- or the door that queued it (20261012040000).
  if v_status in ('built', 'live', 'suspended') or (v_status = 'retiring' and v_built is not null) then
    begin
      select r.id into v_sync
        from erp_meta.fleet_request r
       where r.kind = 'sync' and r.status = 'requested' and r.payload ->> 'code' = p_code
       order by r.created_at
       limit 1
       for update;
      if v_sync is null then
        insert into erp_meta.fleet_request (kind, payload, reason)
        values ('sync', jsonb_build_object('code', p_code),
                'the control plane queued what this client deployment is owed of its contract');
      end if;
    exception when others then
      raise notice 'the sync of % was not asked for, and the hourly sync carries what it is owed: %', p_code, sqlerrm;
    end;
  end if;
  return v_id;
end;
$$;

comment on function erp_meta.queue_deployment_push(text, text, uuid, jsonb) is
  'Queues what a client deployment is owed of its contract: a position (superseding one still pending) or a notice '
  '(stamped with its event''s current version). One to a retired deployment is kept as failed; one to a deployment '
  'that is up asks for a sync, once while one waits, and never stops the routine that queued it (20261011090000, '
  '20261012040000).';

create or replace function erp_meta.deployment_pushes_due(p_code text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  d erp_meta.deployment := erp_meta.deployment_row(p_code);
begin
  -- The newest position, whatever the client did with it before, so a client
  -- rebuilt or restored takes it again; and the notices waiting, oldest first.
  -- When each was queued travels beside it, never inside it (20261012040000).
  return jsonb_build_object(
    'code', d.code,
    'position', (select jsonb_build_object('id', p.id, 'created_at', p.created_at, 'payload', p.payload)
                   from erp_meta.deployment_push p
                  where p.code = d.code and p.kind = 'subscription'
                    and p.status in ('pending', 'claimed', 'applied')
                  order by p.created_at desc, p.id desc
                  limit 1),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'created_at', n.created_at,
                                                              'payload', n.payload)
                                          order by n.created_at, n.id)
                           from (select p.id, p.created_at, p.payload
                                   from erp_meta.deployment_push p
                                  where p.code = d.code and p.kind = 'notice'
                                    and p.status in ('pending', 'claimed')
                                  order by p.created_at, p.id
                                  limit 200) n), '[]'::jsonb));
end;
$$;

revoke all on function erp_meta.deployment_pushes_due(text) from public, anon, authenticated, service_role;

comment on function erp_meta.deployment_pushes_due(text) is
  'What a client deployment is owed, for the fleet''s sync: {code, position, notices}, the position the newest '
  'subscription push not superseded or failed, as {id, created_at, payload}, or null; the notices the pending '
  'notice pushes, oldest first, two hundred at most, each {id, created_at, payload}. Nothing is claimed. Trusted '
  'build role only (20261012040000).';

create or replace function erp_meta.settle_deployment_pushes(p_code text, p_run text, p_results jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d         erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_run     text := btrim(coalesce(p_run, ''));
  v_fault   text;
  p         erp_meta.deployment_push;
  r         record;
  v_applied integer := 0;
  v_again   integer := 0;
  v_super   integer := 0;
  v_waiting integer := 0;
  v_refused integer := 0;
  v_failed  integer := 0;
  v_left    integer := 0;
begin
  -- Refused only for what it cannot read; for any state a push is in, it says
  -- what it did and leaves the rest as it is (20261012040000).
  if v_run = '' or length(v_run) > 200 then
    v_fault := 'it names no run';
  elsif p_results is null or jsonb_typeof(p_results) <> 'array' then
    v_fault := 'the answers are not a list';
  else
    select format('answer %s %s', y.o, y.fault) into v_fault
      from (select x.o, case
                     when jsonb_typeof(x.a) <> 'object' then 'is not a set of named values'
                     when jsonb_typeof(coalesce(x.a -> 'push_id', x.a -> 'id')) is distinct from 'string'
                          or not pg_catalog.pg_input_is_valid(coalesce(x.a ->> 'push_id', x.a ->> 'id'), 'uuid')
                       then 'names no push'
                     when coalesce(x.a ->> 'outcome', '') not in ('applied', 'replay', 'older', 'waiting', 'refused')
                       then 'says none of applied, replay, older, waiting or refused'
                     when jsonb_typeof(coalesce(x.a -> 'detail', 'null'::jsonb)) not in ('string', 'null')
                       then 'has a detail that is not words'
                   end as fault
              from jsonb_array_elements(p_results) with ordinality x(a, o)) y
     where y.fault is not null
     order by y.o
     limit 1;
  end if;
  if v_fault is not null then
    raise exception 'CLOVEERP_PUSH_SETTLE_UNREADABLE: what % answered is not settled: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Settle with the run''s id and the list of the client''s answers, each naming its push_id and its '
                   'outcome, as the apply routines return them.';
  end if;

  for r in
    select coalesce(x.a ->> 'push_id', x.a ->> 'id')::uuid as push_id, x.a ->> 'outcome' as outcome,
           left(coalesce(btrim(x.a ->> 'detail'), ''), 2000) as said, x.o
      from jsonb_array_elements(p_results) with ordinality x(a, o)
     order by x.o
  loop
    select * into p from erp_meta.deployment_push x where x.id = r.push_id for update;
    -- Not this deployment's, or settled for good (superseded, failed): left
    -- as it is.
    if p.id is null or p.code <> d.code or p.status not in ('pending', 'claimed', 'applied') then
      v_left := v_left + 1;
      continue;
    end if;

    if r.outcome in ('applied', 'replay') then
      if p.status <> 'applied' then
        update erp_meta.deployment_push x
           set status = 'applied', settled_at = clock_timestamp(), run_id = v_run,
               detail = coalesce(nullif(r.said, ''),
                                 case r.outcome when 'replay' then 'the client held it already'
                                                else 'applied by the client' end)
         where x.id = p.id;
        v_applied := v_applied + 1;
      elsif p.kind = 'subscription' then
        -- The position is sent every run: the client holding it still, or
        -- taking it again after a rebuild, is recorded.
        update erp_meta.deployment_push x
           set settled_at = clock_timestamp(), run_id = v_run,
               detail = left(case r.outcome when 'applied' then 're-applied by the client'
                                            else 'the client holds it still' end
                             || case when r.said <> '' then ': ' || r.said else '' end, 2000)
         where x.id = p.id;
        v_again := v_again + 1;
      else
        v_left := v_left + 1;
      end if;
    elsif p.status = 'applied' then
      -- Applied already: nothing a later answer says undoes it.
      v_left := v_left + 1;
    elsif r.outcome = 'older' then
      if p.kind = 'subscription' then
        update erp_meta.deployment_push x
           set status = 'superseded', settled_at = clock_timestamp(), run_id = v_run,
               detail = coalesce(nullif(r.said, ''), 'the client holds a position queued later')
         where x.id = p.id;
        v_super := v_super + 1;
      else
        v_left := v_left + 1;
      end if;
    elsif r.outcome = 'waiting' then
      -- Not ready for it yet: tried again next run, and not counted.
      update erp_meta.deployment_push x
         set settled_at = clock_timestamp(), run_id = v_run,
             detail = coalesce(nullif(r.said, ''), 'the client is not ready for it yet')
       where x.id = p.id;
      v_waiting := v_waiting + 1;
    elsif p.kind = 'subscription' then
      -- A position is never failed by the sync: it stays owed, counted, and
      -- the contract provisioning check sees it as queued.
      update erp_meta.deployment_push x
         set attempts = x.attempts + 1, settled_at = clock_timestamp(), run_id = v_run,
             detail = coalesce(nullif(r.said, ''), 'refused by the client')
       where x.id = p.id;
      v_refused := v_refused + 1;
    else
      update erp_meta.deployment_push x
         set status = 'failed', attempts = x.attempts + 1, settled_at = clock_timestamp(), run_id = v_run,
             detail = coalesce(nullif(r.said, ''), 'refused by the client')
       where x.id = p.id;
      v_failed := v_failed + 1;
    end if;
  end loop;

  return jsonb_build_object('code', d.code, 'run', v_run, 'applied', v_applied, 'reapplied', v_again,
                            'superseded', v_super, 'waiting', v_waiting, 'refused', v_refused,
                            'failed', v_failed, 'left', v_left);
end;
$$;

revoke all on function erp_meta.settle_deployment_pushes(text, text, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.settle_deployment_pushes(text, text, jsonb) is
  'Records what a client deployment answered to the pushes it was handed, each {push_id, outcome, detail}, with '
  'the run that carried them. A position applied or replayed is applied (one applied already records the client '
  'holding it still), older is superseded, waiting stays pending, refused stays pending and is counted; a notice '
  'applied or replayed is applied, waiting stays pending, refused is failed and counted. A push not this '
  'deployment''s, superseded or failed is left as it is. Answers the counts; refuses '
  'CLOVEERP_PUSH_SETTLE_UNREADABLE only for answers it cannot read. Trusted build role only (20261012040000).';

create or replace function erp_meta.record_deployment_usage(p_code text, p_rows jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  d         erp_meta.deployment := erp_meta.deployment_row(p_code);
  v_fault   text;
  r         record;
  v_n       integer := 0;
  v_skipped text[] := array[]::text[];
begin
  -- Each reading in its own form; one this register does not keep refuses the
  -- lot, and nothing is recorded (20261012040000).
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    v_fault := 'the readings are not a list';
  elsif jsonb_array_length(p_rows) > 1000 then
    v_fault := 'there are more than a thousand readings';
  else
    for r in select x.a, x.o from jsonb_array_elements(p_rows) with ordinality x(a, o) order by x.o loop
      if jsonb_typeof(r.a) <> 'object' then
        v_fault := 'is not a set of named values';
      elsif jsonb_typeof(r.a -> 'meter_code') is distinct from 'string' or btrim(r.a ->> 'meter_code') = '' then
        v_fault := 'names no meter';
      elsif jsonb_typeof(r.a -> 'period_start') is distinct from 'string'
            or not pg_catalog.pg_input_is_valid(r.a ->> 'period_start', 'date') then
        v_fault := 'period_start is not a date';
      elsif jsonb_typeof(r.a -> 'period_end') is distinct from 'string'
            or not pg_catalog.pg_input_is_valid(r.a ->> 'period_end', 'date') then
        v_fault := 'period_end is not a date';
      elsif (r.a ->> 'period_end')::date < (r.a ->> 'period_start')::date then
        v_fault := 'period_end is before period_start';
      elsif jsonb_typeof(r.a -> 'quantity') is distinct from 'number' then
        v_fault := 'quantity is not a number';
      elsif (r.a ->> 'quantity')::numeric < 0 then
        v_fault := 'quantity is below none';
      elsif jsonb_typeof(coalesce(r.a -> 'measured_at', 'null'::jsonb)) not in ('string', 'null')
            or not coalesce(pg_catalog.pg_input_is_valid(r.a ->> 'measured_at', 'timestamptz'), true) then
        v_fault := 'measured_at is not a time';
      end if;
      if v_fault is not null then
        v_fault := format('reading %s %s', r.o, v_fault);
        exit;
      end if;
    end loop;
  end if;
  if v_fault is not null then
    raise exception 'CLOVEERP_DEPLOYMENT_USAGE_INVALID: the usage read from % is not recorded: %', d.code, v_fault
      using errcode = '22023',
            hint = 'Send a list of readings, each with its meter, the first and last day of its month, its quantity '
                   'as a number of none or more, and when it was measured, as the poll reads them from the client.';
  end if;

  -- A meter this register does not know yet (the client is a release ahead)
  -- is passed over and named. A reading replaces the one before for the same
  -- month; none is deleted.
  for r in select x.a from jsonb_array_elements(p_rows) x(a) loop
    if not exists (select 1 from erp_meta.meter_kind k where k.code = r.a ->> 'meter_code') then
      v_skipped := array_append(v_skipped, r.a ->> 'meter_code');
      continue;
    end if;
    insert into erp_meta.deployment_usage as u
      (code, meter_code, period_start, period_end, quantity, measured_at, recorded_at)
    values (d.code, r.a ->> 'meter_code', (r.a ->> 'period_start')::date, (r.a ->> 'period_end')::date,
            (r.a ->> 'quantity')::numeric, coalesce((r.a ->> 'measured_at')::timestamptz, now()), now())
    on conflict (code, meter_code, period_start, period_end) do update
       set quantity = excluded.quantity, measured_at = excluded.measured_at, recorded_at = excluded.recorded_at;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('code', d.code, 'recorded', v_n,
                            'skipped', to_jsonb(array(select distinct s from unnest(v_skipped) s order by s)));
end;
$$;

revoke all on function erp_meta.record_deployment_usage(text, jsonb) from public, anon, authenticated, service_role;

comment on function erp_meta.record_deployment_usage(text, jsonb) is
  'Called by the poll with a client deployment''s usage as its own database measured it, a list of {meter_code, '
  'period_start, period_end, quantity, measured_at}: each replaces the reading kept for the same meter and month, '
  'and none is deleted. A meter this register does not know yet is passed over and named. Answers {code, '
  'recorded, skipped}; refuses CLOVEERP_DEPLOYMENT_USAGE_INVALID for a reading not in its form, recording nothing. '
  'Trusted build role only (20261012040000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.a_client_holds_its_contract_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  -- The register's own word, named rather than written inline
  -- (erp.record_status_literal_report(), 20261011040000).
  c_retired  constant text := 'retired';
  c_finding  constant text := 'a contract position is held on a database that is not a client''s own';
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_step     text := 'marking the control plane';
  v_state    text;
  v_kind     text := erp.deployment_kind();
  v_origin   jsonb := (select s.value from erp_meta.platform_setting s where s.key = 'deployment.app_origin');
  v_held0    bigint := (select count(*) from erp_meta.subscription_position)
                       + (select count(*) from erp_meta.subscription_position_entitlement)
                       + (select count(*) from erp_meta.subscription_position_capability)
                       + (select count(*) from erp_meta.applied_push);
  rp         record;
  ro         record;
  ad         uuid := gen_random_uuid();
  ow         uuid := gen_random_uuid();
  v_platform uuid;
  v_other    uuid;
  v_tenant   uuid;
  v_pcode    text;
  v_ocode    text;
  v_dcode    text;
  v_bcode    text;
  v_rcode    text;
  v_kcode    text;
  v_qd       uuid;
  v_qd2      uuid;
  v_dc2      uuid;
  v_signed   text;
  v_dc       uuid;
  v_inv      uuid;
  v_amend    uuid;
  v_s1       uuid;
  v_s2       uuid;
  v_s3       uuid;
  v_m1       uuid;
  v_m2       uuid;
  v_m3       uuid;
  v_m4       uuid;
  v_nb       uuid;
  v_nr       uuid;
  v_x1       uuid := gen_random_uuid();
  v_x2       uuid := gen_random_uuid();
  v_x3       uuid := gen_random_uuid();
  v_x4       uuid;
  v_x5       uuid := gen_random_uuid();
  v_x4_at    timestamptz;
  v_old      jsonb;
  v_s1_at    timestamptz;
  v_s2_at    timestamptz;
  v_s1_pay   jsonb;
  v_s2_pay   jsonb;
  v_due      jsonb;
  v_items    jsonb;
  v_pos      jsonb;
  v_told     jsonb;
  v_wait     jsonb;
  v_res      jsonb;
  v_res2     jsonb;
  v_res3     jsonb;
  v_json     jsonb;
  v_json2    jsonb;
  v_json3    jsonb;
  v_row      jsonb;
  v_got      text;
  v_got2     text;
  v_got3     text;
  v_got4     text;
  v_got5     text;
  v_status   text;
  v_session  uuid;
  v_at       timestamptz;
  v_lim      numeric;
  v_lim2     numeric;
  v_used_c   numeric;
  v_used_s   numeric;
  v_used_u   numeric;
  v_ok       boolean;
  v_ok2      boolean;
  v_n        integer;
  v_n2       integer;
  v_n3       integer;
begin
  begin
    v_pcode := 'zzhcp-' || v_tag;
    v_ocode := 'zzhco-' || v_tag;
    v_dcode := 'zzhcd-' || v_tag;
    v_bcode := 'zzhcb-' || v_tag;
    v_rcode := 'zzhcr-' || v_tag;
    -- Where the client is served on its own deployment: not its code in the
    -- register, as after a rename, and the client never compares them.
    v_kcode := 'zzhck-' || v_tag;

    -- The control plane's marker, undone at the end with everything else.
    delete from erp_meta.platform_setting where key = 'deployment.kind';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'a_client_holds_its_contract_suite');

    -- ── 1. Off a client ─────────────────────────────────────────────────────
    v_step := 'applying a position and notices off a client';
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), '{}'::jsonb);
      v_got := 'a position was applied on the control plane';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.apply_pushed_notices('[]'::jsonb);
      v_got2 := 'notices were applied on the control plane';
    exception when others then
      v_got2 := sqlerrm;
    end;
    update erp_meta.platform_setting s set value = '"demonstration"'::jsonb where s.key = 'deployment.kind';
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), '{}'::jsonb);
      v_got3 := 'a position was applied on the demonstration';
    exception when others then
      v_got3 := sqlerrm;
    end;
    update erp_meta.platform_setting s set value = '"production"'::jsonb where s.key = 'deployment.kind';
    v_n := (select count(*) from erp.entitlement_enforcement_report() f where f.finding = c_finding);
    -- A position held here anyway is a finding, and the diagnostic says so.
    insert into erp_meta.applied_push (push_id, kind, queued_at, result)
    values (v_x1, 'notice', clock_timestamp(), '{}'::jsonb);
    v_n2 := (select count(*) from erp.entitlement_enforcement_report() f
              where f.finding = c_finding and f.detail like 'erp_meta.applied_push: % on the production deployment');
    begin
      perform erp.assert_entitlements_enforceable();
      v_got4 := 'it passed';
    exception when others then
      v_got4 := sqlerrm;
    end;
    delete from erp_meta.applied_push ap where ap.push_id = v_x1;
    v_cases := v_cases + 1;
    case_name := 'off a client''s own deployment the position and the notices are refused, and a position held there is a finding';
    passed := v_got like 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the production deployment, not a client''s own%'
          and v_got2 like 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the production deployment, not a client''s own%'
          and v_got3 like 'CLOVEERP_NOT_A_CLIENT_DEPLOYMENT: this is the demonstration deployment, not a client''s own%'
          and v_n = 0 and v_n2 = 1
          and v_got4 like 'CLOVEERP_ENTITLEMENT_UNENFORCEABLE%'
          and not exists (select 1 from erp.entitlement_enforcement_report() f where f.finding = c_finding);
    detail := left(v_got, 90) || ' / ' || left(v_got3, 60) || format(' / %s then %s finding(s) / ', v_n, v_n2)
              || left(v_got4, 60);
    return next;

    -- The control plane: an organisation selling, another organisation, an
    -- owner, a price book and a quote for a client deployment.
    v_step := 'standing up the platform organisation';
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Client Contracts', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into ro from erp.provision_tenant(v_ocode, 'Omega Foods Ltd', 'admin@' || v_ocode || '.test', 'Other Admin');
    v_other := ro.tenant_id;
    insert into auth.users (id, email) values (ad, 'admin@' || v_pcode || '.test'), (ow, 'owner@' || v_pcode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@' || v_pcode || '.test', ow, 'Client Contract Suite Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'The client contract suite sells from its own organisation, and undoes it.');

    v_step := 'opening the price book and accepting a quote';
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.configure_commercial(10, 'administrator');
    perform erp.open_price_book('PB-2026', 'List 2026', array['GBP'], current_date - 1, null);
    perform erp_test.close_bootstrap_window(v_platform);
    perform erp.upsert_price_item('PLAN-STD', 'Standard plan', 'plan_tier', 'standard');
    perform erp.upsert_price_item('USERS-250', 'Up to 250 users', 'user_band', null, null, 'users', 101, 250);
    perform erp.upsert_price_item('CAP-SERIAL', 'Serialisation', 'capability_addon', null, 'serialisation');
    perform erp.set_rate('PB-2026', 'PLAN-STD', 'GBP', 1200000);
    perform erp.set_rate('PB-2026', 'USERS-250', 'GBP', 500000);
    perform erp.set_rate('PB-2026', 'CAP-SERIAL', 'GBP', 150000);
    perform erp.set_cost_model('PLAN-STD', 'GBP', 300000, 100000, 50000);
    perform erp.set_cost_model('USERS-250', 'GBP', 100000, 50000, 0);
    perform erp.set_cost_model('CAP-SERIAL', 'GBP', 20000, 10000, 0);
    v_qd := erp.open_commercial_quote('DELTA', 'Delta Client Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_dcode);
    perform erp.add_quote_line(v_qd, 'PLAN-STD');
    perform erp.add_quote_line(v_qd, 'USERS-250');
    perform erp.add_quote_line(v_qd, 'CAP-SERIAL');
    perform erp.submit_quote(v_qd);
    perform erp.issue_quote(v_qd);
    perform erp.quote_transition(v_qd, 'accept', 'order form returned signed');

    -- Three client deployments: one live, one being built, one retired.
    v_step := 'registering three client deployments';
    insert into erp_meta.deployment (code, client_name, status, owner_email, note)
    values (v_dcode, 'Delta Client Ltd', 'live', 'admin@' || v_dcode || '.test', 'a_client_holds_its_contract_suite'),
           (v_bcode, 'Building Client Ltd', 'building', null, 'a_client_holds_its_contract_suite'),
           (v_rcode, 'Gone Client Ltd', c_retired, null, 'a_client_holds_its_contract_suite');

    -- ── 2. Queueing ─────────────────────────────────────────────────────────
    -- The real routines queue what the client is owed: signing (a position
    -- and a notice), invoicing (a notice), and an amendment (a position that
    -- supersedes the first, and a notice).
    v_step := 'signing, invoicing and amending the client''s contract';
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_dc := erp.create_contract_from_quote(v_qd, v_dcode, 'Delta Client Ltd', 'Clove Ltd', current_date);
    v_s1 := erp.sign_contract(v_dc, 'D. Client, Finance Director', 'P. Owner, Clove Ltd',
                              'Agreement to the order form and the terms it names');
    v_inv := (select i.id from erp_meta.contract_invoice i where i.contract_id = v_dc order by i.period_start limit 1);
    perform erp.issue_contract_invoice(v_inv);
    v_amend := erp.amend_contract(v_dc, 'More users from tomorrow', current_date + 1,
                                  '{"entitlements": [{"code": "users", "limit_value": 500}]}'::jsonb,
                                  'growth at a second site');
    v_s2 := erp.sign_amendment(v_amend, 'D. Client, Finance Director', 'P. Owner, Clove Ltd', 'Agreement to amendment 1');
    v_m1 := (select p.id from erp_meta.deployment_push p
              where p.code = v_dcode and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.contract_signed');
    v_m2 := (select p.id from erp_meta.deployment_push p
              where p.code = v_dcode and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.invoice_issued');
    v_m3 := (select p.id from erp_meta.deployment_push p
              where p.code = v_dcode and p.kind = 'notice' and p.payload ->> 'event_type' = 'commercial.contract_amended');
    v_step := 'queueing for a deployment being built and one retired';
    v_nb := erp_meta.queue_deployment_push(v_bcode, 'notice', null,
              jsonb_build_object('event_type', 'commercial.review_announced',
                                 'payload', jsonb_build_object('contract_id', gen_random_uuid(),
                                                               'due_on', current_date + 30, 'days_left', 30)));
    v_nr := erp_meta.queue_deployment_push(v_rcode, 'notice', null,
              jsonb_build_object('event_type', 'commercial.review_announced', 'event_version', 1,
                                 'payload', jsonb_build_object('contract_id', gen_random_uuid(),
                                                               'due_on', current_date + 30, 'days_left', 30)));
    -- A draft made while a deployment is up is not signed once it is retired:
    -- its position would be failed as it is queued, and the drift check would
    -- call the contract unprovisioned for its whole term.
    v_step := 'signing a draft whose deployment is being offboarded since it was made';
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    v_qd2 := erp.open_commercial_quote('BUILDING', 'Building Client Ltd', 'PB-2026', 'annual', 12, 'GBP', 30, v_bcode);
    perform erp.add_quote_line(v_qd2, 'PLAN-STD');
    perform erp.submit_quote(v_qd2);
    perform erp.issue_quote(v_qd2);
    perform erp.quote_transition(v_qd2, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_dc2 := erp.create_contract_from_quote(v_qd2, v_bcode, 'Building Client Ltd', 'Clove Ltd', current_date);
    -- Being offboarded (a retired deployment stays retired, so the fixture
    -- could not be put back; the door refuses both alike).
    update erp_meta.deployment d
       set status = 'retiring', offboarding_at = now(), purge_due_at = now() + interval '30 days', updated_at = now()
     where d.code = v_bcode;
    begin
      perform erp.sign_contract(v_dc2, 'B. Client, Director', 'P. Owner, Clove Ltd',
                                'Agreement to the order form and the terms it names');
      v_signed := 'it was signed';
    exception when others then
      v_signed := sqlerrm;
    end;
    update erp_meta.deployment d
       set status = 'building', offboarding_at = null, purge_due_at = null, updated_at = now()
     where d.code = v_bcode;
    v_cases := v_cases + 1;
    case_name := 'queueing stamps a notice with its event''s version, asks once for a sync of a deployment that is up and none of one being built, and keeps a push to a retired deployment as failed; and a draft is not signed once its deployment is being offboarded or retired';
    passed := v_m1 is not null and v_m2 is not null and v_m3 is not null
          and not exists (select 1 from erp_meta.deployment_push p
                           join erp_ref.event_type et on et.code = p.payload ->> 'event_type' and et.is_current
                          where p.code in (v_dcode, v_bcode) and p.kind = 'notice'
                            and p.payload -> 'event_version' is distinct from to_jsonb(et.version))
          and (select p.status from erp_meta.deployment_push p where p.id = v_s1) = 'superseded'
          and (select p.status from erp_meta.deployment_push p where p.id = v_s2) = 'pending'
          and (select count(*) from erp_meta.fleet_request r
                where r.kind = 'sync' and r.status = 'requested' and r.payload ->> 'code' = v_dcode) = 1
          and not exists (select 1 from erp_meta.fleet_request r where r.payload ->> 'code' in (v_bcode, v_rcode))
          and (select p.status from erp_meta.deployment_push p where p.id = v_nb) = 'pending'
          -- None waiting anywhere lacks its version: the migration stamped
          -- those queued before it, and queueing stamps every one since.
          and not exists (select 1 from erp_meta.deployment_push p
                           where p.kind = 'notice' and p.status in ('pending', 'claimed')
                             and not (p.payload ? 'event_version'))
          and coalesce((select p.status = 'failed' and p.settled_at is not null
                               and p.detail = 'the deployment was retired, so it is owed nothing more'
                          from erp_meta.deployment_push p where p.id = v_nr), false)
          and v_signed like 'CLOVEERP_CONTRACT_DEPLOYMENT_RETIRED: ' || v_bcode || ' is retiring%'
          and (select c.status from erp_meta.contract c where c.id = v_dc2) = 'draft'
          and (select count(*) from erp_meta.deployment_push p where p.code = v_bcode) = 1;
    detail := format('%s push(es) for the client, %s sync request(s); built: %s; retired: %s',
                     (select count(*) from erp_meta.deployment_push p where p.code = v_dcode),
                     (select count(*) from erp_meta.fleet_request r where r.kind = 'sync' and r.payload ->> 'code' = v_dcode),
                     (select p.status from erp_meta.deployment_push p where p.id = v_nb),
                     (select p.status || ' (' || coalesce(p.detail, '') || ')' from erp_meta.deployment_push p where p.id = v_nr));
    return next;

    -- ── 3. Another organisation's limits ────────────────────────────────────
    v_step := 'reading another organisation''s limits';
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    begin
      v_lim := erp.entitlement_limit('users', v_other);
      v_got := 'read: ' || coalesce(v_lim::text, 'unlimited');
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.entitlement_report(v_other);
      v_got2 := 'the report was read';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_ok := erp.entitlement_limit('companies', v_platform) is not distinct from erp.entitlement_limit('companies');
    -- Through the console's own door, which acts inside the organisation.
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_json := public.erp_platform_seats(v_other);
    -- And a trusted session, which carries nobody, working in one
    -- organisation and naming another, as the breach sweep does.
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', v_platform::text, true);
    v_lim2 := erp.entitlement_limit('companies', v_other);
    v_lim := (select pe.limit_value from erp_meta.plan_entitlement pe
               where pe.plan_code = erp.tenant_plan_code(v_other) and pe.entitlement_code = 'companies');
    perform set_config('erp.job_tenant_id', '', true);
    v_cases := v_cases + 1;
    case_name := 'a signed-in person reads the limits of the organisation they work in and of no other, while the console''s door and a trusted session read any';
    passed := v_got like 'CLOVEERP_ANOTHER_ORGANISATIONS_LIMIT: the limits of ' || v_other || ' are read from inside that organisation%'
          and v_got2 like 'CLOVEERP_ANOTHER_ORGANISATIONS_LIMIT:%'
          and v_ok
          and v_json ->> 'tenant_id' = v_other::text and v_json ? 'full' and v_json ? 'light'
          and v_lim2 is not distinct from v_lim;
    detail := left(v_got, 100) || ' / ' || left(v_got2, 60) || ' / console: ' || coalesce(v_json -> 'full' ->> 'limit', 'unlimited');
    return next;

    -- What the control plane hands the client.
    v_step := 'reading what the client is owed';
    v_due := erp_meta.deployment_pushes_due(v_dcode);
    select p.created_at, p.payload into v_s1_at, v_s1_pay from erp_meta.deployment_push p where p.id = v_s1;
    select p.created_at, p.payload into v_s2_at, v_s2_pay from erp_meta.deployment_push p where p.id = v_s2;
    -- As the workflow passes them on.
    v_items := (select jsonb_agg(jsonb_build_object('push_id', n -> 'id', 'queued_at', n -> 'created_at',
                                                    'event_type', n -> 'payload' -> 'event_type',
                                                    'event_version', n -> 'payload' -> 'event_version',
                                                    'payload', n -> 'payload' -> 'payload') order by x.o)
                  from jsonb_array_elements(v_due -> 'notices') with ordinality x(n, o));

    -- The client's own deployment, empty. The same database plays it: the
    -- control plane's rows stay, and the client reads none of them.
    v_step := 'becoming a client''s own deployment';
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason) values
      ('deployment.kind', '"client"'::jsonb, 'a_client_holds_its_contract_suite'),
      ('deployment.app_origin', to_jsonb('https://' || v_kcode || '.cloveerp.com'), 'a_client_holds_its_contract_suite');
    update erp.tenant t set status = 'deleted' where t.status not in ('deleting', 'deleted');
    delete from erp_meta.subscription_position_entitlement x where true;
    delete from erp_meta.subscription_position_capability x where true;
    delete from erp_meta.subscription_position x where true;
    delete from erp_meta.applied_push x where true;

    -- ── 4. The position, before any organisation ────────────────────────────
    v_step := 'applying the position with no organisation yet';
    v_pos := erp_meta.apply_pushed_position((v_due -> 'position' ->> 'id')::uuid,
                                            (v_due -> 'position' ->> 'created_at')::timestamptz,
                                            v_due -> 'position' -> 'payload');
    v_at := (select sp.applied_at from erp_meta.subscription_position sp);
    v_res := erp_meta.apply_pushed_position(v_s2, v_s2_at, v_s2_pay);
    v_cases := v_cases + 1;
    case_name := 'the newest position applies on a client before its organisation exists, and applying it again is a replay that changes nothing';
    passed := (v_due -> 'position' ->> 'id')::uuid = v_s2
          and jsonb_array_length(v_items) = 3
          and v_pos ->> 'outcome' = 'applied' and (v_pos ->> 'push_id')::uuid = v_s2
          and v_res ->> 'outcome' = 'replay'
          and not exists (select 1 from erp.tenant t where t.status not in ('deleting', 'deleted'))
          and coalesce((select sp.push_id = v_s2 and sp.queued_at = v_s2_at and sp.contract_ref = v_dc
                               and sp.contract_status = 'active' and sp.plan_code = 'standard' and sp.renews
                               and sp.currency = 'GBP' and sp.status = 'active' and sp.term_start = current_date
                               and sp.applied_at = v_at
                          from erp_meta.subscription_position sp), false)
          and (select count(*) from erp_meta.subscription_position_entitlement)
              = jsonb_array_length(v_s2_pay -> 'entitlements')
          and (select count(*) from erp_meta.subscription_position_capability)
              = jsonb_array_length(v_s2_pay -> 'capabilities')
          and exists (select 1 from erp_meta.applied_push ap where ap.push_id = v_s2 and ap.kind = 'subscription')
          and not exists (select 1 from erp_meta.subscription s where s.tenant_code = v_dcode);
    detail := coalesce(v_pos ->> 'detail', '-') || ' / then ' || coalesce(v_res ->> 'outcome', '-');
    return next;

    -- ── 5. An older position ────────────────────────────────────────────────
    v_step := 'applying the older position';
    v_res := erp_meta.apply_pushed_position(v_s1, v_s1_at, v_s1_pay);
    v_cases := v_cases + 1;
    case_name := 'a position queued before the one held is answered older and changes nothing';
    passed := v_res ->> 'outcome' = 'older'
          and (select sp.push_id from erp_meta.subscription_position sp) = v_s2
          and (select sp.applied_at from erp_meta.subscription_position sp) = v_at
          and not exists (select 1 from erp_meta.applied_push ap where ap.push_id = v_s1);
    detail := coalesce(v_res ->> 'outcome', '-') || ': ' || coalesce(v_res ->> 'detail', '-');
    return next;

    -- ── 6. Codes this release does not know ─────────────────────────────────
    v_step := 'applying positions naming codes not known here';
    v_res := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
               jsonb_set(v_s2_pay, '{plan_code}', to_jsonb('zzplan' || v_tag)));
    v_res2 := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
               jsonb_set(v_s2_pay, '{entitlements}', (v_s2_pay -> 'entitlements') || jsonb_build_array(
                 jsonb_build_object('code', 'zzseats' || v_tag, 'limit_value', 3,
                                    'effective_from', current_date, 'effective_to', null))));
    v_res3 := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
               jsonb_set(v_s2_pay, '{capabilities}', jsonb_build_array(
                 jsonb_build_object('code', 'zzfeature' || v_tag, 'effective_from', current_date, 'effective_to', null))));
    v_cases := v_cases + 1;
    case_name := 'a position naming a plan, a band or a feature this database does not know yet waits, naming it, and changes nothing';
    passed := v_res ->> 'outcome' = 'waiting' and v_res ->> 'detail' like '%plan zzplan' || v_tag || '%'
          and v_res2 ->> 'outcome' = 'waiting' and v_res2 ->> 'detail' like '%entitlement zzseats' || v_tag || '%'
          and v_res3 ->> 'outcome' = 'waiting' and v_res3 ->> 'detail' like '%feature zzfeature' || v_tag || '%'
          and (select sp.push_id from erp_meta.subscription_position sp) = v_s2
          and (select count(*) from erp_meta.subscription_position_entitlement)
              = jsonb_array_length(v_s2_pay -> 'entitlements')
          and (select count(*) from erp_meta.applied_push) = 1;
    detail := left(coalesce(v_res ->> 'detail', '-'), 120);
    return next;

    -- ── 7. A position that does not read as one ─────────────────────────────
    v_step := 'applying malformed positions';
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), v_s2_pay - 'plan_code');
      v_got := 'applied';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
                jsonb_set(v_s2_pay, '{entitlements}', '{"users": 5}'::jsonb));
      v_got2 := 'applied';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
                jsonb_set(v_s2_pay, '{entitlements}', jsonb_build_array(
                  jsonb_build_object('code', 'users', 'limit_value', 5,
                                     'effective_from', current_date, 'effective_to', current_date - 1))));
      v_got3 := 'applied';
    exception when others then
      v_got3 := sqlerrm;
    end;
    begin
      perform erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(),
                jsonb_set(v_s2_pay, '{contract_status}', '"draft"'::jsonb));
      v_got4 := 'applied';
    exception when others then
      v_got4 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'a position that does not read as one is refused with the registered refusal, naming the field and not its value, and changes nothing';
    passed := v_got like 'CLOVEERP_PUSH_MALFORMED: the contract position pushed as % is not applied: plan_code is not a plan''s code'
          and v_got2 like 'CLOVEERP_PUSH_MALFORMED: % entitlements is not a list'
          and v_got3 like 'CLOVEERP_PUSH_MALFORMED: % entitlements[1] effective_to is not after effective_from'
          and v_got4 like 'CLOVEERP_PUSH_MALFORMED: % contract_status is not active, terminating, expired or terminated'
          and exists (select 1 from erp_ref.refusal r where r.code = 'CLOVEERP_PUSH_MALFORMED')
          and (select sp.push_id from erp_meta.subscription_position sp) = v_s2
          and (select count(*) from erp_meta.applied_push) = 1;
    detail := left(v_got, 120) || ' / ' || left(v_got3, 60);
    return next;

    -- The notices, before any organisation, wait.
    v_step := 'telling notices before the organisation exists';
    perform set_config('erp.source', '', true);
    v_wait := erp_meta.apply_pushed_notices(v_items);

    -- ── 8. Onboarding takes the plan held ───────────────────────────────────
    v_step := 'onboarding the client''s organisation';
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    v_json := public.erp_platform_onboard_company(v_kcode, 'Delta Client Ltd', 'admin@' || v_kcode || '.test',
                                                  'Client Admin');
    v_tenant := (v_json ->> 'tenant_id')::uuid;
    v_status := (select t.status::text from erp.tenant t where t.id = v_tenant);
    perform set_config('request.jwt.claims', '', true);
    perform erp_meta.act_in_tenant(v_tenant);
    v_step := 'asking the interview about the statutory chart';
    insert into erp.interview_session (tenant_id, code) values (v_tenant, 'zzhc-' || v_tag) returning id into v_session;
    v_ok := (select bool_or((s ->> 'available')::boolean)
               from erp.interview_questions(v_session) q
               cross join lateral jsonb_array_elements(coalesce(q.suggestions, '[]'::jsonb)) s
              where q.code = 'org.chart' and s ->> 'value' = 'statutory');
    begin
      perform erp.answer_interview(v_session, 'org.chart', '"statutory"'::jsonb);
      v_got := 'the statutory chart was accepted';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.require_capability_on_plan('serialisation');
      v_got2 := 'allowed';
    exception when others then
      v_got2 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'the organisation onboarded takes the plan held: the statutory chart is neither offered nor accepted without its add-on, and the add-on its contract sold is allowed';
    passed := v_tenant is not null
          and erp.tenant_plan_code(v_tenant) = 'standard' and erp.tenant_plan_code() = 'standard'
          and v_ok is not null and not v_ok
          and v_got like 'CLOVEERP_CAPABILITY_NOT_ON_PLAN: statutory_chart_8_1%'
          and v_got2 = 'allowed'
          and erp.capability_on_plan('serialisation')
          and not erp.capability_on_plan('statutory_chart_8_1')
          and not exists (select 1 from erp_meta.plan_capability pc
                           where pc.plan_code = 'standard' and pc.capability_code = 'serialisation')
          and not exists (select 1 from erp_meta.subscription s where s.tenant_id = v_tenant);
    detail := format('plan %s; statutory offered %s; %s; serialisation %s',
                     erp.tenant_plan_code(v_tenant), coalesce(v_ok::text, 'not asked'), left(v_got, 80), left(v_got2, 60));
    return next;

    -- ── 9. What the organisation and the console read ───────────────────────
    v_step := 'reading the organisation''s agreement, its seats and the plans';
    perform erp_meta.stop_acting_in_tenant();
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform set_config('erp.job_tenant_id', v_tenant::text, true);
    v_json := erp.my_agreement();
    v_json2 := public.erp_platform_seats(v_tenant);
    v_json3 := public.erp_platform_plans();
    perform set_config('request.jwt.claims', '', true);
    v_cases := v_cases + 1;
    case_name := 'the organisation''s agreement shows the subscription held, each limit''s source and the add-ons; its seats'' limit comes from the contract; and the position held subscribes to its plan and is its organisation''s subscription in the console''s list';
    passed := v_json -> 'subscription' ->> 'plan_code' = 'standard'
          and v_json -> 'subscription' ->> 'status' = 'active'
          and v_json -> 'subscription' ->> 'term_start' = current_date::text
          and (v_json -> 'subscription' ->> 'renews')::boolean
          and v_json -> 'subscription' ->> 'currency' = 'GBP'
          and jsonb_typeof(v_json -> 'contract') = 'null'
          and exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e
                       where e ->> 'entitlement_code' = 'users' and e ->> 'source' = 'contract'
                         and (e ->> 'limit_value')::numeric = 250)
          and exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e
                       where e ->> 'entitlement_code' = 'companies' and e ->> 'source' = 'plan'
                         and (e ->> 'limit_value')::numeric = 3)
          and v_json -> 'capabilities' ? 'serialisation' and v_json -> 'capabilities' ? 'batch_control'
          and not (v_json -> 'capabilities' ? 'statutory_chart_8_1')
          and v_json2 -> 'full' ->> 'limit_from' = 'contract' and (v_json2 -> 'full' ->> 'limit')::numeric = 250
          and v_json2 -> 'light' ->> 'limit_from' = 'plan'
          and (select (x ->> 'subscribers')::integer from jsonb_array_elements(v_json3 -> 'plans') x
                where x ->> 'code' = 'standard')
              = (select count(*) from erp_meta.subscription s where s.plan_code = 'standard' and s.status <> 'terminated') + 1
          and exists (select 1 from jsonb_array_elements(v_json3 -> 'subscriptions') x
                       where x ->> 'tenant_code' = (select t.code from erp.tenant t where t.id = v_tenant)
                         and x ->> 'plan_code' = 'standard' and x ->> 'status' = 'active');
    detail := coalesce(v_json -> 'subscription' ->> 'plan_code', 'no subscription') || ' / users from '
              || coalesce((select e ->> 'source' from jsonb_array_elements(v_json -> 'entitlements') e
                            where e ->> 'entitlement_code' = 'users'), '-')
              || ' / seats ' || coalesce(v_json2 -> 'full' ->> 'limit_from', '-');
    return next;

    -- ── 10. Dated today, and from tomorrow ──────────────────────────────────
    v_step := 'reading bands dated today and from tomorrow';
    perform erp_meta.act_in_tenant(v_tenant);
    v_lim := erp.entitlement_limit('users');
    v_ok := erp.capability_on_plan('serialisation');
    v_res := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), v_s2_pay || jsonb_build_object(
               'entitlements', jsonb_build_array(
                 jsonb_build_object('code', 'users', 'limit_value', 250,
                                    'effective_from', current_date - 30, 'effective_to', current_date),
                 jsonb_build_object('code', 'users', 'limit_value', 500,
                                    'effective_from', current_date, 'effective_to', null)),
               'capabilities', jsonb_build_array(
                 jsonb_build_object('code', 'serialisation', 'effective_from', current_date + 1, 'effective_to', null))));
    v_lim2 := erp.entitlement_limit('users');
    v_ok2 := erp.capability_on_plan('serialisation');
    v_cases := v_cases + 1;
    case_name := 'a band or add-on dated from tomorrow is not in force today, and one dated from today is';
    passed := exists (select 1 from jsonb_array_elements(v_s2_pay -> 'entitlements') e
                       where e ->> 'code' = 'users' and (e ->> 'limit_value')::numeric = 500
                         and e ->> 'effective_from' = (current_date + 1)::text)
          and v_lim = 250 and v_ok
          and v_res ->> 'outcome' = 'applied'
          and v_lim2 = 500 and not v_ok2;
    detail := format('users %s then %s; serialisation %s then %s', v_lim, v_lim2, v_ok, v_ok2);
    return next;

    -- ── 11. The bands refuse, and a null band does not ──────────────────────
    v_step := 'adding beyond the bands held';
    v_used_c := coalesce(erp.entitlement_usage('companies'), 0);
    v_used_s := coalesce(erp.entitlement_usage('sites'), 0);
    v_used_u := coalesce(erp.entitlement_usage('users'), 0);
    v_res := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), v_s2_pay || jsonb_build_object(
               'entitlements', jsonb_build_array(
                 jsonb_build_object('code', 'companies', 'limit_value', v_used_c, 'effective_from', current_date, 'effective_to', null),
                 jsonb_build_object('code', 'sites', 'limit_value', v_used_s, 'effective_from', current_date, 'effective_to', null),
                 jsonb_build_object('code', 'users', 'limit_value', v_used_u, 'effective_from', current_date, 'effective_to', null)),
               'capabilities', '[]'::jsonb));
    begin
      perform erp.require_entitlement('companies');
      v_got := 'allowed';
    exception when others then
      v_got := sqlerrm;
    end;
    begin
      perform erp.require_entitlement('sites');
      v_got2 := 'allowed';
    exception when others then
      v_got2 := sqlerrm;
    end;
    begin
      perform erp.require_entitlement('users');
      v_got3 := 'allowed';
    exception when others then
      v_got3 := sqlerrm;
    end;
    -- Unlimited by contract: beyond the plan's hundred users.
    v_res2 := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), v_s2_pay || jsonb_build_object(
                'entitlements', jsonb_build_array(
                  jsonb_build_object('code', 'users', 'limit_value', null, 'effective_from', current_date, 'effective_to', null)),
                'capabilities', '[]'::jsonb));
    begin
      perform erp.require_entitlement('users', 1000);
      v_got4 := 'allowed';
    exception when others then
      v_got4 := sqlerrm;
    end;
    v_cases := v_cases + 1;
    case_name := 'companies, sites and users are refused at the bands held, and a band held with no limit is unlimited beyond the plan''s';
    passed := v_res ->> 'outcome' = 'applied' and v_res2 ->> 'outcome' = 'applied'
          and v_got like 'CLOVEERP_ENTITLEMENT_EXCEEDED: standard allows%'
          and v_got2 like 'CLOVEERP_ENTITLEMENT_EXCEEDED: standard allows%'
          and v_got3 like 'CLOVEERP_ENTITLEMENT_EXCEEDED: standard allows%'
          and v_got4 = 'allowed'
          and erp.entitlement_limit('users') is null
          and (select pe.limit_value from erp_meta.plan_entitlement pe
                where pe.plan_code = 'standard' and pe.entitlement_code = 'users') = 100;
    detail := format('in use %s/%s/%s: ', v_used_c, v_used_s, v_used_u) || left(v_got, 70) || ' / '
              || left(v_got3, 50) || ' / null band: ' || v_got4;
    return next;

    -- ── 12. The contract expired ────────────────────────────────────────────
    v_step := 'holding an expired contract';
    v_res := erp_meta.apply_pushed_position(gen_random_uuid(), clock_timestamp(), v_s2_pay || jsonb_build_object(
               'contract_status', 'expired', 'status', 'grace', 'renews', false));
    v_lim := erp.entitlement_limit('users');
    begin
      perform erp.require_capability_on_plan('serialisation');
      v_got := 'allowed';
    exception when others then
      v_got := sqlerrm;
    end;
    v_ok := erp.capability_on_plan('serialisation');
    v_got2 := erp.tenant_plan_code();
    perform erp_meta.stop_acting_in_tenant();
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform set_config('erp.job_tenant_id', v_tenant::text, true);
    v_json := erp.my_agreement();
    perform set_config('request.jwt.claims', '', true);
    v_cases := v_cases + 1;
    case_name := 'with the contract expired the plan''s limits apply, its add-ons are refused, the plan is kept and the subscription shows grace, and the organisation''s status is left alone';
    passed := v_res ->> 'outcome' = 'applied'
          and v_lim = 100
          and v_got like 'CLOVEERP_CAPABILITY_NOT_ON_PLAN: serialisation%'
          and not v_ok
          and v_got2 = 'standard'
          and v_json -> 'subscription' ->> 'status' = 'grace'
          and v_json -> 'subscription' ->> 'plan_code' = 'standard'
          and not exists (select 1 from jsonb_array_elements(v_json -> 'entitlements') e where e ->> 'source' = 'contract')
          and not (v_json -> 'capabilities' ? 'serialisation')
          and (select t.status::text from erp.tenant t where t.id = v_tenant) = v_status;
    detail := format('users %s; %s; plan %s; subscription %s', v_lim, left(v_got, 70), v_got2,
                     coalesce(v_json -> 'subscription' ->> 'status', '-'));
    return next;

    -- ── 13. The notices ─────────────────────────────────────────────────────
    -- As the workflow's own connection: nobody acting, nothing declared.
    v_step := 'telling the organisation its notices';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.source', '', true);
    v_told := erp_meta.apply_pushed_notices(v_items);
    v_res := erp_meta.apply_pushed_notices(v_items);
    v_res2 := erp_meta.apply_pushed_notices(jsonb_build_array(
                jsonb_build_object('push_id', v_x1, 'queued_at', clock_timestamp(),
                                   'event_type', 'commercial.capability_refused', 'event_version', 1,
                                   'payload', jsonb_build_object('capability', 'serialisation', 'plan', 'standard')),
                jsonb_build_object('push_id', v_x2, 'queued_at', clock_timestamp(),
                                   'event_type', 'commercial.review_announced', 'event_version', 99,
                                   'payload', jsonb_build_object('contract_id', v_dc, 'due_on', current_date + 30, 'days_left', 30)),
                jsonb_build_object('push_id', v_x3, 'queued_at', clock_timestamp(),
                                   'event_type', 'commercial.review_announced', 'event_version', 1,
                                   'payload', jsonb_build_object('contract_id', v_dc, 'due_on', current_date + 30, 'days_left', 30))));
    -- A notice queued before notices carried their version (as the control
    -- plane hands it out, with none), and one naming none outright: each is
    -- told in the version current here, and neither waits.
    insert into erp_meta.deployment_push (code, kind, contract_id, payload)
    values (v_dcode, 'notice', v_dc,
            jsonb_build_object('event_type', 'commercial.review_announced',
                               'payload', jsonb_build_object('contract_id', v_dc, 'due_on', current_date + 60, 'days_left', 60)))
    returning id, created_at into v_x4, v_x4_at;
    v_old := (select jsonb_agg(jsonb_build_object('push_id', n -> 'id', 'queued_at', n -> 'created_at',
                                                  'event_type', n -> 'payload' -> 'event_type',
                                                  'event_version', n -> 'payload' -> 'event_version',
                                                  'payload', n -> 'payload' -> 'payload'))
                from jsonb_array_elements(erp_meta.deployment_pushes_due(v_dcode) -> 'notices') n
               where (n ->> 'id')::uuid = v_x4)
             || jsonb_build_array(jsonb_build_object('push_id', v_x5, 'queued_at', clock_timestamp(),
                                   'event_type', 'commercial.review_announced', 'event_version', null,
                                   'payload', jsonb_build_object('contract_id', v_dc, 'due_on', current_date + 90, 'days_left', 90)));
    v_res3 := erp_meta.apply_pushed_notices(v_old);
    v_cases := v_cases + 1;
    case_name := 'notices wait while there is no organisation, then are told once, in order, dated when queued, in their version (the current one when they name none), with no source and their push as the correlation; told again they replay; a notice not for a client is refused and an unknown version waits, holding back the next';
    passed := jsonb_array_length(v_wait) = 3
          and (select bool_and(x ->> 'outcome' = 'waiting' and x ->> 'detail' like 'no organisation yet%')
                 from jsonb_array_elements(v_wait) x)
          and (select array_agg(x ->> 'outcome' order by o) from jsonb_array_elements(v_told) with ordinality a(x, o))
              = array['applied', 'applied', 'applied']
          and (select array_agg(x ->> 'outcome' order by o) from jsonb_array_elements(v_res) with ordinality a(x, o))
              = array['replay', 'replay', 'replay']
          and (select bool_and(a.x -> 'event_id' = b.x -> 'event_id')
                 from jsonb_array_elements(v_told) with ordinality a(x, o)
                 join jsonb_array_elements(v_res) with ordinality b(x, o) on b.o = a.o)
          and (select array_agg(e.correlation_id order by e.global_seq)
                 from erp.event e where e.tenant_id = v_tenant and e.correlation_id in (v_m1, v_m2, v_m3))
              = array[v_m1, v_m2, v_m3]
          and (select count(*) from erp.event e
                 join erp_meta.deployment_push p on p.id = e.correlation_id
                where e.tenant_id = v_tenant and p.id in (v_m1, v_m2, v_m3)
                  and e.id::text = (select x ->> 'event_id' from jsonb_array_elements(v_told) x
                                     where x ->> 'push_id' = p.id::text)
                  and e.event_type = p.payload ->> 'event_type'
                  and e.event_version = (p.payload ->> 'event_version')::integer
                  and e.occurred_at = p.created_at
                  and e.payload = p.payload -> 'payload'
                  and e.source = 'undeclared'
                  and e.aggregate_type = 'tenant' and e.aggregate_id = v_tenant) = 3
          and (select array_agg(x ->> 'outcome' order by o) from jsonb_array_elements(v_res2) with ordinality a(x, o))
              = array['refused', 'waiting', 'waiting']
          and v_res2 -> 1 ->> 'detail' like 'commercial.review_announced version 99 is not known here yet%'
          and not exists (select 1 from erp.event e where e.tenant_id = v_tenant and e.correlation_id in (v_x1, v_x2, v_x3))
          and not exists (select 1 from erp_meta.applied_push ap where ap.push_id in (v_x1, v_x2, v_x3))
          and jsonb_array_length(v_old) = 2 and jsonb_typeof(v_old -> 0 -> 'event_version') = 'null'
          and (select array_agg(x ->> 'outcome' order by o) from jsonb_array_elements(v_res3) with ordinality a(x, o))
              = array['applied', 'applied']
          and (select count(*) from erp.event e
                 join erp_ref.event_type et on et.code = e.event_type and et.is_current
                where e.tenant_id = v_tenant and e.correlation_id in (v_x4, v_x5)
                  and e.event_type = 'commercial.review_announced' and e.event_version = et.version) = 2
          and (select e.occurred_at from erp.event e where e.tenant_id = v_tenant and e.correlation_id = v_x4) = v_x4_at
          and (select count(*) from erp_meta.applied_push ap where ap.kind = 'notice') = 5;
    detail := format('before: %s; then %s; again %s; others %s; with no version %s',
                     coalesce(v_wait -> 0 ->> 'detail', '-'),
                     (select string_agg(x ->> 'outcome', ',') from jsonb_array_elements(v_told) x),
                     (select string_agg(x ->> 'outcome', ',') from jsonb_array_elements(v_res) x),
                     (select string_agg(x ->> 'outcome', ',') from jsonb_array_elements(v_res2) x),
                     (select string_agg(x ->> 'outcome' || coalesce(' (' || (x ->> 'detail') || ')', ''), ',')
                        from jsonb_array_elements(v_res3) x));
    return next;

    -- ── 14. The control plane settles, and sees it ──────────────────────────
    v_step := 'settling what the client answered';
    delete from erp_meta.platform_setting where key in ('deployment.kind', 'deployment.app_origin');
    insert into erp_meta.platform_setting (key, value, reason)
    values ('deployment.kind', '"production"'::jsonb, 'a_client_holds_its_contract_suite');
    -- What the client held of the control plane is not the control plane's.
    delete from erp_meta.subscription_position_entitlement x where true;
    delete from erp_meta.subscription_position_capability x where true;
    delete from erp_meta.subscription_position x where true;
    delete from erp_meta.applied_push x where true;
    v_json := erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag,
                (select jsonb_agg(jsonb_build_object('id', x -> 'push_id', 'outcome', x -> 'outcome', 'detail', x -> 'detail'))
                   from jsonb_array_elements(jsonb_build_array(v_pos) || v_told || (v_res3 -> 0)) x));
    v_got := (select string_agg(p.status, ',' order by p.created_at) from erp_meta.deployment_push p
               where p.id in (v_s2, v_m1, v_m2, v_m3, v_x4));
    v_at := (select p.settled_at from erp_meta.deployment_push p where p.id = v_s2);
    v_json2 := erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag || '-2',
                 jsonb_build_array(jsonb_build_object('push_id', v_s2, 'outcome', 'replay', 'detail', 'held already')));
    -- A position and a notice queued since, waiting, then refused, then older
    -- and applied; and answers about pushes that are not this run's to settle.
    perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
    perform erp.provision_entitlement_from_contract(v_dc);
    v_s3 := (select p.id from erp_meta.deployment_push p
              where p.code = v_dcode and p.kind = 'subscription' and p.status = 'pending');
    v_m4 := erp_meta.queue_deployment_push(v_dcode, 'notice', v_dc,
              jsonb_build_object('event_type', 'commercial.review_announced',
                                 'payload', jsonb_build_object('contract_id', v_dc, 'due_on', current_date + 30, 'days_left', 30)));
    v_json3 := erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag || '-3', jsonb_build_array(
                 jsonb_build_object('push_id', v_s3, 'outcome', 'waiting', 'detail', 'this deployment does not know a feature yet'),
                 jsonb_build_object('push_id', v_m4, 'outcome', 'waiting'),
                 jsonb_build_object('push_id', v_s1, 'outcome', 'applied'),
                 jsonb_build_object('push_id', v_nr, 'outcome', 'applied'),
                 jsonb_build_object('push_id', gen_random_uuid(), 'outcome', 'applied')));
    v_got2 := (select string_agg(p.status || '/' || p.attempts || '/' || coalesce(p.run_id, '-'), ',' order by p.kind desc)
                 from erp_meta.deployment_push p where p.id in (v_s3, v_m4));
    perform erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag || '-4', jsonb_build_array(
              jsonb_build_object('push_id', v_s3, 'outcome', 'refused', 'detail', 'CLOVEERP_PUSH_MALFORMED: a test'),
              jsonb_build_object('push_id', v_m4, 'id', v_m4, 'outcome', 'refused')));
    v_got3 := (select string_agg(p.status || '/' || p.attempts, ',' order by p.kind desc)
                 from erp_meta.deployment_push p where p.id in (v_s3, v_m4));
    v_res := erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag || '-5', jsonb_build_array(
               jsonb_build_object('id', v_s3, 'outcome', 'older'),
               jsonb_build_object('push_id', v_m4, 'outcome', 'applied')));
    begin
      perform erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag, '{}'::jsonb);
      v_got4 := 'settled';
    exception when others then
      v_got4 := sqlerrm;
    end;
    begin
      perform erp_meta.settle_deployment_pushes(v_dcode, 'run-' || v_tag,
                jsonb_build_array(jsonb_build_object('push_id', v_s2, 'outcome', 'maybe')));
      v_got5 := 'settled';
    exception when others then
      v_got5 := sqlerrm;
    end;
    -- The usage the poll reads: recorded, replaced, never deleted.
    v_step := 'recording the client''s usage';
    v_res2 := erp_meta.record_deployment_usage(v_dcode, jsonb_build_array(
                jsonb_build_object('meter_code', 'documents_posted', 'quantity', 40,
                                   'period_start', (date_trunc('month', current_date) - interval '1 month')::date,
                                   'period_end', (date_trunc('month', current_date) - interval '1 day')::date,
                                   'measured_at', now()),
                jsonb_build_object('meter_code', 'documents_posted', 'quantity', 12,
                                   'period_start', date_trunc('month', current_date)::date,
                                   'period_end', (date_trunc('month', current_date) + interval '1 month - 1 day')::date,
                                   'measured_at', now()),
                jsonb_build_object('meter_code', 'messages_sent', 'quantity', 3,
                                   'period_start', date_trunc('month', current_date)::date,
                                   'period_end', (date_trunc('month', current_date) + interval '1 month - 1 day')::date),
                jsonb_build_object('meter_code', 'zzmeter' || v_tag, 'quantity', 1,
                                   'period_start', date_trunc('month', current_date)::date,
                                   'period_end', (date_trunc('month', current_date) + interval '1 month - 1 day')::date)));
    v_res3 := erp_meta.record_deployment_usage(v_dcode, jsonb_build_array(
                jsonb_build_object('meter_code', 'documents_posted', 'quantity', 15,
                                   'period_start', date_trunc('month', current_date)::date,
                                   'period_end', (date_trunc('month', current_date) + interval '1 month - 1 day')::date,
                                   'measured_at', now())));
    begin
      perform erp_meta.record_deployment_usage(v_dcode, jsonb_build_array(
                jsonb_build_object('meter_code', 'documents_posted', 'quantity', -1,
                                   'period_start', current_date, 'period_end', current_date)));
      v_got := v_got || ' / a negative reading was recorded';
    exception when others then
      v_got := v_got || ' / ' || sqlerrm;
    end;
    v_row := (select x from jsonb_array_elements(public.erp_platform_deployments()) x where x ->> 'code' = v_dcode);
    v_json3 := v_json3 || jsonb_build_object('plans', public.erp_platform_plans());
    perform set_config('request.jwt.claims', '', true);
    v_cases := v_cases + 1;
    case_name := 'settling follows what the client answered and leaves the rest, a position is never failed and D35 stays green, the Fleet shows the client''s commercial position and usage, the Plans view counts it, and usage is replaced and never deleted';
    passed := v_got like 'applied,applied,applied,applied,applied / CLOVEERP_DEPLOYMENT_USAGE_INVALID: the usage read from ' || v_dcode || ' is not recorded: reading 1 quantity is below none'
          and v_json ->> 'applied' = '5' and v_json ->> 'left' = '0'
          and v_json2 ->> 'reapplied' = '1'
          and (select p.settled_at > v_at and p.run_id = 'run-' || v_tag || '-2' and p.detail = 'the client holds it still: held already'
                 from erp_meta.deployment_push p where p.id = v_s2)
          and v_json3 ->> 'waiting' = '2' and v_json3 ->> 'left' = '3'
          and v_got2 = 'pending/0/run-' || v_tag || '-3,pending/0/run-' || v_tag || '-3'
          and v_got3 = 'pending/1,failed/1'
          and v_res ->> 'superseded' = '1' and v_res ->> 'left' = '1'
          and (select p.status from erp_meta.deployment_push p where p.id = v_s3) = 'superseded'
          and (select p.status from erp_meta.deployment_push p where p.id = v_m4) = 'failed'
          and (select p.status from erp_meta.deployment_push p where p.id = v_s1) = 'superseded'
          and (select p.status from erp_meta.deployment_push p where p.id = v_nr) = 'failed'
          and v_got4 like 'CLOVEERP_PUSH_SETTLE_UNREADABLE: what ' || v_dcode || ' answered is not settled: the answers are not a list'
          and v_got5 like 'CLOVEERP_PUSH_SETTLE_UNREADABLE: % answer 1 says none of applied, replay, older, waiting or refused'
          and not exists (select 1 from erp_meta.deployment_push p where p.kind = 'subscription' and p.status = 'failed'
                            and p.code = v_dcode)
          and erp.assert_contract_provisions_entitlement() like 'contracts: % in force%'
          and not exists (select 1 from erp.contract_provisioning_report() f where f.reference = v_dcode)
          and v_res2 ->> 'recorded' = '3' and v_res2 -> 'skipped' = jsonb_build_array('zzmeter' || v_tag)
          and v_res3 ->> 'recorded' = '1'
          and (select count(*) from erp_meta.deployment_usage u where u.code = v_dcode) = 3
          and (select u.quantity from erp_meta.deployment_usage u
                where u.code = v_dcode and u.meter_code = 'documents_posted'
                  and u.period_start = date_trunc('month', current_date)::date) = 15
          and (select count(*) from jsonb_object_keys(v_row)) = 41
          and v_row -> 'commercial' ->> 'contract_ref' = v_dc::text
          and v_row -> 'commercial' ->> 'contract_status' = 'active'
          and v_row -> 'commercial' ->> 'plan_code' = 'standard'
          and v_row -> 'commercial' ->> 'position' = 'applied'
          and (v_row -> 'commercial' ->> 'position_applied_at')::timestamptz
              = (select p.settled_at from erp_meta.deployment_push p where p.id = v_s2)
          and jsonb_typeof(v_row -> 'commercial' -> 'position_pending_since') = 'null'
          and v_row -> 'commercial' ->> 'position_detail' = 'the client holds it still: held already'
          and (v_row -> 'commercial' ->> 'notices_pending')::integer = 0
          and (v_row -> 'commercial' ->> 'notices_failed')::integer = 1
          and exists (select 1 from jsonb_array_elements(v_row -> 'commercial' -> 'usage') u
                       where u ->> 'meter_code' = 'documents_posted' and (u ->> 'measured')::boolean
                         and (u ->> 'quantity')::numeric = 15
                         and u ->> 'period_start' = date_trunc('month', current_date)::date::text)
          and exists (select 1 from jsonb_array_elements(v_row -> 'commercial' -> 'usage') u
                       where u ->> 'meter_code' = 'active_users' and not (u ->> 'measured')::boolean
                         and jsonb_typeof(u -> 'quantity') = 'null')
          and jsonb_array_length(v_row -> 'commercial' -> 'usage') = (select count(*) from erp_meta.meter_kind)
          and (select (x ->> 'deployments')::integer from jsonb_array_elements(v_json3 -> 'plans' -> 'plans') x
                where x ->> 'code' = 'standard')
              = (select count(*) from erp_meta.contract c where c.plan_code = 'standard'
                   and c.deployment_code is not null and c.status in ('active', 'terminating'))
          and (select (x ->> 'deployments')::integer from jsonb_array_elements(v_json3 -> 'plans' -> 'plans') x
                where x ->> 'code' = 'standard') >= 1;
    detail := left(v_got, 60) || format(' / %s / %s / %s / %s / ', v_json, v_got2, v_got3, v_res)
              || left(coalesce(v_row ->> 'commercial', 'no Fleet row'), 200);
    return next;

    -- ── 15. Standing ────────────────────────────────────────────────────────
    v_step := 'reading the routines'' standing';
    select count(*) into v_n
      from pg_catalog.pg_proc p
     where p.oid in ('erp_meta.apply_pushed_position(uuid,timestamptz,jsonb)'::regprocedure,
                     'erp_meta.apply_pushed_notices(jsonb)'::regprocedure,
                     'erp_meta.deployment_pushes_due(text)'::regprocedure,
                     'erp_meta.settle_deployment_pushes(text,text,jsonb)'::regprocedure,
                     'erp_meta.record_deployment_usage(text,jsonb)'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
       and not pg_catalog.has_function_privilege('service_role', p.oid, 'execute');
    select count(*) into v_n2
      from pg_catalog.pg_proc p
     where p.oid in ('erp.contract_band_in_force(text,uuid)'::regprocedure,
                     'erp.contract_capabilities_in_force(uuid)'::regprocedure)
       and not p.prosecdef
       and not pg_catalog.has_function_privilege('anon', p.oid, 'execute');
    select count(*) into v_n3
      from pg_catalog.pg_class c
     where c.oid in ('erp_meta.subscription_position'::regclass, 'erp_meta.subscription_position_entitlement'::regclass,
                     'erp_meta.subscription_position_capability'::regclass, 'erp_meta.applied_push'::regclass,
                     'erp_meta.deployment_usage'::regclass)
       and c.relrowsecurity and c.relforcerowsecurity
       and not pg_catalog.has_table_privilege('anon', c.oid, 'select')
       and not pg_catalog.has_table_privilege('authenticated', c.oid, 'select')
       and exists (select 1 from erp_meta.table_policy t
                    where t.schema_name = 'erp_meta' and t.table_name = c.relname
                      and t.table_class = 'platform_internal');
    v_cases := v_cases + 1;
    case_name := 'the trusted routines reach no session role, the two helpers run as their caller, the readers still run as their owner, and the five tables are sealed';
    passed := v_n = 5 and v_n2 = 2 and v_n3 = 5
          and (select bool_and(p.prosecdef and pg_catalog.has_function_privilege('authenticated', p.oid, 'execute'))
                 from pg_catalog.pg_proc p
                where p.oid in ('erp.tenant_plan_code(uuid)'::regprocedure, 'erp.entitlement_limit(text,uuid)'::regprocedure,
                                'erp.capability_on_plan(text)'::regprocedure, 'erp.my_agreement()'::regprocedure,
                                'public.erp_platform_seats(uuid)'::regprocedure))
          and (select p.provolatile = 'v' from pg_catalog.pg_proc p
                where p.oid = 'public.erp_platform_seats(uuid)'::regprocedure)
          and exists (select 1 from erp_meta.audit_source_entry_point e
                       where e.entry_point = 'the fleet''s sync applying the control plane''s pushes'
                         and e.records = 'undeclared' and not e.declares);
    detail := format('%s of 5 trusted, %s of 2 helpers, %s of 5 tables', v_n, v_n2, v_n3);
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.correlation_id', '', true);

  -- ── 16. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the suite leaves nothing behind: no deployment, contract, push, request, position, usage or organisation of its own, and the deployment as it was';
  passed := not exists (select 1 from erp_meta.deployment d where d.code in (v_dcode, v_bcode, v_rcode))
        and not exists (select 1 from erp_meta.contract c where c.tenant_code in (v_dcode, v_pcode, v_ocode))
        and not exists (select 1 from erp_meta.deployment_push p where p.code in (v_dcode, v_bcode, v_rcode))
        and not exists (select 1 from erp_meta.fleet_request r where r.payload ->> 'code' in (v_dcode, v_bcode, v_rcode))
        and not exists (select 1 from erp_meta.deployment_usage u where u.code in (v_dcode, v_bcode, v_rcode))
        and not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ocode, v_kcode))
        and (select count(*) from erp_meta.subscription_position)
            + (select count(*) from erp_meta.subscription_position_entitlement)
            + (select count(*) from erp_meta.subscription_position_capability)
            + (select count(*) from erp_meta.applied_push) = v_held0
        and erp.deployment_kind() = v_kind
        and (select s.value from erp_meta.platform_setting s where s.key = 'deployment.app_origin') is not distinct from v_origin;
  detail := format('deployment kind %s, as before; %s row(s) held, as before', erp.deployment_kind(), v_held0);
  return next;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_A_CLIENT_HOLDS_ITS_CONTRACT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

create or replace function erp_test.assert_a_client_holds_its_contract_suite()
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
    from erp_test.a_client_holds_its_contract_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_A_CLIENT_HOLDS_ITS_CONTRACT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A client''s own deployment does not hold, enforce or show its contract as the control plane sold it, or the control plane does not hand out and settle what it is owed: read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_A_CLIENT_HOLDS_ITS_CONTRACT_SUITE_SHRANK: % case(s), expected 16', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('a client holds its contract: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.a_client_holds_its_contract_suite() from public, anon;
revoke all on function erp_test.assert_a_client_holds_its_contract_suite() from public, anon;

comment on function erp_test.assert_a_client_holds_its_contract_suite() is
  'A client''s own deployment applies the newest position its contract holds before its organisation exists, '
  'answers a replay, an older position, codes it does not know yet and a malformed position as such, and refuses '
  'both routines off a client, where a position held is a finding; its organisation takes the plan held, its '
  'bands refuse companies, sites and users and a null band is unlimited, a band dated tomorrow is not in force, '
  'and after expiry the plan''s limits apply and add-ons are refused; the agreement, the seats and the plans show '
  'it; notices wait for the organisation, are told once in order with their version, date and push, replay, and '
  'one not for a client is refused; queueing stamps versions, asks once for a sync of a deployment that is up, and '
  'keeps a push to a retired one as failed; settling follows the client''s answers and never fails a position, '
  'so D35 stays green; the Fleet shows the commercial position and usage; a signed-in person reads no other '
  'organisation''s limits; and nothing is left behind (20261012040000).';

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
