-- ─────────────────────────────────────────────────────────────────────────────
-- A door that reports what it did, not what it was asked to do.
--
-- Found by the production-readiness pass, Phase 1, by feeding one organisation's
-- identifiers to another organisation's doors. Isolation held — every update is
-- scoped by tenant_id and nothing foreign was read or written. What did not hold
-- is what the doors then SAID:
--
--   select public.erp_retire_approval_band('00000000-0000-4000-8000-000000000000');
--     -> {"band_id": "00000000-...", "retired": true}
--
-- That identifier has never existed in any organisation. The update matched no
-- row, and the function returned success regardless, because the return value
-- never depended on whether anything was updated. An administrator retiring an
-- approval band is told it is retired; the band is still live and still
-- approving. This is the fault this codebase is built to refuse — the product
-- recording an outcome it did not produce — arriving through the return value
-- rather than through the write.
--
-- erp.approve_change_set had the same shape for a subtler reason, and it is the
-- more serious of the two because approval is a governance control:
--
--   select * into cs from erp.change_set where tenant_id = v_tenant and id = ...;
--   if cs.status <> 'ready' then raise ...
--
-- With no row found, cs is all NULLs, so `cs.status <> 'ready'` is NULL — not
-- true — and the guard does not fire. Nor does any guard after it. The final
-- update matches nothing and the caller is told the change set was approved.
-- Three-valued logic, and every branch reads as if it were two-valued.
--
-- The last piece is the platform audit trail. erp.access_log refuses UPDATE and
-- DELETE through erp.forbid_mutation, even to a superuser. erp_meta.platform_audit
-- carried no such trigger: on the service connection the workers use,
-- `delete from erp_meta.platform_audit` removed every row and refused nothing.
-- The tenant path was never open — erp_meta is not granted to authenticated —
-- but the record of platform support access could be erased by the same
-- connection that drains the outbox. It gets the same guard the access log has.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The governance control ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.approve_change_set(p_change_set_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  cs       erp.change_set%rowtype;
  v_status erp.approval_status;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs from erp.change_set where tenant_id = v_tenant and id = p_change_set_id;

  -- Before any comparison against cs. Every check below reads a column of a row
  -- that may not exist, and `null <> 'ready'` is null, which no `if` will fire on.
  if not found then
    raise exception
      'ERPWARE_CHANGE_SET_NOT_FOUND: no change set % in this organisation', p_change_set_id
      using errcode = '23503',
      hint = 'Check the change set is one of this organisation''s own; a change '
             'set belonging to another organisation is not visible here.';
  end if;

  if cs.status <> 'ready' then
    raise exception 'ERPWARE_CHANGE_SET_NOT_READY: % is %', cs.code, cs.status
      using errcode = '23514';
  end if;

  if cs.approval_request_id is not null then
    select ar.status into v_status from erp.approval_request ar where ar.id = cs.approval_request_id;
    if v_status <> 'approved' then
      raise exception 'ERPWARE_CHANGE_SET_APPROVAL_PENDING: the approval request is %', v_status
        using errcode = '23514';
    end if;
  end if;

  -- Whoever raised the change may not be the one who waves it through — once
  -- the tenant is live and there is somebody else to be.
  if erp.tenant_is_live(v_tenant)
     and cs.created_by is not null
     and cs.created_by = erp.current_principal_id() then
    raise exception
      'ERPWARE_CHANGE_SET_SELF_APPROVAL: the author of a change set may not approve it'
      using errcode = '42501',
      hint = 'Grant administration.promote to a second principal.';
  end if;

  update erp.change_set
     set status = 'approved', approved_by = erp.current_principal_id(),
         approved_at = now(), updated_at = now()
   where tenant_id = v_tenant and id = p_change_set_id;
end;
$function$;

-- ── The five doors that reported an update they had not made ─────────────────

CREATE OR REPLACE FUNCTION public.erp_retire_approval_band(p_band_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.approval_band
     set status = 'inactive', valid_to = current_date
   where tenant_id = v_tenant and id = p_band_id;
  if not found then
    raise exception 'ERPWARE_APPROVAL_BAND_NOT_FOUND: no approval band % in this organisation', p_band_id
      using errcode = '23503',
      hint = 'Open Settings → Organisation → approval bands and retire it from the list, '
             'which offers only bands this organisation holds.';
  end if;
  return jsonb_build_object('band_id', p_band_id, 'retired', true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_end_approver_assignment(p_assignment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.approver_assignment
     set status = 'inactive', valid_to = current_date
   where tenant_id = v_tenant and id = p_assignment_id;
  if not found then
    raise exception 'ERPWARE_APPROVER_ASSIGNMENT_NOT_FOUND: no approver assignment % in this organisation', p_assignment_id
      using errcode = '23503',
      hint = 'Open Settings → Organisation → approvers and end the assignment from the list, '
             'which offers only assignments this organisation holds.';
  end if;
  return jsonb_build_object('assignment_id', p_assignment_id, 'ended', true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_end_department_membership(p_membership_id uuid, p_valid_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('administration.configure');
  update erp.principal_department
     set valid_to = coalesce(p_valid_to, current_date), status = 'inactive'
   where tenant_id = v_tenant and id = p_membership_id;
  if not found then
    raise exception 'ERPWARE_DEPARTMENT_MEMBERSHIP_NOT_FOUND: no department membership % in this organisation', p_membership_id
      using errcode = '23503',
      hint = 'Open Settings → Organisation → structure and end the membership from the '
             'department it belongs to.';
  end if;
  return jsonb_build_object('membership_id', p_membership_id, 'ended', true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_end_item_supplier(p_item_supplier_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('master_data.write');
  -- 'retired' is not a value of erp.record_status (draft, active, inactive,
  -- archived), so this door raised `invalid input value for enum` on every call
  -- it had ever received — it has never once ended a product-supplier link. The
  -- sibling doors all use 'inactive' and this now does too. Found because the
  -- suite below could not tell a not-found refusal from a door that simply does
  -- not work; both look like "it refused".
  update erp.item_supplier
     set valid_to = current_date, status = 'inactive', is_default = false,
         updated_at = now()
   where tenant_id = v_tenant and id = p_item_supplier_id;
  if not found then
    raise exception 'ERPWARE_ITEM_SUPPLIER_NOT_FOUND: no product-supplier link % in this organisation', p_item_supplier_id
      using errcode = '23503',
      hint = 'Open Settings → Configure → product-suppliers and end the link from the '
             'product it belongs to.';
  end if;
  return jsonb_build_object('item_supplier_id', p_item_supplier_id,
                            'reason', p_reason);
end;
$function$;

CREATE OR REPLACE FUNCTION public.erp_retire_account_determination(p_rule_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  perform erp.authorise('finance.configure');
  -- Same enum fault as erp_end_item_supplier above: 'retired' is not a
  -- record_status, so this door has never retired a determination rule.
  update erp.account_determination
     set status = 'inactive', valid_to = current_date, updated_at = now()
   where tenant_id = v_tenant and id = p_rule_id;
  if not found then
    raise exception 'ERPWARE_ACCOUNT_DETERMINATION_NOT_FOUND: no account determination rule % in this organisation', p_rule_id
      using errcode = '23503',
      hint = 'Open Settings → Configure → account determination and retire the rule '
             'from the matrix, which lists only this organisation''s rules.';
  end if;
  return jsonb_build_object('rule_id', p_rule_id, 'status', 'inactive');
end;
$function$;

-- ── The platform audit trail, append-only like the access log ────────────────

drop trigger if exists t_platform_audit_append_only on erp_meta.platform_audit;
create trigger t_platform_audit_append_only
  before update or delete on erp_meta.platform_audit
  for each row execute function erp.forbid_mutation();

comment on trigger t_platform_audit_append_only on erp_meta.platform_audit is
  'The record of platform support access is evidence. It was reachable for '
  'DELETE on the service connection the workers use — not by any tenant, but by '
  'the process that drains the outbox. erp.access_log has refused this since it '
  'was written; this table now refuses it the same way and through the same '
  'function, so the two cannot drift.';

select erp.assert_public_api_safe();
