-- An administrator approves what they must.
--
-- The owner, on Purchasing, pressed Approve on PO-000001, an order they had
-- submitted themselves and that was waiting for approval, and was told
-- CLOVEERP_DOCUMENT_APPROVAL_PENDING. Their words: "As administrator, I should
-- be able to approve everything, even though I created it." Decided with the
-- owner: on by default for every organisation, existing ones included;
-- switchable per organisation for a customer who needs two-person sign-off;
-- and it covers everything that waits for approval: purchase and sales
-- orders, their discount and credit steps, journals, and configuration changes.
--
-- Every control this changes, as the definitions stand after every patch
-- before this file:
--
--   * The hold. erp.require_document_approval (20260914062000) refuses the
--     approve transition while the request is pending, when it was refused,
--     and, once live, to the person who asked.
--   * erp.decide_approval_task refuses the person who asked a document task
--     once live (20260914062000), and a sales order's discount and credit steps
--     without sales.discount_approve and sales.credit_release (20260914074000).
--   * erp.open_approval_seq refuses a live submission nobody but the person
--     submitting could approve, CLOVEERP_APPROVAL_NO_OTHER_APPROVER.
--   * public.erp_approve_journal refuses whoever raised or submitted a journal
--     once live, CLOVEERP_JOURNAL_SELF_APPROVAL (20260914071000), and
--     public.erp_journals says so in you_may_approve.
--   * erp.approve_change_set refuses a change's author once live,
--     CLOVEERP_CHANGE_SET_SELF_APPROVAL (20260904810000), and
--     public.erp_change_sets says so in may_approve (20260913101000).
--
-- Left alone, because they are separations of duty rather than approvals
-- waiting on somebody: changing your own roles (20260914065000), accepting a
-- match exception you raised or releasing a batch you inspected
-- (20260914070000), invoicing a delivery you despatched (20260914074000), and
-- a payment run's proposer approving it. erp.approve_quote is the platform's
-- own quote flow and still waits for its approval to be given; once given, its
-- transition now lets an administrator through like any document.
--
-- WHO IS AN ADMINISTRATOR
--
-- A person holding administration.promote, "Promote configuration". The brief
-- asked for a new permission granted to the administrator role in every
-- organisation. The code shows a better seam, and this file takes it:
--
--   * erp.role_permission is a promotable surface. In a live organisation the
--     live-configuration guard refuses a new grant row except inside a
--     promotion (20260914015000), and there is no migration route around it;
--     20260914061500 records that no migration rewrites an organisation's
--     roles. The owner's own organisation is live, so a new permission would
--     reach the administrator who asked for this only after they raised,
--     approved and promoted a change granting it to themselves, which is the
--     very approval that fails today.
--   * Every administrator already holds administration.promote: provisioning
--     gives the role the whole catalogue, and the base pack's administrator
--     template names it. No module role holds it.
--   * It is already the permission for a governance decision: accepting a
--     prohibited pairing of duties (20260914065000) and invoicing your own
--     delivery (20260914074000) both ask for it.
--
-- THE SETTING
--
-- The configuration type approval.administrator_override, a tenant-wide
-- singleton {"allowed": boolean} whose product default is allowed, so every
-- organisation has it on without a row being written. It is read by
-- erp.administrator_approval_allowed() and changed through
-- public.erp_set_administrator_approval(), under administration.configure:
-- directly while an organisation is being set up, and in a live organisation
-- as a change on the Configuration screen, which is approved and promoted
-- like any other and audited with it. Switching it off while it is on can be
-- approved by the administrator who asks; switching it back on while it is off
-- needs a second person, which is the point of having it off.
--
-- WHEN IT APPLIES (erp.approves_as_administrator: the setting is on and the
-- person holds administration.promote)
--
--   * Approving a document whose request is pending decides every pending task
--     of the request as the administrator, sequence by sequence, then the
--     request is approved and the transition carries on. Each task records
--     decided_via = 'administrator' (the constraint widens from desk and email)
--     and a comment saying it was approved as administrator, for the person
--     asked or their own, and whether it was the administrator's own request.
--     Names are not written into the comment: the task keeps who it was
--     assigned to and who decided it, which erasure can reach.
--   * A refused request still refuses. An administrator resubmits rather than
--     overrides a no, and the refusal says so.
--   * The person who asked, when they are an administrator, may decide their own
--     task and approve their own document; the discount and credit steps take
--     an administrator; an administrator approves their own journal and their
--     own change.
--   * A live submission nobody else could approve asks the administrator who
--     submitted, instead of refusing, as before go-live.
--   * Every override is an event: approval.administrator_decided (on the
--     approval, with the tasks decided, whose they were and whether the request
--     was the administrator's own), journal.self_approved and
--     change_set.self_approved. The document page lists each task's decision
--     and says "as administrator" where it was one
--     (public.erp_document_approval_decisions).
--
-- With the setting off, or for anybody without the permission, every refusal is
-- exactly what it was.
--
-- Also: the notification router no longer emails about an approval task that
-- was already decided by the time it routes, which an administrator's one press
-- does to the next sequence's tasks inside the same transaction.
--
-- Suites that proved a refusal to an administrator in a live organisation are
-- kept proving it, with the setting switched off in their organisation by
-- erp_test.administrator_approval_off(): approval hold, email action, journal
-- and close, bootstrap window, provisioning window and interview ease. Each
-- is a counted replacement of the suite's body.
--
-- Proof: erp_test.administrator_approval_suite(), eleven cases.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The setting, and who it lets through
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema, max_scope_level, is_singleton,
   default_value, consequence)
values
  ('approval.administrator_override', 'policy', 'administration', 'config.approval.administrator_override',
   'Whether an administrator, a person holding Promote configuration, may approve their own requests '
   'and requests still waiting on others: documents, their discount and credit steps, journals and '
   'configuration changes.',
   '{"type": "object", "required": ["allowed"], "additionalProperties": false,
     "properties": {"allowed": {"type": "boolean"}}}'::jsonb,
   'tenant', true, '{"allowed": true}'::jsonb,
   'Allowed: an administrator approves in one press, deciding the tasks still waiting, and each such '
   'decision is recorded as made by an administrator. Not allowed: every approval needs a second '
   'person, and an administrator is refused their own requests like anybody else. A refused request '
   'is never approved over either way.')
on conflict (code) do update set
  domain = excluded.domain, module_code = excluded.module_code, name_key = excluded.name_key,
  description = excluded.description, value_schema = excluded.value_schema,
  max_scope_level = excluded.max_scope_level, is_singleton = excluded.is_singleton,
  default_value = excluded.default_value, consequence = excluded.consequence;

create or replace function erp.administrator_approval_allowed()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce((erp.config_value('approval.administrator_override') ->> 'allowed')::boolean, true)
$$;

revoke all on function erp.administrator_approval_allowed() from public, anon, authenticated;

comment on function erp.administrator_approval_allowed() is
  'Whether the organisation in context lets administrators approve their own requests and those '
  'still waiting on others (approval.administrator_override). On unless the organisation switched it off.';

create or replace function erp.approves_as_administrator(p_app_user_id uuid default null)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select erp.administrator_approval_allowed()
     and erp.has_permission('administration.promote', null, null, null, p_app_user_id)
$$;

revoke all on function erp.approves_as_administrator(uuid) from public, anon, authenticated;

comment on function erp.approves_as_administrator(uuid) is
  'Whether a person, the acting one when none is named, approves as an administrator: the '
  'organisation allows it and they hold administration.promote. Every self-approval and '
  'waiting-approval refusal asks this first (20260914098000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What an override records
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.approval_task drop constraint if exists approval_task_decided_via_known;
alter table erp.approval_task add constraint approval_task_decided_via_known
  check (decided_via in ('desk', 'email', 'administrator'));

comment on column erp.approval_task.decided_via is
  'How the decision on this task was made: at the desk, from a link in an approval email '
  '(20260914096000), or by an administrator approving for the person asked or on their own '
  'request (20260914098000).';

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values
  ('approval.administrator_decided', 1, 'approval', 'administration', 'event.approval.administrator_decided',
   'An administrator approved a request where the product would otherwise have refused: they decided '
   'the tasks still waiting on the people asked, or approved what they asked for themselves. '
   'task_ids are the tasks decided, assignee_ids whose they were, own_request whether the '
   'administrator had asked for it.',
   '{"type": "object", "required": ["approval_request_id", "own_request"],
     "properties": {"approval_request_id": {"type": "string"}, "own_request": {"type": "boolean"},
                    "task_ids": {"type": "array"}, "assignee_ids": {"type": "array"}}}'::jsonb, true),
  ('journal.self_approved', 1, 'journal', 'finance', 'event.journal.self_approved',
   'An administrator approved and posted a journal they had raised or submitted, once live.',
   '{"type": "object", "required": ["approved_by"]}'::jsonb, true),
  ('change_set.self_approved', 1, 'change_set', 'administration', 'event.change_set.self_approved',
   'An administrator approved a configuration change they had authored, once live.',
   '{"type": "object", "required": ["approved_by"]}'::jsonb, true)
on conflict (code, version) do update set
  aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('config.approval.administrator_override', 'en', 'Administrators approve anything', 'administration',
   'The setting that lets administrators approve their own requests and those waiting on others.'),
  ('config.approval.administrator_override', 'de', 'Administratoren genehmigen alles', 'administration',
   'The setting that lets administrators approve their own requests and those waiting on others.'),
  ('event.approval.administrator_decided', 'en', 'Approval decided by an administrator', 'administration',
   'The event raised when an administrator approves where the product would otherwise refuse.'),
  ('event.approval.administrator_decided', 'de', 'Genehmigung durch einen Administrator entschieden', 'administration',
   'The event raised when an administrator approves where the product would otherwise refuse.'),
  ('event.journal.self_approved', 'en', 'Journal approved by the person who raised it', 'finance',
   'The event raised when an administrator approves their own journal.'),
  ('event.journal.self_approved', 'de', 'Buchung von der erfassenden Person genehmigt', 'finance',
   'The event raised when an administrator approves their own journal.'),
  ('event.change_set.self_approved', 'en', 'Configuration change approved by its author', 'administration',
   'The event raised when an administrator approves their own configuration change.'),
  ('event.change_set.self_approved', 'de', 'Konfigurationsänderung von ihrem Verfasser genehmigt', 'administration',
   'The event raised when an administrator approves their own configuration change.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Approving a request for everybody asked
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.approve_request_as_administrator(p_request_id uuid)
returns erp.approval_status
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_actor  uuid := erp.current_principal_id();
  v_req    erp.approval_request%rowtype;
  v_own    boolean;
  v_seq    integer;
  v_next   integer;
  v_ids    uuid[] := '{}';
  v_whose  uuid[] := '{}';
  v_guard  integer := 0;
  t        record;
begin
  if not erp.approves_as_administrator() then
    raise exception 'CLOVEERP_APPROVAL_NOT_ADMINISTRATOR: only an administrator, where the organisation allows it, approves a request for everybody asked'
      using errcode = '42501',
            hint = 'The people named on the request decide their tasks under My approvals.';
  end if;

  select * into v_req from erp.approval_request ar
   where ar.tenant_id = v_tenant and ar.id = p_request_id
   for update;

  if not found or v_req.status <> 'pending' then
    return v_req.status;
  end if;

  v_own := v_req.requested_by is not distinct from v_actor;

  loop
    v_guard := v_guard + 1;
    if v_guard > 100 then
      raise exception 'CLOVEERP_APPROVAL_CHAIN_UNFINISHED: the approval of this request did not come to an end'
        using errcode = '23514',
              hint = 'Check the approval chain for these documents on the Configuration screen: a step keeps opening another.';
    end if;

    -- The sequence waiting now, decided whole. Every pending task of it is
    -- approved as the administrator, whoever it names.
    select min(tk.seq) into v_seq
      from erp.approval_task tk
     where tk.tenant_id = v_tenant and tk.approval_request_id = p_request_id and tk.status = 'pending';

    if v_seq is null then
      select coalesce(ar.current_seq, (select max(tk.seq) from erp.approval_task tk
                                        where tk.tenant_id = v_tenant and tk.approval_request_id = p_request_id))
        into v_seq
        from erp.approval_request ar
       where ar.tenant_id = v_tenant and ar.id = p_request_id;
    else
      for t in
        select tk.id, tk.assignee_user_id
          from erp.approval_task tk
         where tk.tenant_id = v_tenant and tk.approval_request_id = p_request_id
           and tk.seq = v_seq and tk.status = 'pending'
         order by tk.created_at, tk.id
         for update
      loop
        update erp.approval_task tk
           set status = 'approved',
               decided_by = v_actor,
               decided_at = now(),
               decided_via = 'administrator',
               comment = case when t.assignee_user_id is not distinct from v_actor
                              then 'Approved as administrator'
                              else 'Approved as administrator, for the person asked' end
                         || case when v_own then ', on their own request' else '' end,
               updated_at = now()
         where tk.tenant_id = v_tenant and tk.id = t.id;
        v_ids := v_ids || t.id;
        if t.assignee_user_id is not null then
          v_whose := v_whose || t.assignee_user_id;
        end if;
      end loop;
    end if;

    v_next := case when v_seq is null then null else erp.open_approval_seq(p_request_id, v_seq) end;

    if v_next is null then
      update erp.approval_request ar
         set status = 'approved', decided_at = now(),
             decision_note = 'Approved by an administrator', updated_at = now()
       where ar.tenant_id = v_tenant and ar.id = p_request_id;

      perform erp.settle_approval_outcome(p_request_id);

      perform erp.append_event('approval.administrator_decided', 'approval', p_request_id,
        jsonb_build_object(
          'approval_request_id', p_request_id,
          'object_type', v_req.object_type,
          'object_id', v_req.object_id,
          'own_request', v_own,
          'task_ids', to_jsonb(v_ids),
          'assignee_ids', to_jsonb(array(select distinct x from unnest(v_whose) x))),
        v_req.entity_id, v_req.site_id);

      return 'approved';
    end if;
  end loop;
end;
$$;

revoke all on function erp.approve_request_as_administrator(uuid) from public, anon, authenticated;

comment on function erp.approve_request_as_administrator(uuid) is
  'Approves a pending approval request as an administrator (20260914098000): every pending task, '
  'sequence by sequence, is approved by the acting administrator with decided_via administrator, '
  'the request is approved and settled, and approval.administrator_decided records which tasks and '
  'whose. Refuses anybody erp.approves_as_administrator() does not let through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The hold lets an administrator through
-- ═════════════════════════════════════════════════════════════════════════════

do $check$
declare
  v_def text := pg_get_functiondef('erp.require_document_approval(uuid,text)'::regprocedure);
begin
  if position('CLOVEERP_DOCUMENT_APPROVAL_PENDING' in v_def) = 0
     or position('CLOVEERP_DOCUMENT_SELF_APPROVAL' in v_def) = 0
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.require_document_approval(uuid, text) is not the 20260914062000 body this migration restates'
      using hint = 'Read the live body with pg_get_functiondef and restate it under a new migration version.';
  end if;
end
$check$;

create or replace function erp.require_document_approval(p_document_id uuid, p_transition_code text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_chain   text;
  v_number  text;
  q         erp.approval_request%rowtype;
  v_waiting integer;
  v_admin   boolean;
begin
  if p_transition_code is distinct from 'approve' then
    return;
  end if;

  select dt.approval_chain_code, d.document_number
    into v_chain, v_number
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = p_document_id;

  -- A type with no chain approves on its permission, as it always has.
  if v_chain is null then
    return;
  end if;

  -- The request that governs: the pending one while there is one, otherwise
  -- the newest. Requests opened in one transaction share a timestamp, and an
  -- approved one is preferred on a tie.
  select ar.* into q
    from erp.approval_request ar
   where ar.tenant_id = v_tenant
     and ar.object_type = 'document'
     and ar.object_id = p_document_id
     and ar.status in ('pending', 'approved', 'rejected')
   order by (ar.status = 'pending') desc, ar.requested_at desc, (ar.status = 'approved') desc
   limit 1;

  -- Submitted before its type had a chain: nothing was asked, nothing holds it.
  if not found then
    return;
  end if;

  -- An administrator, where the organisation allows it (20260914098000).
  v_admin := erp.approves_as_administrator();

  if q.status = 'pending' and v_admin then
    -- One press: the tasks still waiting are decided as the administrator, and
    -- the request is approved before the transition carries on.
    perform erp.approve_request_as_administrator(q.id);
    select ar.* into q from erp.approval_request ar where ar.tenant_id = v_tenant and ar.id = q.id;
  end if;

  if q.status = 'pending' then
    select count(*) into v_waiting
      from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = q.id and t.status = 'pending';
    raise exception 'CLOVEERP_DOCUMENT_APPROVAL_PENDING: % is waiting on % approval task(s), and is approved once they are decided',
      coalesce(v_number, p_document_id::text), v_waiting
      using errcode = '23514',
            hint = 'The people asked decide their tasks under My approvals. Approve the document once they have, or ask an administrator, who can approve it at once where the organisation allows it.';
  end if;

  -- A refusal is never approved over, by an administrator or anybody else.
  if q.status = 'rejected' then
    raise exception 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED: the approval asked for on % was refused',
      coalesce(v_number, p_document_id::text)
      using errcode = '23514',
            hint = 'Send it back to draft, change what was refused, and submit it again. Not even an administrator approves over a refusal.';
  end if;

  -- Approved. Whoever asked does not approve it themselves once the
  -- organisation is live — unless nobody was asked at all, because no step
  -- applied and the request approved itself, or they are an administrator
  -- and the organisation allows it.
  if q.requested_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant)
     and exists (select 1 from erp.approval_task t
                  where t.tenant_id = v_tenant and t.approval_request_id = q.id
                    and t.status <> 'skipped') then
    if v_admin then
      if not exists (select 1 from erp.event e
                      where e.tenant_id = v_tenant and e.aggregate_type = 'approval'
                        and e.aggregate_id = q.id and e.event_type = 'approval.administrator_decided') then
        perform erp.append_event('approval.administrator_decided', 'approval', q.id,
          jsonb_build_object('approval_request_id', q.id, 'object_type', q.object_type,
                             'object_id', q.object_id, 'own_request', true,
                             'task_ids', '[]'::jsonb, 'assignee_ids', '[]'::jsonb),
          q.entity_id, q.site_id);
      end if;
      return;
    end if;
    raise exception 'CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval, so somebody else gives it'
      using errcode = '42501',
            hint = 'Another holder of the approving role decides it, or an administrator where the organisation allows administrators to approve their own requests.';
  end if;
end;
$$;

comment on function erp.require_document_approval(uuid, text) is
  'Refuses the approve transition on a document whose type names an approval chain while its '
  'approval request is pending or refused, and, once the organisation is live, refuses it to the '
  'person who asked for an approval somebody else was asked to give. An administrator, where the '
  'organisation allows it, approves a pending request in one press and may approve their own; a '
  'refused request refuses everybody (20260914098000). Called by erp.transition_document after the '
  'transition is found and authorised.';

revoke all on function erp.require_document_approval(uuid, text) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. A task, a submission, a journal and a change
-- ═════════════════════════════════════════════════════════════════════════════

do $decide$
declare
  v_sig text := 'erp.decide_approval_task(uuid,boolean,text)';
  v_def text := pg_get_functiondef('erp.decide_approval_task(uuid,boolean,text)'::regprocedure);
  n1 text := $n$  if p_approve
     and v_task.step_code in ('discount', 'credit')
$n$;
  r1 text := $r$  if p_approve
     and v_task.step_code in ('discount', 'credit')
     -- An administrator takes these steps too, where the organisation allows
     -- it (20260914098000).
     and not erp.approves_as_administrator()
$r$;
  n2 text := $n$     and v_req.requested_by = v_actor
     and erp.tenant_is_live(v_tenant) then
    raise exception 'CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval, so somebody else gives it'
      using errcode = '42501',
            hint = 'Another holder of the approving role decides the task. Give that role to a second person if there is nobody else.';
$n$;
  r2 text := $r$     and v_req.requested_by = v_actor
     and erp.tenant_is_live(v_tenant)
     and not erp.approves_as_administrator() then
    raise exception 'CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval, so somebody else gives it'
      using errcode = '42501',
            hint = 'Another holder of the approving role decides the task, or an administrator where the organisation allows administrators to approve their own requests.';
$r$;
  n3 text := $n$         decided_by = v_actor, decided_at = now(), comment = p_comment, updated_at = now()
   where id = p_task_id;
$n$;
  r3 text := $r$         decided_by = v_actor, decided_at = now(), comment = p_comment, updated_at = now()
   where id = p_task_id;

  -- Reached past the rule above only as an administrator (20260914098000):
  -- the task says so, and the approval records it.
  if p_approve
     and v_req.object_type = 'document'
     and v_req.requested_by = v_actor
     and erp.tenant_is_live(v_tenant) then
    update erp.approval_task set decided_via = 'administrator' where id = p_task_id;
    perform erp.append_event('approval.administrator_decided', 'approval', v_req.id,
      jsonb_build_object('approval_request_id', v_req.id, 'object_type', v_req.object_type,
                         'object_id', v_req.object_id, 'own_request', true,
                         'task_ids', jsonb_build_array(p_task_id),
                         'assignee_ids', jsonb_build_array(v_actor)),
      v_req.entity_id, v_req.site_id);
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or (length(v_def) - length(replace(v_def, n2, ''))) / length(n2) <> 1
     or (length(v_def) - length(replace(v_def, n3, ''))) / length(n3) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914074000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(replace(v_def, n1, r1), n2, r2), n3, r3);
  if (length(pg_get_functiondef(v_sig::regprocedure))
      - length(replace(pg_get_functiondef(v_sig::regprocedure), 'erp.approves_as_administrator()', '')))
     / length('erp.approves_as_administrator()') <> 2 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without both of its administrator checks', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;
end
$decide$;

do $seq$
declare
  v_sig text := 'erp.open_approval_seq(uuid,integer)';
  v_def text := pg_get_functiondef('erp.open_approval_seq(uuid,integer)'::regprocedure);
  n1 text := $n$        if erp.tenant_is_live(v_tenant) then
          select r.code into v_role from erp.role r where r.tenant_id = v_tenant and r.id = st.role_id;
          raise exception 'CLOVEERP_APPROVAL_NO_OTHER_APPROVER: step % needs somebody other than the person asking, and nobody else holds %',
            st.code, coalesce(v_role, 'the approver it names')
            using errcode = '23514',
                  hint = 'Give the approving role to a second person, or choose another approver role for these documents on the Configuration screen.';
$n$;
  r1 text := $r$        -- An administrator who asks is asked themselves, where the organisation
        -- allows it (20260914098000), as the one person setting up is.
        if erp.tenant_is_live(v_tenant) and not erp.approves_as_administrator(v_exclude) then
          select r.code into v_role from erp.role r where r.tenant_id = v_tenant and r.id = st.role_id;
          raise exception 'CLOVEERP_APPROVAL_NO_OTHER_APPROVER: step % needs somebody other than the person asking, and nobody else holds %',
            st.code, coalesce(v_role, 'the approver it names')
            using errcode = '23514',
                  hint = 'Give the approving role to a second person, or choose another approver role for these documents on the Configuration screen. An administrator who submits is asked themselves where the organisation allows it.';
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914062000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, n1, r1);
  if position('erp.approves_as_administrator(v_exclude)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its administrator check', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;
end
$seq$;

do $journal$
declare
  v_sig text := 'public.erp_approve_journal(uuid)';
  v_def text := pg_get_functiondef('public.erp_approve_journal(uuid)'::regprocedure);
  n1 text := $n$  if erp.tenant_is_live(v_tenant)
     and v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)) then
    raise exception 'CLOVEERP_JOURNAL_SELF_APPROVAL: you raised or submitted this journal, so somebody else approves it'
      using errcode = '42501',
            hint = 'Ask another person who may approve journals to approve and post it. Once the organisation is live, every journal typed by hand has a second person behind it.';
$n$;
  r1 text := $r$  if erp.tenant_is_live(v_tenant)
     and v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null))
     -- An administrator approves their own, where the organisation allows it
     -- (20260914098000).
     and not erp.approves_as_administrator() then
    raise exception 'CLOVEERP_JOURNAL_SELF_APPROVAL: you raised or submitted this journal, so somebody else approves it'
      using errcode = '42501',
            hint = 'Ask another person who may approve journals to approve and post it, or an administrator where the organisation allows administrators to approve their own.';
$r$;
  n2 text := $n$  return erp.journal_outcome(p_journal_id);
end;
$n$;
  r2 text := $r$  -- Approved and posted by the person who raised or submitted it: an
  -- administrator, where the organisation allows it (20260914098000).
  if erp.tenant_is_live(v_tenant)
     and v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)) then
    perform erp.append_event('journal.self_approved', 'journal', p_journal_id,
      jsonb_build_object('approved_by', v_me, 'journal_id', p_journal_id), j.entity_id);
  end if;

  return erp.journal_outcome(p_journal_id);
end;
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or (length(v_def) - length(replace(v_def, n2, ''))) / length(n2) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914071000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(v_def, n1, r1), n2, r2);
  if position('journal.self_approved' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its administrator check', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;
end
$journal$;

do $journals$
declare
  v_sig text := 'public.erp_journals(text,integer)';
  v_def text := pg_get_functiondef('public.erp_journals(text,integer)'::regprocedure);
  n1 text := $n$                                  and (not v_live
                                       or not coalesce(v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)), false)),
$n$;
  r1 text := $r$                                  and (not v_live
                                       or erp.approves_as_administrator()
                                       or not coalesce(v_me = any (array_remove(array[j.created_by, j.prepared_by, j.submitted_by], null)), false)),
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914071000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, n1, r1);
end
$journals$;

do $changeset$
declare
  v_sig text := 'erp.approve_change_set(uuid)';
  v_def text := pg_get_functiondef('erp.approve_change_set(uuid)'::regprocedure);
  n1 text := $n$  if erp.tenant_is_live(v_tenant)
     and cs.created_by is not null
     and cs.created_by = erp.current_principal_id() then
    raise exception
      'CLOVEERP_CHANGE_SET_SELF_APPROVAL: the author of a change set may not approve it'
      using errcode = '42501',
      hint = 'Grant administration.promote to a second principal.';
$n$;
  r1 text := $r$  if erp.tenant_is_live(v_tenant)
     and cs.created_by is not null
     and cs.created_by = erp.current_principal_id()
     -- An administrator approves their own, where the organisation allows it
     -- (20260914098000).
     and not erp.approves_as_administrator() then
    raise exception
      'CLOVEERP_CHANGE_SET_SELF_APPROVAL: the author of a change set may not approve it'
      using errcode = '42501',
      hint = 'Ask a second person who may promote configuration to approve it, or let administrators approve their own changes on the Organisation screen.';
$r$;
  n2 text := $n$         approved_at = now(), updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
end;
$n$;
  r2 text := $r$         approved_at = now(), updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;

  -- Approved by its author: an administrator, where the organisation allows
  -- it (20260914098000).
  if erp.tenant_is_live(v_tenant)
     and cs.created_by is not null
     and cs.created_by = erp.current_principal_id() then
    perform erp.append_event('change_set.self_approved', 'change_set', p_change_set_id,
      jsonb_build_object('approved_by', erp.current_principal_id(), 'code', cs.code));
  end if;
end;
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or (length(v_def) - length(replace(v_def, n2, ''))) / length(n2) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260904810000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(v_def, n1, r1), n2, r2);
  if position('change_set.self_approved' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its administrator check', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;
end
$changeset$;

do $changesets$
declare
  v_sig text := 'public.erp_change_sets()';
  v_def text := pg_get_functiondef('public.erp_change_sets()'::regprocedure);
  n1 text := $n$           'may_approve', not coalesce(erp.tenant_is_live(c.tenant_id)
                                       and c.created_by = erp.current_principal_id(), false))
$n$;
  r1 text := $r$           'may_approve', not coalesce(erp.tenant_is_live(c.tenant_id)
                                       and c.created_by = erp.current_principal_id()
                                       and not erp.approves_as_administrator(), false))
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or position('approves_as_administrator' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260913101000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, n1, r1);
end
$changesets$;

-- The email link records its own way in, and leaves an administrator's alone.
do $redeem$
declare
  v_sig text := 'erp.redeem_email_action(text,boolean,text)';
  v_def text := pg_get_functiondef('erp.redeem_email_action(text,boolean,text)'::regprocedure);
  n1 text := $n$   where t.tenant_id = v_tenant and t.id = v_task.id and t.decided_by = v_actor;
$n$;
  r1 text := $r$   where t.tenant_id = v_tenant and t.id = v_task.id and t.decided_by = v_actor
     and t.decided_via = 'desk';
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914096000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, n1, r1);
end
$redeem$;

-- An approval task decided before it routes waits on nobody, so the product's
-- routes do not email about it: an administrator's one press opens and decides
-- the next sequence's tasks in the same transaction.
do $router$
declare
  v_sig text := 'erp.route_notifications()';
  v_def text := pg_get_functiondef('erp.route_notifications()'::regprocedure);
  n1 text := $n$      select d.* from erp_ref.notification_route_default d
       where ev.event_type like d.event_pattern
$n$;
  r1 text := $r$      select d.* from erp_ref.notification_route_default d
       where ev.event_type like d.event_pattern
         -- A task already decided waits on nobody (20260914098000).
         and not (ev.event_type in ('approval.task_assigned', 'approval.task_escalated')
                  and exists (select 1 from erp.approval_task tk
                               where tk.tenant_id = v_tenant and tk.id = ev.aggregate_id
                                 and tk.status <> 'pending'))
$r$;
begin
  if (length(v_def) - length(replace(v_def, n1, ''))) / length(n1) <> 1
     or position('A task already decided waits on nobody' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914094000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, n1, r1);
end
$router$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The doors
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_set_administrator_approval(p_allowed boolean, p_reason text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_cs     uuid;
begin
  perform erp.authorise('administration.configure', null, null, null, 'config', null);
  v_tenant := erp.require_tenant_id();

  if p_allowed is null then
    raise exception 'CLOVEERP_VALIDATION: say whether administrators may approve anything'
      using errcode = '22023',
            hint = 'Choose allowed or not allowed.';
  end if;

  -- A live organisation changes its configuration through a change on the
  -- Configuration screen, approved and promoted there, like every other.
  if erp.environment_is_live() then
    v_cs := erp.create_change_set(
      format('administrator-approval-%s', to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')),
      case when p_allowed then 'Let administrators approve anything'
           else 'Keep a second person on every approval' end,
      coalesce(v_reason, case when p_allowed
                              then 'Administrators may approve their own requests and those waiting on others.'
                              else 'Every approval needs a second person, administrators included.' end));
    perform erp.add_change_set_item(v_cs, 'config', 'approval.administrator_override',
      jsonb_build_object('config_type', 'approval.administrator_override',
                         'value', jsonb_build_object('allowed', p_allowed)),
      'upsert', null, v_reason);
    perform erp.submit_change_set(v_cs);
    return jsonb_build_object('allowed', erp.administrator_approval_allowed(), 'proposed', p_allowed,
                              'route', 'change_set', 'change_set_id', v_cs);
  end if;

  perform erp.set_config_value('approval.administrator_override',
                               jsonb_build_object('allowed', p_allowed),
                               null, current_date, null, null, v_reason);
  return jsonb_build_object('allowed', erp.administrator_approval_allowed(), 'proposed', p_allowed,
                            'route', 'direct');
end;
$$;

comment on function public.erp_set_administrator_approval(boolean, text) is
  'Under administration.configure: whether administrators may approve their own requests and those '
  'waiting on others. Set directly while the organisation is being set up; in a live organisation it '
  'raises and submits a change for the Configuration screen to approve and promote.';

create or replace function public.erp_administrator_approval()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_array(jsonb_build_object(
    'allowed', erp.administrator_approval_allowed(),
    'you_approve_as_administrator', erp.approves_as_administrator(),
    'waiting_change', (
      select cs.code
        from erp.change_set cs
        join erp.change_set_item i on i.tenant_id = cs.tenant_id and i.change_set_id = cs.id
       where cs.tenant_id = erp.current_tenant_id()
         and cs.status in ('draft', 'ready', 'approved')
         and i.object_kind = 'config'
         and i.payload ->> 'config_type' = 'approval.administrator_override'
       order by cs.created_at desc
       limit 1)))
$$;

comment on function public.erp_administrator_approval() is
  'Whether this organisation lets administrators approve anything, whether that applies to the caller, '
  'and the code of a change to it still waiting to be promoted. One row, for the Organisation screen.';

create or replace function public.erp_document_approval_decisions(p_document_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  -- No erp.authorise(), as erp_document_approval_chain has none: row security
  -- scopes this to the caller's organisation, and a person looking at a
  -- document may read who decided its approval.
  select coalesce(jsonb_agg(jsonb_build_object(
           'task_id', t.id,
           'request_id', q.id,
           'request_status', q.status,
           'requested_at', q.requested_at,
           'requested_by', rq.display_name,
           'step', coalesce(nullif(btrim(st.name), ''), t.step_code),
           'status', t.status,
           'assignee', ua.display_name,
           'assignee_role', ro.name,
           'decided_by', ud.display_name,
           'decided_at', t.decided_at,
           'decided_via', t.decided_via,
           'own_request', t.decided_by is not null and t.decided_by = q.requested_by,
           'comment', t.comment)
           order by q.requested_at desc, t.seq, t.created_at, t.id), '[]'::jsonb)
    from erp.approval_request q
    join erp.approval_task t on t.tenant_id = q.tenant_id and t.approval_request_id = q.id
    left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
    left join erp.app_user rq on rq.tenant_id = q.tenant_id and rq.id = q.requested_by
    left join erp.app_user ua on ua.tenant_id = t.tenant_id and ua.id = t.assignee_user_id
    left join erp.role ro on ro.tenant_id = t.tenant_id and ro.id = t.assignee_role_id
    left join erp.app_user ud on ud.tenant_id = t.tenant_id and ud.id = t.decided_by
   where q.tenant_id = erp.current_tenant_id()
     and q.object_type = 'document'
     and q.object_id = p_document_id
     and t.status <> 'skipped'
$$;

comment on function public.erp_document_approval_decisions(uuid) is
  'Every approval task asked on a document, newest request first: the step, whose it was, who '
  'decided it, when, how (at the desk, from email, or as administrator) and whether it was the '
  'decider''s own request.';

revoke all on function public.erp_set_administrator_approval(boolean, text) from public, anon;
revoke all on function public.erp_administrator_approval() from public, anon;
revoke all on function public.erp_document_approval_decisions(uuid) from public, anon;
grant execute on function public.erp_set_administrator_approval(boolean, text) to authenticated, service_role;
grant execute on function public.erp_administrator_approval() to authenticated, service_role;
grant execute on function public.erp_document_approval_decisions(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_administrator_approval', 'erp.authorise',
   'Sets whether administrators may approve anything, under administration.configure: directly while '
   'the organisation is being set up, and as a submitted change for the Configuration screen once it '
   'is live (20260914098000).')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The words
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_DOCUMENT_APPROVAL_PENDING',
  'Approving a document whose approval has not been given yet.',
  'Submitting it asked the approving role to agree. Until the people asked have decided, approving the document would be approving it without them.',
  'Wait for the tasks under My approvals to be decided, then approve the document. An administrator can approve it at once where the organisation lets administrators approve anything.');

select erp.register_refusal('CLOVEERP_DOCUMENT_APPROVAL_REJECTED',
  'Approving a document whose approval was refused.',
  'Somebody asked to approve it said no, and a single refusal decides an approval.',
  'Send the document back to draft, change what was refused, and submit it again. Not even an administrator approves over a refusal.');

select erp.register_refusal('CLOVEERP_DOCUMENT_SELF_APPROVAL',
  'Approving a document you submitted for approval yourself.',
  'An approval is a second person agreeing. Once the organisation is live, whoever asks for one does not give it, unless they are an administrator and the organisation allows it.',
  'Ask another holder of the approving role to decide it, or an administrator where the organisation lets administrators approve their own requests. If nobody else holds that role, give it to a second person.');

select erp.register_refusal('CLOVEERP_APPROVAL_NO_OTHER_APPROVER',
  'Submitting a document for approval when you are the only person who could approve it.',
  'Whoever submits a document is not asked to approve it, and nobody else holds the approving role, so nobody could agree.',
  'Give the approving role to a second person, or choose another approver role for these documents on the Configuration screen, then submit again. An administrator who submits is asked themselves where the organisation lets administrators approve anything.');

select erp.register_refusal('CLOVEERP_JOURNAL_SELF_APPROVAL',
  'Approving a journal you raised or submitted yourself.',
  'Once the organisation is live, a journal typed by hand is posted only when a second person agrees with it, unless an administrator posts their own where the organisation allows it.',
  'Ask another person who may approve journals to approve and post it, or an administrator where the organisation lets administrators approve their own journals.');

-- The Organisation screen's words, each with the row it is renamed by.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Let administrators approve anything',
     'The action on the Organisation screen that switches whether administrators may approve anything.'),
    ('Whether a person holding Promote configuration may approve their own requests, journals and changes, and approve at once what is still waiting on others. Switch it off where every approval needs a second person. In a live organisation this raises a change, approved and promoted on the Configuration screen.',
     'What the action that switches administrator approval does.'),
    ('Administrators may approve anything',
     'The yes-or-no field on the form that switches administrator approval.'),
    ('Allowed',
     'The choice that lets administrators approve anything.'),
    ('Not allowed',
     'The choice that keeps a second person on every approval.'),
    ('Why it is changing',
     'The reason field on the form that switches administrator approval.'),
    ('Kept with the change, so the next person knows why the organisation decided it.',
     'The hint under the reason field on the form that switches administrator approval.'),
    ('Administrators approving',
     'The title of the panel showing whether administrators may approve anything.'),
    ('On by default. When allowed, an administrator approving a document decides the tasks still waiting in one press, and every such decision is recorded as made by an administrator. A refused request is never approved over.',
     'What the panel showing administrator approval explains.'),
    ('The setting could not be read.',
     'Said when the panel showing administrator approval has nothing to show.'),
    ('Setting',
     'The column saying whether administrators may approve anything.'),
    ('For you',
     'The column saying whether the setting lets the reader approve as an administrator.'),
    ('Waiting to be promoted',
     'The column naming a change to the setting not yet in force.'),
    ('You approve as an administrator',
     'Said in the panel when the reader approves as an administrator.'),
    ('Not you',
     'Said in the panel when the setting does not let the reader approve as an administrator.')
  ) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Suites that prove two-person approval keep proving it
-- ═════════════════════════════════════════════════════════════════════════════

-- The setting switched off in one organisation, the way a customer who needs
-- two-person sign-off has it, whatever context the suite is in.
create or replace function erp_test.administrator_approval_off(p_tenant uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_job    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_jobp   text := coalesce(current_setting('erp.job_principal_id', true), '');
  v_live   boolean;
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', p_tenant::text, true);
  perform set_config('erp.job_principal_id', '', true);

  select e.is_live into v_live from erp.environment e where e.tenant_id = p_tenant and e.is_self;
  if coalesce(v_live, false) then
    perform erp_test.reopen_bootstrap_window(p_tenant);
  end if;
  perform erp.set_config_value('approval.administrator_override', '{"allowed": false}'::jsonb,
                               null, current_date, null, null,
                               'a suite that proves an approval needs a second person');
  if coalesce(v_live, false) then
    perform erp_test.close_bootstrap_window(p_tenant);
  end if;

  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('erp.job_tenant_id', v_job, true);
  perform set_config('erp.job_principal_id', v_jobp, true);
end;
$$;

revoke all on function erp_test.administrator_approval_off(uuid) from public, anon, authenticated;

comment on function erp_test.administrator_approval_off(uuid) is
  'Switches administrator approval off in one organisation, opening the bootstrap window around the '
  'write when it is live and restoring the session''s context, so a suite proving two-person approval '
  'keeps proving it (20260914098000).';

do $suites$
declare
  r      record;
  v_def  text;
  v_n    integer := 0;
begin
  for r in
    select * from (values
      ('erp_test.approval_hold_suite()',
       $n$    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-hold-' || v_hex || '.test', 'Second Admin');
$n$,
       $r$    perform erp.claim_invitation(r.admin_token);
    -- Two-person approval is what this organisation proves (20260914098000).
    perform erp_test.administrator_approval_off(r.tenant_id);
    res := public.erp_invite_principal('second@zz-hold-' || v_hex || '.test', 'Second Admin');
$r$),
      ('erp_test.email_action_suite()',
       $n$    u_admin := erp.claim_invitation(r.admin_token);

    v_step := 'an approver and a colleague join, holding no role';
$n$,
       $r$    u_admin := erp.claim_invitation(r.admin_token);
    -- Two-person approval is what this organisation proves (20260914098000).
    perform erp_test.administrator_approval_off(v_tenant);

    v_step := 'an approver and a colleague join, holding no role';
$r$),
      ('erp_test.journal_and_close_suite()',
       $n$    u_admin := erp.claim_invitation(ra.admin_token);
    select i.app_user_id, i.token into u_second, t_tok
$n$,
       $r$    u_admin := erp.claim_invitation(ra.admin_token);
    -- Two-person approval is what this organisation proves (20260914098000).
    perform erp_test.administrator_approval_off(ra.tenant_id);
    select i.app_user_id, i.token into u_second, t_tok
$r$),
      ('erp_test.bootstrap_window_suite()',
       $n$  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
$n$,
       $r$  v_tenant := (v_onboard ->> 'tenant_id')::uuid;
  -- Two-person approval is what this organisation proves (20260914098000).
  perform erp_test.administrator_approval_off(v_tenant);
$r$),
      ('erp_test.provisioning_window_suite()',
       $n$  insert into auth.users (id, email) values (au, 'admin@zzwindow.test');
$n$,
       $r$  -- Two-person approval is what this organisation proves (20260914098000).
  perform erp_test.administrator_approval_off(v_tenant);
  insert into auth.users (id, email) values (au, 'admin@zzwindow.test');
$r$),
      ('erp_test.interview_ease_suite()',
       $n$    t5 := (v ->> 'tenant_id')::uuid;
$n$,
       $r$    t5 := (v ->> 'tenant_id')::uuid;
    -- Two-person approval is what this organisation proves (20260914098000).
    perform erp_test.administrator_approval_off(t5);
$r$)
    ) as s(sig, needle, replacement)
  loop
    v_def := pg_get_functiondef(r.sig::regprocedure);
    if (length(v_def) - length(replace(v_def, r.needle, ''))) / length(r.needle) <> 1
       or position('administrator_approval_off' in v_def) > 0 then
      raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % is not the body this migration patches', r.sig
        using hint = 'A later migration changed the suite. Read its body with pg_get_functiondef and patch that.';
    end if;
    execute replace(v_def, r.needle, r.replacement);
    v_n := v_n + 1;
  end loop;
  if v_n <> 6 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % of 6 suites were adapted', v_n
      using hint = 'Every suite in the list must be found and patched once.';
  end if;
end
$suites$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Built inside a block that is rolled back, so nothing it makes outlives it:
-- a live organisation with two administrators and a buyer who may approve
-- purchase orders, a live organisation with one administrator, and a
-- demonstration.

create or replace function erp_test.administrator_approval_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before     text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_timeout_before text := current_setting('statement_timeout');
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  ab       uuid := gen_random_uuid();
  ad       uuid := gen_random_uuid();
  v_step   text := 'starting';
  v_state  text;
  ra       record;
  rb       record;
  x        record;
  u1       uuid;
  u2       uuid;
  u3       uuid;
  t2       text;
  t3       text;
  cs_fin   uuid;
  cs_proc  uuid;
  v_role   uuid;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  v_item   uuid;
  v_po1    uuid;
  v_po2    uuid;
  v_po3    uuid;
  v_po4    uuid;
  v_po5    uuid;
  v_req    uuid;
  v_task   uuid;
  v_n      integer;
  v_m      integer;
  v_to     text;
  v_err    text;
  v_err2   text;
  v_cs     uuid;
  v_ccy    char(3);
  v_exp    uuid;
  v_acc    uuid;
  v_out    jsonb;
  v_jnl    uuid;
  v_seed   jsonb;
  v_demo   uuid;
  u_demo   uuid;
  v_base   date := make_date(extract(year from current_date)::integer - 1, 3, 2);
  -- The single administrator's organisation.
  bu       uuid;
  b_uom    uuid;
  b_site   uuid;
  b_sup    uuid;
  b_item   uuid;
  b_po     uuid;

  ok_own     boolean; msg_own     text;
  ok_others  boolean; msg_others  text;
  ok_buyer   boolean; msg_buyer   text;
  ok_off     boolean; msg_off     text;
  ok_reject  boolean; msg_reject  text;
  ok_journal boolean; msg_journal text;
  ok_change  boolean; msg_change  text;
  ok_single  boolean; msg_single  text;
  ok_record  boolean; msg_record  text;
  ok_demo    boolean; msg_demo    text;
begin
  begin
    -- ── Organisation A: live, two administrators and a buyer ─────────────────
    v_step := 'organisation A is provisioned and its people join';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzadap-' || v_tag, 'Administrator Approval Suite',
                                               'admin@zzadap-' || v_tag || '.test', 'Approval Admin');
    insert into auth.users (id, email) values
      (a1, 'admin@zzadap-' || v_tag || '.test'),
      (a2, 'second@zzadap-' || v_tag || '.test'),
      (a3, 'buyer@zzadap-' || v_tag || '.test'),
      (ab, 'solo@zzadap1-' || v_tag || '.test'),
      (ad, 'demo@zzadapd-' || v_tag || '.test');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    u1 := erp.claim_invitation(ra.admin_token);
    select i.app_user_id, i.token into u2, t2
      from erp.invite_principal('second@zzadap-' || v_tag || '.test', 'Second Admin') i;
    perform erp.grant_role(u2, 'administrator', null, null, 'co-administrator');
    select i.app_user_id, i.token into u3, t3
      from erp.invite_principal('buyer@zzadap-' || v_tag || '.test', 'Bea Buyer') i;

    v_step := 'finance and procurement are installed, and the second administrator puts them in force';
    cs_fin := erp.configure_finance();
    cs_proc := (public.erp_configure_procurement(1000000, 'purchasing') ->> 'change_set_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(t2);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);

    v_step := 'a buyer''s role, and each person given their roles by somebody else';
    perform erp_test.reopen_bootstrap_window(ra.tenant_id);
    insert into erp.role (tenant_id, code, name, status)
    values (ra.tenant_id, 'zz_buyer', 'Suite buyer', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select ra.tenant_id, v_role, p
      from unnest(array['procurement.read', 'procurement.order', 'procurement.approve',
                        'master_data.read', 'inventory.read']) p;
    perform erp_test.close_bootstrap_window(ra.tenant_id);
    perform erp.grant_role(u1, 'purchasing', null, null, 'approves purchase orders');
    perform erp.grant_role(u3, 'zz_buyer', null, null, 'raises and approves purchase orders');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.grant_role(u2, 'purchasing', null, null, 'approves purchase orders');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(t3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (ra.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (ra.tenant_id, ra.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.party (tenant_id, code, name, status)
    values (ra.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (ra.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (ra.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;

    -- ── 1. Their own order, in one press ────────────────────────────────────
    v_step := 'the administrator submits an order and approves it';
    v_po1 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po1, v_item, 10, 5000, 'Ten widgets');
    perform erp.transition_document(v_po1, 'submit');
    select q.id into v_req from erp.approval_request q
     where q.tenant_id = ra.tenant_id and q.object_type = 'document' and q.object_id = v_po1 and q.status = 'pending';
    select count(*) into v_n from erp.approval_task t
     where t.tenant_id = ra.tenant_id and t.approval_request_id = v_req and t.status = 'pending'
       and t.assignee_user_id = u2;
    v_to := erp.transition_document(v_po1, 'approve');
    ok_own := v_n = 1 and v_to = 'approved'
          and (select q.status = 'approved' from erp.approval_request q where q.id = v_req)
          and not exists (select 1 from erp.approval_task t where t.approval_request_id = v_req and t.status = 'pending')
          and exists (select 1 from erp.approval_task t
                       where t.approval_request_id = v_req and t.assignee_user_id = u2
                         and t.status = 'approved' and t.decided_by = u1 and t.decided_via = 'administrator'
                         and t.comment like 'Approved as administrator, for the person asked, on their own request%');
    msg_own := format('%s task(s) waiting on the second administrator; the order moved to %s; tasks: %s',
                      v_n, v_to, (select string_agg(t.status || '/' || t.decided_via, ', ')
                                    from erp.approval_task t where t.approval_request_id = v_req));

    -- ── 2 and 3. A buyer's order ────────────────────────────────────────────
    v_step := 'the buyer submits an order and is held while it waits';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_po2 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po2, v_item, 2, 5000, 'Two widgets');
    perform erp.transition_document(v_po2, 'submit');
    begin
      perform erp.transition_document(v_po2, 'approve');
    exception when others then
      v_err := left(sqlerrm, 200);
    end;
    v_step := 'the administrator approves the buyer''s order waiting on both approvers';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select q.id into v_req from erp.approval_request q
     where q.tenant_id = ra.tenant_id and q.object_type = 'document' and q.object_id = v_po2 and q.status = 'pending';
    select count(*) into v_m from erp.approval_task t where t.approval_request_id = v_req and t.status = 'pending';
    v_to := erp.transition_document(v_po2, 'approve');
    ok_others := v_m = 2 and v_to = 'approved'
             and (select count(*) from erp.approval_task t
                   where t.approval_request_id = v_req and t.status = 'approved'
                     and t.decided_by = u1 and t.decided_via = 'administrator') = 2
             and exists (select 1 from erp.approval_task t
                          where t.approval_request_id = v_req and t.assignee_user_id = u2
                            and t.comment = 'Approved as administrator, for the person asked');
    msg_others := format('%s task(s) waiting; the order moved to %s', v_m, v_to);

    v_step := 'the buyer raises another order and approves it themselves once it is agreed';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_po3 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po3, v_item, 3, 5000, 'Three widgets');
    perform erp.transition_document(v_po3, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    select t.id into v_task from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = ra.tenant_id and q.object_type = 'document' and q.object_id = v_po3
       and t.status = 'pending' and t.assignee_user_id = u2;
    perform erp.decide_approval_task(v_task, true, 'agreed');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin
      perform erp.transition_document(v_po3, 'approve');
    exception when others then
      v_err2 := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    ok_buyer := v_err like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%'
            and v_err2 like 'CLOVEERP_DOCUMENT_SELF_APPROVAL%';
    msg_buyer := format('while waiting: %s; once agreed, their own: %s',
                        coalesce(v_err, 'approved'), coalesce(v_err2, 'approved'));

    -- ── 5. A refusal stands ─────────────────────────────────────────────────
    v_step := 'the second administrator refuses the administrator''s order';
    v_po4 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po4, v_item, 4, 5000, 'Four widgets');
    perform erp.transition_document(v_po4, 'submit');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    select t.id into v_task from erp.approval_task t
      join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = ra.tenant_id and q.object_type = 'document' and q.object_id = v_po4
       and t.status = 'pending' and t.assignee_user_id = u2;
    perform erp.decide_approval_task(v_task, false, 'not this quarter');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_err := null;
    begin
      perform erp.transition_document(v_po4, 'approve');
    exception when others then
      v_err := left(sqlerrm, 200);
    end;
    ok_reject := v_err like 'CLOVEERP_DOCUMENT_APPROVAL_REJECTED%';
    msg_reject := coalesce(v_err, 'the administrator approved over a refusal');

    -- ── 6. Their own journal ────────────────────────────────────────────────
    v_step := 'the administrator raises, submits and approves a journal';
    select l.currency into v_ccy from erp.ledger l
     where l.tenant_id = ra.tenant_id and l.entity_id = ra.entity_id and l.is_primary limit 1;
    perform erp_test.reopen_bootstrap_window(ra.tenant_id);
    insert into erp.account (tenant_id, entity_id, code, name, account_type, control_kind, is_postable, currency, status) values
      (ra.tenant_id, ra.entity_id, 'ZZ7100', 'Suite light and heat', 'expense',   null, true, coalesce(v_ccy, 'GBP'), 'active'),
      (ra.tenant_id, ra.entity_id, 'ZZ2300', 'Suite accruals',       'liability', null, true, coalesce(v_ccy, 'GBP'), 'active');
    perform erp_test.close_bootstrap_window(ra.tenant_id);
    select a.id into v_exp from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ7100';
    select a.id into v_acc from erp.account a where a.tenant_id = ra.tenant_id and a.code = 'ZZ2300';
    v_out := public.erp_raise_journal(ra.entity_id, current_date, 'Electricity, estimated by the administrator',
               jsonb_build_array(jsonb_build_object('account_id', v_exp, 'debit_minor', 5000),
                                 jsonb_build_object('account_id', v_acc, 'credit_minor', 5000)),
               null, null, true);
    v_jnl := (v_out ->> 'journal_id')::uuid;
    v_out := public.erp_approve_journal(v_jnl);
    ok_journal := v_out ->> 'state' = 'posted'
              and (select j.posted_by = u1 and j.submitted_by = u1 from erp.journal j where j.id = v_jnl)
              and exists (select 1 from erp.event e
                           where e.tenant_id = ra.tenant_id and e.event_type = 'journal.self_approved'
                             and e.aggregate_id = v_jnl);
    msg_journal := 'the journal is ' || coalesce(v_out ->> 'state', 'not posted');

    -- ── 7. Their own configuration change, once live ────────────────────────
    v_step := 'the administrator raises a change and approves it';
    v_cs := erp.create_change_set('zzadap-words', 'Suite words', 'A change the administrator approves themselves', null);
    perform erp.add_change_set_item(v_cs, 'terminology', 'zzadap.words',
      jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Start'),
      'upsert'::erp.change_operation, current_date, 'the administrator approval suite');
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    ok_change := erp.tenant_is_live(ra.tenant_id)
             and (select c.status = 'approved' and c.approved_by = u1 and c.created_by = u1
                    from erp.change_set c where c.id = v_cs)
             and exists (select 1 from erp.event e
                          where e.tenant_id = ra.tenant_id and e.event_type = 'change_set.self_approved'
                            and e.aggregate_id = v_cs)
             and exists (select 1 from jsonb_array_elements(public.erp_change_sets()) c(el)
                          where c.el ->> 'change_set_id' = v_cs::text);
    msg_change := 'the change is ' || coalesce((select c.status::text from erp.change_set c where c.id = v_cs), 'missing');

    -- ── 9. What was recorded ────────────────────────────────────────────────
    v_step := 'the overrides are read back';
    select count(*) filter (where (e.payload ->> 'own_request')::boolean),
           count(*) filter (where not (e.payload ->> 'own_request')::boolean)
      into v_n, v_m
      from erp.event e
     where e.tenant_id = ra.tenant_id and e.event_type = 'approval.administrator_decided';
    v_out := public.erp_document_approval_decisions(v_po2);
    ok_record := v_n >= 1 and v_m >= 1
             and exists (select 1 from jsonb_array_elements(v_out) d(el)
                          where d.el ->> 'decided_via' = 'administrator'
                            and d.el ->> 'decided_by' = 'Approval Admin'
                            and d.el ->> 'assignee' = 'Second Admin'
                            and not (d.el ->> 'own_request')::boolean)
             and not exists (select 1 from jsonb_array_elements(v_out) d(el) where d.el ->> 'decided_via' <> 'administrator');
    msg_record := format('%s override(s) on the administrator''s own requests, %s on others''; decisions: %s',
                         v_n, v_m, left(v_out::text, 300));

    -- ── 4. Switched off, the refusals come back ─────────────────────────────
    v_step := 'the administrator switches administrator approval off';
    v_out := public.erp_set_administrator_approval(false, 'every approval here has two people behind it');
    v_cs := (v_out ->> 'change_set_id')::uuid;
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v_step := 'with it off, the administrator submits an order and tries to approve it';
    v_po5 := erp.open_document('purchase_order', v_sup, null, v_site);
    perform erp.add_document_line(v_po5, v_item, 5, 5000, 'Five widgets');
    perform erp.transition_document(v_po5, 'submit');
    v_err := null;
    begin
      perform erp.transition_document(v_po5, 'approve');
    exception when others then
      v_err := left(sqlerrm, 200);
    end;
    v_err2 := null;
    begin
      v_cs := erp.create_change_set('zzadap-words2', 'Suite words again', 'A change the administrator may not approve', null);
      perform erp.add_change_set_item(v_cs, 'terminology', 'zzadap.words2',
        jsonb_build_object('key', 'nav.home', 'locale', 'en', 'value', 'Begin'),
        'upsert'::erp.change_operation, current_date, 'the administrator approval suite');
      perform erp.submit_change_set(v_cs);
      perform erp.approve_change_set(v_cs);
    exception when others then
      v_err2 := left(sqlerrm, 200);
    end;
    ok_off := v_out ->> 'route' = 'change_set'
          and not erp.administrator_approval_allowed()
          and not erp.approves_as_administrator()
          and (public.erp_administrator_approval() -> 0 ->> 'allowed')::boolean is false
          and v_err like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%'
          and v_err2 like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL%';
    msg_off := format('route %s; allowed now %s; the order: %s; their own change: %s',
                      v_out ->> 'route', erp.administrator_approval_allowed(),
                      coalesce(v_err, 'approved'), coalesce(v_err2, 'approved'));

    -- ── 8. One administrator, live ──────────────────────────────────────────
    v_step := 'organisation B is provisioned with one administrator';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('zzadap1-' || v_tag, 'Administrator Approval Suite, alone',
                                               'solo@zzadap1-' || v_tag || '.test', 'Solo Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', ab)::text, true);
    bu := erp.claim_invitation(rb.admin_token);
    v_step := 'the one administrator installs finance and procurement and puts them in force';
    v_cs := erp.configure_finance();
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v_cs := (public.erp_configure_procurement(1000000, 'administrator') ->> 'change_set_id')::uuid;
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (rb.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into b_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into b_site;
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'SUP', 'Supplier', 'active') returning id into b_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, b_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'WID', 'Widget', b_uom, 'active') returning id into b_item;
    v_step := 'the one administrator submits an order and approves it';
    b_po := erp.open_document('purchase_order', b_sup, null, b_site);
    perform erp.add_document_line(b_po, b_item, 1, 5000, 'One widget');
    perform erp.transition_document(b_po, 'submit');
    v_to := erp.transition_document(b_po, 'approve');
    ok_single := erp.tenant_is_live(rb.tenant_id)
             and v_to = 'approved'
             and exists (select 1 from erp.approval_task t
                           join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
                          where q.tenant_id = rb.tenant_id and q.object_id = b_po
                            and t.assignee_user_id = bu and t.decided_by = bu
                            and t.decided_via = 'administrator' and t.status = 'approved');
    msg_single := format('live %s; the order moved to %s', erp.tenant_is_live(rb.tenant_id), v_to);

    -- ── 10. A demonstration still builds its history ────────────────────────
    v_step := 'a demonstration is made and two days of its trading are built';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
    perform set_config('statement_timeout', '0', true);
    v_seed := erp.seed_demo();
    v_demo := (v_seed ->> 'tenant_id')::uuid;
    u_demo := (v_seed ->> 'principal_id')::uuid;
    perform erp.ensure_demo_configuration(v_demo, u_demo);
    v_out := erp.seed_demo_history(v_base, v_base + 1, 1);
    ok_demo := erp.tenant_is_demonstration(v_demo)
           and (v_out ->> 'done')::boolean
           and (v_out ->> 'built')::integer > 0
           and not exists (select 1 from erp.notification n where n.tenant_id = v_demo and n.channel_kind <> 'in_app');
    msg_demo := left(coalesce(v_out::text, 'nothing built'), 200);

    v_step := 'done';
    raise exception 'ZZ_ADMINISTRATOR_APPROVAL_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_ADMINISTRATOR_APPROVAL_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'an administrator approves their own order in a live organisation in one press, deciding the task waiting on somebody else';
  passed := v_state is null and coalesce(ok_own, false);
  detail := coalesce(v_state, msg_own);
  return next;

  case_name := 'an administrator approves an order whose tasks wait on others, and each task says it was decided as administrator';
  passed := v_state is null and coalesce(ok_others, false);
  detail := coalesce(v_state, msg_others);
  return next;

  case_name := 'a buyer who may approve orders is still held while tasks wait, and still refused their own order';
  passed := v_state is null and coalesce(ok_buyer, false);
  detail := coalesce(v_state, msg_buyer);
  return next;

  case_name := 'switched off through its door and a promoted change, the administrator is refused as before';
  passed := v_state is null and coalesce(ok_off, false);
  detail := coalesce(v_state, msg_off);
  return next;

  case_name := 'a refused request is not approved over, even by an administrator';
  passed := v_state is null and coalesce(ok_reject, false);
  detail := coalesce(v_state, msg_reject);
  return next;

  case_name := 'an administrator approves and posts their own journal once live, and it is recorded';
  passed := v_state is null and coalesce(ok_journal, false);
  detail := coalesce(v_state, msg_journal);
  return next;

  case_name := 'an administrator approves their own configuration change once live, and it is recorded';
  passed := v_state is null and coalesce(ok_change, false);
  detail := coalesce(v_state, msg_change);
  return next;

  case_name := 'a live organisation with one administrator submits and approves an order';
  passed := v_state is null and coalesce(ok_single, false);
  detail := coalesce(v_state, msg_single);
  return next;

  case_name := 'every override is recorded, and the document''s decisions say whose task was decided as administrator';
  passed := v_state is null and coalesce(ok_record, false);
  detail := coalesce(v_state, msg_record);
  return next;

  case_name := 'a demonstration still builds its trading history and sends nothing';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t
                         where t.code in ('zzadap-' || v_tag, 'zzadap1-' || v_tag)
                            or t.id = v_demo)
        and not exists (select 1 from auth.users au where au.id in (a1, a2, a3, ab, ad))
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before
        and current_setting('statement_timeout') = v_timeout_before;
  detail := 'the organisations, their people, orders, journals and changes went with the block';
  return next;
end;
$$;

revoke all on function erp_test.administrator_approval_suite() from public, anon, authenticated;

create or replace function erp_test.assert_administrator_approval_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 11;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _administrator_approval on commit drop as
    select * from erp_test.administrator_approval_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _administrator_approval s;
  drop table _administrator_approval;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_ADMINISTRATOR_APPROVAL_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_ADMINISTRATOR_APPROVAL_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('administrator approval: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_administrator_approval_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
select erp.assert_no_dead_configuration();
select erp.assert_personal_data_register_sound();

select erp_test.assert_administrator_approval_suite();
select erp_test.assert_approval_hold_suite();
select erp_test.assert_email_action_suite();
select erp_test.assert_journal_and_close_suite();
select erp_test.assert_interview_ease_suite();
select erp_test.assert_bootstrap_window_suite();
select erp_test.assert_provisioning_window_suite();
select erp_test.assert_notification_product_routes_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
