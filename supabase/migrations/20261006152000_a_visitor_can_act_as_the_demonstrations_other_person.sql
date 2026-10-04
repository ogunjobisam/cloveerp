set lock_timeout = '30s';

-- =============================================================================
-- 20261006152000  A visitor to a demonstration can act as its other person
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-46). The two before
-- this give a demonstration a second person, Priya Shah of Finance, and make
-- the refused approval say "choose her under Act as". This is Act as.
--
-- Nothing is signed in or out, and no credential is typed. A visitor who may
-- give people roles in the demonstration chooses her in the account menu; the
-- choice is a row keyed by the visitor's own principal; and while it stands
-- erp.principal_context() answers her principal instead of theirs. So
-- erp.current_principal_id() names her, and with it everything that records
-- who did something (created_by, approved_by, the audit trail) and every
-- segregation check. The visitor proposes a payment run as themselves and
-- approves it as her, and she cannot approve a run she proposed.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_persona_choice: who each signed-in person of a
--      demonstration is acting as. Refused outside a demonstration by the
--      same trigger as the persona table. A table of its own rather than a
--      column on erp_meta.principal_preference, which is read on every
--      request: altering that would queue every sign-in behind the deploy.
--   B. erp.principal_context() reads the choice in the query it already
--      makes (one primary-key probe, nothing for anybody without a choice)
--      and answers the persona only where the organisation is a
--      demonstration that is not live, the persona is active and cannot sign
--      in, and the person who signed in is not set aside (below). The
--      support window is still decided on the person who signed in.
--   C. erp.signed_in_principal_id(): the person who signed in, whoever they
--      are acting as.
--   D. erp.is_platform_owner() is false while a persona is in force, so the
--      platform owner acting as her holds her permissions and no more.
--   E. erp.catch_up_demonstrations() acts as the administrator it chose and
--      never as a persona that administrator left chosen
--      (erp.persona_set_aside, transaction-local; it can only make somebody
--      act as themselves).
--   F. public.erp_act_as_persona(persona or null): authorises
--      administration.roles as the person who signed in (somebody who may
--      give her roles is no stronger by acting as her, and switching back
--      works while she, who lacks it, is chosen). The choice is written as
--      the person who signed in, so the audit trail says who switched.
--      Refusals CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION and
--      CLOVEERP_UNKNOWN_PERSONA.
--   G. public.erp_demonstration_personas(): who signed in, who they are
--      acting as, and whom they may act as.
--   H. The words the account menu and the banner say.
--   I. erp.personas_report() also finds a choice outside a demonstration.
--   J. erp_test.persona_switch_suite, nine cases.
--
-- On production: one quiet table is created; three functions on the sign-in
-- path are replaced (erp.principal_context, erp.is_platform_owner,
-- erp.catch_up_demonstrations). No row is written and no hot table altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Who each person is acting as
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists erp.demonstration_persona_choice (
  tenant_id   uuid not null references erp.tenant(id) on delete cascade,
  app_user_id uuid not null,
  persona_id  uuid,
  chosen_at   timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint demonstration_persona_choice_pkey primary key (tenant_id, app_user_id),
  constraint demonstration_persona_choice_user_fk foreign key (tenant_id, app_user_id)
    references erp.app_user(tenant_id, id) on delete cascade,
  constraint demonstration_persona_choice_persona_fk foreign key (tenant_id, persona_id)
    references erp.demonstration_persona(tenant_id, app_user_id) on delete set null (persona_id)
);

comment on table erp.demonstration_persona_choice is
  'Who each signed-in person of a demonstration is acting as (20261006152000, J-46). Read by '
  'erp.principal_context(); written by erp.act_as_persona(). Refused outside a demonstration.';
comment on column erp.demonstration_persona_choice.app_user_id is
  'The person who signed in and made the choice.';
comment on column erp.demonstration_persona_choice.persona_id is
  'The demonstration persona they act as; null when they act as themselves.';
comment on column erp.demonstration_persona_choice.chosen_at is
  'When they last chose.';

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp', 'demonstration_persona_choice', 'tenant_scoped',
   'Who a signed-in person of a demonstration is acting as; only in a demonstration.')
on conflict (schema_name, table_name) do nothing;

drop trigger if exists t_demonstration_persona_choice_only_in_demonstration on erp.demonstration_persona_choice;
create trigger t_demonstration_persona_choice_only_in_demonstration
  before insert or update on erp.demonstration_persona_choice
  for each row execute function erp.refuse_persona_outside_demonstration();

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Who is acting, answered where it always was
-- ─────────────────────────────────────────────────────────────────────────────

do $context$
declare
  v_sig  constant text := 'erp.principal_context()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_tenant    uuid;
begin
$o$;
  v_new1 constant text := $n$  v_tenant    uuid;
  v_persona   uuid;
begin
$n$;
  v_old2 constant text := $o$  select u.id, u.tenant_id
    into v_principal, v_tenant
    from erp.app_user u
    left join erp_meta.principal_preference p
      on p.auth_user_id = u.auth_user_id
   where u.auth_user_id = (select auth.uid())
$o$;
  v_new2 constant text := $n$  select u.id, u.tenant_id, c.persona_id
    into v_principal, v_tenant, v_persona
    from erp.app_user u
    left join erp_meta.principal_preference p
      on p.auth_user_id = u.auth_user_id
    -- A demonstration persona this person chose to act as (20261006152000):
    -- one primary-key probe, which finds nothing for anybody who never chose.
    left join erp.demonstration_persona_choice c
      on c.tenant_id = u.tenant_id and c.app_user_id = u.id
   where u.auth_user_id = (select auth.uid())
$n$;
  v_old3 constant text := $o$  principal_id := v_principal;
  tenant_id    := v_tenant;
  return next;
$o$;
  v_new3 constant text := $n$  -- Acting as the demonstration's other person (20261006152000, J-46). The
  -- window above was decided on the person who signed in. Only in a
  -- demonstration (its code, as erp.tenant_is_demonstration() reads it) that
  -- is not live, only as somebody active who cannot sign in, and never while
  -- the person who signed in is set aside to act as themselves
  -- (erp.act_as_persona, erp.catch_up_demonstrations). One statement, and
  -- only for somebody who chose.
  if v_persona is not null
     and coalesce(current_setting('erp.persona_set_aside', true), '') <> 'yes' then
    select dp.app_user_id into v_persona
      from erp.demonstration_persona dp
      join erp.app_user pu on pu.tenant_id = dp.tenant_id and pu.id = dp.app_user_id
      join erp.tenant t on t.id = dp.tenant_id
     where dp.tenant_id = v_tenant and dp.app_user_id = v_persona
       and t.code like 'demo-%'
       and pu.kind = 'person'::erp.principal_kind
       and pu.status = 'active'::erp.principal_status
       and pu.auth_user_id is null
       and not exists (select 1 from erp.environment e
                        where e.tenant_id = dp.tenant_id and e.is_self and e.is_live);
    if v_persona is not null then
      v_principal := v_persona;
    end if;
  end if;

  principal_id := v_principal;
  tenant_id    := v_tenant;
  return next;
$n$;
begin
  if strpos(v_src, '20261006152000') > 0 then
    raise notice '% already answers a demonstration persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'ef9dbea439ed3ba917ca41c92cdeee78' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006152000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$context$;

update erp_meta.security_definer_allowance
   set rationale = 'Breaks the RLS recursion on erp.app_user. Argument-free, returns only the caller''s own principal, '
                   'never consults the trust check. Reads the windows erp.support_access records for the principal it '
                   'resolves, and refuses one whose windows have all closed. In a demonstration, answers instead the '
                   'persona the signed-in person chose to act as (erp.demonstration_persona_choice, 20261006152000).'
 where schema_name = 'erp' and function_name = 'principal_context';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Who signed in, whoever they are acting as
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.signed_in_principal_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  -- The person who signed in (20261006152000): erp.current_principal_id()
  -- answers the persona they act as, and this answers them.
  select coalesce(
    (select c.app_user_id
       from erp.demonstration_persona_choice c
       join erp.app_user u on u.tenant_id = c.tenant_id and u.id = c.app_user_id
      where c.tenant_id = erp.current_tenant_id()
        and c.persona_id = erp.current_principal_id()
        and u.auth_user_id = (select auth.uid())),
    erp.current_principal_id())
$$;

revoke all on function erp.signed_in_principal_id() from public, anon;

comment on function erp.signed_in_principal_id() is
  'The person who signed in, whoever they are acting as in a demonstration (20261006152000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The platform owner's pass is not the persona's
-- ─────────────────────────────────────────────────────────────────────────────

do $owner$
declare
  v_sig  constant text := 'erp.is_platform_owner()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261006152000') > 0 then
    raise notice '% already sets the owner''s pass aside for a persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '2c8d4c7d69bbd9828d16c1c89a422b05' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006152000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  execute $f$
create or replace function erp.is_platform_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $b$
  -- The platform owner's pass (20261006152000): not while they act as a
  -- demonstration's persona, who holds what her roles give her and no more.
  -- Asked only of the owner, so nobody else pays for the probe.
  select case when erp_meta.is_platform_owner()
              then not exists (select 1 from erp.demonstration_persona dp
                                where dp.app_user_id = erp.current_principal_id())
              else false
         end
$b$;
$f$;
end
$owner$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The nightly catch-up acts as the administrator, never as a persona
-- ─────────────────────────────────────────────────────────────────────────────

do $catchup$
declare
  v_sig  constant text := 'erp.catch_up_demonstrations(text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);
$o$;
  v_new1 constant text := $n$      perform set_config('request.jwt.claims',
                         json_build_object('sub', v_admin)::text, true);
      -- As that administrator, and never as a demonstration persona they
      -- left chosen (20261006152000): the catch-up's work is its own.
      perform set_config('erp.persona_set_aside', 'yes', true);
$n$;
  v_old2 constant text := $o$  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  return v_out;
$o$;
  v_new2 constant text := $n$  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);
  perform set_config('erp.persona_set_aside', '', true);
  return v_out;
$n$;
begin
  if strpos(v_src, '20261006152000') > 0 then
    raise notice '% already sets a persona aside; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '0e6e4c983d02325df524402b2e621655' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006152000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$catchup$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Act as
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_UNKNOWN_PERSONA',
  'Acting as somebody who is not one of this demonstration''s people, or whose access was removed.',
  'Only the people a demonstration was given can be acted as, so the records name somebody who belongs to it.',
  'Choose one of the people under Act as in the account menu, or act as yourself.');

create or replace function erp.act_as_persona(p_persona_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_prev   text := coalesce(current_setting('erp.persona_set_aside', true), '');
  v_tenant uuid;
  v_self   uuid;
begin
  -- Act as a demonstration's other person, or as yourself again with null
  -- (20261006152000, J-46). Everything here is done as the person who signed
  -- in: the persona is set aside first, so the permission asked for is
  -- theirs and the audit trail names them as the one who switched.
  perform set_config('erp.persona_set_aside', 'yes', true);
  v_tenant := erp.require_tenant_id();
  if not erp.tenant_is_demonstration(v_tenant)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = v_tenant and e.is_self and e.is_live) then
    raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: this organisation is not a demonstration'
      using errcode = '42501',
            hint = 'Sign in as yourself. To show a step that needs two people, open a demonstration and choose Act as in the account menu.';
  end if;
  v_self := erp.current_principal_id();

  -- Somebody who may give people their roles may act as one of them; they
  -- are no stronger for it.
  perform erp.authorise('administration.roles', null, null, null, 'demonstration_persona', p_persona_id);

  if p_persona_id is not null
     and not exists (select 1 from erp.demonstration_persona dp
                       join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
                      where dp.tenant_id = v_tenant and dp.app_user_id = p_persona_id
                        and u.kind = 'person'::erp.principal_kind
                        and u.status = 'active'::erp.principal_status
                        and u.auth_user_id is null) then
    raise exception 'CLOVEERP_UNKNOWN_PERSONA: % is not somebody this demonstration can act as', p_persona_id
      using errcode = '23503',
            hint = 'Choose one of the people under Act as in the account menu, or act as yourself.';
  end if;

  insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
  values (v_tenant, v_self, p_persona_id, now())
  on conflict (tenant_id, app_user_id)
  do update set persona_id = excluded.persona_id, chosen_at = excluded.chosen_at;

  perform set_config('erp.persona_set_aside', v_prev, true);
  return public.erp_demonstration_personas();
end;
$$;

revoke all on function erp.act_as_persona(uuid) from public, anon;

comment on function erp.act_as_persona(uuid) is
  'Act as one of a demonstration''s people, or as yourself again with null (20261006152000, J-46). '
  'Authorises administration.roles as the person who signed in; refused outside a demonstration.';

create or replace function public.erp_act_as_persona(p_persona_id uuid)
returns jsonb
language sql
volatile
set search_path = ''
as $$ select erp.act_as_persona(p_persona_id) $$;

revoke all on function public.erp_act_as_persona(uuid) from public, anon;
grant execute on function public.erp_act_as_persona(uuid) to authenticated, service_role;

comment on function public.erp_act_as_persona(uuid) is
  'Act as one of a demonstration''s people, or as yourself with null (20261006152000). Authorises administration.roles.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_act_as_persona', 'erp.act_as_persona',
   'Records which of a demonstration''s people the signed-in person acts as, or that they act as themselves; '
   'authorises administration.roles as the person who signed in, and is refused outside a demonstration.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. Who signed in, who they act as, and whom they may
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_demonstration_personas()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The account menu's Act as, and the banner that says who is acting
  -- (20261006152000). Outside a demonstration nobody can be acted as, and
  -- the list is empty; it is offered only to somebody who may act.
  with ctx as (
    select erp.current_tenant_id() as tenant_id,
           erp.current_principal_id() as acting_id,
           erp.signed_in_principal_id() as self_id
  ), d as (
    select ctx.*, erp.tenant_is_demonstration(ctx.tenant_id) as is_demo from ctx
  )
  select jsonb_build_object(
    'is_demonstration', d.is_demo,
    'signed_in', (select jsonb_build_object('principal_id', u.id, 'display_name', u.display_name)
                    from erp.app_user u where u.tenant_id = d.tenant_id and u.id = d.self_id),
    'acting_as', case when d.acting_id is distinct from d.self_id then (
                   select jsonb_build_object('principal_id', u.id, 'display_name', u.display_name,
                                             'chosen_at', c.chosen_at)
                     from erp.app_user u
                     join erp.demonstration_persona_choice c
                       on c.tenant_id = u.tenant_id and c.app_user_id = d.self_id and c.persona_id = u.id
                    where u.tenant_id = d.tenant_id and u.id = d.acting_id) end,
    'personas', case when d.is_demo
                      and erp.has_permission('administration.roles', null, null, null, d.self_id) then coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'principal_id', u.id,
                            'code', dp.code,
                            'display_name', u.display_name,
                            'roles', coalesce((
                              select jsonb_agg(r.name order by r.name)
                                from erp.user_role ur
                                join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                                               and r.status = 'active'::erp.record_status
                               where ur.tenant_id = dp.tenant_id and ur.app_user_id = dp.app_user_id
                                 and ur.valid_from <= current_date
                                 and (ur.valid_to is null or ur.valid_to >= current_date)), '[]'::jsonb))
                          order by dp.code)
                     from erp.demonstration_persona dp
                     join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
                    where dp.tenant_id = d.tenant_id
                      and u.kind = 'person'::erp.principal_kind
                      and u.status = 'active'::erp.principal_status
                      and u.auth_user_id is null), '[]'::jsonb)
                 else '[]'::jsonb end)
    from d
$$;

revoke all on function public.erp_demonstration_personas() from public, anon;
grant execute on function public.erp_demonstration_personas() to authenticated, service_role;

comment on function public.erp_demonstration_personas() is
  'Who signed in, which of a demonstration''s people they are acting as, and whom they may act as '
  '(20261006152000). Empty outside a demonstration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The words the account menu and the banner say
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Acting as a demonstration''s other person (20261006152000).'
  from (values
    ('Act as'),
    ('Yourself'),
    ('For a step that needs a second person.'),
    ('Acting as'),
    ('What you do now is recorded as theirs.'),
    ('Back to yourself')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- I. A choice outside a demonstration is a finding too
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.personas_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Somebody to act as, or somebody acting, where nobody may be
  -- (20261006150000, 20261006152000).
  select 'a persona is held by an organisation that is not a demonstration, or is live',
         t.code, u.display_name
    from erp.demonstration_persona dp
    join erp.tenant t on t.id = dp.tenant_id
    join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
   where not erp.tenant_is_demonstration(dp.tenant_id)
      or exists (select 1 from erp.environment e
                  where e.tenant_id = dp.tenant_id and e.is_self and e.is_live)
  union all
  select 'a persona can sign in, or is not a person',
         t.code, u.display_name
    from erp.demonstration_persona dp
    join erp.tenant t on t.id = dp.tenant_id
    join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
   where u.auth_user_id is not null or u.kind <> 'person'::erp.principal_kind
  union all
  select 'somebody acts as another person in an organisation that is not a demonstration, or is live',
         t.code, u.display_name
    from erp.demonstration_persona_choice c
    join erp.tenant t on t.id = c.tenant_id
    join erp.app_user u on u.tenant_id = c.tenant_id and u.id = c.app_user_id
   where c.persona_id is not null
     and (not erp.tenant_is_demonstration(c.tenant_id)
          or exists (select 1 from erp.environment e
                      where e.tenant_id = c.tenant_id and e.is_self and e.is_live))
   order by 1, 2, 3
$$;

revoke all on function erp.personas_report() from public, anon;

comment on function erp.personas_report() is
  'Demonstration personas, and people acting as them, where none may be: outside a demonstration, in one '
  'that is live, or a persona who can sign in (20261006150000, 20261006152000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- J. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.persona_switch_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_priya  uuid;
  v_clerk  uuid;
  v_entity uuid; v_site uuid; v_uom uuid; v_item uuid; v_supp uuid;
  v_po uuid; v_pol uuid; v_grn uuid; v_grn2 uuid;
  v_run1 uuid; v_run2 uuid;
  v_sess   jsonb;
  v_who    jsonb;
  v_back   jsonb;
  v_perms  text[];
  v_want   text[];
  v_owner  boolean;
  v_err    text; v_err2 text; v_err3 text; v_hint text;
  v_a      uuid; v_b uuid; v_c uuid;
  v_src    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    -- A demonstration whose administrator is also the platform owner, a
    -- clerk who may not give roles, and two bills owed to a supplier.
    v_step := 'a demonstration, its owner-administrator, a clerk and two bills';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzps' || v_tag, 'Persona Switch Suite',
      'admin@demo-zzps' || v_tag || '.test', 'Switch Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzps' || v_tag || '.test'),
           (a2, 'clerk@demo-zzps' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('admin@demo-zzps' || v_tag || '.test', a1, 'Persona Switch Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select dp.app_user_id into v_priya from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id;
    res := public.erp_invite_principal('clerk@demo-zzps' || v_tag || '.test', 'Colin Clerk');
    v_clerk := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_clerk, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select e.id into v_entity from erp.entity e
     where e.tenant_id = rb.tenant_id and e.status = 'active' order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = rb.tenant_id and s.entity_id = v_entity order by s.code limit 1;
    select u.id into v_uom from erp.uom u where u.tenant_id = rb.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZPSCOAT', 'Switched Coat', v_uom, 'active') returning id into v_item;
    v_supp := erp_test.cash_payment_supplier('ZPSSUP');
    v_po := erp_test.prepayment_order(v_entity, v_site, v_item, v_supp, 20, 1000, 'ZPS1');
    select l.id into v_pol from erp.document_line l where l.document_id = v_po order by l.line_no limit 1;
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 10, null);
    perform erp.transition_document(v_grn, 'post', null);
    perform erp.bill_from_receipt(v_grn, 'ZPS-BILL-1', current_date, current_date + 30, true);

    -- ── 1. The visitor proposes a run and may not approve it ────────────────
    v_step := 'the visitor proposes a run and approves it';
    v_run1 := erp.propose_payment_run(current_date, null, interval '60 days');
    begin perform erp.approve_payment_run(v_run1); v_err := 'approved';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'the visitor proposes a run as themselves and approving it is refused, owner or not';
    passed := v_state is null
          and v_err like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
          and (select pp.created_by from erp.payment_proposal pp where pp.id = v_run1) = rb.admin_user_id
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run1) = 'proposed';
    detail := coalesce(v_state, v_err);
    return next;

    -- The second bill, owed after the first run was proposed.
    v_grn2 := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol, 10, null);
    perform erp.transition_document(v_grn2, 'post', null);
    perform erp.bill_from_receipt(v_grn2, 'ZPS-BILL-2', current_date, current_date + 30, true);

    -- ── 2. Acting as Priya, the visitor holds what she holds ────────────────
    v_step := 'choosing Priya under Act as, as the signed-in role';
    execute 'set local role authenticated';
    v_who := public.erp_act_as_persona(v_priya);
    v_sess := public.erp_session();
    v_owner := erp.is_platform_owner();
    execute 'reset role';
    select array_agg(x order by x) into v_perms from jsonb_array_elements_text(v_sess -> 'permissions') x;
    select array_agg(x order by x) into v_want from unnest(erp.standard_role_permissions('finance')) x;
    v_cases := v_cases + 1;
    case_name := 'acting as the persona, the session names her and holds only her Finance permissions, not the owner''s, and the menu says who signed in';
    passed := v_state is null
          and (v_sess ->> 'principal_id')::uuid = v_priya
          and v_sess #>> '{principal,display_name}' = 'Priya Shah'
          and v_perms = v_want
          and not v_owner
          and (v_who #>> '{acting_as,principal_id}')::uuid = v_priya
          and (v_who #>> '{signed_in,principal_id}')::uuid = rb.admin_user_id
          and jsonb_array_length(v_who -> 'personas') = 1;
    detail := coalesce(v_state, format('principal %s, permissions %s, owner %s, menu %s',
      v_sess ->> 'principal_id', array_to_string(v_perms, ','), v_owner, left(v_who::text, 200)));
    return next;

    -- ── 3. As Priya, the visitor's run is approved and paid ─────────────────
    v_step := 'approving and paying the visitor''s run as Priya';
    execute 'set local role authenticated';
    perform public.erp_approve_payment_run(v_run1);
    perform public.erp_pay_payment_run(v_run1);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'as the persona the visitor''s run is approved in her name and paid';
    passed := v_state is null
          and (select pp.approved_by from erp.payment_proposal pp where pp.id = v_run1) = v_priya
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run1) = 'paid';
    detail := coalesce(v_state, (select format('%s, approved by %s', pp.status, pp.approved_by)
                                   from erp.payment_proposal pp where pp.id = v_run1));
    return next;

    -- ── 4. Priya may not approve what Priya proposed ────────────────────────
    v_step := 'Priya proposes a run and approves it';
    v_run2 := erp.propose_payment_run(current_date, null, interval '60 days');
    v_err := null;
    begin perform erp.approve_payment_run(v_run2); v_err := 'approved';
    exception when others then get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint; end;
    v_cases := v_cases + 1;
    case_name := 'a run the persona proposed is refused when the persona approves it, and the refusal says to go back to yourself';
    passed := v_state is null
          and (select pp.created_by from erp.payment_proposal pp where pp.id = v_run2) = v_priya
          and v_err like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
          and v_hint like '%choose Yourself under Act as%'
          and (select pp.status from erp.payment_proposal pp where pp.id = v_run2) = 'proposed';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_hint));
    return next;

    -- ── 5. The audit trail names who did each thing ─────────────────────────
    v_step := 'reading the audit trail';
    v_cases := v_cases + 1;
    case_name := 'the approval is audited as the persona''s and the switch as the visitor''s';
    passed := v_state is null
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'payment_proposal'
                         and ae.object_id = v_run1 and ae.action = 'update'
                         and ae.after_state ->> 'status' = 'approved'
                         and ae.actor_id = v_priya)
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'demonstration_persona_choice'
                         and (ae.after_state ->> 'app_user_id')::uuid = rb.admin_user_id
                         and (ae.after_state ->> 'persona_id')::uuid = v_priya
                         and ae.actor_id = rb.admin_user_id)
          and not exists (select 1 from erp.audit_entry ae
                           where ae.tenant_id = rb.tenant_id and ae.object_type = 'demonstration_persona_choice'
                             and ae.actor_id = v_priya);
    detail := coalesce(v_state, 'audit read');
    return next;

    -- ── 6. Back to yourself ─────────────────────────────────────────────────
    v_step := 'going back to yourself, and approving Priya''s run';
    execute 'set local role authenticated';
    v_back := public.erp_act_as_persona(null);
    v_sess := public.erp_session();
    perform public.erp_approve_payment_run(v_run2);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'acting as yourself again while the persona is chosen puts the visitor back, and they may approve what she proposed';
    passed := v_state is null
          and (v_sess ->> 'principal_id')::uuid = rb.admin_user_id
          and v_back -> 'acting_as' = 'null'::jsonb
          and (select pp.approved_by from erp.payment_proposal pp where pp.id = v_run2) = rb.admin_user_id;
    detail := coalesce(v_state, format('principal %s, menu %s', v_sess ->> 'principal_id', left(v_back::text, 200)));
    return next;

    -- ── 7. Not by a clerk, and not as somebody unknown ──────────────────────
    v_step := 'a clerk choosing Priya, and the visitor choosing somebody unknown';
    v_err := null; v_err2 := null; v_err3 := null;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    execute 'set local role authenticated';
    begin perform public.erp_act_as_persona(v_priya); v_err := 'acting';
    exception when others then v_err := sqlerrm; end;
    v_a := erp.current_principal_id();
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin perform public.erp_act_as_persona(gen_random_uuid()); v_err2 := 'acting';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_act_as_persona(v_clerk); v_err3 := 'acting';
    exception when others then v_err3 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'somebody who may not give roles is refused, and so is acting as somebody who is not one of the demonstration''s people';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED%' and v_a = v_clerk
          and v_err2 like 'CLOVEERP_UNKNOWN_PERSONA%'
          and v_err3 like 'CLOVEERP_UNKNOWN_PERSONA%'
          and erp.current_principal_id() = rb.admin_user_id;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
    return next;

    -- ── 8. Set aside, or her access removed, the visitor is themselves ──────
    v_step := 'acting as Priya, then set aside, then with her access removed';
    perform public.erp_act_as_persona(v_priya);
    v_a := erp.current_principal_id();
    perform set_config('erp.persona_set_aside', 'yes', true);
    v_b := erp.current_principal_id();
    perform set_config('erp.persona_set_aside', '', true);
    update erp.app_user set status = 'disabled' where tenant_id = rb.tenant_id and id = v_priya;
    v_c := erp.current_principal_id();
    select p.prosrc into v_src from pg_catalog.pg_proc p
     where p.oid = 'erp.catch_up_demonstrations(text)'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'set aside, as the nightly catch-up sets it once it signs in as an administrator, or once the persona''s access is removed, the visitor resolves to themselves';
    passed := v_state is null
          and v_a = v_priya and v_b = rb.admin_user_id and v_c = rb.admin_user_id
          and strpos(v_src, $q$set_config('erp.persona_set_aside', 'yes', true)$q$)
              > strpos(v_src, $q$json_build_object('sub', v_admin)$q$)
          and strpos(v_src, $q$json_build_object('sub', v_admin)$q$) > 0;
    detail := coalesce(v_state, format('chosen %s, set aside %s, removed %s', v_a, v_b, v_c));
    return next;

    -- ── 9. Not in an ordinary organisation ──────────────────────────────────
    v_step := 'an organisation that is not a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzps-' || v_tag, 'Not A Demo Switch Suite', 'admin@zzps-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin@zzps-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_err := null; v_err2 := null;
    begin perform public.erp_act_as_persona(null); v_err := 'acting';
    exception when others then v_err := sqlerrm; end;
    begin
      insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id)
      values (rc.tenant_id, rc.admin_user_id, null);
      v_err2 := 'written';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'in an organisation that is not a demonstration Act as is refused, and a choice cannot be written';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
          and v_err2 like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
          and public.erp_demonstration_personas() -> 'personas' = '[]'::jsonb;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.persona_set_aside', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PERSONA_SWITCH_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.persona_switch_suite() from public, anon;

comment on function erp_test.persona_switch_suite() is
  'A visitor to a demonstration can act as its other person (20261006152000): propose as yourself, approve '
  'as her, never both as one; her permissions only, never the owner''s; each act audited as whoever did it; '
  'back to yourself; refused to a clerk, for an unknown person and outside a demonstration; set aside for the catch-up.';

create or replace function erp_test.assert_persona_switch_suite()
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
    from erp_test.persona_switch_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PERSONA_SWITCH_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Acting as a demonstration''s other person would either not work or let one person do both halves. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_PERSONA_SWITCH_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('persona switch: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_persona_switch_suite() from public, anon;

comment on function erp_test.assert_persona_switch_suite() is
  'A visitor to a demonstration acts as its other person without segregation of duties giving way (20261006152000).';

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
