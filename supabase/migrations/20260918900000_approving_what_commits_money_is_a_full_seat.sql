-- =============================================================================
-- Approving what commits money is a full seat
--
-- The v1 Definition of Done asks, under SEC-03, that a light user attempting to
-- approve a purchase order is denied. 20260914095000 classified
-- procurement.approve as a light permission, and a light user is what the price
-- list sells at £9 a month (£6 on Enterprise). So the requirement and the price
-- list disagreed: a person on a £9 seat could commit the company to a
-- supplier's price. Asked which of the two was wrong, the owner said the
-- attempt must be denied.
--
-- A person's seat is not a setting. erp.person_seats() derives it from the
-- permissions their roles reach: light where every one of them is light, full
-- otherwise. Classifying a permission as full therefore makes "a light user
-- does this" impossible by construction — the moment somebody is granted
-- procurement.approve they are a full user. That is the whole fix. A second
-- check refusing approval to light users would be a different mechanism for the
-- same rule, and two mechanisms for one rule is how they come apart.
--
-- What moves, and why:
--
--   * procurement.approve       light → full. It commits the company to a
--                               supplier's price.
--   * finance.approve_payment   light → full. It releases cash.
--   * sales.discount_approve    light → full. It gives away margin.
--   * master_data.approve       stays light. Approving a product or a supplier
--                               record commits nothing on its own.
--
-- Nothing else moves. inventory.count, inventory.scan, every *.read,
-- reporting.export and document.reprint are light as they were.
--
-- What it costs. A customer with twenty purchase-order approvers now needs
-- twenty full seats where twenty light ones would have done: on Standard that
-- is twenty at £49 rather than twenty at £9. The same goes for whoever approves
-- payment runs and whoever approves discounts. Nobody is locked out by it —
-- erp.require_entitlement() is the only routine that refuses on the users
-- entitlement and no invitation, grant or principal writer calls it — but
-- erp.entitlement_usage('users') counts seat = 'full' only, so those people now
-- count against the plan's included users and appear on the agreement page, the
-- breach sweep and the console as full users. That is the honest number: the
-- price list sells a light seat as somebody who looks rather than decides, and
-- committing money is deciding.
--
-- master_data.approve was deliberately left light so the light tier keeps its
-- purpose: somebody who checks that a new supplier record is properly filled in
-- is not somebody who spends money, and if every approval were full there would
-- be little left for £9 to buy. The residual risk is accepted and named:
-- approving a fake supplier record stays a light action. It is mitigated
-- because paying that supplier needs finance.approve_payment, which is now
-- full, and because a new supplier is master data that the audit trail keeps.
--
-- SEC-03 is proved here, both halves, against the doors that actually do the
-- thing rather than the nearest door to it:
--
--   * erp_test.approval_hold_suite — a person holding procurement.read and
--     reporting.read and nothing else (a light seat) calls the door that
--     approves a purchase order and is refused CLOVEERP_PERMISSION_DENIED:
--     procurement.approve; the order stays where it was; and no person in that
--     organisation who holds an approval that commits money is counted as
--     anything but a full seat.
--   * erp_test.journal_and_close_suite — the finance viewer, who holds
--     finance.read and nothing else, calls public.erp_approve_journal, which is
--     the door that writes 'posted'. What was proved before was a refusal at
--     erp_reverse_journal, and reversing a journal is not posting one.
--   * erp_test.light_users_suite — the suite that used to prove an approver is
--     light now proves the approver who commits money is full, and a new
--     fixture person who only approves master data records is still light.
--
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The reclassification
-- ═════════════════════════════════════════════════════════════════════════════

do $reclassify$
declare
  v_found text;
  v_left  text;
begin
  -- Read what is there before writing over it: the three are light today, and
  -- master_data.approve is light and stays light.
  select string_agg(format('%s is %s', p.code, coalesce(p.seat, 'unclassified')), ', ' order by p.code)
    into v_found
    from erp_ref.permission p
   where p.code in ('procurement.approve', 'finance.approve_payment', 'sales.discount_approve')
     and p.seat is distinct from 'light';
  if v_found is not null then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: the classification this migration changes is not the one it found — %', v_found
      using hint = 'Read erp_ref.permission.seat live. Another migration has already moved these; decide deliberately rather than writing over it.';
  end if;

  if (select count(*) from erp_ref.permission p
       where p.code in ('procurement.approve', 'finance.approve_payment', 'sales.discount_approve')) <> 3 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: the catalogue does not hold all three approvals this migration reclassifies'
      using hint = 'Read erp_ref.permission and name the codes that exist.';
  end if;

  update erp_ref.permission p
     set seat = 'full'
   where p.code in ('procurement.approve', 'finance.approve_payment', 'sales.discount_approve');

  -- And it landed, with master data left where it was.
  select string_agg(format('%s is %s', p.code, coalesce(p.seat, 'unclassified')), ', ' order by p.code)
    into v_left
    from erp_ref.permission p
   where (p.code in ('procurement.approve', 'finance.approve_payment', 'sales.discount_approve')
          and p.seat is distinct from 'full')
      or (p.code = 'master_data.approve' and p.seat is distinct from 'light');
  if v_left is not null then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: the reclassification did not land — %', v_left
      using hint = 'Compare erp_ref.permission.seat with what this migration writes.';
  end if;
end
$reclassify$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The words that described the old classification
--
-- Three of them said a light seat "decides an approval", which was true of
-- every approval until now and is true of one of them today. A description
-- nothing checks is a description that misleads the next person to read it.
-- ═════════════════════════════════════════════════════════════════════════════

comment on column erp_ref.permission.seat is
  'The seat a person needs to hold this permission, as the price list sells '
  'them. light: it only reads or reports, approves a master data record, or '
  'records a count. full: it creates, changes, posts, configures, administers, '
  'or approves something that commits money — an order, a payment, a discount '
  '(20260918900000). Null is unclassified, is counted as full by '
  'erp.person_seats(), and fails erp.assert_every_permission_has_a_seat().';

update erp_meta.entitlement_kind
   set counts_what = 'erp.app_user rows of kind person with status active whose current roles reach a full permission: creating, changing, posting, configuring, administering, or approving something that commits money (erp.person_seat() is full)',
       note = 'What a plan includes, and what an extra full user adds to. Until 20260914095000 this counted every active person; light users are counted apart now. Since 20260918900000 it also counts whoever approves a purchase order, a payment or a discount, because those commit the company. erp.require_entitlement() refuses on it where it is called, and no invitation or grant calls it.'
 where code = 'users';

update erp_meta.entitlement_kind
   set counts_what = 'erp.app_user rows of kind person with status active whose current roles reach only light permissions: reading and reporting, approving master data records, counting stock, using the scanner (erp.person_seat() is light)',
       note = 'Sold per person beside the plan, which includes none. Measured so an organisation is billed as sold; nothing refuses on it. Approving an order, a payment or a discount is not a light action (20260918900000).'
 where code = 'light_users';

do $hint$
declare
  v_sig    constant text := 'erp.assert_every_permission_has_a_seat()';
  v_def    text := pg_get_functiondef(v_sig::regprocedure);
  v_needle constant text := 'light if it only reads or reports, decides an approval or records a count; full otherwise.';
  v_new    constant text := 'light if it only reads or reports, approves a master data record or records a count; full otherwise. Approving something that commits money — an order, a payment, a discount — is full (20260918900000).';
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry the 20260914095000 hint exactly once', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('commits money' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its new hint', v_sig;
  end if;
end
$hint$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite that proved an approver is light
--
-- erp_test.light_users_suite built a person holding procurement.read,
-- procurement.approve, finance.approve_payment, sales.discount_approve and
-- master_data.approve and proved they were light. That case is wrong now, and
-- it is restated rather than removed: the same person, the same permissions,
-- the opposite answer and the reason for it. A second approver joins who holds
-- master_data.read and master_data.approve and nothing else, because the point
-- of leaving master_data.approve light is worth a case of its own.
-- ═════════════════════════════════════════════════════════════════════════════

do $light_fixture$
declare
  v_sig  constant text := 'erp_test.light_users_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  r      record;
  v_hits integer;
begin
  for r in
    select * from (values
      -- The sign-in.
      ($n$  s_support uuid := gen_random_uuid();
$n$,
       $r$  s_support uuid := gen_random_uuid();
  -- The master data approver (20260918900000), who approves records and
  -- commits nothing, and whose seat is therefore still light.
  s_md      uuid := gen_random_uuid();
$r$),
      -- The person.
      ($n$  u_none uuid; u_ended uuid; u_future uuid; u_invited uuid; u_support uuid; u_service uuid;
$n$,
       $r$  u_none uuid; u_ended uuid; u_future uuid; u_invited uuid; u_support uuid; u_service uuid;
  u_md uuid; t_md text;
$r$),
      -- The role.
      ($n$      (v_a, 'zz_configurer', 'Suite configurer', 'active');
$n$,
       $r$      (v_a, 'zz_configurer', 'Suite configurer', 'active'),
      (v_a, 'zz_md_approver', 'Suite master data approver', 'active');
$r$),
      -- What it reaches.
      ($n$                   ('zz_configurer', 'administration.read'), ('zz_configurer', 'administration.configure')) as x(role_code, perm)
$n$,
       $r$                   ('zz_configurer', 'administration.read'), ('zz_configurer', 'administration.configure'),
                   -- Approving a product or a supplier record commits nothing
                   -- on its own, so this role is light (20260918900000).
                   ('zz_md_approver', 'master_data.read'), ('zz_md_approver', 'master_data.approve')) as x(role_code, perm)
$r$),
      -- The invitation.
      ($n$    select x.app_user_id, x.token into u_future, t_future from erp.invite_principal('future@zzlua-' || v_tag || '.test', 'Frankie Future') x;
$n$,
       $r$    select x.app_user_id, x.token into u_future, t_future from erp.invite_principal('future@zzlua-' || v_tag || '.test', 'Frankie Future') x;
    select x.app_user_id, x.token into u_md, t_md from erp.invite_principal('mdapprover@zzlua-' || v_tag || '.test', 'Mia Master Data') x;
$r$),
      -- The grant.
      ($n$    perform erp.grant_role(u_conf,    'zz_configurer', null, null, 'configures');
$n$,
       $r$    perform erp.grant_role(u_conf,    'zz_configurer', null, null, 'configures');
    perform erp.grant_role(u_md,      'zz_md_approver', null, null, 'approves product and supplier records');
$r$),
      -- Accepting it.
      ($n$    perform set_config('request.jwt.claims', json_build_object('sub', s_future)::text, true); perform erp.claim_invitation(t_future);
$n$,
       $r$    perform set_config('request.jwt.claims', json_build_object('sub', s_future)::text, true); perform erp.claim_invitation(t_future);
    perform set_config('request.jwt.claims', json_build_object('sub', s_md)::text, true);     perform erp.claim_invitation(t_md);
$r$),
      -- Reading their seat.
      ($n$      'configurer', erp.person_seat(u_conf),
$n$,
       $r$      'configurer', erp.person_seat(u_conf),
      'master data approver', erp.person_seat(u_md),
$r$)
    ) as t(needle, replacement)
  loop
    v_hits := (length(v_def) - length(replace(v_def, r.needle, ''))) / length(r.needle);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % holds one of its fixture anchors % time(s), not once', v_sig, v_hits
        using detail = left(r.needle, 200),
              hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
    end if;
    v_def := replace(v_def, r.needle, r.replacement);
  end loop;
  execute v_def;
end
$light_fixture$;

do $light_verdicts$
declare
  v_sig  constant text := 'erp_test.light_users_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  -- The case that is wrong now. Restated with its reason, and joined by the
  -- one that says what a light approval still is.
  v_appr constant text := $n$  return query select 'a person who only approves is light',
    coalesce(v_msg is null and v_seats ->> 'approver' = 'light', false),
    coalesce(v_msg, v_seats::text);
$n$;
  v_new  constant text := $n$  -- Until 20260918900000 this case read "a person who only approves is
  -- light", and it was true: every approval was a light permission. Approving
  -- a purchase order commits the company to a supplier's price, approving a
  -- payment releases cash, approving a discount gives away margin, and the
  -- Definition of Done asks that a light user cannot do the first of those.
  -- The same person, the same five permissions, the opposite answer.
  return query select 'a person who approves orders, payments or discounts is full, however little else they hold',
    coalesce(v_msg is null and v_seats ->> 'approver' = 'full'
             and (select p.seat from erp_ref.permission p where p.code = 'procurement.approve') = 'full'
             and (select p.seat from erp_ref.permission p where p.code = 'finance.approve_payment') = 'full'
             and (select p.seat from erp_ref.permission p where p.code = 'sales.discount_approve') = 'full', false),
    coalesce(v_msg, v_seats::text);

  -- And the approval that commits nothing keeps the light tier its purpose.
  return query select 'a person who only approves product and supplier records is light',
    coalesce(v_msg is null and v_seats ->> 'master data approver' = 'light'
             and (select p.seat from erp_ref.permission p where p.code = 'master_data.approve') = 'light', false),
    coalesce(v_msg, v_seats::text);
$n$;
  -- The organisation's own totals move with the person: the approver crosses
  -- to full, and the master data approver joins the light ones.
  v_count constant text := $n$             and v_full = 4 and v_light = 4 and v_disagree is null
$n$;
  v_count_new constant text := $n$             -- Five full: the administrator, the approver who commits money
             -- (20260918900000), the poster, the configurer and the one who
             -- does both. Four light: the reporter, the counter, the person
             -- whose posting ended yesterday, and the master data approver.
             and v_full = 5 and v_light = 4 and v_disagree is null
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_appr, ''))) / length(v_appr);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % states the approver case % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_count, ''))) / length(v_count);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % pins its seat totals % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body and write the needle against it.';
  end if;

  execute replace(replace(v_def, v_appr, v_new), v_count, v_count_new);

  -- The patch 20260915011000 made — the contract, not the plan, sets the full
  -- users limit — is still in the body this one re-emitted.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position($p$res_limits -> 'full' ->> 'limit_from' = 'contract'$p$ in v_def) = 0
     or position($p$(res_limits -> 'full' ->> 'limit')::numeric = 17$p$ in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % lost the 20260915011000 contract limit case', v_sig
      using hint = 'The replacement was written against a body that did not carry the earlier patch.';
  end if;
  if position('a person who approves orders, payments or discounts is full' in v_def) = 0
     or position('a person who only approves product and supplier records is light' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take its restated cases', v_sig;
  end if;
end
$light_verdicts$;

create or replace function erp_test.assert_light_users_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- Fourteen until 20260918900000, which restated the approver's case and
  -- added the master data approver's.
  c_expected constant integer := 15;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.light_users_suite() s;
  if v_total <> c_expected then
    -- The detail comes with the count: a suite whose fixture fell over
    -- returns its cases failed rather than missing, and the reason is in them.
    raise exception E'CLOVEERP_LIGHT_USERS_SUITE_SHRANK: % case(s), expected %\n%', v_total, c_expected,
      coalesce(v_detail, '  every case passed; the count itself moved')
      using detail = 'A case was added or lost.',
            hint = 'Update the expected count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_LIGHT_USERS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail
      using hint = 'Read the failing cases above; each names what it found.';
  end if;
  return format('light users: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_light_users_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. SEC-03, first half: the door that approves a purchase order
--
-- erp_test.approval_hold_suite already stands up a live organisation with
-- procurement installed and a purchase order waiting for its approval. A light
-- user joins it: procurement.read and reporting.read, which is every light
-- permission they need to be somebody rather than nobody, and nothing else.
-- They call the door. erp.transition_document() asks erp.authorise() before it
-- asks whether the approval is pending, so what they are told is the permission
-- they do not hold, and the order does not move.
-- ═════════════════════════════════════════════════════════════════════════════

do $hold_fixture$
declare
  v_sig  constant text := 'erp_test.approval_hold_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_dec  constant text := $n$  v_approved4 text;
begin
$n$;
  v_dec_new constant text := $n$  v_approved4 text;
  -- The light user who tries to approve an order (20260918900000).
  a4            uuid := gen_random_uuid();
  v_light_role  uuid;
  v_light       uuid;
  v_light_tok   text;
  v_light_seat  text;
  v_light_err   text;
  v_po_after    text;
  v_appr_seat   text;
  v_seat_wrong  integer;
begin
$n$;
  v_probe constant text := $n$    -- Pending: not approved, even by somebody who may approve.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_pending_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
$n$;
  v_probe_new constant text := $n$    -- Pending: not approved, even by somebody who may approve.
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin
      perform erp.transition_document(v_po, 'approve');
    exception when others then
      v_pending_err := left(sqlerrm, 200);
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- SEC-03 (20260918900000). A light user tries the door that approves a
    -- purchase order. The role is made while the organisation is put back into
    -- its bootstrap window, because a live organisation changes a role through
    -- a promoted change set and this is a fixture, not a change.
    perform erp_test.reopen_bootstrap_window(r.tenant_id);
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zz_light_reader', 'Suite light reader', 'active')
    returning id into v_light_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code) values
      (r.tenant_id, v_light_role, 'procurement.read'),
      (r.tenant_id, v_light_role, 'reporting.read');
    perform erp_test.close_bootstrap_window(r.tenant_id);
    res := public.erp_invite_principal('light@zz-hold-' || v_hex || '.test', 'Lena Light');
    v_light := (res ->> 'app_user_id')::uuid;
    v_light_tok := res ->> 'token';
    perform erp.grant_role(v_light, 'zz_light_reader', null, null, 'reads orders and nothing else');
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(v_light_tok);
    begin
      perform public.erp_transition_document(v_po, 'approve', 'a light user tries to approve the order');
      v_light_err := 'the order was approved';
    exception when others then
      v_light_err := left(sqlerrm, 200);
    end;
    -- Read back as the administrator: the seats are read from the tables the
    -- light user cannot see.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_light_seat := erp.person_seat(v_light);
    v_appr_seat := erp.person_seat(v_second);
    select s.code into v_po_after
      from erp.object_state os
      join erp.state s on s.id = os.current_state_id
     where os.tenant_id = r.tenant_id and os.object_type = 'document'
       and os.object_id = v_po;
    -- And the other half of the requirement, over everybody in the
    -- organisation rather than the one person: holding an approval that
    -- commits money is holding a full seat.
    select count(*) into v_seat_wrong
      from erp.person_seats(r.tenant_id) ps
     where ps.seat <> 'full'
       and exists (select 1 from erp.effective_permission ep
                    where ep.tenant_id = r.tenant_id
                      and ep.app_user_id = ps.app_user_id
                      and ep.permission_code in ('procurement.approve', 'finance.approve_payment',
                                                 'sales.discount_approve'));
$n$;
  v_case constant text := $n$  case_name := 'while its approval is pending a document is not approved, even by somebody who may approve';
  passed := coalesce(v_state is null and v_pending_err like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%', false);
  detail := coalesce(v_state, v_pending_err, 'the pending order was approved');
  return next;
$n$;
  v_case_new constant text := $n$  case_name := 'while its approval is pending a document is not approved, even by somebody who may approve';
  passed := coalesce(v_state is null and v_pending_err like 'CLOVEERP_DOCUMENT_APPROVAL_PENDING%', false);
  detail := coalesce(v_state, v_pending_err, 'the pending order was approved');
  return next;

  case_name := 'a light user is refused the door that approves a purchase order, and nobody who may approve one holds a light seat';
  passed := coalesce(v_state is null
            and v_light_seat = 'light'
            and v_light_err like 'CLOVEERP_PERMISSION_DENIED: procurement.approve%'
            and v_po_after = 'pending_approval'
            and v_appr_seat = 'full'
            and v_seat_wrong = 0, false);
  detail := coalesce(v_state, format('the light user holds a %s seat; the door said %s; the order is %s; the approver holds a %s seat; %s person(s) approve money on a light seat',
                                     coalesce(v_light_seat, 'no'), coalesce(v_light_err, 'nothing'),
                                     coalesce(v_po_after, 'nowhere'), coalesce(v_appr_seat, 'no'),
                                     coalesce(v_seat_wrong::text, 'an unknown number of')));
  return next;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_dec, ''))) / length(v_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % ends its declarations % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_probe, ''))) / length(v_probe);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % holds the pending-approval probe % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_case, ''))) / length(v_case);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % states the pending-approval case % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;

  execute replace(replace(replace(v_def, v_dec, v_dec_new), v_probe, v_probe_new), v_case, v_case_new);

  -- The patches this body already carried are still in it: who grants the
  -- suite's roles (20260914065000), two-person approval switched off
  -- (20260914098000), and the lone approver who is asked rather than refused
  -- (20260916270000).
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('nobody changes their own roles once the organisation is live' in v_def) = 0
     or position('erp_test.administrator_approval_off(r.tenant_id)' in v_def) = 0
     or position('they are asked rather than refused' in v_def) = 0
     or position('a light user is refused the door that approves a purchase order' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % lost an earlier patch, or did not take this one', v_sig
      using hint = 'Compare the re-emitted body with the patches 20260914065000, 20260914098000 and 20260916270000 made.';
  end if;
end
$hold_fixture$;

create or replace function erp_test.assert_approval_hold_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- Sixteen until 20260918900000, which added the light user at the door.
  c_expected constant integer := 17;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.approval_hold_suite() s;
  if v_total <> c_expected then
    -- With the failing cases, so a fixture that fell over says so here rather
    -- than only in the count.
    raise exception E'CLOVEERP_APPROVAL_HOLD_SUITE_SHRANK: % case(s), expected %\n%', v_total, c_expected,
      coalesce(v_detail, '  every case passed; the count itself moved')
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_APPROVAL_HOLD_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail;
  end if;
  return format('approval hold: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.assert_approval_hold_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. SEC-03, second half: the door that posts a journal
--
-- What was proved before was that the finance viewer — finance.read and nothing
-- else, which is a light seat — could not reverse a posted journal. Reversing
-- is not posting. public.erp_approve_journal is the door that writes 'posted',
-- and it asks for finance.close_period. The same viewer now calls it, on the
-- journal the clerk has waiting for approval, and the case that lists journals
-- a few lines later reads that journal as still submitted.
-- ═════════════════════════════════════════════════════════════════════════════

do $journal_light$
declare
  v_sig  constant text := 'erp_test.journal_and_close_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_dec  constant text := $n$  ok_yearend  boolean; msg_yearend  text;
begin
$n$;
  v_dec_new constant text := $n$  ok_yearend  boolean; msg_yearend  text;
  ok_light    boolean; msg_light    text;
begin
$n$;
  v_probe constant text := $n$    select * into d from erp_test.journal_door_as(s_viewer, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j4, 'reason', 'The viewer reverses one'));
    ok_signed := ok_signed and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.post%', false);
    msg_signed := msg_signed || '; viewer reverses: ' || coalesce(d.err_message, d.outcome::text, 'no answer');
$n$;
  v_probe_new constant text := $n$    select * into d from erp_test.journal_door_as(s_viewer, 'erp_reverse_journal', jsonb_build_object(
      'journal_id', v_j4, 'reason', 'The viewer reverses one'));
    ok_signed := ok_signed and coalesce(d.err_state = '42501' and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.post%', false);
    msg_signed := msg_signed || '; viewer reverses: ' || coalesce(d.err_message, d.outcome::text, 'no answer');

    -- SEC-03 (20260918900000). The viewer holds finance.read and nothing else,
    -- which is a light seat, and erp_approve_journal is the door that writes
    -- 'posted'. The journal it is tried on is the one the clerk submitted; the
    -- case below that lists journals reads it as submitted still.
    select * into d from erp_test.journal_door_as(s_viewer, 'erp_approve_journal',
      jsonb_build_object('journal_id', v_j6));
    ok_light := coalesce(d.err_state = '42501'
                and d.err_message like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%', false)
      and (select p.seat from erp_ref.permission p where p.code = 'finance.read') = 'light'
      and (select p.seat from erp_ref.permission p where p.code = 'finance.close_period') = 'full'
      and (select p.seat from erp_ref.permission p where p.code = 'finance.post') = 'full';
    msg_light := 'viewer posts: ' || coalesce(d.err_message, d.outcome::text, 'no answer')
      || format('; finance.read is %s, finance.post %s, finance.close_period %s',
                (select coalesce(p.seat, 'unclassified') from erp_ref.permission p where p.code = 'finance.read'),
                (select coalesce(p.seat, 'unclassified') from erp_ref.permission p where p.code = 'finance.post'),
                (select coalesce(p.seat, 'unclassified') from erp_ref.permission p where p.code = 'finance.close_period'));
$n$;
  v_case constant text := $n$  case_name := 'a period with no close tasks is refused closing by name, with the way to open its close';
$n$;
  v_case_new constant text := $n$  case_name := 'a light user who only reads the ledger is refused the door that posts a journal';
  passed := v_state_a is null and coalesce(ok_light, false);
  detail := coalesce(v_state_a, msg_light, 'no answer');
  return next;

  case_name := 'a period with no close tasks is refused closing by name, with the way to open its close';
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_dec, ''))) / length(v_dec);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % ends its declarations % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_probe, ''))) / length(v_probe);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % holds the viewer''s reversal probe % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_case, ''))) / length(v_case);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % states the no-close-tasks case % time(s), not once', v_sig, v_hits
      using hint = 'Read the live body with pg_get_functiondef and write the needle against it.';
  end if;

  execute replace(replace(replace(v_def, v_dec, v_dec_new), v_probe, v_probe_new), v_case, v_case_new);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp_test.administrator_approval_off(ra.tenant_id)' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % lost the 20260914098000 patch', v_sig
      using hint = 'The replacement was written against a body that did not carry the earlier patch.';
  end if;
  if position('is refused the door that posts a journal' in v_def) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the light user''s case', v_sig;
  end if;
end
$journal_light$;

create or replace function erp_test.assert_journal_and_close_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- Sixteen until 20260918900000, which added the light user at the door that
  -- posts.
  c_expected constant integer := 17;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.journal_and_close_suite() s;
  if v_total <> c_expected then
    raise exception E'CLOVEERP_JOURNAL_AND_CLOSE_SUITE_SHRANK: % case(s), expected %\n%', v_total, c_expected,
      coalesce(v_detail, '  every case passed; the count itself moved')
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_JOURNAL_AND_CLOSE_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case before the door: a journal or a close that should be refused went through, or one that should go through was refused.';
  end if;
  return format('journals and close: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.assert_journal_and_close_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_every_permission_has_a_seat();
select erp_test.assert_light_users_suite();
select erp_test.assert_approval_hold_suite();
select erp_test.assert_journal_and_close_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
