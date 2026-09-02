-- ─────────────────────────────────────────────────────────────────────────────
-- v1.5 §22.2: first-run guidance that can be acted on and completes itself.
--
-- The panel shipped in 20260904500000 was a register of thirty steps and a
-- checkbox. Two things were wrong with it, and the second is the serious one:
--
--   1. Nothing on it was an action. The title was a text link, and thirty of
--      them rendered flat across nine guides — every guide the caller's
--      permissions touch, all expanded, on a phone. There was no next step,
--      only a wall.
--
--   2. The tick was self-reported. The platform already knows whether a second
--      administrator exists, whether a change set was promoted, whether a
--      period was closed — and it asked the person to tell it. A checklist
--      that does not read the state it describes drifts away from it, and then
--      it is a worse record than no record.
--
-- So a step now carries two things it did not have. `action_label` names the
-- action in the words of the screen it opens, so the row can render a control
-- rather than a hyperlink. `observable` says the platform can see for itself
-- whether the step was taken, and erp.first_run_evidence() is where it looks:
-- one branch per observable step, reading the organisation's own tables,
-- returning what it saw in a sentence.
--
-- Twenty-eight of the thirty are observable. The two that are not —
-- "read the trial balance", "read stock by site and location" — are steps
-- whose whole content is going and looking, and nothing records that a person
-- looked. They keep the tick, which is the honest mechanism for them.
--
-- A step is complete when the evidence satisfies it OR the person ticked it.
-- Ticking an observable step stays possible: the platform may be looking at
-- the wrong thing, and the person is allowed to say so. And a step can be
-- dismissed — an organisation with no scanners should not carry "open a
-- session on a scanner" forever — which is recorded separately from done,
-- because "we did this" and "this is not for us" are different sentences.
--
-- erp.assert_first_run_guidance_actionable() holds the register to it: every
-- step names an action, every observable step is covered by a branch of the
-- evidence function, and the evidence function names no step that is not
-- registered. That last clause is why the evidence function has no fallback
-- branch — a fallback that emitted a row per observable step would make the
-- coverage check pass by construction and prove nothing.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The guides, as a register rather than a map in the front end ─────────────

-- The nine guide names lived in a Record<string, string> in first-run.tsx,
-- which put nine product-visible strings outside the resource layer every
-- other string in the product resolves through.
create table if not exists erp_ref.first_run_guide (
  code     text primary key,
  seq      smallint not null unique,
  name_key text not null,
  blurb    text not null,
  constraint first_run_guide_code_is_a_slug check (code ~ '^[a-z][a-z0-9_]*$')
);

comment on table erp_ref.first_run_guide is
  '§22.2. The guides first-run steps are grouped into, in the order they are '
  'best taken: setting the organisation up comes before running it. name_key '
  'resolves through the resource layer so an organisation can rename a guide '
  'the way it renames anything else.';

select erp_meta.register_table('erp_ref', 'first_run_guide', 'product_content',
  'Part 22. The guides first-run steps are grouped into, and their order.');

insert into erp_ref.first_run_guide (code, seq, name_key, blurb) values
  ('administrator', 1, 'guide.administrator', 'Bring the organisation into a state where work can be done in it.'),
  ('finance',       2, 'guide.finance',       'Prove the ledger agrees with the subledgers, then close a period.'),
  ('sales',         3, 'guide.sales',         'Take an order through to despatch.'),
  ('procurement',   4, 'guide.procurement',   'Order from a supplier and receive against it.'),
  ('warehouse',     5, 'guide.warehouse',     'Move and count stock, on the floor or on a scanner.'),
  ('planning',      6, 'guide.planning',      'Set the policy, then let a run propose against it.'),
  ('production',    7, 'guide.production',    'Make something, and cost what it took.'),
  ('quality',       8, 'guide.quality',       'Inspect what arrived and decide what happens to it.'),
  ('reporting',     9, 'guide.reporting',     'Run a report, then version it so the figures can be re-run.')
on conflict (code) do update set
  seq = excluded.seq, name_key = excluded.name_key, blurb = excluded.blurb;

insert into erp_ref.resource (key, locale, value, description) values
  ('guide.administrator', 'en', 'Setting the organisation up', 'Name of the administrator first-run guide.'),
  ('guide.finance',       'en', 'Finance',     'Name of the finance first-run guide.'),
  ('guide.sales',         'en', 'Sales',       'Name of the sales first-run guide.'),
  ('guide.procurement',   'en', 'Procurement', 'Name of the procurement first-run guide.'),
  ('guide.warehouse',     'en', 'Warehouse',   'Name of the warehouse first-run guide.'),
  ('guide.planning',      'en', 'Planning',    'Name of the planning first-run guide.'),
  ('guide.production',    'en', 'Production',  'Name of the production first-run guide.'),
  ('guide.quality',       'en', 'Quality',     'Name of the quality first-run guide.'),
  ('guide.reporting',     'en', 'Reporting',   'Name of the reporting first-run guide.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

-- ── The step gains an action and a way to be seen ────────────────────────────

alter table erp_ref.first_run_step
  add column if not exists action_label text,
  add column if not exists observable   boolean not null default false;

update erp_ref.first_run_step s set action_label = v.action_label, observable = v.observable
  from (values
    ('administrator', 1::smallint, 'Invite an administrator',   true),
    ('administrator', 2::smallint, 'Open configuration',        true),
    ('administrator', 3::smallint, 'Open the starter packs',    true),
    ('administrator', 4::smallint, 'Open governance',           true),
    ('administrator', 5::smallint, 'Open permissions',          true),
    ('administrator', 6::smallint, 'Open terminology',          true),
    ('administrator', 7::smallint, 'Open sending identity',     true),
    ('finance',       1::smallint, 'Open finance',              false),
    ('finance',       2::smallint, 'Open account determination', true),
    ('finance',       3::smallint, 'Open cutover',              true),
    ('finance',       4::smallint, 'Open the period close',     true),
    ('warehouse',     1::smallint, 'Open inventory',            false),
    ('warehouse',     2::smallint, 'Open warehouse tasks',      true),
    ('warehouse',     3::smallint, 'Open counting',             true),
    ('warehouse',     4::smallint, 'Open devices',              true),
    ('warehouse',     5::smallint, 'Open the scanner client',   true),
    ('sales',         1::smallint, 'Open sales',                true),
    ('sales',         2::smallint, 'Open logistics',            true),
    ('sales',         3::smallint, 'Open release areas',        true),
    ('procurement',   1::smallint, 'Open item supply',          true),
    ('procurement',   2::smallint, 'Open procurement',          true),
    ('procurement',   3::smallint, 'Open receiving',            true),
    ('planning',      1::smallint, 'Open planning policy',      true),
    ('planning',      2::smallint, 'Open planning',             true),
    ('production',    1::smallint, 'Open production',           true),
    ('production',    2::smallint, 'Open works orders',         true),
    ('quality',       1::smallint, 'Open quality',              true),
    ('quality',       2::smallint, 'Open dispositions',         true),
    ('reporting',     1::smallint, 'Open reporting',            true),
    ('reporting',     2::smallint, 'Open reproducibility',      true)
  ) as v(guide_code, seq, action_label, observable)
 where s.guide_code = v.guide_code and s.seq = v.seq;

alter table erp_ref.first_run_step
  alter column action_label set not null,
  add constraint first_run_step_names_an_action check (length(btrim(action_label)) > 0);

-- A step belongs to a guide, and the guide decides the order the guides are
-- offered in. The foreign key is added now that every guide is registered.
alter table erp_ref.first_run_step
  drop constraint if exists first_run_step_guide_code_fkey;
alter table erp_ref.first_run_step
  add constraint first_run_step_guide_code_fkey
  foreign key (guide_code) references erp_ref.first_run_guide (code);

comment on column erp_ref.first_run_step.action_label is
  'The action in the words of the screen it opens, so the step renders a '
  'control rather than a hyperlink.';
comment on column erp_ref.first_run_step.observable is
  'The platform can see for itself whether this step was taken; '
  'erp.first_run_evidence() carries the branch that looks.';

-- ── Dismissal: "this is not for us" is not the same as "we did this" ─────────

alter table erp.first_run_progress
  alter column done_at drop not null;
alter table erp.first_run_progress
  add column if not exists dismissed_at timestamptz;
alter table erp.first_run_progress
  drop constraint if exists first_run_progress_says_something;
alter table erp.first_run_progress
  add constraint first_run_progress_says_something
  check (done_at is not null or dismissed_at is not null);

comment on column erp.first_run_progress.dismissed_at is
  'When this person set the step aside as not applying to their organisation. '
  'Recorded apart from done_at: a step nobody will take and a step already '
  'taken are different facts, and the adoption signals read them differently.';

-- ── What the platform can see ────────────────────────────────────────────────

-- One branch per observable step, reading the organisation's own tables. No
-- fallback branch: the coverage assertion compares this function's rows
-- against the steps marked observable, and a fallback would satisfy it by
-- construction.
--
-- Security invoker on purpose. The evidence for a step is visible to exactly
-- the people the step is offered to, because both are gated by the same
-- permission and the same row-level security. A definer function here would
-- widen the read surface to buy nothing.
create or replace function erp.first_run_evidence()
returns table (guide_code text, seq smallint, satisfied boolean, evidence text)
language sql
stable
security invoker
set search_path = ''
as $$
  with t as (select erp.current_tenant_id() as id),
  -- Administrators, counted through the roles that carry the permission
  -- rather than through a job title nobody maintains.
  admins as (
    select count(distinct ur.app_user_id) as n
      from erp.user_role ur
      join erp.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
      cross join t
     where ur.tenant_id = t.id
       and rp.permission_code = 'administration.users'
       and (ur.valid_to is null or ur.valid_to >= current_date)
  ),
  promoted as (
    select count(*) as n from erp.change_set cs cross join t
     where cs.tenant_id = t.id and cs.status = 'promoted'
  ),
  -- Passed the tenant explicitly rather than left to default. Called with no
  -- argument the report spans every organisation, and row-level security
  -- would be the only thing scoping it — which is true today and is not a
  -- thing to depend on for a figure shown to a person as their own.
  findings as (
    select count(*) as n from erp.determination_coverage_report((select id from t))
  ),
  doctypes as (
    select count(*) as n from erp.document_type dt cross join t
     where dt.tenant_id = t.id and dt.status = 'active'
  )
  select 'administrator', 1::smallint, a.n >= 2,
         case when a.n >= 2 then a.n || ' people hold user administration'
              when a.n = 1 then 'only you hold user administration'
              else 'nobody holds user administration yet' end
    from admins a
  union all
  select 'administrator', 2::smallint, p.n > 0,
         case when p.n > 0 then p.n || ' change set(s) promoted, so modules are installed'
              else 'no module has been installed yet' end
    from promoted p
  union all
  select 'administrator', 3::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' starter pack(s) applied' else 'no starter pack applied yet' end
    from (select count(*) as n from erp.tenant_pack tp cross join t
           where tp.tenant_id = t.id and tp.status = 'applied') x
  union all
  select 'administrator', 4::smallint, p.n > 0,
         case when p.n > 0 then p.n || ' change set(s) approved and promoted'
              else 'nothing has been promoted yet' end
    from promoted p
  union all
  select 'administrator', 5::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' role grant(s) in force' else 'nobody has been given a role yet' end
    from (select count(*) as n from erp.user_role ur cross join t
           where ur.tenant_id = t.id and (ur.valid_to is null or ur.valid_to >= current_date)) x
  union all
  select 'administrator', 6::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' term(s) renamed for this organisation'
              else 'no term has been renamed yet' end
    from (select count(*) as n from erp.resource_override ro cross join t
           where ro.tenant_id = t.id and ro.status = 'active') x
  union all
  select 'administrator', 7::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' sending domain(s) verified'
              else 'no sending domain has verified SPF, DKIM and DMARC yet' end
    from (select count(*) as n from erp.sender_identity si cross join t
           where si.tenant_id = t.id and si.verified_at is not null) x
  union all
  -- Finance. A determination report with no findings only means something
  -- once there are document types for it to have found anything about.
  select 'finance', 2::smallint, d.n > 0 and f.n = 0,
         case when d.n = 0 then 'no document type is configured yet, so there is nothing to determine'
              when f.n = 0 then 'every document type has a path to an account'
              else f.n || ' determination finding(s) outstanding' end
    from findings f cross join doctypes d
  union all
  select 'finance', 3::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' opening balance movement(s) posted'
              else 'no opening balance has been loaded yet' end
    from (select count(*) as n from erp.stock_movement sm cross join t
           where sm.tenant_id = t.id and sm.movement_type = 'opening_balance') x
  union all
  select 'finance', 4::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' period(s) closed' else 'no period has been closed yet' end
    from (select count(*) as n from erp.fiscal_period fp cross join t
           where fp.tenant_id = t.id and fp.closed_at is not null) x
  union all
  -- Warehouse.
  select 'warehouse', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' putaway task(s) completed' else 'no putaway task completed yet' end
    from (select count(*) as n from erp.warehouse_task wt cross join t
           where wt.tenant_id = t.id and wt.kind = 'putaway' and wt.status = 'done') x
  union all
  select 'warehouse', 3::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' count(s) posted' else 'no count has been posted yet' end
    from (select count(*) as n from erp.count_task ct cross join t
           where ct.tenant_id = t.id and ct.posted_at is not null) x
  union all
  select 'warehouse', 4::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' device action(s) applied' else 'no device action has been applied yet' end
    from (select count(*) as n from erp.device_action da cross join t
           where da.tenant_id = t.id and da.applied_at is not null) x
  union all
  select 'warehouse', 5::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' scanner session(s) opened' else 'no scanner session has been opened yet' end
    from (select count(*) as n from erp.device_session ds cross join t where ds.tenant_id = t.id) x
  union all
  -- Sales.
  select 'sales', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' sales order(s) raised' else 'no sales order has been raised yet' end
    from (select count(*) as n from erp.document d
            join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
            cross join t
           where d.tenant_id = t.id and dt.base_type_code = 'sales_order' and not d.is_cancelled) x
  union all
  select 'sales', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' shipment(s) despatched' else 'nothing has been despatched yet' end
    from (select count(*) as n from erp.shipment sh cross join t
           where sh.tenant_id = t.id and sh.actual_despatch is not null) x
  union all
  select 'sales', 3::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' marshalling area(s) set up' else 'no marshalling area yet' end
    from (select count(*) as n from erp.release_area ra cross join t
           where ra.tenant_id = t.id and ra.status = 'active') x
  union all
  -- Procurement.
  select 'procurement', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' product(s) have a default supplier'
              else 'no product has a default supplier yet' end
    from (select count(*) as n from erp.item_supplier isup cross join t
           where isup.tenant_id = t.id and isup.is_default and isup.status = 'active') x
  union all
  select 'procurement', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' purchase order(s) raised' else 'no purchase order has been raised yet' end
    from (select count(*) as n from erp.document d
            join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
            cross join t
           where d.tenant_id = t.id and dt.base_type_code = 'purchase_order' and not d.is_cancelled) x
  union all
  select 'procurement', 3::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' goods receipt movement(s) recorded'
              else 'nothing has been received yet' end
    from (select count(*) as n from erp.stock_movement sm cross join t
           where sm.tenant_id = t.id and sm.movement_type = 'goods_receipt') x
  union all
  -- Planning.
  select 'planning', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' planning polic(ies) defined' else 'no planning policy yet' end
    from (select count(*) as n from erp.planning_policy pp cross join t
           where pp.tenant_id = t.id and pp.status = 'active') x
  union all
  select 'planning', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' planning run(s) finished' else 'planning has not been run yet' end
    from (select count(*) as n from erp.planning_run pr cross join t
           where pr.tenant_id = t.id and pr.finished_at is not null) x
  union all
  -- Production.
  select 'production', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' works order(s) raised' else 'no works order has been raised yet' end
    from (select count(*) as n from erp.works_order wo cross join t where wo.tenant_id = t.id) x
  union all
  select 'production', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' production output movement(s) recorded'
              else 'nothing has been made yet' end
    from (select count(*) as n from erp.stock_movement sm cross join t
           where sm.tenant_id = t.id and sm.movement_type = 'production_output') x
  union all
  -- Quality.
  select 'quality', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' inspection(s) completed' else 'nothing has been inspected yet' end
    from (select count(*) as n from erp.inspection i cross join t
           where i.tenant_id = t.id and i.completed_at is not null) x
  union all
  select 'quality', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' inspection(s) dispositioned' else 'nothing has been dispositioned yet' end
    from (select count(*) as n from erp.inspection i cross join t
           where i.tenant_id = t.id and i.disposition_at is not null) x
  union all
  -- Reporting.
  select 'reporting', 1::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' report run(s) recorded' else 'no report has been run yet' end
    from (select count(*) as n from erp.report_run rr cross join t where rr.tenant_id = t.id) x
  union all
  select 'reporting', 2::smallint, x.n > 0,
         case when x.n > 0 then x.n || ' report version(s) defined' else 'no report has been versioned yet' end
    from (select count(*) as n from erp.report_version rv cross join t where rv.tenant_id = t.id) x;
$$;

comment on function erp.first_run_evidence is
  '§22.2. What the organisation''s own tables say about each observable '
  'first-run step, and a sentence describing what was seen. One branch per '
  'step marked observable; erp.assert_first_run_guidance_actionable() holds '
  'the two sets equal.';

-- ── The guide, with the evidence folded in ──────────────────────────────────

-- Dropped rather than replaced: the row type gains columns.
drop function if exists erp.first_run_guide();

create or replace function erp.first_run_guide()
returns table (guide_code text, guide_name text, guide_seq smallint, seq smallint,
               screen_path text, permission_code text, title text, why text,
               action_label text, observable boolean, satisfied boolean, evidence text,
               done_at timestamptz, dismissed_at timestamptz, complete boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select s.guide_code,
         erp.text(g.name_key) as guide_name,
         g.seq as guide_seq,
         s.seq,
         s.screen_path, s.permission_code, s.title, s.why,
         s.action_label, s.observable,
         coalesce(e.satisfied, false) as satisfied,
         e.evidence,
         p.done_at, p.dismissed_at,
         -- The state decides where it can; the person decides everywhere else,
         -- and may overrule the state in either direction.
         (coalesce(e.satisfied, false) or p.done_at is not null or p.dismissed_at is not null) as complete
    from erp_ref.first_run_step s
    join erp_ref.first_run_guide g on g.code = s.guide_code
    left join erp.first_run_progress p
      on p.tenant_id = erp.current_tenant_id() and p.app_user_id = erp.current_principal_id()
     and p.guide_code = s.guide_code and p.seq = s.seq
    left join erp.first_run_evidence() e
      on e.guide_code = s.guide_code and e.seq = s.seq
   where erp.has_permission(s.permission_code, null, null, null, erp.current_principal_id())
   order by g.seq, s.seq
$$;

comment on function erp.first_run_guide is
  '§22.2. The first-run steps this person''s permissions make theirs, in guide '
  'order, with what the platform can see about each and whether they have '
  'ticked or dismissed it.';

-- ── The writers ──────────────────────────────────────────────────────────────

create or replace function erp.mark_first_run_step(p_guide_code text, p_seq smallint, p_done boolean default true)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_perm   text;
begin
  select s.permission_code into v_perm from erp_ref.first_run_step s
   where s.guide_code = p_guide_code and s.seq = p_seq;
  if v_perm is null then
    raise exception 'ERPWARE_UNKNOWN_STEP: %/% is not a first-run step', p_guide_code, p_seq
      using errcode = '23503',
            hint = 'Take the step from the first-run panel, which offers only steps that exist.';
  end if;
  -- The step is the caller's to mark only if it was theirs to take.
  perform erp.authorise(v_perm, null, null, null, 'first_run_step', null);

  if p_done then
    insert into erp.first_run_progress (tenant_id, app_user_id, guide_code, seq, done_at)
    values (v_tenant, v_me, p_guide_code, p_seq, now())
    on conflict (tenant_id, app_user_id, guide_code, seq) do update set done_at = now();
  else
    update erp.first_run_progress set done_at = null
     where tenant_id = v_tenant and app_user_id = v_me and guide_code = p_guide_code and seq = p_seq;
    delete from erp.first_run_progress
     where tenant_id = v_tenant and app_user_id = v_me and guide_code = p_guide_code and seq = p_seq
       and done_at is null and dismissed_at is null;
  end if;
end;
$$;

create or replace function erp.dismiss_first_run_step(p_guide_code text, p_seq smallint, p_dismissed boolean default true)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_me     uuid := erp.current_principal_id();
  v_perm   text;
begin
  select s.permission_code into v_perm from erp_ref.first_run_step s
   where s.guide_code = p_guide_code and s.seq = p_seq;
  if v_perm is null then
    raise exception 'ERPWARE_UNKNOWN_STEP: %/% is not a first-run step', p_guide_code, p_seq
      using errcode = '23503',
            hint = 'Take the step from the first-run panel, which offers only steps that exist.';
  end if;
  perform erp.authorise(v_perm, null, null, null, 'first_run_step', null);

  if p_dismissed then
    insert into erp.first_run_progress (tenant_id, app_user_id, guide_code, seq, done_at, dismissed_at)
    values (v_tenant, v_me, p_guide_code, p_seq, null, now())
    on conflict (tenant_id, app_user_id, guide_code, seq) do update set dismissed_at = now();
  else
    update erp.first_run_progress set dismissed_at = null
     where tenant_id = v_tenant and app_user_id = v_me and guide_code = p_guide_code and seq = p_seq;
    delete from erp.first_run_progress
     where tenant_id = v_tenant and app_user_id = v_me and guide_code = p_guide_code and seq = p_seq
       and done_at is null and dismissed_at is null;
  end if;
end;
$$;

comment on function erp.dismiss_first_run_step is
  '§22.2. Sets a step aside as not applying to this organisation, or brings it '
  'back. Recorded apart from done: an organisation with no scanners has not '
  'opened a scanner session, and should not be told it has.';

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_first_run_guide()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.require_tenant_id();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'guide_code', g.guide_code, 'guide_name', g.guide_name, 'guide_seq', g.guide_seq,
      'seq', g.seq, 'screen_path', g.screen_path,
      'permission_code', g.permission_code, 'title', g.title, 'why', g.why,
      'action_label', g.action_label, 'observable', g.observable,
      'satisfied', g.satisfied, 'evidence', g.evidence,
      'done_at', g.done_at, 'dismissed_at', g.dismissed_at, 'complete', g.complete)
      order by g.guide_seq, g.seq)
    from erp.first_run_guide() g), '[]'::jsonb);
end;
$$;

create or replace function public.erp_dismiss_first_run_step(p_guide_code text, p_seq integer, p_dismissed boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.dismiss_first_run_step(p_guide_code, p_seq::smallint, p_dismissed);
  return jsonb_build_object('guide_code', p_guide_code, 'seq', p_seq, 'dismissed', p_dismissed);
end;
$$;

revoke all on function public.erp_first_run_guide() from public, anon;
revoke all on function public.erp_dismiss_first_run_step(text, integer, boolean) from public, anon;
grant execute on function public.erp_first_run_guide() to authenticated, service_role;
grant execute on function public.erp_dismiss_first_run_step(text, integer, boolean) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_dismiss_first_run_step', 'erp.dismiss_first_run_step',
   '§22.2. Sets one of the caller''s own first-run steps aside as not applying, or brings it back. Gates on the step''s own permission: a step nobody could take is a step nobody can dismiss.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ── The assertion ────────────────────────────────────────────────────────────

create or replace function erp.first_run_guidance_report()
returns table (guide_code text, seq smallint, finding text)
language sql
stable
set search_path = ''
as $$
  -- A step the platform claims to observe, with no branch that looks.
  select s.guide_code, s.seq,
         'a step is marked observable and the evidence function has no branch for it'
    from erp_ref.first_run_step s
   where s.observable
     and not exists (select 1 from erp.first_run_evidence() e
                      where e.guide_code = s.guide_code and e.seq = s.seq)
  union all
  -- A branch that looks for a step that is not registered as observable: the
  -- evidence would be computed and then silently ignored.
  select e.guide_code, e.seq,
         'the evidence function has a branch for a step that is not marked observable'
    from erp.first_run_evidence() e
   where not exists (select 1 from erp_ref.first_run_step s
                      where s.guide_code = e.guide_code and s.seq = e.seq and s.observable)
  union all
  -- Two branches for one step would make the guide return it twice.
  select e.guide_code, e.seq, 'the evidence function has more than one branch for this step'
    from erp.first_run_evidence() e
   group by e.guide_code, e.seq
  having count(*) > 1
  union all
  -- A guide with no first step is a guide that starts nowhere.
  select g.code, 1::smallint, 'a registered guide has no step 1'
    from erp_ref.first_run_guide g
   where not exists (select 1 from erp_ref.first_run_step s where s.guide_code = g.code and s.seq = 1)
  union all
  -- A guide name that resolves to its own key is a name nobody wrote.
  select g.code, 0::smallint, 'a guide''s name key does not resolve through the resource layer'
    from erp_ref.first_run_guide g
   where erp.text(g.name_key) = g.name_key
  order by 1, 2;
$$;

comment on function erp.first_run_guidance_report is
  '§22.2. Where the first-run register and the evidence function disagree: a '
  'step nothing looks at, a branch nothing reads, a duplicated branch, a guide '
  'with no beginning, a guide with no name.';

create or replace function erp.assert_first_run_guidance_actionable()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_steps    integer;
  v_guides   integer;
  v_observed integer;
begin
  select count(*), string_agg(format('  %s [%s/%s]', r.finding, r.guide_code, r.seq), E'\n' order by r.guide_code, r.seq)
    into v_count, v_findings
    from erp.first_run_guidance_report() r;
  if v_count > 0 then
    raise exception E'ERPWARE_FIRST_RUN_GUIDANCE_BROKEN: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Add the branch to erp.first_run_evidence(), or clear observable on the step it no longer reads.';
  end if;

  select count(*), count(*) filter (where s.observable), count(distinct s.guide_code)
    into v_steps, v_observed, v_guides
    from erp_ref.first_run_step s;

  -- Every step names its action; the check constraint holds this, and the
  -- assertion states it so a reader of the CI log knows it was held.
  if exists (select 1 from erp_ref.first_run_step s where length(btrim(s.action_label)) = 0) then
    raise exception 'ERPWARE_FIRST_RUN_STEP_WITHOUT_ACTION: a step names no action'
      using errcode = 'P0001',
            hint = 'Give the step an action_label in the words of the screen it opens.';
  end if;

  return format('first-run guidance: %s steps across %s guides, %s observed from the organisation''s own state, all naming an action',
                v_steps, v_guides, v_observed);
end;
$$;

comment on function erp.assert_first_run_guidance_actionable is
  '§22.2. Fails when a step claims to be observable and nothing looks, when '
  'the evidence function reads a step the register does not mark observable, '
  'when a branch is duplicated, when a guide has no first step or no name, or '
  'when a step names no action.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('first_run_guidance', 'First-run guidance is actionable', 'assertion', 'platform',
   'erp', 'assert_first_run_guidance_actionable', '', 'first_run_guidance_report', '',
   'Every first-run step names the action it opens, and every step the platform claims to observe has a branch of erp.first_run_evidence() that looks. The message reports how many of the steps complete themselves.',
   true, 75)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function, detail_arguments = excluded.detail_arguments,
  blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ── The refusals this migration raises ──────────────────────────────────────

select erp.register_refusal('ERPWARE_UNKNOWN_STEP',
  'Marking or dismissing a first-run step that does not exist.',
  'The panel offers only steps that are registered; an unknown one came from somewhere else.',
  'Reload the dashboard and take the step from the first-run panel.');

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.first_run_guidance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_steps    integer;
  v_observed integer;
  v_branches integer;
  v_msg      text;
begin
  select count(*), count(*) filter (where observable) into v_steps, v_observed
    from erp_ref.first_run_step;
  select count(*) into v_branches from erp.first_run_evidence();

  return query select 'every guide a step belongs to is registered, in an order',
    not exists (select 1 from erp_ref.first_run_step s
                 where not exists (select 1 from erp_ref.first_run_guide g where g.code = s.guide_code)),
    format('%s guides', (select count(*) from erp_ref.first_run_guide));
  return query select 'every step names the action it opens',
    not exists (select 1 from erp_ref.first_run_step where length(btrim(action_label)) = 0),
    format('%s steps', v_steps);
  return query select 'the evidence function has exactly one branch per observable step',
    v_branches = v_observed, format('%s branches for %s observable steps', v_branches, v_observed);
  return query select 'most of the register completes itself rather than asking',
    v_observed >= v_steps - 3 and v_observed < v_steps,
    format('%s of %s steps are observed', v_observed, v_steps);
  return query select 'the two steps that cannot be observed are the two that are only reading',
    not exists (select 1 from erp_ref.first_run_step where not observable
                 and (guide_code, seq) not in (('finance', 1::smallint), ('warehouse', 1::smallint))),
    'finance/1 and warehouse/1';
  v_msg := erp.assert_first_run_guidance_actionable();
  return query select 'the assertion reports the register rather than claiming it is complete',
    v_msg ~ '^first-run guidance: \d+ steps across \d+ guides, \d+ observed', v_msg;

  -- With no organisation in context every branch reads nothing and says so,
  -- rather than failing: the panel must render for somebody mid-onboarding.
  return query select 'with no organisation in context the evidence is empty, not an error',
    not exists (select 1 from erp.first_run_evidence() where satisfied),
    format('%s branches, none satisfied', v_branches);
  return query select 'and each branch still says what it looked for',
    not exists (select 1 from erp.first_run_evidence() where evidence is null or length(btrim(evidence)) = 0),
    'every branch returns a sentence';

  -- A guide name resolves through the resource layer like every other string.
  return query select 'a guide is named through the resource layer, not in the front end',
    erp.text('guide.administrator') = 'Setting the organisation up',
    erp.text('guide.administrator');

  -- The register and the report agree.
  return query select 'the report finds nothing to say about a sound register',
    (select count(*) from erp.first_run_guidance_report()) = 0,
    format('%s finding(s)', (select count(*) from erp.first_run_guidance_report()));

  -- Dismissal is a different fact from completion, and the table says so.
  return query select 'a progress row must say something: done, dismissed, or it does not exist',
    exists (select 1 from pg_constraint
             where conrelid = 'erp.first_run_progress'::regclass
               and conname = 'first_run_progress_says_something'),
    'first_run_progress_says_something';

  -- The door is registered with the gate it actually reaches.
  return query select 'the dismissal door is registered against the writer it gates through',
    exists (select 1 from erp_meta.public_write_allowance
             where function_name = 'erp_dismiss_first_run_step' and gate = 'erp.dismiss_first_run_step'),
    'erp_meta.public_write_allowance';
end;
$$;

create or replace function erp_test.assert_first_run_guidance_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _first_run_guidance_result on commit drop as
    select * from erp_test.first_run_guidance_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _first_run_guidance_result;
  drop table _first_run_guidance_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_FIRST_RUN_GUIDANCE_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('first-run guidance: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_first_run_guidance_actionable();
select erp.assert_guidance_sound();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
