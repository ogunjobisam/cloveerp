-- Credit, and the last open items.
--
-- The persona walk of 14 September left five things open. Each was checked
-- against the definitions as they stand after every patch before this file was
-- written, reading every later execute replace(pg_get_functiondef(...)) as well
-- as every CREATE, and each was true:
--
--   1. Credit control stopped at a flag.
--      (a) A customer's credit limit lived in two places. erp.credit_position()
--          (20260829280000, restated by 20260906142000) reads
--          erp.party_role_terms: a limit, a status, a block and its reason,
--          dated, per company. erp.document_transition_context()
--          (20260829370000, never patched), which the sales order approval
--          chain's credit step compares against, read
--          erp.party_role.attributes ->> 'credit_limit_minor'. No screen or
--          door wrote either; only suite fixtures wrote the attribute.
--      (b) Nothing set a limit. sales.credit_release ("Release credit holds")
--          is the one credit permission the catalogue carries; the base pack
--          gives it to the sales manager, and erp.release_credit_hold() asks
--          for it.
--      (c) erp.check_release_to_fulfilment() (20260829280000, never patched)
--          was called by a suite and nothing else. erp.pick_document()
--          (20260910165931, never patched), erp.commit_allocation()
--          (20260906070000, patched by 20260906142000; the scanner's pick
--          lands here too) and erp.create_delivery_from_order()
--          (20260914064000, never patched) released a held order to the
--          warehouse without asking. Its refusal, CLOVEERP_CREDIT_HOLD, was
--          registered nowhere and its hint named a function.
--      (d) sales.discount_approve was authorised by nothing. The sales order
--          terms chain erp.configure_sales() installs has a discount step and
--          a credit step, and its own comment says the first "needs someone
--          who may approve discounts" and the second "someone who may release
--          credit"; erp.decide_approval_task() asked only that the task was
--          the caller's and, once live, that the caller had not asked for it.
--      (e) erp.invoice_from_delivery() (20260829280000, patched by
--          20260914070000) refused the despatcher (CLOVEERP_SEGREGATION_OF_
--          DUTIES), and p_allow_self_invoice switched the refusal off for
--          anybody who ticked it. Its hint talked about "B1" and permission
--          codes.
--
--   2. "Commit an allocation" asked for an id to be typed: no door listed
--      allocations.
--
--   3. erp.remove_principal() (20260914020000) refuses removing the last
--      person who manages users (CLOVEERP_LAST_USER_MANAGER), and 020000 said
--      in so many words that "the rule ... is kept by removal only".
--      public.erp_set_user_roles() and public.erp_revoke_role() (both as
--      20260914065000 left them) could end the last grant carrying
--      administration.users, and so could a promoted role change or a role
--      taken out of use (erp.apply_change_set_item(), role arm as 065000 left
--      it) and the role editor (public.erp_save_role()). erp.grant_role() and
--      public.erp_grant_role() only add a grant and cannot take one away.
--
--   4. "Pin a line's stock identity" asked erp_document_lines for open lines
--      only, which still offered a confirmed order's lines, and
--      erp.set_line_stock_identity() (20260906090000, never patched) refused a
--      committed document but not a cancelled one: a cancelled draft is
--      terminal and was never committed.
--
--   5. public.erp_seed_demo_configuration() (20260904500000) was open to
--      anybody holding administration.configure. 20260914030000 kept the
--      other demonstration doors for platform staff and left this one out.
--
-- What this file does, in order:
--
--   1. Credit.
--      (a) One place. erp.party_role_terms is where a limit is kept, because
--          it is what erp.credit_position() and the release check read and it
--          carries the hold, the dates and the company. The approval context
--          reads the terms in force (the document's company first) and falls
--          back to the customer role's attribute only for a customer with no
--          terms in force, so nothing that relied on the attribute changes.
--          Every active customer role that carries an attribute limit and has
--          no terms in force or to come is given terms at the organisation's
--          first company from today, with the limit, so the release check sees
--          the limit the approval chain saw. The attribute is left where it is.
--          erp.party_role_terms gains credit_reason: why the limit or the hold
--          was last set, kept with the row and in its audit trail.
--      (b) public.erp_set_credit_limit(p_party_id, p_credit_limit_minor,
--          p_on_hold, p_reason), under sales.credit_release. The limit is in
--          minor units (the desk takes pounds); empty is no limit. A hold is a
--          block with the reason. The terms in force are changed in place (the
--          audit trail keeps what they said); a customer with none is given
--          terms from today at the organisation's first company. Refuses a
--          business partner who is not a customer (CLOVEERP_NOT_A_CUSTOMER), a
--          limit below nought (CLOVEERP_CREDIT_LIMIT_NEGATIVE) and a change
--          with no reason (CLOVEERP_CREDIT_CHANGE_NEEDS_REASON). Returns the
--          customer's position as it now stands.
--      (c) erp.check_release_to_fulfilment() is restated: a customer over the
--          limit, on hold, or overdue past the policy's window is refused with
--          CLOVEERP_CREDIT_HOLD, saying why in words and pointing at "Release a
--          credit hold". A released order and a customer with no terms pass.
--          erp.pick_document(), erp.commit_allocation() and
--          erp.create_delivery_from_order() ask it after they authorise.
--      (d) sales.discount_approve is wired rather than dropped: approving the
--          discount step of the sales order terms chain authorises it, and
--          approving the credit step authorises sales.credit_release, as the
--          installer has always described the two steps. Refusing either step
--          still needs neither, because it only sends the order back. Dropping
--          the code would have rewritten roles organisations hold and left a
--          discount above the threshold approvable by anybody the task found.
--          erp_decide_approval now reaches a gate, so its register row no
--          longer says it needs none.
--      (e) Invoicing a delivery you despatched is a governed exception. Before
--          go-live it is allowed as it was. Once live, p_allow_self_invoice
--          needs p_self_invoice_reason in at least twenty characters
--          (CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT, 20260914065000) and the
--          caller needs administration.promote, as a separation-of-duties
--          exception does; the invoice records who, when and why. The door and
--          the erp function gain the reason, so both are dropped and created
--          again; the Part 5 register names the new signature.
--
--   2. public.erp_allocations(p_order_id, p_status, p_limit), under
--      sales.read: each allocation with its order, line, customer, product,
--      quantity, shortfall, site and date. The desk's "Commit an allocation"
--      picks from the reservations it lists.
--
--   3. Nobody is left unable to manage people. erp.user_managers_before_change()
--      takes the lock erp.remove_principal() takes, so removals and role
--      changes in one organisation queue behind each other, and counts who
--      manages users; erp.require_user_managers_remain() refuses, with
--      CLOVEERP_LAST_USER_MANAGER, a change that takes that count from some to
--      none. public.erp_set_user_roles(), public.erp_revoke_role() and
--      public.erp_save_role() are restated with it, and the promoter's role
--      arm is patched for a changed role and a role taken out of use. A
--      rollback restores what was there and is not held up, as 20260914065000
--      decided for duties.
--
--   4. erp.set_line_stock_identity() is restated: a line of a cancelled or
--      finished document, or a cancelled line, is refused
--      (CLOVEERP_DOCUMENT_FINISHED), and the committed refusal says what to
--      do. The desk asks for lines of orders in draft or waiting on approval.
--
--   5. public.erp_seed_demo_configuration() asks
--      erp.require_demo_for_platform_staff() first, as the other demonstration
--      doors do. The desk shows its button only to the people useMaySeedDemo()
--      names and who may change configuration.
--
-- The desk: Sales offers "Set a customer's credit limit" and releases a hold
-- from a list of confirmed orders; "Invoice a delivery" shows the self-invoice
-- choice and its reason only to somebody who may promote configuration;
-- "Commit an allocation" picks the reservation; "Pin a line's stock identity"
-- offers lines of orders still being prepared.
--
-- Proof: erp_test.last_open_items_suite(), twenty-two cases, pinned by its
-- wrapper; and the suites these rules touch, run again at the end.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1a. A credit limit is kept in one place
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.party_role_terms
  add column if not exists credit_reason text;

comment on column erp.party_role_terms.credit_reason is
  'Why the credit limit or the credit hold was last set, as the person who set '
  'it said (public.erp_set_credit_limit, 20260914074000). The audit trail keeps '
  'every earlier reason with the values it explained.';

do $context$
declare
  v_sig text := 'erp.document_transition_context(uuid,text)';
  v_def text := pg_get_functiondef('erp.document_transition_context(uuid,text)'::regprocedure);
  v_n   text := $n$  select coalesce((pr.attributes ->> 'credit_limit_minor')::bigint, 9223372036854775807)
    into v_limit
    from erp.party_role pr
   where pr.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer' and pr.status = 'active'
   limit 1;
$n$;
  v_r   text := $r$  -- The limit is read from the customer's trading terms in force, the one
  -- place a limit is set and the place the credit position reads
  -- (20260914074000), the document's company first. A customer with no terms
  -- in force is read from the limit their customer role carried before terms
  -- held it.
  select t.credit_limit_minor
    into v_limit
    from erp.party_role_terms t
    join erp.party_role pr on pr.tenant_id = t.tenant_id and pr.id = t.party_role_id
   where t.tenant_id = v_tenant and pr.party_id = d.party_id
     and pr.role_kind = 'customer'
     and t.valid_from <= current_date
     and (t.valid_to is null or t.valid_to > current_date)
   order by (t.entity_id = d.entity_id) desc, t.valid_from desc
   limit 1;

  if not found then
    select (pr.attributes ->> 'credit_limit_minor')::bigint
      into v_limit
      from erp.party_role pr
     where pr.tenant_id = v_tenant and pr.party_id = d.party_id
       and pr.role_kind = 'customer' and pr.status = 'active'
     limit 1;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not read the limit the way the 20260829370000 body does', v_sig
      using hint = 'A later migration changed where the approval context reads a credit limit. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('from erp.party_role_terms t' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without reading the terms', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$context$;

-- A limit a customer role carries and no terms hold becomes terms from today.
do $move$
declare
  v_moved integer;
begin
  insert into erp.party_role_terms
    (tenant_id, party_role_id, entity_id, currency, credit_limit_minor,
     credit_status, is_blocked, credit_reason, valid_from)
  select pr.tenant_id, pr.id, e.id, e.base_currency,
         (pr.attributes ->> 'credit_limit_minor')::bigint,
         'ok', false,
         'Moved from the customer record when trading terms became the one place a credit limit is kept.',
         current_date
    from erp.party_role pr
    cross join lateral (
      select en.id, en.base_currency
        from erp.entity en
       where en.tenant_id = pr.tenant_id and en.status = 'active'
       order by en.code
       limit 1) e
   where pr.role_kind = 'customer'
     and pr.status = 'active'
     and (pr.attributes ->> 'credit_limit_minor') ~ '^[0-9]{1,18}$'
     and not exists (select 1 from erp.party_role_terms t
                      where t.tenant_id = pr.tenant_id and t.party_role_id = pr.id
                        and (t.valid_to is null or t.valid_to > current_date));
  get diagnostics v_moved = row_count;
  raise notice 'credit limits moved from customer roles into trading terms: %', v_moved;
end
$move$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1c. A held order is not released to the warehouse
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260829280000, so the grants stay.
create or replace function erp.check_release_to_fulfilment(p_document_id uuid)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  d        erp.document%rowtype;
  c        record;
  v_why    text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found or d.party_id is null then
    return 'clear';
  end if;

  -- No terms in force is no credit control: the credit position answers no row.
  select * into c from erp.credit_position(d.party_id);
  if not found or not coalesce(c.on_hold, false) then
    return 'clear';
  end if;

  -- Somebody who may release credit holds released this order, with a reason.
  if d.attributes ? 'credit_released_by' then
    return 'released';
  end if;

  v_why := case
    when coalesce(c.is_blocked, false) then
      format('the customer is on credit hold (%s)', coalesce(nullif(btrim(c.reason), ''), 'no reason was recorded'))
    when c.reason = 'exposure exceeds the credit limit' then
      format('the customer owes and has on order %s, over their credit limit of %s',
             to_char(c.exposure_minor / 100.0, 'FM999,999,999,990.00'),
             to_char(c.credit_limit_minor / 100.0, 'FM999,999,999,990.00'))
    else 'the customer has debt overdue beyond the organisation''s credit policy'
  end;

  raise exception 'CLOVEERP_CREDIT_HOLD: % is held on credit, because %', d.document_number, v_why
    using errcode = '42501',
          hint = 'Somebody who may release credit holds can release the order on the Sales screen with Release a credit hold, giving the reason, or change the customer''s credit with Set a customer''s credit limit. Then pick or deliver it again.';
end;
$$;

comment on function erp.check_release_to_fulfilment(uuid) is
  'Whether an order may go to the warehouse: clear when its customer has no '
  'terms in force or is within them, released when somebody released the hold, '
  'and otherwise refused CLOVEERP_CREDIT_HOLD, saying why. Asked by '
  'erp.pick_document(), erp.commit_allocation() and '
  'erp.create_delivery_from_order() after they authorise (20260914074000).';

do $release$
declare
  v_sig  text;
  v_def  text;
  v_n    text;
  v_r    text;
  v_done integer := 0;
begin
  -- Picking the order.
  v_sig := 'erp.pick_document(uuid,uuid,uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$  perform erp.authorise('sales.despatch', d.entity_id, d.site_id, null,
                        'document', p_document_id);
$n$;
  v_r := $r$  perform erp.authorise('sales.despatch', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- An order over its customer's credit, or for a customer on credit hold,
  -- is not released to the warehouse until somebody releases it
  -- (20260914074000).
  perform erp.check_release_to_fulfilment(p_document_id);
$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not authorise the way the 20260910165931 body does', v_sig
      using hint = 'A later migration changed how an order is picked. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
  v_done := v_done + 1;

  -- Committing one reservation, from the desk or a scanner.
  v_sig := 'erp.commit_allocation(uuid,uuid,uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$  perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                        'allocation', p_allocation_id);
$n$;
  v_r := $r$  perform erp.authorise('sales.despatch', al.entity_id, al.site_id, null,
                        'allocation', p_allocation_id);

  -- The order the reservation is for is not released to the warehouse over
  -- its customer's credit (20260914074000).
  if al.document_id is not null then
    perform erp.check_release_to_fulfilment(al.document_id);
  end if;
$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not authorise the way the 20260906070000 body does', v_sig
      using hint = 'A later migration changed how a reservation is committed. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
  v_done := v_done + 1;

  -- Raising a delivery from the order.
  v_sig := 'erp.create_delivery_from_order(uuid,jsonb,text)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_n := $n$  -- One delivery at a time from one order, so two people cannot both take what
  -- is left.
$n$;
  v_r := $r$  -- Nor is it delivered over its customer's credit (20260914074000).
  perform erp.check_release_to_fulfilment(p_order_id);

  -- One delivery at a time from one order, so two people cannot both take what
  -- is left.
$r$;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not lock its order the way the 20260914064000 body does', v_sig
      using hint = 'A later migration changed how a delivery is raised from an order. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);
  v_done := v_done + 1;

  if (select count(*)
        from pg_catalog.pg_proc p
       where p.oid in ('erp.pick_document(uuid,uuid,uuid)'::regprocedure,
                       'erp.commit_allocation(uuid,uuid,uuid)'::regprocedure,
                       'erp.create_delivery_from_order(uuid,jsonb,text)'::regprocedure)
         and position('erp.check_release_to_fulfilment(' in p.prosrc) > 0) <> v_done then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % of 3 routines that release an order to the warehouse ask about credit', v_done
      using hint = 'A replacement did not land. Compare the needles with pg_get_functiondef() of each.';
  end if;
end
$release$;

update erp_ref.part5_capability
   set artefacts = artefacts || array['public.erp_set_credit_limit(uuid,bigint,boolean,text)']
 where code = '5.6.credit'
   and not ('public.erp_set_credit_limit(uuid,bigint,boolean,text)' = any (artefacts));

-- ═════════════════════════════════════════════════════════════════════════════
-- 1b. A customer's credit is set
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_set_credit_limit(
  p_party_id           uuid,
  p_credit_limit_minor bigint  default null,
  p_on_hold            boolean default false,
  p_reason             text    default null
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_role    uuid;
  v_name    text;
  v_reason  text := nullif(btrim(coalesce(p_reason, '')), '');
  v_hold    boolean := coalesce(p_on_hold, false);
  t         erp.party_role_terms%rowtype;
  v_found   boolean;
  v_entity  uuid;
  v_ccy     char(3);
  v_next    date;
  v_was_limit bigint;
  v_was_hold  boolean := false;
  c         record;
begin
  perform erp.authorise('sales.credit_release', null, null, null, 'party', p_party_id);
  v_tenant := erp.require_tenant_id();

  select pr.id, coalesce(nullif(btrim(p.name), ''), p.code)
    into v_role, v_name
    from erp.party p
    join erp.party_role pr
      on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant and p.id = p_party_id
   order by pr.created_at
   limit 1;

  if v_role is null then
    raise exception 'CLOVEERP_NOT_A_CUSTOMER: that business partner is not a customer here, so it has no credit to set'
      using errcode = '23503',
            hint = 'Choose a customer, or make the business partner a customer first.';
  end if;

  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'CLOVEERP_CREDIT_LIMIT_NEGATIVE: a credit limit for % cannot be below nought', v_name
      using errcode = '22023',
            hint = 'Enter nought or more, or leave the limit empty for no limit. To stop the customer''s orders, put them on credit hold instead.';
  end if;

  if v_reason is null then
    raise exception 'CLOVEERP_CREDIT_CHANGE_NEEDS_REASON: a change to the credit of % needs its reason', v_name
      using errcode = '22023',
            hint = 'Say why the limit or the hold is changing. The reason is kept with the customer''s terms.';
  end if;

  -- The terms in force, most recently begun: the row the credit position reads.
  select * into t
    from erp.party_role_terms x
   where x.tenant_id = v_tenant and x.party_role_id = v_role
     and x.valid_from <= current_date
     and (x.valid_to is null or x.valid_to > current_date)
   order by x.valid_from desc
   limit 1
     for update;
  v_found := found;

  if v_found then
    v_was_limit := t.credit_limit_minor;
    v_was_hold := t.is_blocked;

    update erp.party_role_terms x
       set credit_limit_minor = p_credit_limit_minor,
           is_blocked = v_hold,
           block_reason = case when v_hold then v_reason end,
           credit_status = case when v_hold then 'hold'
                                when x.credit_status in ('hold', 'stop') then 'ok'
                                else x.credit_status end,
           credit_reason = v_reason,
           updated_at = now()
     where x.tenant_id = v_tenant and x.id = t.id;
  else
    select en.id, en.base_currency into v_entity, v_ccy
      from erp.entity en
     where en.tenant_id = v_tenant and en.status = 'active'
     order by en.code
     limit 1;

    if v_entity is null then
      raise exception 'CLOVEERP_NO_ENTITY: this organisation has no company to keep a customer''s terms with'
        using errcode = '23503',
              hint = 'Set up the organisation''s company first, then set the customer''s credit.';
    end if;

    -- Terms already dated to begin later end this row where they begin.
    select min(x.valid_from) into v_next
      from erp.party_role_terms x
     where x.tenant_id = v_tenant and x.party_role_id = v_role
       and x.entity_id = v_entity and x.valid_from > current_date;

    insert into erp.party_role_terms
      (tenant_id, party_role_id, entity_id, currency, credit_limit_minor,
       credit_status, is_blocked, block_reason, credit_reason, valid_from, valid_to)
    values
      (v_tenant, v_role, v_entity, v_ccy, p_credit_limit_minor,
       case when v_hold then 'hold' else 'ok' end, v_hold,
       case when v_hold then v_reason end, v_reason, current_date, v_next);
  end if;

  select * into c from erp.credit_position(p_party_id);

  return jsonb_build_object(
    'party_id', p_party_id,
    'customer', v_name,
    'credit_limit_minor', p_credit_limit_minor,
    'on_hold', v_hold,
    'previous_credit_limit_minor', v_was_limit,
    'previously_on_hold', coalesce(v_was_hold, false),
    'exposure_minor', c.exposure_minor,
    'held', coalesce(c.on_hold, false),
    'position', c.reason);
end;
$$;

comment on function public.erp_set_credit_limit(uuid, bigint, boolean, text) is
  'Sets a customer''s credit limit (minor units; null is no limit) and whether '
  'their orders are on credit hold, with the reason, under sales.credit_release. '
  'Changes the trading terms in force, or gives the customer terms from today at '
  'the organisation''s first company. Returns the customer''s credit as it now '
  'stands (20260914074000).';

revoke all on function public.erp_set_credit_limit(uuid, bigint, boolean, text) from public, anon;
grant execute on function public.erp_set_credit_limit(uuid, bigint, boolean, text) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1d. A discount and a credit release are decided by the people who may
-- ═════════════════════════════════════════════════════════════════════════════

do $decide$
declare
  v_sig text := 'erp.decide_approval_task(uuid,boolean,text)';
  v_def text := pg_get_functiondef('erp.decide_approval_task(uuid,boolean,text)'::regprocedure);
  v_n   text := $n$  -- Whoever asked for a document's approval does not give it, once the
$n$;
  v_r   text := $r$  -- A sales order's discount and credit steps are decisions of their own
  -- (20260914074000): approving a discount above the threshold is for
  -- somebody who may approve discounts, and approving an order past its
  -- customer's credit limit for somebody who may release credit holds, as
  -- the sales installer has always described the two steps. Refusing either
  -- step stays open to whoever the task is assigned to: it sends the order back.
  if p_approve
     and v_task.step_code in ('discount', 'credit')
     and exists (select 1 from erp.approval_chain ac
                  where ac.tenant_id = v_tenant
                    and ac.id = v_req.approval_chain_id
                    and ac.code = 'sales_order_terms') then
    if v_task.step_code = 'discount' then
      perform erp.authorise('sales.discount_approve', v_req.entity_id, v_req.site_id, null,
                            'approval_task', p_task_id);
    else
      perform erp.authorise('sales.credit_release', v_req.entity_id, v_req.site_id, null,
                            'approval_task', p_task_id);
    end if;
  end if;

  -- Whoever asked for a document's approval does not give it, once the
$r$;
begin
  if position('sales.discount_approve' in v_def) > 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % already asks about discounts', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % does not refuse self-approval the way the 20260914062000 body does', v_sig
      using hint = 'A later migration changed how a task is decided. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('''sales.discount_approve''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: % was re-emitted without the discount permission', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$decide$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1e. Invoicing what you despatched is a governed exception
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The body is taken from the catalogue as 20260914070000 left it and changed
-- in three places; the signature gains the reason, so the function is created
-- again under it and the old one dropped.

do $invoice$
declare
  v_src text;
  v_n1  text := $n$  v_posted  boolean;
  v_despatcher uuid;
begin
$n$;
  v_r1  text := $r$  v_posted  boolean;
  v_despatcher uuid;
  v_self    boolean := false;
  v_self_reason text;
begin
$r$;
  v_n2  text := $n$  if v_despatcher = erp.current_principal_id() and not p_allow_self_invoice then
    raise exception
      'CLOVEERP_SEGREGATION_OF_DUTIES: you despatched % and cannot also invoice it',
      dn.document_number
      using errcode = '42501',
      hint = 'B1 has carried sales.despatch and sales.invoice as separate '
             'permissions since it was written; this is the first thing to '
             'require that they be held by different people.';
  end if;
$n$;
  v_r2  text := $r$  if v_despatcher = erp.current_principal_id() then
    if not coalesce(p_allow_self_invoice, false) then
      raise exception
        'CLOVEERP_SEGREGATION_OF_DUTIES: you despatched % and cannot also invoice it',
        dn.document_number
        using errcode = '42501',
              hint = 'Ask somebody who did not despatch these goods to invoice them. If nobody else can, somebody who may promote configuration can invoice them, giving the reason.';
    end if;

    -- Invoicing goods you despatched yourself is an exception to the
    -- separation of duties (20260914074000). Before go-live one person often
    -- does everything, and may, as before. Once live the exception needs its
    -- reason and somebody who may promote configuration, as any
    -- separation-of-duties exception does (20260914065000), and the invoice
    -- keeps who allowed it, when and why.
    v_self_reason := nullif(btrim(coalesce(p_self_invoice_reason, '')), '');
    if erp.tenant_is_live(v_tenant) then
      if coalesce(length(v_self_reason), 0) < 20 then
        raise exception 'CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT: invoicing % when you despatched it needs the reason in at least twenty characters', dn.document_number
          using errcode = '22023',
                hint = 'Say why nobody else can invoice goods you despatched, and what checks the invoice instead. The reason is kept on the invoice.';
      end if;
      perform erp.authorise('administration.promote', dn.entity_id, dn.site_id, null,
                            'document', p_delivery_id);
    end if;
    v_self := true;
  end if;
$r$;
  v_n3  text := $n$  v_inv := erp.open_document('sales_invoice', dn.party_id, dn.entity_id, dn.site_id);
$n$;
  v_r3  text := $r$  v_inv := erp.open_document('sales_invoice', dn.party_id, dn.entity_id, dn.site_id);

  if v_self then
    update erp.document
       set attributes = attributes || jsonb_build_object(
             'self_invoiced_by', erp.current_principal_id(),
             'self_invoiced_at', now(),
             'self_invoice_reason', v_self_reason),
           updated_at = now()
     where tenant_id = v_tenant and id = v_inv;
  end if;
$r$;
begin
  select p.prosrc into v_src
    from pg_catalog.pg_proc p
   where p.oid = 'erp.invoice_from_delivery(uuid,boolean)'::regprocedure;

  if (length(v_src) - length(replace(v_src, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_src) - length(replace(v_src, v_n2, ''))) / length(v_n2) <> 1
     or (length(v_src) - length(replace(v_src, v_n3, ''))) / length(v_n3) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.invoice_from_delivery(uuid,boolean) is not the body 20260914070000 left'
      using hint = 'A later migration changed how a delivery is invoiced. Read the function and patch that body.';
  end if;

  v_src := replace(replace(replace(v_src, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);

  drop function erp.invoice_from_delivery(uuid, boolean);

  execute 'create function erp.invoice_from_delivery('
       || 'p_delivery_id uuid, p_allow_self_invoice boolean default false, '
       || 'p_self_invoice_reason text default null) '
       || 'returns uuid language plpgsql volatile security invoker set search_path = '''' '
       || 'as $invoice_body$' || v_src || '$invoice_body$';

  if to_regprocedure('erp.invoice_from_delivery(uuid,boolean,text)') is null
     or position('erp.tenant_is_live(v_tenant)' in
                 (select p.prosrc from pg_catalog.pg_proc p
                   where p.oid = 'erp.invoice_from_delivery(uuid,boolean,text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.invoice_from_delivery was not created again with the exception'
      using hint = 'Compare the needles with the function 20260914070000 left.';
  end if;
end
$invoice$;

revoke all on function erp.invoice_from_delivery(uuid, boolean, text) from public, anon;

comment on function erp.invoice_from_delivery(uuid, boolean, text) is
  'Spec 5.6: invoicing derived from a validated delivery with role separation '
  'enforced. Built from what actually moved, and refused to the person whose '
  'name is on the movement unless p_allow_self_invoice asks for the exception: '
  'before go-live that is enough; once live it needs p_self_invoice_reason (20 '
  'characters) and administration.promote, and the invoice records who, when '
  'and why (20260914074000).';

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.invoice_from_delivery(uuid,boolean)',
                                            'erp.invoice_from_delivery(uuid,boolean,text)')
 where 'erp.invoice_from_delivery(uuid,boolean)' = any (artefacts);

drop function public.erp_invoice_from_delivery(uuid, boolean);

create function public.erp_invoice_from_delivery(
  p_delivery_id         uuid,
  p_allow_self_invoice  boolean default false,
  p_self_invoice_reason text    default null
) returns uuid
language sql
volatile
security invoker
set search_path = ''
as $$
  select erp.invoice_from_delivery(p_delivery_id, p_allow_self_invoice, p_self_invoice_reason)
$$;

comment on function public.erp_invoice_from_delivery(uuid, boolean, text) is
  'Invoices a posted delivery under sales.invoice. The person who despatched it '
  'is refused unless p_allow_self_invoice asks for the exception; once the '
  'organisation is live that needs p_self_invoice_reason and administration.promote '
  '(20260914074000).';

revoke all on function public.erp_invoice_from_delivery(uuid, boolean, text) from public, anon;
grant execute on function public.erp_invoice_from_delivery(uuid, boolean, text) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Allocations are listed
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_allocations(
  p_order_id uuid    default null,
  p_status   text    default null,
  p_limit    integer default 200
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  perform erp.authorise('sales.read', null, null, null, 'allocation', p_order_id);
  v_tenant := erp.require_tenant_id();

  return coalesce((
    select jsonb_agg(x.item_json order by x.required_by nulls last, x.document_number nulls last,
                                          x.line_no nulls last, x.created_at)
      from (
        select jsonb_build_object(
                 'allocation_id', al.id,
                 'status', al.status,
                 'document_id', al.document_id,
                 'document_number', d.document_number,
                 'document_line_id', al.document_line_id,
                 'line_no', dl.line_no,
                 'customer', coalesce(nullif(btrim(pa.name), ''), pa.code),
                 'item', i.code,
                 'item_name', i.name,
                 'quantity', al.quantity,
                 'unmet_quantity', al.unmet_quantity,
                 'unmet_cause', al.unmet_cause,
                 'site', s.code,
                 'required_by', al.required_by) as item_json,
               al.required_by, d.document_number, dl.line_no, al.created_at
          from erp.allocation al
          join erp.item i on i.tenant_id = al.tenant_id and i.id = al.item_id
          join erp.site s on s.tenant_id = al.tenant_id and s.id = al.site_id
          left join erp.document d on d.tenant_id = al.tenant_id and d.id = al.document_id
          left join erp.document_line dl on dl.tenant_id = al.tenant_id and dl.id = al.document_line_id
          left join erp.party pa on pa.tenant_id = al.tenant_id and pa.id = d.party_id
         where al.tenant_id = v_tenant
           and (p_order_id is null or al.document_id = p_order_id)
           and (p_status is null or al.status::text = p_status)
         order by al.required_by nulls last, d.document_number nulls last, dl.line_no nulls last, al.created_at
         limit greatest(coalesce(p_limit, 200), 1)) x), '[]'::jsonb);
end;
$$;

comment on function public.erp_allocations(uuid, text, integer) is
  'Under sales.read: the organisation''s allocations, or one order''s, optionally '
  'in one status (reserved, committed, picked, released, cancelled, consumed), '
  'each with its order, line, customer, product, quantity, shortfall, site and '
  'date. Volatile because erp.authorise() records the access decision '
  '(20260914074000).';

revoke all on function public.erp_allocations(uuid, text, integer) from public, anon;
grant execute on function public.erp_allocations(uuid, text, integer) to authenticated, service_role;

update erp_ref.part5_capability
   set artefacts = artefacts || array['public.erp_allocations(uuid,text,integer)']
 where code = '5.6.allocation'
   and not ('public.erp_allocations(uuid,text,integer)' = any (artefacts));

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Nobody is left unable to manage people
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.user_managers_before_change(p_tenant uuid)
returns integer
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  -- The lock removing a person takes: removals and role changes in one
  -- organisation queue behind each other, so two people cannot each take the
  -- other's access at the same moment and leave nobody.
  perform pg_advisory_xact_lock(hashtext('erp.remove_principal ' || p_tenant::text));
  return erp.user_managers_remaining(p_tenant, null);
end;
$$;
revoke all on function erp.user_managers_before_change(uuid) from public, anon, authenticated;

comment on function erp.user_managers_before_change(uuid) is
  'Before a change that could take administration.users from somebody: takes the '
  'organisation''s access lock, as erp.remove_principal() does, and returns how '
  'many active people manage users now (20260914074000).';

create or replace function erp.require_user_managers_remain(p_tenant uuid, p_before integer, p_change text)
returns void
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  if coalesce(p_before, 0) > 0 and erp.user_managers_remaining(p_tenant, null) = 0 then
    raise exception 'CLOVEERP_LAST_USER_MANAGER: % would leave nobody here who can manage users', coalesce(p_change, 'This change')
      using errcode = '23514',
            hint = 'Give somebody else a role that lets them invite and remove people first, then make this change.';
  end if;
end;
$$;
revoke all on function erp.require_user_managers_remain(uuid, integer, text) from public, anon, authenticated;

comment on function erp.require_user_managers_remain(uuid, integer, text) is
  'After a change: refuses CLOVEERP_LAST_USER_MANAGER when somebody managed users '
  'before it (p_before, from erp.user_managers_before_change) and nobody does now. '
  'Volatile, so it counts what the change already wrote (20260914074000).';

-- Same signature and return type as 20260914065000, so the grants stay.
create or replace function public.erp_set_user_roles(
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
  v_tenant   uuid := erp.require_tenant_id();
  v_codes    text[] := coalesce(p_role_codes, '{}');
  v_to_end   uuid[];
  v_to_add   text[];
  v_before   uuid[];
  v_change   text;
  v_added    integer := 0;
  v_ended    integer := 0;
  v_grant    uuid;
  v_managers integer;
  v_person   text;
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

  -- Who manages users before the change, under the lock removals take
  -- (20260914074000).
  v_managers := erp.user_managers_before_change(v_tenant);

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

  -- A grant that ended may have been the last one letting anybody manage
  -- users (20260914074000).
  if v_ended > 0 then
    select coalesce(nullif(btrim(u.display_name), ''), u.email, 'this person')
      into v_person
      from erp.app_user u
     where u.tenant_id = v_tenant and u.id = p_app_user_id;
    perform erp.require_user_managers_remain(v_tenant, v_managers,
                                             format('Taking these roles from %s', v_person));
  end if;

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
  'ticked ones are granted. Refuses your own roles once live, and a change that '
  'would leave nobody able to manage users (20260914074000). In a live '
  'organisation a prohibited segregation-of-duties pairing the change introduces '
  'is refused unless p_sod_override_reason records an exception, which needs '
  'administration.promote. Returns granted, revoked and the person''s conflicts.';

-- Same signature and return type as 20260914065000, so the grants stay.
create or replace function public.erp_revoke_role(p_user_role_id uuid)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_person   uuid;
  v_before   uuid[];
  v_outcome  text;
  v_managers integer;
  v_name     text;
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

  v_managers := erp.user_managers_before_change(v_tenant);
  v_before := array(select d.sod_rule_id from erp.duty_conflicts(v_tenant, v_person) d);
  v_outcome := erp.end_grant(v_tenant, p_user_role_id);

  -- The grant may have been the last one letting anybody manage users
  -- (20260914074000).
  select coalesce(nullif(btrim(u.display_name), ''), u.email, 'this person')
    into v_name
    from erp.app_user u
   where u.tenant_id = v_tenant and u.id = v_person;
  perform erp.require_user_managers_remain(v_tenant, v_managers,
                                           format('Ending this grant of %s', v_name));

  return jsonb_build_object(
    'revoked', p_user_role_id,
    'outcome', v_outcome,
    'conflicts', erp.settle_duties(v_tenant, v_person, v_before, null, null, 'grant'));
end;
$$;

comment on function public.erp_revoke_role(uuid) is
  'Ends one grant under administration.roles: begun before today it ends '
  'yesterday and stays on file, begun today or later it is withdrawn. Refuses '
  'your own grants once live, and the last grant letting anybody manage users '
  '(20260914074000). Returns revoked, outcome (ended, withdrawn or already_ended) '
  'and the person''s conflicts as they stand.';

-- Same signature and return type as 20260914065000, so the grants stay.
create or replace function public.erp_save_role(p_role_id uuid, p_code text, p_name text, p_description text, p_permissions text[])
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid;
  v_id       uuid;
  v_before   jsonb;
  v_managers integer;
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

    v_managers := erp.user_managers_before_change(v_tenant);

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

  -- An edited role may no longer let anybody manage users (20260914074000).
  if p_role_id is not null then
    perform erp.require_user_managers_remain(v_tenant, v_managers,
                                             format('Changing the %s role', p_name));
  end if;

  perform erp.settle_role_duties(v_tenant, coalesce(v_before, '{}'::jsonb), p_name, 'role');

  return jsonb_build_object('role_id', v_id);
end;
$$;

-- The promoter's role arm, by counted replacement around the text
-- 20260914065000 left: a role taken out of use and a role whose permissions
-- change are both refused when they would leave nobody able to manage users. A
-- rollback is recognised by the promoter's own call stack, as 065000 does.
do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := $n$      if i.operation = 'remove' then
        update erp.role r set status = 'inactive', updated_at = now()
         where r.tenant_id = v_tenant and r.code = (p ->> 'code');
      else
        declare
          v_duties_before jsonb := erp.role_duties_before(v_tenant, p ->> 'code');
          v_duties_stack  text;
        begin
$n$;
  v_r1  text := $r$      if i.operation = 'remove' then
        -- A role taken out of use takes what it granted from everybody holding
        -- it, and nobody is left unable to manage users (20260914074000).
        declare
          v_managers_before integer := erp.user_managers_before_change(v_tenant);
          v_managers_stack  text;
        begin
          update erp.role r set status = 'inactive', updated_at = now()
           where r.tenant_id = v_tenant and r.code = (p ->> 'code');
          get diagnostics v_managers_stack = pg_context;
          if position('function erp.' || 'rollback_to_snapshot(' in v_managers_stack) = 0 then
            perform erp.require_user_managers_remain(v_tenant, v_managers_before,
              format('Taking the %s role out of use', p ->> 'code'));
          end if;
        end;
      else
        declare
          v_duties_before jsonb := erp.role_duties_before(v_tenant, p ->> 'code');
          v_duties_stack  text;
          v_managers_before integer := erp.user_managers_before_change(v_tenant);
        begin
$r$;
  v_n2  text := $n$               then 'review' else 'role' end);
        end;
$n$;
  v_r2  text := $r$               then 'review' else 'role' end);

        -- Nor is anybody left unable to manage users (20260914074000). A
        -- rollback restores what was there and is not held up.
        if position('function erp.' || 'rollback_to_snapshot(' in v_duties_stack) = 0 then
          perform erp.require_user_managers_remain(v_tenant, v_managers_before,
            format('Changing the %s role',
                   coalesce((select coalesce(nullif(btrim(ro.name), ''), ro.code)
                               from erp.role ro where ro.tenant_id = v_tenant and ro.id = v_obj),
                            p ->> 'code')));
        end if;
        end;
$r$;
begin
  if position('erp.require_user_managers_remain(' in v_def) > 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm already keeps somebody able to manage users';
  end if;
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm of erp.apply_change_set_item() is not the text 20260914065000 left'
      using hint = 'A later migration changed the role arm. Read pg_get_functiondef() of the promoter and patch that body.';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  if (length(pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure))
      - length(replace(pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure),
                       'perform erp.require_user_managers_remain(', '')))
     / length('perform erp.require_user_managers_remain(') <> 2 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the role arm did not take both refusals'
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the promoter.';
  end if;
end
$promoter$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Stock identity is pinned to lines that can still ship
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260906090000, so the grants stay.
create or replace function erp.set_line_stock_identity(
  p_line_id uuid, p_batch_id uuid default null, p_location_id uuid default null, p_container_id uuid default null)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  l        erp.document_line%rowtype;
  d        erp.document%rowtype;
  dt       erp.document_type%rowtype;
  bt       erp_ref.document_type%rowtype;
begin
  select * into l from erp.document_line where tenant_id = v_tenant and id = p_line_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LINE: %', p_line_id using errcode = '23503';
  end if;
  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;
  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  select * into bt from erp_ref.document_type where code = dt.base_type_code;
  perform erp.authorise(coalesce(dt.create_permission, bt.create_permission),
                        d.entity_id, d.site_id, null, 'document', d.id);

  -- A cancelled or finished document, or a cancelled line, ships nothing more
  -- (20260914074000). A cancelled draft is finished without ever committing,
  -- which is why the committed refusal below did not catch it.
  if coalesce(l.is_cancelled, false)
     or d.is_cancelled
     or exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
                 where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = d.id
                   and (s.is_terminal or s.code = 'cancelled')) then
    raise exception 'CLOVEERP_DOCUMENT_FINISHED: % is finished or the line is cancelled, so no stock is pinned to it', d.document_number
      using errcode = '23514',
            hint = 'Choose a line of an order that is still being prepared.';
  end if;

  if exists (select 1 from erp.object_state os join erp.state s on s.id = os.current_state_id
              where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = d.id and s.is_committed) then
    raise exception 'CLOVEERP_DOCUMENT_COMMITTED: % has committed; its lines say where the stock went', d.document_number
      using errcode = '23514',
            hint = 'Pin stock to a line before the order is confirmed. Once it is, reserving and picking say where its stock comes from.';
  end if;
  if p_batch_id is not null and not exists (
       select 1 from erp.batch b where b.tenant_id = v_tenant and b.id = p_batch_id and b.item_id = l.item_id) then
    raise exception 'CLOVEERP_BATCH_ITEM_MISMATCH: the batch is not a batch of the line''s item'
      using errcode = '23514', hint = 'Create a batch of this item (erp_create_batch) and name that.';
  end if;
  if p_location_id is not null and not exists (
       select 1 from erp.location loc where loc.tenant_id = v_tenant and loc.id = p_location_id and loc.site_id = d.site_id) then
    raise exception 'CLOVEERP_LOCATION_NOT_AT_SITE: the location is not at the document''s site'
      using errcode = '23514';
  end if;
  if p_container_id is not null and not exists (
       select 1 from erp.container c where c.tenant_id = v_tenant and c.id = p_container_id and c.site_id = d.site_id) then
    raise exception 'CLOVEERP_CONTAINER_NOT_AT_SITE: the handling unit is not at the document''s site'
      using errcode = '23514', hint = 'Build the unit at this site (erp_create_handling_unit) or name one that stands here.';
  end if;

  update erp.document_line
     set batch_id     = coalesce(p_batch_id, batch_id),
         location_id  = coalesce(p_location_id, location_id),
         container_id = coalesce(p_container_id, container_id),
         updated_at   = now()
   where id = p_line_id;
end;
$$;
revoke all on function erp.set_line_stock_identity(uuid, uuid, uuid, uuid) from public, anon, authenticated;

comment on function erp.set_line_stock_identity(uuid, uuid, uuid, uuid) is
  'Names the batch, location and handling unit a document line''s stock is in, '
  'under the document type''s create permission. Refuses a line of a cancelled '
  'or finished document or a cancelled line (CLOVEERP_DOCUMENT_FINISHED, '
  '20260914074000), and a line of a committed document.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Demonstration configuration is for platform staff
-- ═════════════════════════════════════════════════════════════════════════════

do $seed$
declare
  v_sig text := 'public.erp_seed_demo_configuration()';
  v_def text := pg_get_functiondef('public.erp_seed_demo_configuration()'::regprocedure);
  v_n   text := $n$begin
  -- §22.3: the demo seed is refused in a live environment by the platform.
$n$;
  v_r   text := $r$begin
  -- While self-service sign-up is closed demonstration data is for platform
  -- staff, as the other demonstration doors are (20260914030000,
  -- 20260914074000). Asked first, in the frame of the caller.
  perform erp.require_demo_for_platform_staff();

  -- §22.3: the demo seed is refused in a live environment by the platform.
$r$;
begin
  if position('require_demo_for_platform_staff' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % already asks whether its caller may seed a demo', v_sig;
  end if;
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not begin the way the 20260904500000 body does', v_sig
      using hint = 'A later migration changed the door. Read its definition and patch that body.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('perform erp.require_demo_for_platform_staff();' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its refusal', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the door.';
  end if;
end
$seed$;

comment on function public.erp_seed_demo_configuration() is
  'Writes sample classification axes and values, a code template, supplier '
  'defaults and a release area into the organisation in context, under '
  'administration.configure, never in a live environment, and, while '
  'self-service sign-up is closed, only for platform operators and owners '
  '(20260914074000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Registers, refusals and the words on the screens
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_credit_limit', 'erp.authorise',
   'Sets a customer''s credit limit and credit hold, with the reason, under sales.credit_release: changes the trading terms in force, or gives the customer terms from today (20260914074000).'),
  ('erp_allocations', 'erp.authorise',
   'A read of the organisation''s allocations under sales.read. Volatile because erp.authorise() records the access decision; writes nothing else (20260914074000).')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

do $register$
declare
  v_n integer;
begin
  with truth (function_name, rationale) as (values
    ('erp_invoice_from_delivery',
     'Invoices a posted delivery under sales.invoice, from what moved. The person who despatched it is refused unless they ask for the exception; once live that needs a reason and administration.promote, and the invoice records it (20260914074000).'),
    ('erp_decide_approval',
     'Decides an approval task assigned to the caller: erp.decide_approval_task() refuses anybody else. Approving the discount step of a sales order''s terms also needs sales.discount_approve, and its credit step sales.credit_release (20260914074000).'),
    ('erp_seed_demo_configuration',
     'Writes demonstration configuration into the organisation in context under administration.configure, never in a live environment. erp.require_demo_for_platform_staff() comes first: while self-service sign-up is closed only trusted sessions and platform operators and owners pass (20260914074000).'),
    ('erp_set_line_stock_identity',
     'Names the batch, location and handling unit a line''s stock is in, under the document type''s create permission; refuses a line of a finished or committed document (20260914074000).'),
    ('erp_pick_document',
     'Reserves and picks a sales order in one press. Gated on sales.despatch inside erp.pick_document(); each reservation it makes is authorised again, and an order over its customer''s credit is refused until released (20260914074000).'),
    ('erp_commit_allocation',
     'Commits a reservation to stock under sales.despatch inside erp.commit_allocation(); an order over its customer''s credit is refused until released (20260914074000).')
  ), updated as (
    update erp_meta.public_write_allowance w
       set rationale = t.rationale, ungated_because = null
      from truth t
     where w.function_name = t.function_name
    returning 1
  )
  select count(*) into v_n from updated;

  if v_n <> 6 then
    raise exception 'CLOVEERP_REGISTER_INCOMPLETE: % of 6 register rows were found to reword', v_n
      using hint = 'Each door must have a row in erp_meta.public_write_allowance; if row security refused the update, the migration role has lost its bypass.';
  end if;
end
$register$;

select erp_meta.add_help_actions('/sales', array['erp_set_credit_limit']);
select erp_meta.add_help_actions('/inventory', array['erp_allocations']);

select erp.register_refusal('CLOVEERP_CREDIT_HOLD',
  'Picking or delivering a sales order while its customer is over their credit limit, on credit hold, or overdue.',
  'Goods that leave on credit the customer has not got are money the organisation may never see, so the order waits until somebody who may release credit decides.',
  'Release the order with Release a credit hold on the Sales screen, giving the reason, or change the customer''s credit limit. Then pick or deliver it.');

select erp.register_refusal('CLOVEERP_NOT_A_CUSTOMER',
  'Setting credit for a business partner who is not a customer.',
  'Credit is what a customer may owe, and it is kept with their customer terms.',
  'Choose a customer, or make the business partner a customer first.');

select erp.register_refusal('CLOVEERP_CREDIT_LIMIT_NEGATIVE',
  'Setting a credit limit below nought.',
  'A credit limit is the most a customer may owe, and nobody can owe less than nothing.',
  'Enter nought or more, or leave the limit empty for no limit. To stop a customer''s orders, put them on credit hold instead.');

select erp.register_refusal('CLOVEERP_CREDIT_CHANGE_NEEDS_REASON',
  'Changing a customer''s credit limit or credit hold without saying why.',
  'Whoever reviews what a customer was allowed to owe reads the reason later, and a change with none explains nothing.',
  'Say why the limit or the hold is changing. The reason is kept with the customer''s terms.');

select erp.register_refusal('CLOVEERP_SEGREGATION_OF_DUTIES',
  'Doing the second half of a job you did the first half of, such as invoicing goods you despatched or approving a payment run you proposed.',
  'The two halves of one job are kept apart so that a second person sees each of them, and nothing is despatched and billed, or proposed and paid, by one person alone.',
  'Ask somebody else who may do the second half. If nobody else can invoice goods you despatched, somebody who may promote configuration can invoice them, giving the reason.');

select erp.register_refusal('CLOVEERP_LAST_USER_MANAGER',
  'Taking away the access or the roles of the last people who can invite and remove people in the organisation.',
  'Somebody must always be able to manage the organisation''s people, or nobody inside it could invite a colleague, give roles or restore access again.',
  'Give somebody else a role that lets them manage people first, then make the change.');

select erp.register_refusal('CLOVEERP_DOCUMENT_FINISHED',
  'Pinning stock to a line of an order that is finished, or to a line that was cancelled.',
  'A finished order''s lines already say where its stock went, and a cancelled line ships nothing.',
  'Choose a line of an order that is still being prepared.');

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('Set a customer''s credit limit',
     'Sales: the action that sets a customer''s credit limit and hold (20260914074000).'),
    ('The most this customer may owe across open orders and unpaid invoices, and whether their orders are held. An order over the limit, or for a customer on hold, is not picked or delivered until somebody releases it.',
     'Sales: what setting a customer''s credit does (20260914074000).'),
    ('Credit limit',
     'Sales: the credit limit field, in the organisation''s money (20260914074000).'),
    ('In pounds. Leave empty for no limit.',
     'Sales: the credit limit field''s hint (20260914074000).'),
    ('Hold this customer''s orders',
     'Sales: whether a customer is on credit hold (20260914074000).'),
    ('Yes holds every order for this customer until the hold is lifted here. No lifts a hold.',
     'Sales: the credit hold field''s hint (20260914074000).'),
    ('Why the limit or the hold is changing. Kept with the customer''s terms.',
     'Sales: the reason field when credit is set (20260914074000).'),
    ('Reservation',
     'Stock: the reservation a sales order line holds, chosen to commit (20260914074000).'),
    ('A sales order line''s reservation not yet picked. Leave location and batch empty to let the policy choose.',
     'Stock: the hint for choosing a reservation to commit (20260914074000).'),
    ('Only when you despatched these goods yourself and nobody else can invoice them. Once the organisation is live it needs a reason.',
     'Finance: the hint for invoicing your own delivery (20260914074000).'),
    ('Reason for invoicing your own delivery',
     'Finance: the reason kept on an invoice raised by the person who despatched the goods (20260914074000).'),
    ('Why nobody else can invoice these goods, and what checks the invoice instead. At least twenty characters once the organisation is live; kept on the invoice.',
     'Finance: the hint for the reason to invoice your own delivery (20260914074000).'),
    ('Confirmed sales order',
     'Sales: the order a credit hold is released for (20260914074000).')
) as v(text, why)
on conflict (key, locale) do nothing;

-- A row that did not land is a string the terminology screen cannot offer.
do $words$
declare v_missing text;
begin
  select string_agg(quote_literal(t.text), ', ' order by t.text) into v_missing
    from (values
      ('Set a customer''s credit limit'),
      ('Credit limit'),
      ('In pounds. Leave empty for no limit.'),
      ('Hold this customer''s orders'),
      ('Reservation'),
      ('Reason for invoicing your own delivery'),
      ('Confirmed sales order')
    ) as t(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(t.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_STRINGS_SHORT: no resource row for %', v_missing
      using hint = 'Row security refused the write, or erp_ref.ui_key changed. Seed the row the desk asks for.';
  end if;
end
$words$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A live organisation with two administrators: the first sells and asks for
-- approvals, the second approves and promotes. Finance, procurement and sales
-- are installed through changes the second promotes, and a hundred widgets are
-- received. Narrow roles are made with the organisation's window opened for the
-- purpose: a credit controller, an order clerk, a despatch clerk who also
-- invoices, a delegate, a role keeper, and the permissions a delegate is given
-- on the way. A platform operator is also an administrator here. Every door
-- whose refusal is proven is called as a signed-in caller through
-- erp_test.last_open_items_door_as(). Everything is built inside a block that
-- ends by raising, so nothing outlives the suite.

create or replace function erp_test.last_open_items_door_as(
  p_subject uuid,
  p_door    text,
  p_args    jsonb default '{}'::jsonb
) returns table (outcome jsonb, err_state text, err_message text, err_hint text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_owner  text := current_user;
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  a        jsonb := coalesce(p_args, '{}'::jsonb);
begin
  if p_door not in ('erp_set_credit_limit', 'erp_allocations', 'erp_pick_document',
                    'erp_commit_allocation', 'erp_create_delivery_from_order',
                    'erp_release_credit_hold', 'erp_invoice_from_delivery', 'erp_decide_approval',
                    'erp_set_user_roles', 'erp_revoke_role', 'erp_set_line_stock_identity',
                    'erp_seed_demo_configuration') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a door erp_test.last_open_items_suite calls', p_door
      using hint = 'Call one of the twelve doors the helper names.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_subject, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    case p_door
      when 'erp_set_credit_limit' then
        outcome := public.erp_set_credit_limit(
          p_party_id           => (a ->> 'party_id')::uuid,
          p_credit_limit_minor => (a ->> 'limit')::bigint,
          p_on_hold            => coalesce((a ->> 'on_hold')::boolean, false),
          p_reason             => a ->> 'reason');
      when 'erp_allocations' then
        outcome := public.erp_allocations(
          p_order_id => (a ->> 'order_id')::uuid,
          p_status   => a ->> 'status');
      when 'erp_pick_document' then
        outcome := public.erp_pick_document(p_document_id => (a ->> 'document_id')::uuid);
      when 'erp_commit_allocation' then
        outcome := to_jsonb(public.erp_commit_allocation(p_allocation_id => (a ->> 'allocation_id')::uuid));
      when 'erp_create_delivery_from_order' then
        outcome := public.erp_create_delivery_from_order(
          p_order_id   => (a ->> 'order_id')::uuid,
          p_transition => a ->> 'transition');
      when 'erp_release_credit_hold' then
        perform public.erp_release_credit_hold((a ->> 'document_id')::uuid, a ->> 'reason');
        outcome := jsonb_build_object('released', true);
      when 'erp_invoice_from_delivery' then
        outcome := to_jsonb(public.erp_invoice_from_delivery(
          p_delivery_id         => (a ->> 'delivery_id')::uuid,
          p_allow_self_invoice  => coalesce((a ->> 'allow')::boolean, false),
          p_self_invoice_reason => a ->> 'reason'));
      when 'erp_decide_approval' then
        outcome := public.erp_decide_approval((a ->> 'task_id')::uuid, (a ->> 'approve')::boolean,
                                              'the last open items suite');
      when 'erp_set_user_roles' then
        outcome := public.erp_set_user_roles(
          p_app_user_id => (a ->> 'person')::uuid,
          p_role_codes  => array(select jsonb_array_elements_text(coalesce(a -> 'roles', '[]'::jsonb))),
          p_reason      => 'the last open items suite');
      when 'erp_revoke_role' then
        outcome := public.erp_revoke_role((a ->> 'grant_id')::uuid);
      when 'erp_set_line_stock_identity' then
        outcome := public.erp_set_line_stock_identity(
          p_line_id     => (a ->> 'line_id')::uuid,
          p_location_id => (a ->> 'location_id')::uuid);
      else
        outcome := public.erp_seed_demo_configuration();
    end case;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text,
                            err_hint = pg_exception_hint;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', v_claims, true);
  return next;
end;
$$;
revoke all on function erp_test.last_open_items_door_as(uuid, text, jsonb) from public, anon, authenticated;

comment on function erp_test.last_open_items_door_as(uuid, text, jsonb) is
  'Suite helper: calls one of the doors erp_test.last_open_items_suite proves as '
  'the given sign-in, in the authenticated role, with its arguments read from '
  'p_args, and returns its answer or its refusal with the hint. Returns to the '
  'calling role and claims before it returns.';

create or replace function erp_test.last_open_items_task(p_tenant uuid, p_document_id uuid, p_assignee uuid)
returns table (task_id uuid, step_code text)
language sql
stable
set search_path = ''
as $$
  select t.id, t.step_code
    from erp.approval_task t
    join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
   where t.tenant_id = p_tenant
     and q.object_type = 'document'
     and q.object_id = p_document_id
     and q.status = 'pending'
     and t.status = 'pending'
     and t.assignee_user_id = p_assignee
   order by t.seq, t.created_at, t.id
   limit 1
$$;
revoke all on function erp_test.last_open_items_task(uuid, uuid, uuid) from public, anon, authenticated;

comment on function erp_test.last_open_items_task(uuid, uuid, uuid) is
  'Suite helper: the first pending approval task on a document assigned to one person.';

create or replace function erp_test.last_open_items_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- the first administrator, who sells and asks
  a2       uuid := gen_random_uuid();   -- the second, who approves and promotes
  s_credit uuid := gen_random_uuid();   -- sets credit and releases holds
  s_clerk  uuid := gen_random_uuid();   -- takes orders, and may not set credit
  s_desp   uuid := gen_random_uuid();   -- picks, despatches and invoices, and may not promote
  s_deleg  uuid := gen_random_uuid();   -- decides the approvals delegated to them
  s_keeper uuid := gen_random_uuid();   -- gives roles, and neither manages people nor reads sales
  s_oper   uuid := gen_random_uuid();   -- a platform operator, and an administrator here
  c_reason constant text := 'The second clerk is on leave this week; the partner reviews the invoice.';
  r        record;
  g        record;
  v_step   text := 'reading the doors';
  v_state  text;
  -- The doors as the catalogue holds them.
  v_cl_n integer; v_cl_args text; v_cl_def boolean; v_cl_vol boolean; v_cl_grant boolean; v_cl_gate text;
  v_al_n integer; v_al_args text; v_al_def boolean; v_al_vol boolean; v_al_grant boolean; v_al_gate text;
  v_in_n integer; v_in_args text; v_in_erp_n integer; v_in_erp_args text;
  v_decide_ungated text;
  -- The organisation.
  v_admin uuid; v_second uuid; v_tok text; cs_fin uuid; cs_proc uuid; cs_sales uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid; v_c1 uuid; v_c2 uuid; v_item uuid; v_grn uuid;
  u_credit uuid; u_clerk uuid; u_desp uuid; u_deleg uuid; u_keeper uuid; u_oper uuid;
  -- Orders.
  v_so_a uuid; v_so_a_line uuid; v_so_b uuid; v_so_c uuid; v_so_d uuid; v_so_f uuid;
  v_so_x uuid; v_so_x_line uuid; v_so_y uuid; v_so_y_line uuid;
  v_alloc_a uuid;
  -- 1a, 1b.
  v_set1 jsonb; v_set1_err text;
  v_terms_rows integer; v_pos_limit bigint; v_ctx_c1 text; v_ctx_c2 text; v_so_a_credit_step text;
  v_ref_perm jsonb; v_ref_cust jsonb; v_ref_neg jsonb; v_ref_reason jsonb; v_limit_after_refusals bigint;
  -- 1c.
  v_held_a boolean;
  v_allocs jsonb; v_allocs_err text; v_allocs_denied jsonb;
  v_pick_a jsonb; v_alloc_a_after text;
  v_commit_a jsonb;
  v_dn_refused jsonb; v_dn_none boolean;
  v_release_err text; v_release_says text; v_pick_a2 jsonb; v_pick_a2_err text; v_dn_a uuid; v_dn_a_state text;
  v_set_hold jsonb; v_hold_limit bigint; v_hold_blocked boolean; v_hold_block_reason text;
  v_hold_status text; v_hold_credit_reason text; v_hold_rows integer; v_pick_b jsonb;
  v_set_clear jsonb; v_pick_b2 jsonb; v_pick_b2_err text; v_dn_b uuid;
  -- 1d.
  v_delegation uuid; v_task record;
  v_f1 jsonb; v_f2 jsonb; v_f2_step text; v_f_status text;
  v_d1 jsonb; v_d_disc jsonb; v_d_disc_step text; v_d_disc_pending boolean; v_d_disc_ok jsonb;
  v_d_credit jsonb; v_d_credit_step text; v_d_credit_ok jsonb; v_d_status text;
  -- 1e.
  v_si1 jsonb; v_si2 jsonb; v_si3 jsonb; v_si_none boolean;
  v_dn_c uuid; v_si4 jsonb; v_si5 jsonb; v_si5_attrs jsonb;
  v_si6 jsonb; v_si6_err text; v_si6_attrs jsonb; v_live_after boolean;
  -- 4.
  v_pin_x jsonb; v_pin_a jsonb; v_pin_y jsonb; v_pinned boolean;
  v_lines jsonb; v_offers_y boolean; v_offers_x boolean; v_offers_a boolean;
  -- 5.
  v_demo_admin jsonb; v_demo_oper jsonb; v_demo_axes integer;
  -- 3.
  v_cs uuid; v_promote_msg text; v_admin_keeps boolean; v_cs_status text;
  v_edit_second jsonb; v_edit_oper jsonb; v_managers_left integer;
  v_edit_last jsonb; v_last_grant uuid; v_revoke_last jsonb; v_last_keeps boolean; v_last_grant_open boolean;
begin
  -- ── The doors as the catalogue holds them ────────────────────────────────
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)), coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 'v'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_cl_n, v_cl_args, v_cl_def, v_cl_vol, v_cl_grant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_set_credit_limit';
  select w.gate into v_cl_gate from erp_meta.public_write_allowance w where w.function_name = 'erp_set_credit_limit';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid)), coalesce(bool_or(p.prosecdef), true),
         coalesce(bool_and(p.provolatile = 'v'), false),
         coalesce(bool_and(pg_catalog.has_function_privilege('authenticated', p.oid, 'execute')
                           and not pg_catalog.has_function_privilege('anon', p.oid, 'execute')), false)
    into v_al_n, v_al_args, v_al_def, v_al_vol, v_al_grant
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_allocations';
  select w.gate into v_al_gate from erp_meta.public_write_allowance w where w.function_name = 'erp_allocations';

  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid))
    into v_in_n, v_in_args
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_invoice_from_delivery';
  select count(*), min(pg_catalog.pg_get_function_identity_arguments(p.oid))
    into v_in_erp_n, v_in_erp_args
    from pg_catalog.pg_proc p
   where p.pronamespace = 'erp'::regnamespace and p.proname = 'invoice_from_delivery';
  select coalesce(w.ungated_because, 'none') into v_decide_ungated
    from erp_meta.public_write_allowance w where w.function_name = 'erp_decide_approval';

  begin
    -- ── A live organisation and its two administrators ─────────────────────
    v_step := 'the organisation is provisioned and its two administrators join';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zz-loi-' || v_hex, 'Last open items suite',
      'admin@zz-loi-' || v_hex || '.test', 'First Admin');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    v_admin := r.admin_user_id;
    select i.app_user_id, i.token into v_second, v_tok
      from erp.invite_principal('second@zz-loi-' || v_hex || '.test', 'Second Admin') i;
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_step := 'finance, procurement and sales are installed, and the second administrator promotes them';
    cs_fin := erp.configure_finance();
    cs_proc := erp.configure_procurement(1000000);
    cs_sales := erp.configure_sales(15);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);
    perform erp.approve_change_set(cs_sales);
    perform erp.promote_change_set(cs_sales);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'a site, a supplier, two customers and a product, and a hundred widgets received';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    -- The first customer's role still carries a limit of a million; its terms
    -- will say otherwise. The second has no terms at all.
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'C1', 'Credit Customer', 'active') returning id into v_c1;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_c1, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'C2', 'Cash Customer', 'active') returning id into v_c2;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_c2, 'customer', jsonb_build_object('credit_limit_minor', 10000000), 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'WID', 'Widget', v_uom, 'active') returning id into v_item;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_item, 100, 1000, 'the stock');
    perform erp.transition_document(v_grn, 'post', 'last open items suite');

    v_step := 'the narrow roles are made while the organisation is opened for it';
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status) values
      (r.tenant_id, 'zz_credit_controller', 'Suite credit controller', 'active'),
      (r.tenant_id, 'zz_order_clerk', 'Suite order clerk', 'active'),
      (r.tenant_id, 'zz_despatch_clerk', 'Suite despatch clerk', 'active'),
      (r.tenant_id, 'zz_delegate', 'Suite delegate', 'active'),
      (r.tenant_id, 'zz_discount_approver', 'Suite discount approver', 'active'),
      (r.tenant_id, 'zz_credit_approver', 'Suite credit approver', 'active'),
      (r.tenant_id, 'zz_role_keeper', 'Suite role keeper', 'active'),
      (r.tenant_id, 'zz_viewer', 'Suite viewer', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select r.tenant_id, ro.id, x.perm
      from (values ('zz_credit_controller', 'sales.read'), ('zz_credit_controller', 'sales.credit_release'),
                   ('zz_order_clerk', 'sales.read'), ('zz_order_clerk', 'sales.order'),
                   ('zz_despatch_clerk', 'sales.read'), ('zz_despatch_clerk', 'sales.despatch'),
                   ('zz_despatch_clerk', 'sales.invoice'), ('zz_despatch_clerk', 'inventory.read'),
                   ('zz_despatch_clerk', 'inventory.move'),
                   ('zz_delegate', 'sales.read'),
                   ('zz_discount_approver', 'sales.discount_approve'),
                   ('zz_credit_approver', 'sales.credit_release'),
                   ('zz_role_keeper', 'administration.read'), ('zz_role_keeper', 'administration.roles'),
                   ('zz_viewer', 'reporting.read')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;
    perform erp_test.close_bootstrap_window(r.tenant_id);

    v_step := 'the people';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_credit, 'person', 'active', 'Cara Credit', 'cara@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_credit;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_clerk, 'person', 'active', 'Olly Order', 'olly@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_clerk;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_desp, 'person', 'active', 'Dev Despatch', 'dev@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_desp;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_deleg, 'person', 'active', 'Dee Delegate', 'dee@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_deleg;
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_keeper, 'person', 'active', 'Kit Keeper', 'kit@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_keeper;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select r.tenant_id, x.person, ro.id, 'The suite''s narrow role.'
      from (values (u_credit, 'zz_credit_controller'), (u_clerk, 'zz_order_clerk'),
                   (u_desp, 'zz_despatch_clerk'), (u_deleg, 'zz_delegate'),
                   (u_keeper, 'zz_role_keeper')) as x(person, role_code)
      join erp.role ro on ro.tenant_id = r.tenant_id and ro.code = x.role_code;

    insert into auth.users (id, email) values (s_oper, 'oper@zz-loi-' || v_hex || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('oper@zz-loi-' || v_hex || '.test', s_oper, 'Last Open Items Operator', 'operator');
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (r.tenant_id, s_oper, 'person', 'active', 'Opal Operator', 'oper@zz-loi-' || v_hex || '.test', 'en')
    returning id into u_oper;
    perform erp.grant_role(u_oper, 'administrator', null, null, 'a platform operator who administers here too');

    -- Whatever the platform's switch says, the cases begin from closed.
    delete from erp_meta.platform_setting where key = 'self_service.organisations';
    insert into erp_meta.platform_setting (key, value, reason)
    values ('self_service.organisations', 'false'::jsonb, 'Last open items suite: closed for the cases');

    v_step := 'two orders are confirmed before any credit is set';
    v_so_b := erp.open_document('sales_order', v_c1, null, v_site);
    perform erp.add_document_line(v_so_b, v_item, 1, 1000, 'One widget');
    perform erp.transition_document(v_so_b, 'submit', 'last open items suite');
    perform erp_test.approve_document(v_so_b, 'last open items suite');
    v_so_c := erp.open_document('sales_order', v_c2, null, v_site);
    perform erp.add_document_line(v_so_c, v_item, 2, 2500, 'Two widgets');
    perform erp.transition_document(v_so_c, 'submit', 'last open items suite');
    perform erp_test.approve_document(v_so_c, 'last open items suite');

    -- ── 5. Demonstration configuration ─────────────────────────────────────
    v_step := 'demonstration configuration is asked for by an administrator and by a platform operator';
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_seed_demo_configuration');
    v_demo_admin := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(s_oper, 'erp_seed_demo_configuration');
    v_demo_oper := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select count(*) into v_demo_axes from erp.classification_axis ax where ax.tenant_id = r.tenant_id;

    -- ── 1a, 1b. One place, and a door ──────────────────────────────────────
    v_step := 'the credit controller sets the first customer''s limit';
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', 500000, 'on_hold', false,
                         'reason', 'Opening limit agreed at the account review.'));
    v_set1 := g.outcome;
    v_set1_err := g.err_message;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_terms_rows
      from erp.party_role_terms t join erp.party_role pr on pr.tenant_id = t.tenant_id and pr.id = t.party_role_id
     where t.tenant_id = r.tenant_id and pr.party_id = v_c1
       and t.valid_from <= current_date and (t.valid_to is null or t.valid_to > current_date);
    select c.credit_limit_minor into v_pos_limit from erp.credit_position(v_c1) c;
    v_ctx_c1 := erp.document_transition_context(v_so_b, null) ->> 'credit_limit_minor';
    v_ctx_c2 := erp.document_transition_context(v_so_c, null) ->> 'credit_limit_minor';

    v_step := 'credit is set by somebody who may not, for a supplier, below nought and with no reason';
    select * into g from erp_test.last_open_items_door_as(s_clerk, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', 1, 'reason', 'The order clerk tries to change it.'));
    v_ref_perm := jsonb_build_object('state', g.err_state, 'message', g.err_message);
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_sup, 'limit', 1000, 'reason', 'A supplier is not a customer.'));
    v_ref_cust := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint);
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', -1, 'reason', 'Below nought.'));
    v_ref_neg := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint);
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', 1000, 'reason', '   '));
    v_ref_reason := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint);
    select c.credit_limit_minor into v_limit_after_refusals from erp.credit_position(v_c1) c;

    -- ── 1c. An order over the limit ────────────────────────────────────────
    v_step := 'an order worth more than the limit is confirmed and its line reserved';
    v_so_a := erp.open_document('sales_order', v_c1, null, v_site);
    v_so_a_line := erp.add_document_line(v_so_a, v_item, 3, 250000, 'Three widgets at a premium');
    perform erp.transition_document(v_so_a, 'submit', 'last open items suite');
    perform erp_test.approve_document(v_so_a, 'last open items suite');
    select string_agg(t.status::text, ',' order by t.created_at) into v_so_a_credit_step
      from erp.approval_task t join erp.approval_request q on q.tenant_id = t.tenant_id and q.id = t.approval_request_id
     where q.tenant_id = r.tenant_id and q.object_id = v_so_a and t.step_code = 'credit';
    v_alloc_a := erp.reserve_for_line(v_so_a_line);
    select c.on_hold into v_held_a from erp.credit_position(v_c1) c;

    v_step := 'the reservations are listed, to somebody who reads sales and to somebody who does not';
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_allocations',
      jsonb_build_object('order_id', v_so_a, 'status', 'reserved'));
    v_allocs := g.outcome;
    v_allocs_err := g.err_message;
    select * into g from erp_test.last_open_items_door_as(s_keeper, 'erp_allocations');
    v_allocs_denied := jsonb_build_object('state', g.err_state, 'message', g.err_message);

    v_step := 'the despatch clerk picks, commits and delivers the held order';
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_pick_document',
      jsonb_build_object('document_id', v_so_a));
    v_pick_a := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select al.status::text into v_alloc_a_after from erp.allocation al where al.tenant_id = r.tenant_id and al.id = v_alloc_a;
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_commit_allocation',
      jsonb_build_object('allocation_id', v_alloc_a));
    v_commit_a := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_create_delivery_from_order',
      jsonb_build_object('order_id', v_so_a));
    v_dn_refused := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    v_dn_none := not exists (select 1 from erp.document dn
                               join erp.document_type dt on dt.tenant_id = dn.tenant_id and dt.id = dn.document_type_id
                              where dn.tenant_id = r.tenant_id and dn.party_id = v_c1
                                and dt.base_type_code = 'delivery');

    v_step := 'the credit controller releases the order, and it is picked and delivered';
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_release_credit_hold',
      jsonb_build_object('document_id', v_so_a, 'reason', 'Director agreed the order on the phone.'));
    v_release_err := g.err_message;
    v_release_says := erp.check_release_to_fulfilment(v_so_a);
    perform set_config('request.jwt.claims', json_build_object('sub', s_desp)::text, true);
    begin
      v_pick_a2 := erp.pick_document(v_so_a);
      v_dn_a := (erp.create_delivery_from_order(v_so_a, null, 'auto') ->> 'document_id')::uuid;
    exception when others then
      v_pick_a2_err := left(sqlerrm, 240);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_dn_a_state := erp.object_current_state('document', v_dn_a);

    v_step := 'the credit controller holds the first customer with no limit, and its other order is picked';
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', null, 'on_hold', true,
                         'reason', 'Three invoices are disputed; hold until the account is agreed.'));
    v_set_hold := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select count(*), min(t.credit_limit_minor), bool_and(t.is_blocked), min(t.block_reason),
           min(t.credit_status), min(t.credit_reason)
      into v_hold_rows, v_hold_limit, v_hold_blocked, v_hold_block_reason, v_hold_status, v_hold_credit_reason
      from erp.party_role_terms t join erp.party_role pr on pr.tenant_id = t.tenant_id and pr.id = t.party_role_id
     where t.tenant_id = r.tenant_id and pr.party_id = v_c1
       and t.valid_from <= current_date and (t.valid_to is null or t.valid_to > current_date);
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_pick_document',
      jsonb_build_object('document_id', v_so_b));
    v_pick_b := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);

    v_step := 'the hold is lifted, and the order is picked and delivered';
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', null, 'on_hold', false,
                         'reason', 'The account is agreed and the hold is lifted.'));
    v_set_clear := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_pick_document',
      jsonb_build_object('document_id', v_so_b));
    v_pick_b2 := g.outcome;
    v_pick_b2_err := g.err_message;
    perform set_config('request.jwt.claims', json_build_object('sub', s_desp)::text, true);
    v_dn_b := (erp.create_delivery_from_order(v_so_b, null, 'auto') ->> 'document_id')::uuid;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- ── 1d. The discount and credit steps ──────────────────────────────────
    v_step := 'two discounted orders are opened, the limit is cut and the second administrator delegates';
    v_so_d := erp.open_document('sales_order', v_c1, null, v_site);
    perform erp.add_document_line(v_so_d, v_item, 2, 250000, 'Two widgets at a fifth off');
    update erp.document_line set discount_pct = 20 where tenant_id = r.tenant_id and document_id = v_so_d;
    v_so_f := erp.open_document('sales_order', v_c2, null, v_site);
    perform erp.add_document_line(v_so_f, v_item, 1, 1000, 'One widget at a fifth off');
    update erp.document_line set discount_pct = 20 where tenant_id = r.tenant_id and document_id = v_so_f;
    select * into g from erp_test.last_open_items_door_as(s_credit, 'erp_set_credit_limit',
      jsonb_build_object('party_id', v_c1, 'limit', 100000, 'on_hold', false,
                         'reason', 'Limit cut after the second dispute this quarter.'));
    if g.err_message is not null then
      raise exception 'the limit could not be cut: %', g.err_message;
    end if;
    insert into erp.approval_delegation (tenant_id, from_user_id, to_user_id, reason)
    values (r.tenant_id, v_second, u_deleg, 'Away this week')
    returning id into v_delegation;

    v_step := 'the delegate refuses a discount without the permission to approve one';
    perform erp.transition_document(v_so_f, 'submit', 'last open items suite');
    select * into v_task from erp_test.last_open_items_task(r.tenant_id, v_so_f, u_deleg);
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_f1 := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select * into v_task from erp_test.last_open_items_task(r.tenant_id, v_so_f, u_deleg);
    v_f2_step := v_task.step_code;
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', false));
    v_f2 := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select q.status::text into v_f_status
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_so_f
     order by q.requested_at desc limit 1;

    v_step := 'the delegate approves a discount and a credit release, each once given the permission';
    perform erp.transition_document(v_so_d, 'submit', 'last open items suite');
    select * into v_task from erp_test.last_open_items_task(r.tenant_id, v_so_d, u_deleg);
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_d1 := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select * into v_task from erp_test.last_open_items_task(r.tenant_id, v_so_d, u_deleg);
    v_d_disc_step := v_task.step_code;
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_d_disc := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select t.status = 'pending' into v_d_disc_pending from erp.approval_task t
     where t.tenant_id = r.tenant_id and t.id = v_task.task_id;
    perform erp.grant_role(u_deleg, 'zz_discount_approver', null, null, 'may approve discounts');
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_d_disc_ok := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select * into v_task from erp_test.last_open_items_task(r.tenant_id, v_so_d, u_deleg);
    v_d_credit_step := v_task.step_code;
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_d_credit := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    perform erp.grant_role(u_deleg, 'zz_credit_approver', null, null, 'may release credit');
    select * into g from erp_test.last_open_items_door_as(s_deleg, 'erp_decide_approval',
      jsonb_build_object('task_id', v_task.task_id, 'approve', true));
    v_d_credit_ok := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select q.status::text into v_d_status
      from erp.approval_request q
     where q.tenant_id = r.tenant_id and q.object_type = 'document' and q.object_id = v_so_d
     order by q.requested_at desc limit 1;
    update erp.approval_delegation set status = 'inactive' where tenant_id = r.tenant_id and id = v_delegation;

    -- ── 1e. Invoicing what you despatched ──────────────────────────────────
    v_step := 'the despatch clerk invoices the delivery they despatched';
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_invoice_from_delivery',
      jsonb_build_object('delivery_id', v_dn_a));
    v_si1 := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_invoice_from_delivery',
      jsonb_build_object('delivery_id', v_dn_a, 'allow', true));
    v_si2 := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(s_desp, 'erp_invoice_from_delivery',
      jsonb_build_object('delivery_id', v_dn_a, 'allow', true, 'reason', c_reason));
    v_si3 := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    v_si_none := not exists (
      select 1 from erp.document_relation rel
        join erp.document i2 on i2.tenant_id = rel.tenant_id and i2.id = rel.from_document_id
        join erp.document_type it on it.tenant_id = i2.tenant_id and it.id = i2.document_type_id
       where rel.tenant_id = r.tenant_id and rel.to_document_id = v_dn_a
         and it.base_type_code = 'invoice_reference' and not i2.is_cancelled);

    v_step := 'an administrator invoices a delivery they despatched, with the reason';
    v_dn_c := (erp.create_delivery_from_order(v_so_c, null, 'auto') ->> 'document_id')::uuid;
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_invoice_from_delivery',
      jsonb_build_object('delivery_id', v_dn_c));
    v_si4 := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_invoice_from_delivery',
      jsonb_build_object('delivery_id', v_dn_c, 'allow', true, 'reason', c_reason));
    v_si5 := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select d.attributes into v_si5_attrs
      from erp.document d
     where d.tenant_id = r.tenant_id and d.id = (g.outcome #>> '{}')::uuid;

    v_step := 'before go-live the despatch clerk invoices their own delivery without a reason';
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    perform set_config('request.jwt.claims', json_build_object('sub', s_desp)::text, true);
    begin
      v_si6 := to_jsonb(erp.invoice_from_delivery(v_dn_b, true));
    exception when others then
      v_si6_err := left(sqlerrm, 240);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp_test.close_bootstrap_window(r.tenant_id);
    v_live_after := erp.tenant_is_live(r.tenant_id);
    select d.attributes into v_si6_attrs
      from erp.document d
     where d.tenant_id = r.tenant_id and d.id = (v_si6 #>> '{}')::uuid;

    -- ── 4. Stock identity ──────────────────────────────────────────────────
    v_step := 'stock is pinned to lines of a cancelled, a despatched and a draft order';
    v_so_x := erp.open_document('sales_order', v_c2, null, v_site);
    v_so_x_line := erp.add_document_line(v_so_x, v_item, 1, 1000, 'Cancelled before it went anywhere');
    perform erp.transition_document(v_so_x, 'cancel', 'last open items suite');
    v_so_y := erp.open_document('sales_order', v_c2, null, v_site);
    v_so_y_line := erp.add_document_line(v_so_y, v_item, 1, 1000, 'Still being prepared');
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_set_line_stock_identity',
      jsonb_build_object('line_id', v_so_x_line, 'location_id', v_recv));
    v_pin_x := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_set_line_stock_identity',
      jsonb_build_object('line_id', v_so_a_line, 'location_id', v_recv));
    v_pin_a := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_set_line_stock_identity',
      jsonb_build_object('line_id', v_so_y_line, 'location_id', v_recv));
    v_pin_y := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    select dl.location_id = v_recv into v_pinned
      from erp.document_line dl where dl.tenant_id = r.tenant_id and dl.id = v_so_y_line;
    v_lines := public.erp_document_lines(p_type_code => 'sales_order', p_limit => 500, p_open_only => true,
                                         p_document_states => array['draft', 'pending_approval']);
    v_offers_y := exists (select 1 from jsonb_array_elements(v_lines) e where e ->> 'line_id' = v_so_y_line::text);
    v_offers_x := exists (select 1 from jsonb_array_elements(v_lines) e where e ->> 'line_id' = v_so_x_line::text);
    v_offers_a := exists (select 1 from jsonb_array_elements(v_lines) e where e ->> 'line_id' = v_so_a_line::text);

    -- ── 3. Nobody left unable to manage people ─────────────────────────────
    v_step := 'a change taking user management from the administrator role is written, approved and promoted';
    v_cs := erp.create_change_set('zzloi-admin-' || v_hex, 'Administrators stop managing people',
                                  'Takes the permission to manage people from the administrator role.');
    perform erp.add_change_set_item(v_cs, 'role', 'administrator',
      (select jsonb_build_object(
                'code', ro.code, 'name', ro.name,
                'permissions', (select jsonb_agg(jsonb_build_object('permission', rp.permission_code)
                                                 order by rp.permission_code)
                                  from erp.role_permission rp
                                 where rp.tenant_id = ro.tenant_id and rp.role_id = ro.id
                                   and rp.permission_code <> 'administration.users'))
         from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'administrator'),
      'upsert'::erp.change_operation, null, 'the last open items suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs);
    begin
      perform erp.promote_change_set(v_cs);
      v_promote_msg := 'promoted';
    exception when others then
      v_promote_msg := sqlerrm;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_admin_keeps := exists (select 1 from erp.role_permission rp join erp.role ro on ro.tenant_id = rp.tenant_id and ro.id = rp.role_id
                              where ro.tenant_id = r.tenant_id and ro.code = 'administrator'
                                and rp.permission_code = 'administration.users');
    select cs.status::text into v_cs_status from erp.change_set cs where cs.tenant_id = r.tenant_id and cs.id = v_cs;

    v_step := 'the first administrator takes administration from the other two';
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_set_user_roles',
      jsonb_build_object('person', v_second, 'roles', jsonb_build_array('zz_viewer')));
    v_edit_second := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    select * into g from erp_test.last_open_items_door_as(a1, 'erp_set_user_roles',
      jsonb_build_object('person', u_oper, 'roles', jsonb_build_array()));
    v_edit_oper := coalesce(g.outcome, jsonb_build_object('message', g.err_message));
    v_managers_left := erp.user_managers_remaining(r.tenant_id, null);

    v_step := 'the role keeper takes the last administrator''s roles, and then their grant';
    select * into g from erp_test.last_open_items_door_as(s_keeper, 'erp_set_user_roles',
      jsonb_build_object('person', v_admin, 'roles', jsonb_build_array()));
    v_edit_last := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'hint', g.err_hint, 'outcome', g.outcome);
    select ur.id into v_last_grant
      from erp.user_role ur join erp.role ro on ro.tenant_id = ur.tenant_id and ro.id = ur.role_id
     where ur.tenant_id = r.tenant_id and ur.app_user_id = v_admin and ro.code = 'administrator'
       and (ur.valid_to is null or ur.valid_to >= current_date)
     order by ur.valid_from limit 1;
    select * into g from erp_test.last_open_items_door_as(s_keeper, 'erp_revoke_role',
      jsonb_build_object('grant_id', v_last_grant));
    v_revoke_last := jsonb_build_object('state', g.err_state, 'message', g.err_message, 'outcome', g.outcome);
    v_last_keeps := erp.holds_user_management(r.tenant_id, v_admin);
    v_last_grant_open := exists (select 1 from erp.user_role ur
                                  where ur.tenant_id = r.tenant_id and ur.id = v_last_grant
                                    and (ur.valid_to is null or ur.valid_to >= current_date));

    perform set_config('request.jwt.claims', '', true);
    raise exception 'ZZ_LAST_OPEN_ITEMS_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_LAST_OPEN_ITEMS_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 300));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  -- ── The verdicts ─────────────────────────────────────────────────────────

  case_name := 'the credit and allocation doors are one function each, run as the caller, write the access decision, are the signed-in caller''s to call and name their gate; invoicing takes the reason last; deciding an approval no longer says it needs no gate';
  passed := coalesce(v_cl_n = 1 and v_al_n = 1 and v_in_n = 1 and v_in_erp_n = 1
            and not v_cl_def and not v_al_def and v_cl_vol and v_al_vol and v_cl_grant and v_al_grant
            and v_cl_gate = 'erp.authorise' and v_al_gate = 'erp.authorise'
            and v_cl_args = 'p_party_id uuid, p_credit_limit_minor bigint, p_on_hold boolean, p_reason text'
            and v_al_args = 'p_order_id uuid, p_status text, p_limit integer'
            and v_in_args = 'p_delivery_id uuid, p_allow_self_invoice boolean, p_self_invoice_reason text'
            and v_in_erp_args = 'p_delivery_id uuid, p_allow_self_invoice boolean, p_self_invoice_reason text'
            and v_decide_ungated = 'none', false);
  detail := format('credit %s (%s) gate %s; allocations %s (%s) gate %s; invoice %s (%s); erp %s (%s); decide ungated %s',
                   v_cl_n, coalesce(v_cl_args, 'none'), coalesce(v_cl_gate, 'none'),
                   v_al_n, coalesce(v_al_args, 'none'), coalesce(v_al_gate, 'none'),
                   v_in_n, coalesce(v_in_args, 'none'), v_in_erp_n, coalesce(v_in_erp_args, 'none'),
                   coalesce(v_decide_ungated, 'no row'));
  return next;

  case_name := 'a credit limit set on the door is the one the credit position and the approval chain read, over the limit the customer role still carries; a customer with no terms is read from the role';
  passed := v_state is null and coalesce(
            v_set1_err is null
            and (v_set1 ->> 'credit_limit_minor')::bigint = 500000
            and (v_set1 -> 'on_hold') = 'false'::jsonb
            and (v_set1 -> 'held') = 'false'::jsonb
            and v_terms_rows = 1
            and v_pos_limit = 500000
            and v_ctx_c1 = '500000'
            and v_ctx_c2 = '10000000'
            and v_so_a_credit_step like '%approved%', false);
  detail := coalesce(v_state, format('door %s %s; %s row(s) in force; position %s; context %s and %s; order credit step %s',
                                     coalesce(v_set1::text, ''), coalesce(v_set1_err, ''), v_terms_rows, v_pos_limit,
                                     v_ctx_c1, v_ctx_c2, coalesce(v_so_a_credit_step, 'none')));
  return next;

  case_name := 'credit is refused to somebody who may not release credit, for a business partner who is not a customer, below nought and with no reason, each by name, and the limit is left as it was';
  passed := v_state is null and coalesce(
            v_ref_perm ->> 'state' = '42501' and v_ref_perm ->> 'message' like 'CLOVEERP_PERMISSION_DENIED: sales.credit_release%'
            and v_ref_cust ->> 'message' like 'CLOVEERP_NOT_A_CUSTOMER%' and v_ref_cust ->> 'hint' <> ''
            and v_ref_neg ->> 'state' = '22023' and v_ref_neg ->> 'message' like 'CLOVEERP_CREDIT_LIMIT_NEGATIVE%'
            and v_ref_reason ->> 'state' = '22023' and v_ref_reason ->> 'message' like 'CLOVEERP_CREDIT_CHANGE_NEEDS_REASON%'
            and v_limit_after_refusals = 500000, false);
  detail := coalesce(v_state, format('%s; %s; %s; %s; limit %s', v_ref_perm, v_ref_cust ->> 'message',
                                     v_ref_neg ->> 'message', v_ref_reason ->> 'message', v_limit_after_refusals));
  return next;

  case_name := 'with sales.read the reservations of an order are listed with their order, product and quantity; without it the list is refused';
  passed := v_state is null and coalesce(
            v_allocs_err is null
            and jsonb_array_length(v_allocs) = 1
            and v_allocs -> 0 ->> 'allocation_id' = v_alloc_a::text
            and v_allocs -> 0 ->> 'status' = 'reserved'
            and v_allocs -> 0 ->> 'item' = 'WID'
            and (v_allocs -> 0 ->> 'quantity')::numeric = 3
            and v_allocs -> 0 ->> 'document_number' is not null
            and v_allocs -> 0 ->> 'customer' = 'Credit Customer'
            and v_allocs_denied ->> 'state' = '42501'
            and v_allocs_denied ->> 'message' like 'CLOVEERP_PERMISSION_DENIED: sales.read%', false);
  detail := coalesce(v_state, left(format('%s %s; denied %s', coalesce(v_allocs::text, ''), coalesce(v_allocs_err, ''), v_allocs_denied), 600));
  return next;

  case_name := 'an order over its customer''s limit is refused at picking by name, pointing at Release a credit hold, and nothing is picked';
  passed := v_state is null and coalesce(
            v_held_a
            and v_pick_a ->> 'state' = '42501'
            and v_pick_a ->> 'message' like 'CLOVEERP_CREDIT_HOLD:%over their credit limit%'
            and v_pick_a ->> 'hint' like '%Release a credit hold%'
            and v_pick_a ->> 'hint' not like '%sales.%'
            and v_alloc_a_after = 'reserved', false);
  detail := coalesce(v_state, format('held %s; %s; allocation %s', v_held_a, v_pick_a, v_alloc_a_after));
  return next;

  case_name := 'committing its reservation is refused on credit too';
  passed := v_state is null and coalesce(
            v_commit_a ->> 'state' = '42501' and v_commit_a ->> 'message' like 'CLOVEERP_CREDIT_HOLD:%', false);
  detail := coalesce(v_state, v_commit_a::text);
  return next;

  case_name := 'and so is creating a delivery from it, and no delivery is made';
  passed := v_state is null and coalesce(
            v_dn_refused ->> 'state' = '42501' and v_dn_refused ->> 'message' like 'CLOVEERP_CREDIT_HOLD:%'
            and v_dn_none, false);
  detail := coalesce(v_state, format('%s; none made %s', v_dn_refused, v_dn_none));
  return next;

  case_name := 'released by somebody who may release credit, the order is picked and delivered';
  passed := v_state is null and coalesce(
            v_release_err is null and v_release_says = 'released'
            and v_pick_a2_err is null and (v_pick_a2 ->> 'picked')::integer >= 1
            and v_dn_a is not null and v_dn_a_state = 'posted', false);
  detail := coalesce(v_state, format('release %s, says %s; pick %s %s; delivery %s', coalesce(v_release_err, 'done'),
                                     v_release_says, coalesce(v_pick_a2::text, ''), coalesce(v_pick_a2_err, ''), v_dn_a_state));
  return next;

  case_name := 'a customer put on credit hold with no limit has the reason kept on the one row of terms, and their order is refused at picking with the reason';
  passed := v_state is null and coalesce(
            (v_set_hold -> 'held') = 'true'::jsonb
            and v_hold_rows = 1
            and v_hold_limit is null
            and v_hold_blocked
            and v_hold_status = 'hold'
            and v_hold_block_reason = 'Three invoices are disputed; hold until the account is agreed.'
            and v_hold_credit_reason = v_hold_block_reason
            and v_pick_b ->> 'state' = '42501'
            and v_pick_b ->> 'message' like 'CLOVEERP_CREDIT_HOLD:%Three invoices are disputed%', false);
  detail := coalesce(v_state, format('%s; %s row(s); %s', v_set_hold, v_hold_rows, v_pick_b));
  return next;

  case_name := 'lifting the hold lets the order be picked';
  passed := v_state is null and coalesce(
            (v_set_clear -> 'held') = 'false'::jsonb and (v_set_clear -> 'previously_on_hold') = 'true'::jsonb
            and v_pick_b2_err is null and (v_pick_b2 ->> 'picked')::integer >= 1 and v_dn_b is not null, false);
  detail := coalesce(v_state, format('%s; pick %s %s', v_set_clear, coalesce(v_pick_b2::text, ''), coalesce(v_pick_b2_err, '')));
  return next;

  case_name := 'refusing a discount step needs no permission, and sends the order back';
  passed := v_state is null and coalesce(
            (v_f1 ->> 'status') = 'pending' and v_f2_step = 'discount'
            and (v_f2 ->> 'status') = 'rejected' and v_f_status = 'rejected', false);
  detail := coalesce(v_state, format('first step %s; %s step %s; request %s', v_f1, v_f2_step, v_f2, v_f_status));
  return next;

  case_name := 'approving a discount above the threshold needs sales.discount_approve, and the task waits until the approver holds it';
  passed := v_state is null and coalesce(
            (v_d1 ->> 'status') = 'pending' and v_d_disc_step = 'discount'
            and v_d_disc ->> 'state' = '42501'
            and v_d_disc ->> 'message' like 'CLOVEERP_PERMISSION_DENIED: sales.discount_approve%'
            and v_d_disc_pending
            and (v_d_disc_ok ->> 'status') = 'pending', false);
  detail := coalesce(v_state, format('first %s; %s: %s, still pending %s; then %s', v_d1, v_d_disc_step, v_d_disc,
                                     v_d_disc_pending, v_d_disc_ok));
  return next;

  case_name := 'approving an order past its customer''s limit needs sales.credit_release, read from the terms the door set';
  passed := v_state is null and coalesce(
            v_d_credit_step = 'credit'
            and v_d_credit ->> 'state' = '42501'
            and v_d_credit ->> 'message' like 'CLOVEERP_PERMISSION_DENIED: sales.credit_release%'
            and (v_d_credit_ok ->> 'status') = 'approved'
            and v_d_status = 'approved', false);
  detail := coalesce(v_state, format('%s: %s; then %s; request %s', v_d_credit_step, v_d_credit, v_d_credit_ok, v_d_status));
  return next;

  case_name := 'in a live organisation the despatcher invoicing their own delivery is refused by name in words, asked for a reason, then refused without the permission to promote, and nothing is invoiced';
  passed := v_state is null and coalesce(
            v_si1 ->> 'state' = '42501' and v_si1 ->> 'message' like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
            and v_si1 ->> 'hint' like '%promote configuration%' and v_si1 ->> 'hint' not like '%sales.%'
            and v_si2 ->> 'state' = '22023' and v_si2 ->> 'message' like 'CLOVEERP_SOD_EXCEPTION_REASON_TOO_SHORT%'
            and v_si3 ->> 'state' = '42501' and v_si3 ->> 'message' like 'CLOVEERP_PERMISSION_DENIED: administration.promote%'
            and v_si_none, false);
  detail := coalesce(v_state, left(format('%s; %s; %s; nothing invoiced %s', v_si1, v_si2, v_si3, v_si_none), 700));
  return next;

  case_name := 'an administrator who may promote invoices their own delivery with the reason, and the invoice keeps who allowed it and why';
  passed := v_state is null and coalesce(
            v_si4 ->> 'message' like 'CLOVEERP_SEGREGATION_OF_DUTIES%'
            and v_si5 ->> 'state' is null and v_si5 ->> 'outcome' is not null
            and v_si5_attrs ->> 'self_invoice_reason' = c_reason
            and v_si5_attrs ->> 'self_invoiced_by' = v_admin::text
            and v_si5_attrs ? 'self_invoiced_at', false);
  detail := coalesce(v_state, format('%s; %s; %s', v_si4 ->> 'message', v_si5, coalesce(v_si5_attrs::text, 'no invoice')));
  return next;

  case_name := 'before go-live the despatcher may invoice their own delivery without a reason, as before, and it is still recorded';
  passed := v_state is null and coalesce(
            v_si6_err is null and v_si6 is not null
            and v_si6_attrs ->> 'self_invoiced_by' = u_desp::text
            and v_si6_attrs -> 'self_invoice_reason' = 'null'::jsonb
            and v_live_after, false);
  detail := coalesce(v_state, format('%s %s; %s; live again %s', coalesce(v_si6::text, ''), coalesce(v_si6_err, ''),
                                     coalesce(v_si6_attrs::text, 'no invoice'), v_live_after));
  return next;

  case_name := 'stock is not pinned to a line of a cancelled order or of a despatched one, each refused by name with what to do, and is pinned to a draft order''s line';
  passed := v_state is null and coalesce(
            v_pin_x ->> 'state' = '23514' and v_pin_x ->> 'message' like 'CLOVEERP_DOCUMENT_FINISHED%' and v_pin_x ->> 'hint' <> ''
            and v_pin_a ->> 'state' = '23514' and v_pin_a ->> 'message' like 'CLOVEERP_DOCUMENT_COMMITTED%' and v_pin_a ->> 'hint' <> ''
            and v_pin_y ->> 'state' is null and v_pinned, false);
  detail := coalesce(v_state, format('%s; %s; %s; pinned %s', v_pin_x ->> 'message', v_pin_a ->> 'message', v_pin_y, v_pinned));
  return next;

  case_name := 'the line picker the desk asks with offers a draft order''s line, and neither a cancelled nor a despatched order''s';
  passed := v_state is null and coalesce(v_offers_y and not v_offers_x and not v_offers_a, false);
  detail := coalesce(v_state, format('draft %s, cancelled %s, despatched %s', v_offers_y, v_offers_x, v_offers_a));
  return next;

  case_name := 'while self-service sign-up is closed an administrator who is not staff is refused demonstration configuration by name, and a platform operator passes that gate to the live refusal';
  passed := v_state is null and coalesce(
            v_demo_admin ->> 'state' = '42501' and v_demo_admin ->> 'message' like 'CLOVEERP_DEMO_FOR_PLATFORM_STAFF_ONLY%'
            and v_demo_oper ->> 'state' = '42501' and v_demo_oper ->> 'message' like 'CLOVEERP_DEMO_IN_LIVE%'
            and v_demo_axes = 0, false);
  detail := coalesce(v_state, format('administrator %s; operator %s; axes %s', v_demo_admin, v_demo_oper, v_demo_axes));
  return next;

  case_name := 'a promoted change taking user management from every administrator is refused by name, and the role keeps it';
  passed := v_state is null and coalesce(
            v_promote_msg like 'CLOVEERP_LAST_USER_MANAGER%' and v_admin_keeps and v_cs_status = 'approved', false);
  detail := coalesce(v_state, format('%s; keeps %s; change %s', left(v_promote_msg, 300), v_admin_keeps, v_cs_status));
  return next;

  case_name := 'roles are taken from administrators while somebody else still manages people, and the last one''s roles and grant cannot be taken, each refused by name';
  passed := v_state is null and coalesce(
            (v_edit_second ->> 'revoked')::integer = 1 and (v_edit_oper ->> 'revoked')::integer = 1
            and v_managers_left = 1
            and v_edit_last ->> 'state' = '23514' and v_edit_last ->> 'message' like 'CLOVEERP_LAST_USER_MANAGER%'
            and v_edit_last ->> 'hint' <> ''
            and v_revoke_last ->> 'state' = '23514' and v_revoke_last ->> 'message' like 'CLOVEERP_LAST_USER_MANAGER%'
            and v_last_keeps and v_last_grant_open, false);
  detail := coalesce(v_state, left(format('%s; %s; %s left; %s; %s; keeps %s, grant open %s',
                                          v_edit_second, v_edit_oper, v_managers_left, v_edit_last, v_revoke_last,
                                          v_last_keeps, v_last_grant_open), 700));
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-loi-' || v_hex)
            and not exists (select 1 from erp_meta.platform_staff s where s.auth_user_id = s_oper);
  detail := 'the organisation, its people, orders, terms, deliveries, invoices, the operator and the change rolled back';
  return next;
end;
$$;
revoke all on function erp_test.last_open_items_suite() from public, anon, authenticated;

comment on function erp_test.last_open_items_suite() is
  'Credit, allocations, the last user manager, stock identity and demonstration '
  'configuration through the doors as a signed-in caller in a live organisation '
  'with two administrators: a credit limit set once and read by the position and '
  'the approval chain; a held order refused at picking, committing and delivery '
  'until released; the discount and credit steps needing their permissions; '
  'invoicing your own delivery as a governed exception; the reservations listed; '
  'nobody left unable to manage people; stock pinned only to lines that can ship; '
  'demonstration configuration for platform staff. Rolls back everything it made.';

create or replace function erp_test.assert_last_open_items_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 22;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.last_open_items_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_LAST_OPEN_ITEMS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_LAST_OPEN_ITEMS_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the rule: an order, an invoice, a grant or a pin that should be refused went through, or one that should go through was refused.';
  end if;
  return format('last open items: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;
revoke all on function erp_test.assert_last_open_items_suite() from public, anon, authenticated;

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
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_packs_installable();
select erp.assert_part5_coverage();
select erp.assert_guidance_sound();
select erp.assert_session_context_hygiene();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage('de');
select erp.assert_vocabulary_aligned();
select erp.assert_isolation();

select erp_test.assert_last_open_items_suite();
select erp_test.assert_sales_depth_suite();
select erp_test.assert_sales_suite();
select erp_test.assert_delivery_from_order_suite();
select erp_test.assert_controls_finish_suite();
select erp_test.assert_duties_separated_suite();
select erp_test.assert_access_withdrawal_suite();
select erp_test.assert_approval_hold_suite();
select erp_test.assert_warehouse_and_finance_jobs_suite();
select erp_test.assert_guidance_suite();
