set lock_timeout = '30s';

-- =============================================================================
-- 20261008210000  A sample receipt says what became of it
-- (First written as 20261007061000; it follows 20261007081000, which also
-- edits erp.settle_samples, so a build in version order meets the body it expects.)
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-15). Samples were
-- received, then one was returned, one kept free and one bought at a price.
-- The receipt's own page showed an ordinary goods receipt: the line at the
-- price it was bought at and a net of £0.00, and nothing about what went
-- back, what was kept and what was bought.
--
-- erp.settle_samples writes the price a sample is first bought at onto the
-- receipt line (unit_price_minor), because the supplier's bill is matched
-- against it (20261004940000); net_minor stays nought, since the samples
-- arrived at no price. erp.samples(), which the Samples card reads, answered
-- only what arrived and what is still held, so nothing anywhere said what
-- had been returned, kept or bought.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.settle_samples records on the movement it writes for a sample
--      kept or bought which of the two it was, and at what price
--      (cost_context: sample_outcome, price_minor). The price on the line,
--      which billing reads, stays as it is.
--   B. erp.samples() also answers, per line, returned, kept and bought, each
--      summed from the line's movements net of any reversal, and
--      bought_price_minor, the price each was bought at (the line's, which
--      every purchase of it shares). A movement written before A is read as
--      bought where it carries a cost, and kept where it does not.
--      public.erp_samples answers the same, as it answers every column.
--      The receipt's page shows a Samples card: the purpose, when they are
--      due back, and per line what was received, returned, kept, bought and
--      at what price each, and what is still held. Its Lines card says the
--      price is each for those bought, and no longer shows a net of nothing.
--   C. The words.
--   D. erp_test.supplier_samples_suite proves what one line says after one
--      of each.
--
-- Production: one routine is patched, and one read function is dropped and
-- created again with four more columns (its return type changes; nothing
-- else reads it but public.erp_samples). No table is altered and no row is
-- changed, in any organisation. Movements already written are read as B says.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Kept or bought, on the movement
-- ─────────────────────────────────────────────────────────────────────────────

do $settle$
declare
  v_sig  constant text := 'erp.settle_samples(uuid,text,numeric,bigint,text)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$      owner_party_id, custody_party_id, to_owner_party_id, document_id, document_line_id)$o$,
$o$            d.party_id, v_company, v_company, d.id, l.id)$o$];
  v_new  text[] := array[
$n$      owner_party_id, custody_party_id, to_owner_party_id, document_id, document_line_id, cost_context)$n$,
$n$            d.party_id, v_company, v_company, d.id, l.id,
            -- Kept or bought, and at what price, said on the movement itself
            -- (20261008210000, J-15): under standard costing its unit cost
            -- is the standard, whichever it was.
            jsonb_build_object('sample_outcome', v_outcome, 'price_minor', v_price))$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261008210000') > 0 then
    raise notice '% already says kept or bought on the movement; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'c2bccfdae4e594cd3bfd560105c6f2fb' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008210000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$settle$;

comment on function erp.settle_samples(uuid, text, numeric, bigint, text) is
  'What becomes of some or all of a sample line (20261004930000): returned to the supplier, kept free or bought '
  'at the agreed price, each one movement naming the line; a movement for one kept or bought says which, and at '
  'what price (20261008210000). Authorises procurement.order at the receipt''s site.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. What became of each line
-- ─────────────────────────────────────────────────────────────────────────────

do $samples$
declare
  v_sig  constant text := 'erp.samples(boolean)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$ may_settle boolean)$o$,
$o$         erp.sample_line_held(l.id) > 0 and erp.has_permission('procurement.order', d.entity_id, d.site_id)$o$,
$o$    left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id$o$];
  v_new  text[] := array[
$n$ may_settle boolean, returned numeric, kept numeric, bought numeric, bought_price_minor bigint)$n$,
$n$         erp.sample_line_held(l.id) > 0 and erp.has_permission('procurement.order', d.entity_id, d.site_id),
         -- What became of the line (20261008210000, J-15): returned, kept
         -- free and bought, and the price each was bought at, which is the
         -- line's: every purchase of it is at the price it was first bought at.
         o.returned, o.kept, o.bought,
         case when o.bought > 0 then nullif(l.unit_price_minor, 0) end$n$,
$n$    left join erp.item i on i.tenant_id = l.tenant_id and i.id = l.item_id
    -- The line's movements, each net of its reversal. Kept or bought is what
    -- the movement says (20261008210000); one written before it said is
    -- bought where it carries a cost and kept where it does not.
    cross join lateral (
      select coalesce(sum(x.q) filter (where x.movement_type = 'return_to_supplier'), 0) as returned,
             coalesce(sum(x.q) filter (where x.movement_type = 'ownership_transfer' and x.outcome = 'keep'), 0) as kept,
             coalesce(sum(x.q) filter (where x.movement_type = 'ownership_transfer' and x.outcome = 'buy'), 0) as bought
        from (select m.movement_type,
                     case when m.is_reversal then -m.quantity else m.quantity end as q,
                     coalesce(m.cost_context ->> 'sample_outcome',
                              case when coalesce(m.unit_cost_minor, 0) > 0 then 'buy' else 'keep' end) as outcome
                from erp.stock_movement m
               where m.tenant_id = l.tenant_id and m.document_id = l.document_id
                 and m.document_line_id = l.id
                 and m.movement_type in ('return_to_supplier', 'ownership_transfer')) x
    ) o$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261008210000') > 0 then
    raise notice '% already says what became of each line; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'afd1fecd013656a8f179a13b80870776' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008210000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  -- Its return type changes, which create or replace cannot do. Nothing
  -- else depends on it: public.erp_samples names it in a body, not a type.
  drop function erp.samples(boolean);
  execute v_def2;
end
$samples$;

revoke all on function erp.samples(boolean) from public, anon;

comment on function erp.samples(boolean) is
  'The lines of suppliers'' samples, what is still held, where, for what, due back when, overdue or not, and '
  'whether the reader may settle them (20261004930000); and what became of each: returned, kept, bought and at '
  'what price each (20261008210000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A sample receipt says what became of it (20261008210000).'
  from (values
    ('Returned'),
    ('Kept'),
    ('Bought'),
    ('{price} each, for those bought')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.supplier_samples_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  text[] := array[
$o$  c_expected constant integer := 11;
$o$,
$o$    -- ── 8. What may not be settled ──────────────────────────────────────────
$o$];
  v_new  text[] := array[
$n$  -- Eleven until 20261008210000, which added what became of each line.
  c_expected constant integer := 12;
  v_bag    jsonb;
$n$,
$n$    -- ── 7b. What became of each line (20261008210000, J-15) ───────────────
    v_step := 'reading the receipt''s lines once one dress went back, one was kept and one was bought';
    select x into v_row from jsonb_array_elements(public.erp_samples(true)) x where x ->> 'line_id' = v_line::text;
    select x into v_bag from jsonb_array_elements(public.erp_samples(true)) x where x ->> 'line_id' = v_line2::text;
    v_cases := v_cases + 1;
    case_name := 'the samples list says what became of each line: of three dresses one returned, one kept and one bought at £90 each, none still held; the bag received and still held, nothing returned, kept or bought, and no price; and the kept and bought movements each say which they were';
    passed := v_state is null
          and (v_row ->> 'received')::numeric = 3
          and (v_row ->> 'returned')::numeric = 1
          and (v_row ->> 'kept')::numeric = 1
          and (v_row ->> 'bought')::numeric = 1
          and (v_row ->> 'bought_price_minor')::bigint = 9000
          and (v_row ->> 'held')::numeric = 0
          and (v_bag ->> 'received')::numeric = 1
          and (v_bag ->> 'returned')::numeric = 0
          and (v_bag ->> 'kept')::numeric = 0
          and (v_bag ->> 'bought')::numeric = 0
          and v_bag -> 'bought_price_minor' = 'null'::jsonb
          and (v_bag ->> 'held')::numeric = 1
          and (select array_agg(m.cost_context ->> 'sample_outcome' order by m.id) from erp.stock_movement m
                where m.tenant_id = rb.tenant_id and m.document_line_id = v_line
                  and m.movement_type = 'ownership_transfer') = array['keep', 'buy'];
    detail := coalesce(v_state, left(format('dresses %s; bag %s', v_row, v_bag), 700));
    return next;

    -- ── 8. What may not be settled ──────────────────────────────────────────
$n$];
  v_def2 text;
  i      integer;
begin
  if strpos(v_src, '20261008210000') > 0 then
    raise notice '% already reads what became of each line; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8beeb939782194fc566a8c8652d78006' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008210000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  v_def2 := v_def;
  for i in 1 .. array_length(v_old, 1) loop
    if (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found other than once', v_sig, i;
    end if;
    v_def2 := replace(v_def2, v_old[i], v_new[i]);
  end loop;
  execute v_def2;
end
$suite$;

do $suite_count$
declare
  v_sig  constant text := 'erp_test.assert_supplier_samples_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  if v_total <> 11 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected 11', v_total
$o$;
  v_new  constant text := $n$  -- Eleven until 20261008210000, which added what became of each line.
  if v_total <> 12 then
    raise exception 'CLOVEERP_SUPPLIER_SAMPLES_SUITE_SHRANK: % case(s), expected 12', v_total
$n$;
begin
  if strpos(v_src, '20261008210000') > 0 then
    raise notice '% already counts 12; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '4d5ef4e62ef4744772dc22c93a76a057' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261008210000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$suite_count$;

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
select erp.assert_personal_data_register_sound();
