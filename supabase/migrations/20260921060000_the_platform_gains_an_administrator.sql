set lock_timeout = '30s';

-- =============================================================================
-- 20260921060000  The platform gains an administrator
-- -----------------------------------------------------------------------------
-- The vendor console's staff list had three ranks: owner, operator, support.
-- Everything an operator could not do was an owner's, and that put running the
-- platform and owning it in the same hand. This adds a fourth rank between
-- them.
--
--     owner 4 · administrator 3 · operator 2 · support 1
--
-- An administrator runs the platform. They cannot change who runs it, cannot
-- move a company to a different owner, and cannot purge a company. Purge is the
-- one act with no undo, so it stays at the top with the three acts that decide
-- who holds the top.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What actually moves, read from the routines rather than from a list
--
-- There were thirteen literal erp_meta.require_platform('owner') call sites, and
-- one more inside a case expression that nothing grepping for the literal would
-- find. Fourteen gates, not thirteen. Six move:
--
--   public.erp_platform_set_billing_contact
--   public.erp_platform_set_billing_details
--   public.erp_platform_set_self_service_organisations
--   public.erp_platform_erase_enquiry
--   erp.designate_platform_organisation
--   public.erp_platform_set_tenant_status, for its 'deleted' arm only
--
-- Eight stay:
--
--   public.erp_platform_add_staff            who works on the platform
--   public.erp_platform_revoke_staff
--   public.erp_platform_set_staff_role
--   public.erp_platform_offer_ownership      who a company belongs to
--   public.erp_platform_respond_ownership_transfer
--   public.erp_platform_cancel_ownership_transfer
--   public.erp_platform_purge_tenant         what cannot be undone
--   public.erp_platform_purge_due_tenants
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Rank is computed, never stored
--
-- erp_meta.platform_rank() is the single pivot, and nothing anywhere holds a
-- rank number, so renumbering owner from 3 to 4 is safe. Two callers read it for
-- something other than the gate and both still hold: public.erp_platform_staff
-- orders by it descending, and owner at 4 is still above administrator at 3;
-- erp_platform_add_staff and erp_platform_set_staff_role treat rank 0 as "not a
-- role", and administrator at 3 is therefore a role they will now accept.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The bodies are patched by needle, never re-emitted
--
-- erp_meta.require_platform and its neighbours were written on 30 August with a
-- retired refusal prefix, and 20260904980000 and 20260912201000 swept every
-- routine's source to the current one. The text in the original migration is not
-- the text that is deployed. Re-emitting it would put the retired prefix back
-- and erp.assert_no_legacy_refusal_prefix() would fail the build on it — it
-- reads routine source including comments.
--
-- So each gate is patched from pg_get_functiondef(), and the patch asserts its
-- anchor occurs exactly once before replacing. erp_meta.require_platform itself
-- needs no patch at all: it compares ranks and names no role.
-- erp_meta.platform_rank is the one body re-emitted whole, because it is four
-- lines, has never been patched, and carries no refusal text.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is deliberately NOT converted
--
-- Several tests read staff_role = 'owner' directly. Every one of them is about
-- identity rather than authority and each is left exactly as it is:
--
--   erp_platform_set_staff_role and erp_platform_revoke_staff count the owners
--   before letting the last one go. A rank comparison there would let the last
--   owner be demoted to administrator and leave the platform with nobody who
--   could appoint one.
--
--   erp_platform_offer_ownership requires the person being offered a company to
--   be an owner. An administrator does not own companies, and rank does not
--   change that.
--
--   erp_platform_tenants resolves which owner is accountable for a company.
--   "The owner of this company" is a person, not a rank threshold.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And two gaps in the deletion window, which the owner accepted closing
--
-- erp_platform_set_tenant_status set deleted_at when a company was marked ended
-- and never cleared it. A company brought back to active kept the marker, and
-- erp.purge_due_tenants selects on "deleted_at is not null" — so the only thing
-- standing between a reinstated company and the sweep was the status filter. Get
-- suspended for an unpaid invoice a year later and the sweep would have taken
-- it. That is closed twice over: the existing door clears the marker on its way
-- back to active, and a reinstate door says so as its own act.
--
-- The sweep's grace period was an argument with no floor, so a caller could pass
-- nothing and purge a company ended a minute ago. It is now policy: the routine
-- that does the deleting refuses below the floor, whoever asks and from wherever
-- they ask. Within the floor an owner may still shorten it, and only an owner,
-- because the sweep is owner-gated and stays that way.
--
-- Reinstating is an administrator's, not an owner's. The rank for an act is the
-- rank for undoing it: an administrator who can mark a company ended and cannot
-- bring it back holds the harmful half and not the remedy, which makes a
-- reversible act irreversible for exactly the person most likely to have made
-- the mistake. Symmetry with purge is the wrong symmetry — purge has no undo,
-- which is why it is alone at the top. Reinstating destroys nothing and grants
-- nobody anything; a company wrongly brought back is marked ended again by the
-- same rank.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- And the class is closed
--
-- Fourteen gates that nobody rechecks is a security boundary held together by
-- attention. erp_meta.platform_door_rank records the rank every reserved door
-- demands, and erp.assert_platform_door_ranks() refuses a mismatch in either
-- direction: a registered door whose body no longer asks for the rank the
-- register says, and a body asking for a reserved rank that the register has
-- never heard of. The register covers administrator and owner — the ranks a door
-- can be reserved at — and deliberately not operator or support, which are the
-- floor and would tax every new read for no boundary.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The pivot
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_meta.platform_rank(p_role text)
returns integer
language sql
immutable
set search_path = ''
as $$ select case p_role when 'owner' then 4 when 'administrator' then 3
                         when 'operator' then 2 when 'support' then 1
                         else 0 end $$;

comment on function erp_meta.platform_rank is
  'The order of the platform staff ranks, computed and never stored: owner 4, '
  'administrator 3, operator 2, support 1, and 0 for anything that is not a '
  'rank at all. The gate compares two of these; nothing holds the number.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The constraint that lists the ranks
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The check was written inline in the 30 August table definition, so PostgreSQL
-- named it. Guessing that name and being wrong would drop nothing and leave the
-- new rank refused by a constraint nobody could see; so it is read from
-- pg_constraint, and the read refuses unless it finds exactly one.

do $constraint$
declare
  v_name  text;
  v_count integer;
begin
  select count(*), min(c.conname)
    into v_count, v_name
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class t     on t.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'erp_meta'
     and t.relname = 'platform_staff'
     and c.contype = 'c'
     and pg_catalog.pg_get_constraintdef(c.oid) like '%staff_role%';

  if v_count <> 1 then
    raise exception
      'CLOVEERP_STAFF_RANK_CONSTRAINT_NOT_UNIQUE: found % check constraint(s) on the staff list naming the rank, expected exactly one',
      v_count
      using hint = 'Read pg_constraint and name the one to drop; do not guess it.';
  end if;

  execute format('alter table erp_meta.platform_staff drop constraint %I', v_name);
end
$constraint$;

alter table erp_meta.platform_staff
  add constraint platform_staff_rank_is_known
  check (staff_role in ('owner', 'administrator', 'operator', 'support'));

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The six gates that move, patched by needle
-- ═════════════════════════════════════════════════════════════════════════════

do $needle$
declare
  r      record;
  v_oid  oid;
  v_def  text;
  v_hits integer;
begin
  for r in
    select *
      from (values
        ('public.erp_platform_set_billing_contact(uuid, text, text)',
         '  v := erp_meta.require_platform(''owner'');',
         '  v := erp_meta.require_platform(''administrator'');'),
        ('public.erp_platform_set_billing_details(text, text, text, text, text, text, text)',
         '  v := erp_meta.require_platform(''owner'');',
         '  v := erp_meta.require_platform(''administrator'');'),
        ('public.erp_platform_set_self_service_organisations(boolean, text)',
         '  v := erp_meta.require_platform(''owner'');',
         '  v := erp_meta.require_platform(''administrator'');'),
        ('public.erp_platform_erase_enquiry(uuid, text)',
         '  v := erp_meta.require_platform(''owner'');',
         '  v := erp_meta.require_platform(''administrator'');'),
        ('erp.designate_platform_organisation(text, text)',
         '  v_staff := erp_meta.require_platform(''owner'');',
         '  v_staff := erp_meta.require_platform(''administrator'');'),
        -- Marking a company ended is reversible, so it is an administrator's.
        -- The other arm stays where it was.
        ('public.erp_platform_set_tenant_status(uuid, text, text)',
         'case when p_status = ''deleted'' then ''owner'' else ''operator'' end',
         'case when p_status = ''deleted'' then ''administrator'' else ''operator'' end'),
        -- And the same door stops leaving the deletion marker behind it. A
        -- company that is trading is not a company awaiting removal, and the
        -- sweep reads that column and not the status.
        ('public.erp_platform_set_tenant_status(uuid, text, text)',
         'deleted_at   = case when p_status = ''deleted'' then now() else deleted_at end,',
         'deleted_at   = case when p_status = ''deleted'' then now()
                              when p_status = ''active''  then null
                              else deleted_at end,'),
        -- And the one refusal that counted the ranks out loud. It said an
        -- unknown role "is not owner, operator or support", which from today is
        -- a sentence that refuses a role the same message says is not one.
        ('public.erp_platform_add_staff(text, text, text)',
         '% is not owner, operator or support',
         '% is not one of the four ranks: owner, administrator, operator or support')
      ) as v(sig, needle, thread)
  loop
    v_oid := r.sig::regprocedure::oid;
    v_def := pg_catalog.pg_get_functiondef(v_oid);
    v_hits := (length(v_def) - length(replace(v_def, r.needle, ''))) / length(r.needle);

    if v_hits <> 1 then
      raise exception
        'CLOVEERP_GATE_ANCHOR_NOT_UNIQUE: % occurrence(s) of the anchor in %, expected exactly one',
        v_hits, r.sig
        using hint = 'The deployed body has moved. Read it with pg_get_functiondef and pick an anchor that occurs once.';
    end if;

    execute replace(v_def, r.needle, r.thread);
  end loop;
end
$needle$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The waiting period is policy, not an argument
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.purge_grace_floor()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '7 days' $$;

comment on function erp.purge_grace_floor is
  'The shortest waiting period the deletion sweep will run with. It was an '
  'argument with no floor until 20260921060000, so a caller could pass zero and '
  'take an organisation marked ended a minute earlier.';

create or replace function erp.require_purge_grace(p_grace interval)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_grace is null or p_grace < erp.purge_grace_floor() then
    raise exception
      'CLOVEERP_PURGE_GRACE_TOO_SHORT: the sweep was asked to wait %, and the shortest it waits is %',
      coalesce(p_grace::text, 'no time at all'), erp.purge_grace_floor()::text
      using errcode = '22023';
  end if;
end;
$$;

comment on function erp.require_purge_grace is
  'Refuses a deletion sweep asked to wait less than the platform keeps. Called '
  'from erp.purge_due_tenants, which is where the rows actually go, so a backend '
  'session reaching that routine directly is held to it too.';

select erp.register_refusal('CLOVEERP_PURGE_GRACE_TOO_SHORT',
  'Running the deletion sweep with a shorter wait than the platform keeps.',
  'The wait between an organisation being marked as ended and its rows being removed is the only chance anybody has to notice a mistake. A sweep told to wait less than the shortest wait the platform keeps would take an organisation that was ended minutes earlier, and nothing brings one back.',
  'Run the sweep with at least the wait the platform keeps. To remove a single organisation now, purge that one by name from its own page, which asks for its code to be typed out and a reason to be given.');

do $floor$
declare
  v_def  text;
  v_hits integer;
  c_needle constant text := '  if p_grace < interval ''0'' then';
begin
  v_def := pg_catalog.pg_get_functiondef('erp.purge_due_tenants(interval)'::regprocedure::oid);
  v_hits := (length(v_def) - length(replace(v_def, c_needle, ''))) / length(c_needle);

  if v_hits <> 1 then
    raise exception
      'CLOVEERP_SWEEP_ANCHOR_NOT_UNIQUE: % occurrence(s) of the anchor in the sweep, expected exactly one',
      v_hits
      using hint = 'Read the deployed body with pg_get_functiondef and pick an anchor that occurs once.';
  end if;

  execute replace(v_def, c_needle,
                  '  perform erp.require_purge_grace(p_grace);' || chr(10) || c_needle);
end
$floor$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Reinstating an organisation
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Purging cannot be undone: it is a delete inside a purge fence and the rows are
-- gone. Marking ended can be, and the comment in 20260831170000 says as much —
-- "deleted_at. That is a label. It removes nothing." This is the door that
-- treats it as a label: it takes the marker off, puts the organisation back to a
-- working status, and records that it was brought back rather than that somebody
-- edited a field.

create or replace function public.erp_platform_reinstate_tenant(
  p_tenant_id uuid, p_reason text, p_status text default 'suspended')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v   erp_meta.platform_staff;
  v_t erp.tenant;
begin
  -- The rank that marks an organisation ended is the rank that brings it back.
  v := erp_meta.require_platform('administrator');

  if p_status not in ('active', 'suspended') then
    raise exception
      'CLOVEERP_UNKNOWN_TENANT_STATUS: % is not somewhere an organisation can be brought back to; it can come back trading or come back paused',
      p_status
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception
      'CLOVEERP_REASON_REQUIRED: bringing an organisation back is recorded against your name and needs a reason'
      using errcode = '22023';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: no organisation has that identifier'
      using errcode = '23503';
  end if;

  if v_t.deleted_at is null and v_t.status <> 'deleted'::erp.tenant_status then
    raise exception
      'CLOVEERP_NOTHING_TO_REINSTATE: % is %, and nothing has asked for it to be removed',
      v_t.code, v_t.status::text
      using errcode = '23514';
  end if;

  update erp.tenant
     set status       = p_status::erp.tenant_status,
         deleted_at   = null,
         suspended_at = case when p_status = 'suspended'
                             then coalesce(suspended_at, now()) else null end,
         updated_at   = now()
   where id = p_tenant_id;

  perform erp_meta.platform_log(v, 'platform.tenant_reinstated', p_tenant_id,
                                v_t.code, p_reason,
                                jsonb_build_object('from', v_t.status::text,
                                                   'to', p_status,
                                                   'was_marked_at', v_t.deleted_at));

  return jsonb_build_object('id', p_tenant_id, 'code', v_t.code,
                            'status', p_status, 'reinstated', true);
end;
$$;

comment on function public.erp_platform_reinstate_tenant is
  'Undoes marking an organisation as ended: clears the deletion marker, puts it '
  'back to paused or trading, demands a reason and records the reinstatement in '
  'its own right. Administrator rank, the same as marking it ended. Once the '
  'sweep has purged an organisation there is nothing for this to bring back.';

select erp.register_refusal('CLOVEERP_NOTHING_TO_REINSTATE',
  'Bringing back an organisation that was never on its way out.',
  'Reinstating exists to undo a deletion that has not happened yet. An organisation that is trading, or that is only paused, has nothing to undo, and treating it as though it did would write a record saying it came back from somewhere it never went.',
  'Look at the organisation on the Organisations screen. If it is paused and should be trading, reactivate it. If it should be ended, mark it ended first.');

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_reinstate_tenant', 'erp_meta.require_platform',
   'Takes the deletion marker off an organisation and puts it back to paused or '
   'trading. Gated on the platform staff list at administrator rank, the same '
   'rank that marks one ended, because the rank for an act is the rank for '
   'undoing it. Demands a reason, refuses an organisation that was never marked, '
   'and records the reinstatement so the trail reads as a reversal rather than '
   'as somebody editing a status.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_reinstate_tenant',
   'Writes erp.tenant from above every tenant, where no tenant context could '
   'scope it, and appends to the platform audit trail that no tenant owns. The '
   'caller stays authenticated and is checked against the platform staff list on '
   'the first line.')
on conflict (schema_name, function_name) do update
  set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The register, and the assertion that holds it to the routines
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.platform_door_rank (
  schema_name   text not null,
  function_name text not null,
  minimum_role  text not null
    check (minimum_role in ('owner', 'administrator')),
  why           text not null,
  primary key (schema_name, function_name, minimum_role)
);

comment on table erp_meta.platform_door_rank is
  'Which rank each reserved platform door demands, recorded as data so it can be '
  'compared with what the routines actually ask for. Only the reserved ranks — '
  'administrator and owner — are held here: operator and support are the floor, '
  'and a door cannot drift below them.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_meta', 'platform_door_rank', 'platform_internal',
   'What the platform''s own doors demand of the platform''s own staff. Belongs '
   'to no tenant, so a tenant filter on it would be meaningless.')
on conflict do nothing;

insert into erp_meta.attribution_exemption (schema_name, table_name, rationale) values
  ('erp_meta', 'platform_door_rank',
   'A register of what the build expects, written by migrations. Principal '
   'attribution is tenant-scoped and this row is not about a tenant principal.')
on conflict do nothing;

insert into erp_meta.platform_door_rank (schema_name, function_name, minimum_role, why) values
  ('public', 'erp_platform_add_staff', 'owner',
   'Decides who works on the platform. An administrator runs it and does not choose who else does.'),
  ('public', 'erp_platform_revoke_staff', 'owner',
   'Takes somebody off the platform staff list, which is the same decision in reverse.'),
  ('public', 'erp_platform_set_staff_role', 'owner',
   'Moves somebody between ranks, including into the rank that could then move anybody.'),
  ('public', 'erp_platform_offer_ownership', 'owner',
   'Offers a company to another owner. Who a company belongs to is the owner''s to settle.'),
  ('public', 'erp_platform_respond_ownership_transfer', 'owner',
   'Accepts or declines a company. Only an owner can be offered one, so only an owner can answer.'),
  ('public', 'erp_platform_cancel_ownership_transfer', 'owner',
   'Withdraws an open offer, which is the offering decision taken back.'),
  ('public', 'erp_platform_purge_tenant', 'owner',
   'Removes an organisation and everything in it. There is no undo, which is the whole reason it is here.'),
  ('public', 'erp_platform_purge_due_tenants', 'owner',
   'The same removal in bulk, for every organisation past its wait. Also no undo.'),
  ('public', 'erp_platform_set_billing_contact', 'administrator',
   'Says where a contract''s invoices are sent. Running the platform''s billing is running the platform.'),
  ('public', 'erp_platform_set_billing_details', 'administrator',
   'The platform''s own payment details on the invoices it issues.'),
  ('public', 'erp_platform_set_self_service_organisations', 'administrator',
   'Whether companies may sign themselves up. A setting about how the platform is run.'),
  ('public', 'erp_platform_erase_enquiry', 'administrator',
   'Erases one website enquiry on request. It removes a row, and it is one row somebody asked to have removed.'),
  ('public', 'erp_platform_set_tenant_status', 'administrator',
   'Marks an organisation ended, which is reversible and removes nothing. The door''s other arm, for pausing and reactivating, stays with the operator and is not reserved.'),
  ('public', 'erp_platform_reinstate_tenant', 'administrator',
   'Undoes marking an organisation ended. The rank for an act is the rank for undoing it.'),
  ('erp', 'designate_platform_organisation', 'administrator',
   'Names which organisation is the platform''s own. Part of running the platform, not of owning it.'),
  -- Landed on main from 20260920500000 while this was being written, at owner,
  -- and it is recorded where it is rather than where it might belong. It sits
  -- oddly beside erase_enquiry, which moved down: setting the address enquiries
  -- are sent to is running the platform, and erasing one is the more final act
  -- of the two. Moving it is a decision about the platform and not a tidy-up,
  -- so it is asked rather than taken.
  ('public', 'erp_platform_set_enquiry_notify_to', 'owner',
   'Sets the address website enquiries are sent to. Recorded at the rank it was written with.')
on conflict (schema_name, function_name, minimum_role) do update
  set why = excluded.why;

create or replace function erp.platform_door_rank_report()
returns table(routine text, rank_expected text, rank_found text, finding text)
language sql
stable
set search_path = ''
as $$
  with code as (
    -- Comments are part of prosrc, and a comment that quotes the gate is not a
    -- gate. Strip them before reading anything.
    select n.nspname as schema_name, p.proname as function_name,
           regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') as src
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'public')
       -- Procedures too: there is one in the repository today and it is a
       -- test, but a gate is a gate and the register must not depend on which
       -- kind of routine somebody reaches for next.
       and p.prokind in ('f', 'p')
       and p.proname <> 'require_platform'
       and p.proname not like 'assert\_%'
       and p.proname not like '%\_suite'
       and p.prosrc like '%require_platform(%'
  ),
  -- One row per call. The argument may be a literal or a case expression, so
  -- the call is captured whole and the ranks read out of it afterwards.
  calls as (
    select c.schema_name, c.function_name, m[1] as argument
      from code c
      cross join lateral
        regexp_matches(c.src, 'require_platform[[:space:]]*\(([^()]*)\)', 'g') m
  ),
  found as (
    select distinct k.schema_name, k.function_name, r[1] as minimum_role
      from calls k
      cross join lateral regexp_matches(k.argument, '''(owner|administrator)''', 'g') r
  ),
  expected as (
    select d.schema_name, d.function_name, d.minimum_role
      from erp_meta.platform_door_rank d
  ),
  joined as (
    select coalesce(e.schema_name, f.schema_name)     as schema_name,
           coalesce(e.function_name, f.function_name) as function_name,
           e.minimum_role as expected_role,
           f.minimum_role as found_role
      from expected e
      full outer join found f
        on f.schema_name = e.schema_name
       and f.function_name = e.function_name
       and f.minimum_role = e.minimum_role
  )
  select j.schema_name || '.' || j.function_name,
         coalesce(j.expected_role, ''),
         coalesce(j.found_role, ''),
         case
           when j.found_role is null
            and not exists (select 1 from pg_catalog.pg_proc p
                            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                           where n.nspname = j.schema_name and p.proname = j.function_name)
             then 'the register reserves a routine that is not there any more'
           when j.found_role is null
             then 'the register reserves this door and its body does not ask for that rank'
           when j.expected_role is null
             then 'the body asks for a reserved rank and the register does not say so'
         end
    from joined j
   where j.expected_role is null or j.found_role is null
   order by 1, 2, 3;
$$;

comment on function erp.platform_door_rank_report is
  'Compares what each reserved platform door demands, read out of its own '
  'source, with what erp_meta.platform_door_rank says it demands. Reports a '
  'mismatch in either direction: a reserved door that has drifted, and a door '
  'that reserved itself without the register being told.';

create or replace function erp.assert_platform_door_ranks()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
begin
  select count(*), string_agg(format('  %s — expected %s, found %s: %s',
                                     r.routine,
                                     nullif(r.rank_expected, ''),
                                     nullif(r.rank_found, ''),
                                     r.finding), E'\n' order by r.routine)
    into v_count, v_findings
    from erp.platform_door_rank_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_PLATFORM_DOOR_RANK_DRIFTED: % finding(s)\n%',
      v_count, v_findings
      using errcode = '23514',
            hint = 'A platform door reserved to administrator or owner no longer asks for '
                   'the rank the register records, or a door started asking for a reserved '
                   'rank without a row. Move the gate back, or record the change on purpose.';
  end if;

  return format('platform door ranks: %s reserved door(s) agree with their gates',
                (select count(*) from erp_meta.platform_door_rank));
end;
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('platform_door_ranks', 'Reserved platform doors still ask for the rank they were given',
   'assertion', 'platform', 'erp', 'assert_platform_door_ranks', '',
   'platform_door_rank_report', '',
   'Fourteen separate gates decide what the platform''s own staff may do, and nothing rechecked them. Each reserved door''s rank is recorded, and a body that stops asking for it — or starts asking for one nobody recorded — is refused.',
   true, 910)
on conflict (code) do update set
  title = excluded.title, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three organisations and four people, one at each rank. It is not run from
-- this file: the sweep case really purges, the billing cases really write the
-- platform's singleton rows, and a deploy against three organisations and a
-- year of trading is not where either belongs. erp.ci_check_catalogue() picks
-- the wrapper up by name on every build, and section 8 asserts that it does.

create or replace function erp_test.platform_administrator_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_owner  constant uuid := '00000000-0000-4000-8000-00000000ad01';
  c_admin  constant uuid := '00000000-0000-4000-8000-00000000ad02';
  c_oper   constant uuid := '00000000-0000-4000-8000-00000000ad03';
  c_supp   constant uuid := '00000000-0000-4000-8000-00000000ad04';
  v_cases  integer := 0;
  v_err    text;
  v_msg    text;
  v_msg2   text;
  v_ok     boolean;
  v_ok2    boolean;
  v_ta     record;
  v_tb     record;
  v_tc     record;
  v_admin  uuid;
  v_others uuid[];
  res      jsonb;
begin
  begin
    select * into v_ta from erp.provision_tenant(
      'zzrank-a', 'Rank A', 'admin-a@zzrank.test', 'Rank A Admin');
    select * into v_tb from erp.provision_tenant(
      'zzrank-b', 'Rank B', 'admin-b@zzrank.test', 'Rank B Admin');
    select * into v_tc from erp.provision_tenant(
      'zzrank-c', 'Rank C', 'admin-c@zzrank.test', 'Rank C Admin');

    insert into auth.users (id, email) values
      (c_owner, 'owner@zzrank.test'), (c_admin, 'administrator@zzrank.test'),
      (c_oper,  'operator@zzrank.test'), (c_supp, 'support@zzrank.test');

    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@zzrank.test',         c_owner, 'Rank Owner',         'owner'),
           ('administrator@zzrank.test', c_admin, 'Rank Administrator', 'administrator'),
           ('operator@zzrank.test',      c_oper,  'Rank Operator',      'operator'),
           ('support@zzrank.test',       c_supp,  'Rank Support',       'support');

    select s.id into v_admin from erp_meta.platform_staff s
     where s.email = 'administrator@zzrank.test';

    -- ── 1. The pivot puts the ranks in the stated order ─────────────────────
    v_cases := v_cases + 1;
    case_name := 'the four ranks stand in the order the platform states, and anything else is not a rank';
    passed := erp_meta.platform_rank('owner') = 4
          and erp_meta.platform_rank('administrator') = 3
          and erp_meta.platform_rank('operator') = 2
          and erp_meta.platform_rank('support') = 1
          and erp_meta.platform_rank('emperor') = 0;
    detail := format('owner %s, administrator %s, operator %s, support %s, and a word that is none of them %s',
                     erp_meta.platform_rank('owner'), erp_meta.platform_rank('administrator'),
                     erp_meta.platform_rank('operator'), erp_meta.platform_rank('support'),
                     erp_meta.platform_rank('emperor'));
    return next;

    perform set_config('request.jwt.claims', json_build_object('sub', c_admin)::text, true);

    -- ── 2. An administrator sets the platform's own payment details ─────────
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      res := public.erp_platform_set_billing_details(
        'Rank Suite Ltd', '1 Test Street', '00000000', 'Rank Suite Ltd',
        '01-02-03', '12345678', 'Quote the reference');
      v_ok := coalesce((res ->> 'set')::boolean, false);
      v_msg := coalesce(res ->> 'legal_name', 'nothing came back');
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'an administrator sets the platform''s own payment details';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 3. And marks a company ended ────────────────────────────────────────
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_set_tenant_status(
        v_ta.tenant_id, 'deleted', 'suite: an administrator ends a company');
      select t.status::text = 'deleted' and t.deleted_at is not null
        into v_ok from erp.tenant t where t.id = v_ta.tenant_id;
      v_msg := 'marked ended, and the marker is on it';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'and marks a company ended, which is reversible and removes nothing';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 4 to 11. Each reserved door refused by name ─────────────────────────
    -- Eight doors, eight cases, so a failure says which one let the
    -- administrator through rather than that something did.
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_add_staff('intruder@zzrank.test', 'Intruder', 'operator');
      v_msg := 'an administrator added platform staff';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'an administrator may not add platform staff';
    passed := coalesce(v_ok, false)
          and not exists (select 1 from erp_meta.platform_staff s
                           where s.email = 'intruder@zzrank.test');
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_set_staff_role(
        (select s.id from erp_meta.platform_staff s where s.email = 'operator@zzrank.test'),
        'owner');
      v_msg := 'an administrator changed somebody''s rank';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'nor change anybody''s rank';
    passed := coalesce(v_ok, false)
          and (select s.staff_role from erp_meta.platform_staff s
                where s.email = 'operator@zzrank.test') = 'operator';
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_revoke_staff(
        (select s.id from erp_meta.platform_staff s where s.email = 'support@zzrank.test'),
        'suite: an administrator tries to revoke');
      v_msg := 'an administrator took somebody off the staff list';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'nor take anybody off the staff list';
    passed := coalesce(v_ok, false)
          and (select s.revoked_at is null from erp_meta.platform_staff s
                where s.email = 'support@zzrank.test');
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_offer_ownership(
        v_tb.tenant_id,
        (select s.id from erp_meta.platform_staff s where s.email = 'owner@zzrank.test'),
        'suite: an administrator tries to hand a company on');
      v_msg := 'an administrator offered a company to somebody';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'nor offer a company to another owner';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_respond_ownership_transfer(
        gen_random_uuid(), true, 'suite: an administrator tries to answer an offer');
      v_msg := 'an administrator answered an offer';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    -- The identifier is invented on purpose: the gate is the first line, so a
    -- refusal about the rank proves the rank was read before anything else.
    case_name := 'nor answer one, and the rank is read before the offer is even looked for';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_cancel_ownership_transfer(
        gen_random_uuid(), 'suite: an administrator tries to withdraw an offer');
      v_msg := 'an administrator withdrew an offer';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'nor withdraw one';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_purge_tenant(
        v_ta.tenant_id, 'zzrank-a', 'suite: an administrator tries to purge');
      v_msg := 'an administrator purged a company';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'and may not purge a company, which is the one act with no undo';
    passed := coalesce(v_ok, false)
          and exists (select 1 from erp.tenant t where t.id = v_ta.tenant_id);
    detail := coalesce(v_msg, 'nothing');
    return next;

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_purge_due_tenants(7);
      v_msg := 'an administrator ran the deletion sweep';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'nor run the sweep that purges in bulk';
    passed := coalesce(v_ok, false)
          and exists (select 1 from erp.tenant t where t.id = v_tc.tenant_id);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 12. Everything an operator and a support member may do ──────────────
    -- The gate is the first line of every one of those doors, so passing it at
    -- both ranks is passing all of them. A real door is called as well, and the
    -- one chosen is the shared door's operator arm — the arm that did not move.
    v_cases := v_cases + 1;
    v_ok := false; v_ok2 := false; v_msg := null;
    begin
      perform erp_meta.require_platform('operator');
      perform erp_meta.require_platform('support');
      perform erp_meta.require_platform('administrator');
      v_ok := true;
      perform public.erp_platform_set_tenant_status(
        v_tb.tenant_id, 'suspended', 'suite: the operator arm of a shared door');
      select t.status::text = 'suspended' into v_ok2
        from erp.tenant t where t.id = v_tb.tenant_id;
      v_ok2 := coalesce(v_ok2, false)
           and jsonb_typeof(public.erp_platform_staff()) = 'array';
      v_msg := 'the gate admitted the administrator at operator, support and its own rank';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'an administrator passes every operator and support door, and the operator arm of the shared one';
    passed := coalesce(v_ok, false) and coalesce(v_ok2, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 13. Reinstating takes the marker off ────────────────────────────────
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      res := public.erp_platform_reinstate_tenant(
        v_ta.tenant_id, 'suite: it was ended by mistake', 'active');
      select coalesce((res ->> 'reinstated')::boolean, false)
             and t.deleted_at is null
             and t.status::text = 'active'
        into v_ok
        from erp.tenant t where t.id = v_ta.tenant_id;
      v_ok := coalesce(v_ok, false)
          and exists (select 1 from erp_meta.platform_audit a
                       where a.tenant_id = v_ta.tenant_id
                         and a.action = 'platform.tenant_reinstated');
      v_msg := 'brought back, the marker is off, and the trail says it was brought back';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'an administrator brings a company back, and the deletion marker goes with it';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 14. So the sweep no longer matches it, and still matches a real one ─
    -- Pausing it is what would have taken it before: the marker survived being
    -- reinstated, and the sweep reads the marker rather than the status. The
    -- third company is the control — ended a month ago and never brought back,
    -- so a sweep that takes nothing has proved nothing.
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_set_tenant_status(
        v_ta.tenant_id, 'suspended', 'suite: paused again, long afterwards');

      update erp.tenant
         set status = 'deleted'::erp.tenant_status, deleted_at = now() - interval '30 days'
       where id = v_tc.tenant_id;

      perform set_config('request.jwt.claims', json_build_object('sub', c_owner)::text, true);
      perform public.erp_platform_purge_due_tenants(7);
      perform set_config('request.jwt.claims', json_build_object('sub', c_admin)::text, true);

      v_ok := exists (select 1 from erp.tenant t where t.id = v_ta.tenant_id)
          and not exists (select 1 from erp.tenant t where t.id = v_tc.tenant_id);
      v_msg := 'the one that was brought back stayed; the one that was not is gone';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'and the sweep no longer matches it, however long it is paused for afterwards';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 15. Reinstating something that was never ended is refused ───────────
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_reinstate_tenant(
        v_tb.tenant_id, 'suite: nothing to undo here', 'active');
      v_msg := 'a company that was never ended was brought back';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_NOTHING_TO_REINSTATE%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'a company that was never on its way out has nothing to bring back';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 16. The sweep keeps its own waiting period ──────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', c_owner)::text, true);

    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_purge_due_tenants(0);
      v_msg := 'the sweep ran with no wait at all';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_PURGE_GRACE_TOO_SHORT%'; v_msg := left(sqlerrm, 120);
    end;
    case_name := 'even an owner may not run the sweep with a shorter wait than the platform keeps';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 17. An owner does everything an administrator can ───────────────────
    -- The requirement the owner stated, proved rather than left to hold by
    -- construction: every act that moved down to administrator is performed by
    -- an owner, here, in one case.
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      perform public.erp_platform_set_billing_details(
        'Rank Suite Ltd', '2 Test Street', '00000000', 'Rank Suite Ltd',
        '04-05-06', '87654321', 'Quote the reference');
      perform public.erp_platform_set_self_service_organisations(
        false, 'suite: an owner does an administrator''s work');
      perform public.erp_platform_set_tenant_status(
        v_tb.tenant_id, 'deleted', 'suite: an owner ends a company');
      res := public.erp_platform_reinstate_tenant(
        v_tb.tenant_id, 'suite: and brings it back', 'suspended');
      v_ok := coalesce((res ->> 'reinstated')::boolean, false);
      v_msg := 'payment details, self-service sign-up, marking ended and bringing back';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'an owner passes everything an administrator can do';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 18. The last owner still cannot be demoted ──────────────────────────
    -- The guard counts owners across the whole platform, so the case makes the
    -- fixture's owner the last one by standing every other owner down for the
    -- length of it, and puts them straight back. Rolled back either way.
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      select coalesce(array_agg(s.id), '{}'::uuid[]) into v_others
        from erp_meta.platform_staff s
       where s.staff_role = 'owner' and s.revoked_at is null
         and s.email <> 'owner@zzrank.test';
      update erp_meta.platform_staff set revoked_at = now() where id = any(v_others);

      begin
        perform public.erp_platform_set_staff_role(
          (select s.id from erp_meta.platform_staff s where s.email = 'owner@zzrank.test'),
          'administrator');
        v_msg := 'the last owner became an administrator';
      exception when others then
        v_ok := sqlerrm like 'CLOVEERP_LAST_OWNER%'; v_msg := left(sqlerrm, 120);
      end;

      update erp_meta.platform_staff set revoked_at = null where id = any(v_others);
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'the last owner still cannot be demoted, and the new rank is not a way round it';
    passed := coalesce(v_ok, false)
          and (select s.staff_role from erp_meta.platform_staff s
                where s.email = 'owner@zzrank.test') = 'owner';
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 19. The ordering puts owner above administrator ─────────────────────
    -- Read by position rather than by index, so the case says what it means on
    -- a platform that has other staff on it too.
    v_cases := v_cases + 1;
    v_ok := false; v_msg := null;
    begin
      select (select min(e.ord) from jsonb_array_elements(s.j) with ordinality e(v, ord)
               where e.v ->> 'email' = 'owner@zzrank.test')
           < (select min(e.ord) from jsonb_array_elements(s.j) with ordinality e(v, ord)
               where e.v ->> 'email' = 'administrator@zzrank.test')
        into v_ok
        from (select public.erp_platform_staff() as j) s;
      v_msg := 'the staff list is ordered by rank, highest first';
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'the staff list still sorts owner above administrator';
    passed := coalesce(v_ok, false);
    detail := coalesce(v_msg, 'nothing');
    return next;

    -- ── 20. The falsification ───────────────────────────────────────────────
    -- Every refusal above rests on administrator ranking below owner. Put the
    -- same person at owner rank and the refusal must go; put them back and it
    -- must return. A suite whose refusals survive that is refusing for some
    -- other reason and has proved nothing about the rank.
    v_cases := v_cases + 1;
    v_ok := false; v_ok2 := false; v_msg := null; v_msg2 := null;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', c_admin)::text, true);

      update erp_meta.platform_staff set staff_role = 'owner' where id = v_admin;
      begin
        perform public.erp_platform_add_staff('proof@zzrank.test', 'Proof', 'support');
        v_ok := true; v_msg := 'at owner rank the same call went through';
      exception when others then v_msg := left(sqlerrm, 120);
      end;

      update erp_meta.platform_staff set staff_role = 'administrator' where id = v_admin;
      delete from erp_meta.platform_staff s where s.email = 'proof@zzrank.test';

      begin
        perform public.erp_platform_add_staff('proof-again@zzrank.test', 'Proof', 'support');
        v_msg2 := 'the refusal did not come back';
      exception when others then
        v_ok2 := sqlerrm like 'CLOVEERP_PLATFORM_ROLE_TOO_LOW%'; v_msg2 := left(sqlerrm, 120);
      end;
    exception when others then v_msg := left(sqlerrm, 160);
    end;
    case_name := 'the refusals are the rank talking: at owner rank they go, at administrator rank they come back';
    passed := coalesce(v_ok, false) and coalesce(v_ok2, false);
    detail := format('%s; %s', coalesce(v_msg, 'nothing'), coalesce(v_msg2, 'nothing'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_err := left(sqlerrm, 300);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 21. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant t where t.code like 'zzrank-%')
        and not exists (select 1 from erp_meta.platform_staff s
                         where s.email like '%@zzrank.test')
        and not exists (select 1 from auth.users u
                         where u.id in (c_owner, c_admin, c_oper, c_supp));
  detail := coalesce(v_err,
              'three organisations, four staff rows and four fabricated subjects rolled back');
  return next;

  if v_cases <> 21 then
    raise exception 'CLOVEERP_SUITE_SHRANK: platform_administrator_suite ran % cases, expected 21 (%)',
      v_cases, coalesce(v_err, 'the fixture caught nothing');
  end if;
end;
$$;

revoke all on function erp_test.platform_administrator_suite() from public, anon;

create or replace function erp_test.assert_platform_administrator_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_expected constant integer := 21;
  v_all    integer;
  v_fail   integer;
  v_detail text;
begin
  create temp table if not exists _platform_administrator on commit drop as
    select * from erp_test.platform_administrator_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _platform_administrator;
  drop table _platform_administrator;

  if v_all <> c_expected then
    -- The failing cases come with the count: a fixture that fell over returns
    -- its cases failed rather than missing, and the reason is in them.
    raise exception E'CLOVEERP_PLATFORM_ADMINISTRATOR_SUITE_SHRANK: % case(s), expected %\n%',
      v_all, c_expected,
      coalesce(v_detail, '  every case passed; the count itself moved')
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PLATFORM_ADMINISTRATOR_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'The administrator rank reaches something reserved to the owner, '
                   'or is refused something it is meant to hold.';
  end if;
  return format('platform administrator: %s/%s cases passed', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_platform_administrator_suite()
  from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The build runs the suite, so the deploy does not have to
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Said the way 20260920310000 says it, and for the reason that file records. The
-- suite here purges an organisation to prove the sweep still works, writes the
-- platform's own payment details, and closes self-service sign-up. On a build
-- from an empty database those touch three fabricated companies. On a deploy
-- they would run against every organisation the platform has, inside one
-- statement, under a timeout. So this file does not run it, and asserts instead
-- that something else does.

do $covered$
declare
  v_suite    constant text := 'platform_administrator_suite';
  v_check    constant text := 'assert_platform_administrator_suite';
  v_expected constant integer := 21;
  v_call text;
  v_body text;
  v_wrap text;
begin
  select c.call into v_call
    from erp.ci_check_catalogue() c
   where c.schema_name = 'erp_test' and c.function_name = v_check;

  if v_call is null then
    raise exception
      'CLOVEERP_SUITE_NOT_IN_CATALOGUE: erp_test.%() is not in erp.ci_check_catalogue(), so nothing runs it', v_check
      using errcode = '23503',
            hint = 'The catalogue gathers assert_% routines in erp and erp_test that take no arguments.';
  end if;

  v_body := pg_get_functiondef(('erp_test.' || v_suite || '()')::regprocedure);
  v_wrap := pg_get_functiondef(('erp_test.' || v_check || '()')::regprocedure);

  if position('v_cases <> ' || v_expected in v_body) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold itself to % cases', v_suite, v_expected
      using errcode = '23514',
            hint = 'A suite that loses a case reports success. Pin the count inside the suite.';
  end if;

  if position('v_all <> ' || v_expected in v_wrap) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold the suite to % cases', v_check, v_expected
      using errcode = '23514',
            hint = 'The wrapper counts the rows the suite returned. Pin the same number there.';
  end if;

  raise notice
    'the build runs erp_test.%() from the catalogue as "%", and both ends pin % cases',
    v_check, v_call, v_expected;
end
$covered$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ── Proved ───────────────────────────────────────────────────────────────────
--
-- Every one of these reads the schema and its registers. Their cost is the size
-- of the schema, not the size of anybody's ledger, so they are the same on a
-- build from an empty database as on a deploy against a year of trading — which
-- is the sentence a migration has to be able to write about whatever it runs at
-- the end. The new boundary assertion is one scan of the routines that mention
-- the gate at all, and it is here because a deploy that applied half of this
-- file is exactly when somebody should be told.

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_platform_door_ranks();
