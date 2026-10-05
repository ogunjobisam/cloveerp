set lock_timeout = '30s';

-- =============================================================================
-- 20261010030000  Act as is chosen in each browser tab
-- -----------------------------------------------------------------------------
-- Found in the live re-test, 5 October (DEFECTS D), and decided by the owner
-- the same day. A visitor to a demonstration chooses Priya Shah under Act as
-- (20261006152000). The choice was one row per signed-in person,
-- erp.demonstration_persona_choice, read by erp.principal_context() on every
-- request. So once a visitor chose her in one tab, every tab and every device
-- of that sign-in acted as Priya: a second tab opened to watch the approval
-- approved it too, and a phone left signed in did what she may do.
--
-- Now the tab holds the choice. The screen keeps it in the tab's own storage
-- and sends it with every request to the database as the header
-- x-clove-act-as, which PostgREST hands to SQL in request.headers.
-- erp.principal_context() answers the persona the header names, and only
-- while every rule 20261006152000 and 20261006153000 set still holds:
--
--   (a) she belongs to the signed-in person's organisation in context;
--   (b) that organisation is a demonstration (its address begins demo-)
--       and is not live;
--   (c) she is a person, active, and cannot sign in;
--   (d) the person who signed in holds administration.roles today, judged
--       as themselves;
--   and the person is not set aside to act as themselves
--   (erp.persona_set_aside: erp.act_as_persona, erp.catch_up_demonstrations,
--   erp.pay_demonstration_suppliers).
--
-- A header naming anything else, or not a person at all, or not even a
-- well-formed value, is ignored: the request is answered as the person who
-- signed in, never refused. A tab or device that sends no header is the
-- person, whatever another tab chose.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.principal_context() reads the persona from the request's header
--      instead of the account-wide row. The first query loses its join to
--      the row, so a request that names nobody costs no more than before
--      Act as existed; a request that names somebody costs one statement,
--      as before. The support window is still decided on the person who
--      signed in.
--   B. erp.signed_in_principal_id(): the signed-in person's own principal in
--      the organisation in context, read from the sign-in, not from the row.
--   C. erp.act_as_persona(persona or null) checks a choice as before (the
--      grant held as yourself, only in a demonstration, only somebody who
--      can be acted as; going back needs nothing and works anywhere), and
--      records the switch in the audit trail as the person who signed in.
--      It no longer writes a row: the tab keeps the choice. Its answer says
--      whom the tab now acts as.
--   D. public.erp_demonstration_personas() says whom this request acts as,
--      from the header, without reading the row.
--   E. erp.retire_demonstration_personas() no longer clears rows nobody
--      reads: a tab still naming a retired persona is answered as the
--      person.
--   F. erp.pay_demonstration_suppliers() names the other person the way a
--      tab does, for its approval and payment only, and puts the request's
--      headers back as they were.
--   G. erp.demonstration_persona_choice is retired: nothing reads or writes
--      it, its rows are removed, and erp.personas_report() reports any row
--      that names somebody. The table stays because dropping it would take
--      a lock on erp.app_user and erp.tenant, which every request reads.
--   H. erp_test.persona_switch_suite (9 cases), erp_test.persona_safety_suite
--      (6) and erp_test.demonstration_pays_suppliers_suite (8) act as the
--      tab does; erp_test.act_as_per_tab_suite, 11 cases, proves the rules
--      above case by case, a forged header included.
--
-- Kept: the platform owner's pass is not the persona's (erp.is_platform_owner
-- reads who acts, unchanged); the audit trail and the access log name who
-- acted as her (erp.persona_acted_by, unchanged, through B); segregation of
-- duties is the approval's own rule and is not touched.
--
-- On production: functions only, on the sign-in path among them
-- (erp.principal_context, erp.signed_in_principal_id). The rows of
-- erp.demonstration_persona_choice are deleted, in every organisation that
-- has one: only demonstrations, or organisations that stopped being one and
-- whose choice was already cleared, ever held a row. Whoever was acting as
-- Priya through the row is themselves on their next request, in every tab,
-- until they choose her again in a tab. No table is altered.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- The bodies this replaces, as they stand
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  r     record;
  v_src text;
begin
  for r in
    select * from (values
      ('erp.principal_context()',                   'd7d5c96c7c5521a7db068ffda98916f2'),
      ('erp.signed_in_principal_id()',              '5c4bf8ecd80ef0e70043f2748181e2ca'),
      ('erp.act_as_persona(uuid)',                  'b65a6c44f0e068b4fb83681bdfd55e03'),
      ('public.erp_demonstration_personas()',       'e4e5b262af711b0612652f8b995d51e4'),
      ('erp.retire_demonstration_personas(uuid)',   '883515ea777591ef2f1984ab993f7ffe'),
      ('erp.personas_report()',                     'cdf9bb2ac3b5abae64d9b6cebad57fb5'),
      ('erp_test.persona_switch_suite()',           'e9b3ff3886175ec1cbfe620c5519da77'),
      ('erp_test.persona_safety_suite()',           '723efab407429f0ce81eba3fc0bfbbfb')
    ) v(sig, want)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    if strpos(v_src, '20261010030000') = 0 and md5(v_src) <> r.want then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010030000 replaces (md5 %)', r.sig, md5(v_src);
    end if;
  end loop;
end
$guard$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Who is acting, from the request
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.principal_context()
returns table(principal_id uuid, tenant_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_principal uuid;
  v_tenant    uuid;
  v_persona   uuid;
  v_headers   text;
  v_named     text;
begin
  select u.id, u.tenant_id
    into v_principal, v_tenant
    from erp.app_user u
    left join erp_meta.principal_preference p
      on p.auth_user_id = u.auth_user_id
   where u.auth_user_id = (select auth.uid())
     and u.status = 'active'::erp.principal_status
   order by (p.active_tenant_id is not null and p.active_tenant_id = u.tenant_id) desc,
            u.created_at desc
   limit 1;

  if v_principal is null then
    return;
  end if;

  -- A support principal is in the organisation while a window is open, and
  -- not otherwise, whether it was chosen or reached by the newest-principal
  -- fallback. Outside triggers only: a trigger stamping who changed a row is
  -- not somebody arriving, and the console's own doors fire those triggers on
  -- the very principal they are closing or replacing.
  if pg_catalog.pg_trigger_depth() = 0
     and erp.support_window_closed(v_tenant, v_principal) then
    raise exception 'CLOVEERP_SUPPORT_WINDOW_CLOSED: the support window that let this sign-in into the organisation has closed'
      using errcode = '42501',
            hint = 'Enter the organisation again from the platform console, which opens a new support window and tells the organisation.';
  end if;

  -- Acting as the demonstration's other person (20261006152000, J-46), in the
  -- browser tab that chose her and nowhere else (20261010030000): the tab
  -- names her in the header x-clove-act-as, which PostgREST hands over in
  -- request.headers. The window above was decided on the person who signed
  -- in. Only in a demonstration (its code, as erp.tenant_is_demonstration()
  -- reads it) that is not live, only as somebody of that organisation who is
  -- active and cannot sign in, only while the person who signed in holds
  -- administration.roles as themselves, and never while they are set aside
  -- to act as themselves (erp.act_as_persona, erp.catch_up_demonstrations).
  -- A header naming anything else, or malformed, is not an error: the
  -- request is the person's. Nothing is read for a request that names
  -- nobody but a look for the key in the headers' text (cheaper, measured,
  -- than parsing them, and they carry the bearer token); the headers are
  -- parsed, and one statement made, only for a request that names somebody.
  v_headers := current_setting('request.headers', true);
  if v_headers like '%"x-clove-act-as"%'
     and coalesce(current_setting('erp.persona_set_aside', true), '') <> 'yes'
     and pg_catalog.pg_input_is_valid(v_headers, 'json') then
    v_named := (v_headers::json) ->> 'x-clove-act-as';
    if v_named is not null and pg_catalog.pg_input_is_valid(v_named, 'uuid') then
      v_persona := v_named::uuid;
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
                          where e.tenant_id = dp.tenant_id and e.is_self and e.is_live)
         -- Only while the person who signed in may still choose
         -- (20261006153000): their grant of administration.roles, judged as
         -- themselves. Losing it ends the act at once.
         and exists (select 1 from erp.user_role ur
                       join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                                      and r.status = 'active'::erp.record_status
                       join erp.role_permission rp on rp.tenant_id = ur.tenant_id and rp.role_id = r.id
                      where ur.tenant_id = dp.tenant_id and ur.app_user_id = v_principal
                        and rp.permission_code = 'administration.roles'
                        and ur.valid_from <= current_date
                        and (ur.valid_to is null or ur.valid_to >= current_date));
      if v_persona is not null then
        v_principal := v_persona;
      end if;
    end if;
  end if;

  principal_id := v_principal;
  tenant_id    := v_tenant;
  return next;
end;
$$;

comment on function erp.principal_context() is
  'Who is asking and for which organisation: the signed-in principal, or in a demonstration the persona the '
  'browser tab names in its x-clove-act-as header while every rule holds (20261006152000, 20261006153000, '
  '20261010030000). Refuses a support principal whose windows have closed.';

update erp_meta.security_definer_allowance
   set rationale = 'Breaks the RLS recursion on erp.app_user. Argument-free, returns only the caller''s own principal, '
                   'never consults the trust check. Reads the windows erp.support_access records for the principal it '
                   'resolves, and refuses one whose windows have all closed. In a demonstration, answers instead the '
                   'persona the request''s x-clove-act-as header names, only where she is of the caller''s organisation, '
                   'it is a demonstration not live, she cannot sign in and the caller holds administration.roles as '
                   'themselves; any other header is ignored (20261010030000).'
 where schema_name = 'erp' and function_name = 'principal_context';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Who signed in, whoever this tab acts as
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.signed_in_principal_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  -- The person who signed in (20261006152000): erp.current_principal_id()
  -- answers the persona their tab acts as, and this answers them, from the
  -- sign-in itself (20261010030000). A trusted job, which has no sign-in, is
  -- whoever it acts for.
  select coalesce(
    (select u.id
       from erp.app_user u
      where u.tenant_id = erp.current_tenant_id()
        and u.auth_user_id = (select auth.uid())
        and u.status = 'active'::erp.principal_status),
    erp.current_principal_id())
$$;

revoke all on function erp.signed_in_principal_id() from public, anon;

comment on function erp.signed_in_principal_id() is
  'The person who signed in, whoever their browser tab acts as in a demonstration (20261006152000, 20261010030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Act as: checked and recorded here, kept by the tab
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_was    uuid;
  v_kind   erp.principal_kind;
  v_label  text;
  v_name   text;
begin
  -- Act as a demonstration's other person, or as yourself again with null
  -- (20261006152000, J-46). The browser tab keeps the choice and names her on
  -- each request it makes (20261010030000); this checks the choice and
  -- records it. Everything here is done as the person who signed in: the
  -- persona is set aside first, so the permission asked for is theirs and the
  -- audit trail names them as the one who switched.
  v_was := erp.current_principal_id();
  perform set_config('erp.persona_set_aside', 'yes', true);
  v_tenant := erp.require_tenant_id();
  v_self := erp.current_principal_id();
  if v_was is not distinct from v_self then
    v_was := null;
  end if;

  -- Going back to yourself needs no permission and is refused nowhere
  -- (20261006153000): somebody whose roles were removed, or whose
  -- organisation stopped being a demonstration, can always stop.
  if p_persona_id is not null then
    if not erp.tenant_is_demonstration(v_tenant)
       or exists (select 1 from erp.environment e
                   where e.tenant_id = v_tenant and e.is_self and e.is_live) then
      raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: this organisation is not a demonstration'
        using errcode = '42501',
              hint = 'Sign in as yourself. To show a step that needs two people, open a demonstration and choose Act as in the account menu.';
    end if;

    -- Somebody who may give people their roles may act as one of them; they
    -- are no stronger for it. Held as themselves, as erp.principal_context()
    -- asks it while they act: a platform owner's pass is not the grant.
    perform erp.authorise('administration.roles', null, null, null, 'demonstration_persona', p_persona_id);
    if not erp.has_permission('administration.roles', null, null, null, v_self) then
      raise exception 'CLOVEERP_PERMISSION_DENIED: administration.roles'
        using errcode = '42501';
    end if;

    if not exists (select 1 from erp.demonstration_persona dp
                     join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
                    where dp.tenant_id = v_tenant and dp.app_user_id = p_persona_id
                      and u.kind = 'person'::erp.principal_kind
                      and u.status = 'active'::erp.principal_status
                      and u.auth_user_id is null) then
      raise exception 'CLOVEERP_UNKNOWN_PERSONA: % is not somebody this demonstration can act as', p_persona_id
        using errcode = '23503',
              hint = 'Choose one of the people under Act as in the account menu, or act as yourself.';
    end if;
  end if;

  -- The switch, in the audit trail, as the person who signed in. Nothing
  -- account-wide is written: another tab, or another device, stays as it is.
  select u.kind, u.display_name into v_kind, v_label
    from erp.app_user u where u.tenant_id = v_tenant and u.id = v_self;
  select u.display_name into v_name
    from erp.app_user u where u.tenant_id = v_tenant and u.id = coalesce(p_persona_id, v_was);
  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action, object_schema, object_type,
    object_id, object_key, after_state, reason, correlation_id, source)
  values (
    v_tenant, v_self, coalesce(v_kind, 'person'::erp.principal_kind), coalesce(v_label, 'unknown'), 'execute',
    'erp', 'demonstration_persona', coalesce(p_persona_id, v_was), v_name,
    jsonb_build_object('acting_as', p_persona_id, 'was', v_was, 'kept_by', 'this browser tab'),
    case when p_persona_id is null then 'acts as themselves again in this browser tab'
         else format('acts as %s in this browser tab', v_name) end,
    erp.current_correlation_id(), erp.current_source());

  perform set_config('erp.persona_set_aside', v_prev, true);
  -- Whom the tab acts as once it keeps this choice; this request still
  -- carries the tab's previous header.
  return public.erp_demonstration_personas()
         || jsonb_build_object('acting_as',
              case when p_persona_id is null then null
                   else jsonb_build_object('principal_id', p_persona_id, 'display_name', v_name) end);
end;
$$;

revoke all on function erp.act_as_persona(uuid) from public, anon;

comment on function erp.act_as_persona(uuid) is
  'Act as one of a demonstration''s people in this browser tab, or as yourself again with null (20261006152000, '
  'J-46, 20261010030000). Choosing somebody authorises administration.roles, held as the person who signed in, '
  'and only in a demonstration; going back needs nothing and works anywhere (20261006153000). Records the switch '
  'in the audit trail as the person who signed in; the tab keeps the choice and names her on its requests.';

update erp_meta.public_write_allowance
   set rationale = 'Records in the audit trail which of a demonstration''s people the signed-in person''s browser tab '
                   'acts as, or that it acts as them again; the tab keeps the choice (20261010030000). Choosing '
                   'somebody authorises administration.roles as the person who signed in, and is refused outside a '
                   'demonstration.'
 where function_name = 'erp_act_as_persona';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Whom this request acts as
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_demonstration_personas()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The account menu's Act as, and the banner that says who is acting
  -- (20261006152000). Whom this request acts as is whom the browser tab
  -- names, where erp.principal_context() allows it (20261010030000).
  -- Outside a demonstration nobody can be acted as, and the list is empty;
  -- it is offered only to somebody who may act.
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
                   select jsonb_build_object('principal_id', u.id, 'display_name', u.display_name)
                     from erp.app_user u
                     join erp.demonstration_persona dp
                       on dp.tenant_id = u.tenant_id and dp.app_user_id = u.id
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
  'Who signed in, which of a demonstration''s people this browser tab acts as, and whom they may act as '
  '(20261006152000, 20261010030000). Empty outside a demonstration.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Retiring a persona clears nothing nobody reads
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.retire_demonstration_personas(p_tenant_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer := 0;
begin
  -- An organisation that is no longer a demonstration (its address no longer
  -- demo-, or it went live) keeps nobody to act as (20261006153000): every
  -- persona row is removed and the persona disabled, in the statement that
  -- changed it. A tab that still names her is answered as the person who
  -- signed in (20261010030000). A definer, because the address may be
  -- changed from the platform console, outside the organisation's rows.
  if erp.tenant_is_demonstration(p_tenant_id)
     and not exists (select 1 from erp.environment e
                      where e.tenant_id = p_tenant_id and e.is_self and e.is_live) then
    return 0;
  end if;

  with gone as (
    delete from erp.demonstration_persona dp
     where dp.tenant_id = p_tenant_id
    returning dp.app_user_id)
  update erp.app_user u
     set status = 'disabled'::erp.principal_status
    from gone
   where u.tenant_id = p_tenant_id and u.id = gone.app_user_id
     and u.auth_user_id is null;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function erp.retire_demonstration_personas(uuid) from public, anon;

comment on function erp.retire_demonstration_personas(uuid) is
  'Retires a demonstration''s personas once the organisation is no longer a demonstration: persona rows removed, '
  'the person disabled (20261006153000); a tab still naming her acts as the person (20261010030000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Paying a demonstration's suppliers names the other person as a tab does
-- ─────────────────────────────────────────────────────────────────────────────

do $pay$
declare
  v_sig  constant text := 'erp.pay_demonstration_suppliers(date,date)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_prev_at timestamptz;
$o$;
  v_new1 constant text := $n$  v_prev_at timestamptz;
  v_headers text;
  v_tab     jsonb;
$n$;
  v_old2 constant text := $o$    -- The other person, by the choice a visitor makes under Act as, read by
    -- erp.principal_context() with every condition it sets. The signed-in
    -- person's own choice is put back below.
    select c.persona_id, c.chosen_at into v_prev, v_prev_at
      from erp.demonstration_persona_choice c
     where c.tenant_id = v_tenant and c.app_user_id = v_self;
    v_had := found;
    insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
    values (v_tenant, v_self, v_persona, now())
    on conflict (tenant_id, app_user_id)
    do update set persona_id = excluded.persona_id, chosen_at = excluded.chosen_at;
    perform set_config('erp.persona_set_aside', '', true);
$o$;
  v_new2 constant text := $n$    -- The other person, named as a browser tab names her under Act as
    -- (20261010030000): this request's x-clove-act-as header, read by
    -- erp.principal_context() with every condition it sets. The request's
    -- own headers are put back below.
    v_headers := current_setting('request.headers', true);
    v_tab := '{}'::jsonb;
    if pg_catalog.pg_input_is_valid(coalesce(v_headers, ''), 'jsonb') then
      v_tab := v_headers::jsonb;
      if jsonb_typeof(v_tab) <> 'object' then
        v_tab := '{}'::jsonb;
      end if;
    end if;
    perform set_config('request.headers',
                       (v_tab || jsonb_build_object('x-clove-act-as', v_persona))::text, true);
    perform set_config('erp.persona_set_aside', '', true);
$n$;
  v_old3 constant text := $o$    perform set_config('erp.persona_set_aside', 'yes', true);
    if v_had then
      update erp.demonstration_persona_choice c
         set persona_id = v_prev, chosen_at = v_prev_at
       where c.tenant_id = v_tenant and c.app_user_id = v_self;
    else
      delete from erp.demonstration_persona_choice c
       where c.tenant_id = v_tenant and c.app_user_id = v_self;
    end if;
$o$;
  v_new3 constant text := $n$    perform set_config('erp.persona_set_aside', 'yes', true);
    perform set_config('request.headers', coalesce(v_headers, ''), true);
$n$;
begin
  if strpos(v_src, '20261010030000') > 0 then
    raise notice '% already names the other person as a tab does; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'feafec3f2bfbd6cfdb240f2a04da9a11' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010030000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$pay$;

comment on function erp.pay_demonstration_suppliers(date, date) is
  'A demonstration pays its suppliers (20261006160000, J-142): a payment run dated the day, for what was billed '
  'by then and falls due by the second date, proposed as the person who signed in and approved and paid as the '
  'demonstration''s other person, named in the request''s headers as a browser tab names her and put back '
  'afterwards (20261010030000). Nothing outside a demonstration that is not live; a note, and nothing paid, '
  'without a second person.';

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The account-wide choice is retired
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.personas_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- Somebody to act as where nobody may be (20261006150000), and an
  -- account-wide choice of somebody, which nothing reads since a browser tab
  -- keeps the choice (20261010030000).
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
  select 'an account-wide choice of somebody to act as is left, which nothing reads: a browser tab keeps the choice',
         t.code, u.display_name
    from erp.demonstration_persona_choice c
    join erp.tenant t on t.id = c.tenant_id
    join erp.app_user u on u.tenant_id = c.tenant_id and u.id = c.app_user_id
   where c.persona_id is not null
   order by 1, 2, 3
$$;

revoke all on function erp.personas_report() from public, anon;

comment on function erp.personas_report() is
  'Demonstration personas where none may be: outside a demonstration, in one that is live, or a persona who can '
  'sign in (20261006150000); and any account-wide choice of one, retired since a browser tab keeps the choice '
  '(20261010030000).';

comment on table erp.demonstration_persona_choice is
  'Retired (20261010030000): who each signed-in person of a demonstration acted as, account-wide '
  '(20261006152000). Nothing reads or writes it: a browser tab keeps the choice and names it in its '
  'x-clove-act-as header. A row naming somebody is a finding of erp.personas_report().';

update erp_meta.table_policy
   set note = 'Retired: who a signed-in person of a demonstration acted as, account-wide. Nothing reads or '
              'writes it since a browser tab keeps the choice (20261010030000).'
 where schema_name = 'erp' and table_name = 'demonstration_persona_choice';

do $retire$
declare
  r   record;
  v_n integer;
begin
  for r in select t.id, t.code from erp.tenant t
            where exists (select 1 from erp.demonstration_persona_choice c where c.tenant_id = t.id)
            order by t.code loop
    perform erp_meta.act_in_tenant(r.id);
    delete from erp.demonstration_persona_choice c where c.tenant_id = r.id;
    get diagnostics v_n = row_count;
    -- The checks the delete left waiting, fired while still in the
    -- organisation they read, so the generators below can alter the tables.
    set constraints all immediate;
    raise warning 'act as: % account-wide choice(s) retired in %', v_n, r.code;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$retire$;

-- ─────────────────────────────────────────────────────────────────────────────
-- H. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- The visitor's tab names nobody while the demonstration pays its suppliers,
-- and its request headers are as it left them afterwards.
do $pays$
declare
  v_sig  constant text := 'erp_test.demonstration_pays_suppliers_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_choice  record;
$o$;
  v_new1 constant text := $n$  v_choice  record;
  -- What the visitor's tab sends: its own headers, naming nobody to act as
  -- (20261010030000).
  v_tab_headers constant text := '{"x-client-info": "demonstration pays suppliers suite"}';
$n$;
  v_old2 constant text := $o$    -- The visitor once chose somebody and came back to themselves.
    insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
    values (rb.tenant_id, rb.admin_user_id, null, v_chosen_at);
$o$;
  v_new2 constant text := $n$    -- The visitor's tab names nobody to act as; paying must leave its
    -- request headers as they were (20261010030000).
    perform set_config('request.headers', v_tab_headers, true);
$n$;
  v_old3 constant text := $o$    v_who := erp.current_principal_id();
    select c.persona_id, c.chosen_at into v_choice
      from erp.demonstration_persona_choice c
     where c.tenant_id = rb.tenant_id and c.app_user_id = rb.admin_user_id;
    v_cases := v_cases + 1;
    case_name := 'afterwards the person building is themselves again, and their own choice under Act as is as they left it';
    passed := v_state is null and v_who = rb.admin_user_id
          and v_choice.persona_id is null and v_choice.chosen_at = v_chosen_at
          and coalesce(current_setting('erp.persona_set_aside', true), '') = '';
    detail := coalesce(v_state, format('acting as %s; choice %s chosen at %s',
                       case when v_who = rb.admin_user_id then 'themselves' else coalesce(v_who::text, 'nobody') end,
                       coalesce(v_choice.persona_id::text, 'nobody'), v_choice.chosen_at));
$o$;
  v_new3 constant text := $n$    v_who := erp.current_principal_id();
    v_cases := v_cases + 1;
    case_name := 'afterwards the person building is themselves again, their tab''s request headers are as they left them, and nothing account-wide was written';
    passed := v_state is null and v_who = rb.admin_user_id
          and current_setting('request.headers', true) = v_tab_headers
          and not exists (select 1 from erp.demonstration_persona_choice c where c.tenant_id = rb.tenant_id)
          and coalesce(current_setting('erp.persona_set_aside', true), '') = '';
    detail := coalesce(v_state, format('acting as %s; request headers %s',
                       case when v_who = rb.admin_user_id then 'themselves' else coalesce(v_who::text, 'nobody') end,
                       coalesce(current_setting('request.headers', true), 'unset')));
$n$;
begin
  if strpos(v_src, '20261010030000') > 0 then
    raise notice '% already acts as a tab does; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'dfd9988b6fbf3fcdf1880fc16e7cc32b' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010030000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$pays$;

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
  v_a      uuid; v_b uuid; v_c uuid; v_d uuid;
  v_src    text;
  v_tab    text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    -- A demonstration whose administrator is also the platform owner, a
    -- clerk who may not give roles, and two bills owed to a supplier. The
    -- browser tab keeps whom it acts as and names her in each request's
    -- x-clove-act-as header (20261010030000); v_tab is that header.
    v_step := 'a demonstration, its owner-administrator, a clerk and two bills';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.headers', '', true);
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
    v_tab := json_build_object('x-clove-act-as', v_priya)::text;
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
    v_step := 'choosing Priya under Act as, as the signed-in role, and the tab naming her';
    execute 'set local role authenticated';
    v_who := public.erp_act_as_persona(v_priya);
    perform set_config('request.headers', v_tab, true);
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
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'demonstration_persona'
                         and ae.action = 'execute' and ae.object_id = v_priya
                         and (ae.after_state ->> 'acting_as')::uuid = v_priya
                         and ae.actor_id = rb.admin_user_id)
          and not exists (select 1 from erp.audit_entry ae
                           where ae.tenant_id = rb.tenant_id and ae.object_type = 'demonstration_persona'
                             and ae.action = 'execute' and ae.actor_id = v_priya);
    detail := coalesce(v_state, 'audit read');
    return next;

    -- ── 6. Back to yourself ─────────────────────────────────────────────────
    -- The request that goes back still names her; the tab then forgets her.
    v_step := 'going back to yourself, and approving Priya''s run';
    execute 'set local role authenticated';
    v_back := public.erp_act_as_persona(null);
    perform set_config('request.headers', '', true);
    v_sess := public.erp_session();
    perform public.erp_approve_payment_run(v_run2);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'acting as yourself again while the persona is named puts the visitor back, is audited as theirs, and they may approve what she proposed';
    passed := v_state is null
          and (v_sess ->> 'principal_id')::uuid = rb.admin_user_id
          and v_back -> 'acting_as' = 'null'::jsonb
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = rb.tenant_id and ae.object_type = 'demonstration_persona'
                         and ae.action = 'execute' and ae.after_state -> 'acting_as' = 'null'::jsonb
                         and (ae.after_state ->> 'was')::uuid = v_priya
                         and ae.actor_id = rb.admin_user_id)
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
    -- A clerk's tab that names her anyway is the clerk.
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    perform set_config('request.headers', '', true);
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
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    perform set_config('erp.persona_set_aside', 'yes', true);
    v_b := erp.current_principal_id();
    perform set_config('erp.persona_set_aside', '', true);
    update erp.app_user set status = 'disabled' where tenant_id = rb.tenant_id and id = v_priya;
    v_c := erp.current_principal_id();
    perform set_config('request.headers', '', true);
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
    -- Choosing somebody is refused here; going back to yourself is not
    -- (20261006153000): stopping is never refused.
    begin perform public.erp_act_as_persona(gen_random_uuid()); v_err := 'acting';
    exception when others then v_err := sqlerrm; end;
    v_back := public.erp_act_as_persona(null);
    begin
      insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id)
      values (rc.tenant_id, rc.admin_user_id, null);
      v_err2 := 'written';
    exception when others then v_err2 := sqlerrm; end;
    -- A tab here naming the demonstration's persona is the person.
    perform set_config('request.headers', v_tab, true);
    v_d := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'in an organisation that is not a demonstration choosing somebody is refused and a choice cannot be written, but going back to yourself works';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
          and v_back -> 'acting_as' = 'null'::jsonb
          and v_err2 like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
          and v_d = rc.admin_user_id
          and public.erp_demonstration_personas() -> 'personas' = '[]'::jsonb;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_d::text));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
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
  'A visitor to a demonstration can act as its other person (20261006152000), in the browser tab that chose her '
  '(20261010030000): propose as yourself, approve as her, never both as one; her permissions only, never the '
  'owner''s; each act and each switch audited as whoever did it; back to yourself; refused to a clerk, for an '
  'unknown person and outside a demonstration; set aside for the catch-up.';

create or replace function erp_test.persona_safety_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid(); a3 uuid := gen_random_uuid();
  a4 uuid := gen_random_uuid(); a5 uuid := gen_random_uuid();
  ra record; rg record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_priya  uuid; v_priya_g uuid;
  v_second uuid; v_second_g uuid;
  v_a uuid; v_b uuid;
  v_ok1 boolean; v_ok2 boolean;
  v_menu   jsonb; v_back jsonb;
  v_s1 uuid; v_s2 uuid;
  v_err text; v_err2 text; v_err3 text;
  v_token  text;
  v_n      integer;
  v_tab    text;
  v_tab_g  text;
begin
  begin
    -- ── The fixture: a demonstration with two administrators ────────────────
    -- A browser tab acting as Priya names her in each request's x-clove-act-as
    -- header (20261010030000); v_tab is that header.
    v_step := 'a demonstration with two administrators';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.headers', '', true);
    select * into ra from erp.provision_tenant(
      'demo-zzsf' || v_tag, 'Persona Safety Suite', 'admin@demo-zzsf' || v_tag || '.test', 'Safety Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzsf' || v_tag || '.test'),
           (a2, 'second@demo-zzsf' || v_tag || '.test'),
           (a3, 'claimer@zzsf' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.ensure_demo_configuration(ra.tenant_id, ra.admin_user_id);
    select dp.app_user_id into v_priya from erp.demonstration_persona dp where dp.tenant_id = ra.tenant_id;
    v_tab := json_build_object('x-clove-act-as', v_priya)::text;
    res := public.erp_invite_principal('second@demo-zzsf' || v_tag || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_second, 'administrator', null, null, 'second');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');

    -- ── 1. Roles removed, the act ends and going back works ─────────────────
    v_step := 'the second administrator acts as Priya and loses their roles';
    execute 'set local role authenticated';
    perform public.erp_act_as_persona(v_priya);
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    execute 'reset role';
    delete from erp.user_role where tenant_id = ra.tenant_id and app_user_id = v_second;
    execute 'set local role authenticated';
    v_b := erp.current_principal_id();
    v_ok1 := erp.has_permission('finance.approve_payment');
    v_menu := public.erp_demonstration_personas();
    v_back := public.erp_act_as_persona(null);
    execute 'reset role';
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'somebody acting as the persona whose roles are removed is themselves again at once, holds nothing of hers, and can go back without any permission';
    passed := v_state is null
          and v_a = v_priya and v_b = v_second and not v_ok1
          and v_menu -> 'acting_as' = 'null'::jsonb
          and v_back -> 'acting_as' = 'null'::jsonb
          and not exists (select 1 from erp.demonstration_persona_choice c
                           where c.tenant_id = ra.tenant_id);
    detail := coalesce(v_state, format('chosen %s, after removal %s, finance.approve_payment %s', v_a, v_b, v_ok1));
    return next;

    -- Their roles back, for what follows.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(v_second, 'administrator', null, null, 'second again');

    -- ── 2. Two people acting as her at once are told apart ──────────────────
    v_step := 'both administrators act as Priya and each writes';
    perform public.erp_act_as_persona(v_priya);
    perform set_config('request.headers', v_tab, true);
    v_s1 := erp_test.cash_payment_supplier('ZSFA' || v_tag);
    perform erp.authorise('finance.read', null, null, null, 'party', v_s1);
    perform set_config('request.headers', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_act_as_persona(v_priya);
    perform set_config('request.headers', v_tab, true);
    v_s2 := erp_test.cash_payment_supplier('ZSFB' || v_tag);
    perform erp.authorise('finance.read', null, null, null, 'party', v_s2);
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'two people acting as the persona at once are told apart: the audit trail and the access log name her, and who acted as her';
    passed := v_state is null
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = ra.tenant_id and ae.object_type = 'party' and ae.object_id = v_s1
                         and ae.actor_id = v_priya
                         and ae.actor_label = format('Priya Shah (acted by Safety Admin, %s)', ra.admin_user_id))
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = ra.tenant_id and ae.object_type = 'party' and ae.object_id = v_s2
                         and ae.actor_id = v_priya
                         and ae.actor_label = format('Priya Shah (acted by Second Admin, %s)', v_second))
          and exists (select 1 from erp.access_log al
                       where al.tenant_id = ra.tenant_id and al.object_id = v_s1 and al.app_user_id = v_priya
                         and al.reason = format('acted by Safety Admin, %s', ra.admin_user_id))
          and exists (select 1 from erp.access_log al
                       where al.tenant_id = ra.tenant_id and al.object_id = v_s2 and al.app_user_id = v_priya
                         and al.reason = format('acted by Second Admin, %s', v_second));
    detail := coalesce(v_state, (select string_agg(ae.actor_label, ' / ' order by ae.id) from erp.audit_entry ae
                                  where ae.tenant_id = ra.tenant_id and ae.object_type = 'party'
                                    and ae.object_id in (v_s1, v_s2)));
    return next;

    -- ── 3. Never invited, never signed in as ────────────────────────────────
    v_step := 'inviting Priya, and claiming an invitation onto her';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform public.erp_act_as_persona(null);
    begin perform public.erp_invite_principal('priya.shah@example.invalid', 'Priya Shah'); v_err := 'invited';
    exception when others then v_err := sqlerrm; end;
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    insert into erp.invitation (tenant_id, app_user_id, token_digest, expires_at)
    values (ra.tenant_id, v_priya, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '1 day');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin perform erp.claim_invitation(v_token); v_err2 := 'claimed';
    exception when others then v_err2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'the persona is never invited, and an invitation onto her is never claimed: she keeps no sign-in';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERSONA_CANNOT_SIGN_IN%'
          and v_err2 like 'CLOVEERP_PERSONA_CANNOT_SIGN_IN%'
          and exists (select 1 from erp.app_user u where u.id = v_priya
                       and u.auth_user_id is null and u.status = 'active')
          and not exists (select 1 from erp.personas_report() r where r.reference = 'demo-zzsf' || v_tag);
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2));
    return next;

    -- ── 4. Renamed off demo-, the persona is retired ────────────────────────
    v_step := 'renaming the demonstration while the second administrator acts as Priya';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_act_as_persona(v_priya);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.set_tenant_address('zzsfr' || v_tag);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    v_back := public.erp_act_as_persona(null);
    perform set_config('request.headers', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin delete from erp.app_user where tenant_id = ra.tenant_id and id = v_priya; v_err := 'deleted';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a demonstration renamed off demo- keeps nobody to act as: a tab naming her is the person, persona retired, going back works, and she can be removed';
    passed := v_state is null
          and v_a = v_second
          and v_back -> 'acting_as' = 'null'::jsonb
          and not exists (select 1 from erp.demonstration_persona dp where dp.tenant_id = ra.tenant_id)
          and not exists (select 1 from erp.demonstration_persona_choice c
                           where c.tenant_id = ra.tenant_id and c.persona_id is not null)
          and not exists (select 1 from erp.personas_report() r where r.reference = 'zzsfr' || v_tag)
          and v_err = 'deleted';
    detail := coalesce(v_state, concat_ws(' / ', v_a::text, v_err));
    return next;

    -- ── 5. Gone live, the persona is retired ────────────────────────────────
    v_step := 'a second demonstration going live while somebody acts as Priya';
    perform set_config('request.jwt.claims', '', true);
    select * into rg from erp.provision_tenant(
      'demo-zzsg' || v_tag, 'Persona Live Suite', 'admin@demo-zzsg' || v_tag || '.test', 'Live Admin');
    update erp.environment set is_live = false where tenant_id = rg.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a4, 'admin@demo-zzsg' || v_tag || '.test'), (a5, 'second@demo-zzsg' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(rg.admin_token);
    perform erp.ensure_demo_configuration(rg.tenant_id, rg.admin_user_id);
    select dp.app_user_id into v_priya_g from erp.demonstration_persona dp where dp.tenant_id = rg.tenant_id;
    v_tab_g := json_build_object('x-clove-act-as', v_priya_g)::text;
    res := public.erp_invite_principal('second@demo-zzsg' || v_tag || '.test', 'Second Live Admin');
    v_second_g := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_second_g, 'administrator', null, null, 'second');
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform public.erp_act_as_persona(v_priya_g);
    perform set_config('request.headers', v_tab_g, true);
    v_a := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    v_step := 'going live';
    perform erp.go_live();
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform set_config('request.headers', v_tab_g, true);
    v_b := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'a demonstration that goes live keeps nobody to act as: a tab naming her is the person, persona retired and disabled, and the assertion is clean';
    passed := v_state is null
          and v_a = v_priya_g and v_b = v_second_g
          and not exists (select 1 from erp.demonstration_persona dp where dp.tenant_id = rg.tenant_id)
          and not exists (select 1 from erp.demonstration_persona_choice c
                           where c.tenant_id = rg.tenant_id and c.persona_id is not null)
          and (select u.status::text from erp.app_user u where u.id = v_priya_g) = 'disabled'
          and not exists (select 1 from erp.personas_report() r where r.reference = 'demo-zzsg' || v_tag);
    detail := coalesce(v_state, format('before %s, after %s', v_a, v_b));
    return next;

    -- ── 6. Only the demonstration seed makes a demo- address ────────────────
    -- The application signs in as a role that does not bypass row security;
    -- this suite's own login does, so the rule is asked of each login by name.
    v_step := 'asking for demo- addresses';
    v_err := erp.demo_address_refusal('demo-zzsx' || v_tag, 'authenticated');
    v_err3 := erp.demo_address_refusal('demo-zzsx' || v_tag, 'anon');
    perform set_config('erp.seeding_demonstration', 'yes', true);
    v_err2 := erp.demo_address_refusal('demo-zzsx' || v_tag, 'authenticated');
    perform set_config('erp.seeding_demonstration', '', true);
    v_cases := v_cases + 1;
    case_name := 'a demo- address is refused to the application, except inside the demonstration seed, and the address check asks it of the login';
    passed := v_state is null
          and v_err like 'CLOVEERP_ADDRESS_RESERVED%'
          and v_err3 like 'CLOVEERP_ADDRESS_RESERVED%'
          and v_err2 is null
          and erp.demo_address_refusal('zzsx' || v_tag, 'authenticated') is null
          and erp.demo_address_refusal('demo-zzsx' || v_tag, session_user) is null
          and strpos((select p.prosrc from pg_catalog.pg_proc p
                       where p.oid = 'erp.tenant_code_refusal(text,uuid)'::regprocedure),
                     'erp.demo_address_refusal(p_code, session_user)') > 0
          and strpos((select p.prosrc from pg_catalog.pg_proc p
                       where p.oid = 'erp.seed_demo()'::regprocedure),
                     $q$set_config('erp.seeding_demonstration', 'yes', true)$q$) > 0;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err3, coalesce(v_err2, 'seed allowed')));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
  perform set_config('erp.persona_set_aside', '', true);
  perform set_config('erp.seeding_demonstration', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PERSONA_SAFETY_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.persona_safety_suite() from public, anon;

comment on function erp_test.persona_safety_suite() is
  'Acting as somebody else ends cleanly and names who acted (20261006153000), with the tab keeping the choice '
  '(20261010030000): roles removed ends the act and going back needs nothing; two visitors told apart in the '
  'audit trail and access log; the persona never invited or claimed; renamed or gone live, the persona retired; '
  'demo- addresses only from the seed.';

create or replace function erp_test.act_as_per_tab_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1 uuid := gen_random_uuid();   -- the visitor, administrator of demonstration A
  a2 uuid := gen_random_uuid();   -- a clerk of A, who may not give roles
  a3 uuid := gen_random_uuid();   -- the administrator of demonstration B
  a4 uuid := gen_random_uuid();   -- the administrator of C, which is not a demonstration
  a5 uuid := gen_random_uuid();   -- a sign-in somebody gives Priya
  ra record; rb record; rc record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_priya  uuid; v_priya_b uuid; v_clerk uuid; v_quiet uuid; v_a1_b uuid; v_env uuid;
  v_tab    text; v_tab_b text; v_other text;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid;
  v_t      uuid;
  v_menu   jsonb; v_menu2 jsonb; v_who jsonb; v_back jsonb;
  v_owner1 boolean; v_owner2 boolean;
  v_ok     boolean;
  v_err    text;
  v_h      text;
  v_bad    integer;
  v_n      integer;
  v_from   date;
  v_report integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    -- Demonstration A: the visitor (its administrator and the platform owner)
    -- and a clerk. Demonstration B with its own administrator and persona.
    -- C, an ordinary organisation, with a colleague who cannot sign in. A
    -- browser tab acting as somebody names them in each request's
    -- x-clove-act-as header, which PostgREST hands to SQL as request.headers.
    v_step := 'demonstration A, its administrator and a clerk';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.headers', '', true);
    perform set_config('erp.persona_set_aside', '', true);
    select * into ra from erp.provision_tenant(
      'demo-zzta' || v_tag, 'Act As Tab Suite A', 'admin@demo-zzta' || v_tag || '.test', 'Tab Admin');
    update erp.environment set is_live = false where tenant_id = ra.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzta' || v_tag || '.test'),
           (a2, 'clerk@demo-zzta' || v_tag || '.test'),
           (a3, 'admin@demo-zztb' || v_tag || '.test'),
           (a4, 'admin@zztc' || v_tag || '.test'),
           (a5, 'priya@zztx' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('admin@demo-zzta' || v_tag || '.test', a1, 'Act As Tab Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);
    perform erp.ensure_demo_configuration(ra.tenant_id, ra.admin_user_id);
    select dp.app_user_id into v_priya from erp.demonstration_persona dp where dp.tenant_id = ra.tenant_id;
    v_tab   := json_build_object('x-clove-act-as', v_priya, 'x-client-info', 'act as per tab suite')::text;
    v_other := json_build_object('x-client-info', 'act as per tab suite')::text;
    res := public.erp_invite_principal('clerk@demo-zzta' || v_tag || '.test', 'Tab Clerk');
    v_clerk := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_clerk, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');

    v_step := 'demonstration B and its administrator';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zztb' || v_tag, 'Act As Tab Suite B', 'admin@demo-zztb' || v_tag || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select dp.app_user_id into v_priya_b from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id;
    v_tab_b := json_build_object('x-clove-act-as', v_priya_b)::text;

    v_step := 'C, an ordinary organisation, and a colleague there who cannot sign in';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zztc' || v_tag, 'Act As Tab Suite C', 'admin@zztc' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    insert into erp.app_user (tenant_id, kind, status, display_name, email)
    values (rc.tenant_id, 'person', 'active', 'Quiet Colleague', 'quiet@zztc' || v_tag || '.test')
    returning id into v_quiet;

    -- ── 1. One tab acts as her, another is the person ───────────────────────
    v_step := 'one tab naming Priya and another naming nobody, at the same moment';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    execute 'set local role authenticated';
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    v_menu := public.erp_demonstration_personas();
    perform set_config('request.headers', v_other, true);
    v_b := erp.current_principal_id();
    v_menu2 := public.erp_demonstration_personas();
    perform set_config('request.headers', '', true);
    v_c := erp.current_principal_id();
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'a tab that names the persona acts as her, while another tab or device of the same sign-in, naming nobody, is the person';
    passed := v_state is null
          and v_a = v_priya and v_b = ra.admin_user_id and v_c = ra.admin_user_id
          and (v_menu #>> '{acting_as,principal_id}')::uuid = v_priya
          and (v_menu #>> '{signed_in,principal_id}')::uuid = ra.admin_user_id
          and v_menu2 -> 'acting_as' = 'null'::jsonb
          and (v_menu2 #>> '{signed_in,principal_id}')::uuid = ra.admin_user_id
          and not exists (select 1 from erp.demonstration_persona_choice c where c.tenant_id = ra.tenant_id);
    detail := coalesce(v_state, format('naming her %s, naming nobody %s, no header %s', v_a, v_b, v_c));
    return next;

    -- ── 2. A switch is recorded as the person, and nothing account-wide ─────
    v_step := 'choosing Priya and going back through the door';
    execute 'set local role authenticated';
    v_who := public.erp_act_as_persona(v_priya);
    perform set_config('request.headers', v_tab, true);
    v_back := public.erp_act_as_persona(null);
    perform set_config('request.headers', '', true);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'choosing her and going back are each audited as the person who signed in, even from a tab acting as her, and write nothing that other tabs read';
    passed := v_state is null
          and (v_who #>> '{acting_as,principal_id}')::uuid = v_priya
          and v_back -> 'acting_as' = 'null'::jsonb
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = ra.tenant_id and ae.object_type = 'demonstration_persona'
                         and ae.action = 'execute' and ae.object_id = v_priya
                         and (ae.after_state ->> 'acting_as')::uuid = v_priya
                         and ae.actor_id = ra.admin_user_id and ae.actor_label = 'Tab Admin')
          and exists (select 1 from erp.audit_entry ae
                       where ae.tenant_id = ra.tenant_id and ae.object_type = 'demonstration_persona'
                         and ae.action = 'execute' and ae.after_state -> 'acting_as' = 'null'::jsonb
                         and (ae.after_state ->> 'was')::uuid = v_priya
                         and ae.actor_id = ra.admin_user_id and ae.actor_label = 'Tab Admin')
          and not exists (select 1 from erp.audit_entry ae
                           where ae.tenant_id = ra.tenant_id and ae.object_type = 'demonstration_persona'
                             and ae.action = 'execute' and ae.actor_id = v_priya)
          and not exists (select 1 from erp.demonstration_persona_choice c where c.tenant_id = ra.tenant_id);
    detail := coalesce(v_state, format('chose %s, back %s', left(v_who::text, 160), left(v_back::text, 160)));
    return next;

    -- ── 3. The platform owner's pass is not hers ────────────────────────────
    v_step := 'the visitor, who is the platform owner, in a tab naming Priya and in one naming nobody';
    perform set_config('request.headers', v_tab, true);
    v_owner1 := erp.is_platform_owner();
    perform set_config('request.headers', v_other, true);
    v_owner2 := erp.is_platform_owner();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'the platform owner acting as the persona in one tab has no owner''s pass there, and keeps it in a tab that names nobody';
    passed := v_state is null and not v_owner1 and v_owner2;
    detail := coalesce(v_state, format('acting %s, as themselves %s', v_owner1, v_owner2));
    return next;

    -- ── 4. A header that is not well formed is not an error ─────────────────
    v_step := 'requests whose header is malformed';
    v_bad := 0; v_err := null;
    execute 'set local role authenticated';
    begin
      foreach v_h in array array[
        '{"x-clove-act-as": "not-a-uuid"}',
        '{"x-clove-act-as": 42}',
        '{"x-clove-act-as": null}',
        '{"x-clove-act-as": ""}',
        '{"x-clove-act-as": "' || repeat('-', 36) || '"}',
        '{"x-clove-act-as": {"id": "' || v_priya || '"}}',
        '["x-clove-act-as"]',
        '"x-clove-act-as" is not json {',
        json_build_object('x-clove-act-as', gen_random_uuid())::text,
        json_build_object('x-clove-act-as', ra.admin_user_id)::text] loop
        perform set_config('request.headers', v_h, true);
        if erp.current_principal_id() is distinct from ra.admin_user_id then
          v_bad := v_bad + 1;
        end if;
        perform public.erp_session();
      end loop;
    exception when others then v_err := sqlerrm; end;
    perform set_config('request.headers', '', true);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'a header naming nobody, not a uuid, not text or not even in well-formed headers is ignored: the request is the person''s and is never refused';
    passed := v_state is null and v_bad = 0 and v_err is null;
    detail := coalesce(v_state, format('%s request(s) not the person; error %s', v_bad, coalesce(v_err, 'none')));
    return next;

    -- ── 5. Set aside, the header is not read ────────────────────────────────
    v_step := 'a tab naming Priya while the person is set aside';
    perform set_config('request.headers', v_tab, true);
    perform set_config('erp.persona_set_aside', 'yes', true);
    v_a := erp.current_principal_id();
    perform set_config('erp.persona_set_aside', '', true);
    v_b := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'set aside to act as themselves, as the nightly catch-up and the switch itself set it, a person whose tab names the persona is themselves';
    passed := v_state is null and v_a = ra.admin_user_id and v_b = v_priya;
    detail := coalesce(v_state, format('set aside %s, not %s', v_a, v_b));
    return next;

    -- ── 6. A persona who can sign in, or is not active ──────────────────────
    v_step := 'a tab naming Priya once she has a sign-in, and once she is suspended';
    update erp.app_user set auth_user_id = a5 where tenant_id = ra.tenant_id and id = v_priya;
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    update erp.app_user set auth_user_id = null, status = 'suspended' where tenant_id = ra.tenant_id and id = v_priya;
    v_b := erp.current_principal_id();
    update erp.app_user set status = 'active' where tenant_id = ra.tenant_id and id = v_priya;
    v_c := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'a tab naming a persona who can sign in, or who is not active, is the person; named again once she is neither, it acts as her';
    passed := v_state is null and v_a = ra.admin_user_id and v_b = ra.admin_user_id and v_c = v_priya;
    detail := coalesce(v_state, format('with a sign-in %s, suspended %s, restored %s', v_a, v_b, v_c));
    return next;

    -- ── 7. A demonstration that is live ─────────────────────────────────────
    -- Made live without the retiring trigger seeing it (the environment
    -- ceases to be the organisation's own, goes live, and becomes its own
    -- again), so her persona row stays and only principal_context decides.
    v_step := 'demonstration A made live with its persona kept';
    select e.id into v_env from erp.environment e where e.tenant_id = ra.tenant_id and e.is_self;
    update erp.environment set is_self = false where id = v_env;
    update erp.environment set is_live = true where id = v_env;
    update erp.environment set is_self = true where id = v_env;
    select count(*) into v_n from erp.demonstration_persona dp where dp.tenant_id = ra.tenant_id;
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    update erp.environment set is_live = false where id = v_env;
    v_b := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'in a demonstration that is live, a tab naming its persona is the person, even where her row is still there';
    passed := v_state is null and v_n = 1 and v_a = ra.admin_user_id and v_b = v_priya;
    detail := coalesce(v_state, format('%s persona row(s); live %s, not live %s', v_n, v_a, v_b));
    return next;

    -- ── 8. Not without administration.roles, held as yourself, today ────────
    v_step := 'a clerk''s tab naming Priya, and the visitor''s once their grant has not started';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    v_ok := erp.has_permission('finance.approve_payment');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select min(ur.valid_from) into v_from from erp.user_role ur
     where ur.tenant_id = ra.tenant_id and ur.app_user_id = ra.admin_user_id;
    update erp.user_role set valid_from = current_date + 1
     where tenant_id = ra.tenant_id and app_user_id = ra.admin_user_id;
    v_b := erp.current_principal_id();
    update erp.user_role set valid_from = v_from
     where tenant_id = ra.tenant_id and app_user_id = ra.admin_user_id;
    v_c := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    v_cases := v_cases + 1;
    case_name := 'a tab naming the persona is the person unless they hold administration.roles as themselves today: a clerk is the clerk, holding nothing of hers, and so is a visitor whose grant has not started';
    passed := v_state is null
          and v_a = v_clerk and not v_ok
          and v_b = ra.admin_user_id and v_c = v_priya;
    detail := coalesce(v_state, format('clerk %s (approve %s), grant not started %s, grant restored %s', v_a, v_ok, v_b, v_c));
    return next;

    -- ── 9. A forged header naming another organisation's persona ────────────
    -- The visitor is an administrator of B as well, and B is the organisation
    -- they are in. A tab naming A's persona, where they are an administrator
    -- too, is forged here; B's own persona is not.
    v_step := 'the visitor in B, with tabs naming A''s persona and B''s';
    insert into erp.app_user (tenant_id, kind, status, display_name, email, auth_user_id)
    values (rb.tenant_id, 'person', 'active', 'Tab Admin', 'admin@demo-zzta' || v_tag || '.test', a1)
    returning id into v_a1_b;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.grant_role(v_a1_b, 'administrator', null, null, 'in both');
    -- B's own administrator, whose tab names A's persona.
    perform set_config('request.headers', v_tab, true);
    v_d := erp.current_principal_id();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    delete from erp_meta.principal_preference where auth_user_id = a1;
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (a1, rb.tenant_id, now());
    v_t := erp.current_tenant_id();
    v_a := erp.current_principal_id();
    v_menu := public.erp_demonstration_personas();
    perform set_config('request.headers', v_tab_b, true);
    v_b := erp.current_principal_id();
    perform set_config('request.headers', '', true);
    delete from erp_meta.principal_preference where auth_user_id = a1;
    update erp.app_user set status = 'disabled' where tenant_id = rb.tenant_id and id = v_a1_b;
    v_c := erp.current_principal_id();
    v_cases := v_cases + 1;
    case_name := 'a forged header naming a persona of another organisation is ignored, even one where the person is an administrator too: only a persona of the organisation they are in is acted as';
    passed := v_state is null
          and v_t = rb.tenant_id
          and v_a = v_a1_b and v_menu -> 'acting_as' = 'null'::jsonb
          and v_d = rb.admin_user_id
          and v_b = v_priya_b
          and v_c = ra.admin_user_id;
    detail := coalesce(v_state, format('in %s: naming A''s persona %s, B''s %s; B''s administrator naming A''s %s; back in A %s',
      v_t, v_a, v_b, v_d, v_c));
    return next;

    -- ── 10. Not in an organisation that is not a demonstration ──────────────
    v_step := 'C''s administrator with tabs naming the demonstration''s persona and their own colleague';
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    execute 'set local role authenticated';
    perform set_config('request.headers', v_tab, true);
    v_a := erp.current_principal_id();
    perform set_config('request.headers', json_build_object('x-clove-act-as', v_quiet)::text, true);
    v_b := erp.current_principal_id();
    v_menu := public.erp_demonstration_personas();
    perform set_config('request.headers', '', true);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'in an organisation that is not a demonstration, a tab naming a demonstration''s persona, or a colleague of theirs who cannot sign in, is the person';
    passed := v_state is null
          and v_a = rc.admin_user_id and v_b = rc.admin_user_id
          and v_menu -> 'acting_as' = 'null'::jsonb
          and v_menu -> 'personas' = '[]'::jsonb;
    detail := coalesce(v_state, format('naming the persona %s, the colleague %s', v_a, v_b));
    return next;

    -- ── 11. The account-wide choice is retired ──────────────────────────────
    v_step := 'an account-wide choice of Priya left behind';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id)
    values (ra.tenant_id, ra.admin_user_id, v_priya);
    v_a := erp.current_principal_id();
    select count(*) into v_report from erp.personas_report() r where r.reference = 'demo-zzta' || v_tag;
    delete from erp.demonstration_persona_choice where tenant_id = ra.tenant_id;
    select count(*) into v_n
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'public')
       and p.prosrc like '%demonstration\_persona\_choice%'
       and p.proname not in ('personas_report', 'refuse_persona_outside_demonstration');
    v_cases := v_cases + 1;
    case_name := 'an account-wide choice is read by nothing: a person it names the persona for is themselves, it is reported, and no routine but the report reads or writes one';
    passed := v_state is null and v_a = ra.admin_user_id and v_report = 1 and v_n = 0;
    detail := coalesce(v_state, format('resolved %s, reported %s, %s routine(s) still reach the table', v_a, v_report, v_n));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);
  perform set_config('erp.persona_set_aside', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_ACT_AS_PER_TAB_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.act_as_per_tab_suite() from public, anon;

comment on function erp_test.act_as_per_tab_suite() is
  'Act as is chosen in each browser tab (20261010030000): the tab naming the persona acts as her and another tab '
  'is the person; switches audited as the person; no owner''s pass; malformed headers ignored, never refused; '
  'set aside; a persona who can sign in or is not active, a live demonstration, a person without '
  'administration.roles today, a forged header naming another organisation''s persona and an ordinary '
  'organisation are each the person; the account-wide choice is read by nothing.';

create or replace function erp_test.assert_act_as_per_tab_suite()
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
    from erp_test.act_as_per_tab_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_ACT_AS_PER_TAB_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A browser tab would act as somebody it may not, or one tab''s choice would reach another. Read the case that failed.';
  end if;
  if v_total <> 11 then
    raise exception 'CLOVEERP_ACT_AS_PER_TAB_SUITE_SHRANK: % case(s), expected 11', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('act as per tab: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_act_as_per_tab_suite() from public, anon;

comment on function erp_test.assert_act_as_per_tab_suite() is
  'Act as is per browser tab, and a header never acts as anybody the rules of 20261006152000 and 20261006153000 '
  'refuse (20261010030000).';

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
