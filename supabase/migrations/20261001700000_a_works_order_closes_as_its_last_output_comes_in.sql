set lock_timeout = '30s';

-- =============================================================================
-- 20261001700000  A works order closes as its last output comes in
-- -----------------------------------------------------------------------------
-- docs/spec/simplification-review.md §10: "In every cycle, the terminal state
-- is reached with no user transition." Every cycle's terminal state was
-- derived but one: a works order was closed by a person pressing Close, the
-- fourth press of the make budget (M8, 20260925600000). The close is not a
-- decision on the clean path. By the time an order has completed, its output
-- is in within the policy's completion tolerances, and what the close does
-- (release the order's commitment, settle its work in progress to the
-- variances, move it to closed) follows from that.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * production.policy gains close_on_completion, defaulted true: the clean
--     path. A firm that reviews its variances before an order closes sets it
--     false and closes from the module's actions, as every firm did before.
--     The make cycle holds six parameters (erp.assert_parameter_budget()).
--   * erp.receive_works_order_output(): the receipt that completes an order
--     closes it in the same statement, through erp.close_works_order(), so the
--     settlement journal posts as it did. The close is the system's move,
--     named in erp.deriving_move, and takes its authority from the order
--     having completed (erp.derived_move_fact()), not from production.release:
--     whoever may take the goods in completes the order and its close.
--   * An order whose books disagree with its variance is not closed on the
--     wrong figure, and the receipt is not refused for it: the order stays
--     completed for a person, as the close by hand always named it.
--   * An order short of its completion tolerance is not complete and does not
--     close; it is closed short from the module's actions, as it was.
--   * The make cycle's budget is three presses: the order, the hours, the
--     goods in. The strip's last step lists closed orders and has no verb.
--
-- Re-pinned on purpose: erp_test.step_budget_suite case 10 and
-- erp_test.make_walk (three presses), and the six suites that work on a
-- completed order by hand, which now set close_on_completion false in the
-- change set their fixture installs production with.
--
-- Proof: erp_test.works_order_closes_itself_suite (6 cases).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The setting
-- ─────────────────────────────────────────────────────────────────────────────

do $policy$
declare
  v_n integer;
begin
  update erp_ref.config_type ct
     set value_schema = jsonb_set(ct.value_schema, '{properties,close_on_completion}', '{"type": "boolean"}'::jsonb),
         default_value = ct.default_value || '{"close_on_completion": true}'::jsonb,
         clean_path = 'Complete to the quantity ordered, release with no shortage, scrap written off, and close as '
                   || 'the last of it comes in: the order runs as planned and settles itself.'
   where ct.code = 'production.policy'
     and not (ct.value_schema -> 'properties' ? 'close_on_completion');
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from erp_ref.config_type ct
                              where ct.code = 'production.policy'
                                and ct.value_schema -> 'properties' ? 'close_on_completion') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: production.policy is not the setting this migration extends';
  end if;
end
$policy$;

-- The Manufacturing screen proposes the setting as it proposes the others: a
-- boolean, where the four before it are percentages.
do $propose$
declare
  v_sig constant text := 'erp.propose_production_policy(text,text,jsonb,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    if v_key not in ('over_completion_pct', 'short_completion_pct', 'scrap_pct', 'release_shortage_pct')
       or jsonb_typeof(p_value -> v_key) <> 'number'
       or (p_value ->> v_key)::numeric not between 0 and 100 then$o$,
    $n$    -- close_on_completion is a yes or no (20261001700000); the rest are
    -- percentages.
    if (v_key = 'close_on_completion' and jsonb_typeof(p_value -> v_key) <> 'boolean')
       or (v_key <> 'close_on_completion'
           and (v_key not in ('over_completion_pct', 'short_completion_pct', 'scrap_pct', 'release_shortage_pct')
                or jsonb_typeof(p_value -> v_key) <> 'number'
                or (p_value ->> v_key)::numeric not between 0 and 100)) then$n$,
    $o$            hint = 'Over-completion, short completion, scrap and release shortage are percentages from 0 to 100; give one or more.';
    end if;
  end loop;$o$,
    $n$            hint = 'Over-completion, short completion, scrap and release shortage are percentages from 0 to 100, and close on completion is true or false; give one or more.';
    end if;
  end loop;$n$];
  v_hits integer;
begin
  if strpos(v_def, '20261001700000') > 0 then
    raise notice '% already takes close_on_completion; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$propose$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The fact the close is derived from
-- ─────────────────────────────────────────────────────────────────────────────

do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$     and t.tenant_id = erp.current_tenant_id()
     and t.id = p_object_id
$o$;
  v_new constant text := $n$     and t.tenant_id = erp.current_tenant_id()
     and t.id = p_object_id
  union all
  -- A works order's close as its last output comes in (20261001700000),
  -- asked for by erp.receive_works_order_output(): the order has completed,
  -- within the production policy's completion tolerances.
  select case
           when p_transition_code = 'close' and wo.status = 'completed'
             then 'erp.receive_works_order_output'
         end
    from erp.works_order wo
   where p_object_type = 'works_order'
     and coalesce(current_setting('erp.deriving_move', true), '')
           = p_object_id::text || ':' || p_transition_code
     and wo.tenant_id = erp.current_tenant_id()
     and wo.id = p_object_id
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.receive_works_order_output''') > 0 then
    raise notice '% already derives a works order''s close; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count task tail found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The close takes its authority from the fact when the system makes it
-- ─────────────────────────────────────────────────────────────────────────────

do $close$
declare
  v_sig constant text := 'erp.close_works_order(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.authorise('production.release', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);
$o$;
  v_new constant text := $n$  -- Closed by the system as its last output comes in (20261001700000): the
  -- move takes its authority from the order having completed, which
  -- erp.perform_transition() reads again as the fact. By hand, the person is
  -- asked for production.release, as always.
  if coalesce(current_setting('erp.deriving_move', true), '') <> p_works_order_id::text || ':close'
     or wo.status <> 'completed' then
    perform erp.authorise('production.release', wo.entity_id, wo.site_id, null,
                          'works_order', p_works_order_id);
  end if;
$n$;
  v_hits integer;
begin
  if strpos(v_def, '20261001700000') > 0 then
    raise notice '% already closes as the system asks; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % authorise found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$close$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The receipt that completes an order closes it
-- ─────────────────────────────────────────────────────────────────────────────

do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_done    boolean;
$o$,
    $n$  v_done    boolean;
  v_prev    text;
$n$,
    $o$  return v_batch;
end;
$o$,
    $n$  -- And closed, now that the last of it is in within the policy's
  -- tolerances (20261001700000). The close is the system's move and settles
  -- the order as a close by hand does. An order whose books disagree with its
  -- variance is left completed for a person: the goods are in either way.
  if v_done and coalesce((v_policy ->> 'close_on_completion')::boolean, true)
     and (select w.status from erp.works_order w
           where w.tenant_id = v_tenant and w.id = p_works_order_id) = 'completed' then
    v_prev := coalesce(current_setting('erp.deriving_move', true), '');
    perform set_config('erp.deriving_move', p_works_order_id::text || ':close', true);
    begin
      perform erp.close_works_order(p_works_order_id);
    exception when others then
      if sqlerrm not like 'CLOVEERP_WORKS_ORDER_WIP_DISAGREES:%' then
        perform set_config('erp.deriving_move', v_prev, true);
        raise;
      end if;
    end;
    perform set_config('erp.deriving_move', v_prev, true);
  end if;

  return v_batch;
end;
$n$];
  v_hits integer;
begin
  if strpos(v_def, '20261001700000') > 0 then
    raise notice '% already closes what it completes; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$receive$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The make cycle's budget: three presses
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.flow_budget
   set budget = 3, decision_steps = 3,
       rationale = rationale || ' Three since 20261001700000: the order closes itself as the last of its '
                 || 'output comes in, so Close is no longer a press on the clean path. Closing short, or '
                 || 'an order a firm reviews first, is an action on the module.'
 where flow_code = 'make' and budget = 4;

do $budget$
begin
  if (select b.budget from erp_meta.flow_budget b where b.flow_code = 'make') is distinct from 3 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: the make budget is not four, the figure this migration lowers';
  end if;
end
$budget$;

-- The strip's words, rendered through ui().
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The Making strip, whose orders close themselves (20261001700000).'
  from (values
    ('Create the order, which goes to the floor as it is made, record the hours and take in the finished goods. The materials go out as the goods come in, and the order closes itself with the last of them.'),
    ('Closed'),
    ('An order closes itself as the last of its goods comes in, and settles the difference from plan. One closed short, or held for review, is closed from Close a works order.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Re-pinned on purpose: the walk, its case, and the suites that close by hand
-- ─────────────────────────────────────────────────────────────────────────────

do $make_walk$
declare
  v_sig constant text := 'erp_test.make_walk()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    -- The four presses.$o$,
    $n$    -- The three presses; the order closes itself (20261001700000).$n$,
    $o$    -- 4. The maker closes the order.
    if v_block is null then
      begin
        perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
        res := to_jsonb(public.erp_close_works_order(v_wo));
        v_steps := v_steps || jsonb_build_object('step', 4, 'door', 'erp_close_works_order',
                     'person', 'maker', 'result', res);
        v_subs := v_subs || s_make;
      exception when others then
        v_block := format('4 maker erp_close_works_order: %s', left(sqlerrm, 300));
      end;
    end if;
$o$,
    $n$    -- Nobody closes it: the ten coming in closed it (20261001700000).
$n$];
  v_hits integer;
begin
  if strpos(v_def, '20261001700000') > 0 then
    raise notice '% already walks three presses; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$make_walk$;

do $step_budget$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  case_name := 'the make cycle is walked by one person in four presses: the order released as it is made, the hours, the goods in with their materials out, and the order closed';$o$,
    $n$  case_name := 'the make cycle is walked by one person in three presses: the order released as it is made, the hours, and the goods in with their materials out, which closes the order with nobody pressing Close';$n$,
    $o$            and (v_make ->> 'presses')::integer = 4
$o$,
    $n$            and (v_make ->> 'presses')::integer = 3 /* three since 20261001700000 */
$n$];
  v_hits integer;
begin
  if strpos(v_def, 'three since 20261001700000') > 0 then
    raise notice '% already walks making in three; left as it is', v_sig;
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$step_budget$;

-- The six suites that complete an order and then work on it by hand keep
-- doing so: their fixture's organisation reviews before it closes, set once
-- its production change set is promoted, so the installer does not overwrite
-- it.
create or replace function erp_test.production_closes_by_hand(p_tenant_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_live boolean;
begin
  -- A fixture's setting, written as a fixture writes one (20261001700000):
  -- the organisation is taken out of live for the one write and put back.
  select e.is_live into v_live from erp.environment e where e.tenant_id = p_tenant_id and e.is_self;
  update erp.environment set is_live = false where tenant_id = p_tenant_id and is_self;
  perform erp.set_config_value('production.policy',
    coalesce(erp.config_value('production.policy', null, null, null, null), '{}'::jsonb)
      || '{"close_on_completion": false}'::jsonb,
    null, null, null, null, 'this suite closes its works orders by hand');
  update erp.environment set is_live = coalesce(v_live, false) where tenant_id = p_tenant_id and is_self;
end;
$$;

revoke all on function erp_test.production_closes_by_hand(uuid) from public, anon;

comment on function erp_test.production_closes_by_hand(uuid) is
  'A suite fixture''s organisation that closes its works orders by hand: close_on_completion off '
  '(20261001700000).';

do $by_hand$
declare
  v_sig    text;
  v_def    text;
  v_anchor constant text := $o$perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);$o$;
  v_new    constant text := $n$perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    perform erp_test.production_closes_by_hand(r.tenant_id); -- by hand (20261001700000)$n$;
  v_hits   integer;
begin
  foreach v_sig in array array['erp_test.production_settlement_suite()', 'erp_test.production_suite()',
                               'erp_test.works_order_lifecycle_suite()', 'erp_test.works_order_valuation_suite()',
                               'erp_test.production_inspection_suite()', 'erp_test.production_tolerance_suite()'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if strpos(v_def, 'production_closes_by_hand') > 0 then
      raise notice '% already closes by hand; left as it is', v_sig;
      continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % production promotion found % time(s)', v_sig, v_hits;
    end if;
    execute replace(v_def, v_anchor, v_new);
  end loop;
end
$by_hand$;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.works_order_closes_itself_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 6;
  v_cases integer := 0;
  v_tag   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  s_make  uuid := gen_random_uuid();
  v_step  text := 'provisioning';
  v_state text;
  v_owner text := current_user;
  r       record;
  res     jsonb;
  v_site uuid; v_fg uuid; v_comp uuid; v_recv uuid; v_uom uuid; v_sup uuid; v_bom uuid; v_rout uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid;
  v_j0 integer; v_j1 integer; v_err text; v_role uuid;
begin
  begin
    v_step := 'an organisation that makes, and a maker who may take the goods in but not close an order';
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant(
      'zzwc-' || v_tag, 'Works Order Closes Itself Suite',
      'admin@zzwc-' || v_tag || '.test', 'Works Order Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzwc-' || v_tag || '.test'),
                                              (s_make, 'maker@zzwc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);
    -- Production as the Configuration screen installs it: backflush, and the
    -- close as the goods come in, both its defaults.
    perform erp.configure_production();
    res := public.erp_invite_principal('maker@zzwc-' || v_tag || '.test', 'Maya Maker');
    -- An operator who takes the goods in and may not close an order: no
    -- seeded role draws that line, so the organisation draws it.
    insert into erp.role (tenant_id, code, name, status)
    values (r.tenant_id, 'zw_operator', 'Line operator', 'active') returning id into v_role;
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    values (r.tenant_id, v_role, 'production.execute'), (r.tenant_id, v_role, 'production.read');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'zw_operator', null, null, 'takes the goods in');
    perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'a finished good, its bill and routing, its component on hand, and a place to receive into';
    select u.id into v_uom from erp.uom u where u.tenant_id = r.tenant_id order by u.code limit 1;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'ZWMAIN', 'Works', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'ZWRECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'ZWSUP', 'Works order suite supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZWFG', 'Works order suite finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'ZWC1', 'Works order suite component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'ZWFG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 2, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'ZWFG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 0, 6, 6000);
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 1000, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- ── 1. Completed, and closed with nobody pressing Close ─────────────────
    v_step := 'an order for five, taken in in full by the maker';
    v_wo := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo);
    select count(*) into v_j0 from erp.journal j where j.tenant_id = r.tenant_id and j.source_code like '%works_order%';
    perform set_config('request.jwt.claims', json_build_object('sub', s_make)::text, true);
    v_err := case when erp.has_permission('production.release') then 'may close by hand'
                  else 'may not close by hand' end;
    perform public.erp_receive_works_order_output(v_wo, 5, null, v_recv);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_j1 from erp.journal j where j.tenant_id = r.tenant_id and j.source_code like '%works_order%';
    v_cases := v_cases + 1;
    case_name := 'the receipt that completes an order closes it, settled, by a maker who may not close an order by hand';
    passed := v_state is null
          and v_err = 'may not close by hand'
          and (select wo.status::text from erp.works_order wo where wo.id = v_wo) = 'closed'
          and erp.works_order_wip(v_wo) = 0
          and exists (select 1 from erp.production_event e where e.works_order_id = v_wo and e.event_kind = 'closed')
          and exists (select 1 from erp.state_transition_log l
                       where l.object_type = 'works_order' and l.object_id = v_wo and l.transition_code = 'close'
                         and l.guard_data #>> '{derived,fact}' = 'erp.receive_works_order_output')
          and v_j1 > v_j0;
    detail := coalesce(v_state, format('the maker %s; the order reads %s; %s journal(s) before, %s after',
      v_err, (select wo.status::text from erp.works_order wo where wo.id = v_wo), v_j0, v_j1));
    return next;

    -- ── 2. Short of its tolerance, left for a person ────────────────────────
    v_step := 'an order for five, four of them in';
    v_wo2 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo2);
    perform erp.receive_works_order_output(v_wo2, 4, null, v_recv);
    v_cases := v_cases + 1;
    case_name := 'an order short of its completion tolerance is in progress and not closed, and a person closes it short';
    passed := v_state is null
          and (select wo.status::text from erp.works_order wo where wo.id = v_wo2) = 'in_progress';
    perform erp.close_works_order(v_wo2);
    passed := passed and (select wo.status::text from erp.works_order wo where wo.id = v_wo2) = 'closed';
    detail := coalesce(v_state, 'in progress at four of five, then closed short by hand');
    return next;

    -- ── 3. A firm that reviews first ────────────────────────────────────────
    v_step := 'close_on_completion off, and an order taken in in full';
    perform erp.set_config_value('production.policy',
      coalesce(erp.config_value('production.policy', null, null, null, null), '{}'::jsonb)
        || '{"close_on_completion": false}'::jsonb,
      null, null, null, null, 'this firm reviews its variances before it closes');
    v_wo3 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo3);
    perform erp.receive_works_order_output(v_wo3, 5, null, v_recv);
    v_cases := v_cases + 1;
    case_name := 'a firm that turns close_on_completion off gets its completed order left for a person to close';
    passed := v_state is null
          and (select wo.status::text from erp.works_order wo where wo.id = v_wo3) = 'completed';
    perform erp.close_works_order(v_wo3);
    passed := passed and (select wo.status::text from erp.works_order wo where wo.id = v_wo3) = 'closed';
    detail := coalesce(v_state, 'completed, then closed by hand');
    perform erp.set_config_value('production.policy',
      coalesce(erp.config_value('production.policy', null, null, null, null), '{}'::jsonb)
        || '{"close_on_completion": true}'::jsonb,
      null, null, null, null, 'this firm closes as the goods come in');
    return next;

    -- ── 4. Books that disagree are not closed on the wrong figure ───────────
    v_step := 'an order whose books disagree with its variance, taken in in full';
    v_wo4 := erp.raise_works_order(v_fg, v_site, 5);
    perform erp.release_works_order(v_wo4);
    perform erp.post_works_order_finance(v_wo4, 'works_order_labour', 700);
    v_err := null;
    begin
      perform erp.receive_works_order_output(v_wo4, 5, null, v_recv);
      v_err := 'received';
    exception when others then v_err := left(sqlerrm, 160); end;
    v_cases := v_cases + 1;
    case_name := 'an order whose books disagree with its variance takes its goods in and is left completed for a person, not closed on the wrong figure';
    passed := v_state is null
          and v_err = 'received'
          and (select wo.status::text from erp.works_order wo where wo.id = v_wo4) = 'completed';
    detail := coalesce(v_state, format('%s; the order reads %s', v_err,
      (select wo.status::text from erp.works_order wo where wo.id = v_wo4)));
    return next;

    -- ── 5. The budget ───────────────────────────────────────────────────────
    v_step := 'the make budget and the parameter budget';
    v_cases := v_cases + 1;
    case_name := 'the make cycle''s budget is three presses, and production holds its new setting within its fifteen';
    passed := v_state is null
          and (select b.budget from erp_meta.flow_budget b where b.flow_code = 'make') = 3
          and (select r2.parameters from erp.parameter_budget_report() r2 where r2.cycle_code = 'make') = 6
          and erp.assert_parameter_budget() like 'parameter budget:%';
    detail := coalesce(v_state, 'make at three presses and six parameters');
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 6. Undone ──────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzwc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_make))
        and current_user = v_owner;
  detail := coalesce(v_state, 'zzwc rolled back with its orders');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_WORKS_ORDER_CLOSES_ITSELF_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.works_order_closes_itself_suite() from public, anon;

comment on function erp_test.works_order_closes_itself_suite() is
  'A works order closes itself, settled, as the receipt that completes it comes in, by the fact and not '
  'production.release; short of tolerance, turned off, or with books that disagree, it waits for a person '
  '(20261001700000).';

create or replace function erp_test.assert_works_order_closes_itself_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.works_order_closes_itself_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_WORKS_ORDER_CLOSES_ITSELF_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A completed works order would wait for a press nobody needs to make, or close on the wrong figure. Read the case that failed.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_WORKS_ORDER_CLOSES_ITSELF_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('works order closes itself: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_works_order_closes_itself_suite() from public, anon;

comment on function erp_test.assert_works_order_closes_itself_suite() is
  'A completed works order closes itself, settled, and waits for a person only where it should (20261001700000).';

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
select erp.assert_every_transition_is_driven();
select erp.assert_parameter_budget();
