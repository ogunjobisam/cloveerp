set lock_timeout = '30s';

-- =============================================================================
-- 20260922160000  A bill that does not match what was received is disputed
-- -----------------------------------------------------------------------------
-- erp.match_three_way() (20260829250000_procurement_depth.sql:528) compares the
-- bill against what was received, and where the difference is outside the
-- tolerance it writes an erp.match_exception row and, if the tolerance names a
-- chain, asks for an approval.
--
-- And then nothing. The bill registers, the journal posts, the supplier is
-- credited, and the exception sits beside it on the match workbench waiting for
-- somebody to notice. The document reads Registered, which is what a bill
-- nobody has questioned reads. The one thing standing between that bill and a
-- payment run is a person remembering to look at a different screen.
--
-- The lifecycle already has the state. purchase_invoice declares `disputed`,
-- `dispute` from registered and `resolve` back (20260829250000:1225-1230), and
-- `pay` is declared only from `registered`. So a bill that lands disputed
-- cannot be paid, by the machine, without anybody writing a new rule. What was
-- missing is that nothing ever put it there.
--
-- ── WHY AT THE TRANSITION AND NOT AT THE MATCH ───────────────────────────────
--
-- The obvious place is erp.match_three_way(), beside the insert. It does not
-- work: matching happens as the invoice arrives, not in a nightly sweep
-- (erp.invoice_against():1156 — "an exception found three days later is one
-- somebody has already paid"), so the bill is still a draft when the exception
-- is raised. `dispute` runs from `registered`. There is no move to make yet.
--
-- The first moment the lifecycle offers one is the transition into registered,
-- so that is where it is taken — in the tail of erp.transition_document(),
-- beside the four onward moves already there, each of which exists for the same
-- reason: a document should not sit in a state its own facts contradict.
--
-- ── READ FROM THE MACHINE, NOT KEYED ON A DOCUMENT TYPE ──────────────────────
--
-- The test is "this document carries an unresolved exception, and its lifecycle
-- declares a move to disputed out of where it now is". Not "this is a purchase
-- invoice": purchase_invoice and sales_invoice share the base type
-- `invoice_reference`, so a base type could not tell them apart, and an
-- organisation running a promoted lifecycle of its own would be answered by
-- somebody else's. A lifecycle with no disputed state is left alone, which is
-- the honest answer for one that never declared the concept.
--
-- ── AND THE WAY BACK ─────────────────────────────────────────────────────────
--
-- `resolve` is refused while the exception is still open, rather than allowed
-- and then silently undone. Letting it through would mean a bill could be
-- walked back to registered and paid with the difference unanswered, which is
-- the hole this node closes; bouncing it back without saying so would be a
-- screen that does not do what it says.
--
-- erp.accept_match_exception() — the one route that settles a difference, after
-- the approval its tolerance asked for — resolves the bill itself once nothing
-- is left open against it. So the bill is disputed by the facts and released by
-- the decision, and neither is a button somebody presses to make the colour
-- change.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The move, as its own routine
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Named rather than inlined, for the reason the four onward moves beside it are
-- named: erp.transition_document() is long, and a rule that reads "dispute a
-- bill that does not match" belongs somewhere it can be read on its own and
-- called by anything that later needs it.

create or replace function erp.dispute_unmatched_bill(p_document_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
begin
  if not exists (select 1 from erp.match_exception x
                  where x.tenant_id = v_tenant
                    and x.invoice_document_id = p_document_id
                    and x.resolved_at is null) then
    return false;
  end if;

  -- The move this document's own lifecycle declares out of where it is, and
  -- only if its guard passes. A lifecycle that has no disputed state, or none
  -- reachable from here, is left alone rather than forced.
  if not exists (
    select 1 from erp.available_transitions('document', p_document_id,
                    erp.document_transition_context(p_document_id, 'dispute')) t
     where t.transition_code = 'dispute' and coalesce(t.guard_passes, true))
  then
    return false;
  end if;

  perform erp.perform_transition(
    'document', p_document_id, 'dispute',
    erp.document_transition_context(p_document_id, 'dispute'),
    'the bill does not match what was received');
  return true;
end;
$$;

comment on function erp.dispute_unmatched_bill(uuid) is
  'Moves a bill carrying an unresolved match exception to disputed, where its '
  'own lifecycle declares the move. Returns whether it did. The bill is '
  'disputed by the facts; erp.accept_match_exception() is what releases it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Taken at the first moment the lifecycle offers it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- In the tail, after the posting, beside the onward moves. After rather than
-- before deliberately: registering a bill is what clears goods received not
-- invoiced, and a bill that never posts leaves that account growing for ever.
-- The difference is questioned, not the receipt.

do $tail$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := E'  return v_to;\nend;\n';
  v_new constant text :=
       E'  -- A bill that does not match what was received is disputed, not left\n'
    || E'  -- reading Registered with the difference on another screen\n'
    || E'  -- (20260922160000). erp.match_three_way() raises the exception while the\n'
    || E'  -- bill is still a draft, because matching happens as the invoice arrives,\n'
    || E'  -- so this is the first moment the lifecycle offers the move.\n'
    || E'  if erp.dispute_unmatched_bill(p_document_id) then\n'
    || E'    v_to := ''disputed'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  return v_to;\nend;\n';
  v_hits integer;
begin
  if position('dispute_unmatched_bill' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % already disputes an unmatched bill', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % returns its state % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$tail$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. And it is not walked back by hand
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Beside the settle-and-pay guard 20260922150000 put in the same function, and
-- for the same reason: a state that means something about money is not a label
-- somebody sets.

do $resolve$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
    E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_new constant text :=
       E'  -- And a disputed bill is not walked back while the difference stands\n'
    || E'  -- (20260922160000). erp.accept_match_exception() is the route: it asks\n'
    || E'  -- for the approval the match tolerance named, records who accepted it,\n'
    || E'  -- and resolves the bill itself. Resolving by hand would mean a bill\n'
    || E'  -- returning to registered — and so becoming payable — with the\n'
    || E'  -- difference unanswered.\n'
    || E'  if p_transition_code = ''resolve''\n'
    || E'     and exists (select 1 from erp.match_exception x\n'
    || E'                  where x.tenant_id = v_tenant\n'
    || E'                    and x.invoice_document_id = p_document_id\n'
    || E'                    and x.resolved_at is null)\n'
    || E'  then\n'
    || E'    raise exception\n'
    || E'      ''CLOVEERP_MATCH_EXCEPTION_OPEN: % still carries % difference(s) nobody has accepted'',\n'
    || E'      coalesce(d.document_number, p_document_id::text),\n'
    || E'      (select count(*) from erp.match_exception x\n'
    || E'        where x.tenant_id = v_tenant and x.invoice_document_id = p_document_id\n'
    || E'          and x.resolved_at is null)\n'
    || E'      using errcode = ''23514'',\n'
    || E'            hint = ''Accept the difference on the match workbench once the people '' ||\n'
    || E'                   ''asked have approved it, and the bill returns to registered by itself. '' ||\n'
    || E'                   ''If the supplier is wrong, ask them for a credit note.'';\n'
    || E'  end if;\n'
    || E'\n'
    || E'  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);\n';
  v_hits integer;
begin
  if position('CLOVEERP_MATCH_EXCEPTION_OPEN' in v_def) > 0 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % already refuses a resolve over an open difference', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_TRANSITION_UNRECOGNISED: % builds its guard context % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$resolve$;

select erp.register_refusal('CLOVEERP_MATCH_EXCEPTION_OPEN',
  'Resolving a disputed bill while a difference on it is still unanswered.',
  'A bill is disputed because it does not agree with what was received, and resolving it returns it to registered, where it can be paid. Doing that with the difference still open would pay the supplier the amount nobody agreed to — which is the thing the dispute was raised to stop.',
  'Accept the difference on the match workbench, once the people the tolerance asked have approved it. The bill returns to registered by itself. If the supplier has billed wrongly, ask them for a credit note instead.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. And the decision releases it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.accept_match_exception() already resolves the exception and the older
-- ones it supersedes. It now finishes the job: if nothing is left open against
-- the bill and the bill is where this node put it, it goes back to registered.
--
-- Patched onto the end of the routine, after the row it returns has been built
-- from figures that no longer change, so the caller's answer is unaffected by
-- whether the bill moved.

do $accept$
declare
  v_sig constant text := 'erp.accept_match_exception(uuid, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'  return jsonb_build_object(\n'
    || E'    ''exception_id'', e.id,\n';
  v_new constant text :=
       E'  -- The bill this exception was raised against goes back to registered, if\n'
    || E'  -- nothing is left open on it and its lifecycle offers the move\n'
    || E'  -- (20260922160000). This is the only route back: erp.transition_document()\n'
    || E'  -- refuses a resolve by hand while a difference stands.\n'
    || E'  if e.invoice_document_id is not null\n'
    || E'     and not exists (select 1 from erp.match_exception x\n'
    || E'                      where x.tenant_id = v_tenant\n'
    || E'                        and x.invoice_document_id = e.invoice_document_id\n'
    || E'                        and x.resolved_at is null)\n'
    || E'     and exists (select 1 from erp.available_transitions(''document'', e.invoice_document_id,\n'
    || E'                       erp.document_transition_context(e.invoice_document_id, ''resolve'')) t\n'
    || E'                  where t.transition_code = ''resolve'' and coalesce(t.guard_passes, true))\n'
    || E'  then\n'
    || E'    perform erp.transition_document(e.invoice_document_id, ''resolve'',\n'
    || E'      ''the difference was accepted after approval'');\n'
    || E'  end if;\n'
    || E'\n'
    || E'  return jsonb_build_object(\n'
    || E'    ''exception_id'', e.id,\n';
  v_hits integer;
begin
  if position('20260922160000' in v_def) > 0 then
    raise exception
      'CLOVEERP_ACCEPT_UNRECOGNISED: % already releases the bill it accepted', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_ACCEPT_UNRECOGNISED: % builds its answer % time(s), not once', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$accept$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Its own fixture, and it has to be its own. erp_test.controls_finish_suite()
-- already raises match exceptions and accepts them, and passes unchanged with
-- this node in — because the bill it raises them against is never registered.
-- It stays a draft, so the move this node takes is never offered. A suite that
-- passes either way is not coverage.

create or replace function erp_test.promote_if_pending(p_change_set_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
begin
  select c.status::text into v_status from erp.change_set c where c.id = p_change_set_id;
  if v_status is null or v_status = 'promoted' then
    return coalesce(v_status, 'gone');
  end if;
  perform erp.approve_change_set(p_change_set_id);
  perform erp.promote_change_set(p_change_set_id);
  return (select c.status::text from erp.change_set c where c.id = p_change_set_id);
end;
$$;

comment on function erp_test.promote_if_pending(uuid) is
  'Promotes a change set a fixture authored, unless the bootstrap window already did.';

create or replace function erp_test.match_exception_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 7;
  v_cases  integer := 0;
  v_hex    text := replace(gen_random_uuid()::text, '-', '');
  a1       uuid := gen_random_uuid();
  r        record; t record;
  v_cs     uuid;
  v_uom    uuid; v_site uuid; v_recv uuid; v_sup uuid; v_item uuid;
  v_po     uuid; v_pol uuid; v_pol2 uuid; v_grn uuid;
  v_inv    uuid; v_ok_inv uuid;
  v_exc    uuid; v_req uuid;
  v_state  text; v_ok_state text; v_after text;
  v_moves  text; v_refusal text; v_hint text;
  v_fixture text;
begin
  begin
  select * into r from erp.provision_tenant(
    'zz-mex-' || v_hex, 'Match exception suite',
    'admin@zz-mex-' || v_hex || '.test', 'Match Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- Not live. Case 4 accepts a difference through the same administrator who
  -- raised it, and once an organisation is live nobody accepts their own
  -- (20260914062000). That rule is erp_test.controls_finish_suite()'s to prove,
  -- with the two people it stands up for the purpose; this suite is about the
  -- bill's state and stands up one.
  update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

  -- Before go-live a change set promotes as it is authored, so approving and
  -- promoting again is refused. Asked rather than assumed, because which side
  -- of the bootstrap window a fixture sits on is not this suite's subject.
  v_cs := erp.configure_finance();                  perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_inventory('average');       perform erp_test.promote_if_pending(v_cs);
  v_cs := erp.configure_procurement(1000000);       perform erp_test.promote_if_pending(v_cs);
  -- The three-way match itself: the tolerance, the purchase invoice lifecycle
  -- and the chain the tolerance asks when a difference is outside it.
  v_cs := erp.configure_procurement_controls();     perform erp_test.promote_if_pending(v_cs);

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
  insert into erp.item (tenant_id, code, name, stock_uom_id, status)
  values (r.tenant_id, 'W', 'Widget', v_uom, 'active') returning id into v_item;

  -- Twenty widgets ordered at ten pounds and twenty received, on two lines so
  -- that one bill can be wrong and the other right against the same order.
  v_po := erp.open_document('purchase_order', v_sup, null, v_site);
  v_pol := erp.add_document_line(v_po, v_item, 10, 1000, 'the line billed too high');
  v_pol2 := erp.add_document_line(v_po, v_item, 10, 1000, 'the line billed as agreed');
  perform erp.transition_document(v_po, 'submit', 'match exception suite');
  for t in select tk.id from erp.approval_task tk
             join erp.approval_request q on q.id = tk.approval_request_id
            where q.object_id = v_po and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, true, 'match exception suite'); end loop;
  if erp.object_current_state('document', v_po) = 'pending_approval' then
    perform erp.transition_document(v_po, 'approve', 'match exception suite');
  end if;
  perform erp.transition_document(v_po, 'send', 'match exception suite');
  v_grn := (erp.create_receipt_from_order(v_po) ->> 'document_id')::uuid;
  perform erp.transition_document(v_grn, 'post', 'match exception suite');

  -- ── 1. A bill outside the tolerance lands disputed, not registered ────────
  v_cases := v_cases + 1;
  v_inv := erp.open_document('purchase_invoice', v_sup, null, v_site);
  perform erp.invoice_against(v_inv, v_pol, 10, 1200);
  select x.id, x.approval_request_id into v_exc, v_req
    from erp.match_exception x
   where x.tenant_id = r.tenant_id and x.invoice_document_id = v_inv
     and x.resolved_at is null
   limit 1;
  perform erp.transition_document(v_inv, 'register', 'match exception suite');
  v_state := erp.object_current_state('document', v_inv);
  case_name := 'a bill billed above the agreed price lands disputed, where it used to read registered with the difference on another screen';
  passed := v_exc is not null and v_state = 'disputed';
  detail := format('%s difference(s) open and the bill is %s',
                   (select count(*) from erp.match_exception x
                     where x.tenant_id = r.tenant_id and x.invoice_document_id = v_inv
                       and x.resolved_at is null), v_state);
  return next;

  -- ── 2. And it cannot be paid from there ───────────────────────────────────
  -- The point of the state rather than a flag: pay is declared only out of
  -- registered, so the machine refuses the payment without a new rule.
  v_cases := v_cases + 1;
  select coalesce(string_agg(tr.transition_code, ', ' order by tr.transition_code), 'nothing')
    into v_moves from erp.available_transitions('document', v_inv) tr;
  case_name := 'and it cannot be paid from there: the lifecycle declares no way to paid out of disputed';
  passed := v_moves not like '%pay%';
  detail := format('from disputed the lifecycle offers %s', v_moves);
  return next;

  -- ── 3. And it is not walked back by hand ──────────────────────────────────
  v_cases := v_cases + 1;
  v_refusal := null; v_hint := null;
  begin
    perform erp.transition_document(v_inv, 'resolve', 'it looks fine to me');
  exception when others then
    v_refusal := sqlerrm;
    get stacked diagnostics v_hint = pg_exception_hint;
  end;
  case_name := 'and nobody resolves it by hand while the difference stands, so it cannot be walked back to payable';
  passed := v_refusal like 'CLOVEERP_MATCH_EXCEPTION_OPEN%'
        and v_hint is not null
        and erp.object_current_state('document', v_inv) = 'disputed'
        and exists (select 1 from erp_ref.refusal f
                     where f.code = 'CLOVEERP_MATCH_EXCEPTION_OPEN');
  detail := coalesce(left(v_refusal, 140), 'it was resolved by hand');
  return next;

  -- ── 4. The decision releases it ───────────────────────────────────────────
  -- Accepting is the one route back, and it asks for the approval the match
  -- tolerance named before it will take it.
  v_cases := v_cases + 1;
  for t in select tk.id from erp.approval_task tk
            where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
              and tk.status = 'pending'
  loop perform erp.decide_approval_task(t.id, true, 'the price rise was agreed'); end loop;
  perform erp.accept_match_exception(v_exc, 'agreed with the supplier');
  v_after := erp.object_current_state('document', v_inv);
  case_name := 'accepting the difference after its approval returns the bill to registered, by itself';
  passed := v_after = 'registered'
        and not exists (select 1 from erp.match_exception x
                         where x.tenant_id = r.tenant_id and x.invoice_document_id = v_inv
                           and x.resolved_at is null);
  detail := format('the bill is %s with %s difference(s) still open', v_after,
                   (select count(*) from erp.match_exception x
                     where x.tenant_id = r.tenant_id and x.invoice_document_id = v_inv
                       and x.resolved_at is null));
  return next;

  -- ── 5. And now it can be paid ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  select coalesce(string_agg(tr.transition_code, ', ' order by tr.transition_code), 'nothing')
    into v_moves from erp.available_transitions('document', v_inv) tr;
  case_name := 'and only then is it payable again: the way to paid is back';
  passed := v_moves like '%pay%';
  detail := format('from registered the lifecycle offers %s', v_moves);
  return next;

  -- ── 6. A bill that agrees is not disputed ─────────────────────────────────
  -- The other half of the claim. A guard that disputed every bill would pass
  -- every case above and be worthless.
  v_cases := v_cases + 1;
  v_ok_inv := erp.open_document('purchase_invoice', v_sup, null, v_site);
  perform erp.invoice_against(v_ok_inv, v_pol2, 10, 1000);
  perform erp.transition_document(v_ok_inv, 'register', 'match exception suite');
  v_ok_state := erp.object_current_state('document', v_ok_inv);
  case_name := 'a bill that agrees with what was received registers and stays registered';
  passed := v_ok_state = 'registered'
        and not exists (select 1 from erp.match_exception x
                         where x.tenant_id = r.tenant_id and x.invoice_document_id = v_ok_inv
                           and x.resolved_at is null);
  detail := format('billed at the agreed price, the bill is %s', v_ok_state);
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_fixture := left(sqlerrm, 300);
    end if;
  end;

  -- ── 7. Undone ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := not exists (select 1 from erp.tenant where code = 'zz-mex-' || v_hex)
        and v_fixture is null;
  detail := coalesce('the fixture stopped early: ' || v_fixture,
                     'the organisation rolled back with its order, its receipt and its bills');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SUITE_SHRANK: % case(s), expected % — %',
      v_cases, c_expected, coalesce(v_fixture, 'a case was added or lost');
  end if;
end;
$$;

create or replace function erp_test.assert_match_exception_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer; v_total integer; v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ')
           filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.match_exception_suite() s;

  if v_total <> 7 then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SUITE_SHRANK: % case(s), expected 7', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;

  if v_failed > 0 then
    raise exception 'CLOVEERP_MATCH_EXCEPTION_SUITE_FAILED: %/% case(s) failed%',
      v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A bill that does not match what was received must not read registered, and must not be payable.';
  end if;
end;
$$;

comment on function erp_test.match_exception_suite() is
  'A bill outside its match tolerance is disputed by the facts and released by the decision, not by a button.';

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
