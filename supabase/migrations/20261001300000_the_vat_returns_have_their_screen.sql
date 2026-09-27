set lock_timeout = '30s';

-- =============================================================================
-- 20261001300000  The VAT returns have their screen
-- -----------------------------------------------------------------------------
-- PR14 M4 (docs/spec/simplification-review.md §7 VAT, nodes V1 and V2): the
-- screen of the nine boxes (20261001000000), the finalised return
-- (20261001100000) and its export (20261001200000), and the demonstration's
-- returns (D12).
--
-- ── WHAT CHANGES, AND WHERE ──────────────────────────────────────────────────
--
-- The screen, /finance/vat (src/routes/finance/vat.tsx), is the VAT cycle in
-- two presses (D16): every period of each company with its due date, where it
-- stands and its box 5; the period a company finalises next with its nine
-- boxes as finalising it now would freeze them and the findings to read
-- first, blocking ones and flags; Finalise; and on each finalised return
-- Export as the nine boxes in CSV, the MTD body in JSON or its entries in CSV,
-- downloaded as the door returned it. What it needs of the database:
--
--   * public.erp_vat_obligations(), replaced whole, says what the two doors
--     would take from this reader, as the close checklist does
--     (20260929400000): take_from, the first day a return made now takes
--     entries from, which is the window finalising checks for findings;
--     can_finalise on the period a company finalises next, by the rules
--     erp.finalise_vat_return() applies (it has ended, it is the earliest not
--     finalised, the reader may close the books in the company, the tax
--     module has the return, the scheme is standard and not Northern Ireland,
--     and nothing blocks); finalise_blocked_by, the first of those that does
--     not hold, in words; can_export on a finalised return for somebody who
--     may close the books; and the company's currency. The door's name,
--     argument, gate and allowance are unchanged. The database refuses
--     regardless; this keeps the screen from drawing a refusal (X4).
--   * The four doors that waited for this screen leave erp_meta.api_only_door:
--     erp_vat_boxes, erp_vat_obligations, erp_finalise_vat_return and
--     erp_vat_return_export. The screen calls each.
--   * erp_meta.flow_budget gains the cycle vat: two presses, Finalise then
--     Export, over three steps that each keep a list. It is a new cycle, so no
--     budget rises, and the Money strip keeps its nine (§2 "Never add a step").
--     erp_test.step_budget_suite walks it, case 14.
--   * A help topic for /finance/vat, which says what the return takes and
--     that the product files nothing: bridging tools differ in what they
--     import, the CSV and the MTD JSON are the two common inputs, and no tool
--     is named or claimed. The VAT doors' help actions move to it from
--     /finance. The screen's name in English and German, and its words.
--
-- The demonstration (D12, demonstration only):
--
--   * erp.finalise_demonstration_vat_returns(through) finalises, company by
--     company and in order, every period that has ended, whose trading the
--     builder has built from its first day to the period's end, and that is
--     not the latest to have ended, which is left for somebody to finalise.
--     It does nothing on tax version 1 and refuses a live organisation.
--   * erp.seed_demo_history() calls it at the end of every slice with the
--     last day it built, so the build's demonstration (supabase/ci/
--     seed_demo.sql) and a demonstration built from the tenant screen have
--     their past quarters returned as their trading reaches each end.
--   * erp.demonstration_catch_up() takes the tax module to its current
--     version, as it does the five modules before it, and after the months
--     are closed finalises what the trading it reached allows; its answer
--     says which returns it finalised.
--
-- ── CALLS MADE HERE, FOR THE PR DESCRIPTION ──────────────────────────────────
--
--   * The page is its own screen, as /finance/close is, and its FlowSpec is a
--     declaration the page draws its three sections from, not a ProcessFlow:
--     Finalise needs the company and the period, two answers a strip's step
--     cannot carry from one chosen row, and Export's answer is a file.
--   * Finalise is one press with the boxes and findings drawn above it, not a
--     confirmation dialog, which would be a third press on a budget of two.
--   * The findings are read through erp_vat_boxes over the window the row
--     names, so the screen shows what finalising checks and the door has a
--     caller; the boxes the screen shows are the obligation's own preview.
--   * A period whose trading was never built (a demonstration begun later
--     than its registration) is not finalised as an empty return: the
--     demonstration returns quarters it traded, and a fixture seeding a few
--     recent days finalises nothing.
--   * /finance/vat is off the demo path (e2e/demo-path.ts): neither flow files
--     a return.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No new door, table, lifecycle, refusal or event.
--   * The demonstration's supplier bills still state no VAT, so its box 4 is
--     nought (S5); M5 makes them state it from the next day built.
--   * HMRC submission and the periodKey (spec §5, §11).
--
-- Proved by erp_test.vat_screens_suite, erp_test.demonstration_vat_returns_suite
-- and erp_test.step_budget_suite case 14.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. What the screen needs of the registers
-- ═════════════════════════════════════════════════════════════════════════════

-- A1. The four doors have their screen.

do $vat_homes$
declare
  v_door text;
  v_n    integer;
begin
  foreach v_door in array array['erp_vat_boxes', 'erp_vat_obligations',
                                'erp_finalise_vat_return', 'erp_vat_return_export'] loop
    delete from erp_meta.api_only_door d
     where d.function_name = v_door
       and d.caller = 'pending_screen'
       and d.intended_screen_path = '/finance/vat';
    get diagnostics v_n = row_count;
    if v_n = 1 then
      continue;
    end if;
    if exists (select 1 from erp_meta.api_only_door d where d.function_name = v_door) then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is registered, but not as the pending /finance/vat screen PR14 M1 to M3 wrote', v_door;
    end if;
    raise notice '% already has its screen; left as it is', v_door;
  end loop;
end
$vat_homes$;

-- A2. The VAT cycle's budget: two presses.

insert into erp_meta.flow_budget (flow_code, name, module_code, screen_path, budget, decision_steps,
                                  stages, stages_without_a_list, rationale)
values ('vat', 'VAT returns', 'finance', '/finance/vat', 2, 2, 3, 0,
        'A period is finalised once it has ended, in one press that freezes its nine boxes, then its '
        'return is exported, in one more, as the file the bridging software that files it reads. '
        'Periods, Finalise and Export each list the periods where they stand. Walked by '
        'erp_test.step_budget_suite by a controller who is not an administrator (20261001300000). '
        'A new cycle, off the Money strip, so no budget rises.')
on conflict (flow_code) do nothing;

do $vat_budget$
begin
  if not exists (select 1 from erp_meta.flow_budget b
                  where b.flow_code = 'vat' and b.module_code = 'finance' and b.screen_path = '/finance/vat'
                    and b.budget = 2 and b.decision_steps = 2 and b.stages = 3
                    and b.stages_without_a_list = 0 and position('20261001300000' in b.rationale) > 0) then
    raise exception 'CLOVEERP_ANCHOR_MOVED: a vat flow budget is registered, but not the 2/2/3/0 this migration writes';
  end if;
end
$vat_budget$;

-- A3. The screen's name, its help, and the help actions that move to it.

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('nav.finance_vat', 'en', 'VAT returns', 'finance',
   'Navigation key for /finance/vat, the VAT periods, their returns and their export.'),
  ('nav.finance_vat', 'de', 'Umsatzsteuer-Voranmeldungen', 'finance',
   'Navigation key for /finance/vat, the VAT periods, their returns and their export.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code,
  description = excluded.description;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/finance/vat', 'nav.finance_vat', 'finance',
   'Each company''s VAT periods, from its VAT registration and its VAT return setting, with the date each return is due and where it stands. A return takes every VAT entry dated up to its period''s end that no earlier return took: boxes 1 and 4 are the tax the ledger carries, boxes 6 and 7 the net of the same documents in whole pounds. Nothing is sent to HMRC: a finalised return is exported as a file for bridging software to file. Bridging tools differ in what they import; the nine boxes as CSV and the MTD return body as JSON are the two common inputs, and no tool is named or promised here.',
   '["Read the next period to return: its nine boxes as finalising it now would freeze them, and what to check first.","Put right anything that blocks the return, on the document it names: reverse the posting and post it again, or state the tax before it posts. A flag is for you to judge, and does not stop the return.","Finalise the period once it has ended. Its boxes are frozen, and anything posted into it later goes on the next return.","Export the finalised return in the form your bridging software reads: the nine boxes as a spreadsheet, the MTD return body, or its entries. The file is what the records give, and the export is refused if they have changed since.","File it from the bridging software, and type the filing reference into the return''s notes."]',
   'Finalise the period that is due, then export its return for your bridging software.',
   '{erp_vat_obligations,erp_vat_boxes,erp_finalise_vat_return,erp_vat_return_export}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code,
  summary = excluded.summary, steps = excluded.steps,
  next_action = excluded.next_action, actions = excluded.actions;

-- Finance's topic carried the VAT doors while they had no screen
-- (20261001100000, 20261001200000); they belong to the screen's now.
update erp_ref.help_topic h
   set actions = (select coalesce(array_agg(a order by a), '{}'::text[])
                    from unnest(h.actions) a
                   where a not in ('erp_vat_obligations', 'erp_finalise_vat_return', 'erp_vat_return_export'))
 where h.screen_path = '/finance'
   and h.actions && array['erp_vat_obligations', 'erp_finalise_vat_return', 'erp_vat_return_export'];

do $vat_help$
begin
  if not exists (select 1 from erp_ref.help_topic h where h.screen_path = '/finance') then
    raise exception 'CLOVEERP_ANCHOR_MOVED: /finance has no help topic to take the VAT doors from';
  end if;
end
$vat_help$;

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The obligations say what the doors would take
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Replaced whole, and only over the body 20261001100000 left.

do $anchor_obligations$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_vat_obligations(uuid)'::regprocedure);
begin
  if position('finalise_blocked_by' in v_src) > 0 then
    raise notice 'public.erp_vat_obligations(uuid) already says what its doors take; replaced with the same body';
  elsif md5(v_src) <> 'bf4bb9288db80035da6309c484bb6a07' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_vat_obligations(uuid) is not the body 20261001100000 left (md5 %)', md5(v_src);
  end if;
end
$anchor_obligations$;

create or replace function public.erp_vat_obligations(p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_next   jsonb := '{}'::jsonb;
begin
  if p_entity_id is null then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('finance.read', p_entity_id);
  end if;
  v_tenant := erp.current_tenant_id();

  -- The period each company finalises next takes what no return took from
  -- the registration's first day; a later one, what is dated in it.
  select coalesce(jsonb_object_agg(x.entity_id::text, x.period_end), '{}'::jsonb) into v_next
    from (select o.entity_id, min(o.period_end) as period_end
            from erp.vat_obligations(p_entity_id) o
           where o.status <> 'finalised'
           group by o.entity_id) x;

  return (
    with ob as (
      select o.*,
             coalesce((v_next ->> o.entity_id::text)::date = o.period_end, false) as is_next,
             e.base_currency::text as currency,
             (select g.valid_from from erp.entity_tax_registration g
               where g.tenant_id = v_tenant and g.entity_id = o.entity_id
                 and upper(g.registration_type) like 'VAT%' and g.valid_from <= current_date
               order by g.valid_from desc, g.created_at desc limit 1) as first_day
        from erp.vat_obligations(p_entity_id) o
        join erp.entity e on e.tenant_id = v_tenant and e.id = o.entity_id
       -- Asked for every company, the reader is answered for the companies
       -- they may read the books of.
       where erp.has_permission('finance.read', o.entity_id)
    ),
    -- What erp.finalise_vat_return() and erp.vat_return_export() ask, for
    -- this reader, in the order a person would put them right.
    asked as (
      select ob.*,
             case when ob.status = 'finalised' then null
                  when ob.is_next then ob.first_day
                  else ob.period_start end as take_from,
             erp.has_permission('finance.close_period', ob.entity_id) as may_close,
             exists (select 1 from erp.document_type dt
                      where dt.tenant_id = v_tenant and dt.base_type_code = 'vat_return'
                        and dt.status = 'active'
                        and (dt.entity_id is null or dt.entity_id = ob.entity_id)) as installed,
             erp.vat_return_policy(ob.entity_id) as policy
        from ob
    ),
    said as (
      select a.*, bx.n as blocking, bx.first_finding,
             case
               when a.status = 'finalised' then null
               when a.status = 'open' then
                 format('The period ends on %s; it can be finalised from the day after.', a.period_end)
               when not a.is_next then
                 'An earlier period is not finalised yet; finalise that one first.'
               when not a.may_close then
                 'Finalising a return is for somebody who may close the books of this company.'
               when not a.installed then
                 'This organisation''s tax module has no VAT return yet: upgrade it from Administration, Configuration.'
               when coalesce(a.policy ->> 'scheme', 'standard') <> 'standard' then
                 format('The product computes the standard scheme only, and this company''s returns are set to the %s scheme.',
                        a.policy ->> 'scheme')
               when coalesce(a.policy -> 'northern_ireland', 'false'::jsonb) <> 'false'::jsonb then
                 'This company is set as in Northern Ireland, whose boxes 2, 8 and 9 the product does not compute.'
               when bx.n > 0 then
                 format('%s finding(s) block this return, the first %s', bx.n, bx.first_finding)
             end as blocked_by
        from asked a
        -- Only where it decides anything, so a list of periods is not a
        -- scan of every entry for each.
        left join lateral (
          select count(*) as n, min(format('%s: %s', x.reference, x.detail)) as first_finding
            from erp.vat_exceptions(a.entity_id, a.first_day, a.period_end) x
           where x.blocks
             and a.is_next and a.status in ('due', 'overdue') and a.may_close and a.installed
        ) bx on true
    )
    select coalesce(jsonb_agg(
             jsonb_build_object(
               'entity_id', s.entity_id, 'company', s.company, 'vrn', s.vrn,
               'currency', s.currency, 'frequency', s.frequency, 'stagger', s.stagger,
               'period_start', s.period_start, 'period_end', s.period_end, 'due_on', s.due_on,
               'status', s.status, 'return_document_id', s.return_document_id,
               'return_number', s.return_number, 'is_next', s.is_next, 'take_from', s.take_from,
               'can_finalise', s.status in ('due', 'overdue') and s.blocked_by is null,
               'finalise_blocked_by', s.blocked_by,
               'can_export', s.status = 'finalised' and s.may_close and s.return_document_id is not null)
             || case when s.status = 'finalised' then
                  jsonb_build_object('boxes', d.attributes #> '{vat_return,boxes}',
                                     'entries', d.attributes #> '{vat_return,entries}',
                                     'carried_forward', d.attributes #> '{vat_return,carried_forward}')
                else
                  -- The preview: what finalising it now would take. There is no
                  -- stored draft (D14).
                  (erp.vat_return_figures(s.entity_id, s.period_start, s.period_end, s.take_from)
                   - 'journal_ids')
                end
             order by s.company, s.period_end), '[]'::jsonb)
      from said s
      left join erp.document d on d.tenant_id = v_tenant and d.id = s.return_document_id);
end
$$;

revoke all on function public.erp_vat_obligations(uuid) from public, anon;
grant execute on function public.erp_vat_obligations(uuid) to authenticated, service_role;

comment on function public.erp_vat_obligations(uuid) is
  'The VAT periods of each company the reader may read the books of, under finance.read '
  '(20261001100000): due dates and status, a finalised period''s frozen boxes, and for the rest the '
  'boxes finalising it now would take. Each says what the doors would take from this reader '
  '(20261001300000): take_from, can_finalise with finalise_blocked_by, and can_export.';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The demonstration's returns (D12)
-- ═════════════════════════════════════════════════════════════════════════════

-- C1. The quarters whose trading is built are returned, but the latest.

create or replace function erp.finalise_demonstration_vat_returns(p_through date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_first  date;
  o        record;
  v_res    jsonb;
  v_done   jsonb := '[]'::jsonb;
begin
  -- A demonstration's returns (20261001300000). Each company's periods that
  -- have ended are finalised in order, through erp.finalise_vat_return() and
  -- so under finance.close_period, while:
  --
  --   * the builder has built the period's trading: it began on or before
  --     the period's end, and has reached it (p_through, the last day built);
  --   * it is not the latest period to have ended, which is left for
  --     somebody to finalise on the VAT returns screen.
  --
  -- A period ending before the first day built had no trading, and is not
  -- returned empty; nor is anything after it, which it would stand in front
  -- of. Nothing is done in a live organisation, or on tax version 1, whose
  -- tax module has no VAT return until the catch-up upgrades it. A refusal is
  -- raised: the builder and the catch-up each say what stopped.
  if p_through is null or erp.environment_is_live()
     or not exists (select 1 from erp.document_type dt
                     where dt.tenant_id = v_tenant and dt.base_type_code = 'vat_return'
                       and dt.status = 'active') then
    return v_done;
  end if;

  select min(to_date(substring(d.their_reference from 6 for 8), 'YYYYMMDD')) into v_first
    from erp.document d
   where d.tenant_id = v_tenant and d.their_reference ~ '^DEMO-[0-9]{8}-';
  if v_first is null then
    return v_done;
  end if;

  for o in
    with ob as (select * from erp.vat_obligations(null)),
    latest as (select ob.entity_id, max(ob.period_end) as period_end
                 from ob where ob.status <> 'open' group by ob.entity_id)
    select ob.entity_id, ob.period_end
      from ob
      join latest l on l.entity_id = ob.entity_id
     where ob.status in ('due', 'overdue')
       and ob.period_end < l.period_end
       and ob.period_end <= p_through
       -- The earliest period with no trading stops the company there.
       and not exists (select 1 from ob e
                        where e.entity_id = ob.entity_id and e.status in ('due', 'overdue')
                          and e.period_end <= ob.period_end and e.period_end < v_first)
     order by ob.entity_id, ob.period_end
  loop
    v_res := erp.finalise_vat_return(o.entity_id, o.period_end);
    v_done := v_done || jsonb_build_array(v_res ->> 'document_number');
  end loop;
  return v_done;
end;
$$;

revoke all on function erp.finalise_demonstration_vat_returns(date) from public, anon;

comment on function erp.finalise_demonstration_vat_returns(date) is
  'A demonstration''s VAT returns (20261001300000, D12): each company''s periods that have ended and '
  'whose trading the builder has built through, finalised in order, but the latest to have ended, '
  'which is left to finalise from the screen. Returns the return numbers it made. Nothing on tax '
  'version 1 or in a live organisation. Called by erp.seed_demo_history() and '
  'erp.demonstration_catch_up().';

-- C2. The builder returns the quarters its trading reaches.

do $seed_demo_history$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  end loop days;

  if v_skipped > 0 then
$o$;
  v_new constant text := $n$  end loop days;

  -- The VAT returns of the quarters whose trading this has built through,
  -- but the latest to have ended (20261001300000, D12). What refuses is
  -- said, and the days built stand: a return is not the trading.
  if v_through is not null then
    begin
      v_vat := erp.finalise_demonstration_vat_returns(v_through);
      if jsonb_array_length(v_vat) > 0 then
        v_notes := v_notes || to_jsonb(format('VAT returns finalised: %s.',
          (select string_agg(n, ', ') from jsonb_array_elements_text(v_vat) n)));
      end if;
    exception when others then
      v_notes := v_notes || to_jsonb(format('No VAT return was finalised. %s', sqlerrm));
    end;
  end if;

  if v_skipped > 0 then
$n$;
  v_old2 constant text := $o$  r          record;
  ln         record;

begin
$o$;
  v_new2 constant text := $n$  r          record;
  ln         record;
  v_vat      jsonb;

begin
$n$;
  v_hits integer;
begin
  if position('erp.finalise_demonstration_vat_returns(' in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % end-of-days anchor found % time(s)', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % declare anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old2, v_new2);
end
$seed_demo_history$;

-- C3. The catch-up takes tax to its current version, and returns what the
--     trading it reached allows.

do $demonstration_catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  k          record;
  r          record;
begin
$o$,
    $n$  k          record;
  r          record;
  v_vat      jsonb := '[]'::jsonb;
  v_vat_before uuid[] := '{}'::uuid[];
begin
$n$,
    $o$      'Procurement controls was not upgraded, so its bills move as they did: %s', sqlerrm));
  end;
$o$,
    $n$      'Procurement controls was not upgraded, so its bills move as they did: %s', sqlerrm));
  end;

  -- ── Tax's newer version (20261001100000) ──────────────────────────────────
  --
  -- Version 2 is the VAT return: a demonstration that had tax before it is on
  -- version 1, and has obligations it cannot finalise until this.
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'tax') then
      if exists (select 1 from erp.plan_module_upgrade('tax')) then
        perform erp.upgrade_module_configuration('tax');
        v_notes := v_notes || to_jsonb(format(
          'Tax was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'tax')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Tax was not upgraded, so its VAT periods cannot be finalised: %s', sqlerrm));
  end;

  -- The returns there are before this run, so that what it finalises, the
  -- builder's days included, can be said at the end.
  select coalesce(array_agg(d.id), '{}'::uuid[]) into v_vat_before
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'vat_return';
$n$,
    $o$  return jsonb_build_object(
    'organisation',     v_code,
$o$,
    $n$  -- ── The VAT returns of the quarters whose trading is built ─────────────────
  --
  -- After the months are closed, so a return is made over books that tie.
  -- Each is the builder's rule (20261001300000): every period that has ended,
  -- whose trading the frontier has reached, but the latest, which is left for
  -- somebody to finalise. The builder finalises as each of its days reaches a
  -- quarter's end; this finalises what a run that built nothing, or the
  -- upgrade above, now allows. The answer names every return this run made.
  begin
    if v_frontier is not null then
      perform erp.finalise_demonstration_vat_returns(v_frontier);
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Its VAT periods were left as they were, because finalising refused. %s', sqlerrm));
  end;
  select coalesce(jsonb_agg(d.document_number order by d.document_number), '[]'::jsonb) into v_vat
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and dt.base_type_code = 'vat_return'
     and not (d.id = any (v_vat_before));
  if jsonb_array_length(v_vat) > 0 then
    v_notes := v_notes || to_jsonb(format('VAT returns finalised: %s.',
      (select string_agg(n, ', ') from jsonb_array_elements_text(v_vat) n)));
  end if;

  return jsonb_build_object(
    'organisation',     v_code,
$n$,
    $o$    'periods_left_open', v_stuck,
$o$,
    $n$    'periods_left_open', v_stuck,
    'vat_returns_finalised', v_vat,
$n$];
  v_hits integer;
begin
  if position('erp.finalise_demonstration_vat_returns(' in v_def) > 0 then
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
$demonstration_catch_up$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The VAT cycle, walked: erp_test.vat_walk and step_budget_suite case 14
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.vat_walk()
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  c_undo    constant text := 'CLOVEERP_VAT_WALK_UNDO';
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_code    text;
  a1        uuid := gen_random_uuid();   -- the administrator, who sets up
  s_ctl     uuid := gen_random_uuid();   -- the controller, who returns VAT
  p_ctl     uuid;
  r         record;
  res       jsonb;
  v_role    jsonb;
  v_entity  uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid; v_inv uuid;
  v_pq_from date := (date_trunc('quarter', current_date) - interval '3 months')::date;
  v_pq_to   date := date_trunc('quarter', current_date)::date - 1;
  v_before  jsonb;
  v_after   jsonb;
  v_fin     jsonb;
  v_exp     jsonb;
  v_ret     uuid;
  v_steps   jsonb := '[]'::jsonb;
  v_subs    uuid[] := '{}';
  v_block   text;
  v_out     jsonb;
begin
  -- A quarter's VAT returned by pressing (20261001300000): an organisation
  -- configured as the demonstration is, registered for VAT from the first day
  -- of last quarter, which sold in it; somebody who is not an administrator
  -- finalises the quarter and exports its return through the two doors the
  -- VAT returns screen presses.
  begin
    v_code := 'zzvatw-' || v_hex;
    select * into r from erp.provision_tenant(
      v_code, 'VAT walk', 'admin@' || v_code || '.test', 'Walk Admin');
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@' || v_code || '.test'), (s_ctl, 'controller@' || v_code || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    perform erp.ensure_demo_configuration(r.tenant_id, r.admin_user_id);

    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = r.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = r.tenant_id order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = r.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (r.tenant_id, 'ZZVWCUST', 'VAT walk customer', 'GB', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (r.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    update erp.entity_tax_registration g set valid_from = v_pq_from
     where g.tenant_id = r.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';

    -- Last quarter's trading, as a fixture: a sale supplied in it.
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZVW-A', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 50000, 'supplied last quarter');
    perform erp.set_invoice_tax_point(v_inv, v_pq_to);
    perform erp.transition_document(v_inv, 'issue', 'vat walk');

    -- The organisation's controller, saved as the Roles screen saves one.
    v_role := public.erp_save_role(null, 'controller', 'Controller', 'Reads the books, closes them and returns VAT',
                                   array['finance.read', 'finance.close_period']);
    res := public.erp_invite_principal('controller@' || v_code || '.test', 'Cara Controller');
    p_ctl := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(p_ctl, 'controller', null, null, 'returns VAT');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- ─────────────────────────────────────────────────────────────────────
    -- The cycle: Finalise, then Export. What the screen reads is read too,
    -- and is not a press.
    -- ─────────────────────────────────────────────────────────────────────
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    begin
      select o into v_before from jsonb_array_elements(public.erp_vat_obligations(null)) o
       where (o ->> 'period_end')::date = v_pq_to;
      v_fin := public.erp_finalise_vat_return(v_entity, v_pq_to);
      v_steps := v_steps || jsonb_build_object('door', 'erp_finalise_vat_return', 'person', 'controller',
                                               'result', v_fin ->> 'state');
      v_subs := v_subs || s_ctl;
      v_ret := (v_fin ->> 'document_id')::uuid;
      select o into v_after from jsonb_array_elements(public.erp_vat_obligations(null)) o
       where (o ->> 'period_end')::date = v_pq_to;
      v_exp := public.erp_vat_return_export(v_ret, 'csv');
      v_steps := v_steps || jsonb_build_object('door', 'erp_vat_return_export', 'person', 'controller',
                                               'result', v_exp ->> 'filename');
      v_subs := v_subs || s_ctl;
    exception when others then
      v_block := format('press %s: %s', jsonb_array_length(v_steps) + 1, left(sqlerrm, 300));
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_out := jsonb_build_object(
      'role_in_force', coalesce((v_role ->> 'in_force')::boolean, false),
      'live', erp.tenant_is_live(r.tenant_id),
      'presses', jsonb_array_length(v_steps),
      'people', (select count(distinct u) from unnest(v_subs) u),
      'administrators_pressing', (select count(*) from erp.organisation_administrators() a
                                   where a.app_user_id = p_ctl),
      'offered_finalise', coalesce((v_before ->> 'can_finalise')::boolean, false),
      'offered_export_before', coalesce((v_before ->> 'can_export')::boolean, false),
      'state', erp.object_current_state('document', v_ret),
      'offered_finalise_after', coalesce((v_after ->> 'can_finalise')::boolean, false),
      'offered_export', coalesce((v_after ->> 'can_export')::boolean, false),
      'status_after', v_after ->> 'status',
      'box1_minor', (v_after #>> '{boxes,box1_minor}')::bigint,
      'file_is_the_body', v_exp ->> 'sha256' = encode(sha256(convert_to(v_exp ->> 'body', 'UTF8')), 'hex'),
      'exported_events', (select count(*) from erp.event e
                           where e.tenant_id = r.tenant_id and e.aggregate_id = v_ret
                             and e.event_type = 'vat_return.exported'
                             and e.payload ->> 'sha256' = v_exp ->> 'sha256'),
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

revoke all on function erp_test.vat_walk() from public, anon;

comment on function erp_test.vat_walk() is
  'A quarter''s VAT returned by pressing (20261001300000), in a live organisation, by a controller who '
  'is not an administrator: Finalise, then Export. Returns the presses, the people, what the '
  'obligations offered before and after, the return''s state, and whether the file is the body its '
  'event digests. Rolled back. For erp_test.step_budget_suite, case 14.';

do $step_budget_suite$
declare
  v_sig constant text := 'erp_test.step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  c_expected constant integer := 13;
  v_cases   integer := 0;
$o$,
    $n$  c_expected constant integer := 14;
  v_cases   integer := 0;
$n$,
    $o$  v_close   jsonb;
begin
$o$,
    $n$  v_close   jsonb;
  v_vat     jsonb;
begin
$n$,
    $o$  if v_cases <> c_expected then
$o$,
    $n$  -- ── 14. A quarter's VAT returned, walked ───────────────────────────────
  --
  -- The budget is two (20261001300000). A controller who is not an
  -- administrator, in a live organisation that sold last quarter: Finalise,
  -- offered on the period by the obligations read, then Export, offered on
  -- the return it made, whose file is the body its event digests.
  v_vat := erp_test.vat_walk();

  v_cases := v_cases + 1;
  case_name := 'a quarter''s VAT is returned in two presses by a controller who is not an administrator, finalise and export, each offered only where its door takes it';
  passed := coalesce(v_vat ->> 'blocked' is null
            and (v_vat ->> 'role_in_force')::boolean
            and (v_vat ->> 'live')::boolean
            and (v_vat ->> 'administrators_pressing')::integer = 0
            and (v_vat ->> 'presses')::integer = 2
            and (v_vat ->> 'people')::integer = 1
            and (v_vat ->> 'offered_finalise')::boolean
            and not (v_vat ->> 'offered_export_before')::boolean
            and v_vat ->> 'state' = 'finalised'
            and v_vat ->> 'status_after' = 'finalised'
            and not (v_vat ->> 'offered_finalise_after')::boolean
            and (v_vat ->> 'offered_export')::boolean
            and (v_vat ->> 'box1_minor')::bigint = 10000
            and (v_vat ->> 'file_is_the_body')::boolean
            and (v_vat ->> 'exported_events')::integer = 1, false);
  detail := coalesce('blocked at ' || (v_vat ->> 'blocked') || '; ', '')
            || format('role in force %s, live %s, %s administrator(s) pressing; %s press(es) by %s person(s); Finalise offered %s and Export %s before; the return %s, the period %s; Finalise offered %s and Export %s after; box 1 %s; the file is the body %s, %s event(s) digest it',
                      coalesce(v_vat ->> 'role_in_force', 'unknown'), coalesce(v_vat ->> 'live', 'unknown'),
                      coalesce(v_vat ->> 'administrators_pressing', 'an unknown number of'),
                      coalesce(v_vat ->> 'presses', '0'), coalesce(v_vat ->> 'people', '0'),
                      coalesce(v_vat ->> 'offered_finalise', 'unknown'), coalesce(v_vat ->> 'offered_export_before', 'unknown'),
                      coalesce(v_vat ->> 'state', 'nothing'), coalesce(v_vat ->> 'status_after', 'unknown'),
                      coalesce(v_vat ->> 'offered_finalise_after', 'unknown'), coalesce(v_vat ->> 'offered_export', 'unknown'),
                      coalesce(v_vat ->> 'box1_minor', 'nothing'),
                      coalesce(v_vat ->> 'file_is_the_body', 'unknown'), coalesce(v_vat ->> 'exported_events', '0'));
  return next;

  if v_cases <> c_expected then
$n$];
  v_hits integer;
begin
  -- Applied already: the case is there.
  if position('erp_test.vat_walk()' in v_def) > 0 then
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
$step_budget_suite$;

do $assert_step_budget_suite$
declare
  v_sig constant text := 'erp_test.assert_step_budget_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- is case 12 (20260928400000); a month closed, walked, is case 13
  -- (20260929200000).
  c_expected constant integer := 13;
$o$;
  v_new constant text := $n$  -- is case 12 (20260928400000); a month closed, walked, is case 13
  -- (20260929200000); a quarter's VAT returned, walked, is case 14
  -- (20261001300000).
  c_expected constant integer := 14;
$n$;
  v_hits integer;
begin
  if position(v_new in v_def) > 0 then
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % expected-count anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert_step_budget_suite$;

-- D2. The export suite's first case said the door waited for this screen.

do $vat_export_suite$
declare
  v_sig constant text := 'erp_test.vat_export_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$api-only pending the VAT returns screen, a help action on Finance, and closed to anon';$o$,
    $n$reached from the VAT returns screen and a help action on it, and closed to anon (re-pinned by 20261001300000, which gave the door its screen)';$n$,
    $o$          and exists (select 1 from erp_meta.api_only_door a
                       where a.function_name = 'erp_vat_return_export' and a.caller = 'pending_screen'
                         and a.intended_screen_path = '/finance/vat')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance' and 'erp_vat_return_export' = any(h.actions))
$o$,
    $n$          and not exists (select 1 from erp_meta.api_only_door a
                           where a.function_name = 'erp_vat_return_export')
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance/vat' and 'erp_vat_return_export' = any(h.actions))
$n$];
  v_hits integer;
begin
  if position('re-pinned by 20261001300000' in v_def) > 0 then
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
$vat_export_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The suites
-- ═════════════════════════════════════════════════════════════════════════════

-- E1. What the VAT returns screen reads and presses.

create or replace function erp_test.vat_screens_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  s_ctl    uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  res      jsonb;
  v_rows   jsonb; v_rows2 jsonb; v_read jsonb; v_boxes jsonb; v_v1 jsonb; v_block jsonb;
  o_ppq    jsonb; o_pq jsonb; o_now jsonb;
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid; v_inv uuid;
  v_ret    uuid; v_num text; v_first date;
  v_pq_from date := (date_trunc('quarter', current_date) - interval '3 months')::date;
  v_pq_to  date := date_trunc('quarter', current_date)::date - 1;
  v_ppq_from date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_ppq_to date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_n integer;
  v_err text; v_err2 text; v_err3 text;
  v_files text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is, with a controller and a reader';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvs-' || v_tag, 'VAT Screens Suite',
      'admin@zzvs-' || v_tag || '.test', 'VAT Screens Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzvs-' || v_tag || '.test'),
           (s_ctl, 'controller@zzvs-' || v_tag || '.test'),
           (s_read, 'reader@zzvs-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    perform public.erp_save_role(null, 'controller', 'Controller', 'Reads the books, closes them and returns VAT',
                                 array['finance.read', 'finance.close_period']);
    res := public.erp_invite_principal('controller@zzvs-' || v_tag || '.test', 'Cara Controller');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'controller', null, null, 'returns VAT');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzvs-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, registered for VAT from the first day of the quarter before last, which sold in it';
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZVSCUST', 'VAT screens suite customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'the fixture''s company has % VAT registration(s), expected one', v_n;
    end if;
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust, current_date, v_ccy, 'ZZVS-A', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 50000, 'supplied in the quarter before last');
    perform erp.set_invoice_tax_point(v_inv, v_ppq_to);
    perform erp.transition_document(v_inv, 'issue', 'vat screens suite');

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'the registers';
    v_cases := v_cases + 1;
    case_name := 'the four VAT doors wait for no screen and are the VAT returns screen''s help actions, not Finance''s; the vat cycle is two presses over three steps that each keep a list; the screen is named in English and German';
    passed := v_state is null
          and not exists (select 1 from erp_meta.api_only_door a
                           where a.function_name in ('erp_vat_boxes', 'erp_vat_obligations',
                                                     'erp_finalise_vat_return', 'erp_vat_return_export'))
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/finance/vat' and h.nav_key = 'nav.finance_vat'
                         and h.actions @> array['erp_vat_boxes', 'erp_vat_obligations',
                                                'erp_finalise_vat_return', 'erp_vat_return_export']
                         and strpos(h.summary, 'no tool is named or promised') > 0)
          and not exists (select 1 from erp_ref.help_topic h
                           where h.screen_path = '/finance'
                             and h.actions && array['erp_vat_obligations', 'erp_finalise_vat_return',
                                                    'erp_vat_return_export'])
          and exists (select 1 from erp_meta.flow_budget b
                       where b.flow_code = 'vat' and b.module_code = 'finance'
                         and b.screen_path = '/finance/vat' and b.budget = 2 and b.decision_steps = 2
                         and b.stages = 3 and b.stages_without_a_list = 0)
          and (select count(*) from erp_ref.resource r
                where r.key = 'nav.finance_vat' and r.locale in ('en', 'de')) = 2;
    detail := coalesce(v_state, (select format('%s/%s/%s/%s', b.budget, b.decision_steps, b.stages,
                                                b.stages_without_a_list)
                                   from erp_meta.flow_budget b where b.flow_code = 'vat'));
    return next;

    -- ── 2. What the controller is offered ───────────────────────────────────
    v_step := 'the periods, read by the controller';
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    v_rows := public.erp_vat_obligations(null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select o into o_ppq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_ppq_to;
    select o into o_pq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_pq_to;
    select o into o_now from jsonb_array_elements(v_rows) o where o ->> 'status' = 'open';
    v_cases := v_cases + 1;
    case_name := 'the controller is offered Finalise on the quarter before last alone, which takes from the registration''s first day; last quarter says an earlier one is open, this one that it has not ended, and nothing is offered for export';
    passed := v_state is null
          and jsonb_array_length(v_rows) = 3
          and o_ppq ->> 'status' in ('due', 'overdue')
          and (o_ppq ->> 'is_next')::boolean
          and (o_ppq ->> 'can_finalise')::boolean
          and o_ppq -> 'finalise_blocked_by' = 'null'::jsonb
          and (o_ppq ->> 'take_from')::date = v_ppq_from
          and o_ppq ->> 'currency' = v_ccy
          and (o_ppq #>> '{boxes,box1_minor}')::bigint = 10000
          and not (o_pq ->> 'can_finalise')::boolean
          and o_pq ->> 'finalise_blocked_by' like 'An earlier period is not finalised yet%'
          and (o_pq ->> 'take_from')::date = v_pq_from
          and not (o_now ->> 'can_finalise')::boolean
          and o_now ->> 'finalise_blocked_by' like 'The period ends on %'
          and not exists (select 1 from jsonb_array_elements(v_rows) o where (o ->> 'can_export')::boolean);
    detail := coalesce(v_state, left(format('%s | %s | %s', o_ppq - 'boxes', o_pq - 'boxes', o_now - 'boxes'), 600));
    return next;

    -- ── 3. What somebody who may only read is offered ───────────────────────
    v_step := 'the periods, read by a reader of the books, who then presses Finalise anyway';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    v_read := public.erp_vat_obligations(null);
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err := 'finalised';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a reader of the books sees the same periods and is offered nothing, told that finalising is for somebody who may close the books, and the door refuses them';
    passed := v_state is null
          and jsonb_array_length(v_read) = 3
          and not exists (select 1 from jsonb_array_elements(v_read) o
                           where (o ->> 'can_finalise')::boolean or (o ->> 'can_export')::boolean)
          and exists (select 1 from jsonb_array_elements(v_read) o
                       where (o ->> 'period_end')::date = v_ppq_to
                         and o ->> 'finalise_blocked_by' like 'Finalising a return is for somebody who may close the books%')
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%';
    detail := coalesce(v_state, left(format('%s; %s', v_err,
                 (select string_agg(o ->> 'finalise_blocked_by', ' | ') from jsonb_array_elements(v_read) o)), 500));
    return next;

    -- ── 4. The findings the screen reads before Finalise ────────────────────
    v_step := 'the findings over the days the next return takes';
    v_boxes := public.erp_vat_boxes((o_ppq ->> 'take_from')::date, v_ppq_to, v_entity);
    v_cases := v_cases + 1;
    case_name := 'the findings the screen reads for the next return are one company''s, over the days finalising checks, each with a finding, whether it blocks, a reference and words; none blocks here';
    passed := v_state is null
          and jsonb_array_length(v_boxes) = 1
          and (v_boxes -> 0 ->> 'entity_id')::uuid = v_entity
          and jsonb_typeof(v_boxes -> 0 -> 'exceptions') = 'array'
          and not exists (select 1 from jsonb_array_elements(v_boxes -> 0 -> 'exceptions') x
                           where not (x ? 'finding' and x ? 'blocks' and x ? 'reference' and x ? 'detail')
                              or (x ->> 'blocks')::boolean);
    detail := coalesce(v_state, left(v_boxes::text, 400));
    return next;

    -- ── 5. A finding that blocks takes Finalise away, and says why ──────────
    v_step := 'a determination the ledger no longer agrees with, under the next return';
    begin
      update erp.tax_determination set tax_minor = tax_minor + 1
       where id = (select td.id from erp.tax_determination td
                    where td.tenant_id = rb.tenant_id and td.document_id = v_inv order by td.id limit 1);
      perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
      select o into v_block from jsonb_array_elements(public.erp_vat_obligations(v_entity)) o
       where (o ->> 'period_end')::date = v_ppq_to;
      v_boxes := public.erp_vat_boxes((o_ppq ->> 'take_from')::date, v_ppq_to, v_entity);
      begin
        perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
        v_err := 'finalised';
      exception when others then v_err := left(sqlerrm, 300); end;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      raise exception 'CLOVEERP_TAMPER_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TAMPER_ROLLED_BACK' then raise; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a finding that blocks takes Finalise away from the next return, which names the document; the screen''s findings list it as blocking, and the door refuses by name';
    passed := v_state is null
          and not (v_block ->> 'can_finalise')::boolean
          and v_block ->> 'finalise_blocked_by' like '1 finding(s) block this return, the first '
                || (select d.document_number from erp.document d where d.id = v_inv) || '%'
          and exists (select 1 from jsonb_array_elements(v_boxes -> 0 -> 'exceptions') x
                       where (x ->> 'blocks')::boolean
                         and x ->> 'reference' = (select d.document_number from erp.document d where d.id = v_inv))
          and v_err like 'CLOVEERP_VAT_RETURN_HAS_EXCEPTIONS:%';
    detail := coalesce(v_state, left(format('%s; %s', v_block ->> 'finalise_blocked_by', v_err), 500));
    return next;

    -- ── 6. Finalise, pressed ────────────────────────────────────────────────
    v_step := 'Finalise pressed by the controller on the quarter before last';
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    res := public.erp_finalise_vat_return(v_entity, v_ppq_to);
    v_ret := (res ->> 'document_id')::uuid;
    v_num := res ->> 'document_number';
    v_rows2 := public.erp_vat_obligations(null);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select o into o_ppq from jsonb_array_elements(v_rows2) o where (o ->> 'period_end')::date = v_ppq_to;
    select o into o_pq from jsonb_array_elements(v_rows2) o where (o ->> 'period_end')::date = v_pq_to;
    v_cases := v_cases + 1;
    case_name := 'after Finalise the quarter reads finalised with its return, its frozen boxes and Export offered; last quarter is next, takes what no return took from the registration''s first day, and is offered Finalise';
    passed := v_state is null
          and o_ppq ->> 'status' = 'finalised'
          and o_ppq ->> 'return_number' = v_num
          and (o_ppq ->> 'return_document_id')::uuid = v_ret
          and (o_ppq ->> 'can_export')::boolean
          and not (o_ppq ->> 'can_finalise')::boolean
          and o_ppq -> 'finalise_blocked_by' = 'null'::jsonb
          and o_ppq -> 'take_from' = 'null'::jsonb
          and o_ppq -> 'boxes' = (select d.attributes #> '{vat_return,boxes}' from erp.document d where d.id = v_ret)
          and (o_pq ->> 'is_next')::boolean
          and (o_pq ->> 'can_finalise')::boolean
          and (o_pq ->> 'take_from')::date = v_ppq_from;
    detail := coalesce(v_state, left(format('%s | %s', o_ppq - 'boxes', o_pq - 'boxes'), 600));
    return next;

    -- ── 7. Export, pressed, three ways ──────────────────────────────────────
    v_step := 'Export pressed by the controller in each form the screen offers';
    perform set_config('request.jwt.claims', json_build_object('sub', s_ctl)::text, true);
    select string_agg(format('%s|%s|%s', f, x ->> 'filename', x ->> 'media_type'), ',' order by f),
           count(*) filter (where x ->> 'sha256' = encode(sha256(convert_to(x ->> 'body', 'UTF8')), 'hex')
                              and x ->> 'filename' like v_num || '%'
                              and length(x ->> 'body') > 0)
      into v_files, v_n
      from unnest(array['csv', 'json', 'entries_csv']) f
      cross join lateral (select public.erp_vat_return_export(v_ret, f) as x) e;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'each form the screen offers hands over a body with the filename and media type it is saved under and the sha256 of exactly that body';
    passed := v_state is null
          and v_n = 3
          and v_files like 'csv|%.csv|text/csv,entries_csv|%.csv|text/csv,json|%.json|application/json';
    detail := coalesce(v_state, format('%s of 3 whole; %s', v_n, v_files));
    return next;

    -- ── 8. Export for somebody who may only read, and a tax module on v1 ────
    v_step := 'the finalised return, read and exported by a reader; the next period on tax version 1';
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    v_read := public.erp_vat_obligations(null);
    begin
      perform public.erp_vat_return_export(v_ret, 'csv');
      v_err := 'exported';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      update erp.document_type set status = 'inactive' where tenant_id = rb.tenant_id and code = 'vat_return';
      update erp.module_installation i set installer_version = 1
       where i.tenant_id = rb.tenant_id and i.install_code = 'tax';
      select o into v_v1 from jsonb_array_elements(public.erp_vat_obligations(v_entity)) o
       where (o ->> 'period_end')::date = v_pq_to;
      raise exception 'CLOVEERP_TAMPER_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_TAMPER_ROLLED_BACK' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a reader sees the finalised return with no Export and is refused it; on tax version 1 the next period is offered no Finalise and says to upgrade';
    passed := v_state is null
          and exists (select 1 from jsonb_array_elements(v_read) o
                       where o ->> 'return_number' = v_num and not (o ->> 'can_export')::boolean)
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%'
          and not (v_v1 ->> 'can_finalise')::boolean
          and v_v1 ->> 'finalise_blocked_by' like '%upgrade it from Administration, Configuration.';
    detail := coalesce(v_state, left(format('%s; %s', v_err, v_v1 ->> 'finalise_blocked_by'), 400));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 9. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzvs-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_ctl, s_read));
  detail := coalesce(v_state, 'zzvs rolled back with its invoice, return and events');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_SCREENS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.vat_screens_suite() from public, anon;

comment on function erp_test.vat_screens_suite() is
  'What the VAT returns screen reads and presses (20261001300000): its registers, the obligations '
  'offering Finalise on the next ended period alone and saying why not elsewhere, a reader offered '
  'nothing and refused, the findings read over the days finalising checks, a blocking finding taking '
  'Finalise away, Finalise and then Export offered and pressed in all three forms, a reader refused '
  'Export, and tax version 1 told to upgrade.';

create or replace function erp_test.assert_vat_screens_suite()
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
    from erp_test.vat_screens_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_SCREENS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The VAT returns screen would draw a press its door refuses, or hide one it takes. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_VAT_SCREENS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat screens: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_screens_suite() from public, anon;

comment on function erp_test.assert_vat_screens_suite() is
  'The VAT returns screen offers Finalise and Export only where their doors take them, and reads the '
  'findings finalising checks (20261001300000).';

-- E2. The demonstration's returns.

create or replace function erp_test.build_demo_days(p_from date, p_to date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_from  date := p_from;
  v_res   jsonb;
  v_built integer := 0;
  v_notes jsonb := '[]'::jsonb;
  v_calls integer := 0;
begin
  -- The days from p_from to p_to built as the catch-up builds them, a call at
  -- a time until the builder says it is done (20261001300000): one call stops
  -- when its time is spent, and says where to carry on.
  loop
    v_res := erp.seed_demo_history(v_from, p_to, 1);
    v_calls := v_calls + 1;
    v_built := v_built + coalesce((v_res ->> 'built')::integer, 0);
    v_notes := v_notes || coalesce(v_res -> 'notes', '[]'::jsonb);
    exit when coalesce((v_res ->> 'done')::boolean, true) or v_calls > 100;
    v_from := (v_res ->> 'next_from')::date;
  end loop;
  return jsonb_build_object('built', v_built, 'notes', v_notes, 'built_through', v_res -> 'built_through');
end;
$$;

revoke all on function erp_test.build_demo_days(date, date) from public, anon;

comment on function erp_test.build_demo_days(date, date) is
  'Builds a demonstration''s days from one date to another, calling erp.seed_demo_history() until it '
  'says it is done, and returns what was built and every note. For '
  'erp_test.demonstration_vat_returns_suite (20261001300000).';

create or replace function erp_test.demonstration_vat_returns_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  a1       uuid := '00000000-0000-4000-8000-00000000dc0a';
  a2       uuid := '00000000-0000-4000-8000-00000000dc0b';
  a3       uuid := '00000000-0000-4000-8000-00000000dc0c';
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  res      jsonb; res2 jsonb; v_rep jsonb; v_rep2 jsonb; v_rows jsonb; v_exp jsonb;
  bx       jsonb;
  o_ppq    jsonb; o_pq jsonb;
  v_ta     uuid; v_tb uuid;
  v_entity uuid; v_ret uuid; v_num text;
  v_ppq_from date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_pppq_from date := (date_trunc('quarter', current_date) - interval '9 months')::date;
  v_tc     uuid;
  v_ppq_to date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_pq_to  date := date_trunc('quarter', current_date)::date - 1;
  v_n integer; v_n2 integer; v_ledger bigint; v_entries integer; v_blocks integer; v_odd integer;
  v_notes text; v_ok boolean; v_msg text;
begin
  begin
    -- ── A demonstration on tax version 2, built across a quarter's end ──────
    v_step := 'a demonstration registered for VAT from the first day of the quarter before last';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('demo-zzvata', 'VAT returns demonstration',
                                                'admin@demo-zzvata.test', 'VAT Demo Admin');
    v_ta := rb.tenant_id;
    insert into auth.users (id, email)
    values (a1, 'admin@demo-zzvata.test'), (a2, 'admin@demo-zzvatb.test'), (a3, 'admin@demo-zzvatc.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    update erp.environment set is_live = false where tenant_id = v_ta and is_self;
    perform erp.ensure_demo_configuration(v_ta, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = v_ta order by e.code limit 1;
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = v_ta and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';

    v_step := 'the last week of the quarter before last, built';
    res := erp_test.build_demo_days(v_ppq_to - 6, v_ppq_to);
    v_rows := public.erp_vat_obligations(null);
    select o into o_ppq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_ppq_to;
    select o into o_pq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_pq_to;
    v_ret := (o_ppq ->> 'return_document_id')::uuid;
    v_num := o_ppq ->> 'return_number';

    -- ── 1. The builder returns the quarter its trading reached ──────────────
    v_cases := v_cases + 1;
    case_name := 'the builder finalises the quarter before last once its trading reaches the quarter''s end and says so, and leaves last quarter, the latest to have ended, to be finalised on the screen';
    passed := v_state is null
          and o_ppq ->> 'status' = 'finalised'
          and v_num = 'VAT-000001'
          and exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                       where n = 'VAT returns finalised: VAT-000001.')
          and o_pq ->> 'status' in ('due', 'overdue')
          and (o_pq ->> 'is_next')::boolean
          and (o_pq ->> 'can_finalise')::boolean
          and (select count(*) from erp.document d
                 join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                where d.tenant_id = v_ta and dt.base_type_code = 'vat_return') = 1;
    detail := coalesce(v_state, left(format('notes %s; %s | %s', res -> 'notes', o_ppq - 'boxes', o_pq - 'boxes'), 600));
    return next;

    -- ── 2. Its boxes are the ledger's ───────────────────────────────────────
    v_step := 'the demonstration''s return read against the ledger';
    select d.attributes #> '{vat_return,boxes}', (d.attributes #>> '{vat_return,entries}')::integer
      into bx, v_entries
      from erp.document d where d.id = v_ret;
    select coalesce(sum(jl.base_credit_minor - jl.base_debit_minor), 0)::bigint into v_ledger
      from erp.document d
      cross join lateral jsonb_array_elements_text(d.attributes #> '{vat_return,journal_ids}') j
      join erp.journal_line jl on jl.tenant_id = d.tenant_id and jl.journal_id = j::uuid
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id and a.control_kind = 'tax'
     where d.id = v_ret;
    select count(*) filter (where x.blocks),
           count(*) filter (where not x.blocks
                              and x.finding not in ('a purchase from abroad states no tax, and may need the reverse charge',
                                                    'an exempt supply is in the period, and box 4 claims all input tax'))
      into v_blocks, v_odd
      from erp.vat_exceptions(v_entity, v_ppq_from, v_ppq_to) x;
    v_exp := public.erp_vat_return_export(v_ret, 'csv');
    v_cases := v_cases + 1;
    case_name := 'the demonstration''s return took every entry of its week, built to the quarter''s end, charged VAT on its sales, and its boxes 1 less 4 are what tax control carries on the journals it names; nothing blocks, every finding is a flag the product raises for a judgement, and it exports';
    passed := v_state is null
          and v_entries > 0
          and v_entries = (select count(*) from erp.vat_entries(v_entity, v_ppq_from, v_ppq_to))
          and (bx ->> 'box1_minor')::bigint > 0
          and (bx ->> 'box6_pounds')::bigint > 0
          and (bx ->> 'box2_minor')::bigint = 0 and (bx ->> 'box8_pounds')::bigint = 0
          and (bx ->> 'box9_pounds')::bigint = 0
          and (bx ->> 'box3_minor')::bigint = (bx ->> 'box1_minor')::bigint
          and (bx ->> 'box5_minor')::bigint = abs((bx ->> 'box3_minor')::bigint - (bx ->> 'box4_minor')::bigint)
          and v_ledger = (bx ->> 'box1_minor')::bigint - (bx ->> 'box4_minor')::bigint
          and v_blocks = 0 and v_odd = 0
          and v_exp ->> 'document_number' = v_num;
    detail := coalesce(v_state, format('%s entries; boxes %s; tax control %s; %s blocking, %s other finding(s)',
                                       v_entries, bx, v_ledger, v_blocks, v_odd));
    return next;

    -- ── 3. Built again, nothing more is returned ────────────────────────────
    v_step := 'the same week built again';
    res2 := erp_test.build_demo_days(v_ppq_to - 6, v_ppq_to);
    v_cases := v_cases + 1;
    case_name := 'the same days built again return nothing more: the latest quarter to have ended is still left';
    passed := v_state is null
          and not exists (select 1 from jsonb_array_elements_text(res2 -> 'notes') n where n like 'VAT returns finalised%')
          and (select count(*) from erp.document d
                 join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                where d.tenant_id = v_ta and dt.base_type_code = 'vat_return') = 1;
    detail := coalesce(v_state, left((res2 -> 'notes')::text, 400));
    return next;

    -- ── A demonstration still on tax version 1 ──────────────────────────────
    v_step := 'a second demonstration, put back to tax version 1';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('demo-zzvatb', 'VAT returns catch-up',
                                                'admin@demo-zzvatb.test', 'VAT Catch-up Admin');
    v_tb := rb.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    update erp.environment set is_live = false where tenant_id = v_tb and is_self;
    perform erp.ensure_demo_configuration(v_tb, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = v_tb order by e.code limit 1;
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = v_tb and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    update erp.document_type set status = 'inactive' where tenant_id = v_tb and code = 'vat_return';
    update erp.state_machine set status = 'inactive' where tenant_id = v_tb and code = 'vat_return';
    update erp.module_installation i set installer_version = 1
     where i.tenant_id = v_tb and i.install_code = 'tax';

    v_step := 'the same week built on tax version 1, and yesterday and today';
    res := erp_test.build_demo_days(v_ppq_to - 6, v_ppq_to);
    res2 := erp_test.build_demo_days(current_date - 1, current_date);
    select count(*) into v_n from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tb and dt.base_type_code = 'vat_return';
    select count(*) into v_n2 from erp.vat_obligations(v_entity) o where o.status in ('due', 'overdue');

    -- ── 4. On version 1 the builder returns nothing ─────────────────────────
    v_cases := v_cases + 1;
    case_name := 'on tax version 1 the builder builds its days and finalises nothing, and every period that has ended waits';
    passed := v_state is null
          and v_n = 0 and v_n2 = 2
          and not exists (select 1 from jsonb_array_elements_text(res -> 'notes') n
                           where n like 'VAT returns finalised%' or n like 'No VAT return was finalised%')
          and (res ->> 'built')::integer > 0;
    detail := coalesce(v_state, format('%s return(s), %s period(s) waiting; notes %s', v_n, v_n2, res -> 'notes'));
    return next;

    -- ── 5. The catch-up takes tax to version 2 and returns what it may ──────
    v_step := 'the catch-up';
    v_rep := erp.demonstration_catch_up();
    v_notes := (select string_agg(n, ' | ') from jsonb_array_elements_text(v_rep -> 'notes') n);
    v_rows := public.erp_vat_obligations(v_entity);
    select o into o_ppq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_ppq_to;
    select o into o_pq from jsonb_array_elements(v_rows) o where (o ->> 'period_end')::date = v_pq_to;
    v_cases := v_cases + 1;
    case_name := 'the catch-up, with no day left to build, takes tax to its current version and finalises the quarter before last, whose trading was built, and says so; last quarter is left due for somebody to finalise';
    passed := v_state is null
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = v_tb and i.install_code = 'tax')
              = (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'tax')
          and strpos(coalesce(v_notes, ''), 'Tax was upgraded to version 2.') > 0
          and strpos(coalesce(v_notes, ''), 'VAT returns finalised: VAT-000001.') > 0
          and v_rep -> 'vat_returns_finalised' = '["VAT-000001"]'::jsonb
          and (v_rep ->> 'documents_built')::integer = 0
          and o_ppq ->> 'status' = 'finalised'
          and o_pq ->> 'status' in ('due', 'overdue')
          and (o_pq ->> 'can_finalise')::boolean
          and coalesce(v_notes, '') not ilike '%refused%'
          and coalesce(v_notes, '') not ilike '%would not build%';
    detail := coalesce(v_state, left(format('finalised %s; notes %s', v_rep -> 'vat_returns_finalised', v_notes), 700));
    return next;

    -- ── 6. Again, nothing more ──────────────────────────────────────────────
    v_step := 'the catch-up again';
    v_rep2 := erp.demonstration_catch_up();
    v_cases := v_cases + 1;
    case_name := 'the catch-up run again finalises nothing more, and upgrades nothing';
    passed := v_state is null
          and v_rep2 -> 'vat_returns_finalised' = '[]'::jsonb
          and not exists (select 1 from jsonb_array_elements_text(v_rep2 -> 'notes') n
                           where n like 'Tax was upgraded%' or n like 'VAT returns finalised%');
    detail := coalesce(v_state, left((v_rep2 -> 'notes')::text, 400));
    return next;

    -- ── 7. The books ────────────────────────────────────────────────────────
    v_cases := v_cases + 1;
    begin
      v_msg := erp.assert_vat_agrees_with_ledger() || '; ' || erp.assert_subledger_reconciles()
               || '; ' || erp.assert_trial_balance_balances();
      v_ok := true;
    exception when others then
      v_ok := false;
      v_msg := left(sqlerrm, 300);
    end;
    case_name := 'after the returns, the VAT entries of every finalised return agree with the ledger, and the subledgers and the trial balance tie';
    passed := v_state is null and v_ok;
    detail := coalesce(v_state, v_msg);
    return next;

    -- ── 8. A quarter never traded is not returned empty ─────────────────────
    v_step := 'a third demonstration, registered a quarter before its trading begins';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant('demo-zzvatc', 'VAT returns before the trading',
                                                'admin@demo-zzvatc.test', 'VAT Early Admin');
    v_tc := rb.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    update erp.environment set is_live = false where tenant_id = v_tc and is_self;
    perform erp.ensure_demo_configuration(v_tc, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = v_tc order by e.code limit 1;
    update erp.entity_tax_registration g set valid_from = v_pppq_from
     where g.tenant_id = v_tc and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    res := erp_test.build_demo_days(v_ppq_to - 6, v_ppq_to);
    select count(*) into v_n from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tc and dt.base_type_code = 'vat_return';
    select count(*) into v_n2 from erp.vat_obligations(v_entity) o where o.status in ('due', 'overdue');
    v_cases := v_cases + 1;
    case_name := 'a quarter that ended before the demonstration''s trading began is not returned empty, and the traded quarter behind it waits with it';
    passed := v_state is null
          and v_n = 0 and v_n2 = 3
          and (res ->> 'built')::integer > 0;
    detail := coalesce(v_state, format('%s return(s), %s period(s) waiting; notes %s', v_n, v_n2, res -> 'notes'));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 9. Undone ─────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code in ('demo-zzvata', 'demo-zzvatb', 'demo-zzvatc'))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, a3));
  detail := coalesce(v_state, 'the three demonstrations rolled back with their trading, returns and upgrade');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_vat_returns_suite() from public, anon;

comment on function erp_test.demonstration_vat_returns_suite() is
  'The demonstration''s VAT returns (20261001300000, D12): the builder finalises each quarter its '
  'trading reaches, but the latest to have ended; the return is the ledger''s and nothing in it '
  'blocks; nothing more on a rebuild; nothing on tax version 1, until the catch-up upgrades tax and '
  'finalises what it may, once; the books still tie; and a quarter never traded is not returned empty.';

create or replace function erp_test.assert_demonstration_vat_returns_suite()
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
    from erp_test.demonstration_vat_returns_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A demonstration would show no finalised quarter, return one it never traded, or leave none to finalise. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_DEMONSTRATION_VAT_RETURNS_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration vat returns: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_vat_returns_suite() from public, anon;

comment on function erp_test.assert_demonstration_vat_returns_suite() is
  'A demonstration''s past quarters are finalised as its trading reaches them, the latest left to '
  'finalise, on tax version 2 or once the catch-up upgrades it (20261001300000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The words the screen says
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Each with a row a tenant can rename it by: the ui() literals of
-- src/routes/finance/vat.tsx, the words it passes to ui() from its cycle's
-- declaration and src/lib/vat-returns.ts, the tile in src/lib/modules.tsx, and
-- the Tax report's reworded description.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string of the VAT returns screen, its tile, or the Tax report panel (20261001300000).'
  from (values
    ('Blocks the return'),
    ('Check'),
    ('Company'),
    ('Due on'),
    ('Due'),
    ('Export'),
    ('Finalise'),
    ('Finalised'),
    ('Net VAT'),
    ('Nothing to check before finalising.'),
    ('Open'),
    ('Overdue'),
    ('Period'),
    ('Reading the VAT periods…'),
    ('Reading what to check…'),
    ('Return'),
    ('Saved'),
    ('State'),
    ('They are more than a return may correct under VAT Notice 700/45: decide whether to notify HMRC separately.'),
    ('entries dated in an earlier period are carried into this return.'),
    ('entries'),
    ('payable'),
    ('repayable'),
    ('No VAT periods. A company has periods once its VAT registration is recorded on it.'),
    ('A return takes every VAT entry dated up to its period''s end that no earlier return took, so something posted late into a finalised quarter is in the next return. Boxes 1 and 4 are the tax the ledger carries; boxes 6 and 7 are the net of the same documents, in whole pounds. Finalising freezes the boxes, and an error in a finalised return is corrected by posting the correction, which the next return takes. The product does not send anything to HMRC: the return is filed from bridging software, which reads the exported file. Bridging tools differ in what they import — most read a spreadsheet of the nine boxes, some the MTD return body as JSON — so check which yours reads; no tool is named or promised here.'),
    ('Periods'),
    ('Every VAT period of each company, with its due date and where it stands.'),
    ('The next period to return, once it has ended: its nine boxes and what to check first.'),
    ('A finalised return, as a file for the bridging software that files it.'),
    ('Nine boxes (CSV)'),
    ('MTD body (JSON)'),
    ('Entries (CSV)'),
    ('VAT due on sales'),
    ('VAT due on EU acquisitions, Northern Ireland'),
    ('Total VAT due'),
    ('VAT reclaimed on purchases'),
    ('Sales excluding VAT'),
    ('Purchases excluding VAT'),
    ('Goods supplied to the EU, Northern Ireland'),
    ('Goods acquired from the EU, Northern Ireland'),
    ('VAT returns'),
    ('Each VAT period with its due date and nine boxes from the ledger, finalised in one press and exported for the bridging software that files it.'),
    ('Taxable amount and tax by code, for this calendar quarter so far, signed: credit notes and reversals reduce it, as they do the ledger. Returns are made from VAT returns.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- Named rather than counted: a seed that quietly inserted all but one would
-- leave the last to the build.
do $seeded$
declare v_missing text;
begin
  select string_agg(w.text, ' | ') into v_missing
    from (values
    ('Blocks the return'),
    ('Check'),
    ('Company'),
    ('Due on'),
    ('Due'),
    ('Export'),
    ('Finalise'),
    ('Finalised'),
    ('Net VAT'),
    ('Nothing to check before finalising.'),
    ('Open'),
    ('Overdue'),
    ('Period'),
    ('Reading the VAT periods…'),
    ('Reading what to check…'),
    ('Return'),
    ('Saved'),
    ('State'),
    ('They are more than a return may correct under VAT Notice 700/45: decide whether to notify HMRC separately.'),
    ('entries dated in an earlier period are carried into this return.'),
    ('entries'),
    ('payable'),
    ('repayable'),
    ('No VAT periods. A company has periods once its VAT registration is recorded on it.'),
    ('A return takes every VAT entry dated up to its period''s end that no earlier return took, so something posted late into a finalised quarter is in the next return. Boxes 1 and 4 are the tax the ledger carries; boxes 6 and 7 are the net of the same documents, in whole pounds. Finalising freezes the boxes, and an error in a finalised return is corrected by posting the correction, which the next return takes. The product does not send anything to HMRC: the return is filed from bridging software, which reads the exported file. Bridging tools differ in what they import — most read a spreadsheet of the nine boxes, some the MTD return body as JSON — so check which yours reads; no tool is named or promised here.'),
    ('Periods'),
    ('Every VAT period of each company, with its due date and where it stands.'),
    ('The next period to return, once it has ended: its nine boxes and what to check first.'),
    ('A finalised return, as a file for the bridging software that files it.'),
    ('Nine boxes (CSV)'),
    ('MTD body (JSON)'),
    ('Entries (CSV)'),
    ('VAT due on sales'),
    ('VAT due on EU acquisitions, Northern Ireland'),
    ('Total VAT due'),
    ('VAT reclaimed on purchases'),
    ('Sales excluding VAT'),
    ('Purchases excluding VAT'),
    ('Goods supplied to the EU, Northern Ireland'),
    ('Goods acquired from the EU, Northern Ireland'),
    ('VAT returns'),
    ('Each VAT period with its due date and nine boxes from the ledger, finalised in one press and exported for the bridging software that files it.'),
    ('Taxable amount and tax by code, for this calendar quarter so far, signed: credit notes and reversals reduce it, as they do the ledger. Returns are made from VAT returns.')
    ) as w(text)
   where not exists (select 1 from erp_ref.resource r
                      where r.key = erp_ref.ui_key(w.text) and r.locale = 'en');
  if v_missing is not null then
    raise exception 'CLOVEERP_SCREEN_STRING_UNSEEDED: % has no en resource row, so no tenant can rename it', v_missing
      using errcode = '23503',
            hint = 'erp_ref.ui_key() keys the row; insert it above rather than leaving it to supabase/ci/screen_strings.sh.';
  end if;
end
$seeded$;

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
select erp.assert_no_dead_configuration();
select erp.assert_every_posting_can_be_undone();
