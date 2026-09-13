-- Every writer reaches a gate, or says why it needs none.
--
-- The build has always had a rule for this. erp.public_api_report() refuses "a
-- public API write function [that] reaches no authorisation at all", and every
-- migration since 0042 has run it inside its own transaction. It could not
-- fail. It walked from the gate a door's register row names rather than from
-- the door, and it counted any function on erp_meta.security_definer_allowance
-- as a gate. Every organisation-scoped function reaches erp.principal_context(),
-- through erp.require_tenant_id() and erp.current_tenant_id(), and
-- erp.principal_context() is on that allowance — so every writer passed. On 6
-- September 20260906145000 recreated public.erp_assign_named_approver() without
-- its erp.authorise('administration.configure'), ran the rule, and passed; the
-- permission prop on three desk buttons was the only guard for a week.
-- 20260913060000 found it from the desk's side, because a form happened to name
-- a permission for that door. A writer no form gates would have stayed hidden.
--
-- So the rule now means what it says:
--
--   * the walk starts at the door, and uses the judge the desk check already
--     uses (erp.app_gate_report(), 20260913060000): names matched on
--     comment-stripped, string-blanked code, so a routine named in a comment or
--     a hint is not a call;
--   * only erp.authorise() or erp_meta.require_platform() in code counts as a
--     gate, and the SECURITY DEFINER allowance does not;
--   * a writer legitimately gated another way says so, in a new column on its
--     own register row — erp_meta.public_write_allowance.ungated_because — with
--     one of five reasons: it touches only the caller's own records; it acts only
--     on a task assigned to the caller; a secret the caller presents is the gate;
--     it is the bootstrap that creates the first owner or organisation, before
--     anyone could hold a permission; or it is a read that writes nothing;
--   * and a door registered as needing no gate that reaches one is stale, and
--     refused too, so the column cannot go on excusing a door that changed.
--
-- The stricter walk found fifteen register rows. What happened to each:
--
--   Given a gate, because they had none and should have:
--     erp_platform_propose_renewals — runs the renewal sweep across every
--       organisation's contracts. erp.propose_renewals() refuses a session whose
--       role does not bypass row-level security, but it is SECURITY DEFINER, and
--       inside its own frame current_user is the owner, so that test passes for
--       everybody signed in. The door now requires the platform operator on its
--       first line, and runs as its owner as erp_platform_generate_invoices
--       does, because the platform schema its gate lives in is sealed to a
--       signed-in caller; the scheduler calls the erp function directly.
--     erp_purge_expired_document_previews — any member of an organisation could
--       delete its expired preview rows, and with them the only record of where
--       the preview files are, which no browser role can then remove. The door
--       now asks for document.template_manage, the permission that creates a
--       preview. The worker sweeps through the erp function under its own
--       principal and is unaffected; the server function sweeps only when it
--       makes a preview (committed with this file).
--
--   Registered as needing no gate, each with its reason:
--     erp_claim_invitation, erp_analytics_read          — a secret presented
--     erp_decide_approval                               — the caller's own task
--     erp_mark_notification_read, erp_set_my_quiet_hours,
--     erp_set_notification_preference, erp_set_active_tenant
--                                                       — the caller's own records
--     erp_platform_claim_ownership, erp_onboard_tenant  — bootstrap
--     erp_tenant_state, erp_report_reproducibility      — reads, volatile since
--       20260904680000 because a comment named a gate they never call
--
--   Taken off the write register, because they do not write:
--     erp_platform_me — a stable lookup of the caller's own staff row, declared
--       volatile by accident in 20260830091046; now stable;
--     erp_document_approval_chain — stable since 20260904730000; the row stayed.
--
-- And the walkthrough is judged the same way: erp.setup_walkthrough_report()
-- gains a finding for a step whose permission its door does not ask for. All
-- fifty-three steps that open a door match today; the finding keeps it so.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A register row can say why its door needs no gate
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.public_write_allowance
  add column if not exists ungated_because text;

alter table erp_meta.public_write_allowance
  add constraint public_write_allowance_ungated_because_known
  check (ungated_because is null
         or ungated_because in ('own_records', 'assigned_task', 'bearer_token', 'bootstrap', 'read_only'));

comment on column erp_meta.public_write_allowance.ungated_because is
  'Null for a door that reaches erp.authorise() or erp_meta.require_platform(). '
  'Otherwise why it needs neither: own_records (it touches only the caller''s '
  'own rows), assigned_task (it acts only on a task assigned to the caller), '
  'bearer_token (a secret the caller presents is the gate), bootstrap (it '
  'creates the first owner or organisation, before any permission can exist), '
  'read_only (it writes nothing). erp.public_api_report() refuses a door with '
  'neither a gate nor a reason, and a door with a reason that reaches a gate.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Two rows for doors that do not write
-- ═════════════════════════════════════════════════════════════════════════════

-- A lookup of the caller's own staff row through the stable
-- erp_meta.platform_actor(); nothing it reaches writes.
alter function public.erp_platform_me() stable;
delete from erp_meta.public_write_allowance where function_name = 'erp_platform_me';

-- Stable since 20260904730000; the row outlived the volatility.
delete from erp_meta.public_write_allowance where function_name = 'erp_document_approval_chain';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Two doors that needed a gate
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260904620000, so the grants stay.
create or replace function public.erp_platform_propose_renewals()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Runs as its owner because erp_meta is sealed to a signed-in caller, so an
  -- invoker door could not even name its gate (20260910145350 met the same
  -- wall). erp.propose_renewals() tests erp.session_is_trusted(), which inside
  -- a SECURITY DEFINER frame reports the owner and so admits everybody; the
  -- gate is here, on the first line. The scheduler calls the erp function directly.
  perform erp_meta.require_platform('operator');
  return erp.propose_renewals();
end;
$$;

-- Same signature and return type as 20260911123400, so the grants stay.
create or replace function public.erp_purge_expired_document_previews()
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  -- The permission that creates a preview is the one that may sweep them. The
  -- worker sweeps through erp.purge_expired_document_previews() under its own
  -- principal, not through this door.
  perform erp.authorise('document.template_manage');
  return erp.purge_expired_document_previews();
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_propose_renewals', 'erp.propose_renewals',
   'Runs the renewal sweep on demand. Platform operator, on the first line of the door; the sweep writes renewal proposals only.'),
  ('erp_purge_expired_document_previews', 'erp.purge_expired_document_previews',
   'Deletes this organisation''s expired preview rows and returns their paths so the files go too, under document.template_manage.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_propose_renewals',
   'Operator door, gated by erp_meta.require_platform(''operator'') on its first line. Runs as its owner because erp_meta is sealed to a signed-in caller, so an invoker door cannot name the gate.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

update erp_meta.security_definer_allowance
   set rationale = 'Sweeps every contract in force and writes proposals. Reached by the scheduler and by public.erp_platform_propose_renewals(), which requires the platform operator; its session_is_trusted() test reports the owner inside this frame and is not the gate.'
 where schema_name = 'erp' and function_name = 'propose_renewals';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Eleven doors that need no gate, and why
-- ═════════════════════════════════════════════════════════════════════════════

do $ungated$
declare
  v_n integer;
begin
  with reasons (function_name, basis, rationale) as (values
    ('erp_claim_invitation', 'bearer_token',
     'Redeems a single-use invitation: erp.claim_invitation() refuses unless the digest of a token of at least 32 characters matches an open invitation minted under administration.users or the platform operator, and binds only auth.uid() to that one waiting principal.'),
    ('erp_analytics_read', 'bearer_token',
     'The presented analytics credential is the gate: its digest must match a live credential whose principal is active, the view must be one it names and the organisation exposed, and it writes only last_used_at.'),
    ('erp_decide_approval', 'assigned_task',
     'Decides only an approval task assigned to the caller: erp.decide_approval_task() refuses unless the pending task''s assignee is the current principal, and tasks are assigned from the configured chain, not by the caller.'),
    ('erp_mark_notification_read', 'own_records',
     'Marks read only a notification addressed to the caller: the update is keyed to the session''s organisation and erp.current_principal_id(), and it refuses when no unread row of theirs matches.'),
    ('erp_set_notification_preference', 'own_records',
     'Sets only the caller''s own channel preference: the row is keyed to the session''s organisation and erp.current_principal_id(), never a parameter, and in-app cannot be switched off.'),
    ('erp_set_my_quiet_hours', 'own_records',
     'Replaces only the caller''s own quiet-hours window: every delete and insert is keyed to erp.current_principal_id() in the caller''s organisation, so role and organisation windows are out of reach.'),
    ('erp_set_active_tenant', 'own_records',
     'Writes only the caller''s own active-organisation preference, keyed on auth.uid(), and only to an organisation where that sign-in already holds an active principal; the door also refuses anyone who is not platform staff.'),
    ('erp_platform_claim_ownership', 'bootstrap',
     'The one-time platform bootstrap: it refuses without a signed-in subject and once any unrevoked staff row exists, and writes only the caller''s own owner row and its audit entry.'),
    ('erp_onboard_tenant', 'bootstrap',
     'Creates a new organisation with the signed-in caller as its first administrator; there is no organisation yet in which anyone could hold a permission, and it refuses a subject without an email.'),
    ('erp_tenant_state', 'read_only',
     'A read of this organisation''s own state for the go-live screen. Volatile since 20260904680000 because a comment named erp.go_live(); it calls no gate and writes nothing.'),
    ('erp_report_reproducibility', 'read_only',
     'A read of this organisation''s report versions and runs. Volatile since 20260904680000 because a comment named erp.authorise(); it calls no gate and writes nothing.')
  ), updated as (
    update erp_meta.public_write_allowance w
       set ungated_because = r.basis, rationale = r.rationale
      from reasons r
     where w.function_name = r.function_name
    returning 1
  )
  select count(*) into v_n from updated;

  if v_n <> 11 then
    raise exception 'CLOVEERP_UNGATED_REGISTER_INCOMPLETE: % of 11 register rows were found to annotate', v_n;
  end if;
end
$ungated$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The rule, walking from the door and counting only real gates
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive fn as (
    select p.oid, p.pronamespace::regnamespace::text as ns, p.proname, p.prosrc
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
  ),
  edge as (
    select caller.oid as caller, callee.oid as callee
      from fn caller join fn callee
        on caller.oid <> callee.oid
       and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
  ),
  -- What each registered writer reaches, judged by erp.app_gate_report()
  -- (20260913060000): the walk starts at the door itself, names are matched on
  -- comment-stripped, string-blanked text, and only erp.authorise() or
  -- erp_meta.require_platform() in code counts as a gate. Membership of
  -- erp_meta.security_definer_allowance does not: every organisation-scoped
  -- function reaches erp.principal_context(), which is on it, and counting it
  -- passed every writer, erp_assign_named_approver's lost gate included.
  door_gate as (
    select g.door, g.verdict, g.detail
      from erp.app_gate_report(array(select w.function_name || '|'
                                       from erp_meta.public_write_allowance w)) g
  ),
  -- Everything in erp/erp_meta that authorises, and everything that reaches
  -- something that authorises within six hops. Used to judge whether a public
  -- DEFINER function gates, whether it does so itself or through the erp
  -- function it delegates to.
  authorising as (
    select f.oid, f.ns, f.proname from fn f
     where position('erp.authorise(' in f.prosrc) > 0
        or position('erp_meta.require_platform(' in f.prosrc) > 0
  ),
  reaches_gate as (
    select a.oid as reached, 0 as depth from authorising a
    union
    select e.caller, r.depth + 1
      from reaches_gate r join edge e on e.callee = r.reached
     where r.depth < 6
  ),
  secdef_ok as (
    select p.oid
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
       and (
         position('erp.authorise(' in p.prosrc) > 0
         or position('erp_meta.require_platform(' in p.prosrc) > 0
         or exists (
           select 1 from fn f join reaches_gate g on g.reached = f.oid
            where position(f.ns || '.' || f.proname || '(' in p.prosrc) > 0)
       )
  )
  select 'a public API function is SECURITY DEFINER and is not registered',
         p.oid::regprocedure::text,
         'it runs as the owner, who bypasses row-level security; add it to '
         'erp_meta.security_definer_allowance under schema_name ''public'' '
         'with a rationale, or make it SECURITY INVOKER'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and not exists (select 1 from erp_meta.security_definer_allowance a
                      where a.schema_name = 'public' and a.function_name = p.proname)
  union all
  select 'a registered SECURITY DEFINER function reaches no authorisation',
         p.oid::regprocedure::text,
         'it is exempt from the blanket ban but still never asks whether the '
         'caller may; registration excuses the bypass, not the gate'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and exists (select 1 from erp_meta.security_definer_allowance a
                  where a.schema_name = 'public' and a.function_name = p.proname
                    and a.rationale not like 'UNGATED BY DESIGN:%')
     and not exists (select 1 from secdef_ok s where s.oid = p.oid)
  union all
  -- Three names carried two functions each before this migration, and every
  -- one of them was a live breakage: a call matching both candidates and
  -- neither, raising "is not unique" rather than failing a case. CREATE OR
  -- REPLACE silently overloads when the argument list differs, so this is what
  -- editing a public function through a slightly different signature looks
  -- like, and nothing was watching for it.
  --
  -- The register is keyed on function_name alone, so it cannot describe two
  -- functions sharing a name even when both are reachable. One name, one
  -- function.
  select 'two functions share a public API name',
         'public.' || p.proname,
         format('%s overloads: %s. A caller relying on defaults matches both '
                'and resolves to neither', count(*),
                string_agg(pg_catalog.pg_get_function_arguments(p.oid), ' | '))
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
   group by p.proname
  having count(*) > 1
  union all
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  select 'a public API function writes but is not on the write allow-list',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; add it to '
         'erp_meta.public_write_allowance with a rationale, or make it STABLE'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and p.provolatile = 'v'
     and not exists (select 1 from erp_meta.public_write_allowance w
                      where w.function_name = p.proname)
  union all
  select 'a public API write function does not call its declared gate',
         p.oid::regprocedure::text,
         format('%s is on the allow-list gated by %s, but its body does not call it',
                p.proname, w.gate)
    from pg_catalog.pg_proc p
    join erp_meta.public_write_allowance w on w.function_name = p.proname
   where p.pronamespace = 'public'::regnamespace
     and position(w.gate || '(' in p.prosrc) = 0
  union all
  select 'a write allow-list entry names no function', w.function_name,
         'nothing is being permitted, and nothing is being checked'
    from erp_meta.public_write_allowance w
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname = w.function_name)
  union all
  select 'a public API write function reaches no authorisation at all',
         w.function_name,
         'nothing the door calls within six calls authorises or requires platform '
         'staff, reading code rather than comments; give the door a gate, or say '
         'in erp_meta.public_write_allowance.ungated_because why it needs none'
    from erp_meta.public_write_allowance w
    join door_gate g on g.door = w.function_name
   where g.verdict in ('ungated_read', 'ungated_write')
     and w.ungated_because is null
  union all
  select 'a write door registered as needing no gate reaches one',
         w.function_name,
         format('registered ungated because %s, but the door now reaches an '
                'authorisation (%s: %s); clear ungated_because', w.ungated_because, g.verdict, g.detail)
    from erp_meta.public_write_allowance w
    join door_gate g on g.door = w.function_name
   where w.ungated_because is not null
     and g.verdict not in ('ungated_read', 'ungated_write', 'missing_door')
$$;

comment on function erp.public_api_report() is
  'Every way the public surface could be unsafe: an unregistered or ungated '
  'SECURITY DEFINER door, two functions under one name, a door anon may call, '
  'a writer off the register or not calling its declared gate, and a writer '
  'that reaches neither erp.authorise() nor erp_meta.require_platform() in code '
  'without saying in ungated_because why it needs none — or says so and does.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. A walkthrough step names a permission its door asks for
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.setup_walkthrough_report()
returns table (finding text, step_code text, detail text)
language sql
stable
set search_path = ''
as $$
  -- A step that claims to be observable and nothing looks.
  select 'an observable step has no evidence branch', s.code, s.title
    from erp_ref.setup_step s
   where s.observable
     and not exists (select 1 from erp.setup_evidence() e where e.step_code = s.code)
  union all
  -- A branch that looks at a step the register does not mark observable, or
  -- that does not exist.
  select 'the evidence function reads a step that is not observable', e.step_code, ''
    from erp.setup_evidence() e
   where not exists (select 1 from erp_ref.setup_step s where s.code = e.step_code and s.observable)
  union all
  select 'the evidence function reads a step twice', e.step_code, count(*)::text || ' branches'
    from erp.setup_evidence() e
   group by e.step_code having count(*) > 1
  union all
  -- The door a step opens must exist.
  select 'a step opens a door that does not exist', s.code, s.action_fn
    from erp_ref.setup_step s
   where s.action_fn is not null
     and not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace and p.proname = s.action_fn)
  union all
  -- What a step requires must exist, and must come first in the order.
  select 'a step requires a step that does not exist', s.code, r
    from erp_ref.setup_step s, unnest(s.requires) r
   where not exists (select 1 from erp_ref.setup_step x where x.code = r)
  union all
  select 'a step requires a step that comes after it', s.code, r
    from erp_ref.setup_step s
    join erp_ref.setup_screen sc on sc.screen_path = s.screen_path,
    unnest(s.requires) r
    join erp_ref.setup_step x on x.code = r
    join erp_ref.setup_screen xc on xc.screen_path = x.screen_path
   where (xc.seq, x.seq) >= (sc.seq, s.seq)
  union all
  -- Every screen in the order has a first step, and the order has no gaps.
  select 'a screen in the setup order has no first step', sc.screen_path, ''
    from erp_ref.setup_screen sc
   where not exists (select 1 from erp_ref.setup_step s where s.screen_path = sc.screen_path and s.seq = 1)
  union all
  select 'the setup order has a gap', sc.seq::text, ''
    from erp_ref.setup_screen sc
   where sc.seq > 1 and not exists (select 1 from erp_ref.setup_screen p where p.seq = sc.seq - 1)
  union all
  -- The permission a step names is one its door asks for, judged the way the
  -- desk's forms are (erp.app_gate_report, 20260913060000). A step under the
  -- wrong code tells a person they may take it, then the door refuses them.
  select 'a step names a permission its door does not ask for', s.code,
         format('%s under %s — %s: %s', g.door, g.permission_code, g.verdict, g.detail)
    from erp_ref.setup_step s
    join erp.app_gate_report(array(select distinct x.action_fn || '|' || x.permission_code
                                     from erp_ref.setup_step x
                                    where x.action_fn is not null)) g
      on g.door = s.action_fn and g.permission_code = s.permission_code
   where g.verdict in ('mismatch', 'ungated_write', 'platform')
$$;

comment on function erp.setup_walkthrough_report() is
  'Part 22. What is wrong with the setup walkthrough register, if anything: an '
  'observable step nothing looks at, a branch for a step that is not '
  'observable, a step the evidence function reads twice, a door that does not '
  'exist, a requirement that does not exist or comes later, a screen with no '
  'first step, a gap in the order, or a step naming a permission its door does '
  'not ask for, judged by erp.app_gate_report().';

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.write_gate_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_findings    text;
  v_msg         text;
  v_tenancy     boolean;
  v_comment     boolean;
  v_own_flagged boolean;
  v_stale       boolean;
begin
  -- 1
  select string_agg(format('%s [%s]', r.finding, r.reference), '; ' order by r.reference)
    into v_findings
    from erp.public_api_report() r;
  case_name := 'every registered writer reaches a gate or says why it needs none';
  passed := v_findings is null;
  detail := coalesce(v_findings, 'no finding');
  return next;

  -- 2 to 5. Four doors built, judged together and undone.
  begin
    execute $ddl$
      create function public.erp_zz_writes_behind_tenancy() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.require_tenant_id();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_names_a_gate_in_a_comment() returns void
      language plpgsql set search_path = '' as $b$
      begin
        -- perform erp.authorise('administration.configure');
        perform erp.require_tenant_id();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_touches_own_records() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.current_principal_id();
      end $b$
    $ddl$;
    execute $ddl$
      create function public.erp_zz_gated_yet_registered_ungated() returns void
      language plpgsql set search_path = '' as $b$
      begin
        perform erp.authorise('administration.configure');
      end $b$
    $ddl$;

    insert into erp_meta.public_write_allowance (function_name, gate, rationale, ungated_because) values
      ('erp_zz_writes_behind_tenancy', 'erp.require_tenant_id', 'Suite fixture: reaches only erp.principal_context().', null),
      ('erp_zz_names_a_gate_in_a_comment', 'erp.require_tenant_id', 'Suite fixture: names a gate only in a comment.', null),
      ('erp_zz_touches_own_records', 'erp.current_principal_id', 'Suite fixture: registered as touching own records.', 'own_records'),
      ('erp_zz_gated_yet_registered_ungated', 'erp.authorise', 'Suite fixture: gated, yet registered as needing none.', 'own_records');

    select coalesce(bool_or(r.reference = 'erp_zz_writes_behind_tenancy'
                            and r.finding = 'a public API write function reaches no authorisation at all'), false),
           coalesce(bool_or(r.reference = 'erp_zz_names_a_gate_in_a_comment'
                            and r.finding = 'a public API write function reaches no authorisation at all'), false),
           coalesce(bool_or(r.reference = 'erp_zz_touches_own_records'
                            and r.finding in ('a public API write function reaches no authorisation at all',
                                              'a write door registered as needing no gate reaches one')), false),
           coalesce(bool_or(r.reference = 'erp_zz_gated_yet_registered_ungated'
                            and r.finding = 'a write door registered as needing no gate reaches one'), false)
      into v_tenancy, v_comment, v_own_flagged, v_stale
      from erp.public_api_report() r;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
  end;

  -- 2
  case_name := 'a writer whose only route to a SECURITY DEFINER function is tenancy is refused';
  passed := v_msg is null and v_tenancy;
  detail := coalesce(v_msg, 'erp.require_tenant_id() reaches erp.principal_context(), and that is not a gate');
  return next;

  -- 3
  case_name := 'a gate named only in a comment is not a gate';
  passed := v_msg is null and v_comment;
  detail := coalesce(v_msg, 'the comment names erp.authorise(); the code calls nothing that authorises');
  return next;

  -- 4
  case_name := 'a writer that says it touches only its caller''s records is accepted';
  passed := v_msg is null and not v_own_flagged;
  detail := coalesce(v_msg, 'ungated_because own_records');
  return next;

  -- 5
  case_name := 'a writer registered as needing no gate that reaches one is refused as stale';
  passed := v_msg is null and v_stale;
  detail := coalesce(v_msg, 'it calls erp.authorise() and says it needs no gate');
  return next;

  -- 6
  case_name := 'the fixtures were undone';
  passed := not exists (select 1 from pg_catalog.pg_proc p
                         where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_zz\_%')
        and not exists (select 1 from erp_meta.public_write_allowance w where w.function_name like 'erp\_zz\_%');
  detail := 'four doors and four register rows rolled back';
  return next;
end;
$$;
revoke all on function erp_test.write_gate_suite() from public, anon, authenticated;

create or replace function erp_test.assert_write_gate_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _write_gate on commit drop as
    select * from erp_test.write_gate_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _write_gate;
  drop table _write_gate;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_WRITE_GATE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_WRITE_GATE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('write gates: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_write_gate_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_setup_walkthrough_actionable();
select erp_test.assert_write_gate_suite();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
