-- =============================================================================
-- An organisation writes its own approval chain
--
-- 20260916170000 taught an approval step to ask who raised the request:
-- erp.approval_step.approver_source may be line_manager, department_band or
-- named_assignment, and erp.step_approvers() answers each of them from the
-- routing engine that has known about departments, bands and named approvers
-- all along. The routing works.
--
-- Nothing can switch it on. A chain arrives in an organisation one way only —
-- an installer, erp.install_module_config(), building an 'approval_chain'
-- change-set item from arguments the installer chose — and the only editing
-- surface the product has is Configuration's module cards, which offer ONE
-- approver role and ONE threshold for procurement and ONE of each for sales.
-- No screen, and no door, can author a step at all, let alone one naming a
-- source. So an administrator can configure departments, membership, value
-- bands, named approvers and vacancy behaviour on Organisation and approval
-- routing, and still have no way to write a chain that reads any of it.
--
-- This adds the door and the screen. Three things about the door matter:
--
--   * erp.approval_chain, erp.approval_chain_version and erp.approval_step are
--     registered promotable surfaces (20260901130000), so
--     erp.guard_live_configuration() refuses a direct write to any of them in a
--     live organisation. The door therefore writes none of them: it builds one
--     change set with one 'approval_chain' item and submits it, exactly as an
--     installer does, and the applier writes the rows on promotion.
--   * Before go-live it approves and promotes its own change set, because there
--     is nobody else to ask. After go-live it stops at submitted and a second
--     administrator approves it on the Configuration screen. That is
--     erp.install_module_config()'s tail, and it is the whole point: who
--     approves what is exactly the kind of change the control exists for.
--   * It refuses a chain with no steps at the door rather than at the
--     promotion. erp.activate_approval_chain_version() already refuses one —
--     but by then the change set has been authored, submitted and approved, and
--     the person who typed it has gone. A refusal is worth more where the
--     mistake was made.
--
-- One thing had to be fixed on the way, and it is the same class of fault as
-- the one being repaired. erp.approval_step carries escalate_after with a check
-- constraint (0014) that an escalation must name somebody to escalate TO, and
-- erp.apply_change_set_item() never wrote escalate_to_role_id or
-- escalate_to_user_id. So a promoted step could not carry an escalation at all:
-- any payload with escalate_after violated the constraint and took the whole
-- promotion down. The applier now reads escalate_to_role and escalate_to_user
-- beside it, and the door refuses an escalation that names nobody.
-- =============================================================================

-- ── 1. The applier can write an escalation that has somewhere to go ──────────

-- Patched against the LIVE body rather than any file: 20260916170000 already
-- rewrote this arm to carry approver_source, so the text on disk in
-- 20260904920000 is not the text in the database. Both needles are asserted to
-- occur exactly once, and the aliases are ro2/u2 because ro and u are already
-- taken in the same statement.
do $applier$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_cols constant text :=
    E'          role_id, app_user_id, min_approvals, condition, escalate_after, allow_delegation)';
  v_vals constant text :=
    E'               (e.value ->> ''escalate_after'')::interval,\n'
    || E'               coalesce((e.value ->> ''allow_delegation'')::boolean, true)';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_cols, ''))) / length(v_cols) <> 1 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the approval step column list written by % is not the one this migration adds two columns to', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  if (length(v_def) - length(replace(v_def, v_vals, ''))) / length(v_vals) <> 1 then
    raise exception 'CLOVEERP_APPLIER_UNRECOGNISED: the escalation written by % is not the text this migration adds a target beside', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  v_new := replace(v_def, v_cols,
       E'          role_id, app_user_id, min_approvals, condition, escalate_after,\n'
    || E'          escalate_to_role_id, escalate_to_user_id, allow_delegation)');

  v_new := replace(v_new, v_vals,
       E'               (e.value ->> ''escalate_after'')::interval,\n'
    || E'               (select ro2.id from erp.role ro2\n'
    || E'                 where ro2.tenant_id = v_tenant and ro2.code = e.value ->> ''escalate_to_role''),\n'
    || E'               (select u2.id from erp.app_user u2\n'
    || E'                 where u2.tenant_id = v_tenant and u2.email = e.value ->> ''escalate_to_user''),\n'
    || E'               coalesce((e.value ->> ''allow_delegation'')::boolean, true)');

  execute v_new;
end
$applier$;

-- ── 2. The doors ─────────────────────────────────────────────────────────────

-- The three sources, said in words, so a form can offer them and a reader can
-- tell what each one asks for. A constant list rather than a table: the check
-- constraint on erp.approval_step.approver_source is what decides them, and a
-- table beside it could disagree with it.
create or replace function public.erp_approval_step_sources()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_array(
    jsonb_build_object(
      'source', 'line_manager',
      'name', 'The line manager',
      'description', 'The manager of the department the person who raised it belongs to.'),
    jsonb_build_object(
      'source', 'department_band',
      'name', 'The department value bands',
      'description', 'The value bands configured for that department, which decide who approves at what value.'),
    jsonb_build_object(
      'source', 'named_assignment',
      'name', 'The named approver',
      'description', 'The approver named for that person, their role or their department.'))
$$;

comment on function public.erp_approval_step_sources() is
  'The three ways an approval step can find its approver without naming one: '
  'the raiser''s line manager, their department''s value bands, or the approver '
  'named for them. The values erp.approval_step.approver_source accepts, in '
  'words a form can offer.';

-- Every chain this organisation holds, at the version in force where one is,
-- with who each step asks. Read-only and scoped by row security, like every
-- other read on this screen.
create or replace function public.erp_approval_chains()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with latest as (
    select c.id as chain_id, c.code, c.name, c.object_type, c.priority,
           c.status::text as chain_status,
           acv.id as version_id, acv.version, acv.status::text as version_status,
           acv.effective_from, acv.value_field,
           row_number() over (partition by c.id
             order by (acv.status = 'active') desc nulls last,
                      acv.version desc nulls last) as rn
      from erp.approval_chain c
      left join erp.approval_chain_version acv
        on acv.tenant_id = c.tenant_id and acv.approval_chain_id = c.id
     where c.tenant_id = erp.current_tenant_id()
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'chain_id', ch.chain_id,
           'code', ch.code,
           'name', coalesce(nullif(btrim(ch.name), ''), ch.code),
           'object_type', ch.object_type,
           'priority', ch.priority,
           'chain_status', ch.chain_status,
           'version', ch.version,
           'version_status', ch.version_status,
           'effective_from', ch.effective_from,
           'value_field', ch.value_field,
           'step_count', (
             select count(*) from erp.approval_step s
              where s.tenant_id = erp.current_tenant_id()
                and s.approval_chain_version_id = ch.version_id),
           'approvers', (
             select string_agg(
                      format('%s. %s — %s', s.seq,
                             coalesce(nullif(btrim(s.name), ''), s.code),
                             case s.approver_source
                               when 'line_manager' then 'the line manager'
                               when 'department_band' then 'the department value bands'
                               when 'named_assignment' then 'the named approver'
                               else coalesce(ro.name, ro.code,
                                             u.display_name, u.email, 'nobody')
                             end),
                      '; ' order by s.seq, s.code)
               from erp.approval_step s
               left join erp.role ro
                 on ro.tenant_id = s.tenant_id and ro.id = s.role_id
               left join erp.app_user u
                 on u.tenant_id = s.tenant_id and u.id = s.app_user_id
              where s.tenant_id = erp.current_tenant_id()
                and s.approval_chain_version_id = ch.version_id),
           'waiting_change', (
             select cs.code
               from erp.change_set cs
               join erp.change_set_item i
                 on i.tenant_id = cs.tenant_id and i.change_set_id = cs.id
              where cs.tenant_id = erp.current_tenant_id()
                and cs.status in ('draft', 'ready', 'approved')
                and i.object_kind = 'approval_chain'
                and i.object_key = ch.code
              order by cs.created_at desc
              limit 1))
           order by ch.object_type, ch.code), '[]'::jsonb)
    from latest ch
   where ch.rn = 1
$$;

comment on function public.erp_approval_chains() is
  'Every approval chain this organisation holds, at the version in force where '
  'there is one: what it applies to, how many steps it has, who each step asks, '
  'and the code of a proposed change to it still waiting to be promoted.';

-- The door. It authors configuration; it does not write it.
create or replace function public.erp_propose_approval_chain(
  p_code         text,
  p_name         text,
  p_object_type  text,
  p_steps        jsonb,
  p_applies_when jsonb   default null,
  p_value_field  text    default null,
  p_priority     integer default null,
  p_note         text    default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_code    text := lower(btrim(coalesce(p_code, '')));
  v_name    text := btrim(coalesce(p_name, ''));
  v_type    text := btrim(coalesce(p_object_type, ''));
  v_field   text := nullif(btrim(coalesce(p_value_field, '')), '');
  v_note    text := nullif(btrim(coalesce(p_note, '')), '');
  v_steps   jsonb := '[]'::jsonb;
  v_step    jsonb;
  v_seen    text[] := '{}';
  v_i       integer := 0;
  v_seq     integer;
  v_scode   text;
  v_sname   text;
  v_role    text;
  v_user    text;
  v_source  text;
  v_min     integer;
  v_after   text;
  v_torole  text;
  v_touser  text;
  v_cond    jsonb;
  v_cs      uuid;
  v_status  text;
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'change_set', null);
  v_tenant := erp.require_tenant_id();

  if v_code = '' or v_name = '' or v_type = '' then
    raise exception 'CLOVEERP_VALIDATION: an approval chain needs a code, a name and the kind of thing it approves'
      using errcode = '22023',
            hint = 'Give it a short code, a name people will read, and the object type it applies to.';
  end if;

  if p_applies_when is not null
     and jsonb_typeof(p_applies_when) not in ('object', 'boolean') then
    raise exception 'CLOVEERP_VALIDATION: the condition that decides when this chain applies must be a condition, not a word'
      using errcode = '22023',
            hint = 'Leave it empty for every request of this kind, or send a condition such as the document type it applies to.';
  end if;

  if p_steps is null or jsonb_typeof(p_steps) <> 'array'
     or jsonb_array_length(p_steps) = 0 then
    raise exception 'CLOVEERP_APPROVAL_CHAIN_NEEDS_STEPS: a chain with no steps would approve everything unchecked'
      using errcode = '23514',
            hint = 'Add at least one step saying who approves: a role, a named person, or one of the three sources that read the organisation.';
  end if;

  for v_step in select e.value from jsonb_array_elements(p_steps) e
  loop
    v_i := v_i + 1;

    if coalesce(v_step ->> 'seq', '') <> '' and (v_step ->> 'seq') !~ '^[0-9]+$' then
      raise exception 'CLOVEERP_VALIDATION: step % gives an order that is not a whole number', v_i
        using errcode = '22023',
              hint = 'Number the steps 1, 2, 3. Two steps sharing a number are asked at the same time.';
    end if;
    v_seq   := coalesce(nullif(v_step ->> 'seq', '')::integer, v_i);
    v_scode := lower(btrim(coalesce(nullif(btrim(coalesce(v_step ->> 'code', '')), ''),
                                    'step_' || v_seq)));
    v_sname := nullif(btrim(coalesce(v_step ->> 'name', '')), '');
    v_role  := nullif(btrim(coalesce(v_step ->> 'role', '')), '');
    v_user  := nullif(btrim(coalesce(v_step ->> 'user', '')), '');
    v_source := nullif(btrim(coalesce(v_step ->> 'approver_source', '')), '');

    if v_scode = any(v_seen) then
      raise exception 'CLOVEERP_VALIDATION: two steps of this chain both call themselves %', v_scode
        using errcode = '23505',
              hint = 'Give each step its own code. Steps sharing an order number are asked together and still need different codes.';
    end if;
    v_seen := v_seen || v_scode;

    if v_source is not null and (v_role is not null or v_user is not null) then
      raise exception 'CLOVEERP_APPROVAL_STEP_TWO_APPROVERS: step % names an approver and also a source to find one', v_scode
        using errcode = '23514',
              hint = 'A step either names the role or person who approves, or asks where to look. Clear one of the two.';
    end if;

    if v_source is null and v_role is null and v_user is null then
      raise exception 'CLOVEERP_APPROVAL_STEP_NO_APPROVER: step % says nothing about who approves it', v_scode
        using errcode = '23514',
              hint = 'Choose a role, a person, or one of the three sources: the line manager, the department value bands, or the named approver.';
    end if;

    if v_source is not null
       and v_source not in ('line_manager', 'department_band', 'named_assignment') then
      raise exception 'CLOVEERP_APPROVAL_STEP_UNKNOWN_SOURCE: step % asks for %, which is not a place this product looks for an approver', v_scode, v_source
        using errcode = '23514',
              hint = 'The three sources are the line manager, the department value bands and the named approver.';
    end if;

    if v_role is not null
       and not exists (select 1 from erp.role r
                        where r.tenant_id = v_tenant and r.code = v_role
                          and r.status = 'active') then
      raise exception 'CLOVEERP_APPROVAL_STEP_UNKNOWN_APPROVER: step % names the role %, and this organisation has no such role', v_scode, v_role
        using errcode = '23503',
              hint = 'Choose a role this organisation holds, or create it under Roles and permissions first.';
    end if;

    if v_user is not null
       and not exists (select 1 from erp.app_user u
                        where u.tenant_id = v_tenant and u.email = v_user
                          and u.status = 'active') then
      raise exception 'CLOVEERP_APPROVAL_STEP_UNKNOWN_APPROVER: step % names %, and nobody in this organisation has that email', v_scode, v_user
        using errcode = '23503',
              hint = 'Choose somebody who has already been invited, or invite them first.';
    end if;

    if coalesce(v_step ->> 'min_approvals', '') <> ''
       and (v_step ->> 'min_approvals') !~ '^[0-9]+$' then
      raise exception 'CLOVEERP_VALIDATION: step % asks for a number of approvals that is not a whole number', v_scode
        using errcode = '22023', hint = 'One is the usual answer. Two means two of the eligible approvers must agree.';
    end if;
    v_min := coalesce(nullif(v_step ->> 'min_approvals', '')::integer, 1);
    if v_min < 1 then
      raise exception 'CLOVEERP_VALIDATION: step % asks for fewer than one approval, which is no approval at all', v_scode
        using errcode = '22023', hint = 'Set it to one, or leave it empty.';
    end if;

    v_after  := nullif(btrim(coalesce(v_step ->> 'escalate_after', '')), '');
    if coalesce(v_step ->> 'escalate_after_hours', '') <> '' then
      if (v_step ->> 'escalate_after_hours') !~ '^[0-9]+(\.[0-9]+)?$' then
        raise exception 'CLOVEERP_VALIDATION: step % waits a number of hours before escalating, and that is not a number', v_scode
          using errcode = '22023', hint = 'Give the wait in whole hours, or leave it empty for no escalation.';
      end if;
      v_after := (v_step ->> 'escalate_after_hours') || ' hours';
    end if;
    v_torole := nullif(btrim(coalesce(v_step ->> 'escalate_to_role', '')), '');
    v_touser := nullif(btrim(coalesce(v_step ->> 'escalate_to_user', '')), '');

    if v_after is not null and v_torole is null and v_touser is null then
      raise exception 'CLOVEERP_VALIDATION: step % escalates after a wait and names nobody to escalate to', v_scode
        using errcode = '23514',
              hint = 'Name the role or person the step goes to when nobody has decided in time, or clear the wait.';
    end if;

    if v_torole is not null
       and not exists (select 1 from erp.role r
                        where r.tenant_id = v_tenant and r.code = v_torole
                          and r.status = 'active') then
      raise exception 'CLOVEERP_APPROVAL_STEP_UNKNOWN_APPROVER: step % escalates to the role %, and this organisation has no such role', v_scode, v_torole
        using errcode = '23503', hint = 'Choose a role this organisation holds.';
    end if;

    if v_touser is not null
       and not exists (select 1 from erp.app_user u
                        where u.tenant_id = v_tenant and u.email = v_touser
                          and u.status = 'active') then
      raise exception 'CLOVEERP_APPROVAL_STEP_UNKNOWN_APPROVER: step % escalates to %, and nobody in this organisation has that email', v_scode, v_touser
        using errcode = '23503', hint = 'Choose somebody who has already been invited.';
    end if;

    if v_step ? 'condition'
       and jsonb_typeof(v_step -> 'condition') not in ('object', 'boolean') then
      raise exception 'CLOVEERP_VALIDATION: the condition on step % must be a condition, not a word', v_scode
        using errcode = '22023',
              hint = 'Leave it empty for a step that always fires, or send a condition such as a value above which it does.';
    end if;
    v_cond := coalesce(v_step -> 'condition', 'true'::jsonb);

    v_steps := v_steps || jsonb_build_array(
      jsonb_build_object(
        'seq', v_seq,
        'code', v_scode,
        'name', coalesce(v_sname, v_scode),
        'min_approvals', v_min,
        'condition', v_cond,
        'allow_delegation',
          coalesce(nullif(v_step ->> 'allow_delegation', ''), 'true')
            not in ('false', 'f', 'no', '0'))
      || case
           when v_source is not null then jsonb_build_object('approver_source', v_source)
           when v_user is not null then jsonb_build_object('approver_kind', 'user', 'user', v_user)
           else jsonb_build_object('approver_kind', 'role', 'role', v_role)
         end
      || case when v_after is null then '{}'::jsonb
              else jsonb_build_object('escalate_after', v_after) end
      || case when v_torole is null then '{}'::jsonb
              else jsonb_build_object('escalate_to_role', v_torole) end
      || case when v_touser is null then '{}'::jsonb
              else jsonb_build_object('escalate_to_user', v_touser) end);
  end loop;

  -- One change set, one item, submitted. The code carries the clock because a
  -- chain is amended as often as the organisation changes shape, and a set
  -- named after the chain alone could be proposed exactly once.
  v_cs := erp.create_change_set(
    format('approval-chain-%s-%s', v_code,
           to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')),
    format('Approval chain: %s', v_name),
    coalesce(v_note,
             format('Who approves a %s, in what order, and where each approver is found.',
                    replace(v_type, '_', ' '))));

  perform erp.add_change_set_item(
    v_cs, 'approval_chain', v_code,
    jsonb_build_object(
      'code', v_code,
      'name', v_name,
      'object_type', v_type,
      'applies_when', coalesce(p_applies_when, 'true'::jsonb),
      'priority', coalesce(p_priority, 100),
      'steps', v_steps)
    || case when v_field is null then '{}'::jsonb
            else jsonb_build_object('value_field', v_field) end,
    'upsert', null::date, v_note);

  perform erp.submit_change_set(v_cs);

  -- erp.install_module_config()'s tail, and for the same reason. Before an
  -- organisation declares itself live there is no second person for the control
  -- to find, and refusing here would leave a new organisation unable to say who
  -- approves anything. Afterwards the set is left submitted, because who
  -- approves what is precisely the change a second administrator should see.
  if not erp.tenant_is_live() then
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
  end if;

  select cs.status::text into v_status
    from erp.change_set cs
   where cs.tenant_id = v_tenant and cs.id = v_cs;

  return jsonb_build_object(
    'change_set_id', v_cs,
    'code', v_code,
    'name', v_name,
    'status', v_status,
    'steps', jsonb_array_length(v_steps),
    'in_force', v_status = 'promoted');
end;
$$;

comment on function public.erp_propose_approval_chain(text, text, text, jsonb, jsonb, text, integer, text) is
  'Under administration.configure: authors an approval chain and its steps as '
  'one B6 change set and submits it. A step names a role, names a person, or '
  'asks one of the three sources that read the organisation — the raiser''s '
  'line manager, their department''s value bands, or the approver named for '
  'them. Promoted at once while the organisation is being set up; left for a '
  'second administrator once it is live. Writes no configuration itself: '
  'erp.approval_chain and its versions and steps are promotable surfaces, and a '
  'live organisation refuses a direct write to them.';

revoke all on function public.erp_approval_step_sources() from public, anon;
revoke all on function public.erp_approval_chains() from public, anon;
revoke all on function public.erp_propose_approval_chain(text, text, text, jsonb, jsonb, text, integer, text)
  from public, anon;
grant execute on function public.erp_approval_step_sources() to authenticated, service_role;
grant execute on function public.erp_approval_chains() to authenticated, service_role;
grant execute on function public.erp_propose_approval_chain(text, text, text, jsonb, jsonb, text, integer, text)
  to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_approval_chain', 'erp.authorise',
   'Authors an approval chain and its steps as one B6 change set under '
   'administration.configure and submits it. It writes no promotable surface: '
   'erp.approval_chain, erp.approval_chain_version and erp.approval_step are '
   'written by erp.apply_change_set_item() on promotion, which is the only '
   'route a live organisation accepts (20260916300000).')
on conflict (function_name) do update set gate = excluded.gate,
                                          rationale = excluded.rationale;

-- ── 3. The words, and the refusals ───────────────────────────────────────────

select erp.register_refusal('CLOVEERP_APPROVAL_CHAIN_NEEDS_STEPS',
  'Proposing an approval chain with no steps in it.',
  'A chain with no steps approves everything the moment it is asked, which is the opposite of what an approval chain is for. The database refuses to put such a version in force, so a chain proposed without steps could never have been promoted.',
  'Add at least one step saying who approves: a role, a named person, or one of the three sources that read the organisation — the line manager, the department value bands, or the named approver.');

select erp.register_refusal('CLOVEERP_APPROVAL_STEP_TWO_APPROVERS',
  'A step that both names an approver and asks where to find one.',
  'A step answers "who approves this?" once. Naming a role and also asking for the line manager leaves two answers and no way to choose between them, and the database refuses the row.',
  'Decide which the step means: clear the role or person to route by department, membership and named approvers, or clear the source to name the approver outright.');

select erp.register_refusal('CLOVEERP_APPROVAL_STEP_NO_APPROVER',
  'A step that says nothing about who approves it.',
  'A step nobody is asked cannot be satisfied, so the document it holds would wait for ever.',
  'Choose a role, a person, or one of the three sources: the line manager, the department value bands, or the named approver.');

select erp.register_refusal('CLOVEERP_APPROVAL_STEP_UNKNOWN_SOURCE',
  'A step asking for an approver somewhere this product does not look.',
  'A step that names a source is answered by the routing engine, and it knows three: the manager of the raiser''s department, the value bands of that department, and the approver named for that person.',
  'Use one of the three sources — the line manager, the department value bands, or the named approver — or name the role or person instead.');

select erp.register_refusal('CLOVEERP_APPROVAL_STEP_UNKNOWN_APPROVER',
  'A step naming a role or a person this organisation does not have.',
  'The chain is promoted into this organisation, and a step naming a role nobody holds or an email nobody has would resolve to nobody.',
  'Choose a role this organisation holds or somebody already invited to it. Create the role under Roles and permissions, or invite the person, and propose the chain again.');

-- The Organisation screen's new words, each with the row it is renamed by. The
-- panel's own strings are seeded too, although supabase/ci/screen_strings.sh
-- cannot see them: a generic JSX tag — <AutoPanel<Chain> … — does not match its
-- harvest, and a string the check happens not to demand is still a string
-- somebody reads.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Approval chains',
     'The heading of the card that composes an approval chain, and of the panel listing the chains in force.'),
    ('A chain is the order things are approved in. Bands and named approvers above say who; a chain says how many steps there are, which of them apply, and where each one looks. Composing one raises a change: promoted at once while the organisation is being set up, and left for a second administrator once it is live.',
     'What the card that composes an approval chain explains.'),
    ('Compose an approval chain',
     'The action on the Organisation screen that authors an approval chain and its steps.'),
    ('The steps a request goes through before it may go ahead. A step names the role or the person who approves it, or asks for one of the three that read the organisation: the line manager of whoever raised it, the value bands of their department, or the approver named for them. This writes nothing directly — it raises a change, which the Configuration screen approves and promotes.',
     'What the form that composes an approval chain does.'),
    ('Propose the chain',
     'The button that submits a composed approval chain as a change.'),
    ('What this chain is called on the approvals people see.',
     'The hint under the name of an approval chain.'),
    ('Approves',
     'The field naming the kind of thing an approval chain is asked about, and the column showing it.'),
    ('The kind of thing this chain is asked about.',
     'The hint under the kind of thing an approval chain approves.'),
    ('Only documents of type',
     'The field narrowing an approval chain to one document type.'),
    ('Leave empty and the chain is considered for every request of the kind above.',
     'The hint under the document type an approval chain is narrowed to.'),
    ('The figure a threshold reads',
     'The field naming the value a step''s threshold is measured against.'),
    ('Set this where a step only applies above a value. Leave it empty for a chain that does not depend on how much something is worth.',
     'The hint under the figure a threshold reads.'),
    ('Steps',
     'The list of steps on the form that composes an approval chain, and the column counting them.'),
    ('One row per step, in the order they are asked. Steps sharing a number are asked at the same time. Name a role or a person, or choose where to look — never both.',
     'The hint above the steps of an approval chain.'),
    ('Where to look',
     'The column of a step choosing one of the three sources that find an approver.'),
    ('Or the role',
     'The column of a step naming the role that approves it.'),
    ('Or the person',
     'The column of a step naming the person who approves it.'),
    ('Approvals needed',
     'The column of a step saying how many of the eligible approvers must agree.'),
    ('Only above',
     'The column of a step saying the value above which it applies.'),
    ('Escalate to',
     'The column of a step naming who it goes to when nobody has decided in time.'),
    ('Why this chain exists',
     'The reason field on the form that composes an approval chain.'),
    ('Every chain this organisation holds, at the version in force. A step asking for the line manager, the department value bands or the named approver reads the departments, bands and assignments configured above; a step naming a role or a person does not.',
     'What the panel listing approval chains explains.'),
    ('No approval chains yet. Compose one under Actions above, or install a module on the Configuration screen and take the chain it brings. Until one exists, nothing is held for approval.',
     'Said when this organisation holds no approval chain.'),
    ('Who approves',
     'The column listing each step of a chain and who it asks.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

-- ── 4. The generators, then the assertions ───────────────────────────────────

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_resource_coverage('en');
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

-- Two organisations' worth of behaviour in one fixture: the same door, called
-- before and after the environment declares itself live, has to do two
-- different things, and the second of them is the control the product's whole
-- promotion story rests on.
create or replace function erp_test.approval_chain_authoring_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_mgr uuid; v_dept uuid;
  v_second uuid; v_stoken text;
  v_res    jsonb; v_cs uuid; v_ver uuid;
  v_n      integer; v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-chain-author', 'Approval chain authoring suite',
                              'admin@zz-chain-author.test', 'Chain Author Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000c1', 'admin@zz-chain-author.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000c1')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id into v_entity
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;

  -- A department with a manager, so a promoted line_manager step has somebody
  -- to resolve to and the chain is not merely written but usable.
  v_mgr := (public.erp_invite_principal('mgr@zz-chain-author.test', 'Department Manager')
              ->> 'app_user_id')::uuid;
  insert into erp.department (tenant_id, entity_id, code, name, manager_user_id, status)
  values (v_tenant, v_entity, 'ZZCHA', 'Buying', v_mgr, 'active')
  returning id into v_dept;
  insert into erp.principal_department (tenant_id, app_user_id, department_id, is_primary, status)
  values (v_tenant, v_admin, v_dept, true, 'active');

  -- ── 1. Before go-live, proposing is putting it in force ──────────────────
  v_cases := v_cases + 1;
  v_res := public.erp_propose_approval_chain(
    'zz_not_live', 'Purchase order approval', 'document',
    jsonb_build_array(
      jsonb_build_object('seq', 1, 'code', 'manager', 'name', 'Line manager',
                         'approver_source', 'line_manager'),
      jsonb_build_object('seq', 2, 'code', 'bands', 'name', 'Department bands',
                         'approver_source', 'department_band', 'min_approvals', 1),
      jsonb_build_object('seq', 3, 'code', 'named', 'name', 'Named approver',
                         'approver_source', 'named_assignment'),
      jsonb_build_object('seq', 4, 'code', 'admin', 'name', 'Administrator',
                         'role', 'administrator', 'escalate_after_hours', 48,
                         'escalate_to_role', 'administrator')),
    jsonb_build_object('==', jsonb_build_array(
      jsonb_build_object('var', 'document_type'), 'purchase_order')),
    'total_minor', 100, 'Proposed by the authoring suite');
  case_name := 'a chain proposed before go-live is promoted and in force';
  passed := (v_res ->> 'status') = 'promoted' and (v_res ->> 'in_force')::boolean;
  detail := format('the change set is %s', coalesce(v_res ->> 'status', 'missing'));
  return next;

  select acv.id into v_ver
    from erp.approval_chain c
    join erp.approval_chain_version acv
      on acv.tenant_id = c.tenant_id and acv.approval_chain_id = c.id
   where c.tenant_id = v_tenant and c.code = 'zz_not_live' and acv.status = 'active';

  -- ── 2. And its steps carry the sources the routing engine reads ──────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.approval_step s
   where s.tenant_id = v_tenant and s.approval_chain_version_id = v_ver
     and s.approver_source in ('line_manager', 'department_band', 'named_assignment');
  case_name := 'its steps carry the three sources that read the organisation';
  passed := v_n = 3;
  detail := format('%s of 3 sourced step(s) written', v_n);
  return next;

  -- ── 3. A sourced step resolves to the person the source names ────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.approval_step s
   where s.tenant_id = v_tenant and s.approval_chain_version_id = v_ver
     and s.approver_source = 'line_manager'
     and s.role_id is null and s.app_user_id is null;
  case_name := 'a sourced step names no role and no person of its own';
  passed := v_n = 1;
  detail := format('%s step(s) ask the line manager and nobody else', v_n);
  return next;

  -- ── 4. The escalation the applier could not write before this migration ──
  v_cases := v_cases + 1;
  case_name := 'a step that escalates after a wait has somewhere to escalate to';
  passed := exists (
    select 1 from erp.approval_step s
      join erp.role r on r.tenant_id = s.tenant_id and r.id = s.role_id
     where s.tenant_id = v_tenant and s.approval_chain_version_id = v_ver
       and s.code = 'admin' and r.code = 'administrator'
       and s.escalate_after = interval '48 hours'
       and s.escalate_to_role_id is not null);
  detail := 'the promoter now carries escalate_to_role, so escalate_after can be promoted at all';
  return next;

  -- ── 5. And the screen can read it back ──────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from jsonb_array_elements(public.erp_approval_chains()) e
   where e.value ->> 'code' = 'zz_not_live'
     and (e.value ->> 'step_count')::integer = 4
     and (e.value ->> 'approvers') like '%the line manager%';
  case_name := 'the chains door reads the chain back with its steps and who they ask';
  passed := v_n = 1;
  detail := format('%s matching row(s) from erp_approval_chains', v_n);
  return next;

  -- ── 6. A step is one thing or the other, never both ─────────────────────
  v_cases := v_cases + 1;
  begin
    perform public.erp_propose_approval_chain('zz_both', 'Both at once', 'document',
      jsonb_build_array(jsonb_build_object('seq', 1, 'code', 'both', 'name', 'Both',
        'role', 'administrator', 'approver_source', 'line_manager')));
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_STEP_TWO_APPROVERS%'; v_msg := left(sqlerrm, 90);
  end;
  case_name := 'a step that names a role and also asks for a source is refused';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 7. A chain with no steps is refused where it was typed ──────────────
  v_cases := v_cases + 1;
  begin
    perform public.erp_propose_approval_chain('zz_empty', 'Nothing to ask', 'document',
                                              '[]'::jsonb);
    v_ok := false; v_msg := 'it was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APPROVAL_CHAIN_NEEDS_STEPS%'; v_msg := left(sqlerrm, 90);
  end;
  case_name := 'a chain with no steps is refused at the door, not at the promotion';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── The organisation goes live, with a second administrator to ask ───────
  -- Two-person approval is what the live half of this organisation proves, and
  -- administrators may approve their own changes by default (20260914098000).
  -- Switched off while the window is still open, so what refuses below is the
  -- control and not the setting.
  perform erp_test.administrator_approval_off(v_tenant);
  v_res := public.erp_invite_principal('second@zz-chain-author.test', 'Second Admin');
  v_second := (v_res ->> 'app_user_id')::uuid;
  v_stoken := v_res ->> 'token';
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000c2', 'second@zz-chain-author.test');
  update erp.environment set is_live = true where tenant_id = v_tenant and is_self;

  -- ── 8. In a live organisation the proposal stops at submitted ───────────
  v_cases := v_cases + 1;
  v_res := public.erp_propose_approval_chain(
    'zz_live', 'Requisition approval', 'document',
    jsonb_build_array(jsonb_build_object('seq', 1, 'code', 'manager',
      'name', 'Line manager', 'approver_source', 'line_manager')));
  v_cs := (v_res ->> 'change_set_id')::uuid;
  case_name := 'a chain proposed in a live organisation waits for a second administrator';
  passed := (v_res ->> 'status') = 'ready' and not (v_res ->> 'in_force')::boolean;
  detail := format('the change set is %s', coalesce(v_res ->> 'status', 'missing'));
  return next;

  -- ── 9. And nothing is written until it is promoted ──────────────────────
  v_cases := v_cases + 1;
  case_name := 'and no chain, version or step exists until it is promoted';
  passed := not exists (select 1 from erp.approval_chain c
                         where c.tenant_id = v_tenant and c.code = 'zz_live')
        and not exists (select 1 from erp.approval_step s
                          join erp.approval_chain_version acv
                            on acv.tenant_id = s.tenant_id
                           and acv.id = s.approval_chain_version_id
                          join erp.approval_chain c
                            on c.tenant_id = acv.tenant_id
                           and c.id = acv.approval_chain_id
                         where c.tenant_id = v_tenant and c.code = 'zz_live');
  detail := 'the chain and its steps arrive with the promotion, not with the proposal';
  return next;

  -- ── 10. The administrator who proposed it may not wave it through ───────
  v_cases := v_cases + 1;
  begin
    perform erp.approve_change_set(v_cs);
    v_ok := false; v_msg := 'the author approved their own change';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL%'; v_msg := left(sqlerrm, 90);
  end;
  case_name := 'the administrator who proposed the chain may not approve it';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 11. A second administrator can, and then the step is there ─────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000c2')::text, true);
  perform erp.claim_invitation(v_stoken);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000c1')::text, true);

  v_cases := v_cases + 1;
  case_name := 'once a second administrator promotes it, the step is in force with its source';
  passed := exists (
    select 1 from erp.approval_step s
      join erp.approval_chain_version acv
        on acv.tenant_id = s.tenant_id and acv.id = s.approval_chain_version_id
      join erp.approval_chain c
        on c.tenant_id = acv.tenant_id and c.id = acv.approval_chain_id
     where c.tenant_id = v_tenant and c.code = 'zz_live'
       and acv.status = 'active' and s.approver_source = 'line_manager');
  detail := 'separation of duties has to be satisfiable or it is only an outage';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 12. Undone ──────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-chain-author')
        and not exists (select 1 from auth.users
                         where id in ('00000000-0000-4000-8000-0000000000c1',
                                      '00000000-0000-4000-8000-0000000000c2'));
  detail := 'zz-chain-author rolled back with its chains, versions and steps';
  return next;

  if v_cases <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_chain_authoring_suite ran % cases, expected 12', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.approval_chain_authoring_suite() from public, anon;

create or replace function erp_test.assert_approval_chain_authoring_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _chain_author on commit drop as
    select * from erp_test.approval_chain_authoring_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _chain_author;
  drop table _chain_author;
  if v_fail > 0 then
    raise exception E'CLOVEERP_APPROVAL_CHAIN_AUTHORING_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_chain_authoring_suite ran % cases, expected 12', v_all;
  end if;
  return format('an organisation writes its own approval chain: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_approval_chain_authoring_suite() from public, anon;

select erp.apply_execute_grants();

select erp.assert_suite_verdicts_strict();
select erp.assert_ci_coverage();

select erp_test.assert_approval_chain_authoring_suite();
select erp_test.assert_approval_step_source_suite();
