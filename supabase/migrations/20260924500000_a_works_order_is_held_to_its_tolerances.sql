set lock_timeout = '30s';

-- =============================================================================
-- 20260924500000  A works order is held to its tolerances
-- -----------------------------------------------------------------------------
-- PR7, M3: node M3 of docs/spec/simplification-review.md, "yield, scrap and
-- completion tolerances", as checked against the built database first.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- The word tolerance did not appear once in production.
--
--   * erp.receive_works_order_output() took any quantity: nought, a negative,
--     or a thousand against an order for ten, in one receipt.
--   * An order completed only on its last unit. One unit short of a hundred it
--     stayed In progress until somebody closed it short by hand.
--   * erp.book_operation_time() took any scrap, however much more than the
--     order was for.
--   * erp.release_works_order(p_allow_shortage) was a switch a person pressed
--     on the form, "Release despite shortages", with nothing to say how short
--     was too short. The spec's words: a boolean override, not a tolerance.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
-- One configuration type, production.policy, read through
-- erp.production_policy() at the order's entity and site, as sales.policy is:
--
--   over_completion_pct   how far past its quantity an order may be taken in
--                         (default 0): a receipt beyond it is refused
--   short_completion_pct  how little may be left for an order to read
--                         Completed (default 0: every unit)
--   scrap_pct             how much of the order's quantity may be booked as
--                         scrap across its operations (default 100)
--   release_shortage_pct  how short of any component, as a share of what the
--                         order needs of it, an order may be released
--                         (default 0: not at all). It replaces the switch:
--                         erp_release_works_order takes the order and nothing
--                         else, and the form loses "Release despite shortages".
--
-- A receipt of nought or less is refused whatever the policy. An order that
-- reads Completed, short or not, still takes in its last units and issues
-- what they consumed until it is closed, within over_completion_pct; before,
-- a completed order took nothing more, so a short completion would have
-- stranded the units still to come off the line.
--
-- The policy is proposed on the Manufacturing screen with Propose the
-- production policy, as an item of a change set somebody else approves and
-- promotes, as the sales policy is. At the defaults the only changes are the
-- ones above that the defaults are for: a receipt past the order is refused,
-- and a release short of material is refused rather than acknowledged.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The policy
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('production.policy', 'policy', 'production',
   'config.production.policy',
   'How far past its quantity a works order may be taken in, how little may be '
   'left for it to read completed, how much of it may be scrapped, and how short '
   'of material it may be released.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'over_completion_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'short_completion_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'scrap_pct', jsonb_build_object('type','number','minimum',0,'maximum',100),
       'release_shortage_pct', jsonb_build_object('type','number','minimum',0,'maximum',100))),
   'site', true,
   jsonb_build_object('over_completion_pct', 0, 'short_completion_pct', 0,
                      'scrap_pct', 100, 'release_shortage_pct', 0),
   'Raising over_completion_pct takes more finished goods into stock than were '
   'ordered, at a cost spread across more units; raising short_completion_pct reads '
   'an order completed with units still to make; lowering scrap_pct refuses scrap '
   'the floor has already lost; raising release_shortage_pct sends an order to the '
   'floor without the material to finish it.')
on conflict (code) do nothing;

insert into erp_ref.resource (key, locale, value, description) values
  ('config.production.policy', 'en', 'Production policy',
   'The name of the production.policy configuration type.'),
  ('config.production.policy', 'de', 'Fertigungsrichtlinie',
   'Der Name des Konfigurationstyps production.policy.')
on conflict (key, locale) do nothing;

create or replace function erp.production_policy(p_entity_id uuid default null,
                                                 p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The production policy in force at an entity and site (20260924500000),
  -- layered key by key as the sales policy is: the product's defaults, then
  -- what the organisation set, then its entity, then its site.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('production.policy', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('production.policy', null, null, p_entity_id, null), '{}'::jsonb) end
      || case when p_site_id is null then '{}'::jsonb
              else coalesce(erp.config_value('production.policy', null, null, p_entity_id, p_site_id), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'production.policy'
$$;

comment on function erp.production_policy(uuid, uuid) is
  'production.policy at an entity and site, over its defaults (20260924500000). '
  'Read by erp.receive_works_order_output (over_completion_pct, '
  'short_completion_pct), erp.book_operation_time (scrap_pct) and '
  'erp.release_works_order (release_shortage_pct).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_OUTPUT_NOT_POSITIVE',
  'Taking in finished goods of nought, or less, against a works order.',
  'A receipt records goods that came off the line. Goods that did not are not taken in, and goods that went back are not a negative receipt.',
  'Give the quantity that came off the line.');

select erp.register_refusal('CLOVEERP_OVER_COMPLETION',
  'Taking in more finished goods against a works order than it was for, beyond what the production policy allows.',
  'An order is costed and planned for its quantity. Goods beyond what the policy allows past it were made without an order.',
  'Take in what the order is for, raise another order for the rest, or propose the production policy with more room on the Manufacturing screen.');

select erp.register_refusal('CLOVEERP_SCRAP_OVER_TOLERANCE',
  'Booking more scrap against a works order than the production policy allows.',
  'The policy says how much of an order may be lost as scrap across its operations. Beyond it, the loss is not the order''s to absorb.',
  'Check the quantity. If it is right, propose the production policy with more room on the Manufacturing screen, then book it.');

select erp.register_refusal('CLOVEERP_MATERIAL_SHORTAGE',
  'Releasing a works order short of a component by more than the production policy allows.',
  'A released order commits its material and goes to the floor. Released without it, the line stops part of the way through.',
  'Receive or move the material first, or propose the production policy with a release shortage allowance on the Manufacturing screen.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Receipt: nothing, or too much, is refused; enough completes it
-- ─────────────────────────────────────────────────────────────────────────────

do $receive$
declare
  v_sig constant text := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o1$  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  select * into it from erp.item where tenant_id = v_tenant and id = wo.item_id;$o1$;
  v_new1 constant text := $n1$  perform erp.authorise('production.execute', wo.entity_id, wo.site_id, null,
                        'works_order', p_works_order_id);

  -- Held to the production policy (20260924500000), before anything is
  -- consumed or made: nought or less is not a receipt, and nothing past the
  -- order's quantity widened by over_completion_pct is taken in.
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'CLOVEERP_OUTPUT_NOT_POSITIVE: % of finished goods is not a receipt against %',
      coalesce(p_quantity::text, 'nothing'), wo.order_number
      using errcode = '22023', hint = 'Give the quantity that came off the line.';
  end if;
  v_policy := erp.production_policy(wo.entity_id, wo.site_id);
  if wo.quantity_completed + p_quantity
     > wo.quantity * (1 + coalesce((v_policy ->> 'over_completion_pct')::numeric, 0) / 100.0) then
    raise exception 'CLOVEERP_OVER_COMPLETION: % would take % to % of %, and the production policy allows % per cent over',
      wo.order_number, wo.quantity_completed, wo.quantity_completed + p_quantity, wo.quantity,
      coalesce(v_policy ->> 'over_completion_pct', '0')
      using errcode = '23514',
            hint = 'Take in what the order is for, raise another order for the rest, or propose the production policy with more room on the Manufacturing screen.';
  end if;

  select * into it from erp.item where tenant_id = v_tenant and id = wo.item_id;$n1$;
  v_old2 constant text := $o2$         actual_end = case when quantity_completed + p_quantity >= quantity
                           then now() end,
         updated_at = now()
   where id = p_works_order_id
   returning status, quantity_completed >= quantity into wo.status, v_done;$o2$;
  v_new2 constant text := $n2$         actual_end = case when quantity_completed + p_quantity
                                >= quantity * (1 - coalesce((v_policy ->> 'short_completion_pct')::numeric, 0) / 100.0)
                           then now() end,
         updated_at = now()
   where id = p_works_order_id
   -- Complete once no more than short_completion_pct of it is left
   -- (20260924500000); at the default, every unit.
   returning status,
             quantity_completed >= quantity * (1 - coalesce((v_policy ->> 'short_completion_pct')::numeric, 0) / 100.0)
        into wo.status, v_done;$n2$;
  v_old3 constant text := $o3$  v_done    boolean;
$o3$;
  v_new3 constant text := $n3$  v_done    boolean;
  v_policy  jsonb;
$n3$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % authorise anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % completion anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % declaration anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$receive$;

-- An order completed short is still on the floor until it is closed: the
-- last units may yet come off the line, and a backflush issues what they
-- consumed. Both doors take a completed order, within over_completion_pct,
-- and neither moves it again.
do $running$
declare
  v_sig text;
  v_def text;
  v_hits integer;
  v_old_recv constant text := $o1$  if wo.status not in ('released', 'in_progress') then
    raise exception 'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %',$o1$;
  v_new_recv constant text := $n1$  if wo.status not in ('released', 'in_progress', 'completed') then
    raise exception 'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %',$n1$;
  v_old_move constant text := $o2$  if v_done then
    perform erp.move_works_order(p_works_order_id,$o2$;
  v_new_move constant text := $n2$  if v_done and wo.status <> 'completed' then
    perform erp.move_works_order(p_works_order_id,$n2$;
  v_old_issue constant text := $o3$  if wo.status not in ('released', 'in_progress') then
    raise exception
      'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %, and material is not issued to '$o3$;
  v_new_issue constant text := $n3$  -- A completed order takes material only while it may still take in
  -- finished goods under the production policy (found on review).
  if wo.status = 'completed'
     and wo.quantity_completed
         >= wo.quantity * (1 + coalesce((erp.production_policy(wo.entity_id, wo.site_id)
                                           ->> 'over_completion_pct')::numeric, 0) / 100.0) then
    raise exception 'CLOVEERP_OVER_COMPLETION: % has taken in all the production policy allows, so nothing more is issued to it',
      wo.order_number
      using errcode = '23514',
            hint = 'Close the order, or raise another for further work.';
  end if;

  if wo.status not in ('released', 'in_progress', 'completed') then
    raise exception
      'CLOVEERP_WORKS_ORDER_NOT_RUNNING: % is %, and material is not issued to '$n3$;
begin
  v_sig := 'erp.receive_works_order_output(uuid,numeric,text,uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_old_recv, ''))) / length(v_old_recv);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old_move, ''))) / length(v_old_move);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % move anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(replace(v_def, v_old_recv, v_new_recv), v_old_move, v_new_move);

  v_sig := 'erp.issue_to_works_order(uuid,uuid,numeric,uuid,uuid)';
  v_def := pg_get_functiondef(v_sig::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_old_issue, ''))) / length(v_old_issue);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % status anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old_issue, v_new_issue);
end
$running$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. Scrap: no more than the policy allows, across the order's operations
-- ─────────────────────────────────────────────────────────────────────────────

do $book$
declare
  v_sig constant text := 'erp.book_operation_time(uuid,integer,numeric,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- The header is the sum of its operations (20260922140000). Read and$o$;
  v_new constant text := $n$  -- No more scrap across the order than the production policy allows
  -- (20260924500000), counted as the header is, from the operations.
  -- Asked only of a booking that adds scrap: hours, or a correction down, on
  -- an order already past a policy since lowered are still taken (found on
  -- review). The order is locked first, so two bookings on different
  -- operations cannot each pass on the other's figure.
  if p_scrapped > 0 then
    perform 1 from erp.works_order w
     where w.tenant_id = v_tenant and w.id = p_works_order_id for update;
  end if;
  if p_scrapped > 0
     and (select coalesce(sum(o.quantity_scrapped), 0)
            from erp.works_order_operation o
           where o.tenant_id = v_tenant and o.works_order_id = p_works_order_id)
         > wo.quantity * coalesce((erp.production_policy(wo.entity_id, wo.site_id) ->> 'scrap_pct')::numeric, 100) / 100.0 then
    raise exception 'CLOVEERP_SCRAP_OVER_TOLERANCE: % would have more scrapped than the production policy allows of its %',
      wo.order_number, wo.quantity
      using errcode = '23514',
            hint = 'Check the quantity. If it is right, propose the production policy with more room on the Manufacturing screen, then book it.';
  end if;

  -- The header is the sum of its operations (20260922140000). Read and$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % header anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$book$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. Release: short by no more than the policy allows, and no switch
--
-- The door loses p_allow_shortage. The routine is re-made with the order
-- alone and the two-argument one dropped, so nothing can still pass the
-- switch and have it quietly ignored.
-- ─────────────────────────────────────────────────────────────────────────────

do $release$
declare
  v_old_sig constant text := 'erp.release_works_order(uuid,boolean)';
  v_def text := pg_get_functiondef(v_old_sig::regprocedure);
  v_old1 constant text := $o1$erp.release_works_order(p_works_order_id uuid, p_allow_shortage boolean DEFAULT false)$o1$;
  v_new1 constant text := $n1$erp.release_works_order(p_works_order_id uuid)$n1$;
  v_old2 constant text := $o2$  select string_agg(format('%s short by %s', a.item_code, a.shortfall), '; ')
    into v_short
    from erp.works_order_availability(p_works_order_id) a
   where a.shortfall > 0;

  if v_short is not null and not p_allow_shortage then
    raise exception 'CLOVEERP_MATERIAL_SHORTAGE: %', v_short
      using errcode = '23514',
      hint = 'Release with the shortage acknowledged if the material is coming, '
             'or plan it in. Releasing quietly is how a line stops mid-shift.';
  end if;$o2$;
  v_new2 constant text := $n2$  -- Short by no more of any component than the production policy's
  -- release_shortage_pct of what the order needs of it (20260924500000). It
  -- replaces a switch the person releasing pressed, which said nothing about
  -- how short was too short.
  select string_agg(format('%s short by %s', a.item_code, a.shortfall), '; ')
    into v_short
    from erp.works_order_availability(p_works_order_id) a
   where a.shortfall > 0;

  if exists (
    select 1
      from erp.works_order_availability(p_works_order_id) a
     -- Short by no more than the order needs: where other orders have
     -- committed more than is on hand, what is available reads below nought,
     -- and the order is short of all of it and no more (found on review).
     where least(a.shortfall, a.required)
           > a.required
             * coalesce((erp.production_policy(wo.entity_id, wo.site_id)
                           ->> 'release_shortage_pct')::numeric, 0) / 100.0) then
    raise exception 'CLOVEERP_MATERIAL_SHORTAGE: % is short by more than the production policy allows: %',
      wo.order_number, v_short
      using errcode = '23514',
      hint = 'Receive or move the material first, or propose the production policy with a release shortage allowance on the Manufacturing screen.';
  end if;$n2$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % signature found % time(s)', v_old_sig, v_hits; end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % shortage anchor found % time(s)', v_old_sig, v_hits; end if;
  v_def := replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
  if strpos(v_def, 'p_allow_shortage') > 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % reads p_allow_shortage somewhere else too', v_old_sig;
  end if;
  execute v_def;
end
$release$;

-- The event said whether a shortage was acknowledged; it says whether the
-- order went short, within the policy.
do $event$
declare
  v_sig constant text := 'erp.release_works_order(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$'shortage_acknowledged', v_short is not null$o$;
  v_new constant text := $n$'released_short', v_short is not null$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % event anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$event$;

drop function public.erp_release_works_order(uuid, boolean);
drop function erp.release_works_order(uuid, boolean);

revoke all on function erp.release_works_order(uuid) from public, anon;

comment on function erp.release_works_order(uuid) is
  'Releases a works order: commits its material against it, freezes its standard and '
  'moves it by its lifecycle. Short of a component by more than the production '
  'policy''s release_shortage_pct, refused (20260924500000). Authorises production.release.';

create or replace function public.erp_release_works_order(p_works_order_id uuid)
returns erp.works_order_status
language sql
set search_path = ''
as $$ select erp.release_works_order(p_works_order_id) $$;

revoke all on function public.erp_release_works_order(uuid) from public, anon;
grant execute on function public.erp_release_works_order(uuid) to authenticated, service_role;

-- The Part 5 register claims release for material availability, by its
-- signature (found on review).
update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.release_works_order(uuid,boolean)',
                                 'erp.release_works_order(uuid)')
 where 'erp.release_works_order(uuid,boolean)' = any (artefacts);

do $part5$
begin
  if exists (select 1 from erp_ref.part5_capability
              where 'erp.release_works_order(uuid,boolean)' = any (artefacts)) then
    raise exception 'CLOVEERP_PART5_STILL_NAMES_THE_SWITCH: the Part 5 register names the dropped release';
  end if;
end
$part5$;

-- The form's switch had its words; nothing says them now.
delete from erp_ref.resource where key = 'ui.release_despite_shortages_125v9ig';

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The callers that pressed the switch
-- ─────────────────────────────────────────────────────────────────────────────

-- The demonstration receives five hundred of its raw material before it
-- releases an order needing a hundred, so it never needed the switch.
do $demo$
declare
  v_sig constant text := 'erp.seed_demo_operations()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$erp.release_works_order(v_wo, true)$o$;
  v_new constant text := $n$erp.release_works_order(v_wo)$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % release anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$demo$;

-- The costing suite releases an order with none of its component on hand, on
-- purpose: what it measures is the standard frozen at release. It says so to
-- the policy, in its own organisation, instead of pressing the switch.
do $fifo$
declare
  v_sig constant text := 'erp_test.fifo_is_costed_from_its_layers_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    perform erp.release_works_order(v_wo, true);$o$;
  v_new constant text := $n$    perform erp.set_config_value('production.policy',
      jsonb_build_object('release_shortage_pct', 100), null, null, null, null,
      'released with none of its component on hand, to measure the standard frozen at release');
    perform erp.release_works_order(v_wo);$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then raise exception 'CLOVEERP_ANCHOR_MOVED: % release anchor found % time(s)', v_sig, v_hits; end if;
  execute replace(v_def, v_old, v_new);
end
$fifo$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The policy is proposed as a change, from the Manufacturing screen
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.propose_production_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity text := p_entity_code;
  ct       erp_ref.config_type%rowtype;
  v_key    text;
  v_cs     uuid := p_change_set_id;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  select * into ct from erp_ref.config_type c where c.code = 'production.policy';
  if p_value is null or jsonb_typeof(p_value) <> 'object' or p_value = '{}'::jsonb
     or not erp.jsonb_matches_schema(ct.value_schema::json, p_value) then
    raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the production policy does not fit its declared shape'
      using errcode = '22023',
            hint = 'Over-completion, short completion, scrap and release shortage are percentages from 0 to 100; give one or more.';
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if v_key not in ('over_completion_pct', 'short_completion_pct', 'scrap_pct', 'release_shortage_pct')
       or jsonb_typeof(p_value -> v_key) <> 'number'
       or (p_value ->> v_key)::numeric not between 0 and 100 then
      raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the production policy does not fit its declared shape'
        using errcode = '22023',
              hint = 'Over-completion, short completion, scrap and release shortage are percentages from 0 to 100; give one or more.';
    end if;
  end loop;

  if p_site_code is not null then
    select e.code into v_entity
      from erp.site s join erp.entity e on e.id = s.entity_id
     where s.tenant_id = v_tenant and s.code = p_site_code;
    if v_entity is null then
      raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
        using errcode = '23503', hint = 'erp_sites() lists the sites by code; a site policy belongs to the site''s company.';
    end if;
  elsif p_entity_code is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = p_entity_code) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', p_entity_code
      using errcode = '23503', hint = 'erp_entities() lists the companies by code.';
  end if;

  if v_cs is null then
    v_cs := erp.create_change_set(
      'production-policy-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US'),
      'Production policy',
      'How far past its quantity a works order may be taken in, how little may be left for it to read completed, how much of it may be scrapped, and how short of material it may be released.');
  end if;

  return erp.add_change_set_item(v_cs, 'config',
    format('production.policy|%s|%s', coalesce(v_entity, '*'), coalesce(p_site_code, '*')),
    jsonb_strip_nulls(jsonb_build_object(
      'config_type', 'production.policy', 'value', p_value,
      'entity', v_entity, 'site', p_site_code)),
    'upsert', null, 'proposed from the Manufacturing screen');
end;
$$;

revoke all on function erp.propose_production_policy(text, text, jsonb, uuid) from public, anon;

comment on function erp.propose_production_policy(text, text, jsonb, uuid) is
  'Proposes the production policy for the organisation, a company or a site, as an '
  'item of a change set (20260924500000).';

create or replace function public.erp_propose_production_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language sql
set search_path = ''
as $$
  select erp.propose_production_policy(p_entity_code, p_site_code, p_value, p_change_set_id)
$$;

revoke all on function public.erp_propose_production_policy(text, text, jsonb, uuid) from public, anon;
grant execute on function public.erp_propose_production_policy(text, text, jsonb, uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_production_policy', 'erp.propose_production_policy',
   'Proposes how far past its quantity a works order may be taken in, how little may be left for it to read completed, how much may be scrapped and how short it may be released, as a change-set item; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/production', array['erp_propose_production_policy']);

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. The words the Manufacturing screen says for it (src/lib/modules.tsx)
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The production policy''s proposal on the Manufacturing screen (20260924500000).'
  from (values
    ('Propose the production policy'),
    ('How far past its quantity a works order may be taken in, how little may be left for it to count as completed, how much of it may be scrapped, and how short of material it may be released. Proposed as a change like any other configuration.'),
    ('Over-completion allowed (%)'),
    ('How far past its quantity an order may be taken in. 0 allows none; left empty, the broader setting applies.'),
    ('Short completion (%)'),
    ('An order counts as completed once no more than this share of it is left to make. 0 means every unit; left empty, the broader setting applies.'),
    ('Scrap allowed (%)'),
    ('How much of an order''s quantity may be booked as scrap across its operations. Left empty, the broader setting applies.'),
    ('Release short by up to (%)'),
    ('How short of any component, as a share of what the order needs of it, an order may be released. 0 means none short; left empty, the broader setting applies.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What proves it: erp_test.production_tolerance_suite, the name node M3
--    gives it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.production_tolerance_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  a2      uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok   text;
  v_second uuid;
  csf uuid; csp uuid; csi uuid; csr uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_sup uuid;
  v_fg uuid; v_comp uuid; v_bom uuid; v_rout uuid; v_grn uuid;
  v_wo uuid; v_wo2 uuid; v_wo3 uuid; v_wo4 uuid;
  v_pol jsonb; v_ecode text; v_cs uuid;
  v_err text; v_err2 text; v_err3 text; v_ok text;
begin
  -- 1. The switch is gone, not ignored.
  return query select 'releasing takes the order alone: the switch that released despite a shortage is gone',
    to_regprocedure('public.erp_release_works_order(uuid,boolean)') is null
    and to_regprocedure('erp.release_works_order(uuid,boolean)') is null
    and to_regprocedure('public.erp_release_works_order(uuid)') is not null,
    'the two-argument door and routine are dropped';

  begin
    select * into r from erp.provision_tenant(
      'zz-ptol-' || v_hex, 'Production tolerance suite',
      'a@zz-ptol-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-ptol-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csr := erp.configure_production('manual');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csr); perform erp.promote_change_set(csr);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select e.code into v_ecode from erp.entity e where e.id = r.entity_id;
    -- Not live, so the suite may set the policy directly, as the sales
    -- policy's suite does; the door that proposes it is case 8's.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'production', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'FG', 'Finished good', v_uom, 'active') returning id into v_fg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'C1', 'Component', v_uom, 'active') returning id into v_comp;
    insert into erp.bom (tenant_id, code, item_id, site_id, version, name,
                         output_quantity, yield_factor, status, effective_from)
    values (r.tenant_id, 'FG-1', v_fg, v_site, 1, 'Finished good', 1, 1, 'active', current_date - 1)
    returning id into v_bom;
    insert into erp.bom_line (tenant_id, bom_id, seq, component_item_id, quantity, uom_id, scrap_factor, is_phantom)
    values (r.tenant_id, v_bom, 10, v_comp, 1, v_uom, 0, false);
    insert into erp.routing (tenant_id, code, item_id, site_id, version, name, status, effective_from)
    values (r.tenant_id, 'FG-R1', v_fg, v_site, 1, 'Assemble', 'active', current_date - 1)
    returning id into v_rout;
    insert into erp.routing_operation (
      tenant_id, routing_id, seq, code, name, work_centre_code,
      setup_minutes, run_minutes_per_unit, cost_rate_minor_per_hour)
    values (r.tenant_id, v_rout, 10, 'ASM', 'Assembly', 'WC1', 10, 1, 6000);

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_comp, 100, 100, 'component');
    perform erp.transition_document(v_grn, 'post');

    -- 2. The defaults.
    v_pol := erp.production_policy(r.entity_id, v_site);
    return query select 'the production policy reads nought over, nought short, a hundred scrap and nought short at release by default',
      (v_pol ->> 'over_completion_pct')::numeric = 0 and (v_pol ->> 'short_completion_pct')::numeric = 0
      and (v_pol ->> 'scrap_pct')::numeric = 100 and (v_pol ->> 'release_shortage_pct')::numeric = 0,
      v_pol::text;

    -- 3. Nothing, or less, is not a receipt; past the order is refused.
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo);
    begin perform erp.receive_works_order_output(v_wo, 0, null, v_recv); v_err := 'taken';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin perform erp.receive_works_order_output(v_wo, -2, null, v_recv); v_err2 := 'taken';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin perform erp.receive_works_order_output(v_wo, 11, null, v_recv); v_err3 := 'taken';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    return query select 'a receipt of nought or less is refused, and so is one past the order at the default',
      v_err like 'CLOVEERP_OUTPUT_NOT_POSITIVE:%' and v_err2 like 'CLOVEERP_OUTPUT_NOT_POSITIVE:%'
      and v_err3 like 'CLOVEERP_OVER_COMPLETION:%'
      and (select wo.quantity_completed from erp.works_order wo where wo.id = v_wo) = 0,
      format('%s | %s | %s', v_err, v_err2, v_err3);

    -- 4. Within the allowance it is taken in; past it, not.
    perform erp.set_config_value('production.policy', jsonb_build_object('over_completion_pct', 10),
      null, null, r.entity_id, null, 'the production tolerance suite');
    begin perform erp.receive_works_order_output(v_wo, 12, null, v_recv); v_err := 'taken';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform erp.receive_works_order_output(v_wo, 10, null, v_recv);
    perform erp.receive_works_order_output(v_wo, 1, null, v_recv);
    return query select 'an entity''s over-completion allowance takes eleven against ten, the eleventh after it completed, and not twelve',
      (select wo.quantity_completed from erp.works_order wo where wo.id = v_wo) = 11
      and erp.object_current_state('works_order', v_wo) = 'completed'
      and v_err like 'CLOVEERP_OVER_COMPLETION:%',
      format('%s taken in, %s; %s',
             (select wo.quantity_completed from erp.works_order wo where wo.id = v_wo),
             erp.object_current_state('works_order', v_wo), v_err);

    -- 5. Short completion.
    perform erp.set_config_value('production.policy',
      jsonb_build_object('over_completion_pct', 0, 'short_completion_pct', 5),
      null, null, r.entity_id, null, 'the production tolerance suite');
    v_wo2 := erp.raise_works_order(v_fg, v_site, 20);
    perform erp.release_works_order(v_wo2);
    perform erp.receive_works_order_output(v_wo2, 18, null, v_recv);
    v_ok := erp.object_current_state('works_order', v_wo2);
    perform erp.receive_works_order_output(v_wo2, 1, null, v_recv);
    v_err2 := erp.object_current_state('works_order', v_wo2);
    perform erp.receive_works_order_output(v_wo2, 1, null, v_recv);
    return query select 'with five per cent short allowed, eighteen of twenty leaves it in progress, nineteen completes it, and the twentieth is still taken in',
      v_ok = 'in_progress' and v_err2 = 'completed'
      and erp.object_current_state('works_order', v_wo2) = 'completed'
      and (select wo.status::text from erp.works_order wo where wo.id = v_wo2) = 'completed'
      and (select wo.quantity_completed from erp.works_order wo where wo.id = v_wo2) = 20,
      format('after eighteen %s, after nineteen %s', v_ok, erp.object_current_state('works_order', v_wo2));

    -- 6. Scrap.
    perform erp.set_config_value('production.policy', jsonb_build_object('scrap_pct', 10),
      null, null, r.entity_id, null, 'the production tolerance suite');
    v_wo3 := erp.raise_works_order(v_fg, v_site, 10);
    perform erp.release_works_order(v_wo3);
    perform erp.book_operation_time(v_wo3, 10, 5, 0, 1);
    begin perform erp.book_operation_time(v_wo3, 10, 5, 0, 1); v_err := 'booked';
    exception when others then v_err := left(sqlerrm, 160); end;
    return query select 'with ten per cent scrap allowed, one of ten is booked and a second is refused',
      v_err like 'CLOVEERP_SCRAP_OVER_TOLERANCE:%'
      and (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo3) = 1,
      format('%s scrapped; %s', (select wo.quantity_scrapped from erp.works_order wo where wo.id = v_wo3), v_err);

    -- 7. Release short: refused at the default, released within an allowance.
    --    Of the 100 received, the orders above commit 10 + 20 + 10 (issue is
    --    manual here, so nothing has left), and an order for 200 is short.
    v_wo4 := erp.raise_works_order(v_fg, v_site, 200);
    begin perform erp.release_works_order(v_wo4); v_err := 'released';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform erp.set_config_value('production.policy', jsonb_build_object('release_shortage_pct', 100),
      null, null, r.entity_id, null, 'the production tolerance suite');
    perform erp.release_works_order(v_wo4);
    return query select 'an order short of its material is refused at release by default, and released within an allowance that says so in its history',
      v_err like 'CLOVEERP_MATERIAL_SHORTAGE:%'
      and erp.object_current_state('works_order', v_wo4) = 'released'
      and exists (select 1 from erp.production_event pe
                   where pe.works_order_id = v_wo4 and pe.event_kind = 'released'
                     and (pe.detail ->> 'released_short')::boolean),
      v_err;

    -- 7b. With more committed than is on hand, an order is short of all it
    --     needs and no more, so a whole allowance still releases it.
    --     And scrap lowered below what one order already lost: hours on it
    --     are still taken, since they add no scrap.
    perform erp.set_config_value('production.policy',
      jsonb_build_object('release_shortage_pct', 100, 'scrap_pct', 5),
      null, null, r.entity_id, null, 'the production tolerance suite');
    v_wo := erp.raise_works_order(v_fg, v_site, 10);
    begin perform erp.release_works_order(v_wo); v_err := 'released';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform erp.book_operation_time(v_wo3, 10, 30, 0, 0);
    return query select 'with more committed than is on hand, an allowance of a hundred per cent still releases, and hours are still taken on an order at its scrap allowance',
      v_err = 'released' and erp.object_current_state('works_order', v_wo) = 'released'
      and (select a.available from erp.works_order_availability(v_wo) a) < 0
      and (select sum(o.actual_minutes) from erp.works_order_operation o where o.works_order_id = v_wo3) = 35,
      format('%s; available %s', v_err, (select a.available from erp.works_order_availability(v_wo) a));

    -- 8. Proposed as a change.
    begin
      perform public.erp_propose_production_policy(v_ecode, null, jsonb_build_object('scrap_pct', 150), null);
      v_err := 'proposed';
    exception when others then v_err := left(sqlerrm, 160); end;
    v_cs := public.erp_propose_production_policy(v_ecode, null,
      jsonb_build_object('over_completion_pct', 2, 'release_shortage_pct', 5), null);
    return query select 'the production policy is proposed as a change, and a percentage past a hundred is refused',
      v_err like 'CLOVEERP_POLICY_VALUE_INVALID:%'
      and exists (select 1 from erp.change_set_item i
                   where i.id = v_cs and i.object_key = format('production.policy|%s|*', v_ecode)),
      v_err;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-ptol-' || v_hex);
  detail := 'the organisation, its orders and its policy rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.production_tolerance_suite() from public, anon;

create or replace function erp_test.assert_production_tolerance_suite()
returns void
language plpgsql
security definer
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
    from erp_test.production_tolerance_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PRODUCTION_TOLERANCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A works order taken past its quantity, left open short of it, scrapped past its allowance or released without its material is the case that failed. Read it.';
  end if;
  if v_total <> 10 then
    raise exception 'CLOVEERP_PRODUCTION_TOLERANCE_SUITE_SHRANK: % case(s), expected 10', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_production_tolerance_suite() from public, anon;

comment on function erp_test.assert_production_tolerance_suite() is
  'A works order is held to the production policy: no receipt of nothing or past its '
  'allowance, completion within its short allowance, scrap within its allowance and '
  'release within its shortage allowance, with no switch to override it (20260924500000).';

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
