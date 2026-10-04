set lock_timeout = '30s';

-- =============================================================================
-- 20261006022000  A demonstration says it sends no email
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-139). A purchase
-- order sent to its supplier from the demonstration stayed "queued" for over
-- an hour (PO-000137), under a dialog that had said "Emails the order with
-- its PDF attached". It looked like a stuck queue. It is not: a
-- demonstration never sends email, by design (erp.claim_document_email_batch()
-- claims nothing for one, and CLOVEERP_DEMONSTRATION_SENDS_NO_EMAIL says
-- why), so a send there is queued and stays queued. Nothing on the screen
-- said so, because erp.purchase_order_sends() gave the page no way to know.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.purchase_order_sends(order), which public.erp_purchase_order_sends
--      answers with, also says 'demonstration': whether the order's
--      organisation is one, by erp.tenant_is_demonstration(). Read only,
--      inside the reader's own organisation; nothing else in the answer
--      changes.
--   B. The order page's "Sent to the supplier" section and its Send dialog
--      say, in a demonstration, the words the refusal already gives:
--      "A demonstration organisation never sends email outside the product,
--      so nobody is written to by accident." One screen string, added here.
--
-- On production: no rows change. Every organisation's order page reads one
-- more key; only a demonstration's says true.
--
-- Proof: erp_test.demonstration_order_sends_suite.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. An order's sends say whether its organisation is a demonstration
-- ─────────────────────────────────────────────────────────────────────────────

do $sends$
declare
  v_sig  constant text := 'erp.purchase_order_sends(uuid)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$           'default_to', erp.supplier_email_address(d.party_id) ->> 'address',
$o$;
  v_new  constant text := $n$           'default_to', erp.supplier_email_address(d.party_id) ->> 'address',
           -- Whether a send from here leaves the product at all: a
           -- demonstration's never does (20261006022000).
           'demonstration', erp.tenant_is_demonstration(d.tenant_id),
$n$;
begin
  if strpos(v_src, '20261006022000') > 0 then
    raise notice '% already says whether it is a demonstration; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '818946a5341b8690724fb2ac33d498cd' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006022000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$sends$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The words the screen says
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A demonstration says it sends no email (20261006022000).'
  from (values
    ('A demonstration organisation never sends email outside the product, so nobody is written to by accident.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_order_sends_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  c_words    constant text :=
    'A demonstration organisation never sends email outside the product, so nobody is written to by accident.';
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  rc       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_conf   jsonb;
  v_po     uuid;
  v_sends  jsonb;
begin
  begin
    -- ── The fixture: a demonstration with a draft order ─────────────────────
    v_step := 'a demonstration with a draft order to Midland Steel';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzos' || v_tag, 'Demo Order Sends Suite',
      'admin@demo-zzos' || v_tag || '.test', 'Sends Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzos' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    v_conf := erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    v_po := erp.open_document('purchase_order',
              (select p.id from erp.party p where p.tenant_id = rb.tenant_id and p.code = 'S-STEEL'),
              (v_conf ->> 'entity_id')::uuid, (v_conf ->> 'site_id')::uuid);
    v_sends := public.erp_purchase_order_sends(v_po);

    -- ── 1. A demonstration's order says so, and has its supplier's address ──
    v_cases := v_cases + 1;
    case_name := 'a demonstration''s order says it is a demonstration, and its supplier''s address is filled in';
    passed := v_state is null and (v_sends ->> 'demonstration')::boolean
          and v_sends ->> 'default_to' = 'orders.s-steel@example.invalid';
    detail := coalesce(v_state, left(v_sends::text, 400));
    return next;

    -- ── 2. An ordinary organisation's order does not ────────────────────────
    v_step := 'an organisation that is not a demonstration, with a draft order';
    perform set_config('request.jwt.claims', '', true);
    select * into rc from erp.provision_tenant(
      'zzos-' || v_tag, 'Not A Demo Order Sends Suite', 'admin@zzos-' || v_tag || '.test', 'Plain Admin');
    update erp.environment set is_live = false where tenant_id = rc.tenant_id and is_self;
    insert into auth.users (id, email) values (a2, 'admin@zzos-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    v_conf := erp.ensure_demo_configuration(rc.tenant_id, rc.admin_user_id);
    v_po := erp.open_document('purchase_order',
              (select p.id from erp.party p where p.tenant_id = rc.tenant_id and p.code = 'S-STEEL'),
              (v_conf ->> 'entity_id')::uuid, (v_conf ->> 'site_id')::uuid);
    v_sends := public.erp_purchase_order_sends(v_po);
    v_cases := v_cases + 1;
    case_name := 'an ordinary organisation''s order says it is not a demonstration';
    passed := v_state is null and v_sends ? 'demonstration'
          and not (v_sends ->> 'demonstration')::boolean;
    detail := coalesce(v_state, left(v_sends::text, 400));
    return next;

    -- ── 3. The page says the refusal's own words ────────────────────────────
    v_cases := v_cases + 1;
    case_name := 'the sentence the order page shows is a screen string, and is what the refusal says';
    passed := v_state is null
          and exists (select 1 from erp_ref.resource x
                       where x.key = erp_ref.ui_key(c_words) and x.locale = 'en' and x.value = c_words)
          and exists (select 1 from erp_ref.resource x
                       where x.key = 'refusal.cloveerp_demonstration_sends_no_email.why'
                         and x.locale = 'en' and x.value = c_words);
    detail := coalesce(v_state, erp_ref.ui_key(c_words));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_ORDER_SENDS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_order_sends_suite() from public, anon;

comment on function erp_test.demonstration_order_sends_suite() is
  'A demonstration says it sends no email (20261006022000): an order''s sends say whether its organisation is a '
  'demonstration, only a demonstration''s say true, and the page''s sentence is the refusal''s own.';

create or replace function erp_test.assert_demonstration_order_sends_suite()
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
    from erp_test.demonstration_order_sends_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_ORDER_SENDS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A demonstration''s order page would not say that nothing is emailed. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_DEMONSTRATION_ORDER_SENDS_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration order sends: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_order_sends_suite() from public, anon;

comment on function erp_test.assert_demonstration_order_sends_suite() is
  'A demonstration''s purchase order page can say that it sends no email, and only a demonstration''s does (20261006022000).';

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
