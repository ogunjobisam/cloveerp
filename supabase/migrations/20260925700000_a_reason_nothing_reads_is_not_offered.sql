set lock_timeout = '30s';

-- =============================================================================
-- 20260925700000  A reason nothing reads is not offered
-- -----------------------------------------------------------------------------
-- PR9, the dead configuration gate, first of its cleanups: node W5 of
-- docs/spec/simplification-review.md names "unused reason codes" among the
-- configuration the gate must refuse. Checked against the built database
-- before it was built.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * The register of reasons offered eleven categories and the product reads
--     three: a stock adjustment, a customer return and a return to a
--     supplier, each through erp.check_reason_code(). Scrap, order hold,
--     order cancellation, approval rejection, batch amendment, allocation
--     override, price override and period reopen were categories an
--     organisation could fill with codes, mark as needing a note or an
--     approval, and nothing would ever ask: the door that reopens a period
--     takes its reason as words, and so do the others. Forty-seven codes in
--     the catalogue and fifty-nine in the packs said a control existed where
--     none did.
--   * Nothing would have said so.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp_ref.reason_category says whether it is offered. The eight nothing reads are
--     retired: kept, because an organisation's own codes name them, but not
--     offered. Wiring one to its door is a product change that adds a field to
--     that door, and is left to the node that needs it.
--   * Their codes leave the catalogue and the packs, erp.upsert_reason_code()
--     refuses a retired category, and an organisation's codes in one are made
--     inactive rather than deleted: nothing ever read them, and a record of
--     what somebody set up is kept.
--   * The vocabulary door and the Configuration screen offer the three.
--   * The dead configuration report names a category offered that no
--     function reads.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. A category nothing reads is retired
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp_ref.reason_category
  add column if not exists is_offered boolean not null default true;

comment on column erp_ref.reason_category.is_offered is
  'True where some function reads the category through erp.check_reason_code(); false where '
  'nothing does, so it is retired and not offered (20260925700000).';

update erp_ref.reason_category
   set is_offered = false
 where code in ('SCRAP', 'ORDER_HOLD', 'ORDER_CANCEL', 'APPROVAL_REJECT', 'BATCH_AMENDMENT',
                'ALLOCATION_OVERRIDE', 'PRICE_OVERRIDE', 'PERIOD_REOPEN');

delete from erp_ref.pack_item pi
 where pi.object_kind = 'reason_code'
   and pi.payload ->> 'category' in (select c.code from erp_ref.reason_category c where not c.is_offered);

delete from erp_ref.reason_code rc
 where rc.category_code in (select c.code from erp_ref.reason_category c where not c.is_offered);

-- A live organisation's configuration moves by change set, and the guard says
-- so; this is the platform retiring what it shipped, not an organisation
-- changing its mind, and it cannot be done by change set because the upsert
-- it would promote is refused below. The guard comes off for one statement and
-- goes straight back, inside the same transaction (as 20260904980000 did).
-- Found on review: an organisation that applied the base pack holds these
-- codes, and the plain update aborted the migration.
alter table erp.reason_code disable trigger t_reason_code_live_guard;
update erp.reason_code r
   set status = 'inactive', updated_at = now()
 where r.status = 'active'
   and r.category_code in (select c.code from erp_ref.reason_category c where not c.is_offered);
alter table erp.reason_code enable trigger t_reason_code_live_guard;

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. A retired category takes no new code, and is not offered
-- ─────────────────────────────────────────────────────────────────────────────

do $upsert$
declare
  v_sig constant text := 'erp.upsert_reason_code(text,text,text,boolean,boolean,integer)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$            hint = 'A reason belongs to one of the eleven §6 categories. A new '
                   'category is a product change, not a tenant one — otherwise '
                   'the write-off report cannot be grouped across organisations.';
  end if;$o$;
  v_new constant text := $n$            hint = 'A reason belongs to one of the categories the product reads. A new '
                   'category is a product change, not a tenant one — otherwise '
                   'the write-off report cannot be grouped across organisations.';
  end if;

  -- Nothing reads a retired category, so a code in it would insist on
  -- nothing (20260925700000).
  if exists (select 1 from erp_ref.reason_category where code = v_cat and not is_offered) then
    raise exception 'CLOVEERP_REASON_CATEGORY_RETIRED: nothing reads the category %, so a reason in it would insist on nothing', v_cat
      using errcode = '23514',
            hint = 'Keep reasons for stock adjustments, customer returns and returns to suppliers, which the product asks for.';
  end if;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$upsert$;

-- Nor is one switched back on (found on review of this migration's own
-- design: erp.set_reason_code_status() reactivates by category and code).
do $status_door$
declare
  v_sig constant text := 'erp.set_reason_code_status(text,text,boolean)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$begin
  update erp.reason_code$o$;
  v_new constant text := $n$begin
  if p_active and exists (select 1 from erp_ref.reason_category
                           where code = upper(btrim(p_category)) and not is_offered) then
    raise exception 'CLOVEERP_REASON_CATEGORY_RETIRED: nothing reads the category %, so a reason in it would insist on nothing',
      upper(btrim(p_category))
      using errcode = '23514',
            hint = 'Keep reasons for stock adjustments, customer returns and returns to suppliers, which the product asks for.';
  end if;

  update erp.reason_code$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$status_door$;

select erp.register_refusal('CLOVEERP_REASON_CATEGORY_RETIRED',
  'Adding a reason, or switching one back on, in a category nothing in the product reads.',
  'A reason code is a control only where a door asks for it; in a category no door asks for, its note and approval rules would never be applied.',
  'Keep reasons for stock adjustments, customer returns and returns to suppliers, which the product asks for.');

do $vocab$
declare
  v_sig constant text := 'public.erp_vocabularies()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      order by rc.seq, rc.code) from erp_ref.reason_category rc), '[]'::jsonb))$o$;
  v_new constant text := $n$      order by rc.seq, rc.code) from erp_ref.reason_category rc
      -- Only what the product reads is offered (20260925700000).
      where rc.is_offered), '[]'::jsonb))$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$vocab$;

-- A change set or a snapshot that carries a reason in a retired category
-- promotes without it, rather than failing whole (found on review: a rollback
-- to a snapshot taken before this migration replays every reason it recorded
-- as an upsert, and the refusal above made that rollback impossible).
do $promote$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$        perform erp.set_reason_code_status(p ->> 'category', p ->> 'code', false);
      else
        perform erp.upsert_reason_code($o$;
  v_new constant text := $n$        perform erp.set_reason_code_status(p ->> 'category', p ->> 'code', false);
      elsif exists (select 1 from erp_ref.reason_category rc
                     where rc.code = upper(btrim(p ->> 'category')) and not rc.is_offered) then
        -- Nothing reads it, so there is nothing to keep (20260925700000).
        null;
      else
        perform erp.upsert_reason_code($n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$promote$;

-- The Configuration screen's note names only what is kept.
insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A reason nothing reads is not offered (20260925700000).'
  from (values
    ('Why something happened, from a list the organisation maintains: a return, a write-off. A code can insist on a note or an approval.')
  ) v(text)
on conflict (key, locale) do update set value = excluded.value;

delete from erp_ref.resource
 where key = erp_ref.ui_key('Why something happened, from a list the organisation maintains: a return, a write-off, a price override. A code can insist on a note or an approval.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The dead configuration report sees one
-- ─────────────────────────────────────────────────────────────────────────────

do $report$
declare
  v_sig constant text := 'erp.dead_configuration_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- An event kind the table allows that nothing records (20260925500000).$o$;
  v_new constant text := $n$  -- A reason category offered that nothing reads (20260925700000): no
  -- function in the product asks erp.check_reason_code() about it.
  select 'a reason category is offered and nothing reads it',
         c.code,
         format('%s: an organisation can keep reasons in it, and no door asks for one; retire it or wire it to its door',
                c.name)
    from erp_ref.reason_category c
   where c.is_offered
     and not exists (
       select 1 from pg_catalog.pg_proc p
       join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('erp', 'public')
        and p.proname <> 'check_reason_code'
        and strpos(p.prosrc, 'check_reason_code(''' || c.code || '''') > 0)
  union all
  -- An event kind the table allows that nothing records (20260925500000).$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$report$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The starter packs plan fewer items, and the acceptance suite says why
-- ─────────────────────────────────────────────────────────────────────────────

do $acceptance$
declare
  v_sig constant text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    (res ->> 'items')::integer = 345$o$,
    $n$    -- 299 since 20260925700000: the forty-seven reasons in the categories
    -- nothing reads left the base pack; forty-six of them were planned here
    -- and one, a recalled item's scrap, was held back with the recall
    -- capability it waited for.
    (res ->> 'items')::integer = 299$n$,
    $o$    (res ->> 'items')::integer = 11,$o$,
    $n$    -- 10 since 20260925700000: one of the reasons held back was in a
    -- category nothing reads, and left the pack.
    (res ->> 'items')::integer = 10,$n$,
    $o$    (res ->> 'items')::integer = 12, format('%s items', res ->> 'items');$o$,
    $n$    -- 8 since 20260925700000: the pack's four reasons, for scrap and
    -- batch amendment, were in categories nothing reads, and left it.
    (res ->> 'items')::integer = 8, format('%s items', res ->> 'items');$n$];
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
$acceptance$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.reason_register_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.reason_register_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1      uuid := gen_random_uuid();
  r       record;
  v_found text;
  v_err   text;
  v_cats  text;
begin
  -- 1. Here, every category offered is one something reads.
  select string_agg(d.reference, ', ') into v_found
    from erp.dead_configuration_report() d
   where d.finding = 'a reason category is offered and nothing reads it';
  return query select 'every reason category offered is one a door asks about',
    v_found is null, coalesce(v_found, 'none');

  -- 2. The three the product reads are offered, and the retired carry nothing.
  select string_agg(c.code, ', ' order by c.code) into v_cats
    from erp_ref.reason_category c where c.is_offered;
  return query select 'the categories offered are the three the product reads, and a retired one ships no reasons',
    v_cats = 'RETURN_CUSTOMER, RETURN_SUPPLIER, STOCK_ADJUSTMENT'
    and not exists (select 1 from erp_ref.reason_code rc
                      join erp_ref.reason_category c on c.code = rc.category_code
                     where not c.is_offered)
    and not exists (select 1 from erp_ref.pack_item pi
                      join erp_ref.reason_category c on c.code = pi.payload ->> 'category'
                     where pi.object_kind = 'reason_code' and not c.is_offered),
    v_cats;

  -- 3. The vocabulary the screens read offers only those.
  return query select 'the vocabulary the Configuration screen reads offers only the categories something reads',
    (select string_agg(e ->> 'code', ', ' order by e ->> 'code')
       from jsonb_array_elements(public.erp_vocabularies() -> 'reason_categories') e)
      = 'RETURN_CUSTOMER, RETURN_SUPPLIER, STOCK_ADJUSTMENT',
    (select string_agg(e ->> 'code', ', ' order by e ->> 'code')
       from jsonb_array_elements(public.erp_vocabularies() -> 'reason_categories') e);

  -- 4. An organisation cannot keep a reason in a retired category.
  begin
    select * into r from erp.provision_tenant(
      'zz-rr-' || v_hex, 'Reason register suite', 'a@zz-rr-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    update erp.environment e set is_live = false where e.tenant_id = r.tenant_id and e.is_self;
    begin
      perform erp.upsert_reason_code('PERIOD_REOPEN', 'LATE_INVOICE', 'Late invoice');
      v_err := 'kept';
    exception when others then v_err := left(sqlerrm, 120); end;
    perform erp.upsert_reason_code('STOCK_ADJUSTMENT', 'ZZ_SUITE', 'Suite adjustment');
    -- Nor switched back on.
    begin
      perform erp.set_reason_code_status('SCRAP', 'ZZ_NONE', true);
      v_err := v_err || ' / reactivated';
    exception when others then
      v_err := v_err || ' / ' || left(sqlerrm, 60);
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_err := 'setting up: ' || left(sqlerrm, 200); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  return query select 'an organisation cannot keep a reason in a category nothing reads, nor switch one back on, and still keeps one that is read',
    v_err like 'CLOVEERP_REASON_CATEGORY_RETIRED:% / CLOVEERP_REASON_CATEGORY_RETIRED:%', coalesce(v_err, 'nothing');

  -- 5. The report names a category offered that nothing reads.
  begin
    update erp_ref.reason_category set is_offered = true where code = 'PERIOD_REOPEN';
    select string_agg(d.reference, ', ') into v_found
      from erp.dead_configuration_report() d
     where d.finding = 'a reason category is offered and nothing reads it';
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_found := left(sqlerrm, 200); end if;
  end;
  return query select 'a reason category offered that no door reads is named by the dead configuration report',
    v_found = 'PERIOD_REOPEN', coalesce(v_found, 'nothing named');

  -- 6. Nothing is left behind.
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.code = 'zz-rr-' || v_hex)
    and not (select c.is_offered from erp_ref.reason_category c where c.code = 'PERIOD_REOPEN'),
    'the organisation rolled back and the category retired';
end;
$function$;

revoke all on function erp_test.reason_register_suite() from public, anon;

create or replace function erp_test.assert_reason_register_suite()
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
    from erp_test.reason_register_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_REASON_REGISTER_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A reason category offered that nothing reads, or a report that no longer sees one, is the case that failed. Read it.';
  end if;
  if v_total <> 6 then
    raise exception 'CLOVEERP_REASON_REGISTER_SUITE_SHRANK: % case(s), expected 6', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_reason_register_suite() from public, anon;

comment on function erp_test.assert_reason_register_suite() is
  'The reason categories offered are those a door asks about, a retired one takes no reason, and '
  'the dead configuration report names one offered that nothing reads (20260925700000).';

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
