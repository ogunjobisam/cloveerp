set lock_timeout = '30s';

-- =============================================================================
-- 20261006153000  Acting as somebody else ends cleanly, and names who acted
-- -----------------------------------------------------------------------------
-- Found by an adversarial review of the three migrations before this one
-- (20261006150000-152000, J-46), before they reached production. Five things
-- were wrong:
--
--   1. Losing your roles did not end your act. A visitor acting as Priya
--      whose grants were removed stayed Priya, kept her permissions, and
--      could not go back: going back asked for administration.roles, which
--      they no longer held, and the menu offered nobody.
--   2. A demonstration renamed off demo- (erp.set_tenant_address) or taken
--      live (erp.go_live) kept its persona and everybody's choice of her.
--      Live assurance would then refuse it, and nothing could remove them:
--      going back was refused outside a demonstration, and deleting the
--      persona fired the choice trigger through its foreign key.
--   3. An administrator could invite Priya's address, and another account
--      could claim it, giving the persona a sign-in.
--   4. The audit trail and the access log named only Priya, so two people
--      acting as her at once could not be told apart.
--   5. erp.tenant_code_refusal() let any caller give an organisation a demo-
--      address. Only the rename door refused one; the platform's own
--      onboarding passed straight through.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.principal_context() answers the persona only while the person who
--      signed in still holds administration.roles, judged as themselves.
--      erp.act_as_persona(null), going back to yourself, needs no permission
--      and works anywhere; choosing somebody needs the grant as yourself.
--   B. The persona trigger refuses only a row, or a choice of somebody,
--      outside a demonstration. Going back to yourself, and deleting, is
--      never refused.
--   C. erp.retire_demonstration_personas(): when an organisation stops being
--      a demonstration (its address no longer demo-, or it goes live), in
--      the same statement every choice is cleared, every persona row is
--      removed and the persona is disabled. Fired by a trigger on erp.tenant
--      (a change of address) and on erp.environment (going live). Retiring
--      rather than refusing: the organisation's administrator has no way to
--      remove a persona, so a refusal would leave them stuck.
--   D. erp.invite_principal() and erp.claim_invitation() refuse a persona:
--      CLOVEERP_PERSONA_CANNOT_SIGN_IN.
--   E. erp.persona_acted_by(): "acted by <name>, <id>" of the person who
--      signed in, where a persona acts. erp.audit_row_change() adds it to
--      actor_label and erp.log_access_decision() to reason. No column is
--      added: both tables take a write on every request, and altering them
--      would queue every one behind the deploy.
--   F. erp.tenant_code_refusal() refuses a demo- address to the application
--      (any login that does not bypass row security, the platform's own
--      onboarding included), except inside erp.seed_demo(), which says so
--      for its one insert (erp.seeding_demonstration, transaction-local).
--      The deploy, a worker or a test fixture, whose login bypasses row
--      security, is unchanged: suites make demo- organisations directly.
--   G. erp_test.persona_switch_suite case 9 now expects going back to
--      yourself to work outside a demonstration; erp_test.persona_safety_suite,
--      six cases, proves A to F.
--
-- On production: three functions on the sign-in path are replaced
-- (erp.principal_context, erp.act_as_persona, erp.tenant_code_refusal),
-- with erp.audit_row_change, erp.log_access_decision, erp.invite_principal,
-- erp.claim_invitation and erp.seed_demo. Two triggers are created, on
-- erp.tenant and erp.environment (quiet tables; a trigger takes a lock that
-- waits for writers, never for readers). No row is written; no hot table is
-- altered.
-- =============================================================================

select erp.register_refusal('CLOVEERP_PERSONA_CANNOT_SIGN_IN',
  'Inviting a demonstration''s persona, or signing in as one.',
  'A persona is somebody visitors act as. If somebody could sign in as her, what the records say she did might be what one person did alone.',
  'Invite the person under their own address. To act as the persona, choose Act as in the account menu.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Only while the person who signed in may choose; going back always works
-- ─────────────────────────────────────────────────────────────────────────────

do $context$
declare
  v_sig  constant text := 'erp.principal_context()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$       and pu.auth_user_id is null
       and not exists (select 1 from erp.environment e
                        where e.tenant_id = dp.tenant_id and e.is_self and e.is_live);
$o$;
  v_new  constant text := $n$       and pu.auth_user_id is null
       and not exists (select 1 from erp.environment e
                        where e.tenant_id = dp.tenant_id and e.is_self and e.is_live)
       -- And only while the person who signed in may still choose
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
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already asks the person who signed in; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '42fb21445b9226f4016f563422f2cdcf' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$context$;

do $act$
declare
  v_sig  constant text := 'erp.act_as_persona(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already lets anybody go back; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '34817da14e7839aa9f0091203e196631' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  execute $f$
create or replace function erp.act_as_persona(p_persona_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $b$
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
  v_self := erp.current_principal_id();

  -- Going back to yourself needs no permission and is refused nowhere
  -- (20261006153000): somebody whose roles were removed, or whose
  -- organisation stopped being a demonstration, can always stop.
  if p_persona_id is null then
    update erp.demonstration_persona_choice c
       set persona_id = null, chosen_at = now()
     where c.tenant_id = v_tenant and c.app_user_id = v_self
       and c.persona_id is not null;
    perform set_config('erp.persona_set_aside', v_prev, true);
    return public.erp_demonstration_personas();
  end if;

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

  insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
  values (v_tenant, v_self, p_persona_id, now())
  on conflict (tenant_id, app_user_id)
  do update set persona_id = excluded.persona_id, chosen_at = excluded.chosen_at;

  perform set_config('erp.persona_set_aside', v_prev, true);
  return public.erp_demonstration_personas();
end;
$b$;
$f$;
end
$act$;

comment on function erp.act_as_persona(uuid) is
  'Act as one of a demonstration''s people, or as yourself again with null (20261006152000, J-46). '
  'Choosing somebody authorises administration.roles, held as the person who signed in, and only in a '
  'demonstration; going back needs nothing and works anywhere (20261006153000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Refuse somebody chosen outside a demonstration, never somebody released
-- ─────────────────────────────────────────────────────────────────────────────

do $trigger$
declare
  v_sig  constant text := 'erp.refuse_persona_outside_demonstration()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already lets a choice be cleared; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'cb5b26a451c7393f55f1370dbfed6038' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  execute $f$
create or replace function erp.refuse_persona_outside_demonstration()
returns trigger
language plpgsql
set search_path = ''
as $b$
begin
  -- Somebody to act as exists only in a demonstration (20261006150000), and
  -- is somebody who cannot sign in: acting as a person who can would put
  -- your acts in the name of somebody real.
  --
  -- Going back to yourself is never refused (20261006153000): a choice
  -- cleared, by the person or by a persona's removal through the foreign
  -- key, is how an organisation that stopped being a demonstration is left
  -- with nobody acting as anybody. Deleting is not refused either; this
  -- trigger does not fire on it.
  if tg_table_name = 'demonstration_persona_choice' and tg_op = 'UPDATE' then
    if new.persona_id is null then
      return new;
    end if;
  end if;
  if not erp.tenant_is_demonstration(new.tenant_id)
     or exists (select 1 from erp.environment e
                 where e.tenant_id = new.tenant_id and e.is_self and e.is_live) then
    raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: % is not a demonstration', new.tenant_id
      using errcode = '42501',
            hint = 'Sign in as yourself. To show a step that needs two people, open a demonstration and choose Act as in the account menu.';
  end if;
  if tg_table_name = 'demonstration_persona'
     and not exists (select 1 from erp.app_user u
                      where u.tenant_id = new.tenant_id and u.id = new.app_user_id
                        and u.kind = 'person'::erp.principal_kind
                        and u.auth_user_id is null) then
    raise exception 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION: % can sign in, or is not a person', new.app_user_id
      using errcode = '42501',
            hint = 'Only a person of the demonstration who cannot sign in may be acted as.';
  end if;
  return new;
end;
$b$;
$f$;
end
$trigger$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. An organisation that stops being a demonstration has no persona
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
  -- choice is cleared, every persona row removed and the persona disabled,
  -- in the statement that changed it. A definer, because the address may be
  -- changed from the platform console, outside the organisation's rows.
  if erp.tenant_is_demonstration(p_tenant_id)
     and not exists (select 1 from erp.environment e
                      where e.tenant_id = p_tenant_id and e.is_self and e.is_live) then
    return 0;
  end if;

  update erp.demonstration_persona_choice c
     set persona_id = null, chosen_at = now()
   where c.tenant_id = p_tenant_id and c.persona_id is not null;

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
  'Retires a demonstration''s personas once the organisation is no longer a demonstration: choices cleared, '
  'persona rows removed, the person disabled (20261006153000).';

create or replace function erp.retire_personas_with_the_demonstration()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- A change of address, or going live, may end a demonstration (20261006153000).
  if tg_table_name = 'tenant' then
    perform erp.retire_demonstration_personas(new.id);
  else
    perform erp.retire_demonstration_personas(new.tenant_id);
  end if;
  return null;
end;
$$;

revoke all on function erp.retire_personas_with_the_demonstration() from public, anon;

comment on function erp.retire_personas_with_the_demonstration() is
  'After an organisation''s address changes or it goes live, retires the personas of what is no longer a '
  'demonstration (20261006153000).';

drop trigger if exists t_tenant_retires_personas on erp.tenant;
create trigger t_tenant_retires_personas
  after update of code on erp.tenant
  for each row when (old.code is distinct from new.code)
  execute function erp.retire_personas_with_the_demonstration();

drop trigger if exists t_environment_retires_personas on erp.environment;
create trigger t_environment_retires_personas
  after update of is_live on erp.environment
  for each row when (new.is_self and new.is_live and old.is_live is distinct from new.is_live)
  execute function erp.retire_personas_with_the_demonstration();

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'retire_demonstration_personas',
   'Run by a trigger when an organisation stops being a demonstration, which the platform console may cause '
   'from outside the organisation''s rows. Takes nothing from its caller but the organisation, does nothing '
   'while it is still a demonstration, and only clears choices, removes persona rows and disables personas.')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. A persona is never invited, and never signed in as
-- ─────────────────────────────────────────────────────────────────────────────

do $invite$
declare
  v_sig  constant text := 'erp.invite_principal(text,text,interval)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    if v_kind <> 'person' then
      raise exception
        'CLOVEERP_VALIDATION: % belongs to a machine account, not a person', p_email;
    end if;
$o$;
  v_new  constant text := $n$    if v_kind <> 'person' then
      raise exception
        'CLOVEERP_VALIDATION: % belongs to a machine account, not a person', p_email;
    end if;

    -- A demonstration's persona is acted as, never signed in as (20261006153000).
    if exists (select 1 from erp.demonstration_persona dp
                where dp.tenant_id = v_tenant and dp.app_user_id = v_user) then
      raise exception
        'CLOVEERP_PERSONA_CANNOT_SIGN_IN: % is a person this demonstration is acted as, and is not invited', p_email
        using errcode = '42501',
              hint = 'Invite the person under their own address. To act as the persona, choose Act as in the account menu.';
    end if;
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already refuses a persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '5d7e6fc8c8ecf5b6545beffbc8253f72' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$invite$;

do $claim$
declare
  v_sig  constant text := 'erp.claim_invitation(text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  update erp.app_user
     set auth_user_id = v_subject, status = 'active'
   where tenant_id = inv.tenant_id and id = inv.app_user_id
     and auth_user_id is null;
$o$;
  v_new  constant text := $n$  -- A demonstration's persona is acted as, never signed in as (20261006153000).
  if exists (select 1 from erp.demonstration_persona dp
              where dp.tenant_id = inv.tenant_id and dp.app_user_id = inv.app_user_id) then
    raise exception
      'CLOVEERP_PERSONA_CANNOT_SIGN_IN: that invitation is for a person this demonstration is acted as'
      using errcode = '42501',
            hint = 'Invite the person under their own address. To act as the persona, choose Act as in the account menu.';
  end if;

  update erp.app_user
     set auth_user_id = v_subject, status = 'active'
   where tenant_id = inv.tenant_id and id = inv.app_user_id
     and auth_user_id is null;
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already refuses a persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'f07df6e138acb3fc308df697fb33870f' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$claim$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The audit trail and the access log say who was acting
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.persona_acted_by(p_actor uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- Where a demonstration's persona acts, the person who signed in and chose
  -- her (20261006153000): their name and principal, so two people acting as
  -- her at once are told apart. Null for anybody acting as themselves.
  select format('acted by %s, %s', u.display_name, u.id)
    from erp.app_user u
   where u.id = erp.signed_in_principal_id()
     and u.id is distinct from p_actor
     and exists (select 1 from erp.demonstration_persona dp where dp.app_user_id = p_actor)
$$;

revoke all on function erp.persona_acted_by(uuid) from public, anon;

comment on function erp.persona_acted_by(uuid) is
  'Who signed in and acted as a demonstration''s persona, for the audit trail and the access log (20261006153000).';

do $audit$
declare
  v_sig  constant text := 'erp.audit_row_change()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_actor is not null then
    select u.kind, u.display_name into v_kind, v_label
      from erp.app_user u where u.id = v_actor;
$o$;
  v_new  constant text := $n$  if v_actor is not null then
    select u.kind, u.display_name into v_kind, v_label
      from erp.app_user u where u.id = v_actor;
    -- Where a demonstration's persona acted, who was at the keyboard
    -- (20261006153000): two visitors acting as her are told apart.
    if exists (select 1 from erp.demonstration_persona dp where dp.app_user_id = v_actor) then
      v_label := concat_ws(' ', v_label, '(' || erp.persona_acted_by(v_actor) || ')');
    end if;
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already names who acted as a persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '3cc7a94851c0e3dc67c969e32302f118' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$audit$;

do $access$
declare
  v_sig  constant text := 'erp.log_access_decision(text,boolean,uuid,uuid,text,text,uuid,text,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$declare
  v_tenant uuid := erp.require_tenant_id();
begin
  insert into erp.access_log (
    tenant_id, app_user_id, permission_code, entity_id, site_id, data_class,
    granted, object_type, object_id, reason, correlation_id)
  values (
    v_tenant, erp.current_principal_id(), p_permission_code, p_entity_id,
    p_site_id, p_data_class, p_granted, p_object_type, p_object_id, p_reason,
    p_correlation_id);
$o$;
  v_new  constant text := $n$declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
  v_reason text := p_reason;
begin
  -- Where a demonstration's persona is asked, who was at the keyboard
  -- (20261006153000), after the reason.
  if v_actor is not null
     and exists (select 1 from erp.demonstration_persona dp where dp.app_user_id = v_actor) then
    v_reason := concat_ws('; ', p_reason, erp.persona_acted_by(v_actor));
  end if;
  insert into erp.access_log (
    tenant_id, app_user_id, permission_code, entity_id, site_id, data_class,
    granted, object_type, object_id, reason, correlation_id)
  values (
    v_tenant, v_actor, p_permission_code, p_entity_id,
    p_site_id, p_data_class, p_granted, p_object_type, p_object_id, v_reason,
    p_correlation_id);
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already names who acted as a persona; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '11a27cdbf99ef3613987a2fd32231112' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$access$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Only the demonstration seed gives an organisation a demo- address
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.demo_address_refusal(p_code text, p_session_role name)
returns text
language sql
stable
set search_path = ''
as $$
  -- demo- marks the product's own demonstrations, and a demonstration is
  -- where somebody may be acted as (20261006153000). Only erp.seed_demo()
  -- gives one to an organisation through the application; a connection
  -- whose own login bypasses row security (the deploy, a worker, a test
  -- fixture) may too. Asked of the login (session_user), not of the role a
  -- definer runs as: the application signs in as a role that does not
  -- bypass row security, whatever function it is inside.
  select case
    when p_code like 'demo-%'
     and coalesce(current_setting('erp.seeding_demonstration', true), '') <> 'yes'
     and not coalesce((select r.rolbypassrls from pg_catalog.pg_roles r
                        where r.rolname = p_session_role), false) then
      'CLOVEERP_ADDRESS_RESERVED: "' || p_code || '" starts with "demo-", which marks the product''s own '
      || 'demonstration organisations; only the demonstration seed makes one'
  end
$$;

revoke all on function erp.demo_address_refusal(text, name) from public, anon;

comment on function erp.demo_address_refusal(text, name) is
  'Refuses a demo- address to the application, except inside erp.seed_demo(); a login that bypasses row '
  'security (the deploy, a worker, a fixture) is not refused (20261006153000). Read by erp.tenant_code_refusal().';

do $code$
declare
  v_sig  constant text := 'erp.tenant_code_refusal(text,uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      || ' is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit'
$o$;
  v_new  constant text := $n$      || ' is not an address: use three to 63 lower-case letters, digits and hyphens, starting and ending with a letter or digit'
    -- Only the demonstration seed gives the application a demo- address
    -- (20261006153000); see erp.demo_address_refusal().
    when erp.demo_address_refusal(p_code, session_user) is not null then
      erp.demo_address_refusal(p_code, session_user)
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already refuses demo- addresses; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '0f9967ba06225598f6ecda1dc595343e' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$code$;

do $seed$
declare
  v_sig  constant text := 'erp.seed_demo()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  insert into erp.tenant (code, name, status, provisioned_at)
  values ('demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
$o$;
  v_new  constant text := $n$  -- The demonstration seed is the one way somebody signed in gives an
  -- organisation a demo- address (20261006153000); said for this insert only.
  perform set_config('erp.seeding_demonstration', 'yes', true);
  insert into erp.tenant (code, name, status, provisioned_at)
  values ('demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
$n$;
  v_old2 constant text := $o$  returning id into v_tenant_id;

  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
$o$;
  v_new2 constant text := $n$  returning id into v_tenant_id;
  perform set_config('erp.seeding_demonstration', '', true);

  insert into erp.environment (tenant_id, code, name, kind, is_live, is_self,
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already says it is seeding; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '1fc4ed1deab0390ef90d938ed088d347' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old2, v_new2);
end
$seed$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- persona_switch_suite case 9: outside a demonstration choosing somebody is
-- refused, and going back to yourself works.
do $switch$
declare
  v_sig  constant text := 'erp_test.persona_switch_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$    begin perform public.erp_act_as_persona(null); v_err := 'acting';
    exception when others then v_err := sqlerrm; end;
$o$;
  v_new1 constant text := $n$    -- Choosing somebody is refused here; going back to yourself is not
    -- (20261006153000): stopping is never refused.
    begin perform public.erp_act_as_persona(gen_random_uuid()); v_err := 'acting';
    exception when others then v_err := sqlerrm; end;
    v_back := public.erp_act_as_persona(null);
$n$;
  v_old2 constant text := $o$    case_name := 'in an organisation that is not a demonstration Act as is refused, and a choice cannot be written';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
$o$;
  v_new2 constant text := $n$    case_name := 'in an organisation that is not a demonstration choosing somebody is refused and a choice cannot be written, but going back to yourself works';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERSONA_OUTSIDE_DEMONSTRATION%'
          and v_back -> 'acting_as' = 'null'::jsonb
$n$;
begin
  if strpos(v_src, '20261006153000') > 0 then
    raise notice '% already expects going back to work anywhere; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '2078066a11e715abf386abbef333d2e2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006153000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$switch$;

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
begin
  begin
    -- ── The fixture: a demonstration with two administrators ────────────────
    v_step := 'a demonstration with two administrators';
    perform set_config('request.jwt.claims', '', true);
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
    res := public.erp_invite_principal('second@demo-zzsf' || v_tag || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_second, 'administrator', null, null, 'second');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');

    -- ── 1. Roles removed, the act ends and going back works ─────────────────
    v_step := 'the second administrator acts as Priya and loses their roles';
    execute 'set local role authenticated';
    perform public.erp_act_as_persona(v_priya);
    v_a := erp.current_principal_id();
    execute 'reset role';
    delete from erp.user_role where tenant_id = ra.tenant_id and app_user_id = v_second;
    execute 'set local role authenticated';
    v_b := erp.current_principal_id();
    v_ok1 := erp.has_permission('finance.approve_payment');
    v_menu := public.erp_demonstration_personas();
    v_back := public.erp_act_as_persona(null);
    execute 'reset role';
    v_cases := v_cases + 1;
    case_name := 'somebody acting as the persona whose roles are removed is themselves again at once, holds nothing of hers, and can go back without any permission';
    passed := v_state is null
          and v_a = v_priya and v_b = v_second and not v_ok1
          and v_menu -> 'acting_as' = 'null'::jsonb
          and v_back -> 'acting_as' = 'null'::jsonb
          and not exists (select 1 from erp.demonstration_persona_choice c
                           where c.tenant_id = ra.tenant_id and c.app_user_id = v_second
                             and c.persona_id is not null);
    detail := coalesce(v_state, format('chosen %s, after removal %s, finance.approve_payment %s', v_a, v_b, v_ok1));
    return next;

    -- Their roles back, for what follows.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(v_second, 'administrator', null, null, 'second again');

    -- ── 2. Two people acting as her at once are told apart ──────────────────
    v_step := 'both administrators act as Priya and each writes';
    perform public.erp_act_as_persona(v_priya);
    v_s1 := erp_test.cash_payment_supplier('ZSFA' || v_tag);
    perform erp.authorise('finance.read', null, null, null, 'party', v_s1);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_act_as_persona(v_priya);
    v_s2 := erp_test.cash_payment_supplier('ZSFB' || v_tag);
    perform erp.authorise('finance.read', null, null, null, 'party', v_s2);
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
    v_a := erp.current_principal_id();
    v_back := public.erp_act_as_persona(null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin delete from erp.app_user where tenant_id = ra.tenant_id and id = v_priya; v_err := 'deleted';
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a demonstration renamed off demo- keeps nobody to act as: choices cleared, persona retired, going back works, and she can be removed';
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
    res := public.erp_invite_principal('second@demo-zzsg' || v_tag || '.test', 'Second Live Admin');
    v_second_g := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_second_g, 'administrator', null, null, 'second');
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform public.erp_act_as_persona(v_priya_g);
    v_a := erp.current_principal_id();
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    v_step := 'going live';
    perform erp.go_live();
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    v_b := erp.current_principal_id();
    v_cases := v_cases + 1;
    case_name := 'a demonstration that goes live keeps nobody to act as: choices cleared, persona retired and disabled, and the assertion is clean';
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
  'Acting as somebody else ends cleanly and names who acted (20261006153000): roles removed ends the act and '
  'going back needs nothing; two visitors told apart in the audit trail and access log; the persona never '
  'invited or claimed; renamed or gone live, the persona retired; demo- addresses only from the seed.';

create or replace function erp_test.assert_persona_safety_suite()
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
    from erp_test.persona_safety_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PERSONA_SAFETY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'Acting as a demonstration''s persona would outlast the right to, outlive the demonstration, or hide who acted. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_PERSONA_SAFETY_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('persona safety: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_persona_safety_suite() from public, anon;

comment on function erp_test.assert_persona_safety_suite() is
  'Acting as a demonstration''s persona ends when it should, and the records say who acted (20261006153000).';

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
