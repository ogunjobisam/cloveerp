-- Duties stay separated.
--
-- The base pack ships eight segregation-of-duties rules (§3.3) and the regulated
-- profile a ninth, each two sets of permissions that must not meet in one
-- person. A static walk through every persona (14 September) said the rules
-- were data nothing evaluated. Each finding was checked against the
-- definitions the database carries after every patch before this file was
-- written, and each was true:
--
--   1. erp.detect_sod_conflicts() (0003) has no caller. No migration, screen,
--      Edge Function or worker names it, and no patch since added a call.
--   2. Nothing reads erp.sod_conflict except that function. No public door
--      reads it, and the desk never names it.
--   3. Neither grant path asks. erp.grant_role() (0041) and
--      public.erp_set_user_roles() (20260910135355) authorise
--      administration.roles and insert; neither reads a rule, and neither
--      refuses somebody changing their own roles. Two more doors on the same
--      screen do the same: public.erp_grant_role() (20260829180000) inserts a
--      grant directly, and public.erp_revoke_role() deletes one.
--   4. "Unticked: the grant ends today", says erp_set_user_roles, and then it
--      deletes the row, as erp_revoke_role does. Who held what, and until
--      when, was lost.
--   5. The base pack's templates break the pack's own prohibited rules:
--      finance_manager holds finance.post and finance.close_period (POST_CLOSE),
--      procurement_manager procurement.requisition and procurement.approve
--      (RAISE_APPROVE_REQ), quality_manager and responsible_person
--      quality.disposition and quality.release_batch (AMEND_RELEASE_BATCH).
--      20260914061500 changed the warehouse templates and DELIVER_INVOICE, and
--      neither warehouse template breaks a prohibited rule.
--   6. So do the module roles, as erp.standard_role_permissions() stands after
--      20260914061500: purchasing holds all of procurement (RAISE_APPROVE_REQ,
--      APPROVE_RECEIVE_PO), finance all of finance (POST_CLOSE), quality all of
--      quality (AMEND_RELEASE_BATCH, and the regulated INSPECT_AND_RELEASE).
--      Inventory holds adjust and write_off (ADJUST_APPROVE_STOCK) and sales
--      holds sales.despatch and sales.invoice (DELIVER_INVOICE since
--      20260914061500 named sales.despatch); both rules are material.
--
-- What this file does, in order:
--
--   1. What a person holds against the rules. erp.duty_conflicts(tenant,
--      person) lists, per person and active rule, the permissions of each side
--      they hold through grants not yet ended, in overlapping scopes and
--      overlapping dates, so a grant dated to start next week counts now.
--
--      The organisation's administrator is not a conflict. Provisioning gives
--      role administrator every permission, installers route approvals to it,
--      go-live needs two people holding it and platform support enters as it:
--      holding everything is what the role is for. Evaluated naively it would
--      meet every rule, every administrator would stand on the list for good,
--      and a second administrator could never be appointed in a live
--      organisation. So a rule is not met by a person when an organisation-wide
--      grant of the role coded administrator gives them both sides of that rule
--      by itself. The provisioned administrator holds both sides of every rule
--      and is never flagged. An administrator narrowed to administration (the
--      base pack's template, or an organisation's own edit) holds neither side
--      of POST_CLOSE, so an administrator who also posts journals through
--      another role is still caught, by GRANT_AND_USE. Exempting rather than
--      reporting was chosen because a list that can never be clear is a list
--      nobody reads; who holds administrator is still named on the screen, the
--      grant is audited, and nobody gives it to themselves once live.
--
--   2. Granting evaluates the rules for the person's resulting permissions.
--      erp.grant_role(), public.erp_set_user_roles(), public.erp_grant_role()
--      and public.erp_revoke_role() capture what the person met before the
--      change and settle it after, through erp.settle_duties():
--        * In a live organisation a prohibited pairing the change introduces
--          is refused, CLOVEERP_SOD_PROHIBITED, naming the person, the rule and
--          both permissions in words, and saying how to proceed.
--        * p_sod_override_reason records a documented exception instead. The
--          reason needs twenty characters (CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT)
--          and the caller needs administration.promote: granting is
--          administration.roles, accepting a prohibited pairing is a
--          governance decision. The exception is the table the specification
--          already built for it: an erp.sod_conflict row with status accepted,
--          the reason in mitigation_note and the decider in reviewed_by, which
--          the audit trigger records like every other row. It covers that
--          person and rule until the pairing ends, when it is resolved; a
--          pairing that returns needs a new decision.
--        * A material or advisory pairing is allowed and recorded as an open
--          conflict to review.
--        * Before go-live nothing is refused: one person often sets everything
--          up. Every pairing is recorded and reported.
--        * A pairing somebody already held before the change is not
--          introduced by it, so an unrelated grant is not refused over it; it
--          is recorded if it was not.
--      The public grant doors return the person's conflicts as they stand.
--
--      Nobody changes their own roles in a live organisation
--      (CLOVEERP_SOD_SELF_GRANT), through any of the four.
--
--      erp_set_user_roles and erp_grant_role gain p_sod_override_reason, so
--      each is dropped and created again, and so is erp.grant_role; the Part 5
--      register names its new signature. erp_set_user_roles now writes its
--      grants itself and settles once, so a swap that keeps a pairing the
--      person already held is judged as the whole change, not role by role.
--
--      A role whose permissions change settles every person holding it: the
--      role arm of erp.apply_change_set_item() (patched by counted replacement
--      around the text 20260914061500 left) and public.erp_save_role(). A
--      promoted change that introduces a prohibited pairing for a holder in a
--      live organisation is refused; the hint says to take the role from them
--      first. A rollback records and never refuses: it restores what was
--      there, and an emergency undo must not be held up.
--      erp.detect_sod_conflicts() becomes the organisation-wide recording pass
--      on the same rules, refusing nothing.
--
--   3. Grants end rather than disappear. erp.end_grant() does to one grant
--      what 20260914020000's erp.end_principal_grants() does to a person's: a
--      grant begun before today ends yesterday and stays on file; one begun
--      today or later cannot end before it begins (user_role_range), so it is
--      withdrawn and the audit stream keeps the row.
--
--   4. A read door. public.erp_sod_conflicts(), under administration.audit_read,
--      lists every current conflict: person, rule, severity, both sides'
--      permission codes, and the recorded status with any exception's reason,
--      decider and date; and names the people exempt as administrators. People
--      and permissions shows it, names permissions through permissionName, and
--      offers the reason for an exception after a refusal, only to somebody
--      holding administration.promote.
--
--   5. The templates keep no prohibited pairing. Base pack items are edited in
--      place, as 20260914061500 did: procurement_manager loses
--      procurement.requisition (the buyer raises, the manager approves),
--      finance_manager loses finance.post (a controller who closes periods and
--      approves payments does not post; the finance clerk does),
--      quality_manager loses quality.release_batch and responsible_person
--      quality.disposition (the manager dispositions, the Responsible Person
--      releases). The module roles: purchasing without procurement.approve and
--      procurement.receive (the warehouse receives, since 20260914061500),
--      finance without finance.close_period and finance.reopen_period, quality
--      without quality.release_batch. Inventory keeps adjust and write_off and
--      sales keeps despatch and invoice: both pairings are material and are
--      recorded when granted. 062000's approver default is untouched:
--      procurement_manager still holds procurement.approve, and the third
--      bands still name finance_manager, who still approves payments.
--
--      No organisation's roles are rewritten. Seeding never rewrites a role,
--      and re-applying the base pack plans a role only while it lacks a
--      permission the template grants, so a template-made role that holds more
--      than its template keeps it. Those conflicts show on the screen.
--
--   6. The suites. erp_test.approval_hold_suite gave the first administrator
--      purchasing and sales as that administrator, in a live organisation: the
--      second administrator gives them now. No other suite, seeder or fixture
--      grants itself a role in a live organisation or meets a rule outside an
--      administrator (the demonstration is never live, and support and
--      provisioning grants administrator directly).
--
-- Proof: erp_test.duties_separated_suite(), fifteen cases, pinned by its
-- wrapper; and the suites this touches, run again at the end.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What a person holds against the rules
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.duty_conflicts(p_tenant uuid, p_app_user_id uuid default null)
returns table (app_user_id uuid, sod_rule_id uuid, rule_code text, rule_name text,
               severity erp.sod_severity, permissions_a text[], permissions_b text[])
language sql
stable
security invoker
set search_path = ''
as $$
  with held as (
    -- Every permission each person holds through a grant that has not ended,
    -- with the grant's scope and dates: a grant that starts next week is a
    -- pairing somebody decided on today.
    select ur.app_user_id as person, rp.permission_code as code,
           ur.entity_id as entity, ur.site_id as site,
           ur.valid_from as held_from, coalesce(ur.valid_to, 'infinity'::date) as held_to
      from erp.user_role ur
      join erp.role r
        on r.tenant_id = ur.tenant_id and r.id = ur.role_id and r.status = 'active'
      join erp.role_permission rp
        on rp.tenant_id = r.tenant_id and rp.role_id = r.id
     where ur.tenant_id = p_tenant
       and (p_app_user_id is null or ur.app_user_id = p_app_user_id)
       and (ur.valid_to is null or ur.valid_to >= current_date)
  ),
  administrator as (
    -- The organisation's administrator role, held for the whole organisation.
    select distinct ur.app_user_id as person, r.id as role_id
      from erp.user_role ur
      join erp.role r
        on r.tenant_id = ur.tenant_id and r.id = ur.role_id
       and r.status = 'active' and r.code = 'administrator'
     where ur.tenant_id = p_tenant
       and (p_app_user_id is null or ur.app_user_id = p_app_user_id)
       and ur.entity_id is null and ur.site_id is null
       and (ur.valid_to is null or ur.valid_to >= current_date)
  )
  select a.person, sr.id, sr.code, sr.name, sr.severity,
         array_agg(distinct a.code order by a.code),
         array_agg(distinct b.code order by b.code)
    from erp.sod_rule sr
    join held a
      on a.code = any (sr.permissions_a)
    join held b
      on b.person = a.person
     and b.code = any (sr.permissions_b)
     and (a.entity is null or b.entity is null or a.entity = b.entity)
     and (a.site is null or b.site is null or a.site = b.site)
     and a.held_from <= b.held_to and b.held_from <= a.held_to
   where sr.tenant_id = p_tenant
     and sr.status = 'active'
     -- Not met by a person whose administrator role holds both sides by itself.
     and not exists (
       select 1
         from administrator ad
        where ad.person = a.person
          and exists (select 1 from erp.role_permission rp
                       where rp.tenant_id = p_tenant and rp.role_id = ad.role_id
                         and rp.permission_code = any (sr.permissions_a))
          and exists (select 1 from erp.role_permission rp
                       where rp.tenant_id = p_tenant and rp.role_id = ad.role_id
                         and rp.permission_code = any (sr.permissions_b)))
   group by a.person, sr.id, sr.code, sr.name, sr.severity
$$;
revoke all on function erp.duty_conflicts(uuid, uuid) from public, anon, authenticated;

comment on function erp.duty_conflicts(uuid, uuid) is
  'Per person (or one person) and active segregation rule of the organisation, '
  'the permissions of each side the person holds through grants not yet ended, '
  'in overlapping scopes and dates. A rule is not met by a person whose '
  'organisation-wide administrator role holds both of its sides by itself: the '
  'administrator holds every permission by design (20260914065000).';

create or replace function erp.require_not_own_roles(p_tenant uuid, p_app_user_id uuid)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_app_user_id is not null
     and p_app_user_id = erp.current_principal_id()
     and erp.tenant_is_live(p_tenant) then
    raise exception 'CLOVEERP_SOD_SELF_GRANT: you cannot change your own roles once the organisation is live'
      using errcode = '42501',
            hint = 'Ask another administrator who may administer roles to change them. Nobody gives themselves access in a live organisation, so every grant has a second person behind it.';
  end if;
end;
$$;
revoke all on function erp.require_not_own_roles(uuid, uuid) from public, anon, authenticated;

comment on function erp.require_not_own_roles(uuid, uuid) is
  'Refuses CLOVEERP_SOD_SELF_GRANT when the caller is the person whose roles '
  'are about to change and the organisation is live. Before go-live one person '
  'sets everything up, and may.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Settling a change: refuse, record, resolve
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.settle_duties(
  p_tenant          uuid,
  p_app_user_id     uuid,
  p_before          uuid[],
  p_override_reason text,
  p_change          text,
  p_kind            text
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  -- grant: a person is given a role. role: a role a person holds changed.
  -- review: record what stands and refuse nothing (a rollback, the
  -- organisation-wide pass).
  v_enforce    boolean := p_kind in ('grant', 'role') and erp.tenant_is_live(p_tenant);
  v_reason     text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_person     text;
  v_names_a    text;
  v_names_b    text;
  v_current    uuid[] := '{}'::uuid[];
  v_out        jsonb := '[]'::jsonb;
  v_rec_id     uuid;
  v_rec_status text;
  v_rec_note   text;
  v_found      boolean;
  c            record;
begin
  if p_kind not in ('grant', 'role', 'review') then
    raise exception 'CLOVEERP_DUTIES_KIND_UNKNOWN: % is not a way duties are settled', p_kind
      using hint = 'Pass grant, role or review.';
  end if;

  select coalesce(nullif(btrim(u.display_name), ''), u.email, 'This person')
    into v_person
    from erp.app_user u
   where u.tenant_id = p_tenant and u.id = p_app_user_id;

  for c in
    select d.sod_rule_id, d.rule_code, d.rule_name, d.severity, d.permissions_a, d.permissions_b
      from erp.duty_conflicts(p_tenant, p_app_user_id) d
     order by d.rule_code
  loop
    v_current := v_current || c.sod_rule_id;

    -- What is on file: an exception first, then an open conflict.
    select sc.id, sc.status::text, sc.mitigation_note
      into v_rec_id, v_rec_status, v_rec_note
      from erp.sod_conflict sc
     where sc.tenant_id = p_tenant
       and sc.app_user_id = p_app_user_id
       and sc.sod_rule_id = c.sod_rule_id
       and sc.status in ('open', 'accepted', 'mitigated')
     order by (sc.status = 'open'), sc.detected_at desc
     limit 1;
    v_found := found;
    if not v_found then
      v_rec_id := null; v_rec_status := null; v_rec_note := null;
    end if;

    if c.severity = 'prohibited'
       and coalesce(v_rec_status, '') not in ('accepted', 'mitigated')
       and (v_reason is not null
            or (v_enforce and not (c.sod_rule_id = any (coalesce(p_before, '{}'::uuid[]))))) then

      if v_reason is null then
        select string_agg(erp.text('permission.' || x), '" or "' order by x) into v_names_a
          from unnest(c.permissions_a) x;
        select string_agg(erp.text('permission.' || x), '" or "' order by x) into v_names_b
          from unnest(c.permissions_b) x;

        if p_kind = 'role' then
          raise exception 'CLOVEERP_SOD_PROHIBITED: %',
            format('%s cannot be given %s, because they would hold both "%s" and "%s", which the rule "%s" keeps apart',
                   v_person, coalesce(p_change, 'this role'), v_names_a, v_names_b, c.rule_name)
            using errcode = '23514',
                  hint = format('The rule "%s" does not let one person hold "%s" and "%s". Take the role from %s before promoting this change, or leave that permission out of the role. An exception is recorded when a role is given to somebody, with the reason for it.',
                                c.rule_name, v_names_a, v_names_b, v_person);
        end if;

        raise exception 'CLOVEERP_SOD_PROHIBITED: %',
          format('%s cannot be given %s, because they would hold both "%s" and "%s", which the rule "%s" keeps apart',
                 v_person, coalesce(p_change, 'this role'), v_names_a, v_names_b, c.rule_name)
          using errcode = '23514',
                hint = format('The rule "%s" does not let one person hold "%s" and "%s". Give %s to somebody else, or first take away what already gives %s the other of the two. If the organisation accepts the risk, somebody who may promote configuration can record an exception by giving the reason for it, in at least twenty characters.',
                              c.rule_name, v_names_a, v_names_b, coalesce(p_change, 'the role'), v_person);
      end if;

      if length(v_reason) < 20 then
        raise exception 'CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT: %',
          format('an exception to "%s" needs its reason in at least twenty characters', c.rule_name)
          using errcode = '22023',
                hint = 'Say why the organisation accepts one person holding both, and what checks the work instead. The reason is kept with the exception and shown to whoever reviews access.';
      end if;

      -- Granting is administration.roles; accepting a prohibited pairing is a
      -- governance decision, taken by somebody who may promote configuration.
      perform erp.authorise('administration.promote', null, null, null, 'sod_rule', c.sod_rule_id);

      if v_found then
        update erp.sod_conflict sc
           set status = 'accepted', mitigation_note = v_reason,
               reviewed_by = erp.current_principal_id(), reviewed_at = now(),
               matched_a = c.permissions_a, matched_b = c.permissions_b, updated_at = now()
         where sc.tenant_id = p_tenant and sc.id = v_rec_id;
      else
        insert into erp.sod_conflict
          (tenant_id, sod_rule_id, app_user_id, matched_a, matched_b,
           status, mitigation_note, reviewed_by, reviewed_at)
        values
          (p_tenant, c.sod_rule_id, p_app_user_id, c.permissions_a, c.permissions_b,
           'accepted', v_reason, erp.current_principal_id(), now());
      end if;
      v_rec_status := 'accepted';
      v_rec_note := v_reason;

    elsif not v_found then
      -- Allowed, and recorded for review.
      insert into erp.sod_conflict (tenant_id, sod_rule_id, app_user_id, matched_a, matched_b)
      values (p_tenant, c.sod_rule_id, p_app_user_id, c.permissions_a, c.permissions_b);
      v_rec_status := 'open';
      v_rec_note := null;

    else
      update erp.sod_conflict sc
         set matched_a = c.permissions_a, matched_b = c.permissions_b, updated_at = now()
       where sc.tenant_id = p_tenant and sc.id = v_rec_id
         and (sc.matched_a is distinct from c.permissions_a
              or sc.matched_b is distinct from c.permissions_b);
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'rule_code', c.rule_code,
      'rule_name', c.rule_name,
      'severity', c.severity,
      'permissions_a', to_jsonb(c.permissions_a),
      'permissions_b', to_jsonb(c.permissions_b),
      'status', v_rec_status,
      'exception_reason', v_rec_note));
  end loop;

  -- A pairing that no longer stands is resolved, and so is its exception: if
  -- it returns, somebody decides again.
  update erp.sod_conflict sc
     set status = 'resolved', updated_at = now()
   where sc.tenant_id = p_tenant
     and sc.app_user_id = p_app_user_id
     and sc.status in ('open', 'accepted', 'mitigated')
     and not (sc.sod_rule_id = any (v_current));

  return v_out;
end;
$$;
revoke all on function erp.settle_duties(uuid, uuid, uuid[], text, text, text) from public, anon, authenticated;

comment on function erp.settle_duties(uuid, uuid, uuid[], text, text, text) is
  'Settles one person''s segregation-of-duties conflicts after a change. p_before '
  'is the rules they met before it. In a live organisation, for a grant or a '
  'role change, a prohibited pairing the change introduces is refused '
  '(CLOVEERP_SOD_PROHIBITED) unless an exception is on file or p_override_reason '
  'records one (twenty characters, administration.promote). Every other pairing '
  'is recorded as an open conflict; pairings that ended are resolved. Returns the '
  'person''s conflicts as they stand. Internal: callers authorise first.';

create or replace function erp.role_duties_before(p_tenant uuid, p_role_code text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(h.person::text, to_jsonb(coalesce(met.rules, '{}'::uuid[]))),
                  '{}'::jsonb)
    from (select distinct ur.app_user_id as person
            from erp.user_role ur
            join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
           where ur.tenant_id = p_tenant
             and r.code = p_role_code
             and (ur.valid_to is null or ur.valid_to >= current_date)) h
    left join lateral (
      select array_agg(d.sod_rule_id) as rules
        from erp.duty_conflicts(p_tenant, h.person) d) met on true
$$;
revoke all on function erp.role_duties_before(uuid, text) from public, anon, authenticated;

comment on function erp.role_duties_before(uuid, text) is
  'Before a role''s permissions change: every person holding it through a grant '
  'not yet ended, keyed by principal, with the rules they meet now.';

create or replace function erp.settle_role_duties(p_tenant uuid, p_before jsonb, p_role_name text, p_kind text)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  h record;
begin
  for h in
    select e.key::uuid as person, e.value as rules
      from jsonb_each(coalesce(p_before, '{}'::jsonb)) e
     order by e.key
  loop
    perform erp.settle_duties(
      p_tenant, h.person,
      array(select x::uuid from jsonb_array_elements_text(h.rules) x),
      null,
      format('the %s role as this change leaves it', coalesce(p_role_name, 'changed')),
      p_kind);
  end loop;
end;
$$;
revoke all on function erp.settle_role_duties(uuid, jsonb, text, text) from public, anon, authenticated;

comment on function erp.settle_role_duties(uuid, jsonb, text, text) is
  'After a role''s permissions changed: settles the duties of every person '
  'erp.role_duties_before() found holding it, as a role change (p_kind role) or '
  'as a record only (review).';

-- Same signature and return type as 0003. The organisation-wide pass, on the
-- same rules as the grant doors: records every conflict that stands, resolves
-- those that ended, refuses nothing.
create or replace function erp.detect_sod_conflicts()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_open   integer;
  r        record;
begin
  for r in
    select ur.app_user_id as person
      from erp.user_role ur
     where ur.tenant_id = v_tenant
    union
    select sc.app_user_id
      from erp.sod_conflict sc
     where sc.tenant_id = v_tenant
       and sc.status in ('open', 'accepted', 'mitigated')
  loop
    perform erp.settle_duties(
      v_tenant, r.person,
      array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, r.person) d),
      null, null, 'review');
  end loop;

  select count(*)::integer into v_open
    from erp.sod_conflict sc
   where sc.tenant_id = v_tenant
     and sc.status in ('open', 'accepted', 'mitigated');
  return v_open;
end;
$$;
revoke all on function erp.detect_sod_conflicts() from public, anon, authenticated;

comment on function erp.detect_sod_conflicts() is
  'Records every segregation-of-duties conflict that stands in the organisation '
  'and resolves those that ended, on the rules the grant doors apply '
  '(erp.settle_duties, 20260914065000). Refuses nothing. Returns how many '
  'conflicts are on file and not resolved.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A grant ends rather than disappears
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.end_grant(p_tenant uuid, p_user_role_id uuid)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_from date;
  v_to   date;
begin
  select ur.valid_from, ur.valid_to
    into v_from, v_to
    from erp.user_role ur
   where ur.tenant_id = p_tenant and ur.id = p_user_role_id
     for update;

  if not found then
    return 'not_found';
  end if;

  if v_to is not null and v_to < current_date then
    return 'already_ended';
  end if;

  -- Begun before today: it ends yesterday, and the record of who held what
  -- stays readable.
  if v_from < current_date then
    update erp.user_role ur
       set valid_to = current_date - 1
     where ur.tenant_id = p_tenant and ur.id = p_user_role_id;
    return 'ended';
  end if;

  -- Begun today, or not begun: it cannot end before it begins
  -- (user_role_range), and ending it today would leave it in force today. It
  -- is withdrawn; the audit stream keeps the row.
  delete from erp.user_role ur
   where ur.tenant_id = p_tenant and ur.id = p_user_role_id;
  return 'withdrawn';
end;
$$;
revoke all on function erp.end_grant(uuid, uuid) from public, anon, authenticated;

comment on function erp.end_grant(uuid, uuid) is
  'Ends one grant, as erp.end_principal_grants() ends a person''s: begun before '
  'today, it ends yesterday and stays on file (ended); begun today or later, it '
  'is deleted with the audit stream keeping the row (withdrawn). Returns ended, '
  'withdrawn, already_ended or not_found. Internal: callers authorise first.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The grant doors
-- ═════════════════════════════════════════════════════════════════════════════

-- The eighth argument changes the signature, which CREATE OR REPLACE cannot do
-- without leaving an overload.
drop function erp.grant_role(uuid, text, uuid, uuid, text, date, date);

create function erp.grant_role(
  p_app_user_id         uuid,
  p_role_code           text,
  p_entity_id           uuid default null,
  p_site_id             uuid default null,
  p_reason              text default null,
  p_valid_from          date default current_date,
  p_valid_to            date default null,
  p_sod_override_reason text default null
) returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_role   uuid;
  v_name   text;
  v_id     uuid;
  v_before uuid[];
begin
  perform erp.authorise('administration.roles', p_entity_id, p_site_id, null,
                        'user_role', null);

  select r.id, coalesce(nullif(btrim(r.name), ''), r.code)
    into v_role, v_name
    from erp.role r
   where r.tenant_id = v_tenant and r.code = p_role_code and r.status = 'active';

  if v_role is null then
    raise exception 'CLOVEERP_UNKNOWN_ROLE: %', p_role_code
      using errcode = '23503',
            hint = 'Choose one of the organisation''s active roles under People and permissions.';
  end if;

  perform erp.require_not_own_roles(v_tenant, p_app_user_id);

  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);

  insert into erp.user_role (tenant_id, app_user_id, role_id, entity_id, site_id,
                             valid_from, valid_to, granted_by, grant_reason)
  values (v_tenant, p_app_user_id, v_role, p_entity_id, p_site_id,
          coalesce(p_valid_from, current_date), p_valid_to, erp.current_principal_id(), p_reason)
  returning id into v_id;

  perform erp.settle_duties(v_tenant, p_app_user_id, v_before, p_sod_override_reason,
                            format('the %s role', v_name), 'grant');

  return v_id;
end;
$$;
revoke all on function erp.grant_role(uuid, text, uuid, uuid, text, date, date, text) from public, anon;

comment on function erp.grant_role(uuid, text, uuid, uuid, text, date, date, text) is
  'Grants a role under administration.roles. Refuses the caller''s own roles '
  'once live, and settles the person''s segregation of duties: a prohibited '
  'pairing the grant introduces in a live organisation is refused unless '
  'p_sod_override_reason records an exception (administration.promote); anything '
  'else is recorded (20260914065000).';

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.grant_role(uuid,text,uuid,uuid,text,date,date)',
                                            'erp.grant_role(uuid,text,uuid,uuid,text,date,date,text)')
 where 'erp.grant_role(uuid,text,uuid,uuid,text,date,date)' = any (artefacts);

update erp_ref.part5_capability
   set artefacts = artefacts || array['erp.duty_conflicts(uuid,uuid)',
                                      'erp.settle_duties(uuid,uuid,uuid[],text,text,text)',
                                      'public.erp_sod_conflicts()']
 where code = '5.11.sod'
   and not ('erp.duty_conflicts(uuid,uuid)' = any (artefacts));

drop function public.erp_set_user_roles(uuid, text[], text);

-- One call sets the whole set a person holds, so combining roles is a single
-- honest write rather than a grant here and a revoke there, and its duties are
-- settled once, against what the person held before the call.
create function public.erp_set_user_roles(
  p_app_user_id         uuid,
  p_role_codes          text[],
  p_reason              text default null,
  p_sod_override_reason text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_codes   text[] := coalesce(p_role_codes, '{}');
  v_to_end  uuid[];
  v_to_add  text[];
  v_before  uuid[];
  v_change  text;
  v_added   integer := 0;
  v_ended   integer := 0;
  v_grant   uuid;
begin
  perform erp.authorise('administration.roles', null, null, null, 'user_role',
                        p_app_user_id);

  if not exists (select 1 from erp.app_user u
                  where u.id = p_app_user_id and u.tenant_id = v_tenant) then
    raise exception 'CLOVEERP_VALIDATION: person not found in this organisation'
      using hint = 'Refresh the list of people. They may belong to another organisation, or the list you acted on is out of date.';
  end if;

  if exists (select 1 from unnest(v_codes) c
              where not exists (select 1 from erp.role r
                                 where r.tenant_id = v_tenant
                                   and r.code = c
                                   and r.status = 'active')) then
    raise exception 'CLOVEERP_UNKNOWN_ROLE: one of those roles does not exist here'
      using errcode = '23503',
            hint = 'Refresh the list of roles and choose again.';
  end if;

  -- Unticked: the organisation-wide grant ends (erp.end_grant). A grant
  -- narrowed to an entity or a site was made deliberately and is left alone.
  select coalesce(array_agg(ur.id order by ur.id), '{}'::uuid[])
    into v_to_end
    from erp.user_role ur
    join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
   where ur.tenant_id = v_tenant
     and ur.app_user_id = p_app_user_id
     and ur.entity_id is null
     and ur.site_id is null
     and (ur.valid_to is null or ur.valid_to >= current_date)
     and not (r.code = any (v_codes));

  -- Ticked and not held today, organisation-wide.
  select coalesce(array_agg(x.code order by x.code), '{}'::text[])
    into v_to_add
    from (select distinct c as code from unnest(v_codes) c) x
   where not exists (
     select 1 from erp.user_role ur join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
      where ur.tenant_id = v_tenant
        and ur.app_user_id = p_app_user_id
        and r.code = x.code
        and ur.entity_id is null and ur.site_id is null
        and ur.valid_from <= current_date
        and (ur.valid_to is null or ur.valid_to >= current_date));

  if cardinality(v_to_end) > 0 or cardinality(v_to_add) > 0 then
    perform erp.require_not_own_roles(v_tenant, p_app_user_id);
  end if;

  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d);

  foreach v_grant in array v_to_end loop
    if erp.end_grant(v_tenant, v_grant) in ('ended', 'withdrawn') then
      v_ended := v_ended + 1;
    end if;
  end loop;

  insert into erp.user_role (tenant_id, app_user_id, role_id, valid_from, granted_by, grant_reason)
  select v_tenant, p_app_user_id, r.id, current_date, erp.current_principal_id(),
         coalesce(p_reason, 'set from the roles panel')
    from erp.role r
   where r.tenant_id = v_tenant and r.status = 'active' and r.code = any (v_to_add);
  get diagnostics v_added = row_count;

  select case when count(*) = 1 then format('the %s role', min(coalesce(nullif(btrim(r.name), ''), r.code)))
              else format('the roles %s', string_agg(coalesce(nullif(btrim(r.name), ''), r.code), ', ' order by r.code))
         end
    into v_change
    from erp.role r
   where r.tenant_id = v_tenant and r.status = 'active' and r.code = any (v_to_add);

  return jsonb_build_object(
    'granted', v_added,
    'revoked', v_ended,
    'conflicts', erp.settle_duties(v_tenant, p_app_user_id, v_before, p_sod_override_reason,
                                   v_change, 'grant'));
end;
$$;

comment on function public.erp_set_user_roles(uuid, text[], text, text) is
  'Replaces the organisation-wide roles a person holds with exactly the set '
  'given: unticked grants end (kept on file where they began before today), '
  'ticked ones are granted. Refuses your own roles once live. In a live '
  'organisation a prohibited segregation-of-duties pairing the change introduces '
  'is refused unless p_sod_override_reason records an exception, which needs '
  'administration.promote. Returns granted, revoked and the person''s conflicts.';

revoke all on function public.erp_set_user_roles(uuid, text[], text, text) from public, anon;
grant execute on function public.erp_set_user_roles(uuid, text[], text, text) to authenticated, service_role;

drop function public.erp_grant_role(uuid, uuid, date, date, text);

create function public.erp_grant_role(
  p_app_user_id         uuid,
  p_role_id             uuid,
  p_valid_from          date default current_date,
  p_valid_to            date default null,
  p_grant_reason        text default null,
  p_sod_override_reason text default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_code   text;
  v_id     uuid;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if not exists (select 1 from erp.app_user u
                  where u.id = p_app_user_id and u.tenant_id = v_tenant) then
    raise exception 'CLOVEERP_VALIDATION: principal not found in this tenant'
      using hint = 'Refresh the list of people and choose again.';
  end if;

  select r.code into v_code
    from erp.role r
   where r.id = p_role_id and r.tenant_id = v_tenant and r.status = 'active'::erp.record_status;
  if v_code is null then
    raise exception 'CLOVEERP_VALIDATION: active role not found in this tenant'
      using hint = 'Refresh the list of roles and choose again.';
  end if;

  if p_valid_to is not null and p_valid_to < coalesce(p_valid_from, current_date) then
    raise exception 'CLOVEERP_VALIDATION: valid_to precedes valid_from'
      using hint = 'A grant cannot end before it begins. Change one of the two dates.';
  end if;

  -- The grant, its refusal of your own roles and its duties are erp.grant_role's.
  v_id := erp.grant_role(p_app_user_id, v_code, null, null, p_grant_reason,
                         coalesce(p_valid_from, current_date), p_valid_to,
                         p_sod_override_reason);

  return jsonb_build_object(
    'grant_id', v_id,
    'conflicts', erp.settle_duties(v_tenant, p_app_user_id,
                                   array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, p_app_user_id) d),
                                   null, null, 'review'));
end;
$$;

comment on function public.erp_grant_role(uuid, uuid, date, date, text, text) is
  'Grants one role to a person from a date, under administration.roles, through '
  'erp.grant_role(): refuses your own roles once live, and a prohibited '
  'segregation-of-duties pairing unless p_sod_override_reason records an '
  'exception. Returns grant_id and the person''s conflicts.';

revoke all on function public.erp_grant_role(uuid, uuid, date, date, text, text) from public, anon;
grant execute on function public.erp_grant_role(uuid, uuid, date, date, text, text) to authenticated, service_role;

-- Same signature and return type as 20260829180000, so the grants stay.
create or replace function public.erp_revoke_role(p_user_role_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_person  uuid;
  v_before  uuid[];
  v_outcome text;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  select ur.app_user_id into v_person
    from erp.user_role ur
   where ur.id = p_user_role_id and ur.tenant_id = v_tenant;
  if not found then
    raise exception 'CLOVEERP_VALIDATION: grant not found in this tenant'
      using hint = 'Refresh the list of grants. It may have ended already, or belong to another organisation.';
  end if;

  perform erp.require_not_own_roles(v_tenant, v_person);

  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, v_person) d);
  v_outcome := erp.end_grant(v_tenant, p_user_role_id);

  return jsonb_build_object(
    'revoked', p_user_role_id,
    'outcome', v_outcome,
    'conflicts', erp.settle_duties(v_tenant, v_person, v_before, null, null, 'grant'));
end;
$$;

comment on function public.erp_revoke_role(uuid) is
  'Ends one grant under administration.roles: begun before today it ends '
  'yesterday and stays on file, begun today or later it is withdrawn. Refuses '
  'your own grants once live. Returns revoked, outcome (ended, withdrawn or '
  'already_ended) and the person''s conflicts as they stand.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A role whose permissions change settles the people holding it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The role arm 20260914061500 left is wrapped, by counted replacement at its
-- first and last lines, in a block that reads what each holder met before the
-- arm runs and settles them after. A rollback is recognised by the promoter's
-- own call stack, as erp.audit_row_change() names the mechanism.

do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := $n$        -- A content pack meeting a role this organisation already holds, and
$n$;
  v_r1  text := $r$        declare
          v_duties_before jsonb := erp.role_duties_before(v_tenant, p ->> 'code');
          v_duties_stack  text;
        begin
        -- A content pack meeting a role this organisation already holds, and
$r$;
  v_n2  text := $n$            from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
        end if;
$n$;
  v_r2  text := $r$            from jsonb_array_elements(coalesce(p -> 'permissions', '[]'::jsonb)) e;
        end if;

        -- Everybody holding the role holds what it now grants, and their
        -- duties are settled like a grant's (20260914065000): in a live
        -- organisation a prohibited pairing the change introduces is refused.
        -- A rollback restores what was there and records only.
        get diagnostics v_duties_stack = pg_context;
        perform erp.settle_role_duties(
          v_tenant, v_duties_before,
          (select coalesce(nullif(btrim(ro.name), ''), ro.code)
             from erp.role ro where ro.tenant_id = v_tenant and ro.id = v_obj),
          case when position('function erp.' || 'rollback_to_snapshot(' in v_duties_stack) > 0
               then 'review' else 'role' end);
        end;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm of erp.apply_change_set_item() is not the text 20260914061500 left'
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  if position('erp.settle_role_duties(' in pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm did not take the duties'
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the promoter.';
  end if;
end
$promoter$;

-- Same signature and return type as 20260829180000, so the grants stay. The
-- role editor writes only before go-live (the live guard refuses erp.role
-- after it), so its holders' duties are recorded, never refused.
create or replace function public.erp_save_role(p_role_id uuid, p_code text, p_name text, p_description text, p_permissions text[])
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_id     uuid;
  v_before jsonb;
begin
  perform erp.authorise('administration.roles');
  v_tenant := erp.current_tenant_id();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'CLOVEERP_VALIDATION: role name is required'
      using hint = 'Give the role a name people will recognise.';
  end if;
  if exists (select 1
               from unnest(coalesce(p_permissions, '{}')) perm
              where not exists (select 1 from erp_ref.permission p where p.code = perm)) then
    raise exception 'CLOVEERP_VALIDATION: unknown permission code'
      using hint = 'Choose permissions from the list the screen offers.';
  end if;

  if p_role_id is null then
    if p_code is null or btrim(p_code) = '' then
      raise exception 'CLOVEERP_VALIDATION: role code is required'
        using hint = 'Give the role a short code, such as stock-clerk.';
    end if;
    insert into erp.role (tenant_id, code, name_key, name, description, status, created_by)
    values (v_tenant, p_code, 'role.' || replace(p_code, '-', '_') || '.name', p_name,
            p_description, 'active'::erp.record_status, erp.current_principal_id())
    returning id into v_id;
  else
    select erp.role_duties_before(v_tenant, r.code) into v_before
      from erp.role r
     where r.id = p_role_id and r.tenant_id = v_tenant;

    update erp.role r
       set name = p_name, description = p_description, updated_at = now(),
           updated_by = erp.current_principal_id()
     where r.id = p_role_id and r.tenant_id = v_tenant
    returning id into v_id;
    if not found then
      raise exception 'CLOVEERP_VALIDATION: role not found in this tenant'
        using hint = 'Refresh the list of roles. It may belong to another organisation.';
    end if;
    delete from erp.role_permission rp where rp.tenant_id = v_tenant and rp.role_id = v_id;
  end if;

  insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes, created_by)
  select v_tenant, v_id, perm, '{}', erp.current_principal_id()
  from unnest(coalesce(p_permissions, '{}')) perm;

  perform erp.settle_role_duties(v_tenant, coalesce(v_before, '{}'::jsonb), p_name, 'role');

  return jsonb_build_object('role_id', v_id);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The read door
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_sod_conflicts()
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('administration.audit_read', null, null, null, 'sod_conflict', null);
  v_tenant := erp.require_tenant_id();

  return jsonb_build_object(
    'is_live', erp.tenant_is_live(v_tenant),
    'rules', (select count(*) from erp.sod_rule sr
               where sr.tenant_id = v_tenant and sr.status = 'active'),
    'conflicts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'app_user_id', d.app_user_id,
               'person', coalesce(nullif(btrim(u.display_name), ''), u.email),
               'email', u.email,
               'rule_code', d.rule_code,
               'rule_name', d.rule_name,
               'severity', d.severity,
               'description', sr.description,
               'mitigation', sr.mitigation_guidance,
               'permissions_a', to_jsonb(d.permissions_a),
               'permissions_b', to_jsonb(d.permissions_b),
               'status', coalesce(rec.status::text, 'unrecorded'),
               'recorded_at', rec.detected_at,
               'exception_reason', rec.mitigation_note,
               'exception_by', coalesce(nullif(btrim(rv.display_name), ''), rv.email),
               'exception_at', rec.reviewed_at)
             order by (d.severity = 'prohibited') desc,
                      coalesce(nullif(btrim(u.display_name), ''), u.email), d.rule_code)
        from erp.duty_conflicts(v_tenant, null) d
        join erp.app_user u on u.tenant_id = v_tenant and u.id = d.app_user_id
        join erp.sod_rule sr on sr.tenant_id = v_tenant and sr.id = d.sod_rule_id
        left join lateral (
          select sc.status, sc.detected_at, sc.mitigation_note, sc.reviewed_by, sc.reviewed_at
            from erp.sod_conflict sc
           where sc.tenant_id = v_tenant
             and sc.app_user_id = d.app_user_id
             and sc.sod_rule_id = d.sod_rule_id
             and sc.status in ('open', 'accepted', 'mitigated')
           order by (sc.status = 'open'), sc.detected_at desc
           limit 1) rec on true
        left join erp.app_user rv on rv.tenant_id = v_tenant and rv.id = rec.reviewed_by), '[]'::jsonb),
    'administrators', coalesce((
      select jsonb_agg(jsonb_build_object('app_user_id', a.id, 'person', a.person) order by a.person)
        from (select distinct u.id, coalesce(nullif(btrim(u.display_name), ''), u.email) as person
                from erp.user_role ur
                join erp.role r
                  on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                 and r.status = 'active' and r.code = 'administrator'
                join erp.app_user u on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
               where ur.tenant_id = v_tenant
                 and ur.entity_id is null and ur.site_id is null
                 and (ur.valid_to is null or ur.valid_to >= current_date)) a), '[]'::jsonb));
end;
$$;

comment on function public.erp_sod_conflicts() is
  'Under administration.audit_read: every segregation-of-duties conflict that '
  'stands in the organisation (person, rule, severity, both sides'' permission '
  'codes, the recorded status unrecorded/open/accepted/mitigated, and any '
  'exception''s reason, decider and date), the number of active rules, whether '
  'the organisation is live, and the people exempt because their administrator '
  'role holds both sides of every rule by design.';

revoke all on function public.erp_sod_conflicts() from public, anon;
grant execute on function public.erp_sod_conflicts() to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The templates keep no prohibited pairing
-- ═════════════════════════════════════════════════════════════════════════════

do $templates$
declare
  v_n integer;
begin
  update erp_ref.pack_item pi
     set payload = jsonb_set(pi.payload, '{permissions}',
                     (select coalesce(jsonb_agg(e.value order by e.ord), '[]'::jsonb)
                        from jsonb_array_elements(pi.payload -> 'permissions') with ordinality as e(value, ord)
                       where e.value ->> 'permission' <> v.code_out)),
         provenance = v.why
    from (values
      ('procurement_manager', 'procurement.requisition',
       'Starter Content Packs §3.2. Approves, and §3.3 refuses receiving against '
       'what this role approved. Does not raise requisitions: raising and '
       'approving one in the same hands is §3.3''s first conflict, which the pack '
       'prohibits, so the buyer raises and this role approves (20260914065000).'),
      ('finance_manager', 'finance.post',
       'Starter Content Packs §3.2. Holds close_period but not reopen_period: '
       'reopening a closed period is §6''s own reason category and belongs above '
       'the person who closed it. Closes periods and approves payments, and does '
       'not post: posting and closing in one person is §3.3''s POST_CLOSE, which '
       'the pack prohibits; the finance clerk posts (20260914065000).'),
      ('quality_manager', 'quality.release_batch',
       'Starter Content Packs §3.2. Inspects, dispositions and recalls, and does '
       'not release: amending a batch and releasing it is §3.3''s '
       'AMEND_RELEASE_BATCH, which the pack prohibits; release is the '
       'Responsible Person''s (20260914065000).'),
      ('responsible_person', 'quality.disposition',
       'Starter Content Packs §3.2, and Terminology §3, which says the UK '
       'regulatory titles are not to be softened. Named authority for batch '
       'release and for a recall, which is why it also reads the audit trail. '
       'Releases and does not disposition: the quality manager dispositions, and '
       '§3.3''s AMEND_RELEASE_BATCH keeps the two apart (20260914065000).')
    ) as v(role_code, code_out, why)
   where pi.pack_code = 'base'
     and pi.object_kind = 'role'
     and pi.object_key = v.role_code
     and pi.payload -> 'permissions' @> jsonb_build_array(jsonb_build_object('permission', v.code_out));
  get diagnostics v_n = row_count;
  if v_n <> 4 then
    raise exception 'CLOVEERP_PACK_TEMPLATE_MISSING: % of 4 base pack role templates held the permission this migration takes away', v_n
      using hint = 'The templates are registered by 20260903150000 and edited by 20260914061500; a code changed name, or a template already lost the permission.';
  end if;
end
$templates$;

-- Same signature and return type as 20260914061500, so the grants stay.
create or replace function erp.standard_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p.code order by p.code), '{}')
    from erp_ref.permission p
   where (p.module_code = case p_code
                            when 'purchasing'  then 'procurement'
                            when 'despatch'    then 'logistics'
                            when 'master_data' then 'master_data'
                            when 'warehouse'   then null
                            else p_code
                          end
       or p.code = any (case p_code
         when 'inventory'   then array['master_data.read','reporting.read']
         when 'purchasing'  then array['master_data.read','inventory.read','reporting.read']
         -- Whoever raises the invoice issues and reprints it. Managing the
         -- template is a different job and stays out.
         when 'sales'       then array['master_data.read','inventory.read','reporting.read',
                                       'document.issue','document.reprint']
         when 'finance'     then array['master_data.read','reporting.read','reporting.export',
                                       'document.issue','document.reprint']
         when 'production'  then array['inventory.read','master_data.read','reporting.read']
         when 'quality'     then array['inventory.read','production.read','reporting.read']
         when 'despatch'    then array['inventory.read','sales.read','reporting.read']
         when 'planning'    then array['inventory.read','procurement.read','production.read','reporting.read']
         when 'reporting'   then array['master_data.read']
         -- The template is reference material, kept by the people who keep the
         -- rest of it. Issuing is not theirs.
         when 'master_data' then array['reporting.read','document.template_manage']
         -- Goods arrive at the warehouse, so receiving against an order is the
         -- warehouse's, and so is reading the order it is received against
         -- (20260914061500). Approving that order is not.
         when 'warehouse'   then array[
                                 'inventory.read','inventory.move','inventory.count',
                                 'logistics.read','logistics.despatch',
                                 'procurement.read','procurement.receive',
                                 'sales.read','sales.despatch',
                                 'master_data.read','reporting.read']
         else '{}'::text[]
       end))
     -- A module role does not hand one person both sides of a prohibited rule
     -- (20260914065000): purchasing raises and orders, and neither approves nor
     -- receives; finance posts and pays, and neither closes nor reopens a
     -- period; quality inspects and dispositions, and does not release.
     -- Inventory keeps adjust and write_off, and sales despatch and invoice:
     -- both pairings are material, recorded when granted.
     and not (p.code = any (case p_code
         when 'purchasing' then array['procurement.approve','procurement.receive']
         when 'finance'    then array['finance.close_period','finance.reopen_period']
         when 'quality'    then array['quality.release_batch']
         else '{}'::text[]
       end))
$$;

comment on function erp.standard_role_permissions is
  'What one job needs, by role code. Roles combine, so a person doing two jobs '
  'holds both roles rather than a third role made for the pair. Issuing and '
  'reprinting a document sit with the roles that already raise it; managing the '
  'template sits with master data. The warehouse receives, moves, counts, picks '
  'and despatches, and neither adjusts nor approves. No module role holds both '
  'sides of a prohibited segregation rule: approving, receiving, closing and '
  'releasing are other people''s.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. A suite that granted itself a role
-- ═════════════════════════════════════════════════════════════════════════════

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.approval_hold_suite()'::regprocedure);
  v_old text := $p$    -- Purchasing is held by both administrators; sales by the first alone.
    perform erp.grant_role(r.admin_user_id, 'purchasing', null, null, 'buys, and could approve');
    perform erp.grant_role(v_second, 'purchasing', null, null, 'approves');
    perform erp.grant_role(r.admin_user_id, 'sales', null, null, 'sells, and alone could approve');
$p$;
  v_new text := $q$    -- Purchasing is held by both administrators; sales by the first alone.
    -- Each is given their roles by the other: nobody changes their own roles
    -- once the organisation is live (20260914065000).
    perform erp.grant_role(v_second, 'purchasing', null, null, 'approves');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.grant_role(r.admin_user_id, 'purchasing', null, null, 'buys, and could approve');
    perform erp.grant_role(r.admin_user_id, 'sales', null, null, 'sells, and alone could approve');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.approval_hold_suite() is not the body this migration patches'
      using hint = 'A later migration changed who grants the suite''s roles. Read the suite and patch that body.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. Refusals, registers and the words on the screen
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_SOD_PROHIBITED',
  'Giving somebody two permissions a separation-of-duties rule keeps apart.',
  'The organisation''s rules prohibit one person holding both, because together they let somebody complete and conceal work nobody else sees.',
  'Give the role to somebody else, or take away the other permission first. If the organisation accepts the risk, somebody who may promote configuration records the reason for an exception.');

select erp.register_refusal('CLOVEERP_SOD_SELF_GRANT',
  'Changing your own roles in a live organisation.',
  'Once an organisation is live every grant has a second person behind it, so nobody gives themselves access or takes their own away.',
  'Ask another administrator who may administer roles to make the change.');

select erp.register_refusal('CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT',
  'Recording an exception to a separation-of-duties rule without a proper reason.',
  'An exception is a decision somebody reviewing access will read later, and a word or two does not say why the risk was accepted.',
  'Say why the organisation accepts one person holding both, and what checks the work instead, in at least twenty characters.');

do $allowances$
declare
  v_n integer;
begin
  update erp_meta.public_write_allowance a
     set gate = v.gate, rationale = v.rationale
    from (values
      ('erp_set_user_roles', 'erp.authorise',
       'Sets the whole set of organisation-wide roles a person holds under administration.roles: unticked grants end (erp.end_grant), ticked ones are inserted, and the person''s segregation of duties is settled once (erp.settle_duties), refusing a prohibited pairing in a live organisation unless an exception is recorded under administration.promote. Refuses your own roles once live (20260914065000).'),
      ('erp_grant_role', 'erp.authorise',
       'Grants one role to a person within the caller''s tenant under administration.roles, through erp.grant_role(), which refuses your own roles once live and settles segregation of duties (20260914065000).'),
      ('erp_revoke_role', 'erp.authorise',
       'Ends a grant under administration.roles: it ends yesterday and stays on file, or is withdrawn when it had not begun before today (erp.end_grant). Refuses your own grants once live (20260914065000).'),
      ('erp_save_role', 'erp.authorise',
       'Creates or edits a role and its permission set under administration.roles, and records the segregation-of-duties conflicts the edit gives the people holding it (20260914065000).')
    ) as v(function_name, gate, rationale)
   where a.function_name = v.function_name;
  get diagnostics v_n = row_count;
  if v_n <> 4 then
    raise exception 'CLOVEERP_WRITE_ALLOWANCE_NOT_UPDATED: % of 4 write allowance rows were reworded', v_n
      using hint = 'The rows are written by 20260829180000 and 20260910135355. If row security refused the update, the migration role has lost its bypass.';
  end if;
end
$allowances$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_sod_conflicts', 'erp.authorise',
   'A read of the organisation''s segregation-of-duties conflicts, exceptions and exempt administrators. Volatile because erp.authorise() records the access decision; writes nothing else. administration.audit_read.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/administration/permissions', array['erp_sod_conflicts']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). Added when People and permissions began showing and enforcing separation of duties (20260914065000).'
  from (values
    ('Separation of duties'),
    ('People who hold both sides of one of the organisation''s separation rules. A prohibited pairing is refused once the organisation is live unless somebody records why it is accepted; anything else is allowed and listed here to review.'),
    ('The organisation has no separation rules yet. Applying the base pack brings them.'),
    ('Nobody holds both sides of a separation rule.'),
    ('Person'),
    ('Rule'),
    ('Severity'),
    ('Holds'),
    ('Decision'),
    ('Prohibited'),
    ('Material'),
    ('Advisory'),
    ('together with'),
    ('Exception recorded'),
    ('To review'),
    ('Administrators hold every permission by design, so the rules do not flag them. Keep the role to the few people who set the organisation up:'),
    ('Could not load the separation of duties.'),
    ('Reason for the exception'),
    ('Why the organisation accepts one person holding both, and what checks the work instead. At least twenty characters; it is kept with the exception for whoever reviews access.'),
    ('Record the exception and save'),
    ('Only somebody who may promote configuration can record an exception.'),
    ('The reason needs at least twenty characters.'),
    ('Saved. What this person now holds is listed under Separation of duties to review:'),
    ('Removing a grant ends it: it stops today and stays on file. A grant that had not begun is withdrawn.')
) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Organisation A is live: two administrators, the base pack's rules installed
-- as its promoter writes them, and six narrow roles. Organisation B
-- is not yet live, with the same rules and roles and one administrator. Every
-- door is called as a signed-in caller through erp_test.duties_door_as(), so the
-- grants and row security a real caller meets are the ones proven. Both
-- organisations are undone.

create or replace function erp_test.duties_door_as(
  p_subject  uuid,
  p_door     text,
  p_person   uuid default null,
  p_roles    text[] default null,
  p_target   uuid default null,
  p_override text default null
) returns table (outcome jsonb, err_state text, err_message text, err_hint text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner text := current_user;
begin
  if p_door not in ('erp_set_user_roles', 'erp_grant_role', 'erp_revoke_role', 'erp_sod_conflicts') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door erp_test.duties_separated_suite calls', p_door
      using hint = 'Call erp_set_user_roles, erp_grant_role, erp_revoke_role or erp_sod_conflicts.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    if p_door = 'erp_set_user_roles' then
      outcome := public.erp_set_user_roles(p_person, p_roles, 'the duties suite', p_override);
    elsif p_door = 'erp_grant_role' then
      outcome := public.erp_grant_role(p_person, p_target, current_date, null, 'the duties suite', p_override);
    elsif p_door = 'erp_revoke_role' then
      outcome := public.erp_revoke_role(p_target);
    else
      outcome := public.erp_sod_conflicts();
    end if;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text,
                            err_hint = pg_exception_hint;
  end;
  execute format('set local role %I', v_owner);
  return next;
end;
$$;
revoke all on function erp_test.duties_door_as(uuid, text, uuid, text[], uuid, text) from public, anon, authenticated;

comment on function erp_test.duties_door_as(uuid, text, uuid, text[], uuid, text) is
  'Suite helper: calls one of the four doors erp_test.duties_separated_suite '
  'proves (setting roles, granting one, ending one, reading conflicts) as the '
  'given sign-in, in the authenticated role, and returns its answer or its '
  'refusal with the hint. Returns to the calling role before it returns.';

create or replace function erp_test.duties_rules_and_roles(p_tenant uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  -- Every rule the base pack ships, as its promoter writes them.
  perform erp.upsert_sod_rule(
            pi.payload ->> 'code', pi.payload ->> 'name',
            string_to_array(pi.payload ->> 'permissions_a', ','),
            string_to_array(pi.payload ->> 'permissions_b', ','),
            coalesce(pi.payload ->> 'severity', 'material')::erp.sod_severity,
            pi.payload ->> 'description', pi.payload ->> 'mitigation')
     from erp_ref.pack_item pi
    where pi.pack_code = 'base' and pi.object_kind = 'sod_rule';

  insert into erp.role (tenant_id, code, name, status) values
    (p_tenant, 'zz_poster',      'Suite poster',       'active'),
    (p_tenant, 'zz_closer',      'Suite closer',       'active'),
    (p_tenant, 'zz_adjuster',    'Suite adjuster',     'active'),
    (p_tenant, 'zz_writer_off',  'Suite writer-off',   'active'),
    (p_tenant, 'zz_viewer',      'Suite viewer',       'active'),
    (p_tenant, 'zz_role_keeper', 'Suite role keeper',  'active');
  insert into erp.role_permission (tenant_id, role_id, permission_code)
  select p_tenant, ro.id, x.perm
    from (values ('zz_poster', 'finance.read'), ('zz_poster', 'finance.post'),
                 ('zz_closer', 'finance.read'), ('zz_closer', 'finance.close_period'),
                 ('zz_adjuster', 'inventory.read'), ('zz_adjuster', 'inventory.adjust'),
                 ('zz_writer_off', 'inventory.read'), ('zz_writer_off', 'inventory.write_off'),
                 ('zz_viewer', 'reporting.read'),
                 ('zz_role_keeper', 'administration.read'), ('zz_role_keeper', 'administration.roles')) as x(role_code, perm)
    join erp.role ro on ro.tenant_id = p_tenant and ro.code = x.role_code;
end;
$$;
revoke all on function erp_test.duties_rules_and_roles(uuid) from public, anon, authenticated;

comment on function erp_test.duties_rules_and_roles(uuid) is
  'Suite fixture: the base pack''s segregation rules, upserted as its promoter '
  'writes them, and six narrow roles (poster, closer, adjuster, writer-off, '
  'viewer, role keeper) in the organisation in context. Call it while the '
  'organisation is not live.';

create or replace function erp_test.duties_separated_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  c_reason   constant text := 'Two-person office until the new clerk starts in October; the partner reviews every close.';
  ra record; rb record; d record;
  -- Organisation A, live.
  s_admin    uuid := gen_random_uuid();
  s_second   uuid := gen_random_uuid();
  s_una      uuid := gen_random_uuid();
  u_admin    uuid; u_second uuid; u_una uuid;
  u_poppy    uuid; u_adam uuid; u_quinn uuid; u_ivy uuid; u_rhea uuid; u_pete uuid;
  t_tok      text;
  v_viewer_role  uuid;
  v_admin_grant  uuid;
  g_rhea_viewer  uuid; g_rhea_closer uuid; g_rhea_adjuster uuid;
  g_adam_writer  uuid;
  v_rule_post_close uuid;
  v_poppy_conflict  uuid;
  v_cs       uuid;
  v_step     text := 'provisioning';
  v_state_a  text;
  v_read     jsonb;
  -- Organisation B, not yet live.
  s_badmin   uuid := gen_random_uuid();
  u_badmin   uuid; u_bea uuid;
  v_detected integer;
  v_state_b  text;
  -- The door shapes.
  v_sn integer; v_sargs text; v_sdef boolean; v_sgrant boolean;
  v_gn integer; v_gargs text; v_gdef boolean; v_ggrant boolean;
  v_rn integer; v_rvol text; v_rdef boolean; v_rgrant boolean;
  v_ern integer; v_eargs text;
  -- The templates.
  v_breaks   text;
  v_fm text[]; v_fc text[]; v_pm text[]; v_buyer text[]; v_qm text[]; v_rp text[];
  v_purchasing text[] := erp.standard_role_permissions('purchasing');
  v_finance    text[] := erp.standard_role_permissions('finance');
  v_quality    text[] := erp.standard_role_permissions('quality');
  v_inventory  text[] := erp.standard_role_permissions('inventory');
  v_warehouse  text[] := erp.standard_role_permissions('warehouse');

  ok_refused  boolean; msg_refused  text;
  ok_override boolean; msg_override text;
  ok_needs    boolean; msg_needs    text;
  ok_material boolean; msg_material text;
  ok_admin    boolean; msg_admin    text;
  ok_read     boolean; msg_read     text;
  ok_noread   boolean; msg_noread   text;
  ok_self     boolean; msg_self     text;
  ok_ended    boolean; msg_ended    text;
  ok_role     boolean; msg_role     text;
  ok_prelive  boolean; msg_prelive  text;
begin
  -- ── The doors as the catalogue holds them ──────────────────────────────
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)), coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_sn, v_sargs, v_sdef, v_sgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_set_user_roles';
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)), coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_gn, v_gargs, v_gdef, v_ggrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_grant_role';
  select count(*), min(p.provolatile::text), coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_rn, v_rvol, v_rdef, v_rgrant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_sod_conflicts';
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid))
    into v_ern, v_eargs
    from pg_catalog.pg_proc p
   where p.pronamespace = 'erp'::regnamespace and p.proname = 'grant_role';

  -- ── The templates ──────────────────────────────────────────────────────
  select string_agg(format('%s holds both sides of %s', h.holder, s.object_key), '; ' order by h.holder, s.object_key)
    into v_breaks
    from (select 'template ' || pi.object_key as holder,
                 array(select e.value ->> 'permission' from jsonb_array_elements(pi.payload -> 'permissions') e) as perms
            from erp_ref.pack_item pi
           where pi.object_kind = 'role'
          union all
          select 'module role ' || m.code, erp.standard_role_permissions(m.code)
            from unnest(array['inventory', 'warehouse', 'purchasing', 'sales', 'finance', 'production',
                              'quality', 'despatch', 'planning', 'reporting', 'master_data']) as m(code)) h
    cross join erp_ref.pack_item s
   where s.object_kind = 'sod_rule'
     and s.payload ->> 'severity' = 'prohibited'
     and h.perms && string_to_array(s.payload ->> 'permissions_a', ',')
     and h.perms && string_to_array(s.payload ->> 'permissions_b', ',');

  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'finance_manager') into v_fm;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'finance_clerk') into v_fc;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'procurement_manager') into v_pm;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'buyer') into v_buyer;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'quality_manager') into v_qm;
  select array(select e.value ->> 'permission' from erp_ref.pack_item pi, jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role' and pi.object_key = 'responsible_person') into v_rp;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Organisation A, live
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    v_step := 'organisation A is provisioned and its two administrators join';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzsoda-' || v_tag, 'Duties Suite A',
                                               'admin@zzsoda-' || v_tag || '.test', 'Duties Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    u_admin := erp.claim_invitation(ra.admin_token);
    select i.app_user_id, i.token into u_second, t_tok
      from erp.invite_principal('second@zzsoda-' || v_tag || '.test', 'Second Admin') i;
    perform erp.grant_role(u_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', s_second)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    v_step := 'the base pack''s rules and six narrow roles, while the organisation is opened for it';
    perform erp_test.reopen_bootstrap_window(ra.tenant_id);
    perform erp_test.duties_rules_and_roles(ra.tenant_id);
    perform erp_test.close_bootstrap_window(ra.tenant_id);
    select sr.id into v_rule_post_close from erp.sod_rule sr
     where sr.tenant_id = ra.tenant_id and sr.code = 'POST_CLOSE';
    select ro.id into v_viewer_role from erp.role ro
     where ro.tenant_id = ra.tenant_id and ro.code = 'zz_viewer';

    v_step := 'the people';
    select i.app_user_id into u_poppy from erp.invite_principal('poppy@zzsoda-' || v_tag || '.test', 'Poppy Poster') i;
    select i.app_user_id into u_adam  from erp.invite_principal('adam@zzsoda-' || v_tag || '.test', 'Adam Adjuster') i;
    select i.app_user_id into u_quinn from erp.invite_principal('quinn@zzsoda-' || v_tag || '.test', 'Quinn Quick') i;
    select i.app_user_id into u_ivy   from erp.invite_principal('ivy@zzsoda-' || v_tag || '.test', 'Ivy Administrator') i;
    select i.app_user_id into u_rhea  from erp.invite_principal('rhea@zzsoda-' || v_tag || '.test', 'Rhea Reporter') i;
    select i.app_user_id into u_pete  from erp.invite_principal('pete@zzsoda-' || v_tag || '.test', 'Pete Poster') i;
    select i.app_user_id, i.token into u_una, t_tok
      from erp.invite_principal('una@zzsoda-' || v_tag || '.test', 'Una Rolekeeper') i;
    perform erp.grant_role(u_una, 'zz_role_keeper', null, null, 'gives roles, reads no audit, promotes nothing');
    g_rhea_viewer := erp.grant_role(u_rhea, 'zz_viewer', null, null, 'held for a month', current_date - 30);
    g_rhea_closer := erp.grant_role(u_rhea, 'zz_closer', null, null, 'held for ten days', current_date - 10);
    g_rhea_adjuster := erp.grant_role(u_rhea, 'zz_adjuster', null, null, 'given today');
    perform erp.grant_role(u_pete, 'zz_poster', null, null, 'posts');
    perform set_config('request.jwt.claims', json_build_object('sub', s_una)::text, true);
    perform erp.claim_invitation(t_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    -- ── A prohibited pairing, live ───────────────────────────────────────
    v_step := 'the administrator gives one person posting and closing';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_poppy, array['zz_poster', 'zz_closer']);
    ok_refused := coalesce(
      d.err_state = '23514'
      and d.err_message like 'CLOVEERP_SOD_PROHIBITED%'
      and d.err_message like '%Poppy Poster%'
      and d.err_hint like '%Post a journal and close the period%'
      and d.err_hint like ('%' || erp.text('permission.finance.post') || '%')
      and d.err_hint like ('%' || erp.text('permission.finance.close_period') || '%')
      and d.err_hint like '%promote configuration%'
      and not exists (select 1 from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_poppy)
      and not exists (select 1 from erp.sod_conflict sc where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_poppy), false);
    msg_refused := coalesce(d.err_message || ' / ' || d.err_hint, d.outcome::text, 'no answer');

    -- ── An exception needs a reason and somebody who may promote ──────────
    v_step := 'an exception with too short a reason, and one from somebody who may not promote';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_quinn, array['zz_poster', 'zz_closer'], null, 'ok by me');
    ok_needs := coalesce(d.err_state = '22023' and d.err_message like 'CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT%' and d.err_hint <> '', false);
    msg_needs := 'short: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.duties_door_as(s_una, 'erp_set_user_roles', u_quinn, array['zz_poster', 'zz_closer']);
    ok_needs := ok_needs and coalesce(d.err_state = '23514' and d.err_message like 'CLOVEERP_SOD_PROHIBITED%', false);
    msg_needs := msg_needs || '; without promote, no reason: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.duties_door_as(s_una, 'erp_set_user_roles', u_quinn, array['zz_poster', 'zz_closer'], null, c_reason);
    ok_needs := ok_needs
      and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: administration.promote%', false)
      and not exists (select 1 from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_quinn)
      and not exists (select 1 from erp.sod_conflict sc where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_quinn);
    msg_needs := msg_needs || '; without promote, with a reason: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── The exception, recorded ──────────────────────────────────────────
    v_step := 'the administrator records an exception with its reason';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_poppy, array['zz_poster', 'zz_closer'], null, c_reason);
    select sc.id into v_poppy_conflict
      from erp.sod_conflict sc
     where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_poppy and sc.sod_rule_id = v_rule_post_close
       and sc.status = 'accepted' and sc.mitigation_note = c_reason
       and sc.reviewed_by = u_admin and sc.reviewed_at is not null;
    ok_override := coalesce(
      d.err_state is null
      and (d.outcome ->> 'granted')::integer = 2
      and erp.has_permission('finance.post', null, null, null, u_poppy)
      and erp.has_permission('finance.close_period', null, null, null, u_poppy)
      and v_poppy_conflict is not null
      and exists (select 1 from jsonb_array_elements(d.outcome -> 'conflicts') x(el)
                   where x.el ->> 'rule_code' = 'POST_CLOSE' and x.el ->> 'status' = 'accepted'
                     and x.el ->> 'exception_reason' = c_reason)
      and exists (select 1 from erp.audit_entry ae
                   where ae.tenant_id = ra.tenant_id and ae.object_type = 'sod_conflict'
                     and ae.object_id = v_poppy_conflict and ae.action = 'insert'), false);
    msg_override := coalesce(d.err_message, d.outcome::text, 'no answer')
      || case when v_poppy_conflict is null then '; no accepted conflict with the reason on file' else '; the exception is on file' end;

    -- ── A material pairing ───────────────────────────────────────────────
    v_step := 'the administrator gives one person adjusting and writing off';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_adam, array['zz_adjuster', 'zz_writer_off']);
    select ur.id into g_adam_writer
      from erp.user_role ur join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
     where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_adam and ro.code = 'zz_writer_off';
    ok_material := coalesce(
      d.err_state is null
      and (d.outcome ->> 'granted')::integer = 2
      and g_adam_writer is not null
      and exists (select 1 from jsonb_array_elements(d.outcome -> 'conflicts') x(el)
                   where x.el ->> 'rule_code' = 'ADJUST_APPROVE_STOCK' and x.el ->> 'severity' = 'material'
                     and x.el ->> 'status' = 'open')
      and exists (select 1 from erp.sod_conflict sc join erp.sod_rule sr on sr.tenant_id = sc.tenant_id and sr.id = sc.sod_rule_id
                   where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_adam
                     and sr.code = 'ADJUST_APPROVE_STOCK' and sc.status = 'open' and sc.mitigation_note is null), false);
    msg_material := coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── The administrator ────────────────────────────────────────────────
    v_step := 'the administrator makes a third administrator';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_ivy, array['administrator']);
    ok_admin := coalesce(
      d.err_state is null
      and (d.outcome ->> 'granted')::integer = 1
      and jsonb_array_length(d.outcome -> 'conflicts') = 0
      and erp.has_permission('finance.post', null, null, null, u_ivy)
      and erp.has_permission('finance.close_period', null, null, null, u_ivy)
      and erp.has_permission('administration.roles', null, null, null, u_ivy)
      and exists (select 1 from erp.sod_rule sr
                   where sr.tenant_id = ra.tenant_id and sr.status = 'active' and sr.code = 'POST_CLOSE'
                     and sr.severity = 'prohibited')
      and (select count(*) from erp.sod_rule sr where sr.tenant_id = ra.tenant_id and sr.status = 'active')
          = (select count(*) from erp_ref.pack_item pi where pi.pack_code = 'base' and pi.object_kind = 'sod_rule')
      and not exists (select 1 from erp.duty_conflicts(ra.tenant_id, null) dc
                       where dc.app_user_id in (u_admin, u_second, u_ivy))
      and not exists (select 1 from erp.sod_conflict sc
                       where sc.tenant_id = ra.tenant_id and sc.app_user_id in (u_admin, u_second, u_ivy)), false);
    msg_admin := coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; %s conflict(s) for the administrators',
                (select count(*) from erp.duty_conflicts(ra.tenant_id, null) dc
                  where dc.app_user_id in (u_admin, u_second, u_ivy)));

    -- ── The read door ────────────────────────────────────────────────────
    v_step := 'the administrator reads the conflicts';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_sod_conflicts');
    v_read := d.outcome;
    ok_read := coalesce(
      d.err_state is null
      and v_read ?& array['is_live', 'rules', 'conflicts', 'administrators']
      and (v_read -> 'is_live') = 'true'::jsonb
      and (v_read ->> 'rules')::integer
          = (select count(*) from erp_ref.pack_item pi where pi.pack_code = 'base' and pi.object_kind = 'sod_rule')
      and exists (select 1 from jsonb_array_elements(v_read -> 'conflicts') x(el)
                   where x.el ->> 'app_user_id' = u_poppy::text
                     and x.el ->> 'person' = 'Poppy Poster'
                     and x.el ->> 'rule_code' = 'POST_CLOSE'
                     and x.el ->> 'rule_name' = 'Post a journal and close the period'
                     and x.el ->> 'severity' = 'prohibited'
                     and x.el -> 'permissions_a' = '["finance.post"]'::jsonb
                     and x.el -> 'permissions_b' = '["finance.close_period"]'::jsonb
                     and x.el ->> 'status' = 'accepted'
                     and x.el ->> 'exception_reason' = c_reason
                     and x.el ->> 'exception_by' is not null
                     and x.el ->> 'exception_at' is not null)
      and exists (select 1 from jsonb_array_elements(v_read -> 'conflicts') x(el)
                   where x.el ->> 'app_user_id' = u_adam::text
                     and x.el ->> 'rule_code' = 'ADJUST_APPROVE_STOCK'
                     and x.el ->> 'severity' = 'material'
                     and x.el ->> 'status' = 'open'
                     and x.el -> 'exception_reason' = 'null'::jsonb)
      and not exists (select 1 from jsonb_array_elements(v_read -> 'conflicts') x(el)
                       where x.el ->> 'app_user_id' in (u_admin::text, u_second::text, u_ivy::text))
      and exists (select 1 from jsonb_array_elements(v_read -> 'administrators') x(el)
                   where x.el ->> 'app_user_id' = u_ivy::text)
      and exists (select 1 from jsonb_array_elements(v_read -> 'administrators') x(el)
                   where x.el ->> 'app_user_id' = u_admin::text), false);
    msg_read := left(coalesce(d.err_message, v_read::text, 'no answer'), 700);

    v_step := 'somebody without administration.audit_read reads the conflicts';
    select * into d from erp_test.duties_door_as(s_una, 'erp_sod_conflicts');
    ok_noread := coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: administration.audit_read%', false);
    msg_noread := coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── Your own roles ───────────────────────────────────────────────────
    v_step := 'the second administrator changes their own roles';
    select ur.id into v_admin_grant
      from erp.user_role ur join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
     where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_second and ro.code = 'administrator';
    select * into d from erp_test.duties_door_as(s_second, 'erp_set_user_roles', u_second, array['administrator', 'zz_viewer']);
    ok_self := coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_SOD_SELF_GRANT%' and d.err_hint <> '', false);
    msg_self := 'set roles: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.duties_door_as(s_second, 'erp_grant_role', u_second, null, v_viewer_role);
    ok_self := ok_self and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_SOD_SELF_GRANT%', false);
    msg_self := msg_self || '; grant: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.duties_door_as(s_second, 'erp_revoke_role', null, null, v_admin_grant);
    ok_self := ok_self
      and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_SOD_SELF_GRANT%', false)
      and not exists (select 1 from erp.user_role ur join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
                       where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_second and ro.code = 'zz_viewer')
      and exists (select 1 from erp.user_role ur
                   where ur.tenant_id = ra.tenant_id and ur.id = v_admin_grant and ur.valid_to is null);
    msg_self := msg_self || '; end: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── A grant ends ─────────────────────────────────────────────────────
    v_step := 'the administrator ends one grant, then clears a person''s roles, then ends a material pairing';
    select * into d from erp_test.duties_door_as(s_admin, 'erp_revoke_role', null, null, g_rhea_closer);
    ok_ended := coalesce(d.err_state is null and d.outcome ->> 'outcome' = 'ended', false);
    msg_ended := 'end the closer grant: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
    select * into d from erp_test.duties_door_as(s_admin, 'erp_set_user_roles', u_rhea, array[]::text[]);
    ok_ended := ok_ended
      and coalesce(d.err_state is null and (d.outcome ->> 'revoked')::integer = 2, false)
      and exists (select 1 from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.id = g_rhea_viewer
                     and ur.valid_from = current_date - 30 and ur.valid_to = current_date - 1)
      and exists (select 1 from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.id = g_rhea_closer
                     and ur.valid_from = current_date - 10 and ur.valid_to = current_date - 1)
      and not exists (select 1 from erp.user_role ur where ur.tenant_id = ra.tenant_id and ur.id = g_rhea_adjuster)
      and exists (select 1 from erp.audit_entry ae
                   where ae.tenant_id = ra.tenant_id and ae.object_type = 'user_role'
                     and ae.object_id = g_rhea_adjuster and ae.action = 'delete')
      and not erp.has_permission('reporting.read', null, null, null, u_rhea)
      and not erp.has_permission('finance.close_period', null, null, null, u_rhea);
    msg_ended := msg_ended || '; clear: ' || coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; on file %s',
                (select string_agg(ro.code || ' ' || ur.valid_from || '..' || coalesce(ur.valid_to::text, 'open'), ', ' order by ro.code)
                   from erp.user_role ur join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
                  where ur.tenant_id = ra.tenant_id and ur.app_user_id = u_rhea));
    select * into d from erp_test.duties_door_as(s_admin, 'erp_revoke_role', null, null, g_adam_writer);
    ok_ended := ok_ended
      and coalesce(d.err_state is null and d.outcome ->> 'outcome' = 'withdrawn'
                   and jsonb_array_length(d.outcome -> 'conflicts') = 0, false)
      and exists (select 1 from erp.sod_conflict sc join erp.sod_rule sr on sr.tenant_id = sc.tenant_id and sr.id = sc.sod_rule_id
                   where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_adam
                     and sr.code = 'ADJUST_APPROVE_STOCK' and sc.status = 'resolved')
      and not exists (select 1 from erp.sod_conflict sc
                       where sc.tenant_id = ra.tenant_id and sc.app_user_id = u_adam and sc.status = 'open');
    msg_ended := msg_ended || '; end the write-off: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- ── A role changes under the people holding it ───────────────────────
    v_step := 'a change giving the poster role closing is written, approved and promoted';
    v_cs := erp.create_change_set('zzsod-poster-' || v_tag, 'Posters close',
                                  'Gives the suite''s poster role the close as well.');
    perform erp.add_change_set_item(v_cs, 'role', 'zz_poster',
      jsonb_build_object('code', 'zz_poster', 'name', 'Suite poster',
        'permissions', jsonb_build_array(
          jsonb_build_object('permission', 'finance.read'),
          jsonb_build_object('permission', 'finance.post'),
          jsonb_build_object('permission', 'finance.close_period'))),
      'upsert'::erp.change_operation, null, 'the duties suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', s_second)::text, true);
    perform erp.approve_change_set(v_cs);
    begin
      perform erp.promote_change_set(v_cs);
      msg_role := 'promoted';
    exception when others then
      msg_role := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    ok_role := coalesce(
      msg_role like 'CLOVEERP_SOD_PROHIBITED%'
      and msg_role like '%Pete Poster%'
      and not exists (select 1 from erp.role_permission rp join erp.role ro on ro.tenant_id = rp.tenant_id and ro.id = rp.role_id
                       where ro.tenant_id = ra.tenant_id and ro.code = 'zz_poster' and rp.permission_code = 'finance.close_period')
      and (select cs.status::text from erp.change_set cs where cs.tenant_id = ra.tenant_id and cs.id = v_cs) = 'approved', false);
    msg_role := left(msg_role, 300);

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_DUTIES_SUITE_A_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_DUTIES_SUITE_A_UNDO' then
      v_state_a := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- ───────────────────────────────────────────────────────────────────────────
  -- Organisation B, not yet live
  -- ───────────────────────────────────────────────────────────────────────────
  begin
    v_step := 'organisation B is provisioned and opened for setting up';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzsodb-' || v_tag, 'Duties Suite B',
                                               'admin@zzsodb-' || v_tag || '.test', 'Setup Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', s_badmin)::text, true);
    u_badmin := erp.claim_invitation(rb.admin_token);
    perform erp_test.duties_rules_and_roles(rb.tenant_id);
    select i.app_user_id into u_bea from erp.invite_principal('bea@zzsodb-' || v_tag || '.test', 'Bea Bookkeeper') i;

    v_step := 'before go-live, one person is given posting and closing';
    select * into d from erp_test.duties_door_as(s_badmin, 'erp_set_user_roles', u_bea, array['zz_poster', 'zz_closer']);
    ok_prelive := coalesce(
      d.err_state is null
      and (d.outcome ->> 'granted')::integer = 2
      and exists (select 1 from jsonb_array_elements(d.outcome -> 'conflicts') x(el)
                   where x.el ->> 'rule_code' = 'POST_CLOSE' and x.el ->> 'severity' = 'prohibited'
                     and x.el ->> 'status' = 'open' and x.el -> 'exception_reason' = 'null'::jsonb)
      and (select count(*) from erp.sod_conflict sc
            where sc.tenant_id = rb.tenant_id and sc.app_user_id = u_bea and sc.status = 'open') = 1, false);
    msg_prelive := 'grant: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    v_step := 'before go-live, the administrator gives themselves a role';
    select * into d from erp_test.duties_door_as(s_badmin, 'erp_set_user_roles', u_badmin, array['administrator', 'zz_viewer']);
    ok_prelive := ok_prelive and coalesce(d.err_state is null and (d.outcome ->> 'granted')::integer = 1, false);
    msg_prelive := msg_prelive || '; own role: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    v_step := 'before go-live, the conflicts are read and recorded again';
    select * into d from erp_test.duties_door_as(s_badmin, 'erp_sod_conflicts');
    ok_prelive := ok_prelive and coalesce(
      d.err_state is null
      and (d.outcome -> 'is_live') = 'false'::jsonb
      and exists (select 1 from jsonb_array_elements(d.outcome -> 'conflicts') x(el)
                   where x.el ->> 'app_user_id' = u_bea::text and x.el ->> 'rule_code' = 'POST_CLOSE'
                     and x.el ->> 'status' = 'open'), false);
    msg_prelive := msg_prelive || '; read: ' || left(coalesce(d.err_message, d.outcome::text, 'no answer'), 300);
    perform set_config('request.jwt.claims', json_build_object('sub', s_badmin)::text, true);
    v_detected := erp.detect_sod_conflicts();
    ok_prelive := ok_prelive
      and v_detected = 1
      and (select count(*) from erp.sod_conflict sc where sc.tenant_id = rb.tenant_id) = 1;
    msg_prelive := msg_prelive || format('; the organisation-wide pass finds %s on file', v_detected);

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_DUTIES_SUITE_B_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_DUTIES_SUITE_B_UNDO' then
      v_state_b := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── The verdicts ─────────────────────────────────────────────────────────

  case_name := 'the grant doors are one function each, run as the caller and take the reason for an exception last, and the read door runs as the caller';
  passed := coalesce(v_sn = 1 and v_gn = 1 and v_rn = 1 and v_ern = 1
            and not v_sdef and not v_gdef and not v_rdef and v_sgrant and v_ggrant and v_rgrant
            and v_rvol = 'v'
            and v_sargs = 'p_app_user_id uuid, p_role_codes text[], p_reason text, p_sod_override_reason text'
            and v_gargs = 'p_app_user_id uuid, p_role_id uuid, p_valid_from date, p_valid_to date, p_grant_reason text, p_sod_override_reason text'
            and v_eargs like '%, p_sod_override_reason text', false);
  detail := format('set roles %s (%s); grant %s (%s); read %s volatile %s; erp.grant_role %s (%s)',
                   v_sn, coalesce(v_sargs, 'none'), v_gn, coalesce(v_gargs, 'none'), v_rn, v_rvol,
                   v_ern, coalesce(v_eargs, 'none'));
  return next;

  case_name := 'in a live organisation, giving one person both sides of a prohibited rule is refused by name, naming the rule and both permissions in words';
  passed := v_state_a is null and coalesce(ok_refused, false);
  detail := coalesce(v_state_a, msg_refused, 'no answer');
  return next;

  case_name := 'an exception needs a reason of twenty characters, from somebody who may promote configuration';
  passed := v_state_a is null and coalesce(ok_needs, false);
  detail := coalesce(v_state_a, msg_needs, 'no answer');
  return next;

  case_name := 'an administrator who may promote configuration records the exception with its reason, and it is kept and audited';
  passed := v_state_a is null and coalesce(ok_override, false);
  detail := coalesce(v_state_a, msg_override, 'no answer');
  return next;

  case_name := 'a material pairing is allowed and recorded as a conflict to review';
  passed := v_state_a is null and coalesce(ok_material, false);
  detail := coalesce(v_state_a, msg_material, 'no answer');
  return next;

  case_name := 'the administrator holds both sides of every rule by design, and is neither refused nor flagged';
  passed := v_state_a is null and coalesce(ok_admin, false);
  detail := coalesce(v_state_a, msg_admin, 'no answer');
  return next;

  case_name := 'with administration.audit_read the read door lists each conflict with its rule, severity, both permissions and exception, and names the administrators';
  passed := v_state_a is null and coalesce(ok_read, false);
  detail := coalesce(v_state_a, msg_read, 'no answer');
  return next;

  case_name := 'without administration.audit_read the read door is refused';
  passed := v_state_a is null and coalesce(ok_noread, false);
  detail := coalesce(v_state_a, msg_noread, 'no answer');
  return next;

  case_name := 'in a live organisation nobody changes their own roles, through setting, granting or ending';
  passed := v_state_a is null and coalesce(ok_self, false);
  detail := coalesce(v_state_a, msg_self, 'no answer');
  return next;

  case_name := 'a removed grant begun before today ends yesterday and stays on file, one begun today is withdrawn and audited, and a conflict whose grant went is resolved';
  passed := v_state_a is null and coalesce(ok_ended, false);
  detail := coalesce(v_state_a, msg_ended, 'no answer');
  return next;

  case_name := 'a promoted change that gives a role''s holder both sides of a prohibited rule is refused, and the role is left as it was';
  passed := v_state_a is null and coalesce(ok_role, false);
  detail := coalesce(v_state_a, msg_role, 'no answer');
  return next;

  case_name := 'before go-live a prohibited pairing is allowed and reported, the administrator may give themselves a role, and the organisation-wide pass records nothing twice';
  passed := v_state_b is null and coalesce(ok_prelive, false);
  detail := coalesce(v_state_b, msg_prelive, 'no answer');
  return next;

  case_name := 'no role template in any pack and no module role holds both sides of a prohibited rule in any pack';
  passed := v_breaks is null
            and exists (select 1 from erp_ref.pack_item pi where pi.object_kind = 'role')
            and exists (select 1 from erp_ref.pack_item pi where pi.object_kind = 'sod_rule' and pi.payload ->> 'severity' = 'prohibited');
  detail := coalesce(v_breaks, 'no prohibited pairing');
  return next;

  case_name := 'the jobs are still somebody''s: the clerk posts, the manager closes and pays, the buyer raises and the manager approves, the Responsible Person releases, the warehouse receives';
  passed := coalesce(
            v_fc @> array['finance.post']
            and v_fm @> array['finance.close_period', 'finance.approve_payment'] and not (v_fm @> array['finance.post'])
            and v_buyer @> array['procurement.requisition']
            and v_pm @> array['procurement.approve', 'procurement.order'] and not (v_pm @> array['procurement.requisition'])
            and v_qm @> array['quality.disposition'] and not (v_qm @> array['quality.release_batch'])
            and v_rp @> array['quality.release_batch'] and not (v_rp @> array['quality.disposition'])
            and v_purchasing @> array['procurement.requisition', 'procurement.order']
            and not (v_purchasing && array['procurement.approve', 'procurement.receive'])
            and v_warehouse @> array['procurement.receive']
            and v_finance @> array['finance.post', 'finance.approve_payment']
            and not (v_finance && array['finance.close_period', 'finance.reopen_period'])
            and v_quality @> array['quality.inspect', 'quality.disposition']
            and not (v_quality @> array['quality.release_batch'])
            and v_inventory @> array['inventory.adjust', 'inventory.write_off'], false);
  detail := format('finance clerk: %s; finance manager: %s; procurement manager: %s; quality manager: %s; responsible person: %s; purchasing: %s; finance: %s; quality: %s',
                   array_to_string(v_fc, ', '), array_to_string(v_fm, ', '), array_to_string(v_pm, ', '),
                   array_to_string(v_qm, ', '), array_to_string(v_rp, ', '), array_to_string(v_purchasing, ', '),
                   array_to_string(v_finance, ', '), array_to_string(v_quality, ', '));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in ('zzsoda-' || v_tag, 'zzsodb-' || v_tag));
  detail := 'two organisations, their people, rules, roles, grants, conflicts and the change set rolled back';
  return next;
end;
$$;
revoke all on function erp_test.duties_separated_suite() from public, anon, authenticated;

comment on function erp_test.duties_separated_suite() is
  'Separation of duties through the doors as a signed-in caller: a live '
  'organisation with the base pack''s rules, where a prohibited pairing is '
  'refused, an exception is recorded under administration.promote with a proper '
  'reason, a material pairing is recorded, administrators are exempt, the read '
  'door answers under administration.audit_read only, nobody changes their own '
  'roles, grants end rather than disappear and a promoted role change is '
  'refused; an organisation not yet live, where everything is allowed and '
  'reported; and the templates. Rolls back everything it made.';

create or replace function erp_test.assert_duties_separated_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 15;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.duties_separated_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DUTIES_SEPARATED_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_DUTIES_SEPARATED_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: a grant that should be refused went through, or one that should go through was refused.';
  end if;
  return format('duties separated: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_duties_separated_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. Generators, then the checks that read what changed
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
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_duties_separated_suite();
select erp_test.assert_approval_hold_suite();
select erp_test.assert_access_withdrawal_suite();
select erp_test.assert_warehouse_and_finance_jobs_suite();
