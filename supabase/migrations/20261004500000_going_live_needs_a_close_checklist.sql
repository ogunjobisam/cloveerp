set lock_timeout = '30s';

-- =============================================================================
-- 20261004500000  Going live needs a close checklist
-- -----------------------------------------------------------------------------
-- F6 (docs/spec/simplification-review.md §7 Finance, PR12).
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- The four unwaivable ties — trial_balance, inventory_valued,
-- subledgers_reconcile, ageing_agrees (erp.close_tie_check()) — are the v1
-- master gate, and for a real organisation they gated nothing. They run only
-- as tasks of a period's close checklist, which erp.open_period_close() raises
-- from erp.close_task_template, and only erp.configure_period_close() writes
-- that template. Neither route by which an organisation is built installed it:
-- erp.ensure_demo_configuration() installs finance, master data, procurement,
-- sales, inventory, receivables and tax, and the onboarding interview's books
-- step installs finance alone. erp.go_live() asked about dead configuration
-- and a second administrator, and not about a checklist. So an organisation
-- went live, traded, and first learned it had no close when a close was
-- refused (CLOVEERP_NO_CLOSE_TEMPLATE); and an organisation whose checklist
-- had lost a tie closed without it.
--
-- The build could not see it: supabase/ci/close_month.sh installs the module
-- itself before closing ci-demo, and erp.demonstration_catch_up() installs it
-- retroactively. A customer got neither.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   A. erp.close_ties_missing(tenant): the ties an organisation with an active
--      ledger has no active checklist task for. Nothing for an organisation
--      with no ledger: it has nothing to close.
--   B. erp.go_live() refuses while any is missing (CLOVEERP_NO_CLOSE_CHECKLIST),
--      after the single-administrator check, and names them.
--      public.erp_tenant_state() says so before the button, as it already says
--      how many administrators there are.
--   C. The two installers install it: erp.ensure_demo_configuration() beside
--      tax, and erp_ai.accept_interview()'s books step beside finance, inside
--      the same block, so a refusal there keeps nothing, as it does for
--      finance. Each asks first, as the catch-up does, so a second call
--      installs nothing twice.
--   D. Three suites that take an organisation with books live now install the
--      checklist first, which is what the product now asks of anybody; four
--      that built an organisation as the demonstration is and then installed
--      the checklist no longer install it twice.
--
-- The rule is a go-live refusal and not a finding of
-- erp.dead_configuration_report(), which the spec first proposed. That report
-- is asserted across every organisation on every deploy
-- (erp.platform_assurance(), 'dead_configuration', platform scope), so a
-- finding would have turned the deploy red over any organisation already
-- building its books without a checklist. Going live is where it matters, and
-- an organisation already live keeps running: nothing here refuses a posting,
-- a close or a change.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The ties an organisation's checklist does not carry
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.close_ties_missing(p_tenant_id uuid)
returns text[]
language sql
stable
set search_path = ''
as $$
  -- The task codes erp.close_tie_check() stamps as ties. Listed here because
  -- that function is a case expression and cannot be enumerated; the suite
  -- proves each code listed is one it knows.
  select coalesce(array_agg(t.code order by t.code), '{}'::text[])
    from unnest(array['ageing_agrees', 'inventory_valued',
                      'subledgers_reconcile', 'trial_balance']) as t(code)
   where exists (select 1 from erp.ledger l
                  where l.tenant_id = p_tenant_id and l.status = 'active')
     and not exists (select 1 from erp.close_task_template ct
                      where ct.tenant_id = p_tenant_id and ct.code = t.code
                        and ct.status = 'active')
$$;

revoke all on function erp.close_ties_missing(uuid) from public, anon;

comment on function erp.close_ties_missing(uuid) is
  'The unwaivable close ties an organisation with an active ledger has no active checklist task for '
  '(20261004500000). erp.go_live() refuses while any is missing; erp.configure_period_close() installs them.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. Going live asks for them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.go_live()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_env    uuid;
  v_live   boolean;
  v_dead   integer;
  v_detail text;
  v_admins integer;
  v_ties   text[];
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'environment', null);

  v_env := erp.self_environment_id(v_tenant);
  select e.is_live into v_live from erp.environment e where e.id = v_env;

  if v_live then
    raise exception 'CLOVEERP_ALREADY_LIVE: this tenant is already live'
      using errcode = '23514',
      hint = 'Configuration changes go through erp.promote_change_set().';
  end if;

  -- Going live over configuration that is known to be wrong would make the
  -- first governed change a repair. The report is scoped by row-level security
  -- to this tenant, so this asks about this tenant only.
  select count(*), string_agg(format('%s (%s)', finding, reference), '; ')
    into v_dead, v_detail
    from erp.dead_configuration_report();

  if v_dead > 0 then
    raise exception 'CLOVEERP_DEAD_CONFIGURATION: % finding(s) before go-live: %',
      v_dead, v_detail
      using errcode = '23514',
      hint = 'erp.dead_configuration_report() lists them in full.';
  end if;

  -- After this call the author of a change set may no longer approve it, so a
  -- tenant with one administrator would go live unable to change anything.
  -- Saying so now is better than saying it at the next promotion.
  select count(distinct ur.app_user_id) into v_admins
    from erp.user_role ur
    join erp.role_permission rp
      on rp.tenant_id = ur.tenant_id and rp.role_id = ur.role_id
    join erp.app_user u
      on u.tenant_id = ur.tenant_id and u.id = ur.app_user_id
   where ur.tenant_id = v_tenant
     and rp.permission_code = 'administration.promote'
     and u.status in ('active', 'invited')
     and (ur.valid_to is null or ur.valid_to >= current_date);

  if v_admins < 2 then
    raise exception
      'CLOVEERP_SINGLE_ADMINISTRATOR: going live needs a second principal '
      'holding administration.promote; found %', v_admins
      using errcode = '23514',
      hint = 'erp.invite_principal() and erp.grant_role(), then call this again.';
  end if;

  -- An organisation with books goes live with the close that checks them
  -- (20261004500000). Without the ties its first close would be refused, or
  -- would run without them, and a live organisation's checklist is a change set.
  v_ties := erp.close_ties_missing(v_tenant);
  if cardinality(v_ties) > 0 then
    raise exception
      'CLOVEERP_NO_CLOSE_CHECKLIST: going live needs a close checklist that checks the books; '
      'it does not carry %', array_to_string(v_ties, ', ')
      using errcode = '23514',
      hint = 'Install Period close on the Configuration screen (erp_configure_period_close()), then go live again.';
  end if;

  update erp.environment set is_live = true, updated_at = now()
   where id = v_env;

  return jsonb_build_object('tenant_id', v_tenant,
                            'environment_id', v_env,
                            'is_live', true,
                            'administrators', v_admins);
end;
$$;

comment on function erp.go_live is
  'Closes a tenant''s bootstrap window: from here configuration changes only '
  'through a promoted change set, and the author of one may not approve it. '
  'Refuses over dead configuration, a tenant with a single administrator, '
  'because that tenant would be live and unable to change, and books without '
  'the close checklist''s ties (20261004500000).';

select erp.register_refusal('CLOVEERP_NO_CLOSE_CHECKLIST',
  'Going live with books whose close checklist does not carry the checks every close must pass.',
  'A period is closed by its checklist, and four of its checks — the trial balance, the inventory valuation, the subledgers and the ageing — cannot be waived. An organisation that goes live without them would find its first close refused, or closing without them.',
  'Install Period close on the Configuration screen, then go live again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. And the screen can say so first
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_tenant_state()
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object(
    'is_live', erp.tenant_is_live(),
    'environment', (select jsonb_build_object('environment_id', e.id, 'code', e.code,
                                              'name', e.name, 'is_live', e.is_live)
                      from erp.environment e
                     where e.tenant_id = erp.current_tenant_id() and e.is_self),
    -- erp.go_live() refuses below two, so a screen can say why before the
    -- button fails rather than after.
    'administrators', (select count(distinct ur.app_user_id)
                         from erp.user_role ur
                         join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                        where ur.tenant_id = erp.current_tenant_id()
                          and r.code = 'administrator'),
    -- And refuses books without the close's ties (20261004500000).
    'close_ties_missing', to_jsonb(erp.close_ties_missing(erp.current_tenant_id())),
    'dead_configuration', coalesce((
      select jsonb_agg(jsonb_build_object('finding', d.finding, 'detail', d.detail))
        from erp.dead_configuration_report() d), '[]'::jsonb))
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The installers install it
-- ─────────────────────────────────────────────────────────────────────────────

do $installers$
declare
  v_sigs constant text[] := array[
    'erp.ensure_demo_configuration(uuid,uuid)',
    'erp_ai.accept_interview(uuid)'];
  v_pairs constant text[] := array[
    -- ensure_demo_configuration: beside tax.
    $o$    perform erp.configure_tax('GB', 20);
    v_did := v_did || '"tax"'::jsonb;
  end if;
$o$,
    $n$    perform erp.configure_tax('GB', 20);
    v_did := v_did || '"tax"'::jsonb;
  end if;

  -- The close checklist, so the demonstration closes with the ties from the
  -- day it is built rather than from the day the catch-up first closes it
  -- (20261004500000).
  if not exists (select 1 from erp.change_set c where c.tenant_id = p_tenant_id and c.code = 'period-close') then
    perform erp.configure_period_close();
    v_did := v_did || '"period-close"'::jsonb;
  end if;
$n$,
    -- accept_interview: the books step, beside finance and inside its block.
    $o$              perform erp.configure_finance(null::integer, null::character, v_first);
            end if;
$o$,
    $n$              perform erp.configure_finance(null::integer, null::character, v_first);
            end if;

            -- Books go live with the close that checks them (20261004500000).
            if not exists (select 1 from erp.change_set c
                            where c.tenant_id = v_tenant and c.code = 'period-close') then
              perform erp.configure_period_close();
            end if;
$n$];
  v_def  text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_sigs, 1) loop
    v_def := pg_get_functiondef(v_sigs[v_i]::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sigs[v_i], v_hits;
    end if;
    execute replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
end
$installers$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The suites that take books live install the checklist first
-- ─────────────────────────────────────────────────────────────────────────────

do $suites$
declare
  v_sigs constant text[] := array[
    'erp_test.bootstrap_window_suite()',
    'erp_test.addendum_b_promotion_suite()',
    'erp_test.interview_ease_suite()',
    'erp_test.ageing_tie_suite()',
    'erp_test.close_and_cash_screens_suite()',
    'erp_test.close_and_ties_read_suite()',
    'erp_test.demonstration_reopen_suite()'];
  v_pairs constant text[] := array[
    $o$  perform erp.configure_inventory('average');
$o$,
    $n$  perform erp.configure_inventory('average');
  perform erp.configure_period_close();
$n$,
    $o$  perform erp.configure_finance();
$o$,
    $n$  perform erp.configure_finance();
  perform erp.configure_period_close();
$n$,
    $o$    perform erp_test.administrator_approval_off(t5);
    perform erp.configure_finance();
$o$,
    $n$    perform erp_test.administrator_approval_off(t5);
    perform erp.configure_finance();
    perform erp.configure_period_close();
$n$,
    -- Built as the demonstration is, which now installs the checklist itself.
    $o$    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
    perform erp.configure_period_close();
$o$,
    $n$    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
$n$,
    $o$    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    perform erp.configure_period_close();
$o$,
    $n$    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
$n$,
    $o$    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
    perform erp.configure_period_close();
$o$,
    $n$    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);
$n$,
    $o$  perform erp.ensure_demo_configuration(v_tenant, v_admin);
  perform erp.configure_period_close();
$o$,
    $n$  perform erp.ensure_demo_configuration(v_tenant, v_admin);
$n$];
  v_def  text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_sigs, 1) loop
    v_def := pg_get_functiondef(v_sigs[v_i]::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sigs[v_i], v_hits;
    end if;
    execute replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
end
$suites$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof: erp_test.close_checklist_required_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.close_checklist_required_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid();
  b2 uuid := gen_random_uuid();
  c1 uuid := gen_random_uuid();
  d1 uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  v jsonb; res jsonb;
  t_a uuid; t_b uuid; t_c uuid; t_d uuid; v_admin uuid;
  v_u uuid; v_tok text; v_cs uuid; s uuid;
  v_err text;
  v_ties text[];
begin
  begin
    insert into auth.users (id, email) values
      (a1, 'first@zzclose-a-' || v_tag || '.test'),
      (a2, 'second@zzclose-a-' || v_tag || '.test'),
      (b1, 'first@zzclose-b-' || v_tag || '.test'),
      (b2, 'second@zzclose-b-' || v_tag || '.test'),
      (c1, 'first@zzclose-c-' || v_tag || '.test'),
      (d1, 'admin@zzclose-d-' || v_tag || '.test');

    -- 1. The list is the ties, and nothing else.
    v_step := 'reading the ties';
    v_cases := v_cases + 1;
    case_name := 'every task go-live asks for is one the close stamps as a tie';
    passed := (select bool_and(erp.close_tie_check(t) is not null)
                 from unnest(array['ageing_agrees', 'inventory_valued',
                                   'subledgers_reconcile', 'trial_balance']) t)
          and cardinality(erp.close_ties_missing(gen_random_uuid())) = 0;
    detail := 'four codes, each a tie; an organisation with no ledger is missing none';
    return next;

    -- zzclose-a: books, two administrators, no checklist.
    v_step := 'building an organisation with books and no checklist';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v := erp.onboard_tenant('Close checklist A', 'zzclose-a-' || v_tag);
    t_a := (v ->> 'tenant_id')::uuid;
    perform erp_test.administrator_approval_off(t_a);
    perform erp.configure_finance();
    v := public.erp_invite_principal('second@zzclose-a-' || v_tag || '.test', 'Second Admin');
    v_u := (v ->> 'app_user_id')::uuid; v_tok := v ->> 'token';
    perform erp.grant_role(v_u, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    -- 2. The screen says so before the button.
    v_cases := v_cases + 1;
    case_name := 'the organisation''s state names the ties its books would go live without';
    v := public.erp_tenant_state();
    passed := (select array_agg(x order by x) from jsonb_array_elements_text(v -> 'close_ties_missing') x)
              = array['ageing_agrees', 'inventory_valued', 'subledgers_reconcile', 'trial_balance'];
    detail := coalesce(v ->> 'close_ties_missing', 'no close_ties_missing');
    return next;

    -- 3. And the button refuses, naming them.
    v_step := 'going live without a checklist';
    v_err := null;
    begin
      perform erp.go_live();
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'go-live refuses books with no close checklist and names every tie';
    passed := v_err like 'CLOVEERP_NO_CLOSE_CHECKLIST:%'
          and v_err like '%trial_balance%' and v_err like '%inventory_valued%'
          and v_err like '%subledgers_reconcile%' and v_err like '%ageing_agrees%'
          and not erp.tenant_is_live(t_a);
    detail := coalesce(left(v_err, 240), 'it went live');
    return next;

    -- 4. One press answers it.
    v_step := 'installing the checklist';
    perform public.erp_configure_period_close();
    v_cases := v_cases + 1;
    case_name := 'one press of Period close installs every tie';
    passed := cardinality(erp.close_ties_missing(t_a)) = 0
          and jsonb_array_length(public.erp_tenant_state() -> 'close_ties_missing') = 0;
    detail := format('missing %s', erp.close_ties_missing(t_a));
    return next;

    -- 5. A checklist that has lost a tie is refused for that tie alone.
    v_step := 'taking a tie out of the checklist';
    v_cs := erp.create_change_set('zzclose-no-tb', 'Without the trial balance', null);
    perform erp.add_change_set_item(v_cs, 'close_task', 'trial_balance',
              jsonb_build_object('code', 'trial_balance'), 'remove', null, null);
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v_err := null;
    begin
      perform erp.go_live();
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a checklist without a tie is refused, naming that tie alone';
    passed := v_err like 'CLOVEERP_NO_CLOSE_CHECKLIST:%'
          and v_err like '%trial_balance%' and v_err not like '%inventory_valued%'
          and not erp.tenant_is_live(t_a);
    detail := coalesce(left(v_err, 240), 'it went live');
    return next;

    -- 6. Put back, it goes live.
    v_step := 'putting the tie back and going live';
    v_cs := erp.create_change_set('zzclose-tb', 'The trial balance again', null);
    perform erp.add_change_set_item(v_cs, 'close_task', 'trial_balance',
              jsonb_build_object('code', 'trial_balance', 'name', 'Trial balance reviewed and signed',
                                 'seq', 90), 'upsert', null, null);
    perform erp.submit_change_set(v_cs);
    perform erp.approve_change_set(v_cs);
    perform erp.promote_change_set(v_cs);
    v := erp.go_live();
    v_cases := v_cases + 1;
    case_name := 'with every tie in its checklist the organisation goes live';
    passed := (v ->> 'is_live')::boolean and erp.tenant_is_live(t_a);
    detail := v::text;
    return next;

    -- 7. No books, nothing to close: this rule does not stand in the way.
    v_step := 'going live with no books';
    perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
    v := erp.onboard_tenant('Close checklist B', 'zzclose-b-' || v_tag);
    t_b := (v ->> 'tenant_id')::uuid;
    perform erp_test.administrator_approval_off(t_b);
    v := public.erp_invite_principal('second@zzclose-b-' || v_tag || '.test', 'Second Admin');
    v_u := (v ->> 'app_user_id')::uuid; v_tok := v ->> 'token';
    perform erp.grant_role(v_u, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', b2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
    v_err := null;
    begin
      perform erp.go_live();
    exception when others then v_err := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'an organisation with no ledger is not refused for a checklist';
    passed := v_err is null and erp.tenant_is_live(t_b);
    detail := coalesce(left(v_err, 240), 'went live');
    return next;

    -- 8. The onboarding interview's books come with the checklist.
    v_step := 'setting up the books through the interview';
    perform set_config('request.jwt.claims', json_build_object('sub', c1)::text, true);
    v := erp.onboard_tenant('Close checklist C', 'zzclose-c-' || v_tag);
    t_c := (v ->> 'tenant_id')::uuid;
    perform erp_test.administrator_approval_off(t_c);
    s := (public.erp_start_interview('close-c') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s, 'posting.item_classes', '[{"code":"FG","name":"Finished good"}]'::jsonb);
    perform public.erp_answer_interview(s, 'posting.receipt_account', '"1200"'::jsonb);
    perform public.erp_propose_from_interview(s);
    res := public.erp_accept_interview(s);
    v_cases := v_cases + 1;
    case_name := 'the interview sets up books with the close checklist beside them';
    passed := exists (select 1 from erp.ledger l where l.tenant_id = t_c and l.status = 'active')
          and cardinality(erp.close_ties_missing(t_c)) = 0
          and (select c.status from erp.change_set c
                where c.tenant_id = t_c and c.code = 'period-close') = 'promoted';
    detail := format('missing %s; steps %s', erp.close_ties_missing(t_c), left(res::text, 200));
    return next;

    -- 9. The demonstration is built with it, which is the case the build's own
    --    order hid: close_month.sh installed it before anything asked.
    v_step := 'building a demonstration';
    perform set_config('request.jwt.claims', '', true);
    select r.tenant_id, r.admin_user_id, r.admin_token into t_d, v_admin, v_tok
      from erp.provision_tenant('zzclose-d-' || v_tag, 'Close checklist D',
                                'admin@zzclose-d-' || v_tag || '.test', 'Demo Admin') r;
    perform set_config('request.jwt.claims', json_build_object('sub', d1)::text, true);
    perform erp.claim_invitation(v_tok);
    update erp.environment set is_live = false where tenant_id = t_d and is_self;
    v := erp.ensure_demo_configuration(t_d, v_admin);
    v_cases := v_cases + 1;
    case_name := 'a demonstration is built with every tie in its checklist';
    passed := cardinality(erp.close_ties_missing(t_d)) = 0
          and (v -> 'installed') ? 'period-close'
          and exists (select 1 from erp.ledger l where l.tenant_id = t_d and l.status = 'active');
    detail := format('missing %s; installed %s', erp.close_ties_missing(t_d), v::text);
    return next;

    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_CLOSE_CHECKLIST_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code like 'zzclose-%-' || v_tag)
     or exists (select 1 from auth.users u where u.id in (a1, a2, b1, b2, c1, d1)) then
    raise exception 'CLOVEERP_CLOSE_CHECKLIST_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.close_checklist_required_suite() from public, anon, authenticated;

create or replace function erp_test.assert_close_checklist_required_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.close_checklist_required_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_CLOSE_CHECKLIST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An organisation could go live with books whose close does not check them, or an installer stopped installing the checklist. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_CLOSE_CHECKLIST_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('close checklist required: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_close_checklist_required_suite() from public, anon;

comment on function erp_test.assert_close_checklist_required_suite() is
  'Books go live only with the close checklist''s ties, and both installers install it (20261004500000).';

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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
