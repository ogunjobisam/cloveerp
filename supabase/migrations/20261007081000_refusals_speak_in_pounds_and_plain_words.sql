set lock_timeout = '30s';

-- =============================================================================
-- 20261007081000  Refusals speak in pounds and plain words
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October.
--
--   J-146. Buying a sample with no price was refused with "Name the price
--          agreed with the supplier, in minor units, or keep it free instead."
--          The field it points at takes pounds, as every money field does;
--          minor units are how the database keeps an amount, not how anybody
--          types one. Three refusals beside it say the same to the person
--          allocating a credit or a prepayment: CLOVEERP_ALLOCATION_AMOUNT_INVALID,
--          CLOVEERP_PREPAYMENT_AMOUNT_INVALID and
--          CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID.
--   J-147. Scanning a label no shipping notice lists was headed "Scanning a
--          carton no open notice of this organisation lists.", which reads
--          as a puzzle rather than as what happened.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. The four refusals' next action no longer says "in minor units", in the
--      register (and so in the words an organisation can rename) and in the
--      hint each raise carries: erp.settle_samples, erp.allocate_on_account,
--      erp.request_prepayment, erp.allocate_prepayment and
--      erp.allocate_supplier_credit. What was refused and why are unchanged.
--   B. CLOVEERP_CARTON_UNKNOWN is headed "Receiving a carton that is not on
--      any open shipping notice." Why and what to do are unchanged.
--   C. erp_test.refusal_wording_suite.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- What is refused, when, and the amounts each routine takes (still minor
-- units at the door, which is the database's business). On production: five
-- functions' hints and five registered refusals are reworded, together with
-- the en words they mirror. An organisation that renamed one of these keys
-- keeps its own wording. No other row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A and B. The register
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(f.code, f.refused, f.why, v.next_action)
  from (values
    ('CLOVEERP_SAMPLE_PRICE_REQUIRED',
     'Name the price agreed with the supplier, or keep it free instead.'),
    ('CLOVEERP_ALLOCATION_AMOUNT_INVALID',
     'Name a positive amount, or leave it out to allocate as much as the credit and the invoice allow.'),
    ('CLOVEERP_PREPAYMENT_AMOUNT_INVALID',
     'Name an amount: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.'),
    ('CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID',
     'Name a positive amount, or leave it out to allocate as much as the credit and the bill allow.')
  ) as v(code, next_action)
  join erp_ref.refusal f on f.code = v.code;

select erp.register_refusal(f.code, 'Receiving a carton that is not on any open shipping notice.', f.why, f.next_action)
  from erp_ref.refusal f
 where f.code = 'CLOVEERP_CARTON_UNKNOWN';

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The hints the raises carry
-- ─────────────────────────────────────────────────────────────────────────────

do $hints$
declare
  r      record;
  v_src  text;
  v_def  text;
  v_note constant text := E'\n  -- Said in pounds, as the person types it, not in minor units (20261007081000).';
begin
  for r in
    select * from (values
      ('erp.settle_samples(uuid,text,numeric,bigint,text)', '59d9336baa2e3df6b5de4a4400e1afcb',
       $o$            hint = 'Name the price agreed with the supplier, in minor units, or keep it free instead.';
  end if;$o$,
       $n$            hint = 'Name the price agreed with the supplier, or keep it free instead.';
  end if;$n$),
      ('erp.allocate_on_account(uuid,uuid,bigint)', 'e39b1af8eb8489420348b9fd7bb98ee7',
       $o$            hint = 'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the invoice allow.';
  end if;$o$,
       $n$            hint = 'Name a positive amount, or leave it out to allocate as much as the credit and the invoice allow.';
  end if;$n$),
      ('erp.request_prepayment(uuid,bigint,date,text)', '805a33807e7d4111d16ea97a9bc0bd19',
       $o$            hint = 'Name an amount in minor units: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;$o$,
       $n$            hint = 'Name an amount: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;$n$),
      ('erp.allocate_prepayment(uuid,uuid,bigint)', '0c8271c89c84aee7cdbe1f9ff19f8136',
       $o$            hint = 'Name an amount in minor units: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;$o$,
       $n$            hint = 'Name an amount: nought or more to ask, more than nought to allocate, or leave the allocation''s amount out to allocate as much as the prepayment and the bill allow.';
  end if;$n$),
      ('erp.allocate_supplier_credit(uuid,uuid,bigint)', 'b13067212dd0b9a85eabd33ca8ee8bd3',
       $o$            hint = 'Name a positive amount in minor units, or leave it out to allocate as much as the credit and the bill allow.';
  end if;$o$,
       $n$            hint = 'Name a positive amount, or leave it out to allocate as much as the credit and the bill allow.';
  end if;$n$)
    ) as t(sig, digest, old_text, new_text)
  loop
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = r.sig::regprocedure);
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    if strpos(v_src, '20261007081000') > 0 then
      raise notice '% already says it in pounds; left as it is', r.sig;
      continue;
    end if;
    if md5(v_src) <> r.digest then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007081000 expects (md5 %)', r.sig, md5(v_src);
    end if;
    if (length(v_def) - length(replace(v_def, r.old_text, ''))) / length(r.old_text) <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', r.sig;
    end if;
    execute replace(v_def, r.old_text, r.new_text || v_note);
  end loop;
end
$hints$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.refusal_wording_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases  integer := 0;
  v_step   text := 'reading';
  v_state  text;
  v_bad    text;
  v_n      integer;
begin
  begin
    -- ── 1. The register says it in pounds ───────────────────────────────────
    v_step := 'the register and its words';
    select string_agg(f.code, ', ' order by f.code) into v_bad
      from erp_ref.refusal f
      left join erp_ref.resource x
        on x.locale = 'en' and x.key = erp_ref.refusal_key(f.code, 'next_action')
     where f.code in ('CLOVEERP_SAMPLE_PRICE_REQUIRED', 'CLOVEERP_ALLOCATION_AMOUNT_INVALID',
                      'CLOVEERP_PREPAYMENT_AMOUNT_INVALID', 'CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID')
       and (f.next_action ilike '%minor unit%' or x.value is distinct from f.next_action);
    select count(*) into v_n from erp_ref.refusal f
     where f.code in ('CLOVEERP_SAMPLE_PRICE_REQUIRED', 'CLOVEERP_ALLOCATION_AMOUNT_INVALID',
                      'CLOVEERP_PREPAYMENT_AMOUNT_INVALID', 'CLOVEERP_SUPPLIER_CREDIT_AMOUNT_INVALID');
    v_cases := v_cases + 1;
    case_name := 'the four refusals about an amount a person types name no minor units, and the words an organisation renames say the same';
    passed := v_state is null and v_n = 4 and v_bad is null;
    detail := coalesce(v_state, coalesce(v_bad, format('%s refusals read', v_n)));
    return next;

    -- ── 2. Every raise of them says it in pounds, and as the register does ──
    v_step := 'the raises';
    with raised as (
      select n.nspname || '.' || p.proname as routine, m[1] as token,
             substring(m[2] from 'hint\s*=\s*''((?:[^'']|'''')*)''') as hint
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       cross join lateral regexp_matches(p.prosrc,
             'raise exception\s+E?''(CLOVEERP_(?:SAMPLE_PRICE_REQUIRED|ALLOCATION_AMOUNT_INVALID|PREPAYMENT_AMOUNT_INVALID|SUPPLIER_CREDIT_AMOUNT_INVALID))((?:[^;]|;[ \t]*[^ \t\n])*);', 'g') m
       where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'public')
         and p.proname not like 'assert\_%'
         and p.proname not like '%\_suite')
    select count(*), string_agg(r.routine || ' ' || r.token, ', ' order by r.routine)
             filter (where r.hint is null or r.hint ilike '%minor unit%'
                        or replace(r.hint, '''''', '''') is distinct from
                           (select f.next_action from erp_ref.refusal f where f.code = r.token))
      into v_n, v_bad
      from raised r;
    v_cases := v_cases + 1;
    case_name := 'every raise of them carries a hint with no minor units in it, the same as the register''s next action';
    passed := v_state is null and v_n >= 5 and v_bad is null;
    detail := coalesce(v_state, coalesce(v_bad, format('%s raises read', v_n)));
    return next;

    -- ── 3. A carton nobody notified, said as what happened ──────────────────
    v_step := 'the carton refusal';
    v_cases := v_cases + 1;
    case_name := 'a carton on no open notice is headed as what happened, and its words say the same';
    passed := v_state is null
          and (select f.refused from erp_ref.refusal f where f.code = 'CLOVEERP_CARTON_UNKNOWN')
              = 'Receiving a carton that is not on any open shipping notice.'
          and (select x.value from erp_ref.resource x
                where x.locale = 'en' and x.key = erp_ref.refusal_key('CLOVEERP_CARTON_UNKNOWN', 'refused'))
              = 'Receiving a carton that is not on any open shipping notice.'
          and (select f.next_action from erp_ref.refusal f where f.code = 'CLOVEERP_CARTON_UNKNOWN') <> '';
    detail := coalesce(v_state, 'register read');
    return next;
  exception when others then
    v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
  end;

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_REFUSAL_WORDING_SUITE_SHRANK: % case(s), expected %; the reading stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.refusal_wording_suite() from public, anon;

comment on function erp_test.refusal_wording_suite() is
  'Refusals speak in pounds and plain words (20261007081000): the four refusals about an amount a person types name '
  'no minor units in the register, its words or any raise, and the unknown-carton refusal is headed as what happened. '
  'The raises themselves are exercised by the sample, on-account, prepayment, supplier-return and shipping-notice suites.';

create or replace function erp_test.assert_refusal_wording_suite()
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
    from erp_test.refusal_wording_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_REFUSAL_WORDING_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A refusal tells a person to type an amount in minor units, or its hint and the register disagree. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_REFUSAL_WORDING_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('refusal wording: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_refusal_wording_suite() from public, anon;

comment on function erp_test.assert_refusal_wording_suite() is
  'The refusals about an amount a person types speak in pounds, and an unknown carton is headed as what happened (20261007081000).';

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
select erp.assert_personal_data_register_sound();
