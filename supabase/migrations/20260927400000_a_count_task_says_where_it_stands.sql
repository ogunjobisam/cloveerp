set lock_timeout = '30s';

-- =============================================================================
-- 20260927400000  A count task says where it stands
-- -----------------------------------------------------------------------------
-- PR10, M3a: the database half of node I2 of docs/spec/simplification-review.md,
-- "the counter's worklist", on top of M2b (20260927300000), which posts a count
-- inside its tolerance as it is recorded.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- Since M2b a count inside tolerance costs one door call per place, and the
-- only human decision is the figure. The screen could not show that. The one
-- read of the count tasks, public.erp_count_tasks(), said a task's item code,
-- site code, place, figures and status, and nothing else: not the count sheet
-- the task is a line of, so a list could not be walked in the paper's order;
-- not the adjustment a posted count wrote; not whether the system posted it or
-- a person did; not why a count inside tolerance waits (post_held_reason); not
-- the site's id, which is what the desk scopes by; and not whether the person
-- reading counted it, which is what decides whether Post is theirs to press
-- once the organisation is live. Nothing pinned the door's shape, and nothing
-- walked a count: erp_test.step_budget_suite walked procurement, order to cash
-- and making, and the stock row of erp_meta.flow_budget said only that the
-- plan's target of one action per count task was a different shape.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * public.erp_count_tasks(p_limit) keeps its signature, its volatility
--     (stable), its language, its empty search path, its grants and its
--     governance: it authorises nothing, and the tenant filter and row
--     security scope it. It gains, beside the keys it had:
--       item_name, batch, site_id, programme
--       document_id, document_number, sheet_line_no
--                               the count sheet the task is a line of, and
--                               the line; null for a task raised with no
--                               sheet (before inventory-operations 7)
--       adjustment_document_id, adjustment_number
--                               the stock adjustment its post wrote, or null
--       posted_by_system        true when the count posted itself as it was
--                               recorded, inside tolerance
--       post_held_reason        why an approved count waits for somebody to
--                               post it; null once it is no longer approved,
--                               because a count that has posted or gone back
--                               to be counted waits for nothing (the column
--                               keeps what it said)
--       counted_by_me           whether the person reading recorded the count
--       post_refused_to_me      whether a post by the person reading would be
--                               refused as their own count's (a variance,
--                               once the organisation is live), so a screen
--                               offers Post to somebody else (found on review)
--     The site filter stays on the screen, as the balance panels do it.
--   * erp_test.count_worklist_suite proves each key in each state a count
--     reaches: on a sheet and with none, posted by the system, held by the
--     site's policy, posted by hand, cancelled, sent back to be counted
--     again, and read by the counter and by somebody else, under row
--     security, with another organisation's count in the same database.
--   * erp_test.step_budget_suite walks a count (case 11, erp_test.count_walk):
--     a counter who is not an administrator raises a programme of three
--     places in one press and records each in one more, down the sheet in
--     its order, in a live organisation; every count posts itself, two of
--     them through an adjustment, nobody presses Post, and the sheet closes
--     itself.
--   * The stock row of erp_meta.flow_budget keeps its numbers (6, 6, 5, 2)
--     and says what they measure and where a count's own cost is walked.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No screen. The worklist, its exceptions, Print and Cancel are M3b, and
--     so is the deletion of the two erp_meta.api_only_door rows that name
--     erp_cancel_count_task and erp_render_count_sheet as pending_screen:
--     erp.assert_doors_have_a_home() refuses the deletion without the screen
--     that names them, and the screen without the deletion.
--   * No string. The words the worklist says are seeded with the screen that
--     says them, when they are final.
--   * No new refusal: the door refuses nothing, and the suites' own
--     CLOVEERP_*_SUITE_* tokens are outside the refusal register's scope, as
--     every suite's are.
--   * No signature change, so a client of either age works against a
--     database of either age: an old client ignores the new keys, and a new
--     one reads them as missing until this is deployed.
--   * No table, lifecycle, change set or register restatement.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The door says where a count task stands
-- ─────────────────────────────────────────────────────────────────────────────

-- The door as 20260830014600 left it, or stop: a restatement over a body that
-- has moved since would drop whatever moved it.
do $door_anchor$
declare
  v_sig constant text := 'public.erp_count_tasks(integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_needles constant text[] := array[
    $o$'counted_at', c.counted_at, 'posted_at', c.posted_at) as x$o$,
    $o$     where c.tenant_id = erp.current_tenant_id()
     order by c.status, c.created_at desc limit greatest(p_limit, 1)) t$o$,
    $o$ STABLE
$o$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_needles, 1) loop
    v_hits := (length(v_def) - length(replace(v_def, v_needles[v_i], ''))) / length(v_needles[v_i]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
  end loop;
  if (select p.prosecdef or p.prolang <> (select l.oid from pg_language l where l.lanname = 'sql')
             or p.proconfig is distinct from array['search_path=""']
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is no longer a plain sql door with an empty search path', v_sig;
  end if;
end
$door_anchor$;

create or replace function public.erp_count_tasks(p_limit integer default 200)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- Every count task of the organisation, open work first (20260927400000):
  -- where it stands, the sheet and line it is on, the adjustment its post
  -- wrote, whether the system posted it, why an approved one waits, and
  -- whether the reader counted it. It authorises nothing; the tenant filter
  -- and row security scope it, and every join is inside the task's own
  -- organisation.
  select coalesce(jsonb_agg(x order by x->>'status'), '[]'::jsonb) from (
    select jsonb_build_object('task_id', c.id, 'item', i.code, 'site', s.code,
      'location', l.code, 'expected', c.expected_quantity, 'counted', c.counted_quantity,
      'variance', c.variance, 'within_tolerance', c.within_tolerance, 'status', c.status,
      'counted_at', c.counted_at, 'posted_at', c.posted_at,
      'item_name', i.name, 'batch', b.batch_number, 'site_id', c.site_id,
      'programme', pg.code,
      'document_id', c.document_id, 'document_number', sh.document_number,
      'sheet_line_no', sl.line_no,
      'adjustment_document_id', c.adjustment_document_id,
      'adjustment_number', adj.document_number,
      'posted_by_system', c.posted_by_system,
      'post_held_reason', case when c.status = 'approved' then c.post_held_reason end,
      'counted_by_me', coalesce(c.counted_by = erp.current_principal_id(), false),
      -- erp.post_count() refuses a person's post of their own count with a
      -- variance once the organisation is live (CLOVEERP_COUNT_SELF_POSTING).
      'post_refused_to_me', coalesce(c.counted_by = erp.current_principal_id()
                                     and c.variance <> 0
                                     and erp.tenant_is_live(c.tenant_id), false)) as x
      from erp.count_task c
      join erp.item i on i.tenant_id = c.tenant_id and i.id = c.item_id
      left join erp.site s on s.tenant_id = c.tenant_id and s.id = c.site_id
      left join erp.location l on l.tenant_id = c.tenant_id and l.id = c.location_id
      left join erp.batch b on b.tenant_id = c.tenant_id and b.id = c.batch_id
      left join erp.count_programme pg on pg.tenant_id = c.tenant_id and pg.id = c.count_programme_id
      left join erp.document sh on sh.tenant_id = c.tenant_id and sh.id = c.document_id
      left join erp.document_line sl on sl.tenant_id = c.tenant_id and sl.id = c.document_line_id
      left join erp.document adj on adj.tenant_id = c.tenant_id and adj.id = c.adjustment_document_id
     where c.tenant_id = erp.current_tenant_id()
     order by c.status, c.created_at desc limit greatest(p_limit, 1)) t
$$;

revoke all on function public.erp_count_tasks(integer) from public, anon;
grant execute on function public.erp_count_tasks(integer) to authenticated, service_role;

comment on function public.erp_count_tasks(integer) is
  'The organisation''s count tasks, open work first, up to p_limit: the place, the figures and where '
  'each stands, the count sheet and line it is on (null when raised with no sheet), the stock '
  'adjustment its post wrote, whether the system posted it as it was recorded, why an approved count '
  'waits for somebody to post it, and whether the reader counted it (20260927400000). Authorises '
  'nothing; the tenant filter and row security scope it.';

-- The same grants as before, and still a read that authorises nothing.
do $door_kept$
declare
  v_sig constant text := 'public.erp_count_tasks(integer)';
begin
  -- Judged by what each role may do, not by a value carried from an earlier
  -- statement: the file is applied statement by statement as often as in one
  -- transaction (found on the full build), and a setting does not outlive
  -- the transaction that set it.
  if not has_function_privilege('authenticated', v_sig, 'execute')
     or not has_function_privilege('service_role', v_sig, 'execute')
     or has_function_privilege('anon', v_sig, 'execute') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not executable by exactly the signed-in and the service', v_sig;
  end if;
  if (select p.provolatile <> 's' or p.prosecdef or p.prosrc like '%erp.authorise(%'
        from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % no longer reads as a stable door that authorises nothing', v_sig;
  end if;
end
$door_kept$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The stock cycle's budget says what it measures
-- ─────────────────────────────────────────────────────────────────────────────

do $stock_budget$
declare
  v_n integer;
begin
  update erp_meta.flow_budget b
     set rationale =
       'The six actions over five steps are what the Stock screen''s strip draws, not what a count '
       'costs. A count is walked by erp_test.step_budget_suite at one press per place, each count '
       'inside its tolerance posting as it is recorded with nobody pressing Post (20260927400000). '
       'The plan''s three for a transfer is PR11''s.'
   where b.flow_code = 'stock'
     and b.budget = 6 and b.decision_steps = 6 and b.stages = 5 and b.stages_without_a_list = 2
     and b.rationale = 'Today''s cost. The plan''s targets are one action per count task and three '
                       'for a transfer, which is a different shape from the five steps drawn here.';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the stock flow budget is not 6/6/5/2 with the rationale 20260921420000 wrote (% row(s))', v_n;
  end if;
end
$stock_budget$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. A count, walked: erp_test.count_walk, and step_budget_suite case 11
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_walk()
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  c_undo   constant text := 'CLOVEERP_COUNT_WALK_UNDO';
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code   text;
  a1       uuid := gen_random_uuid();   -- the first administrator, who sets up
  a2       uuid := gen_random_uuid();   -- the second, who approves the changes
  s_count  uuid := gen_random_uuid();   -- the counter
  p_count  uuid;
  r        record;
  res      jsonb;
  v_tok_a2 text;
  v_tok_c  text;
  cs_fin   uuid;
  cs_inv   uuid;
  cs_proc  uuid;
  v_uom    uuid;
  v_site   uuid;
  v_sup    uuid;
  i_1 uuid; i_2 uuid; i_3 uuid;
  v_grn    uuid;
  v_raised integer;
  v_rows   jsonb;
  v_row    jsonb;
  v_got    text;
  v_walked uuid[] := '{}';
  v_lines  integer[] := '{}';
  v_sheets text[] := '{}';
  v_states text[] := '{}';
  v_raises integer := 0;
  v_steps  jsonb := '[]'::jsonb;
  v_subs   uuid[] := '{}';
  v_block  text;
  v_admins integer;
  v_out    jsonb;
begin
  -- A count of three places, walked by pressing (20260927400000): the
  -- counter raises the programme once and records each place once, in the
  -- order the worklist gives, which is the sheet's. Nothing else is pressed.
  begin
    v_code := 'zzcount-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'Count walk', 'admin@' || v_code || '.test', 'Walk Admin');

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp_test.administrator_approval_off(r.tenant_id);

    res := public.erp_invite_principal('second@' || v_code || '.test', 'Second Admin');
    v_tok_a2 := res ->> 'token';
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('counter@' || v_code || '.test', 'Cy Counter');
    p_count := (res ->> 'app_user_id')::uuid; v_tok_c := res ->> 'token';
    perform erp.grant_role(p_count, 'stock_counter', null, null, 'counts the shelves');

    -- Installed as the Configuration screen installs it, and approved and
    -- promoted by the other administrator.
    cs_fin := erp.configure_finance();
    cs_inv := erp.configure_inventory('average');
    select (d ->> 'lifecycle_change_set_id')::uuid into cs_proc
      from public.erp_configure_procurement(1000000, null) d;

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok_a2);
    perform erp.approve_change_set(cs_fin);
    perform erp.promote_change_set(cs_fin);
    perform erp.approve_change_set(cs_inv);
    perform erp.promote_change_set(cs_inv);
    perform erp.approve_change_set(cs_proc);
    perform erp.promote_change_set(cs_proc);

    perform set_config('request.jwt.claims', json_build_object('sub', s_count)::text, true);
    perform erp.claim_invitation(v_tok_c);

    -- Three products in stock at one site, as a fixture, the organisation
    -- not live while it is written and live for the walk.
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P1', 'First place', v_uom, 'active') returning id into i_1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P2', 'Second place', v_uom, 'active') returning id into i_2;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'P3', 'Third place', v_uom, 'active') returning id into i_3;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, i_1, 100, 100, 'P1');
    perform erp.add_document_line(v_grn, i_2, 100, 100, 'P2');
    perform erp.add_document_line(v_grn, i_3, 100, 100, 'P3');
    perform erp.transition_document(v_grn, 'post', 'count walk');
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    select count(*) into v_admins
      from erp.organisation_administrators() a
     where a.app_user_id = p_count;

    -- ─────────────────────────────────────────────────────────────────────
    -- One press for the programme.
    -- ─────────────────────────────────────────────────────────────────────
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', s_count)::text, true);
      v_raised := public.erp_raise_count_tasks('cycle_a');
      v_raises := v_raises + 1;
      v_subs := v_subs || s_count;
    exception when others then
      v_block := format('raise counter erp_raise_count_tasks: %s', left(sqlerrm, 300));
    end;

    -- ─────────────────────────────────────────────────────────────────────
    -- One press per place, down the worklist in the sheet's order, each
    -- figure what the counter found.
    -- ─────────────────────────────────────────────────────────────────────
    if v_block is null then
      perform set_config('request.jwt.claims', json_build_object('sub', s_count)::text, true);
      v_rows := public.erp_count_tasks(500);
      for v_row in
        select x from jsonb_array_elements(v_rows) x
         where x ->> 'status' = 'open'
         order by x ->> 'document_number', (x ->> 'sheet_line_no')::integer, x ->> 'location', x ->> 'item'
      loop
        exit when v_block is not null;
        begin
          v_got := public.erp_record_count((v_row ->> 'task_id')::uuid,
                     case v_row ->> 'item' when 'P1' then 100 when 'P2' then 99 else 101 end)::text;
          v_steps := v_steps || jsonb_build_object('step', jsonb_array_length(v_steps) + 1,
                       'door', 'erp_record_count', 'person', 'counter',
                       'item', v_row ->> 'item', 'result', v_got);
          v_walked := v_walked || (v_row ->> 'task_id')::uuid;
          v_lines := v_lines || (v_row ->> 'sheet_line_no')::integer;
          v_sheets := v_sheets || (v_row ->> 'document_number');
          v_states := v_states || v_got;
          v_subs := v_subs || s_count;
        exception when others then
          v_block := format('%s counter erp_record_count %s: %s', jsonb_array_length(v_steps) + 1,
                            v_row ->> 'item', left(sqlerrm, 300));
        end;
      end loop;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'places', coalesce(v_raised, 0),
      'raises', v_raises,
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', v_admins,
      'live', erp.tenant_is_live(r.tenant_id),
      'post_presses', (select count(*) from jsonb_array_elements(v_steps) s where s ->> 'door' = 'erp_post_count'),
      'results', to_jsonb(v_states),
      'posted', (select count(*) from erp.count_task t
                  where t.tenant_id = r.tenant_id and t.id = any (v_walked) and t.status = 'posted'),
      'posted_by_system', (select count(*) from erp.count_task t
                            where t.tenant_id = r.tenant_id and t.id = any (v_walked) and t.posted_by_system),
      'adjustments', (select count(*) from erp.count_task t
                       where t.tenant_id = r.tenant_id and t.id = any (v_walked)
                         and t.adjustment_document_id is not null),
      -- Down one sheet, line by line, every line of it.
      'in_sheet_order', coalesce(array_length(v_walked, 1) = 3
                                 and v_lines = (select array_agg(l.line_no order by l.line_no)
                                                  from erp.count_task t
                                                  join erp.document_line l
                                                    on l.tenant_id = t.tenant_id and l.document_id = t.document_id
                                                 where t.tenant_id = r.tenant_id and t.id = v_walked[1])
                                 and (select count(distinct s) from unnest(v_sheets) s) = 1
                                 and v_sheets[1] is not null, false),
      'sheet', v_sheets[1],
      'sheet_state', (select erp.object_current_state('document', t.document_id)
                        from erp.count_task t where t.tenant_id = r.tenant_id and t.id = v_walked[1]),
      'stock', (select coalesce(sum(b.quantity), 0) from erp.stock_balance b
                 where b.tenant_id = r.tenant_id and b.item_id in (i_1, i_2, i_3)),
      'blocked', v_block,
      'steps', v_steps);

    raise exception using message = c_undo;
  exception when others then
    if sqlerrm <> c_undo then
      v_out := jsonb_build_object('presses', 0, 'people', 0, 'blocked',
                 'setting up: ' || left(sqlerrm, 300), 'steps', v_steps);
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$function$;

revoke all on function erp_test.count_walk() from public, anon;

comment on function erp_test.count_walk() is
  'A count of three places walked by pressing (20260927400000): a counter who is not an '
  'administrator raises cycle_a in one press, in a live organisation, and records each place in one '
  'more, down the worklist in its sheet''s order. Returns the presses, the people, whether anybody '
  'pressed Post, how each count ended, and where the sheet stands. Rolled back. For '
  'erp_test.step_budget_suite, case 11.';

do $step_budget_suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 10;
  v_cases   integer := 0;
$o$,
    $n$  c_expected constant integer := 11;
  v_cases   integer := 0;
$n$,
    $o$  v_make    jsonb;
begin
$o$,
    $n$  v_make    jsonb;
  v_count   jsonb;
begin
$n$,
    $o$  if v_cases <> c_expected then
$o$,
    $n$  -- ── 11. Counting, walked ───────────────────────────────────────────────
  --
  -- The plan's target is one action per count task (20260927400000). One
  -- person who is not an administrator, in a live organisation: the
  -- programme raised in one press, then one press per place down the
  -- worklist in its sheet's order. Every count inside its tolerance posts as
  -- it is recorded, two of them through an adjustment, nobody presses Post,
  -- and the sheet closes itself with its last count.
  v_count := erp_test.count_walk();

  v_cases := v_cases + 1;
  case_name := 'a count of three places is raised in one press and counted by one person in three more, one per place down the sheet, and every count inside its tolerance posts as it is recorded with nobody pressing Post';
  passed := coalesce(v_count ->> 'blocked' is null
            and (v_count ->> 'places')::integer = 3
            and (v_count ->> 'raises')::integer = 1
            and (v_count ->> 'presses')::integer = 3
            and (v_count ->> 'people')::integer = 1
            and (v_count ->> 'administrators_pressing')::integer = 0
            and (v_count ->> 'live')::boolean
            and (v_count ->> 'post_presses')::integer = 0
            and v_count -> 'results' = '["posted", "posted", "posted"]'::jsonb
            and (v_count ->> 'posted')::integer = 3
            and (v_count ->> 'posted_by_system')::integer = 3
            and (v_count ->> 'adjustments')::integer = 2
            and (v_count ->> 'in_sheet_order')::boolean
            and v_count ->> 'sheet_state' = 'closed'
            and (v_count ->> 'stock')::numeric = 300, false);
  detail := coalesce('blocked at ' || (v_count ->> 'blocked') || '; ', '')
            || format('%s place(s) raised in %s press(es), then %s press(es) by %s people (%s of them administrators), live %s; Post pressed %s time(s); results %s; %s posted, %s by the system, %s through an adjustment; down the sheet in order %s; sheet %s reads %s; %s in stock',
                      coalesce(v_count ->> 'places', '0'), coalesce(v_count ->> 'raises', '0'),
                      coalesce(v_count ->> 'presses', '0'), coalesce(v_count ->> 'people', '0'),
                      coalesce(v_count ->> 'administrators_pressing', 'an unknown number'),
                      coalesce(v_count ->> 'live', 'unknown'),
                      coalesce(v_count ->> 'post_presses', 'an unknown number of'),
                      coalesce(v_count ->> 'results', '[]'),
                      coalesce(v_count ->> 'posted', '0'), coalesce(v_count ->> 'posted_by_system', '0'),
                      coalesce(v_count ->> 'adjustments', '0'),
                      coalesce(v_count ->> 'in_sheet_order', 'false'),
                      coalesce(v_count ->> 'sheet', 'none'),
                      coalesce(v_count ->> 'sheet_state', 'nothing'),
                      coalesce(v_count ->> 'stock', 'nothing'));
  return next;

  if v_cases <> c_expected then
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$step_budget_suite$;

do $assert_step_budget_suite$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  c_expected constant integer := 10;
$o$;
  v_new constant text := $n$  -- Counting, walked, is case 11 (20260927400000).
  c_expected constant integer := 11;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % expected-count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert_step_budget_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.count_worklist_suite
--
-- One organisation on two sites, one of which holds counts inside tolerance
-- for somebody to post. A counter who holds inventory.count and nothing that
-- adjusts stock, two administrators. A task raised on version 6 with no
-- sheet, then six on two sheets, taken to every state a count reaches, and
-- the door read back by the counter and by an administrator, as the
-- authenticated role, beside another organisation's count.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_worklist_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  c_keys constant text[] := array[
    'adjustment_document_id', 'adjustment_number', 'batch', 'counted', 'counted_at',
    'counted_by_me', 'document_id', 'document_number', 'expected', 'item', 'item_name',
    'location', 'post_held_reason', 'post_refused_to_me', 'posted_at', 'posted_by_system', 'programme',
    'sheet_line_no', 'site', 'site_id', 'status', 'task_id', 'variance', 'within_tolerance'];
  v_owner  text := current_user;
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  a4       uuid := gen_random_uuid();
  r        record;
  r2       record;
  res      jsonb;
  v_tok    text; v_tok3 text;
  v_second uuid; v_counter uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_sup uuid; v_grn uuid;
  s_main uuid; s_hold uuid;
  i_a uuid; i_c uuid; i_d uuid; i_e uuid; i_h uuid; i_p uuid; i_v uuid;
  t_a uuid; t_c uuid; t_d uuid; t_e uuid; t_h uuid; t_p uuid; t_v uuid;
  o_uom uuid; o_site uuid; o_item uuid; o_prog uuid; o_task uuid;
  v_main uuid; v_hold uuid;
  v_rows jsonb; v_rows1 jsonb; v_rows_o jsonb; v_rows_owner jsonb; v_rows_live jsonb;
  x_a jsonb; x_c jsonb; x_d jsonb; x_e jsonb; x_h jsonb; x_p jsonb; x_v jsonb;
  v_status text; v_status2 text; v_status3 text; v_status4 text;
  v_n integer; v_n2 integer;
  v_bad text;
  v_fixture text;
begin
  -- 1. The door keeps its shape: the same signature, a stable sql read with
  --    an empty search path, granted to the signed-in and nobody anonymous,
  --    that authorises nothing.
  return query select 'erp_count_tasks keeps its signature and stays a stable read that authorises nothing, granted to the signed-in only',
    exists (select 1 from pg_proc p
             where p.oid = 'public.erp_count_tasks(integer)'::regprocedure
               and p.provolatile = 's' and not p.prosecdef
               and p.prolang = (select l.oid from pg_language l where l.lanname = 'sql')
               and p.proconfig = array['search_path=""']
               and p.pronargdefaults = 1 and p.prorettype = 'jsonb'::regtype
               and p.prosrc not like '%erp.authorise(%'
               and p.prosrc like '%erp.current_tenant_id()%')
    and has_function_privilege('authenticated', 'public.erp_count_tasks(integer)', 'execute')
    and not has_function_privilege('anon', 'public.erp_count_tasks(integer)', 'execute')
    and (select count(*) from pg_proc p
          where p.pronamespace = 'public'::regnamespace and p.proname = 'erp_count_tasks') = 1,
    (select format('volatility %s, security definer %s, %s argument default(s)',
                   p.provolatile, p.prosecdef, p.pronargdefaults)
       from pg_proc p where p.oid = 'public.erp_count_tasks(integer)'::regprocedure);

  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-cwl-' || v_hex, 'Count worklist suite',
      'a@zz-cwl-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-cwl-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('counter@zz-cwl-' || v_hex || '.test', 'Stock Counter');
    v_counter := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    perform erp.grant_role(v_counter, 'stock_counter', null, null, 'counts the shelves');

    v_fixture := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    v_fixture := 'the sites, the stock and the policy';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status) values
      (r.tenant_id, r.entity_id, 'MAIN', 'On the default', 'warehouse', 'active') returning id into s_main;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status) values
      (r.tenant_id, r.entity_id, 'HOLD', 'Holds every count inside tolerance', 'warehouse', 'active') returning id into s_hold;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status) values
      (r.tenant_id, s_main, 'RECV', 'Goods in', 'receiving', 'active'),
      (r.tenant_id, s_hold, 'RECV-H', 'Goods in, held', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'A', 'Posted by the system', v_uom, 'active') returning id into i_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'C', 'Cancelled', v_uom, 'active') returning id into i_c;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'D', 'Counted again', v_uom, 'active') returning id into i_d;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'E', 'Not counted yet', v_uom, 'active') returning id into i_e;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'H', 'Held by the policy', v_uom, 'active') returning id into i_h;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'P', 'Held, then posted by hand', v_uom, 'active') returning id into i_p;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'V', 'Raised on version 6', v_uom, 'active') returning id into i_v;
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.add_document_line(v_grn, i_c, 100, 100, 'C');
    perform erp.add_document_line(v_grn, i_d, 100, 100, 'D');
    perform erp.add_document_line(v_grn, i_e, 100, 100, 'E');
    perform erp.add_document_line(v_grn, i_v, 100, 100, 'V');
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_hold);
    perform erp.add_document_line(v_grn, i_h, 100, 100, 'H');
    perform erp.add_document_line(v_grn, i_p, 100, 100, 'P');
    perform erp.transition_document(v_grn, 'post');
    perform erp.set_config_value('inventory.count_posting',
      jsonb_build_object('within_tolerance', 'hold'),
      null, null, r.entity_id, s_hold, 'the count worklist suite');

    -- Inside two units, and nobody to approve anything outside them.
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r.tenant_id, 'zz_v6', 'Raised on version 6', 'cycle',
            '{"==": [{"var": "item_code"}, "V"]}'::jsonb, 2, 0, null, 'active'),
           (r.tenant_id, 'zz_list', 'Raised with a sheet', 'cycle',
            '{"or": [{"==": [{"var": "item_code"}, "A"]}, {"==": [{"var": "item_code"}, "C"]},
                     {"==": [{"var": "item_code"}, "D"]}, {"==": [{"var": "item_code"}, "E"]},
                     {"==": [{"var": "item_code"}, "H"]}, {"==": [{"var": "item_code"}, "P"]}]}'::jsonb,
            2, 0, null, 'active');

    -- Version 6 has no count sheet: put back as one, raise, and upgrade.
    v_fixture := 'raising on version 6';
    update erp.document_type set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.output_template set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.state_machine set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.module_installation i set installer_version = 6
     where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations';
    perform erp.raise_count_tasks('zz_v6');
    v_fixture := 'upgrading to version 7';
    perform erp.upgrade_module_configuration('inventory-operations');

    v_fixture := 'raising with a sheet';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform public.erp_raise_count_tasks('zz_list');
    select t.id into t_a from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_a;
    select t.id into t_c from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_c;
    select t.id into t_d from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_d;
    select t.id into t_e from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_e;
    select t.id into t_h from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_h;
    select t.id into t_p from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_p;
    select t.id into t_v from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_v;
    select t.document_id into v_main from erp.count_task t where t.id = t_a;
    select t.document_id into v_hold from erp.count_task t where t.id = t_h;

    -- The counter counts: A inside tolerance on the default site, D outside
    -- it with nobody to approve, H and P inside it on the site that holds;
    -- and cancels C, which nobody counted.
    v_fixture := 'the counter counting';
    v_status  := public.erp_record_count(t_a, 101)::text;
    v_status2 := public.erp_record_count(t_d, 150)::text;
    v_status3 := public.erp_record_count(t_h, 99)::text;
    v_status4 := public.erp_record_count(t_p, 101)::text;
    perform public.erp_cancel_count_task(t_c, 'The bay was emptied for a refit');

    -- The second administrator posts P by hand; the first sends D back to be
    -- counted again.
    v_fixture := 'posting P by hand';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform public.erp_post_count(t_p);
    v_fixture := 'sending D back';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform public.erp_recount_task(t_d);

    -- Another organisation, with a count of its own, in the same database.
    v_fixture := 'another organisation';
    select * into r2 from erp.provision_tenant(
      'zz-cwo-' || v_hex, 'Count worklist suite, the other',
      'a@zz-cwo-' || v_hex || '.test', 'Other Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(r2.admin_token);
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r2.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into o_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r2.tenant_id, r2.entity_id, 'MAIN', 'Theirs', 'warehouse', 'active') returning id into o_site;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r2.tenant_id, 'A', 'Theirs', o_uom, 'active') returning id into o_item;
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r2.tenant_id, 'zz_theirs', 'Theirs', 'cycle', 'true'::jsonb, 2, 0, null, 'active')
    returning id into o_prog;
    insert into erp.count_task (tenant_id, count_programme_id, site_id, item_id, expected_quantity)
    values (r2.tenant_id, o_prog, o_site, o_item, 5) returning id into o_task;

    -- The door, read as the authenticated role by the counter, by an
    -- administrator, and by the other organisation; and by the owner.
    v_fixture := 'reading the door';
    perform set_config('request.jwt.claims', json_build_object('sub', a3, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_rows := public.erp_count_tasks(500);
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_rows1 := public.erp_count_tasks(500);
    execute format('set local role %I', v_owner);
    perform set_config('request.jwt.claims', json_build_object('sub', a4, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_rows_o := public.erp_count_tasks(500);
    execute format('set local role %I', v_owner);
    -- And by the counter once the organisation is live, when a post of their
    -- own count's variance is refused to them.
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a3, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    v_rows_live := public.erp_count_tasks(500);
    execute format('set local role %I', v_owner);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_rows_owner := public.erp_count_tasks(500);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select x into x_a from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_a::text;
    select x into x_c from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_c::text;
    select x into x_d from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_d::text;
    select x into x_e from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_e::text;
    select x into x_h from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_h::text;
    select x into x_p from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_p::text;
    select x into x_v from jsonb_array_elements(v_rows) x where x ->> 'task_id' = t_v::text;

    -- 2. The fixture: seven counts, one with no sheet, six on two sheets,
    --    each where the case below reads it.
    return query select 'the fixture: seven counts, one raised on version 6 and six on a sheet per site, taken to every state a count reaches',
      jsonb_array_length(v_rows) = 7
      and v_main is not null and v_hold is not null and v_main <> v_hold
      and (select t.document_id from erp.count_task t where t.id = t_v) is null
      and v_status = 'posted' and v_status2 = 'counted' and v_status3 = 'approved' and v_status4 = 'approved'
      and (select string_agg(i.code || ' ' || t.status::text, ', ' order by i.code)
             from erp.count_task t join erp.item i on i.id = t.item_id
            where t.tenant_id = r.tenant_id)
          = 'A posted, C cancelled, D open, E open, H approved, P posted, V open',
      format('%s row(s); recorded A %s, D %s, H %s, P %s; %s', jsonb_array_length(v_rows),
             v_status, v_status2, v_status3, v_status4,
             (select string_agg(i.code || ' ' || t.status::text, ', ' order by i.code)
                from erp.count_task t join erp.item i on i.id = t.item_id
               where t.tenant_id = r.tenant_id));

    -- 3. Every row says the same keys, and each names its site, item and
    --    programme.
    select string_agg(x ->> 'item', ', ' order by x ->> 'item') into v_bad
      from jsonb_array_elements(v_rows) x
     where array(select k from jsonb_object_keys(x) k order by k) <> c_keys
        or (x ->> 'site_id')::uuid is distinct from
           (select t.site_id from erp.count_task t where t.id = (x ->> 'task_id')::uuid)
        or x ->> 'item_name' is distinct from
           (select i.name from erp.count_task t join erp.item i on i.id = t.item_id
             where t.id = (x ->> 'task_id')::uuid)
        or x ->> 'programme' is distinct from (case when x ->> 'item' = 'V' then 'zz_v6' else 'zz_list' end)
        or x ? 'batch' is false or x -> 'batch' <> 'null'::jsonb;
    return query select 'every row carries the same keys, and names its site by id, its product by name and its programme',
      v_bad is null and jsonb_array_length(v_rows) = 7,
      coalesce('wrong for ' || v_bad, 'all seven rows, ' || array_length(c_keys, 1) || ' keys each');

    -- 4. On a sheet: the sheet's id, number and the task's own line, which
    --    are the sheet's lines one for one.
    select count(*) into v_n
      from jsonb_array_elements(v_rows) x
      join erp.count_task t on t.id = (x ->> 'task_id')::uuid
      join erp.document d on d.id = t.document_id
      join erp.document_line l on l.id = t.document_line_id and l.document_id = d.id
     where (x ->> 'document_id')::uuid = d.id
       and x ->> 'document_number' = d.document_number
       and d.document_number like 'CNT-%'
       and (x ->> 'sheet_line_no')::integer = l.line_no;
    select count(*) into v_n2
      from (select x ->> 'document_id' as sheet, x ->> 'sheet_line_no' as line
              from jsonb_array_elements(v_rows) x where x ->> 'document_id' is not null
             group by 1, 2 having count(*) = 1) g;
    return query select 'a count raised on a sheet reads its sheet''s id, number and its own line, one row to a line',
      v_n = 6 and v_n2 = 6
      and (select count(distinct x ->> 'document_id') from jsonb_array_elements(v_rows) x) = 2
      and (select count(*) from erp.document_line l
            where l.tenant_id = r.tenant_id and l.document_id in (v_main, v_hold)) = 6
      and x_a ->> 'document_number' = x_e ->> 'document_number'
      and x_h ->> 'document_number' = x_p ->> 'document_number'
      and x_a ->> 'document_number' <> x_h ->> 'document_number',
      format('%s row(s) matching their sheet''s line, %s distinct line(s); %s and %s',
             v_n, v_n2, coalesce(x_a ->> 'document_number', 'no sheet'),
             coalesce(x_h ->> 'document_number', 'no sheet'));

    -- 5. Raised on version 6: no sheet, and still on the list to count.
    return query select 'a count raised with no sheet, on version 6, reads no sheet and is still listed to count',
      x_v is not null and x_v ->> 'status' = 'open'
      and x_v -> 'document_id' = 'null'::jsonb and x_v -> 'document_number' = 'null'::jsonb
      and x_v -> 'sheet_line_no' = 'null'::jsonb
      and x_v -> 'adjustment_document_id' = 'null'::jsonb
      and x_v -> 'post_held_reason' = 'null'::jsonb
      and not (x_v ->> 'posted_by_system')::boolean and not (x_v ->> 'counted_by_me')::boolean,
      coalesce(x_v::text, 'not listed');

    -- 6. Posted by the system as it was recorded, through its adjustment.
    return query select 'a count posted as it was recorded reads posted by the system, with the number of the adjustment it wrote and no reason to wait',
      x_a ->> 'status' = 'posted' and (x_a ->> 'posted_by_system')::boolean
      and (x_a ->> 'adjustment_document_id')::uuid =
          (select t.adjustment_document_id from erp.count_task t where t.id = t_a)
      and x_a ->> 'adjustment_number' =
          (select d.document_number from erp.count_task t join erp.document d on d.id = t.adjustment_document_id
            where t.id = t_a)
      and x_a -> 'post_held_reason' = 'null'::jsonb
      and (x_a ->> 'variance')::numeric = 1 and x_a ->> 'posted_at' is not null,
      coalesce(x_a::text, 'not listed');

    -- 7. Held by the site's policy: approved, and why.
    return query select 'a count the site''s policy holds reads approved, with its reason, not posted and with no adjustment',
      x_h ->> 'status' = 'approved'
      and x_h ->> 'post_held_reason' like 'held_by_policy:%'
      and x_h ->> 'post_held_reason' = (select t.post_held_reason from erp.count_task t where t.id = t_h)
      and not (x_h ->> 'posted_by_system')::boolean
      and x_h -> 'adjustment_document_id' = 'null'::jsonb and x_h -> 'adjustment_number' = 'null'::jsonb,
      coalesce(x_h::text, 'not listed');

    -- 8. Held, then posted by hand: a person's post, its adjustment, and
    --    nothing to wait for, though the task still keeps why it was held.
    return query select 'a count posted by hand reads posted by a person, with its adjustment, and no longer says why it waited',
      x_p ->> 'status' = 'posted' and not (x_p ->> 'posted_by_system')::boolean
      and (x_p ->> 'adjustment_document_id')::uuid =
          (select t.adjustment_document_id from erp.count_task t where t.id = t_p)
      and x_p ->> 'adjustment_number' =
          (select d.document_number from erp.count_task t join erp.document d on d.id = t.adjustment_document_id
            where t.id = t_p)
      and x_p ->> 'adjustment_number' <> x_a ->> 'adjustment_number'
      and x_p -> 'post_held_reason' = 'null'::jsonb
      and (select t.post_held_reason from erp.count_task t where t.id = t_p) like 'held_by_policy:%',
      coalesce(x_p::text, 'not listed');

    -- 9. Cancelled: on its sheet's line still, with nothing posted.
    return query select 'a cancelled count reads cancelled on its sheet''s line, with no adjustment and nothing to wait for',
      x_c ->> 'status' = 'cancelled'
      and (x_c ->> 'document_id')::uuid = v_main and (x_c ->> 'sheet_line_no') is not null
      and x_c -> 'adjustment_document_id' = 'null'::jsonb
      and x_c -> 'post_held_reason' = 'null'::jsonb
      and not (x_c ->> 'posted_by_system')::boolean,
      coalesce(x_c::text, 'not listed');

    -- 10. Sent back to be counted again: open, its figure gone, nobody's
    --     count, on the same line of the same sheet.
    return query select 'a count sent back to be counted again reads open with no figure, counted by nobody, on the same line of the same sheet',
      x_d ->> 'status' = 'open'
      and x_d -> 'counted' = 'null'::jsonb and x_d -> 'variance' = 'null'::jsonb
      and x_d -> 'within_tolerance' = 'null'::jsonb and x_d -> 'counted_at' = 'null'::jsonb
      and not (x_d ->> 'counted_by_me')::boolean
      and (x_d ->> 'document_id')::uuid = v_main
      and (x_d ->> 'sheet_line_no')::integer =
          (select l.line_no from erp.count_task t join erp.document_line l on l.id = t.document_line_id
            where t.id = t_d)
      and x_d -> 'post_held_reason' = 'null'::jsonb
      and (select string_agg(l.transition_code, ',' order by l.occurred_at, l.id)
             from erp.state_transition_log l
            where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_d
              and l.transition_code is not null) like '%recount_counted',
      coalesce(x_d::text, 'not listed');

    -- 11. Whose count it is: the counter's, to the counter, and nobody's to
    --     an administrator; a count nobody made is nobody's.
    return query select 'counted_by_me is true to the person who counted and false to anybody else, and false where nobody has counted',
      (x_a ->> 'counted_by_me')::boolean and (x_h ->> 'counted_by_me')::boolean
      and (x_p ->> 'counted_by_me')::boolean
      and not (x_e ->> 'counted_by_me')::boolean and not (x_c ->> 'counted_by_me')::boolean
      and not exists (select 1 from jsonb_array_elements(v_rows1) x where (x ->> 'counted_by_me')::boolean)
      and jsonb_array_length(v_rows1) = 7
      -- A post is refused to the reader exactly where they counted a
      -- variance and the organisation is live; to nobody before go-live.
      and not exists (select 1 from jsonb_array_elements(v_rows) x where (x ->> 'post_refused_to_me')::boolean)
      and not exists (select 1 from jsonb_array_elements(v_rows1) x where (x ->> 'post_refused_to_me')::boolean)
      and not exists (select 1 from jsonb_array_elements(v_rows_live) x
                       where (x ->> 'post_refused_to_me')::boolean
                             is distinct from ((x ->> 'counted_by_me')::boolean
                                               and coalesce((x ->> 'variance')::numeric, 0) <> 0))
      and exists (select 1 from jsonb_array_elements(v_rows_live) x where (x ->> 'post_refused_to_me')::boolean),
      format('to the counter %s; to an administrator %s',
             (select string_agg(x ->> 'item', ',' order by x ->> 'item') from jsonb_array_elements(v_rows) x
               where (x ->> 'counted_by_me')::boolean),
             coalesce((select string_agg(x ->> 'item', ',' order by x ->> 'item') from jsonb_array_elements(v_rows1) x
                        where (x ->> 'counted_by_me')::boolean), 'none'));

    -- 12. Scoped to the organisation, under row security as the signed-in
    --     read it: nobody sees another organisation's count, and the counter
    --     sees what the owner of the tables sees.
    return query select 'each organisation reads its own counts and nobody else''s, and under row security the counter reads what the tables hold',
      v_rows_o = jsonb_build_array((select x from jsonb_array_elements(v_rows_o) x where x ->> 'task_id' = o_task::text))
      and jsonb_array_length(v_rows_o) = 1
      and not exists (select 1 from jsonb_array_elements(v_rows) x where x ->> 'task_id' = o_task::text)
      and not exists (select 1 from jsonb_array_elements(v_rows_o) x
                       join erp.count_task t on t.id = (x ->> 'task_id')::uuid
                      where t.tenant_id = r.tenant_id)
      and (select count(*) from jsonb_array_elements(v_rows) x
             join erp.count_task t on t.id = (x ->> 'task_id')::uuid and t.tenant_id = r.tenant_id) = 7
      and v_rows = v_rows_owner,
      format('ours %s row(s), theirs %s; the counter''s read and the owner''s agree %s',
             jsonb_array_length(v_rows), jsonb_array_length(v_rows_o), v_rows = v_rows_owner);

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
  passed := not exists (select 1 from erp.tenant t where t.code in ('zz-cwl-' || v_hex, 'zz-cwo-' || v_hex))
            and current_user = v_owner;
  detail := 'both organisations, their sites, policies, counts, sheets and adjustments rolled back, and the role the suite began as';
  return next;
end;
$function$;

revoke all on function erp_test.count_worklist_suite() from public, anon;

comment on function erp_test.count_worklist_suite() is
  'public.erp_count_tasks says where each count task stands (20260927400000): the sheet, its number '
  'and the line, or none on version 6; the adjustment and its number; posted by the system or by a '
  'person; why an approved count waits and nothing once it no longer does; whether the reader counted '
  'it; for a count held, posted by the system, posted by hand, cancelled, sent back and not yet '
  'counted, read under row security by the counter, an administrator and another organisation.';

create or replace function erp_test.assert_count_worklist_suite()
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
    from erp_test.count_worklist_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The counter''s worklist reads where each count stands from erp_count_tasks. Read the case that failed.';
  end if;
  if v_total <> 13 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_SHRANK: % case(s), expected 13; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('the count worklist: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_count_worklist_suite() from public, anon;

comment on function erp_test.assert_count_worklist_suite() is
  'erp_count_tasks says, for every state a count reaches, the sheet and line it is on, the adjustment '
  'its post wrote, whether the system posted it, why an approved count waits, and whether the reader '
  'counted it, scoped to the organisation under row security (20260927400000).';

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
