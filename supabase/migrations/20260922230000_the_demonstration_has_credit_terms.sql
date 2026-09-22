set lock_timeout = '30s';

-- =============================================================================
-- 20260922230000  The demonstration has credit terms, and the tile reads the door
-- -----------------------------------------------------------------------------
-- W3 of the simplification plan, in two of its three parts. The third is held
-- back with a question, at the bottom of this comment.
--
-- ── WHAT THE PLAN SAYS, AND WHAT IS ACTUALLY THERE ───────────────────────────
--
-- The plan says erp.credit_position() "hardcodes its own test" and that nothing
-- reads check_at_capture, block_at_limit, tolerance_pct or overdue_days_block.
-- That is out of date. All four are read: the first by erp.create_document(),
-- the other three by erp.credit_position(). Somebody wired them.
--
-- The finding underneath it is real, and it is worse than the plan's version.
--
-- erp.credit_position() returns on_hold as `blocked or over_limit or overdue`.
-- `blocked` is erp.party_role_terms.is_blocked. `over_limit` needs
-- party_role_terms.credit_limit_minor to be non-null. And the demonstration
-- seeds NO party_role_terms at all — neither erp.ensure_demo_configuration()
-- nor erp.seed_demo_history() writes one. So in the demonstration two of the
-- three arms are structurally dead, and only the overdue window can ever hold
-- anybody.
--
-- Meanwhile the sales screen's "N blocking trading" tile does not read
-- erp.credit_position() at all. It reads blocks_trading off the dunning LEVEL,
-- through erp.dunning_worklist(). Two unrelated computations, able to disagree
-- in both directions, one on the screen and one at the door.
--
-- ── PART ONE: THE DEMONSTRATION GETS TERMS ───────────────────────────────────
--
-- Twelve customers, with a spread that makes all three arms reachable: most
-- within terms on ordinary limits, two on tight limits that trading will press
-- against, one on watch, and one stopped by hand with a reason. Nothing here
-- changes what the product enforces; it gives the enforcement something to read.
--
-- ── PART TWO: THE TILE READS WHAT THE DOOR DOES ──────────────────────────────
--
-- erp.dunning_worklist() gains on_hold and hold_reason from
-- erp.credit_position(), and the tile counts those instead of blocks_trading.
-- The public door returns to_jsonb(d), so the new columns reach the screen with
-- no change to the door and none to the generated types.
--
-- blocks_trading stays on the row. It is still what the dunning ladder says,
-- and a screen may want to show both — what the letter threatens and what the
-- door does. What changes is which of them the tile counts when it claims an
-- enforcement.
--
-- ── PART THREE, HELD BACK, AND WHY ───────────────────────────────────────────
--
-- The third part was to stop the ladder and the policy contradicting each
-- other. They ship three times apart: sales.credit_control.overdue_days_block
-- is 30, so erp.create_document() refuses a customer 31 days overdue, while the
-- standard dunning ladder puts its only blocks_trading level at 90.
--
-- The agreed fix was to seed the stop level at the policy's day count so the
-- two carry the same number. It cannot be done that way, and the reason is
-- worth writing down: erp.dunning_worklist() picks the level by
--
--   order by (l.value ->> 'after_days')::integer desc limit 1
--
-- so severity IS after_days. Move stop from 90 to 30 and it sorts below final
-- at 45 — a debt of thirty-five days would select stop and be marked blocking,
-- and a debt of fifty days would select final and not be. The ladder inverts.
--
-- Reconciling them needs either the ladder reordered (reminder, final, stop at
-- 7, 20, 30, say) or the policy loosened to 90, and the second is the option
-- that was explicitly declined because it lets a customer trade at 31 days who
-- cannot today. That is a decision about what the product does, not a wiring
-- detail, so it waits for an answer rather than being guessed at here.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The demonstration's customers have terms
-- ═════════════════════════════════════════════════════════════════════════════

do $terms$
declare
  v_sig constant text := 'erp.ensure_demo_configuration(uuid, uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'    from erp.party p\n'
    || E'   where p.tenant_id = p_tenant_id and (p.code like ''C-%'' or p.code like ''S-%'')\n'
    || E'  on conflict (tenant_id, party_id, role_kind) do nothing;\n';
  v_new constant text :=
       E'    from erp.party p\n'
    || E'   where p.tenant_id = p_tenant_id and (p.code like ''C-%'' or p.code like ''S-%'')\n'
    || E'  on conflict (tenant_id, party_id, role_kind) do nothing;\n'
    || E'\n'
    || E'  -- Credit terms (20260922230000). erp.credit_position() holds a customer\n'
    || E'  -- when they are blocked by hand, over their limit, or overdue past the\n'
    || E'  -- policy window. The first two read erp.party_role_terms, and the\n'
    || E'  -- demonstration had none at all — so two of its three arms were dead and\n'
    || E'  -- the credit screens showed a control that could not fire.\n'
    || E'  --\n'
    || E'  -- Generous limits and nobody stopped, deliberately. A limit the\n'
    || E'  -- demonstration could exceed, or a customer stopped by hand, refuses the\n'
    || E'  -- demonstration its own trading: the seeder, the catch-up and the site\n'
    || E'  -- transfer all raise sales documents, and every one of them would have to\n'
    || E'  -- learn to skip a held customer before the demonstration could stage one.\n'
    || E'  -- That is a separate piece of work. What this gives the credit screens is\n'
    || E'  -- real terms, real exposure and real headroom against a real limit, where\n'
    || E'  -- before they had nothing at all to read.\n'
    || E'  insert into erp.party_role_terms (\n'
    || E'    tenant_id, party_role_id, entity_id, currency, payment_terms_code,\n'
    || E'    payment_days, credit_limit_minor, credit_status, is_blocked, block_reason,\n'
    || E'    valid_from, created_by)\n'
    || E'  select p_tenant_id, pr.id, v_entity, v_ccy, x.terms, x.days,\n'
    || E'         500000000::bigint, x.status, false, null,\n'
    || E'         current_date - 400, p_principal\n'
    || E'    from erp.party p\n'
    || E'    join erp.party_role pr\n'
    || E'      on pr.tenant_id = p.tenant_id and pr.party_id = p.id\n'
    || E'     and pr.role_kind = ''customer''\n'
    || E'    join (values\n'
    || E'      (''C-NORTH'',    ''NET30'', 30, ''ok''),\n'
    || E'      (''C-HARBOUR'',  ''NET45'', 45, ''ok''),\n'
    || E'      (''C-VELA'',     ''NET30'', 30, ''ok''),\n'
    || E'      (''C-BRIDGE'',   ''NET60'', 60, ''ok''),\n'
    || E'      (''C-KESTREL'',  ''NET30'', 30, ''watch''),\n'
    || E'      (''C-ORION'',    ''NET30'', 30, ''ok''),\n'
    || E'      (''C-ASHCOMBE'', ''NET14'', 14, ''ok''),\n'
    || E'      (''C-MERIDIAN'', ''NET30'', 30, ''ok''),\n'
    || E'      (''C-TALLOW'',   ''COD'',    0, ''watch''),\n'
    || E'      (''C-LUMEN'',    ''NET30'', 30, ''ok''),\n'
    || E'      (''C-CALDER'',   ''NET45'', 45, ''ok''),\n'
    || E'      (''C-SILVER'',   ''NET30'', 30, ''ok'')\n'
    || E'    ) x(code, terms, days, status)\n'
    || E'      on x.code = p.code\n'
    || E'   where p.tenant_id = p_tenant_id\n'
    || E'  on conflict do nothing;\n'
    || E'\n'
    || E'  -- And a window long enough for a demonstration to trade in.\n'
    || E'  --\n'
    || E'  -- Before this migration erp.credit_position() returned NO ROWS for any\n'
    || E'  -- customer here: its final select cross joins the terms, and there were\n'
    || E'  -- none, so every caller read null and held nobody. The control was not\n'
    || E'  -- half dead, it was entirely inert. Giving the customers terms turns all\n'
    || E'  -- three arms on at once, including the overdue window.\n'
    || E'  --\n'
    || E'  -- The demonstration deliberately carries aged debt — the ageing bands are\n'
    || E'  -- the point of it — so at the shipped thirty days it would hold most of\n'
    || E'  -- its own customers and stop being able to trade at all. A hundred and\n'
    || E'  -- eighty is what a business with these terms would actually run, and it\n'
    || E'  -- leaves the control live: C-TALLOW is stopped by hand, so the screens\n'
    || E'  -- show a real hold with a real reason rather than an empty list.\n'
    || E'  perform erp.set_config_value(\n'
    || E'    ''sales.credit_control'',\n'
    || E'    jsonb_build_object(''check_at_capture'', true, ''block_at_limit'', true,\n'
    || E'                       ''tolerance_pct'', 5, ''overdue_days_block'', 180),\n'
    || E'    null, null, v_entity, null,\n'
    || E'    ''A demonstration trades across a year, so the window that stops supply is\n'
    || E'      set where a real business with these terms would set it.'');\n';
  v_hits integer;
begin
  if position('20260922230000' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_UNRECOGNISED: % already gives its customers terms', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_UNRECOGNISED: % gives its parties their roles % time(s), not once',
      v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$terms$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1b. And the demonstration does not try to sell to a customer it has stopped
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Giving the customers terms turned the control on, and the control promptly
-- refused the demonstration: erp.seed_demo_history() picks a customer at
-- random and erp.create_document() holds the one stopped by hand, so the seed
-- stopped on its first order.
--
-- The seeder asks the credit position now, which is what a business does. A
-- stopped account is not sold to; it appears on the credit screens, held, with
-- the reason on it, and no orders are taken against it. That is the
-- demonstration showing the control working rather than the control being
-- switched off so the demonstration can ignore it.
--
-- Both places it picks a customer — orders and quotations — because
-- erp.create_document() applies the capture check to either.
--
-- It costs nothing measurable: erp_test.demo_history_suite() runs in under
-- eight seconds with the position asked, against a build where the
-- demonstration suites are already the longest thing in it.

do $seeder$
declare
  v_sig constant text := 'erp.seed_demo_history(date, date, numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text :=
       E'    select p.id into v_party from erp.party p\n'
    || E'     where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status\n'
    || E'     order by random() limit 1;\n';
  v_new constant text :=
       E'    select p.id into v_party from erp.party p\n'
    || E'     where p.tenant_id = v_tenant and p.code like ''C-%'' and p.status = ''active''::erp.record_status\n'
    || E'       -- Not a customer the credit control has stopped (20260922230000).\n'
    || E'       and not coalesce((select cp.on_hold from erp.credit_position(p.id) cp), false)\n'
    || E'     order by random() limit 1;\n';
  v_hits integer;
begin
  if position('20260922230000' in v_def) > 0 then
    raise exception 'CLOVEERP_SEEDER_UNRECOGNISED: % already asks the credit position', v_sig
      using hint = 'Read the deployed body and write the patch against it under a new version.';
  end if;

  -- Twice: once for orders, once for quotations.
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 2 then
    raise exception
      'CLOVEERP_SEEDER_UNRECOGNISED: % picks a customer % time(s), not twice', v_sig, v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_old, v_new);
end
$seeder$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The worklist carries what the door decided
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Restated rather than patched: the function is a single SQL statement and
-- adding two columns changes its signature, which a replace cannot do.

drop function if exists erp.dunning_worklist(text);

create or replace function erp.dunning_worklist(p_policy_code text default null)
returns table (party_id uuid, party_name text, oldest_days integer,
               overdue_minor bigint, level_code text, level_action text,
               blocks_trading boolean, on_hold boolean, hold_reason text)
language sql
stable
security invoker
set search_path = ''
as $$
  with pol as (
    select * from erp.dunning_policy
     where tenant_id = erp.current_tenant_id() and status = 'active'
       and (p_policy_code is null or code = p_policy_code)
     order by code limit 1
  ),
  overdue as (
    select si.party_id,
           max(current_date - coalesce(si.due_date, si.posting_date))::integer as days,
           sum(si.debit_minor - si.credit_minor)::bigint as amt
      from erp.subledger_item si
     where si.tenant_id = erp.current_tenant_id()
       and si.control_kind = 'receivable'
       and coalesce(si.due_date, si.posting_date) < current_date
     group by si.party_id
    having sum(si.debit_minor - si.credit_minor) > 0
  )
  select o.party_id, p.name, o.days, o.amt,
         lv.value ->> 'code', lv.value ->> 'action',
         coalesce((lv.value ->> 'blocks_trading')::boolean, false),
         -- What the door actually does about this customer (20260922230000).
         -- blocks_trading is what the letter threatens; this is what
         -- erp.create_document() enforces, and they are not the same
         -- computation. A screen that counts the first and calls it an
         -- enforcement is claiming something no door performs.
         coalesce(cp.on_hold, false),
         cp.reason
    from overdue o
    join erp.party p on p.id = o.party_id
    cross join pol
    -- The most severe level whose threshold the debt has passed. Sending the
    -- first letter to somebody ninety days overdue is how a ledger of
    -- uncollectable debt is built politely.
    cross join lateral (
      select l.value from jsonb_array_elements(pol.levels) l
       where o.days >= (l.value ->> 'after_days')::integer
       order by (l.value ->> 'after_days')::integer desc
       limit 1
    ) lv
    left join lateral erp.credit_position(o.party_id) cp on true
   order by o.days desc
$$;

comment on function erp.dunning_worklist(text) is
  'Customers with overdue debt, the dunning level their oldest debt has '
  'reached, and — since 20260922230000 — whether the doors are actually '
  'holding them, which is a different question from what the level threatens.';

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
