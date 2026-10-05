set lock_timeout = '30s';

-- =============================================================================
-- 20261007172000  A reporting tag preview answers in words
-- -----------------------------------------------------------------------------
-- Found on the live journey test, 4 October (J-97). "Preview a document's
-- reporting tags" on Extra reporting tags (/finance/dimensions) offered the
-- hundred newest documents of every type at once, labelled with their type
-- codes, and its answer was the door's raw shape: a DOCUMENT ID as a uuid, the
-- POSTING RULE as its code (sales_commitment), and each line's VERDICT either
-- "ok" or the refusal exactly as raised, CLOVEERP_ code and all. A line that
-- failed to work out its tags also showed the tags of the line before it,
-- because the variable holding them was not cleared between lines.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_preview_dimensions(uuid) answers in words. It names the
--      document by its number and type, and the accounting rule by its name;
--      it no longer returns the document's id. Each line says whether it is
--      allowed, gives its verdict as a sentence ("Allowed: ..." or "Refused:
--      " and the refusal's own message without its CLOVEERP_ code), and, when
--      refused, what to do. Its tags are under reporting_tags and are cleared
--      for every line. Same signature, same gate (finance.read on the
--      document, through erp.authorise), still an invoker and still a read.
--   B. erp_test.dimension_suite proves it: the preview of a document the rules
--      let through says so in words and names its accounting rule, and a line
--      the rules refuse is refused in words with what to do, with no refusal
--      code and no identifier in the answer. Re-pinned from 12 cases to 13.
--      erp_test.rule_dimensions_suite, which also reads the preview, reads the
--      tags under reporting_tags and the verdict as allowed (an anchored edit).
--
-- The screen's half is in src/routes/finance/dimensions.tsx: the inquiry asks
-- the document type first and offers that type's documents by number, party
-- and state, through src/components/erp/inquiry.tsx, whose picker now follows
-- another choice on the same form (OptionSource.argsFrom) as the action forms
-- do.
--
-- On production: one door is replaced and two test suites are redefined. No
-- table is altered and no row is written.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The preview
-- ─────────────────────────────────────────────────────────────────────────────

do $anchor$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p
                  where p.oid = 'public.erp_preview_dimensions(uuid)'::regprocedure);
begin
  if strpos(v_src, '20261007172000') > 0 then
    raise notice 'public.erp_preview_dimensions already answers in words; replaced again as it is';
    return;
  end if;
  if md5(v_src) <> 'eaea253553cd6c41377c2e34a23b65ec' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_preview_dimensions(uuid) is not the body 20261007172000 expects (md5 %)', md5(v_src);
  end if;
end
$anchor$;

create or replace function public.erp_preview_dimensions(p_document_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $function$
declare
  v_tenant  uuid := erp.require_tenant_id();
  d         erp.document%rowtype;
  dt        erp.document_type%rowtype;
  pr        erp.posting_rule%rowtype;
  v_line    jsonb;
  v_dims    jsonb;
  v_acc     erp.account%rowtype;
  v_out     jsonb := '[]'::jsonb;
  v_on      date;
  v_allowed boolean;
  v_verdict text;
  v_todo    text;
  v_code    text;
begin
  select * into d from erp.document where tenant_id = v_tenant and id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_DOCUMENT: %', p_document_id using errcode = '23503';
  end if;
  perform erp.authorise('finance.read', d.entity_id, d.site_id, null, 'document', p_document_id);

  select * into dt from erp.document_type where tenant_id = v_tenant and id = d.document_type_id;
  v_on := coalesce(d.posting_date, d.document_date, current_date);

  select * into pr from erp.posting_rule r
   where r.tenant_id = v_tenant and r.code = dt.posting_rule_code and r.status = 'active'
     and (r.entity_id is null or r.entity_id = d.entity_id)
     and r.effective_from <= v_on and (r.effective_to is null or r.effective_to > v_on)
   order by (r.entity_id is not null) desc, r.version desc limit 1;

  -- In words, and by name (20261007172000): the document by its number and
  -- type, never its id; the accounting rule by its name.
  if pr.id is null then
    return jsonb_build_object('document', d.document_number, 'document_type', dt.name,
                              'accounting_rule', null, 'lines', '[]'::jsonb,
                              'note', 'This kind of document reaches no ledger, or no accounting rule is in force '
                                      'for it on its posting date, so nothing would be stamped.');
  end if;

  for v_line in select l.value from jsonb_array_elements(pr.posting_lines) l loop
    v_acc  := null;
    v_dims := null;
    v_todo := null;
    select * into v_acc from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = d.entity_id
       and a.code = erp.posting_line_account_code(v_line, p_document_id, pr.ledger_id)
       and a.status = 'active';
    begin
      v_dims := erp.derive_dimensions(p_document_id, coalesce(v_acc.code, v_line ->> 'account'), v_line, v_on,
                                      pr.ledger_id);
      if v_acc.id is not null then
        perform erp.check_dimension_combination(d.entity_id, v_acc.id, v_dims);
      end if;
      v_allowed := true;
      v_verdict := 'Allowed: the rules let this line through.';
    exception when others then
      -- The refusal's own message, without its code, and what to do about it.
      v_allowed := false;
      v_code := substring(sqlerrm from '^(CLOVEERP_[A-Z0-9_]+)');
      v_verdict := 'Refused: ' || left(regexp_replace(sqlerrm, '^CLOVEERP_[A-Z0-9_]+:\s*', ''), 300);
      v_todo := case v_code
        when 'CLOVEERP_DIMENSION_COMBINATION_FORBIDDEN' then
          'Change the reporting tags this document gives the line, or the combination rule that forbids them.'
        when 'CLOVEERP_DIMENSION_COMBINATION_NOT_PERMITTED' then
          'Change the reporting tags this document gives the line, or the combination rule, so it permits them.'
        when 'CLOVEERP_DIMENSION_VALUE_UNKNOWN' then
          'Add the value to its reporting tag, or make it valid on the posting date, or change what the document says.'
        when 'CLOVEERP_DERIVATION_INVALID' then
          'Rewrite the reporting tag''s derivation; it is checked against the posting''s facts when it is saved.'
        when 'CLOVEERP_DIMENSIONS_NOT_AN_OBJECT' then
          'Correct the reporting tags the document carries: each is a tag code with one value code.'
        else coalesce((select r.next_action from erp_ref.refusal r where r.code = v_code),
                      'Read why above, then change the document or the rule it names.')
      end;
    end;
    v_out := v_out || jsonb_build_object(
      'account', coalesce(v_acc.code, v_line ->> 'account'), 'account_name', v_acc.name,
      'side', v_line ->> 'side', 'reporting_tags', v_dims,
      'allowed', v_allowed, 'verdict', v_verdict, 'what_to_do', v_todo);
  end loop;

  return jsonb_build_object('document', d.document_number, 'document_type', dt.name,
                            'accounting_rule', coalesce(pr.name, pr.code),
                            'posting_date', v_on, 'lines', v_out);
end;
$function$;

revoke all on function public.erp_preview_dimensions(uuid) from public, anon;

comment on function public.erp_preview_dimensions(uuid) is
  'What each journal line of a document would be stamped with when it posts, and whether the rules let it '
  'through, in words (20261007172000): the document by number and type, the accounting rule by name, and per '
  'line its reporting tags, allowed or refused with the refusal''s message and what to do. Under finance.read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

-- erp_test.rule_dimensions_suite reads the preview too: its eighth case now
-- reads the tags under reporting_tags and the verdict as allowed.
do $rule_dimensions$
declare
  v_sig  constant text := 'erp_test.rule_dimensions_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$        and (select bool_and(l -> 'dimensions' ->> 'CC' = 'MATRIX' and l ->> 'verdict' = 'ok')
$o$;
  v_new  constant text := $n$        -- The preview answers in words (20261007172000).
        and (select bool_and(l -> 'reporting_tags' ->> 'CC' = 'MATRIX' and (l ->> 'allowed')::boolean)
$n$;
begin
  if strpos(v_src, '20261007172000') > 0 then
    raise notice '% already reads the preview in words; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'e0688f12d25428d4683a50f9b8c57002' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261007172000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$rule_dimensions$;


create or replace function erp_test.dimension_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $function$
declare
  v_tenant uuid; v_admin uuid; v_token text;
  v_auth uuid := gen_random_uuid();
  v_entity uuid; v_site uuid; v_site_code text; v_sup uuid; v_item uuid; v_ledger uuid;
  v_acc uuid; v_acc_code text; v_po uuid; v_po2 uuid; v_po3 uuid; v_rule_name text; v_j uuid; v_dims jsonb; v_x jsonb;
  t record; v_ok boolean; v_msg text; v_n integer;
begin
  begin
    select x.tenant_id, x.admin_user_id, x.admin_token into v_tenant, v_admin, v_token
      from erp.provision_tenant('zzdim', 'Dimension Suite', 'admin@zzdim.test', 'Dim Admin') x;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (v_auth, 'admin@zzdim.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
    perform erp.claim_invitation(v_token);
    perform erp.ensure_demo_configuration(v_tenant, v_admin);

    select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id, s.code into v_site, v_site_code from erp.site s where s.tenant_id = v_tenant and s.entity_id = v_entity order by s.code limit 1;
    select i.id into v_item from erp.item i where i.tenant_id = v_tenant and i.status = 'active' order by i.code limit 1;
    select pr.party_id into v_sup from erp.party_role pr where pr.tenant_id = v_tenant and pr.role_kind = 'supplier' order by pr.party_id limit 1;
    select l.id into v_ledger from erp.ledger l where l.tenant_id = v_tenant and l.entity_id = v_entity and l.status = 'active' order by l.code limit 1;
    select a.id, a.code into v_acc, v_acc_code from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8100' and a.is_postable;

    -- 1. A derivation that reads a fact the posting does not have.
    begin
      perform erp.upsert_dimension('CC', 'Cost centre', '{"var": "invoice.region"}'::jsonb);
      v_ok := false; v_msg := 'accepted a derivation over a fact that does not exist';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_RULE_UNKNOWN_FACT:%invoice.region%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a derivation that names a fact the posting does not have is refused when written', v_ok, v_msg;

    -- 2. A value for a dimension nobody declared.
    begin
      perform erp.upsert_dimension_value('CC', 'PURCH', 'Purchasing');
      v_ok := false; v_msg := 'accepted a value for an unknown dimension';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_UNKNOWN_DIMENSION:%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a value for a dimension nobody declared is refused', v_ok, v_msg;

    -- The dimensions: a cost centre derived from the document type, a region
    -- derived from the site.
    perform erp.upsert_dimension('CC', 'Cost centre',
      '{"if": [{"==": [{"var": "document.base_type"}, "purchase_order"]}, "PURCH", "GEN"]}'::jsonb);
    perform erp.upsert_dimension_value('CC', 'PURCH', 'Purchasing');
    perform erp.upsert_dimension_value('CC', 'GEN', 'General');
    perform erp.upsert_dimension_value('CC', 'OLD', 'Closed centre', null, null, current_date - 1);
    perform erp.upsert_dimension('REGION', 'Region', '{"var": "document.site_code"}'::jsonb);
    perform erp.upsert_dimension_value('REGION', v_site_code, 'The main site');

    -- 3. Derived from the document.
    v_po := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po, v_item, 2, 500, 'for the cost centre');
    v_dims := erp.derive_dimensions(v_po, v_acc_code, '{"account": "8100", "side": "debit"}'::jsonb);
    return query select 'a document''s dimensions are derived from its facts',
      v_dims ->> 'CC' = 'PURCH' and v_dims ->> 'REGION' = v_site_code,
      format('CC %s, REGION %s', v_dims ->> 'CC', v_dims ->> 'REGION');

    -- 4. The document's own word wins over the derivation.
    update erp.document set attributes = coalesce(attributes, '{}'::jsonb) || '{"dimensions": {"CC": "GEN"}}'::jsonb
     where id = v_po;
    v_dims := erp.derive_dimensions(v_po, v_acc_code, '{"account": "8100", "side": "debit", "dimensions": {"CC": "PURCH"}}'::jsonb);
    return query select 'what the document carries overrides the derivation and the rule''s static value',
      v_dims ->> 'CC' = 'GEN' and v_dims ->> 'REGION' = v_site_code,
      'the document said GEN; the derivation and the rule said PURCH';

    -- 5. A value nobody defined, or one no longer in force.
    update erp.document set attributes = attributes || '{"dimensions": {"CC": "OLD"}}'::jsonb where id = v_po;
    begin
      v_dims := erp.derive_dimensions(v_po, v_acc_code, '{}'::jsonb);
      v_ok := false; v_msg := 'a closed value was stamped';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_VALUE_UNKNOWN: CC has no value OLD%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a value not in force on the posting date is refused wherever it came from', v_ok, v_msg;
    update erp.document set attributes = attributes - 'dimensions' where id = v_po;

    -- 6. A forbidden combination, refused at the line by the trigger.
    perform erp.upsert_dimension_rule('NO_GEN_ON_COMMITMENTS', 'No general cost centre on commitments',
      '{"==": [{"var": "dimensions.CC"}, "GEN"]}'::jsonb, 'forbid',
      'a commitment must name the buying cost centre', null,
      '{"==": [{"var": "account.code"}, "8100"]}'::jsonb);
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description, status, manual_reason)
    values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'dimension suite', 'draft', 'the suite is proving the rules')
    returning id into v_j;
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      values (v_tenant, v_j, 1, v_acc, 100, 0, 'GBP', 100, 0, 1, '{"CC": "GEN"}'::jsonb);
      v_ok := false; v_msg := 'a forbidden combination posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_COMBINATION_FORBIDDEN: NO_GEN_ON_COMMITMENTS%'; v_msg := left(sqlerrm, 100);
    end;
    return query select 'a forbidden combination is refused at the line, for a manual journal too', v_ok, v_msg;

    -- 7. A permit rule: in scope it refuses what it does not permit; out of
    --    scope it says nothing.
    perform erp.upsert_dimension_rule('REGION_ON_8100', 'Commitments are regional',
      jsonb_build_object('in', jsonb_build_array(jsonb_build_object('var', 'dimensions.REGION'),
                                                 jsonb_build_array(v_site_code))), 'permit',
      'a commitment is booked to the main site''s region', null,
      '{"==": [{"var": "account.code"}, "8100"]}'::jsonb);
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      values (v_tenant, v_j, 2, v_acc, 100, 0, 'GBP', 100, 0, 1, '{"CC": "PURCH"}'::jsonb);
      v_ok := false; v_msg := 'a line outside what the rule permits posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_COMBINATION_NOT_PERMITTED: REGION_ON_8100%'; v_msg := left(sqlerrm, 100);
    end;
    -- The same dimensions on the offset account are outside the rule's scope.
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                  base_debit_minor, base_credit_minor, exchange_rate, dimensions)
    select v_tenant, v_j, 3, a.id, 0, 100, 'GBP', 0, 100, 1, '{"CC": "PURCH"}'::jsonb
      from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8900';
    return query select 'a permit rule refuses what it does not permit in scope, and is silent out of scope',
      v_ok and (select count(*) from erp.journal_line jl where jl.journal_id = v_j) = 1,
      v_msg;

    -- 8. Mandatory by default.
    perform erp.upsert_dimension('PROJECT', 'Project', null, true);
    perform erp.upsert_dimension_value('PROJECT', 'P1', 'The first project');
    begin
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate, dimensions)
      select v_tenant, v_j, 4, a.id, 0, 100, 'GBP', 0, 100, 1, '{"CC": "PURCH"}'::jsonb
        from erp.account a where a.tenant_id = v_tenant and a.entity_id = v_entity and a.code = '8900';
      v_ok := false; v_msg := 'a line without the mandatory dimension posted';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_DIMENSION_REQUIRED: 8900 requires PROJECT%'; v_msg := left(sqlerrm, 90);
    end;
    return query select 'a dimension mandatory by default is required on every line', v_ok, v_msg;
    perform erp.upsert_dimension('PROJECT', 'Project', null, false, 'inactive');

    -- 9. The bridge: a purchase order sent carries the derived dimensions on
    --    both lines, and the preview said so first.
    v_po2 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po2, v_item, 1, 500, 'to be committed');
    v_x := public.erp_preview_dimensions(v_po2);
    perform erp.transition_document(v_po2, 'submit');
    for t in select tk.id from erp.approval_task tk join erp.approval_request q on q.id = tk.approval_request_id
              where q.object_id = v_po2 and tk.status = 'pending' and tk.assignee_user_id = erp.current_principal_id()
    loop perform erp.decide_approval_task(t.id, true, 'suite'); end loop;
    perform erp.transition_document(v_po2, 'approve');
    perform erp.transition_document(v_po2, 'send');
    select count(*) into v_n from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
     where j.tenant_id = v_tenant and j.document_id = v_po2
       and jl.dimensions ->> 'CC' = 'PURCH' and jl.dimensions ->> 'REGION' = v_site_code;
    return query select 'a purchase order sent carries the derived dimensions on every journal line',
      v_n = 2 and v_n = (select count(*) from erp.journal j join erp.journal_line jl on jl.journal_id = j.id
                          where j.tenant_id = v_tenant and j.document_id = v_po2),
      format('%s line(s) stamped CC PURCH, REGION %s', v_n, v_site_code);

    -- 20261007172000: the preview answers in words, names its accounting rule
    -- and shows no identifier.
    select coalesce(pr.name, pr.code) into v_rule_name
      from erp.posting_rule pr
      join erp.document_type dt on dt.tenant_id = pr.tenant_id and dt.posting_rule_code = pr.code
      join erp.document d on d.tenant_id = dt.tenant_id and d.document_type_id = dt.id
     where d.id = v_po2 and pr.status = 'active'
     order by pr.version desc limit 1;
    return query select 'the preview showed the same reporting tags and let the lines through, in words',
      jsonb_array_length(v_x -> 'lines') = 2
      and (select bool_and((l ->> 'allowed')::boolean and l -> 'reporting_tags' ->> 'CC' = 'PURCH'
                           and l ->> 'verdict' not like '%CLOVEERP_%')
             from jsonb_array_elements(v_x -> 'lines') l)
      and v_x ->> 'accounting_rule' = v_rule_name
      and v_x ->> 'document' is not null
      and not (v_x ? 'document_id'),
      format('%s; %s', v_x ->> 'accounting_rule', v_x -> 'lines' -> 0 ->> 'verdict');

    -- A line the rules would refuse says so in words, with what to do, and
    -- the answer carries no refusal code and no identifier (J-97).
    v_po3 := erp.open_document('purchase_order', v_sup, v_entity, v_site);
    perform erp.add_document_line(v_po3, v_item, 1, 500, 'for the general cost centre');
    update erp.document set attributes = coalesce(attributes, '{}'::jsonb) || '{"dimensions": {"CC": "GEN"}}'::jsonb
     where id = v_po3;
    v_x := public.erp_preview_dimensions(v_po3);
    return query select 'a line the rules would refuse is refused in words, with what to do, and no code or identifier',
      exists (select 1 from jsonb_array_elements(v_x -> 'lines') l
               where not (l ->> 'allowed')::boolean
                 and l ->> 'verdict' like 'Refused: NO_GEN_ON_COMMITMENTS%a commitment must name the buying cost centre%'
                 and coalesce(l ->> 'what_to_do', '') <> '')
      and exists (select 1 from jsonb_array_elements(v_x -> 'lines') l where (l ->> 'allowed')::boolean)
      and v_x::text not like '%CLOVEERP_%'
      and v_x::text not like '%document_id%'
      and v_x::text not like '%' || v_po3::text || '%',
      left((select string_agg(l ->> 'verdict' || ' / ' || coalesce(l ->> 'what_to_do', '-'), '; ')
              from jsonb_array_elements(v_x -> 'lines') l), 300);

    return query select 'the register says dimensions are built, and the artefacts exist',
      (select c.status from erp_ref.part5_capability c where c.code = '5.7.dimensions') = 'built'
      and not exists (select 1 from erp.part5_coverage_report() f where f.reference = '5.7.dimensions')
      and exists (select 1 from erp_ref.product_decision_check c
                   where c.decision_code = 'D4' and c.routine_name = 'assert_dimension_suite'),
      '5.7.dimensions; D4 bound';

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant tn where tn.code = 'zzdim');
  detail := 'the organisation, its dimensions and its journals rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.dimension_suite() from public, anon;

comment on function erp_test.dimension_suite() is
  'Analysis by reporting tag (specification v1.6 §5.7): derivation, the document''s own word, closed values, '
  'combination rules at the line, mandatory tags, the posting bridge, and (20261007172000) a preview that answers '
  'in words with no refusal code and no identifier.';

create or replace function erp_test.assert_dimension_suite()
returns text
language plpgsql
set search_path = ''
as $function$
declare
  c_expected constant integer := 13;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _dimension_suite on commit drop as
    select * from erp_test.dimension_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _dimension_suite;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_DIMENSION_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_DIMENSION_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('dimensions: %s/%s cases passed', v_passed, v_total);
end;
$function$;

revoke all on function erp_test.assert_dimension_suite() from public, anon;

comment on function erp_test.assert_dimension_suite() is
  'Analysis by reporting tag holds, thirteen cases, including a preview that answers in words (20261007172000).';

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
