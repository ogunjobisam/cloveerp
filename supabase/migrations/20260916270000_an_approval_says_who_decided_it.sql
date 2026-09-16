-- =============================================================================
-- An approval says who decided it, and never asks nobody
--
-- Three things the owner has decided, and one they asked for and did not get.
--
--   1. A request that resolves to nobody goes to the administrators. Today it
--      refuses — CLOVEERP_APPROVAL_STEP_UNSTAFFED — and the document stops. A
--      refusal is the right answer to "this organisation has nobody who can
--      approve anything"; it is the wrong answer to "the person who normally
--      approves this has left", which is the case that actually happens.
--
--   2. Whoever raised a document may approve it WHERE NOBODY ELSE CAN.
--      20260914098000 already granted exactly this to an administrator, and
--      stopped there; for everybody else the case still refuses with
--      CLOVEERP_APPROVAL_NO_OTHER_APPROVER, so a company whose one buyer is
--      also its one approver cannot raise anything at all unless that person
--      happens to hold Promote configuration. The allowance is widened to
--      anybody who is the only candidate. Where a second approver exists the
--      exclusion stands, unchanged, because there it buys what it was written
--      to buy.
--
--   3. Except where somebody has said those two duties are separate. An
--      organisation that has written a separation rule pairing the raising of
--      a document with its approval means it, and the allowance gives way to
--      it. The switch stays, so a company that wants neither can have neither.
--
--   4. And the history. The owner asked to know "what was approved or not".
--      erp_approval_audit answers who each step went TO, because it reads the
--      routing stamp, which is written when the request is captured. The yes or
--      no lives on erp.approval_task and no door has ever read it across the
--      organisation — only per document. public.erp_approval_decisions() does.
--
-- Nothing here changes who is asked first. The department, the named approver
-- and the line manager still decide that, through the step's source
-- (20260916170000). This decides what happens when that answer is nobody, and
-- whether the answer may be the person asking.
-- =============================================================================

-- ── 1. Whether a person may approve their own ────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema, max_scope_level, is_singleton,
   default_value, consequence)
values
  ('approval.self_approval', 'policy', 'administration', 'config.approval.self_approval',
   'Whether the person who raised something may satisfy an approval step they are themselves an '
   'approver for.',
   '{"type": "object", "required": ["allowed"], "additionalProperties": false,
     "properties": {"allowed": {"type": "boolean"}}}'::jsonb,
   'tenant', true, '{"allowed": true}'::jsonb,
   'Allowed: somebody who raises a document and is an approver for one of its steps satisfies that '
   'step themselves, and the decision records that it was their own request. A separation of duties '
   'rule pairing the two still overrides it. Not allowed: every step needs somebody else, and a '
   'request nobody else can approve goes to the administrators.')
on conflict (code) do update set
  domain = excluded.domain, module_code = excluded.module_code, name_key = excluded.name_key,
  description = excluded.description, value_schema = excluded.value_schema,
  max_scope_level = excluded.max_scope_level, is_singleton = excluded.is_singleton,
  default_value = excluded.default_value, consequence = excluded.consequence;

-- The config type names a key, and a key with no words is a setting the
-- terminology screen offers and never shows. The sibling setting
-- (20260914098000) carries both locales, so this one does too.
insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('config.approval.self_approval', 'en', 'Somebody may approve what they raised', 'administration',
   'The setting that lets the person who raised something satisfy an approval step they are an approver for.'),
  ('config.approval.self_approval', 'de', 'Eigene Anforderungen dürfen genehmigt werden', 'administration',
   'The setting that lets the person who raised something satisfy an approval step they are an approver for.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

create or replace function erp.self_approval_allowed()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce((erp.config_value('approval.self_approval') ->> 'allowed')::boolean, true)
$$;

revoke all on function erp.self_approval_allowed() from public, anon, authenticated;

comment on function erp.self_approval_allowed() is
  'Whether this organisation lets somebody approve what they raised '
  '(approval.self_approval). On unless the organisation switched it off, and '
  'overridden for a person a separation rule names either way.';

-- A separation rule is a pair of permission sets one principal should not hold
-- together. Where one side of such a rule names the permission that RAISES this
-- document and the person holds something on the other side, the organisation
-- has said in writing that raising and approving are different duties here, and
-- that is a stronger statement than the tenant-wide allowance.
create or replace function erp.duties_separate_raising_from_approving(
  p_app_user_id uuid, p_create_permission text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1
      from erp.sod_rule r
     where r.tenant_id = erp.current_tenant_id()
       and r.status = 'active'
       and (
         (p_create_permission = any (r.permissions_a)
          and exists (select 1 from unnest(r.permissions_b) b
                       where erp.has_permission(b, null, null, null, p_app_user_id)))
         or
         (p_create_permission = any (r.permissions_b)
          and exists (select 1 from unnest(r.permissions_a) a
                       where erp.has_permission(a, null, null, null, p_app_user_id)))
       ));
$$;

revoke all on function erp.duties_separate_raising_from_approving(uuid, text) from public, anon, authenticated;

comment on function erp.duties_separate_raising_from_approving(uuid, text) is
  'Whether a separation of duties rule names the permission that raises this '
  'kind of document on one side and something this person holds on the other. '
  'An organisation that wrote such a rule meant it, so it beats the '
  'self-approval allowance rather than the other way round.';

create or replace function erp.may_approve_own(p_app_user_id uuid, p_document_id uuid)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_perm   text;
begin
  if p_app_user_id is null then
    return false;
  end if;
  if not erp.self_approval_allowed() then
    return false;
  end if;

  select coalesce(dt.create_permission, bt.create_permission) into v_perm
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where d.tenant_id = v_tenant and d.id = p_document_id;

  if v_perm is null then
    return true;
  end if;

  return not erp.duties_separate_raising_from_approving(p_app_user_id, v_perm);
end;
$$;

revoke all on function erp.may_approve_own(uuid, uuid) from public, anon, authenticated;

comment on function erp.may_approve_own(uuid, uuid) is
  'Whether the person who raised this document may satisfy a step of its own '
  'approval: the organisation allows it, and no separation rule pairs the '
  'permission that raised it with one they hold.';

-- The policy says whether somebody MAY approve their own. This says whether
-- they are the only person who WAS asked. The owner's rule needs both: a
-- company with a second approver still waits for them, and only a person
-- nobody else can relieve decides their own.
create or replace function erp.sole_approver_asked(p_request_id uuid, p_app_user_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select not exists (
    select 1
      from erp.approval_task t
     where t.tenant_id = erp.current_tenant_id()
       and t.approval_request_id = p_request_id
       and t.status <> 'skipped'
       and t.assignee_user_id is distinct from p_app_user_id);
$$;

revoke all on function erp.sole_approver_asked(uuid, uuid) from public, anon, authenticated;

comment on function erp.sole_approver_asked(uuid, uuid) is
  'Whether this person is the only one asked on this request. Beside '
  'erp.may_approve_own(), which says whether the organisation would allow them '
  'to decide their own at all: a second approver still gets to be the second '
  'opinion the exclusion was written for.';

-- ── 2. And who is asked when the answer is nobody ────────────────────────────

create or replace function erp.organisation_administrators()
returns table (app_user_id uuid)
language sql
stable
security invoker
set search_path = ''
as $$
  -- The same permission the administrator override reads, for the same reason
  -- it was chosen there (20260914098000): a new permission cannot be granted in
  -- a live organisation except through an approval, which is the thing being
  -- unblocked.
  select distinct ur.app_user_id
    from erp.user_role ur
    join erp.role_permission rp
      on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
    join erp.app_user u
      on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
   where ur.tenant_id = erp.current_tenant_id()
     and rp.permission_code = 'administration.promote'
     and u.status = 'active'
     and ur.valid_from <= current_date
     and (ur.valid_to is null or ur.valid_to >= current_date);
$$;

revoke all on function erp.organisation_administrators() from public, anon, authenticated;

comment on function erp.organisation_administrators() is
  'Everybody in this organisation who may promote configuration, which is the '
  'product''s working definition of an administrator. Whom a request falls to '
  'when the step it names resolves to nobody.';

-- ── 3. The two changes to how tasks are made ─────────────────────────────────

do $seq$
declare
  v_sig constant text := 'erp.open_approval_seq(uuid, integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  -- 20260914098000 already let an administrator be asked here rather than
  -- refused. This is the same for anybody else who is the only person who
  -- could approve it, so the needle is that migration's replacement, not the
  -- original.
  v_lone constant text :=
    E'        if erp.tenant_is_live(v_tenant) and not erp.approves_as_administrator(v_exclude) then';
  v_unstaffed constant text :=
    E'      if v_made = 0 then\n'
    || E'        -- A step whose role has nobody in it would silently stall the request.\n'
    || E'        raise exception\n'
    || E'          ''CLOVEERP_APPROVAL_STEP_UNSTAFFED: step % has no eligible approver in scope'',\n'
    || E'          st.code using errcode = ''23514'',\n'
    || E'          hint = ''Give the approving role to somebody, or choose another approver role for these documents on the Configuration screen.'';\n'
    || E'      end if;';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_lone, ''))) / length(v_lone) <> 1 then
    raise exception 'CLOVEERP_APPROVAL_SEQ_UNRECOGNISED: the lone-approver refusal in % is not the one this migration changes', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_unstaffed, ''))) / length(v_unstaffed) <> 1 then
    raise exception 'CLOVEERP_APPROVAL_SEQ_UNRECOGNISED: the unstaffed refusal in % is not the one this migration replaces', v_sig;
  end if;

  -- (a) Where the person who asked is the ONLY person who could approve, they
  --     are asked rather than refused. Everywhere else the exclusion stands:
  --     an organisation with a second approver still gets a second opinion,
  --     which is what the exclusion was for and remains right.
  v_new := replace(v_def, v_lone,
       E'        -- And anybody else who is the only person who could approve it,\n'
    || E'        -- where the organisation allows that and no separation rule\n'
    || E'        -- pairs the raising of this document with its approval.\n'
    || E'        if erp.tenant_is_live(v_tenant)\n'
    || E'           and not erp.approves_as_administrator(v_exclude)\n'
    || E'           and not erp.may_approve_own(v_exclude, v_req.object_id) then');

  -- (b) Nobody in the step is a reason to ask the administrators, not to stop.
  v_new := replace(v_new, v_unstaffed,
       E'      if v_made = 0 then\n'
    || E'        -- Nobody holds what the step names. An organisation always has\n'
    || E'        -- somebody who may promote configuration, and a request that\n'
    || E'        -- stops dead helps nobody, so it falls to them and says so.\n'
    || E'        insert into erp.approval_task (\n'
    || E'          tenant_id, approval_request_id, approval_step_id, step_code, seq,\n'
    || E'          assignee_user_id, due_at)\n'
    || E'        select v_tenant, p_request_id, st.id, st.code, st.seq, a.app_user_id,\n'
    || E'               case when st.escalate_after is not null then now() + st.escalate_after end\n'
    || E'          from erp.organisation_administrators() a\n'
    || E'         where v_exclude is null or a.app_user_id <> v_exclude;\n'
    || E'\n'
    || E'        get diagnostics v_made = row_count;\n'
    || E'      end if;\n'
    || E'\n'
    || E'      if v_made = 0 then\n'
    || E'        -- Not even an administrator. That is an organisation nobody can\n'
    || E'        -- approve anything in, and it is worth refusing by name.\n'
    || E'        raise exception\n'
    || E'          ''CLOVEERP_APPROVAL_STEP_UNSTAFFED: step % has no eligible approver in scope'',\n'
    || E'          st.code using errcode = ''23514'',\n'
    || E'          hint = ''Give the approving role to somebody, or choose another approver role for these documents on the Configuration screen.'';\n'
    || E'      end if;');

  execute v_new;
end
$seq$;

-- ── 4. What was approved, and what was not ───────────────────────────────────

create or replace function public.erp_approval_decisions(
  p_limit integer default 100, p_status text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  -- The decision, across the organisation. erp_approval_audit reads the routing
  -- stamp, which is written when a request is captured and therefore records
  -- who each step went TO. The yes or no is on the task, and until now only
  -- erp_document_approval_decisions read it, one document at a time.
  -- The decision, across the organisation. erp_approval_audit reads the routing
  -- stamp, which is written when a request is captured and therefore records
  -- who each step went TO. The yes or no is on the task, and until now only
  -- erp_document_approval_decisions read it, one document at a time.
  select coalesce(jsonb_agg(s.j order by s.decided_at desc nulls last, s.requested_at desc),
                  '[]'::jsonb)
    from (
      select jsonb_build_object(
               'task_id', t.id,
               'request_id', q.id,
               'object_type', q.object_type,
               'document_id', case when q.object_type = 'document' then q.object_id end,
               'document_number', d.document_number,
               'document_type_name', dt.name,
               'value_minor', q.value_at_approval::bigint,
               'currency', nullif(q.context ->> 'currency', ''),
               'step', coalesce(nullif(btrim(st.name), ''), t.step_code),
               'outcome', t.status,
               'decided_by', ud.display_name,
               'decided_at', t.decided_at,
               'decided_via', t.decided_via,
               'own_request', t.decided_by is not null and t.decided_by = q.requested_by,
               'requested_by', rq.display_name,
               'requested_at', q.requested_at,
               'comment', t.comment) as j,
             t.decided_at as decided_at, q.requested_at as requested_at
        from erp.approval_request q
        join erp.approval_task t
          on t.tenant_id = q.tenant_id and t.approval_request_id = q.id
        left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
        left join erp.document d
          on q.object_type = 'document' and d.tenant_id = q.tenant_id and d.id = q.object_id
        left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
        left join erp.app_user rq on rq.tenant_id = q.tenant_id and rq.id = q.requested_by
        left join erp.app_user ud on ud.tenant_id = t.tenant_id and ud.id = t.decided_by
       where q.tenant_id = erp.current_tenant_id()
         and t.status <> 'skipped'
         and (p_status is null or t.status::text = p_status)
       order by t.decided_at desc nulls last, q.requested_at desc
       limit greatest(coalesce(p_limit, 100), 1)
    ) s
$$;

revoke all on function public.erp_approval_decisions(integer, text) from public, anon;

comment on function public.erp_approval_decisions(integer, text) is
  'Every approval decision in this organisation, newest first: what was being '
  'approved and for how much, which step, the outcome, who decided it, when, '
  'how, and whether it was their own request. The answer to "what was approved '
  'and what was not", which the routing audit cannot give because it is written '
  'before anybody decides.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.approval_policy_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_item uuid; v_ccy char(3);
  v_cust uuid; v_doc uuid; v_perm text;
  v_chain uuid; v_ver uuid; v_req uuid; v_task uuid;
  v_hist jsonb; v_row jsonb;
  v_n integer;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-approval-policy', 'Approval policy suite',
                              'admin@zz-approval-policy.test', 'Approval Policy Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ec', 'admin@zz-approval-policy.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ec')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  v_doc := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                               current_date, v_ccy, 'ZZAP-DOC', '{}'::jsonb);
  select coalesce(dt.create_permission, bt.create_permission) into v_perm
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where d.id = v_doc;

  -- ── 1. On by default ─────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'an organisation lets somebody approve what they raised unless it says otherwise';
  passed := erp.self_approval_allowed() and erp.may_approve_own(v_admin, v_doc);
  detail := format('allowed %s, may approve own %s',
                   erp.self_approval_allowed(), erp.may_approve_own(v_admin, v_doc));
  return next;

  -- ── 2. And stops when it does ────────────────────────────────────────────
  v_cases := v_cases + 1;
  perform erp.set_config_value('approval.self_approval', '{"allowed": false}'::jsonb,
                               null, null, null, null, 'suite: switched off');
  case_name := 'an organisation that switches it off refuses somebody their own request';
  passed := not erp.self_approval_allowed() and not erp.may_approve_own(v_admin, v_doc);
  detail := format('allowed %s', erp.self_approval_allowed());
  return next;

  perform erp.set_config_value('approval.self_approval', '{"allowed": true}'::jsonb,
                               null, null, null, null, 'suite: switched back on');

  -- ── 3. A separation rule beats the allowance ─────────────────────────────
  v_cases := v_cases + 1;
  insert into erp.sod_rule (tenant_id, code, name, permissions_a, permissions_b, status)
  values (v_tenant, 'ZZ_RAISE_APPROVE', 'Raising and approving are separate duties',
          array[v_perm], array['administration.promote'], 'active');
  case_name := 'a separation of duties rule pairing the two overrides the allowance';
  passed := erp.self_approval_allowed()
        and erp.duties_separate_raising_from_approving(v_admin, v_perm)
        and not erp.may_approve_own(v_admin, v_doc);
  detail := format('allowed %s, duties separate %s, may approve own %s',
                   erp.self_approval_allowed(),
                   erp.duties_separate_raising_from_approving(v_admin, v_perm),
                   erp.may_approve_own(v_admin, v_doc));
  return next;

  update erp.sod_rule set status = 'inactive'
   where tenant_id = v_tenant and code = 'ZZ_RAISE_APPROVE';

  -- ── 4. And a withdrawn rule stops beating it ─────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'a separation rule no longer in force stops overriding it';
  passed := erp.may_approve_own(v_admin, v_doc);
  detail := format('may approve own %s', erp.may_approve_own(v_admin, v_doc));
  return next;

  -- ── 5. Somebody is always an administrator ───────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.organisation_administrators() a where a.app_user_id = v_admin;
  case_name := 'the organisation knows who its administrators are, which is who a request falls to';
  passed := v_n = 1;
  detail := format('%s administrator(s) matched the founder', v_n);
  return next;

  -- ── 6. The history says the outcome, not the routing ─────────────────────
  v_cases := v_cases + 1;
  insert into erp.approval_chain (tenant_id, code, name, object_type, entity_id, status)
  values (v_tenant, 'zz_policy', 'Approval policy suite', 'document', v_entity, 'active')
  returning id into v_chain;
  insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status,
                                          effective_from, value_field)
  values (v_tenant, v_chain, 1, 'draft', current_date, 'total_minor')
  returning id into v_ver;
  insert into erp.approval_request (tenant_id, object_type, object_id, entity_id, site_id,
                                    approval_chain_version_id, status, context,
                                    value_at_approval, requested_by)
  values (v_tenant, 'document', v_doc, v_entity, v_site, v_ver, 'approved',
          jsonb_build_object('total_minor', 250000, 'currency', v_ccy), 250000, v_admin)
  returning id into v_req;
  insert into erp.approval_task (tenant_id, approval_request_id, step_code, seq,
                                 assignee_user_id, status, decided_by, decided_at)
  values (v_tenant, v_req, 'zz_only', 1, v_admin, 'approved', v_admin, now())
  returning id into v_task;

  v_hist := public.erp_approval_decisions(50, null);
  select value into v_row from jsonb_array_elements(v_hist) value
   where value ->> 'task_id' = v_task::text limit 1;

  case_name := 'the history says what was decided, by whom, and that it was their own request';
  passed := v_row is not null
        and v_row ->> 'outcome' = 'approved'
        and v_row ->> 'document_number' is not null
        and (v_row ->> 'own_request')::boolean
        and (v_row ->> 'value_minor')::bigint = 250000;
  detail := coalesce(format('outcome %s, own request %s, value %s',
                            v_row ->> 'outcome', v_row ->> 'own_request', v_row ->> 'value_minor'),
                     'the decision is not in the history');
  return next;

  -- ── 7. Including the ones that were refused ──────────────────────────────
  v_cases := v_cases + 1;
  update erp.approval_task set status = 'rejected', comment = 'suite: not this one'
   where id = v_task;
  v_hist := public.erp_approval_decisions(50, 'rejected');
  case_name := 'a refusal is history too, and can be asked for on its own';
  passed := exists (select 1 from jsonb_array_elements(v_hist) e
                     where e.value ->> 'task_id' = v_task::text
                       and e.value ->> 'outcome' = 'rejected')
        and not exists (select 1 from jsonb_array_elements(public.erp_approval_decisions(50, 'approved')) e
                         where e.value ->> 'task_id' = v_task::text);
  detail := format('%s rejected decision(s) in the history', jsonb_array_length(v_hist));
  return next;

  -- ── 8. Being allowed is not the same as being alone ──────────────────────
  v_cases := v_cases + 1;
  insert into erp.approval_task (tenant_id, approval_request_id, step_code, seq,
                                 assignee_user_id, status)
  values (v_tenant, v_req, 'zz_second', 1,
          (select u.id from erp.app_user u
            where u.tenant_id = v_tenant and u.id <> v_admin
            order by u.created_at limit 1), 'pending');
  case_name := 'somebody the organisation would let approve their own is still not alone once a colleague is asked';
  passed := erp.may_approve_own(v_admin, v_doc)
        and not erp.sole_approver_asked(v_req, v_admin);
  detail := format('may approve own %s, sole approver asked %s',
                   erp.may_approve_own(v_admin, v_doc),
                   erp.sole_approver_asked(v_req, v_admin));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 9. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-approval-policy')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ec');
  detail := 'zz-approval-policy rolled back with its rule, request and decision';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_policy_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.approval_policy_suite() from public, anon;

create or replace function erp_test.assert_approval_policy_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _approval_policy on commit drop as
    select * from erp_test.approval_policy_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _approval_policy;
  drop table _approval_policy;
  if v_fail > 0 then
    raise exception E'CLOVEERP_APPROVAL_POLICY_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: approval_policy_suite ran % cases, expected 9', v_all;
  end if;
  return format('an approval says who decided it: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_approval_policy_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The words the screen says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Decisions', 'The panel of approvals that have been decided, beside the ones still waiting.'),
    ('Every approval decided in this organisation, newest first.', 'What that panel holds, said under its heading.'),
    ('Nothing has been decided yet. Approvals appear here once somebody approves or rejects them.', 'Said when the organisation has decided no approval yet.'),
    ('Outcome', 'Whether an approval was given or refused.'),
    ('Decided by', 'Who gave or refused it.'),
    ('Decided', 'When they did.'),
    ('Own request', 'Whether the person who decided it was the person who raised it.')
) as v(text, why)
on conflict (key, locale) do nothing;

do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values ('Decisions'),
                 ('Every approval decided in this organisation, newest first.'),
                 ('Nothing has been decided yet. Approvals appear here once somebody approves or rejects them.'),
                 ('Outcome'), ('Decided by'), ('Decided'), ('Own request')) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_WORDS_MISSING: % have no en row', v_missing;
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_resource_coverage('en');
select erp.assert_ci_coverage();
select erp_test.assert_approval_policy_suite();

-- ═════════════════════════════════════════════════════════════════════════════
-- The two cases that asserted the old answer
-- ═════════════════════════════════════════════════════════════════════════════

-- erp_test.approval_hold_suite() proved the behaviour this migration changes:
-- that the person submitting is not asked, and that a live organisation where
-- only they hold the approving role refuses the submission. Both were true and
-- worth asserting while they were the rule. Both are false now, on purpose. A
-- suite that asserts the old answer fails the moment the answer changes, which
-- is exactly what it is for — so the cases keep their place and their subject,
-- and assert the new answer instead.
do $hold$
declare
  v_sig constant text := 'erp_test.approval_hold_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_two constant text :=
       E'  case_name := ''where only the person submitting holds the approving role, a live organisation refuses the submission'';\n'
    || E'  passed := coalesce(v_state is null and v_so_err like ''CLOVEERP_APPROVAL_NO_OTHER_APPROVER%''\n'
    || E'            and v_so_state = ''draft'', false);';
  v_new text;
begin
  if (length(v_def) - length(replace(v_def, v_two, ''))) / length(v_two) <> 1 then
    raise exception 'CLOVEERP_HOLD_SUITE_UNRECOGNISED: the case about the lone approver in % is not the one this migration turns round', v_sig;
  end if;

  -- And a lone approver approves instead of being refused.
  v_new := replace(v_def, v_two,
       E'  case_name := ''where only the person submitting holds the approving role, they are asked rather than refused'';\n'
    || E'  passed := coalesce(v_state is null and v_so_err is null\n'
    || E'            and v_so_state = ''pending_approval'', false);');

  execute v_new;
end
$hold$;

select erp_test.assert_approval_hold_suite();

-- ═════════════════════════════════════════════════════════════════════════════
-- The other two places the same rule is written
-- ═════════════════════════════════════════════════════════════════════════════

-- Excluding the requester when the tasks are made is only the first of three
-- guards. The second refuses the approve transition on the document, and the
-- third refuses the decision on the task. All three said the same thing, so all
-- three have to ask the same question, or the allowance moves the refusal
-- rather than lifting it.
do $guards$
declare
  v_doc constant text := 'erp.require_document_approval(uuid, text)';
  v_task constant text := 'erp.decide_approval_task(uuid, boolean, text)';
  v_def text;
  v_needle text;
  v_new text;
begin
  -- (a) The approve transition on the document.
  v_def := pg_get_functiondef(v_doc::regprocedure);
  v_needle :=
       E'  if q.requested_by = erp.current_principal_id()\n'
    || E'     and erp.tenant_is_live(v_tenant)\n'
    || E'     and exists (select 1 from erp.approval_task t\n'
    || E'                  where t.tenant_id = v_tenant and t.approval_request_id = q.id\n'
    || E'                    and t.status <> ''skipped'') then';
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_SELF_APPROVAL_GUARD_UNRECOGNISED: the guard in % is not the one this migration adds the allowance to', v_doc;
  end if;
  v_new := replace(v_def, v_needle,
       E'  if q.requested_by = erp.current_principal_id()\n'
    || E'     and erp.tenant_is_live(v_tenant)\n'
    || E'     and not (erp.may_approve_own(q.requested_by, p_document_id)\n'
    || E'              and erp.sole_approver_asked(q.id, q.requested_by))\n'
    || E'     and exists (select 1 from erp.approval_task t\n'
    || E'                  where t.tenant_id = v_tenant and t.approval_request_id = q.id\n'
    || E'                    and t.status <> ''skipped'') then');
  execute v_new;

  -- (b) The decision on the task.
  v_def := pg_get_functiondef(v_task::regprocedure);
  v_needle :=
       E'  if p_approve\n'
    || E'     and v_req.object_type = ''document''\n'
    || E'     and v_req.requested_by = v_actor\n'
    || E'     and erp.tenant_is_live(v_tenant) then';
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_SELF_APPROVAL_GUARD_UNRECOGNISED: the guard in % is not the one this migration adds the allowance to', v_task;
  end if;
  v_new := replace(v_def, v_needle,
       E'  if p_approve\n'
    || E'     and v_req.object_type = ''document''\n'
    || E'     and v_req.requested_by = v_actor\n'
    || E'     and erp.tenant_is_live(v_tenant)\n'
    || E'     and not (erp.may_approve_own(v_req.requested_by, v_req.object_id)\n'
    || E'              and erp.sole_approver_asked(v_req.id, v_req.requested_by)) then');
  execute v_new;
end
$guards$;

select erp.apply_execute_grants();
select erp.assert_public_api_safe();
