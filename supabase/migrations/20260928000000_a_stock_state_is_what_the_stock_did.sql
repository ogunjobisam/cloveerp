set lock_timeout = '30s';

-- =============================================================================
-- 20260928000000  A stock state is what the stock did
-- -----------------------------------------------------------------------------
-- PR11, M1 (docs/spec/simplification-review.md §7, nodes C3 and I7): the
-- transfer order and the stock adjustment refuse, in every organisation and
-- on every version of their lifecycles, the moves no stock movement backs, and
-- the generic document screen stops offering them. Decision D1 as taken on 25
-- September: no existing row is changed; what is already wrong is reported,
-- and stranded stock is returned only when an operator asks.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- C3 (20260922200000) refused `in_transit` and `received` by their codes when
-- no stock had moved. It asked about two codes and not about the states they
-- reach, and it asked nothing about who was moving the document. On a
-- database built from main (PR11 scoping, E1 to E5):
--
--   * 13 of the transfer order's 16 transitions, and the stock adjustment's
--     `post` and `approved_to_cancelled`, carry no required_permission. A
--     transition with none is open to anybody who can read the document, so a
--     person who holds only inventory.read walked an approved transfer to
--     discrepancy, received and closed, and clicked Post on an approved
--     adjustment.
--   * draft_to_discrepancy then discrepancy_to_received walked round the C3
--     guard: a transfer read received, then closed, with no movement at all.
--   * in_transit_to_cancelled, clicked after a real despatch, left the goods in
--     transit for good: the receive door refuses a cancelled transfer, and
--     nothing else writes the arrival.
--   * An adjustment clicked to posted wrote no movement, and its variance
--     could then never be posted, because the door refuses a posted document.
--   * The generic document screen offered every one of these moves.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A transfer order's or a stock adjustment's move with no required_
--     permission asks the type's own: inventory.move, at both sites of a
--     transfer, as erp.despatch_transfer() and erp.receive_transfer() ask it;
--     inventory.adjust at the adjustment's site, as erp.post_stock_adjustment()
--     asks it. A move the system derives (a count's own adjustment, posted as
--     the count is, 20260927200000) keeps its authority from the fact, as
--     erp.perform_transition() gives it. The lifecycles are not touched: no
--     required_permission is written and no version moves, so a document in
--     flight on any version is governed the same way today.
--   * erp.stock_state_refusal(document, to_state) says what the stock has
--     not done, by what the state reached means in the version the document
--     is on (its is_terminal and is_committed), and by name only for the
--     states the doors make, so an organisation's own version with a state of
--     its own is asked the same thing. A transfer order:
--       discrepancy   refused always (CLOVEERP_TRANSFER_DISCREPANCY_RETIRED):
--                     nothing enters it but a click, and M3 removes it.
--       in_transit    no movement against the transfer, and
--       received      no movement at the receiving site
--                     (CLOVEERP_TRANSFER_HAS_NOT_MOVED, C3's code and reading,
--                     now for every move that reaches either state, so
--                     discrepancy_to_received is asked it too).
--       closed        nothing arrived (CLOVEERP_TRANSFER_HAS_NOT_MOVED), or
--                     some of it is still in transit
--                     (CLOVEERP_TRANSFER_STILL_ON_THE_ROAD).
--       any other     an end (cancelled, or a state of the organisation's
--                     own) once a movement stands that nobody has returned
--                     (CLOVEERP_TRANSFER_HAS_MOVED); and any state at all
--                     while stock is in transit
--                     (CLOVEERP_TRANSFER_STILL_ON_THE_ROAD).
--     A stock adjustment reaches a committed end, or a committed state past
--     its approval, only once its door has written its movements
--     (CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR), and once it has them, moves
--     only on to committed states (CLOVEERP_ADJUSTMENT_ALREADY_POSTED).
--   * erp.transition_document() asks both, through
--     erp.require_stock_backed_move(), after C3's own guard, which stays as it
--     was. A fallback permission answered by a fact is written on the
--     transition log as erp.perform_transition() writes it: {derived: {fact,
--     permission, actor_permitted}}.
--   * erp.available_transitions(), which public.erp_available_transitions()
--     and so the generic document screen read, asks the same function for its
--     guard_passes and the same fallback for its permitted, so the screen
--     draws only what the database would take. The menu and the enforcement
--     read one definition, as 20260922300000 made them for the guard context.
--   * erp.stock_state_mismatch_report() lists what is already wrong in the
--     organisation it is run in: transfers in discrepancy; transfers
--     cancelled with stock still in transit, or after their stock moved and
--     was not returned; transfers whose state says stock moved that their
--     movements do not; and stock adjustments posted with no movement. A
--     tenant report in the diagnostic register, not an assertion: it blocks
--     nothing. The runbook (supabase/ops/20260928_stock_state_mismatches.sql)
--     carries the same reading as plain SQL for the run before the deploy.
--   * erp.return_stranded_transit_stock(document, reason) puts stock stranded
--     in transit by a transfer cancelled or sent to discrepancy back on the
--     despatching site's shelf, by reversing each despatch leg not yet
--     returned; a transfer any of whose stock arrived is refused. Only an
--     operator's session may call it (a trusted session acting inside the
--     organisation, with nobody signed in), it writes the operator and the
--     reason in the audit trail, and nothing calls it here.
--   * A3 and A4 leave a body that already carries them as it is, so the file
--     can be applied again.
--   * erp_test.stock_state_guard_suite is the proof.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The report is granted as every tenant report is, to the signed-in for
--     erp.run_diagnostic(); the repair is granted to nobody, and nothing the
--     signed-in can reach names it, which erp.apply_execute_grants() reads.
--   * No existing row is changed: no document moves, no movement is written,
--     no lifecycle, register row or configuration is restated. Documents
--     already in discrepancy stay there; one can leave only once its goods
--     arrive, which the repair cannot write (see below).
--   * No lifecycle change. Removing discrepancy, the cancellations, and
--     writing a permission on every transition is M3's (inventory-operations
--     v8), with the upgrade register. The fallback here is what M3 writes into
--     the machine, asked in code until then, so it reaches every organisation
--     without a version bump.
--   * erp.transition_driver_register() is not restated, and so neither is
--     DOOR_ONLY_TRANSITIONS in src/components/erp/available-transitions.ts:
--     every row stays `screen`, and a refused move is not drawn because its
--     guard does not pass, not because a door owns it.
--   * erp.transition_refusal(), the "refused" flag, is not taught these
--     codes: the screen hides a move whose guard does not pass, and says so
--     once ("Some moves wait on a condition this document does not meet
--     yet"), and a refusal it could name would need screen strings of its own.
--   * The repair returns stock to the despatching site only. Booking stranded
--     stock into the receiving site would move value between sites and take
--     the document to received, and that is an operator's judgement about
--     where the goods are, not a repair.
--   * No public function, so no allowance and no door: the operator reaches
--     the report and the repair from psql.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_TRANSFER_HAS_MOVED',
  'Cancelling or otherwise ending a transfer order after stock has left the shelf against it.',
  'A cancelled transfer order says nothing is being moved. Once the goods have left the despatching site, ending the order any way but by their arrival leaves them in transit, or on the receiving site''s shelf, with an order that says they never went.',
  'Receive the transfer at the site expecting it, then raise a new transfer to send back what should not have gone. If the goods never left, ask an operator to return them to the despatching site''s shelf.');

select erp.register_refusal('CLOVEERP_TRANSFER_DISCREPANCY_RETIRED',
  'Moving a transfer order into discrepancy.',
  'Discrepancy is a state nothing but a click ever reached, and nothing leaves it until goods arrive. A transfer marked in discrepancy stops the receiving site booking in what did arrive, and says nothing about what went missing.',
  'Receive what arrived at the receiving site, then count the difference where it was lost. The count writes the loss, and the transfer closes on what arrived.');

select erp.register_refusal('CLOVEERP_TRANSFER_STILL_ON_THE_ROAD',
  'Closing a transfer order, or moving it anywhere but received, while some of its stock is still in transit.',
  'Stock in transit is on its way to the receiving site. Moving the order anywhere but received while it is would leave the stock on the road with nothing left to receive it.',
  'Receive the rest at the site expecting it, and the transfer can be closed. If it will never arrive, count the difference where it was lost.');

select erp.register_refusal('CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR',
  'Marking a stock adjustment posted, or moving it on past its approval, by hand.',
  'A stock adjustment is posted by writing its movements and its journals. Marked posted by hand, it would say the shelf had been corrected when nothing was, and the adjustment could never be posted afterwards.',
  'Post it from the Stock adjustments screen, which writes the stock and the ledger and then marks it posted.');

select erp.register_refusal('CLOVEERP_TRANSFER_NOT_STRANDED',
  'Returning a transfer order''s stock to the despatching site when none of it is stranded.',
  'Stock is stranded when a transfer was cancelled or sent to discrepancy after it left the shelf, and none of it has since arrived. Any other transfer is received or cancelled in the usual way, and returning its stock would take goods off a lorry that is still going somewhere.',
  'Ask the operator to run the stock state report, and repair only the transfers it lists as cancelled or in discrepancy with stock in transit. Receive any other transfer at the site expecting it.');

select erp.register_refusal('CLOVEERP_STRANDED_STOCK_NEEDS_AN_OPERATOR',
  'Returning stranded transfer stock while signed in.',
  'Returning stranded stock writes movements nobody on the desk asked for, so it is a repair an operator makes and records, not a button.',
  'Ask the operator to run the stock state report first, then to repair each transfer it lists, one at a time and with the reason, as the operations runbook says.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. What the stock has done, read one way for the menu and the refusal
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transfer_in_transit_quantity(p_document_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- What a transfer order has put in transit and not yet taken out of it
  -- (20260928000000): each despatch leg ends in_transit, and each arrival, and
  -- each return of a despatch leg, starts from it.
  select coalesce(sum(case when m.to_status = 'in_transit' then m.quantity else 0 end), 0)
       - coalesce(sum(case when m.from_status = 'in_transit' then m.quantity else 0 end), 0)
    from erp.stock_movement m
   where m.tenant_id = erp.current_tenant_id()
     and m.document_id = p_document_id
$$;

comment on function erp.transfer_in_transit_quantity(uuid) is
  'The quantity a transfer order has put in transit and not taken out again, by its arrival or '
  'by a return: what is on the road against it (20260928000000).';

create or replace function erp.stock_state_refusal(p_document_id uuid, p_to_state text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.current_tenant_id();
  v_base      text;
  v_dest      uuid;
  v_version   uuid;
  v_from_committed boolean;
  v_terminal  boolean;
  v_committed boolean;
  v_any       boolean;
  v_stands    boolean;
  v_arrived   boolean;
  v_transit   numeric;
begin
  -- The refusal a transfer order's or a stock adjustment's move into
  -- p_to_state meets because the stock has not done what the state says, or
  -- null (20260928000000). Read by what the state means in the version the
  -- document is on, its is_terminal and is_committed, and not by its code, so
  -- an organisation's own version with a state of its own is asked the same
  -- thing. Raised by erp.require_stock_backed_move(); read for guard_passes
  -- by erp.available_transitions(), so the screen offers what this allows.
  if v_tenant is null or p_to_state is null then
    return null;
  end if;

  select dt.base_type_code, d.destination_site_id, os.state_machine_version_id, fs.is_committed
    into v_base, v_dest, v_version, v_from_committed
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
    join erp.object_state os
      on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
    join erp.state fs on fs.id = os.current_state_id
   where d.tenant_id = v_tenant and d.id = p_document_id;

  if v_base is null or v_base not in ('transfer_order', 'adjustment') then
    return null;
  end if;

  select s.is_terminal, s.is_committed into v_terminal, v_committed
    from erp.state s
   where s.tenant_id = v_tenant and s.state_machine_version_id = v_version and s.code = p_to_state;
  v_terminal  := coalesce(v_terminal, false);
  v_committed := coalesce(v_committed, false);

  v_any := exists (select 1 from erp.stock_movement m
                    where m.tenant_id = v_tenant and m.document_id = p_document_id);

  if v_base = 'adjustment' then
    -- Once its door has written the stock, it moves only on to committed
    -- states: not cancelled, not back to be edited.
    if v_any then
      if not v_committed then
        return 'CLOVEERP_ADJUSTMENT_ALREADY_POSTED';
      end if;
      return null;
    end if;
    -- With nothing written, it reaches a committed end, or a committed state
    -- beyond the first (its approval), only through its door.
    if v_committed and (v_terminal or coalesce(v_from_committed, false)) then
      return 'CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR';
    end if;
    return null;
  end if;

  if p_to_state = 'discrepancy' then
    return 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED';
  end if;

  -- A movement that stands: not itself a return, and not returned.
  v_stands := exists (select 1 from erp.stock_movement m
                       where m.tenant_id = v_tenant and m.document_id = p_document_id
                         and not m.is_reversal
                         and not exists (select 1 from erp.stock_movement r
                                          where r.tenant_id = m.tenant_id
                                            and r.reverses_movement_id = m.id));
  -- C3's reading of "it got there": a movement at the receiving site.
  v_arrived := exists (select 1 from erp.stock_movement m
                        where m.tenant_id = v_tenant and m.document_id = p_document_id
                          and m.site_id = v_dest);
  v_transit := erp.transfer_in_transit_quantity(p_document_id);

  -- The two states the doors make, and the close that follows them.
  if p_to_state = 'in_transit' then
    if not v_any then
      return 'CLOVEERP_TRANSFER_HAS_NOT_MOVED';
    end if;
    return null;
  elsif p_to_state = 'received' then
    if not v_arrived then
      return 'CLOVEERP_TRANSFER_HAS_NOT_MOVED';
    end if;
    return null;
  elsif p_to_state = 'closed' then
    if not v_arrived then
      return 'CLOVEERP_TRANSFER_HAS_NOT_MOVED';
    end if;
    if v_transit <> 0 then
      return 'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD';
    end if;
    return null;
  end if;

  -- Any other state, whatever it is called: no end once stock has moved and
  -- stands unreturned, and nowhere at all while stock is on the road.
  if v_terminal and v_stands then
    return 'CLOVEERP_TRANSFER_HAS_MOVED';
  end if;
  if v_transit > 0 then
    return 'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD';
  end if;
  return null;
end;
$$;

comment on function erp.stock_state_refusal(uuid, text) is
  'The refusal a transfer order''s or stock adjustment''s move into the given state meets because '
  'the stock has not done what that state means, or null. Read by the state''s is_terminal and '
  'is_committed in the document''s version, and by name only for the states the doors make: '
  'discrepancy always; in transit with no movement; received or closed with nothing at the '
  'receiving site; closed, or anywhere else, with stock still in transit; any other end once a '
  'movement stands; an adjustment''s committed end, or a committed state past its approval, with '
  'no movement, and anything but a committed state once it has one (20260928000000).';

create or replace function erp.may_move_stock_document(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- Whether the caller holds what a transfer order's or stock adjustment's
  -- move with no required_permission asks (20260928000000): inventory.move at
  -- both sites of a transfer, inventory.adjust at an adjustment's site. True
  -- for every other document, whose permissionless moves ask nothing, as
  -- before.
  select coalesce((
    select case dt.base_type_code
             when 'transfer_order' then
               erp.has_permission('inventory.move', d.entity_id, d.site_id)
               and (d.destination_site_id is null
                    or erp.has_permission('inventory.move', d.entity_id, d.destination_site_id))
             when 'adjustment' then
               erp.has_permission('inventory.adjust', d.entity_id, d.site_id)
             else true
           end
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id), true)
$$;

comment on function erp.may_move_stock_document(uuid) is
  'Whether the caller holds the permission a transfer order''s or stock adjustment''s move with none '
  'of its own asks: inventory.move at both sites, inventory.adjust at the site. True for any other '
  'document (20260928000000). The menu''s half of erp.require_stock_backed_move().';

create or replace function erp.require_stock_backed_move(p_document_id uuid, p_transition_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  v_base    text;
  v_from    text;
  v_to      text;
  v_perm    text;
  v_found   boolean;
  v_derived text;
  v_permitted boolean := true;
  v_site    uuid;
  v_code    text;
  v_label   text;
  v_stranded_hint constant text :=
    'This transfer is already in discrepancy. Ask the operator to run the stock state report: '
    'stock stranded in transit goes back to the despatching site, and anything else is counted '
    'where it is.';
begin
  -- A transfer order or stock adjustment moves because its stock did
  -- (20260928000000). Asked by erp.transition_document() of every move, on
  -- every version of either lifecycle; anything else returns at once.
  --
  -- Returns what erp.perform_transition() writes on the transition log for a
  -- derived move, {fact, permission, actor_permitted}, when the fallback
  -- permission below was answered by a fact, and null otherwise, so the log
  -- says the same whichever of the two asked.
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    return null;
  end if;
  select dt.base_type_code into v_base
    from erp.document_type dt where dt.tenant_id = v_tenant and dt.id = d.document_type_id;
  if v_base is null or v_base not in ('transfer_order', 'adjustment') then
    return null;
  end if;

  -- The move as the version this document started on declares it, from where
  -- it stands. Not declared: erp.perform_transition() says so.
  select fs.code, ts.code, t.required_permission, true into v_from, v_to, v_perm, v_found
    from erp.object_state os
    join erp.state fs on fs.id = os.current_state_id
    join erp.transition t
      on t.tenant_id = os.tenant_id
     and t.state_machine_version_id = os.state_machine_version_id
     and t.from_state_id = os.current_state_id
     and t.code = p_transition_code
    join erp.state ts on ts.id = t.to_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id;
  if not coalesce(v_found, false) then
    return null;
  end if;

  -- Who: a move with no permission of its own asks the type's, as the doors
  -- do. A derived move takes its authority from the fact, as
  -- erp.perform_transition() gives it: the person is asked, and only their
  -- CLOVEERP_PERMISSION_DENIED is answered by the fact, logged against them.
  if v_perm is null then
    v_perm := case v_base when 'transfer_order' then 'inventory.move' else 'inventory.adjust' end;
    v_derived := erp.derived_move_fact('document', p_document_id, p_transition_code);
    for v_site in
      select x.site_id
        from unnest(case when v_base = 'transfer_order' and d.destination_site_id is not null
                         then array[d.site_id, d.destination_site_id]
                         else array[d.site_id] end) with ordinality as x(site_id, n)
       order by x.n
    loop
      if v_derived is null then
        perform erp.authorise(v_perm, d.entity_id, v_site, null, 'document', p_document_id);
      else
        begin
          perform erp.authorise(v_perm, d.entity_id, v_site, null, 'document', p_document_id);
        exception when insufficient_privilege then
          if sqlerrm not like 'CLOVEERP_PERMISSION_DENIED:%' then
            raise;
          end if;
          v_permitted := false;
          perform erp.log_access_decision(
            v_perm, true, d.entity_id, v_site, null, 'document', p_document_id,
            format('derived from %s: the system''s move, made on this person''s action', v_derived));
        end;
      end if;
    end loop;
  end if;

  -- What: the stock has done what the state says.
  v_code  := erp.stock_state_refusal(p_document_id, v_to);
  v_label := coalesce(d.document_number, p_document_id::text);
  if v_code is null then
    return case when v_derived is not null
                then jsonb_build_object('fact', v_derived, 'permission', v_perm,
                                        'actor_permitted', v_permitted) end;
  elsif v_code = 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED' then
    raise exception
      'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED: % cannot be put in discrepancy (%)', v_label, p_transition_code
      using errcode = '23514',
            hint = case when v_from = 'discrepancy' then v_stranded_hint
                        else 'Receive what arrived at the receiving site, and count the difference where it was lost.' end;
  elsif v_code = 'CLOVEERP_TRANSFER_HAS_NOT_MOVED' then
    raise exception
      'CLOVEERP_TRANSFER_HAS_NOT_MOVED: % cannot be % (%): no stock has %',
      v_label, v_to, p_transition_code,
      case when v_to = 'in_transit' then 'left the despatching site'
           else 'arrived at the receiving site' end
      using errcode = '23514',
            hint = case when v_from = 'discrepancy' then v_stranded_hint
                        else 'Despatch it from the warehouse that holds it, and receive it at the one expecting it. '
                             'A transfer order follows the stock; it is not how the stock is told where it went.' end;
  elsif v_code = 'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD' then
    raise exception
      'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD: % cannot be % (%): % is still in transit against it',
      v_label, v_to, p_transition_code, trim_scale(erp.transfer_in_transit_quantity(p_document_id))
      using errcode = '23514',
            hint = case when v_from = 'discrepancy' then v_stranded_hint
                        else 'Receive it at the site expecting it; the transfer can be closed once nothing is left on the road.' end;
  elsif v_code = 'CLOVEERP_TRANSFER_HAS_MOVED' then
    raise exception
      'CLOVEERP_TRANSFER_HAS_MOVED: % cannot be % (%): its stock has left the shelf',
      v_label, v_to, p_transition_code
      using errcode = '23514',
            hint = 'Receive it at the site expecting it, and send back what should not have gone with a new transfer.';
  elsif v_code = 'CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR' then
    raise exception
      'CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR: % cannot be % (%): no stock has been adjusted',
      v_label, v_to, p_transition_code
      using errcode = '23514',
            hint = 'Post it from the Stock adjustments screen, which writes the stock and then marks it posted.';
  elsif v_code = 'CLOVEERP_ADJUSTMENT_ALREADY_POSTED' then
    raise exception
      'CLOVEERP_ADJUSTMENT_ALREADY_POSTED: % has already changed the stock it names, so it cannot be % (%)',
      v_label, v_to, p_transition_code
      using errcode = '23514',
            hint = 'Raise a new adjustment for a further correction; the stock ledger is never written twice for one document.';
  else
    raise exception 'CLOVEERP_TRANSITION_GUARD_FAILED: the guard on % did not pass (%)',
      p_transition_code, v_code
      using errcode = '23514';
  end if;
end;
$$;

comment on function erp.require_stock_backed_move(uuid, text) is
  'Refuses a transfer order''s or stock adjustment''s move the stock did not make, and asks the '
  'type''s own permission (inventory.move at both sites, inventory.adjust) of a move that declares '
  'none, a derived move taking its authority from the fact. Returns the derived fact for the '
  'transition log, or null (20260928000000). Called by erp.transition_document() for every move; '
  'returns at once for any other document.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. erp.transition_document() asks it
-- ─────────────────────────────────────────────────────────────────────────────

-- After C3's guard and before the count sheet's, in the body 20260927100000
-- left, or stop. What it returns for a derived move joins the context the
-- move is made with, which is what erp.perform_transition() writes on the
-- transition log. Applied once: a body that already asks it is left alone.
do $transition_document$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old_decl constant text := E'  v_said   boolean;\nbegin\n';
  v_new_decl constant text := E'  v_said   boolean;\n  v_stock_derived jsonb;\nbegin\n';
  v_old constant text :=
    E'  -- A count sheet closes with its last count (20260927100000):\n';
  v_new constant text :=
       E'  -- A transfer order or stock adjustment moves because its stock did\n'
    || E'  -- (20260928000000): by what the state a move reaches means, not its code,\n'
    || E'  -- and with the type''s own permission asked of a move that declares none.\n'
    || E'  v_stock_derived := erp.require_stock_backed_move(p_document_id, p_transition_code);\n'
    || E'\n'
    || E'  -- A count sheet closes with its last count (20260927100000):\n';
  v_old_ctx constant text :=
    E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_new_ctx constant text :=
       E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n'
    || E'  -- The fact a fallback permission was answered by, for the log (20260928000000).\n'
    || E'  if v_stock_derived is not null then\n'
    || E'    v_ctx := coalesce(v_ctx, ''{}''::jsonb) || jsonb_build_object(''derived'', v_stock_derived);\n'
    || E'  end if;\n';
  v_hits integer;
begin
  if position('erp.require_stock_backed_move(' in v_def) > 0 then
    raise notice '% already asks erp.require_stock_backed_move(); left as it is', v_sig;
    return;
  end if;
  if position('CLOVEERP_TRANSFER_HAS_NOT_MOVED' in v_def) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer carries C3''s guard (20260922200000)', v_sig;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet guard anchor found % time(s)', v_sig, v_hits;
  end if;
  if position(E'CLOVEERP_TRANSFER_HAS_NOT_MOVED' in v_def) > position(v_old in v_def) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer asks C3''s guard before the count sheet''s', v_sig;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_decl, ''))) / length(v_old_decl);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_ctx, ''))) / length(v_old_ctx);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % guard context anchor found % time(s)', v_sig, v_hits;
  end if;
  if position(v_old in v_def) > position(v_old_ctx in v_def) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % builds its guard context before the count sheet''s guard', v_sig;
  end if;
  v_def := replace(v_def, v_old_decl, v_new_decl);
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old_ctx, v_new_ctx);
  execute v_def;
end
$transition_document$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The menu reads the same
-- ─────────────────────────────────────────────────────────────────────────────

do $available_transitions$
declare
  v_sig constant text := 'erp.available_transitions(text, uuid, jsonb)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'         erp.jsonlogic_bool(t.guard, p_data),\n'
    || E'         t.required_permission is null\n'
    || E'           or erp.has_permission(t.required_permission, os.entity_id, os.site_id),\n'
    || E'         t.is_automatic\n';
  v_new constant text :=
       E'         -- A transfer order''s or stock adjustment''s move the stock did not\n'
    || E'         -- make does not pass, and one with no permission of its own asks the\n'
    || E'         -- type''s, as erp.transition_document() does (20260928000000).\n'
    || E'         erp.jsonlogic_bool(t.guard, p_data)\n'
    || E'           and (p_object_type <> ''document''\n'
    || E'                or erp.stock_state_refusal(os.object_id, ts.code) is null),\n'
    || E'         case when t.required_permission is not null\n'
    || E'                then erp.has_permission(t.required_permission, os.entity_id, os.site_id)\n'
    || E'              when p_object_type = ''document''\n'
    || E'                then erp.may_move_stock_document(os.object_id)\n'
    || E'              else true\n'
    || E'         end,\n'
    || E'         t.is_automatic\n';
  v_hits integer;
begin
  if position('erp.stock_state_refusal(' in v_def) > 0 then
    raise notice '% already asks erp.stock_state_refusal(); left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % guard and permission anchor found % time(s)', v_sig, v_hits;
  end if;
  if (select p.provolatile <> 's' or p.prosecdef
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is no longer a stable invoker read', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$available_transitions$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. What is already wrong: the report
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.stock_state_mismatch_report()
returns table(finding text, document_id uuid, document_number text, document_type text,
              state text, movements integer, in_transit numeric, next_action text)
language sql
stable
security invoker
set search_path = ''
as $$
  -- Transfer orders and stock adjustments in the organisation it is run in
  -- whose state says something their stock movements do not (20260928000000).
  -- Read only. What it lists was written before the refusals of the same
  -- migration, and it is an operator's to decide about, so it is a report and
  -- not an assertion: a finding here must not fail a deploy's proof. The
  -- runbook carries the same reading as plain SQL, for the run before the
  -- deploy, when this does not exist yet.
  with t as (select erp.require_tenant_id() as tenant_id),
  docs as (
    select d.id, d.document_number, dt.code as type_code, dt.base_type_code as base,
           s.code as state, s.is_terminal, s.is_committed,
           (select count(*) from erp.stock_movement m
             where m.tenant_id = d.tenant_id and m.document_id = d.id)::integer as movements,
           (select coalesce(sum(case when m.to_status = 'in_transit' then m.quantity else 0 end), 0)
                 - coalesce(sum(case when m.from_status = 'in_transit' then m.quantity else 0 end), 0)
              from erp.stock_movement m
             where m.tenant_id = d.tenant_id and m.document_id = d.id) as in_transit,
           exists (select 1 from erp.stock_movement m
                    where m.tenant_id = d.tenant_id and m.document_id = d.id
                      and m.site_id = d.destination_site_id) as arrived,
           -- An arrival leg: out of transit, and not a return.
           exists (select 1 from erp.stock_movement m
                    where m.tenant_id = d.tenant_id and m.document_id = d.id
                      and m.from_status = 'in_transit' and not m.is_reversal) as part_arrived,
           exists (select 1 from erp.stock_movement m
                    where m.tenant_id = d.tenant_id and m.document_id = d.id and m.is_reversal) as part_returned,
           exists (select 1 from erp.stock_movement m
                    where m.tenant_id = d.tenant_id and m.document_id = d.id and not m.is_reversal
                      and not exists (select 1 from erp.stock_movement r
                                       where r.tenant_id = m.tenant_id
                                         and r.reverses_movement_id = m.id)) as stands
      from t
      join erp.document d on d.tenant_id = t.tenant_id
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.object_state os
        on os.tenant_id = d.tenant_id and os.object_type = 'document' and os.object_id = d.id
      join erp.state s on s.tenant_id = os.tenant_id and s.id = os.current_state_id
     where dt.base_type_code in ('transfer_order', 'adjustment')
  )
  select f.finding, x.id, x.document_number, x.type_code, x.state, x.movements,
         case when x.base = 'transfer_order' then x.in_transit end, f.next_action
    from docs x
    cross join lateral (
      select 'a transfer in discrepancy'::text as finding,
             case when x.in_transit > 0 and x.part_arrived
                    then 'Some of its stock arrived and some is still in transit. Count it at both sites; the operator''s repair returns only a transfer none of whose stock arrived.'
                  when x.in_transit > 0
                    then 'Stock is in transit against it. If it never left, the operator returns what is still in transit to the despatching site; if it arrived, it is for the receiving site to count.'
                  else 'Nothing is in transit against it. It cannot leave discrepancy; leave it, and count whatever it was about.' end
               as next_action
       where x.base = 'transfer_order' and x.state = 'discrepancy'
      union all
      select 'a transfer cancelled with stock still in transit',
             case when x.part_arrived
                    then 'Some of its stock arrived and some is still in transit. Count it at both sites; the operator''s repair returns only a transfer none of whose stock arrived.'
                  when x.part_returned
                    then 'Some of it has been returned already. The operator returns what is still in transit to the despatching site, or it is counted where it is.'
                  else 'The operator returns the stock to the despatching site, or it is counted where it is.' end
       where x.base = 'transfer_order' and x.is_terminal and x.state not in ('received', 'closed')
         and x.in_transit > 0
      union all
      select 'a transfer cancelled after its stock moved',
             'Its stock left the shelf and was not returned, and the order says nothing moved. Count the stock at both sites; the count is what the shelves say.'
       where x.base = 'transfer_order' and x.is_terminal and x.state not in ('received', 'closed')
         and x.in_transit <= 0 and x.stands
      union all
      select 'a transfer whose state says stock moved that its movements do not',
             'Count the stock at both sites. The order''s state is not what the shelves say; the count is.'
       where x.base = 'transfer_order'
         and ((x.state = 'in_transit' and x.movements = 0)
              or (x.state in ('received', 'closed') and (not x.arrived or x.in_transit <> 0)))
      union all
      select 'a stock adjustment posted with no movement',
             'Nothing was adjusted. Raise a new stock adjustment for the correction it was meant to make.'
       where x.base = 'adjustment' and x.is_terminal and x.is_committed and x.movements = 0
    ) f
   order by 1, 3
$$;

-- Granted as every tenant report in the diagnostic register is: to the
-- signed-in, by erp.apply_execute_grants(), for erp.run_diagnostic(). It is
-- an invoker read of the caller's own organisation under row security, and
-- names no routine that writes.
revoke all on function erp.stock_state_mismatch_report() from public, anon;

comment on function erp.stock_state_mismatch_report() is
  'Transfer orders and stock adjustments in this organisation whose state says something their stock '
  'movements do not: a transfer in discrepancy; one cancelled, or otherwise ended, with stock still in '
  'transit, or after its stock moved and was not returned; one whose state says stock moved that its '
  'movements do not; and an adjustment posted with no movement, each with what to do. Read only; a '
  'report, not an assertion, run by an operator (supabase/ops/20260928_stock_state_mismatches.sql) '
  '(20260928000000).';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('stock_state_mismatches', 'Stock documents whose state their stock did not make', 'report', 'tenant',
   'stock_state_mismatch_report', '', null, '',
   'Transfers in discrepancy, transfers cancelled with stock in transit or after it moved, transfers whose state says stock moved that did not, and stock adjustments posted with no movement.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, blurb = excluded.blurb;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The repair, for an operator to call
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.return_stranded_transit_stock(p_document_id uuid, p_reason text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid;
  d          erp.document%rowtype;
  v_state    text;
  v_terminal boolean;
  v_left     numeric;
  m          record;
  v_n        integer := 0;
  v_qty      numeric := 0;
  v_ids      bigint[] := '{}';
  v_new      bigint;
  v_operator text := session_user;
begin
  -- Stock a transfer order put in transit and then left there, by a cancel or
  -- a discrepancy clicked after despatch, back on the shelf it left
  -- (20260928000000). Each despatch leg not yet returned is reversed, which is
  -- the leg with its two ends swapped: the goods leave the transit place for
  -- the place they came from, at the despatching site, and no value moves,
  -- because a despatch leg moved none. A transfer some of whose legs were
  -- returned already has the rest returned; one any of whose stock arrived is
  -- refused, because what is on the road is then not what was despatched.
  -- The document's state is not touched.
  --
  -- An operator's repair and nobody's button: a trusted session acting inside
  -- the organisation (erp_meta.act_in_tenant), with nobody signed in. Nothing
  -- in any migration calls it. The operator is recorded in the audit trail,
  -- as the database role that ran it, with the reason; the movements carry
  -- no person, because the operator is not one of the organisation's.
  if not erp.session_is_trusted() or erp.current_principal_id() is not null then
    raise exception
      'CLOVEERP_STRANDED_STOCK_NEEDS_AN_OPERATOR: stranded transfer stock is returned by an operator, not by % signed in',
      coalesce(erp.current_principal_id()::text, current_user)
      using errcode = '42501',
            hint = 'Follow the operations runbook for stock states from a trusted session.';
  end if;
  v_tenant := erp.require_tenant_id();

  if coalesce(p_reason, '') !~ '[^[:space:][:cntrl:]]' then
    raise exception 'CLOVEERP_REVERSAL_NEEDS_A_REASON: returning stranded stock says why'
      using errcode = '23514',
            hint = 'Say why the stock is going back, and where the operator''s decision is recorded.';
  end if;

  d := erp.transfer_document(p_document_id);

  -- The document's state, locked, so nothing moves it while this runs.
  select s.code, s.is_terminal into v_state, v_terminal
    from erp.object_state os
    join erp.state s on s.id = os.current_state_id
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_document_id
     for update of os;

  v_left := erp.transfer_in_transit_quantity(p_document_id);
  if v_state is null
     or not (v_state = 'discrepancy'
             or (coalesce(v_terminal, false) and v_state not in ('received', 'closed')))
     or v_left <= 0
     or exists (select 1 from erp.stock_movement mm
                 where mm.tenant_id = v_tenant and mm.document_id = p_document_id
                   and mm.from_status = 'in_transit' and not mm.is_reversal) then
    raise exception
      'CLOVEERP_TRANSFER_NOT_STRANDED: % is %, with % in transit, and none of it is stranded',
      d.document_number, coalesce(v_state, 'in no state at all'), trim_scale(v_left)
      using errcode = '23514',
            hint = 'Only a transfer cancelled or in discrepancy with its stock in transit, none of it arrived, is repaired here.';
  end if;

  for m in
    select mm.id, mm.quantity from erp.stock_movement mm
     where mm.tenant_id = v_tenant and mm.document_id = p_document_id
       and mm.to_status = 'in_transit' and not mm.is_reversal
       and not exists (select 1 from erp.stock_movement r
                        where r.tenant_id = mm.tenant_id and r.reverses_movement_id = mm.id)
     order by mm.id
  loop
    v_new := erp.reverse_stock_movement(m.id, left(btrim(p_reason), 200));
    v_ids := v_ids || v_new;
    v_n   := v_n + 1;
    v_qty := v_qty + m.quantity;
  end loop;

  -- Who did it and why, where an auditor reads it.
  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action, object_schema, object_type,
    object_id, object_key, entity_id, site_id, after_state, reason, correlation_id)
  values (
    v_tenant, null, 'service', 'operator: ' || v_operator, 'execute', 'erp', 'document',
    p_document_id, d.document_number, d.entity_id, d.site_id,
    jsonb_build_object('repair', 'stranded transit stock returned to the despatching site',
                       'state', v_state, 'legs_returned', v_n, 'quantity_returned', v_qty,
                       'movements', to_jsonb(v_ids)),
    btrim(p_reason), erp.current_correlation_id());

  return jsonb_build_object(
    'document_id', p_document_id,
    'document_number', d.document_number,
    'state', v_state,
    'legs_returned', v_n,
    'quantity_returned', v_qty,
    'operator', v_operator,
    'in_transit', erp.transfer_in_transit_quantity(p_document_id));
end;
$$;

revoke all on function erp.return_stranded_transit_stock(uuid, text) from public, anon, authenticated;

comment on function erp.return_stranded_transit_stock(uuid, text) is
  'Returns the stock a transfer order cancelled, or sent to discrepancy, after despatch left in '
  'transit to the shelf it came from, by reversing each despatch leg not yet returned; refused if '
  'any of it arrived. No value moves and the document''s state is not touched. An operator''s repair '
  'from a trusted session inside the organisation, with the reason, recorded in the audit trail '
  'under the database role (supabase/ops/20260928_stock_state_mismatches.sql). Nothing calls it '
  '(20260928000000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.stock_state_guard_suite
--
-- One organisation, not live, installed as the demonstration is, with two
-- sites, stock at the first, an administrator and a person who may only read.
-- Moves are tried through erp_test.stock_state_try(), which undoes whatever
-- went through, so every case starts from the fixture. Six documents are put
-- where a database built before this migration could have left them, by
-- erp.perform_transition() directly, for the report and the repair.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.stock_state_try(p_document_id uuid, p_transition_code text)
returns text
language plpgsql
set search_path = ''
as $$
begin
  -- The move through the public door, then undone: 'went through', or what
  -- refused it (20260928000000).
  begin
    perform public.erp_transition_document(p_document_id, p_transition_code, 'tried by the suite');
    raise exception using message = 'CLOVEERP_STOCK_STATE_TRY_UNDO';
  exception when others then
    if sqlerrm = 'CLOVEERP_STOCK_STATE_TRY_UNDO' then
      return 'went through';
    end if;
    return sqlerrm;
  end;
end;
$$;

revoke all on function erp_test.stock_state_try(uuid, text) from public, anon;

comment on function erp_test.stock_state_try(uuid, text) is
  'Tries a document move through public.erp_transition_document and undoes it: ''went through'', or '
  'the refusal. For erp_test.stock_state_guard_suite (20260928000000).';

create or replace function erp_test.stock_state_menu_disagrees(p_document_id uuid)
returns text
language plpgsql
set search_path = ''
as $$
declare
  x      jsonb;
  v_got  text;
  v_bad  text := '';
  v_offer boolean;
begin
  -- Every move of the document's current state, offered or not by
  -- public.erp_available_transitions as the screen reads it, against what
  -- the door does with it (20260928000000). Null when they agree.
  for x in select y from jsonb_array_elements(public.erp_available_transitions(p_document_id)) y loop
    v_offer := (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean
               and not (x ->> 'is_automatic')::boolean and x ->> 'refused' is null;
    v_got := erp_test.stock_state_try(p_document_id, x ->> 'code');
    if v_offer <> (v_got = 'went through') then
      v_bad := v_bad || format('%s offered %s and %s; ', x ->> 'code', v_offer, left(v_got, 60));
    end if;
  end loop;
  return nullif(v_bad, '');
end;
$$;

revoke all on function erp_test.stock_state_menu_disagrees(uuid) from public, anon;

comment on function erp_test.stock_state_menu_disagrees(uuid) is
  'The moves the screen''s menu offers for a document that the door refuses, and those it does not '
  'offer that the door takes, or null. For erp_test.stock_state_guard_suite (20260928000000).';

create or replace function erp_test.stock_state_plant_version(
  p_states jsonb, p_transitions jsonb, p_documents uuid[])
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_old    uuid;
  v_new    uuid;
  v_mach   uuid;
  x        jsonb;
begin
  -- A version of the lifecycle the first document is on, as an organisation
  -- could write one of its own: every state and move of it, and the states
  -- (each {code, like}: flags of the state it is like) and moves (each
  -- {code, from, to, permission}) given, with the documents moved onto it
  -- where they stand. For erp_test.stock_state_guard_suite, inside its
  -- rolled-back block (20260928000000).
  select os.state_machine_version_id into v_old
    from erp.object_state os
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = p_documents[1];
  select v.state_machine_id into v_mach from erp.state_machine_version v where v.id = v_old;

  insert into erp.state_machine_version (tenant_id, state_machine_id, version, status, note)
  values (v_tenant, v_mach,
          (select max(v.version) + 100 from erp.state_machine_version v where v.state_machine_id = v_mach),
          'draft', 'An organisation''s own version, planted by the stock state guard suite')
  returning id into v_new;

  insert into erp.state (tenant_id, state_machine_version_id, code, name_key, name, description,
                         is_initial, is_terminal, is_committed, sort_order, on_enter, on_exit)
  select s.tenant_id, v_new, s.code, s.name_key, s.name, s.description,
         s.is_initial, s.is_terminal, s.is_committed, s.sort_order, s.on_enter, s.on_exit
    from erp.state s where s.state_machine_version_id = v_old;
  for x in select y from jsonb_array_elements(p_states) y loop
    insert into erp.state (tenant_id, state_machine_version_id, code, name_key, name, description,
                           is_initial, is_terminal, is_committed, sort_order, on_enter, on_exit)
    select s.tenant_id, v_new, x ->> 'code', null, initcap(x ->> 'code'), s.description,
           false, s.is_terminal, s.is_committed, s.sort_order + 1, s.on_enter, s.on_exit
      from erp.state s where s.state_machine_version_id = v_old and s.code = x ->> 'like';
  end loop;

  insert into erp.transition (tenant_id, state_machine_version_id, code, name_key, name, description,
                              from_state_id, to_state_id, guard, required_permission, effects,
                              is_automatic, sort_order)
  select t.tenant_id, v_new, t.code, t.name_key, t.name, t.description, nf.id, nt.id, t.guard,
         t.required_permission, t.effects, t.is_automatic, t.sort_order
    from erp.transition t
    join erp.state f on f.id = t.from_state_id
    join erp.state tt on tt.id = t.to_state_id
    join erp.state nf on nf.state_machine_version_id = v_new and nf.code = f.code
    join erp.state nt on nt.state_machine_version_id = v_new and nt.code = tt.code
   where t.state_machine_version_id = v_old;
  for x in select y from jsonb_array_elements(p_transitions) y loop
    insert into erp.transition (tenant_id, state_machine_version_id, code, name, from_state_id,
                                to_state_id, guard, required_permission, effects, is_automatic, sort_order)
    select v_tenant, v_new, x ->> 'code', initcap(replace(x ->> 'code', '_', ' ')), nf.id, nt.id,
           'true'::jsonb, x ->> 'permission', '[]'::jsonb, false, 900
      from erp.state nf, erp.state nt
     where nf.state_machine_version_id = v_new and nf.code = x ->> 'from'
       and nt.state_machine_version_id = v_new and nt.code = x ->> 'to';
  end loop;

  update erp.object_state os
     set state_machine_version_id = v_new,
         current_state_id = (select ns.id from erp.state ns join erp.state cs on cs.code = ns.code
                              where ns.state_machine_version_id = v_new and cs.id = os.current_state_id)
   where os.tenant_id = v_tenant and os.object_type = 'document' and os.object_id = any (p_documents);
  return v_new;
end;
$$;

revoke all on function erp_test.stock_state_plant_version(jsonb, jsonb, uuid[]) from public, anon;

comment on function erp_test.stock_state_plant_version(jsonb, jsonb, uuid[]) is
  'Plants a lifecycle version of an organisation''s own, with states and moves of its own, and moves '
  'the given documents onto it. For erp_test.stock_state_guard_suite, rolled back (20260928000000).';

create or replace function erp_test.stock_state_guard_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();   -- the administrator
  a_obs    uuid := gen_random_uuid();   -- somebody who may only read
  r        record;
  res      jsonb;
  v_obs    uuid; v_tok text;
  v_ccy    char(3);
  v_uom    uuid; v_item uuid;
  s_a      uuid; s_b uuid; l_a uuid; l_b uuid;
  t_ok uuid; t_obs uuid; t_draft uuid; t_appr uuid; t_road uuid;
  a_obs_doc uuid; a_click uuid;
  l_disc uuid; l_recv uuid; l_cancel uuid; l_road uuid; l_adj uuid; l_part uuid;
  l_arr uuid; l_half uuid;
  t_c1 uuid; t_c2 uuid; a_c1 uuid;
  v_cnt uuid; a_cnt uuid := gen_random_uuid(); v_ctok text; v_task uuid;
  v_log jsonb;
  v_fixture text;
  v_got text; v_got2 text; v_got3 text; v_got4 text;
  v_menu jsonb;
  v_bad  text; v_bad2 text;
  v_n    integer; v_n2 integer;
  v_q    numeric; v_q2 numeric;
  v_rep  text;
  v_before bigint; v_after bigint;
  v_ok   boolean;
  v_owner text := current_user;
begin
  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-ssg-' || v_hex, 'Stock state guard suite',
      'a@zz-ssg-' || v_hex || '.test', 'Suite Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    v_fixture := 'installing';
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    select e.base_currency into v_ccy from erp.entity e where e.id = r.entity_id;

    v_fixture := 'the reader';
    res := public.erp_invite_principal('reader@zz-ssg-' || v_hex || '.test', 'Stock Reader');
    v_obs := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_obs, 'observer', null, null, 'reads the stock');
    perform set_config('request.jwt.claims', json_build_object('sub', a_obs)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_fixture := 'two sites and stock at the first';
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-A', 'Despatching', 'warehouse', 'GB', 'active') returning id into s_a;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, country_code, status)
    values (r.tenant_id, r.entity_id, 'ZZ-B', 'Receiving', 'warehouse', 'GB', 'active') returning id into s_b;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_a, 'ZZ-A-BULK', 'A bulk', 'bulk', true, 'active') returning id into l_a;
    insert into erp.location (tenant_id, site_id, code, name, location_type, is_pickable, status)
    values (r.tenant_id, s_b, 'ZZ-B-IN', 'B in', 'receiving', false, 'active') returning id into l_b;
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZZ-T', 'Widget', v_uom, 'active') returning id into v_item;
    perform erp.receive_cost(v_item, s_a, 100, 500, v_ccy);
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code)
    values (r.tenant_id, r.entity_id, s_a, 'receipt_no_order', v_item, l_a, 'available', 100, v_uom, 500,
      v_ccy, 'OPENING');

    v_fixture := 'the documents';
    t_ok    := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 5))) ->> 'document_id')::uuid;
    t_obs   := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1))) ->> 'document_id')::uuid;
    t_draft := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    t_appr  := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    t_road  := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 3))) ->> 'document_id')::uuid;
    perform erp.transition_document(t_ok, 'approved', null);
    perform erp.transition_document(t_obs, 'approved', null);
    perform erp.transition_document(t_appr, 'approved', null);
    perform erp.transition_document(t_road, 'approved', null);
    perform erp.despatch_transfer(t_road);
    a_obs_doc := (erp.raise_stock_adjustment(s_a, 'DAMAGE_STORAGE', jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', l_a)), null, 'dropped') ->> 'document_id')::uuid;
    a_click   := (erp.raise_stock_adjustment(s_a, 'DAMAGE_STORAGE', jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -2, 'location_id', l_a)), null, 'dropped') ->> 'document_id')::uuid;
    perform erp.transition_document(a_obs_doc, 'approve', null);
    perform erp.transition_document(a_click, 'approve', null);

    -- Where a database built before this migration could have left them:
    -- moved by erp.perform_transition(), which asks the lifecycle and not the
    -- stock, as every click did before.
    v_fixture := 'the documents a database could already hold';
    l_disc := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1))) ->> 'document_id')::uuid;
    perform erp.perform_transition('document', l_disc, 'draft_to_discrepancy', '{}'::jsonb, 'before');
    l_recv := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 1))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_recv, 'approved', null);
    perform erp.perform_transition('document', l_recv, 'issued', '{}'::jsonb, 'before');
    perform erp.perform_transition('document', l_recv, 'in_transit', '{}'::jsonb, 'before');
    perform erp.perform_transition('document', l_recv, 'received', '{}'::jsonb, 'before');
    l_cancel := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 4))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_cancel, 'approved', null);
    perform erp.despatch_transfer(l_cancel);
    perform erp.perform_transition('document', l_cancel, 'in_transit_to_cancelled', '{}'::jsonb, 'before');
    l_road := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 6))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_road, 'approved', null);
    perform erp.despatch_transfer(l_road);
    perform erp.perform_transition('document', l_road, 'in_transit_to_discrepancy', '{}'::jsonb, 'before');
    l_part := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 7))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_part, 'approved', null);
    perform erp.despatch_transfer(l_part);
    perform erp.perform_transition('document', l_part, 'received', '{}'::jsonb, 'before');
    -- Something at the receiving site, and the goods still on the road.
    insert into erp.stock_movement (tenant_id, entity_id, site_id, movement_type, item_id, to_location_id,
      to_status, quantity, uom_id, unit_cost_minor, currency, reason_code, document_id)
    values (r.tenant_id, r.entity_id, s_b, 'receipt_no_order', v_item, l_b, 'available', 1, v_uom, 500,
      v_ccy, 'OPENING', l_part);
    -- Arrived, then cancelled: the goods are on the receiving site's shelf.
    l_arr := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_arr, 'approved', null);
    perform erp.despatch_transfer(l_arr);
    perform erp.receive_transfer(l_arr);
    perform erp.perform_transition('document', l_arr, 'received_to_cancelled', '{}'::jsonb, 'before');
    -- Cancelled on the road, and one of its two legs put back by hand since.
    l_half := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2),
                                                                   jsonb_build_object('item_id', v_item, 'quantity', 3))) ->> 'document_id')::uuid;
    perform erp.transition_document(l_half, 'approved', null);
    perform erp.despatch_transfer(l_half);
    perform erp.perform_transition('document', l_half, 'in_transit_to_cancelled', '{}'::jsonb, 'before');
    perform erp.reverse_stock_movement(
      (select min(m.id) from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = l_half), 'put back');
    l_adj := (erp.raise_stock_adjustment(s_a, 'DAMAGE_STORAGE', jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -3, 'location_id', l_a)), null, 'dropped') ->> 'document_id')::uuid;
    perform erp.transition_document(l_adj, 'approve', null);
    perform erp.perform_transition('document', l_adj, 'post', '{}'::jsonb, 'before');

    -- ── 1. Somebody who may only read moves nothing ─────────────────────────
    v_fixture := 'the reader''s moves';
    perform set_config('request.jwt.claims', json_build_object('sub', a_obs)::text, true);
    v_got  := erp_test.stock_state_try(t_obs, 'approved_to_discrepancy');
    v_got2 := erp_test.stock_state_try(t_obs, 'approved_to_cancelled');
    v_got3 := erp_test.stock_state_try(a_obs_doc, 'post');
    v_got4 := erp_test.stock_state_try(a_obs_doc, 'approved_to_cancelled');
    select string_agg(distinct rp.permission_code, ',') into v_rep
      from erp.user_role g join erp.role_permission rp on rp.role_id = g.role_id
     where g.app_user_id = v_obs and rp.permission_code like 'inventory.%';
    case_name := 'somebody who may only read stock is refused every move of a transfer and an adjustment that declares no permission';
    passed := coalesce(v_rep = 'inventory.read'
              and v_got like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got2 like 'CLOVEERP_PERMISSION_DENIED: inventory.move%'
              and v_got3 like 'CLOVEERP_PERMISSION_DENIED: inventory.adjust%'
              and v_got4 like 'CLOVEERP_PERMISSION_DENIED: inventory.adjust%'
              and erp.document_state_code(t_obs) = 'approved'
              and erp.document_state_code(a_obs_doc) = 'approved', false);
    detail := format('holds %s; to discrepancy: %s; cancel: %s; post: %s; cancel the adjustment: %s',
                     coalesce(v_rep, 'nothing'), left(v_got, 60), left(v_got2, 60), left(v_got3, 60), left(v_got4, 60));
    return next;

    -- ── 2. And is offered none of them ──────────────────────────────────────
    select count(*) into v_n
      from (select x from jsonb_array_elements(public.erp_available_transitions(t_obs)) x
            union all
            select x from jsonb_array_elements(public.erp_available_transitions(a_obs_doc)) x) y
     where (y.x ->> 'permitted')::boolean;
    v_bad := concat_ws('; ', erp_test.stock_state_menu_disagrees(t_obs), erp_test.stock_state_menu_disagrees(a_obs_doc));
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    case_name := 'and the screen offers them nothing, and what it offers is what the door takes';
    passed := v_n = 0 and coalesce(v_bad, '') = '';
    detail := format('%s move(s) marked permitted; %s', v_n, coalesce(nullif(v_bad, ''), 'the menu and the door agree'));
    return next;

    -- ── 3. Nothing enters discrepancy ───────────────────────────────────────
    v_fixture := 'discrepancy';
    v_got  := erp_test.stock_state_try(t_draft, 'draft_to_discrepancy');
    v_got2 := erp_test.stock_state_try(t_appr, 'approved_to_discrepancy');
    v_got3 := erp_test.stock_state_try(t_road, 'in_transit_to_discrepancy');
    case_name := 'a transfer is not put in discrepancy from draft, from approved or from the road';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED%'
              and v_got2 like 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED%'
              and v_got3 like 'CLOVEERP_TRANSFER_DISCREPANCY_RETIRED%', false);
    detail := format('draft: %s; approved: %s; on the road: %s', left(v_got, 70), left(v_got2, 70), left(v_got3, 70));
    return next;

    -- ── 4. One already there is not received over nothing ───────────────────
    v_got := erp_test.stock_state_try(l_disc, 'discrepancy_to_received');
    case_name := 'a transfer already in discrepancy is not marked received with nothing arrived';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%arrived at the receiving site%'
              and erp.document_state_code(l_disc) = 'discrepancy', false);
    detail := left(v_got, 140);
    return next;

    -- ── 5. Not cancelled on the road; received by the door ──────────────────
    v_fixture := 'cancelling on the road';
    v_got  := erp_test.stock_state_try(t_road, 'in_transit_to_cancelled');
    v_got2 := erp_test.stock_state_try(t_road, 'received');
    v_q := erp.transfer_in_transit_quantity(t_road);
    perform erp.receive_transfer(t_road);
    case_name := 'a transfer on the road is not cancelled or clicked received, and its stock stays in transit until the receive door books it in';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_HAS_MOVED%'
              and v_got2 like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%'
              and v_q = 3
              and erp.document_state_code(t_road) = 'received'
              and erp.transfer_in_transit_quantity(t_road) = 0, false);
    detail := format('cancel: %s; received: %s; %s in transit before the receive; then %s with %s in transit',
                     left(v_got, 60), left(v_got2, 60), trim_scale(v_q), erp.document_state_code(t_road),
                     trim_scale(erp.transfer_in_transit_quantity(t_road)));
    return next;

    -- ── 6. Not closed over nothing, and cancelled if nothing moved ─────────
    v_got  := erp_test.stock_state_try(l_recv, 'closed');
    v_got2 := erp_test.stock_state_try(l_recv, 'received_to_cancelled');
    case_name := 'a transfer marked received with nothing arrived is not closed, and may still be cancelled because nothing moved';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_HAS_NOT_MOVED%' and v_got2 = 'went through', false);
    detail := format('closed: %s; cancelled: %s', left(v_got, 90), left(v_got2, 60));
    return next;

    -- ── 7. Not closed while some of it is on the road ───────────────────────
    v_got := erp_test.stock_state_try(l_part, 'closed');
    case_name := 'a transfer is not closed while some of its stock is still in transit';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD%: 7 is still in transit%', false);
    detail := left(v_got, 140);
    return next;

    -- ── 8. An adjustment is posted by its door ──────────────────────────────
    v_fixture := 'posting by hand';
    v_got := erp_test.stock_state_try(a_click, 'post');
    select count(*) into v_n from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = a_click;
    perform erp.post_stock_adjustment(a_click);
    select count(*) into v_n2 from erp.stock_movement m where m.tenant_id = r.tenant_id and m.document_id = a_click;
    case_name := 'a stock adjustment is not clicked to posted, and its door still posts it';
    passed := coalesce(v_got like 'CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR%'
              and v_n = 0 and v_n2 = 1 and erp.document_state_code(a_click) = 'posted', false);
    detail := format('clicked: %s; %s movement(s) after the click, %s after the door; %s',
                     left(v_got, 80), v_n, v_n2, erp.document_state_code(a_click));
    return next;

    -- ── 9. The real walk, and the menu at each step ─────────────────────────
    v_fixture := 'the real walk';
    v_bad := concat_ws('; ', 'approved: ' || erp_test.stock_state_menu_disagrees(t_ok));
    select string_agg(x ->> 'code', ',' order by x ->> 'code') into v_got
      from jsonb_array_elements(public.erp_available_transitions(t_ok)) x
     where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean;
    perform erp.despatch_transfer(t_ok);
    v_bad := concat_ws('; ', v_bad, 'in transit: ' || erp_test.stock_state_menu_disagrees(t_ok));
    select string_agg(x ->> 'code', ',' order by x ->> 'code') into v_got2
      from jsonb_array_elements(public.erp_available_transitions(t_ok)) x
     where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean;
    perform erp.receive_transfer(t_ok);
    v_bad := concat_ws('; ', v_bad, 'received: ' || erp_test.stock_state_menu_disagrees(t_ok));
    select string_agg(x ->> 'code', ',' order by x ->> 'code') into v_got3
      from jsonb_array_elements(public.erp_available_transitions(t_ok)) x
     where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean;
    perform erp.transition_document(t_ok, 'closed', 'arrived in full');
    select coalesce(sum(m.quantity), 0) into v_q
      from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.document_id = t_ok and m.site_id = s_b
       and m.to_status = 'available';
    case_name := 'a transfer despatched, received and closed by hand goes through, and at each step the screen offers only what the stock has made true';
    passed := coalesce(v_bad, '') = ''
              and v_got = 'approved_to_cancelled,issued'
              and v_got2 is null
              and v_got3 = 'closed'
              and erp.document_state_code(t_ok) = 'closed'
              and v_q = 5;
    detail := format('offered when approved %s, on the road %s, received %s; %s; %s available at the receiving site; %s',
                     coalesce(v_got, 'nothing'), coalesce(v_got2, 'nothing'), coalesce(v_got3, 'nothing'),
                     erp.document_state_code(t_ok), trim_scale(v_q),
                     coalesce(nullif(v_bad, ''), 'the menu and the door agree'));
    return next;

    -- ── 10. The menu agrees with the door everywhere else ──────────────────
    v_fixture := 'the menu';
    v_bad := concat_ws('; ',
      'draft: ' || erp_test.stock_state_menu_disagrees(t_draft),
      'approved: ' || erp_test.stock_state_menu_disagrees(t_appr),
      'received by the door: ' || erp_test.stock_state_menu_disagrees(t_road),
      'posted adjustment: ' || erp_test.stock_state_menu_disagrees(a_click),
      'in discrepancy: ' || erp_test.stock_state_menu_disagrees(l_disc),
      'received over nothing: ' || erp_test.stock_state_menu_disagrees(l_recv),
      'part arrived: ' || erp_test.stock_state_menu_disagrees(l_part),
      'discrepancy on the road: ' || erp_test.stock_state_menu_disagrees(l_road),
      'approved adjustment: ' || erp_test.stock_state_menu_disagrees(a_obs_doc),
      'cancelled after arrival: ' || erp_test.stock_state_menu_disagrees(l_arr),
      'cancelled, part returned: ' || erp_test.stock_state_menu_disagrees(l_half));
    select string_agg(x ->> 'code', ',' order by x ->> 'code') into v_got
      from jsonb_array_elements(public.erp_available_transitions(a_obs_doc)) x
     where (x ->> 'permitted')::boolean and (x ->> 'guard_passes')::boolean;
    case_name := 'nothing the door refuses is offered, and everything offered goes through, on every document in every state the fixture holds';
    passed := coalesce(v_bad, '') = '' and v_got = 'approved_to_cancelled';
    detail := format('an approved adjustment offers %s; %s', coalesce(v_got, 'nothing'),
                     coalesce(nullif(v_bad, ''), 'the menu and the door agree on eleven documents'));
    return next;

    -- ── 11. The lifecycles are as they were ─────────────────────────────────
    select count(*) filter (where t.required_permission is null and m.code = 'transfer_order'),
           count(*) filter (where t.required_permission is null and m.code = 'stock_adjustment')
      into v_n, v_n2
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
     where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment');
    case_name := 'no lifecycle is changed: the permission is asked in code, and the machines still declare what they declared';
    passed := v_n = 13 and v_n2 = 2
              and (select count(*) from erp.state_machine_version v
                    join erp.state_machine m on m.id = v.state_machine_id
                   where m.tenant_id = r.tenant_id and m.code in ('transfer_order', 'stock_adjustment')) = 2;
    detail := format('%s transfer and %s adjustment transition(s) declare no permission', v_n, v_n2);
    return next;

    -- ── 12. The report lists what is already wrong ──────────────────────────
    v_fixture := 'the report';
    select count(*) into v_before from erp.stock_movement m where m.tenant_id = r.tenant_id;
    select string_agg(f.document_number || ' ' || f.finding || coalesce(' ' || trim_scale(f.in_transit), ''), '; '
                      order by f.document_number, f.finding)
      into v_rep from erp.stock_state_mismatch_report() f;
    select count(*) into v_after from erp.stock_movement m where m.tenant_id = r.tenant_id;
    select count(*) into v_n from erp.stock_state_mismatch_report() f
     where (f.document_id = l_disc and f.finding = 'a transfer in discrepancy' and f.in_transit = 0)
        or (f.document_id = l_road and f.finding = 'a transfer in discrepancy' and f.in_transit = 6)
        or (f.document_id = l_cancel and f.finding = 'a transfer cancelled with stock still in transit' and f.in_transit = 4)
        or (f.document_id = l_recv and f.finding = 'a transfer whose state says stock moved that its movements do not')
        or (f.document_id = l_part and f.finding = 'a transfer whose state says stock moved that its movements do not')
        or (f.document_id = l_adj and f.finding = 'a stock adjustment posted with no movement' and f.in_transit is null)
        or (f.document_id = l_arr and f.finding = 'a transfer cancelled after its stock moved' and f.in_transit = 0)
        or (f.document_id = l_half and f.finding = 'a transfer cancelled with stock still in transit' and f.in_transit = 3
            and f.next_action like 'Some of it has been returned already.%');
    select count(*) into v_n2 from erp.stock_state_mismatch_report() f;
    case_name := 'the report lists the eight documents a database could already hold, each once and for what is wrong with it, and nothing that is right';
    passed := v_n = 8 and v_n2 = 8 and v_before = v_after
              and not exists (select 1 from erp.stock_state_mismatch_report() f where f.next_action is null or f.next_action = '');
    detail := format('%s of 8 as expected, %s row(s): %s', v_n, v_n2, coalesce(v_rep, 'none'));
    return next;

    -- ── 13. A report, for an operator, that blocks nothing ──────────────────
    case_name := 'the report is a stable invoker read of the organisation it is run in, registered as a tenant report that no build or deploy runs as a gate';
    passed := exists (select 1 from pg_proc p where p.oid = 'erp.stock_state_mismatch_report()'::regprocedure
                        and p.provolatile = 's' and not p.prosecdef
                        and p.prosrc like '%erp.require_tenant_id()%'
                        and p.prosrc not like '%erp.authorise(%'
                        and p.prosrc !~ 'erp[a-z_]*\.return_stranded_transit_stock\(')
              and not has_function_privilege('anon', 'erp.stock_state_mismatch_report()', 'execute')
              and exists (select 1 from erp_meta.diagnostic_check d
                           where d.code = 'stock_state_mismatches' and d.kind = 'report' and d.scope = 'tenant'
                             and d.function_name = 'stock_state_mismatch_report' and not d.runs_in_ci);
    detail := 'erp.stock_state_mismatch_report(), diagnostic stock_state_mismatches';
    return next;

    -- ── 14. A lifecycle of the organisation's own is asked the same ─────────
    v_fixture := 'a lifecycle of the organisation''s own';
    t_c1 := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    perform erp.transition_document(t_c1, 'approved', null);
    perform erp.despatch_transfer(t_c1);
    t_c2 := (erp.raise_transfer_order(s_a, s_b, jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', 2))) ->> 'document_id')::uuid;
    perform erp.transition_document(t_c2, 'approved', null);
    perform erp.despatch_transfer(t_c2);
    perform erp.receive_transfer(t_c2);
    a_c1 := (erp.raise_stock_adjustment(s_a, 'DAMAGE_STORAGE', jsonb_build_array(jsonb_build_object('item_id', v_item, 'quantity', -1, 'location_id', l_a)), null, 'dropped') ->> 'document_id')::uuid;
    perform erp.transition_document(a_c1, 'approve', null);
    perform erp_test.stock_state_plant_version(
      '[{"code": "void", "like": "cancelled"}, {"code": "held", "like": "issued"}]'::jsonb,
      '[{"code": "in_transit_to_void", "from": "in_transit", "to": "void", "permission": "inventory.move"},
        {"code": "in_transit_to_held", "from": "in_transit", "to": "held", "permission": "inventory.move"},
        {"code": "received_to_void", "from": "received", "to": "void", "permission": "inventory.move"},
        {"code": "received_to_held", "from": "received", "to": "held", "permission": "inventory.move"}]'::jsonb,
      array[t_c1, t_c2]);
    perform erp_test.stock_state_plant_version(
      '[{"code": "booked", "like": "approved"}, {"code": "reopened", "like": "draft"}]'::jsonb,
      '[{"code": "approved_to_booked", "from": "approved", "to": "booked", "permission": "inventory.adjust"},
        {"code": "posted_to_reopened", "from": "posted", "to": "reopened", "permission": "inventory.adjust"}]'::jsonb,
      array[a_c1, a_click]);
    v_got  := erp_test.stock_state_try(t_c1, 'in_transit_to_void');
    v_got2 := erp_test.stock_state_try(t_c1, 'in_transit_to_held');
    v_got3 := erp_test.stock_state_try(t_c2, 'received_to_void');
    v_got4 := erp_test.stock_state_try(a_c1, 'approved_to_booked');
    v_rep  := erp_test.stock_state_try(a_click, 'posted_to_reopened');
    v_bad2 := erp_test.stock_state_try(t_c2, 'received_to_held');
    select string_agg(y.x ->> 'code', ',' order by y.x ->> 'code') into v_bad
      from (select x from jsonb_array_elements(public.erp_available_transitions(t_c1)) x
            union all select x from jsonb_array_elements(public.erp_available_transitions(t_c2)) x
            union all select x from jsonb_array_elements(public.erp_available_transitions(a_c1)) x
            union all select x from jsonb_array_elements(public.erp_available_transitions(a_click)) x) y
     where (y.x ->> 'guard_passes')::boolean
       and y.x ->> 'code' in ('in_transit_to_void', 'in_transit_to_held', 'received_to_void',
                              'approved_to_booked', 'posted_to_reopened');
    v_menu := to_jsonb(concat_ws('; ', erp_test.stock_state_menu_disagrees(t_c1), erp_test.stock_state_menu_disagrees(t_c2),
                                 erp_test.stock_state_menu_disagrees(a_c1), erp_test.stock_state_menu_disagrees(a_click)));
    case_name := 'a lifecycle of the organisation''s own, with states of its own, is refused by what its states mean and offers nothing the door refuses';
    passed := coalesce(v_got like 'CLOVEERP_TRANSFER_HAS_MOVED%'
              and v_got2 like 'CLOVEERP_TRANSFER_STILL_ON_THE_ROAD%'
              and v_got3 like 'CLOVEERP_TRANSFER_HAS_MOVED%'
              and v_got4 like 'CLOVEERP_ADJUSTMENT_POSTS_BY_ITS_DOOR%'
              and v_rep like 'CLOVEERP_ADJUSTMENT_ALREADY_POSTED%'
              and v_bad2 = 'went through'
              and v_bad is null and v_menu #>> '{}' = ''
              and erp.document_state_code(t_c1) = 'in_transit'
              and erp.transfer_in_transit_quantity(t_c1) = 2, false);
    detail := format('void on the road: %s; held on the road: %s; void after arrival: %s; booked: %s; reopened: %s; held after arrival: %s; offered %s; %s',
                     left(v_got, 50), left(v_got2, 50), left(v_got3, 50), left(v_got4, 50), left(v_rep, 50),
                     left(v_bad2, 40), coalesce(v_bad, 'none of them'),
                     coalesce(nullif(v_menu #>> '{}', ''), 'the menu and the door agree'));
    return next;

    -- ── 15. A count's own adjustment is posted on the fact, and says so ─────
    v_fixture := 'a count''s own adjustment';
    res := public.erp_invite_principal('counter@zz-ssg-' || v_hex || '.test', 'Cy Counter');
    v_cnt := (res ->> 'app_user_id')::uuid; v_ctok := res ->> 'token';
    perform erp.grant_role(v_cnt, 'stock_counter', null, null, 'counts the shelves');
    perform erp.set_config_value('inventory.count_posting', jsonb_build_object('within_tolerance', 'post'),
                                 null, null, null, null, 'the stock state guard suite');
    update erp.count_programme set tolerance_absolute = 1000000, tolerance_pct = 999
     where tenant_id = r.tenant_id and code = 'cycle_a';
    perform erp.raise_count_tasks('cycle_a');
    perform set_config('request.jwt.claims', json_build_object('sub', a_cnt)::text, true);
    perform erp.claim_invitation(v_ctok);
    select t.id, t.expected_quantity into v_task, v_q
      from erp.count_task t
     where t.tenant_id = r.tenant_id and t.status = 'open' and t.item_id = v_item and t.location_id = l_a
     limit 1;
    v_got := erp.record_count(v_task, v_q - 3)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select l.guard_data -> 'derived' into v_log
      from erp.count_task t
      join erp.state_transition_log l
        on l.tenant_id = t.tenant_id and l.object_type = 'document' and l.object_id = t.adjustment_document_id
     where t.id = v_task and l.transition_code = 'post';
    case_name := 'a count''s own adjustment is posted by a counter who may not adjust stock, on the count''s fact, and the log says so';
    passed := coalesce(v_got = 'posted'
              and v_log ->> 'fact' = 'erp.count_task_is_approved'
              and v_log ->> 'permission' = 'inventory.adjust'
              and not (v_log ->> 'actor_permitted')::boolean
              and not erp.has_permission('inventory.adjust', r.entity_id, s_a, null, v_cnt), false);
    detail := format('the count %s; the post''s log says %s', coalesce(v_got, 'was not recorded'), coalesce(v_log::text, 'nothing derived'));
    return next;

    -- ── 16. The repair is an operator's ─────────────────────────────────────
    v_fixture := 'the repair, refused';
    begin
      perform erp.return_stranded_transit_stock(l_cancel, 'the lorry never left');
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    perform erp_meta.act_in_tenant(r.tenant_id);
    begin
      perform erp.return_stranded_transit_stock(l_cancel, '   ');
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    begin
      perform erp.return_stranded_transit_stock(t_road, 'not stranded');
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    begin
      perform erp.return_stranded_transit_stock(l_recv, 'nothing on the road');
      v_got4 := 'went through';
    exception when others then v_got4 := sqlerrm; end;
    case_name := 'the repair is refused to a person signed in, without a reason, and for a transfer whose stock is not stranded';
    passed := coalesce(v_got like 'CLOVEERP_STRANDED_STOCK_NEEDS_AN_OPERATOR%'
              and v_got2 like 'CLOVEERP_REVERSAL_NEEDS_A_REASON%'
              and v_got3 like 'CLOVEERP_TRANSFER_NOT_STRANDED%'
              and v_got4 like 'CLOVEERP_TRANSFER_NOT_STRANDED%'
              and not has_function_privilege('authenticated', 'erp.return_stranded_transit_stock(uuid, text)', 'execute')
              and not has_function_privilege('anon', 'erp.return_stranded_transit_stock(uuid, text)', 'execute'), false);
    detail := format('signed in: %s; no reason: %s; received: %s; received over nothing: %s',
                     left(v_got, 60), left(v_got2, 50), left(v_got3, 50), left(v_got4, 50));
    return next;

    -- ── 17. And returns stranded stock to the shelf it left ─────────────────
    v_fixture := 'the repair';
    select coalesce(sum(b.quantity), 0) into v_q
      from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.site_id = s_a and b.stock_status = 'available';
    res := erp.return_stranded_transit_stock(l_cancel, 'the lorry never left');
    v_got := res::text;
    res := erp.return_stranded_transit_stock(l_road, 'the lorry never left');
    v_got2 := res::text;
    res := erp.return_stranded_transit_stock(l_half, 'the rest never left either');
    v_got4 := res::text;
    select coalesce(sum(b.quantity), 0) into v_q2
      from erp.stock_balance b
     where b.tenant_id = r.tenant_id and b.item_id = v_item and b.site_id = s_a and b.stock_status = 'available';
    begin
      perform erp.return_stranded_transit_stock(l_cancel, 'again');
      v_got3 := 'went through';
    exception when others then v_got3 := sqlerrm; end;
    select string_agg(f.document_number || ' ' || f.finding || coalesce(' ' || trim_scale(f.in_transit), ''), '; '
                      order by f.document_number, f.finding)
      into v_rep from erp.stock_state_mismatch_report() f;
    case_name := 'the repair puts stranded stock back on the despatching site''s shelf, once, leaves the documents where they stand, and the report no longer lists it as stranded';
    passed := coalesce(v_q2 - v_q = 4 + 6 + 3
              and (res ->> 'legs_returned')::integer = 1
              and erp.transfer_in_transit_quantity(l_half) = 0
              and exists (select 1 from erp.audit_entry ae
                           where ae.tenant_id = r.tenant_id and ae.object_id = l_cancel
                             and ae.action = 'execute' and ae.actor_label = 'operator: ' || session_user
                             and ae.reason = 'the lorry never left')
              and erp.transfer_in_transit_quantity(l_cancel) = 0
              and erp.transfer_in_transit_quantity(l_road) = 0
              and erp.document_state_code(l_cancel) = 'cancelled'
              and erp.document_state_code(l_road) = 'discrepancy'
              and (select bool_and(m.is_reversal and m.site_id = s_a and m.to_location_id = l_a
                                   and m.to_status = 'available' and m.from_status = 'in_transit')
                     from erp.stock_movement m
                    where m.tenant_id = r.tenant_id and m.document_id in (l_cancel, l_road)
                      and m.is_reversal)
              and v_got3 like 'CLOVEERP_TRANSFER_NOT_STRANDED%'
              and not exists (select 1 from erp.stock_state_mismatch_report() f where f.document_id in (l_cancel, l_half))
              and exists (select 1 from erp.stock_state_mismatch_report() f
                           where f.document_id = l_road and f.finding = 'a transfer in discrepancy' and f.in_transit = 0), false);
    detail := format('%s more available at the despatching site; %s; %s; %s; again: %s; the report then: %s',
                     trim_scale(v_q2 - v_q), v_got, v_got2, v_got4, left(v_got3, 50), coalesce(v_rep, 'nothing'));
    return next;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(v_fixture || ': ' || sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ssg-' || v_hex)
            and current_user = v_owner;
  detail := 'the organisation, its documents, movements, repairs and the reader rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.stock_state_guard_suite() from public, anon;

comment on function erp_test.stock_state_guard_suite() is
  'A transfer order and a stock adjustment refuse the moves their stock did not make '
  '(20260928000000): somebody who may only read moves nothing; nothing enters discrepancy or leaves '
  'it over nothing; a transfer on the road is not cancelled, one is not closed over nothing or with '
  'stock still in transit, and an adjustment is posted only by its door; the screen offers exactly '
  'what the door takes; the report lists what a database could already hold, and the operator''s '
  'repair returns stranded stock.';

create or replace function erp_test.assert_stock_state_guard_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
  v_ended  text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false)),
         max(s.detail) filter (where s.case_name = 'the suite ran to its end')
    into v_failed, v_total, v_detail, v_ended
    from erp_test.stock_state_guard_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_STOCK_STATE_GUARD_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A transfer order or stock adjustment took a move its stock did not make, or the screen offered one. Read the case that failed.';
  end if;
  if v_total <> 18 then
    raise exception 'CLOVEERP_STOCK_STATE_GUARD_SUITE_SHRANK: % case(s), expected 18; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('stock states: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_stock_state_guard_suite() from public, anon;

comment on function erp_test.assert_stock_state_guard_suite() is
  'Transfer orders and stock adjustments refuse the moves their stock did not make, the screen offers '
  'only what the door takes, and the report and the operator''s repair do what they say (20260928000000).';

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
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
