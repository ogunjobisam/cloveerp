-- The trading company is named first.
--
-- The second attempt to configure the live demonstration organisation was
-- refused with the same words as the first — goods_receipt on ACME wants
-- account 2300 — and this time the chart pack had been applied. It had landed
-- on the wrong company.
--
-- The pack, like the finance installer, places its accounts on the first
-- entity by code. The demonstration's companies were coded ACME-UK and
-- ACME-EU, and the migration before this one renamed the UK company ACME so
-- that it would sort first — inside the finance block, after the pack had
-- already chosen. So with §8.1's chart chosen, twenty accounts went to
-- Rotterdam, the ledger went to Birmingham, and the gate that refuses a
-- posting rule naming an account the company does not have did exactly that.
-- Reproduced locally with two companies in that order: ACME-EU=20, ACME-UK=0.
--
-- The rename now happens before anything chooses a company: before the pack,
-- before finance. The suite gains the demonstration's own shape — two
-- companies, the trading one coded second — because a suite with one company
-- cannot see which one was chosen.
--
-- Patched by asserted replacement, like the two before it.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Rename first
-- ═════════════════════════════════════════════════════════════════════════════

do $ensure$
declare
  v_def  text;
  v_n1   text := $n$  if v_ledgers = 0 then
    if exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME-UK')
       and not exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME') then
      update erp.entity set code = 'ACME' where tenant_id = p_tenant_id and code = 'ACME-UK';
      v_did := v_did || '"entity ACME-UK renamed ACME"'::jsonb;
    end if;
    perform erp.configure_finance(v_year, null);$n$;
  v_r1   text := $r$  if v_ledgers = 0 then
    perform erp.configure_finance(v_year, null);$r$;
  v_n2   text := $n$  -- An organisation that chose §8.1's chart gets no chart from the finance$n$;
  v_r2   text := $r$  -- Whatever chooses a company — the chart pack, the finance installer —
  -- takes the first by code, so the trading company must sort first before
  -- anything chooses. The demo's UK company was coded ACME-UK and its Dutch
  -- one ACME-EU, which put the chart, the ledger and every document after
  -- them in Rotterdam. Renamed once, before there is a ledger to have chosen
  -- wrongly; a demo that already has a ledger keeps whatever it has.
  select count(*) into v_ledgers from erp.ledger l where l.tenant_id = p_tenant_id;
  if v_ledgers = 0
     and exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME-UK')
     and not exists (select 1 from erp.entity e where e.tenant_id = p_tenant_id and e.code = 'ACME') then
    update erp.entity set code = 'ACME' where tenant_id = p_tenant_id and code = 'ACME-UK';
    v_did := v_did || '"entity ACME-UK renamed ACME"'::jsonb;
  end if;

  -- An organisation that chose §8.1's chart gets no chart from the finance$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1),
    (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: a needle this migration expects '
        'once in erp.ensure_demo_configuration() was found % time(s).', v_hits;
    end if;
  end loop;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  v_def := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  if position('renamed ACME' in v_def) = 0
     or position('renamed ACME' in v_def) > position('chart_8_1' in v_def) then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: the rename does not precede the '
      'chart pack after the rewrite.';
  end if;
end
$ensure$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite sees two companies
-- ═════════════════════════════════════════════════════════════════════════════

do $suite$
declare
  v_def  text;
  v_n1   text := $n$  update erp.environment set is_live = false where tenant_id = d.tenant_id and is_self;
  perform erp.set_capability('statutory_chart_8_1', true, 'chose §8.1''s chart');$n$;
  v_r1   text := $r$  update erp.environment set is_live = false where tenant_id = d.tenant_id and is_self;
  -- The demonstration's own shape: two companies, the trading one coded so
  -- that it sorts second. A suite with one company cannot see which was chosen.
  update erp.entity set code = 'ACME-UK', name = 'Acme United Kingdom'
   where tenant_id = d.tenant_id;
  insert into erp.entity (tenant_id, code, name, legal_name, base_currency, country_code, created_by)
  values (d.tenant_id, 'ACME-EU', 'Acme Europe', 'Acme Manufacturing BV', 'EUR', 'NL', d.admin_user_id);
  perform erp.set_capability('statutory_chart_8_1', true, 'chose §8.1''s chart');$r$;
  v_n2   text := $n$        and (select count(*) from erp.account a where a.tenant_id = d.tenant_id) = 20$n$;
  v_r2   text := $r$        and (select count(*) from erp.account a where a.tenant_id = d.tenant_id) = 20
        and (select count(*) from erp.account a join erp.entity e on e.id = a.entity_id
              where a.tenant_id = d.tenant_id and e.code = 'ACME') = 20
        and exists (select 1 from erp.ledger l join erp.entity e on e.id = l.entity_id
                     where l.tenant_id = d.tenant_id and l.is_primary and e.code = 'ACME')$r$;
  v_n3   text := $n$'with the statutory chart chosen, the pack is applied first and every module installs on it'$n$;
  v_r3   text := $r$'with the statutory chart chosen and two companies, the trading one is named first, the pack lands on it and every module installs'$r$;
  -- The rename is now the first thing installed, so the pack is no longer
  -- element zero; it is in the list.
  v_n4   text := $n$    v_ok := (v_conf -> 'installed' ->> 0) = 'chart_8_1'$n$;
  v_r4   text := $r$    v_ok := (v_conf -> 'installed') ? 'chart_8_1'
        and (v_conf -> 'installed' ->> 0) = 'entity ACME-UK renamed ACME'$r$;
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp_test.demo_chart_suite()'::regprocedure);
  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1),
    (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2),
    (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3),
    (length(v_def) - length(replace(v_def, v_n4, ''))) / length(v_n4)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_DEMO_CHART_SUITE_UNRECOGNISED: a needle this migration expects once '
        'in erp_test.demo_chart_suite() was found % time(s).', v_hits;
    end if;
  end loop;
  execute replace(replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3), v_n4, v_r4);
end
$suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Proved here
-- ═════════════════════════════════════════════════════════════════════════════

select erp_test.assert_demo_chart_suite();
select erp_test.assert_demo_history_suite();
select erp.assert_intelligence_boundary();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_diagnostics_registered();
