set lock_timeout = '30s';

-- =============================================================================
-- 20261010042000  A stock shortfall says what is short and where
-- -----------------------------------------------------------------------------
-- Found looking into DN-000444 on the demonstration, 5 October. The delivery
-- posted, rightly: there was stock to take. But had there not been, the
-- person posting it would have read
--
--   "This is not allowed right now."
--   "despatch would leave FG-5000. at -5.000000 in available"
--
-- CLOVEERP_NEGATIVE_STOCK, raised by erp.apply_stock_movement() whenever a
-- movement would take a place below nought, was never registered in
-- erp_ref.refusal, so the screen fell to its generic title and the raise's
-- own text: a movement type's code, the product code with a stray full stop
-- where a batch would go, a quantity to six places, and no place at all. The
-- hint ("Only movement types marked allows_negative may drive a position
-- below zero") was written for the people who build the product, and the
-- screen rightly drops it.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. CLOVEERP_NEGATIVE_STOCK is registered: what was refused, why, and what
--      to do next, in plain words (three en strings, through
--      erp.register_refusal).
--   B. erp.apply_stock_movement() raises it naming the product by its code
--      (and batch), the place and its site by their codes, the quantity asked
--      for and the quantity there, in whole numbers where they are whole, and
--      who the stock is held for where that is not the company. Its hint, which
--      the screen shows in place of the registered next action, says the same
--      to a person:
--        "This takes 5 of FG-5000 from DESPATCH at MAIN-WH, which holds 0
--         available. Receive or move FG-5000 into a place at MAIN-WH, or
--         change the quantity, then try again."
--      The token, the errcode and when it is raised are unchanged: the same
--      movements are refused, and none that were allowed is refused.
--   C. erp_test.sales_suite gains a case (13): a despatch of more than is on
--      hand is refused by a registered refusal whose hint names the product,
--      the place, what was asked for and what is there, in words the screen
--      shows.
--
-- On production: one function is replaced, one refusal and its three strings
-- are added, a suite and its assertion are replaced. No table is altered and
-- no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The refusal, registered
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_NEGATIVE_STOCK',
  'Taking more of a product from a place than the place holds.',
  'Stock never goes below nought. A place gives out only what was received or moved into it, and stock held for '
  'somebody else cannot be given out as the company''s own.',
  'Receive or move the product into a place at the site, or change the quantity, then try again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The raise names the product, the place and both quantities
-- ─────────────────────────────────────────────────────────────────────────────

do $movement$
declare
  v_sig  constant text := 'erp.apply_stock_movement()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_to_keeper       uuid := coalesce(new.to_custody_party_id, new.custody_party_id);
begin
$o$;
  v_new1 constant text := $n$  v_to_keeper       uuid := coalesce(new.to_custody_party_id, new.custody_party_id);
  -- What a shortfall names (20261010042000).
  v_place           text;
  v_site_code       text;
  v_batch           text;
  v_held_for        text;
  v_there           numeric;
  v_status_words    text;
begin
$n$;
  v_old2 constant text := $o$    if v_resulting < 0 and not coalesce(v_allows_negative, false) then
      raise exception
        'CLOVEERP_NEGATIVE_STOCK: % would leave %.% at % in %',
        new.movement_type, v_item.code, coalesce(new.batch_id::text, ''),
        v_resulting, new.from_status
        using errcode = '23514',
              hint = 'Only movement types marked allows_negative may drive a position below zero. '
                     'A position is per owner and keeper: stock the company does not own cannot be issued as its own.';
    end if;
$o$;
  v_new2 constant text := $n$    if v_resulting < 0 and not coalesce(v_allows_negative, false) then
      -- In words a person can act on: the product, the place, what was asked
      -- for and what is there (20261010042000). Only a movement type that
      -- allows it, a count or an emergency issue, takes a place below nought.
      select l.code into v_place
        from erp.location l where l.tenant_id = new.tenant_id and l.id = new.from_location_id;
      select s.code, case when new.owner_party_id is distinct from e.party_id
                          then ' held for ' || coalesce(op.name, 'somebody else') end
        into v_site_code, v_held_for
        from erp.site s
        left join erp.entity e on e.tenant_id = s.tenant_id and e.id = s.entity_id
        left join erp.party op on op.tenant_id = new.tenant_id and op.id = new.owner_party_id
       where s.tenant_id = new.tenant_id and s.id = new.site_id;
      select ' batch ' || b.batch_number into v_batch
        from erp.batch b where b.tenant_id = new.tenant_id and b.id = new.batch_id;
      v_there := trim_scale(v_resulting + new.quantity);
      v_status_words := case new.from_status::text
                          when 'quarantine' then 'in quarantine'
                          else replace(new.from_status::text, '_', ' ') end;
      raise exception
        'CLOVEERP_NEGATIVE_STOCK: % takes % of % from % at %, which holds % %',
        new.movement_type, trim_scale(new.quantity), v_item.code || coalesce(v_batch, ''),
        coalesce(v_place, 'no place'), coalesce(v_site_code, 'no site'), v_there,
        v_status_words || coalesce(v_held_for, '')
        using errcode = '23514',
              hint = format('This takes %s of %s%s from %s at %s, which holds %s %s%s. '
                            'Receive or move %s into a place at %s, or change the quantity, then try again.',
                            trim_scale(new.quantity), v_item.code, coalesce(v_batch, ''),
                            coalesce(v_place, 'no place'), coalesce(v_site_code, 'no site'),
                            v_there, v_status_words, coalesce(v_held_for, ''),
                            v_item.code, coalesce(v_site_code, 'the site'));
    end if;
$n$;
begin
  if strpos(v_src, '20261010042000') > 0 then
    raise notice '% already names the shortfall; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e43e2baa836b1f87f21cc4e429fde655' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010042000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$movement$;

revoke all on function erp.apply_stock_movement() from public, anon;

comment on function erp.apply_stock_movement() is
  'The stock ledger''s trigger: writes each movement into the cached balance of the place it leaves and the place it '
  'reaches, refusing a reason, batch or serial the movement type or product requires and a change of hands that '
  'changes nothing. A movement that would take a place below nought is refused unless its type allows it '
  '(CLOVEERP_NEGATIVE_STOCK), naming the product, the place, what was asked for and what is there (20261010042000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The sales suite: a shortfall in words a person can act on
-- ─────────────────────────────────────────────────────────────────────────────

do $sales$
declare
  v_sig  constant text := 'erp_test.sales_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1 constant text := $o$  v_ok boolean; v_msg text;
begin
$o$;
  v_new1 constant text := $n$  v_ok boolean; v_msg text;
  v_hint text; v_err text;
begin
$n$;
  v_old2 constant text := $o$  exception when others then
    v_ok := (sqlerrm like '%NEGATIVE_STOCK%'); v_msg := left(sqlerrm,58);
  end;
  return query select 'despatching more than is on hand is refused', v_ok, v_msg;
$o$;
  v_new2 constant text := $n$  exception when others then
    v_ok := (sqlerrm like '%NEGATIVE_STOCK%'); v_msg := left(sqlerrm,58);
    v_err := sqlerrm;
    get stacked diagnostics v_hint = pg_exception_hint;
  end;
  return query select 'despatching more than is on hand is refused', v_ok, v_msg;

  -- And said so a person can act on it (20261010042000): registered, so the
  -- screen titles it, and a hint the screen shows, naming the product, the
  -- place, what was asked for and what is there. RECV holds the 300 left of
  -- the 500 received after the 200 despatched.
  return query select 'a shortfall is refused in plain words that name the product, the place, what was asked for and what is there',
    exists (select 1 from erp_ref.refusal f
             where f.code = 'CLOVEERP_NEGATIVE_STOCK' and coalesce(f.next_action, '') <> '')
      and coalesce(v_hint, '') like 'This takes 99999 of WID from RECV at MAIN, which holds 300 available. %'
      and not erp_test.sounds_internal(coalesce(v_hint, 'no_hint'))
      and coalesce(v_err, '') like '%CLOVEERP_NEGATIVE_STOCK: despatch takes 99999 of WID from RECV at MAIN, which holds 300 available%',
    coalesce(v_hint, v_err, 'nothing was refused');
$n$;
begin
  if strpos(v_src, '20261010042000') > 0 then
    raise notice '% already reads the shortfall''s words; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '8d18c7f852d250d1d8e2b28d29a5f4a2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010042000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
end
$sales$;

do $sales_assert$
declare
  v_sig  constant text := 'erp_test.assert_sales_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  c_expected constant integer := 12;
$o$;
  v_new  constant text := $n$  -- Thirteen since a shortfall names what is short and where (20261010042000).
  c_expected constant integer := 13;
$n$;
begin
  if strpos(v_src, '20261010042000') > 0 then
    raise notice '% already expects thirteen cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '12796ecafe862f09d0366013f5462aae' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261010042000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sales_assert$;

revoke all on function erp_test.sales_suite() from public, anon;
revoke all on function erp_test.assert_sales_suite() from public, anon;

comment on function erp_test.sales_suite() is
  'Selling through the shared installer: two modules installed and promoted, a receipt and a delivery moving stock '
  'through one bridge, a document posted once, a despatch of more than is on hand refused, in words naming the '
  'product, the place, what was asked for and what is there (20261010042000), lineage from quotation to order, the '
  'discount and credit bands, and dead configuration refused both ways.';

comment on function erp_test.assert_sales_suite() is
  'erp_test.sales_suite(), thirteen cases: the sales lifecycle through one installer, and a stock shortfall refused '
  'in plain words (20261010042000).';

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
