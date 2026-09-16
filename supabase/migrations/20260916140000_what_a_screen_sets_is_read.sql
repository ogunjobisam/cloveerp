set lock_timeout = '30s';

-- What a screen sets is read.
--
-- Four fields a person fills in on a screen, each of which was stored and then
-- read by nothing. A setting that is saved and never consulted is worse than a
-- setting that is missing: the person believes they have said something, and
-- the product carries on as though they had not.
--
--   1. Governance → Change requests showed "Apply" only while the request said
--      'approved'. erp.submit_change_request() writes 'approved' when no field
--      approval rule covers the field and 'pending' when one does, and nothing
--      ever moves that column on again — the approval outcome lives on
--      erp.approval_request. erp.change_request_effective_status() reconciles
--      the two and was called from erp.apply_change_request() and nowhere else.
--      So a request somebody had approved still read "pending" on the screen,
--      the Apply button never appeared, and a request somebody had refused read
--      "pending" for ever too. The door now reports the reconciled status as
--      'status' and keeps the column's own answer as 'stored_status'.
--
--   2. Administration → Organisation writes erp.department.default_cost_centre
--      under the words "Charged by default for spend this department approves".
--      What actually stamped the cost centre on a posting was the COST_CENTRE
--      derivation — attributes.cost_centre, then the department CODE, then the
--      site code — which never looked at the centre the department had chosen.
--      The derivation now reads it, between the document's own answer and the
--      department code, and a posting is charged where the department said.
--
--   3. Finance → Cost centres writes parent_value_id under "Use it to roll
--      several cost centres into one heading". erp.statement_lines() matched
--      the cost centre exactly, so a heading's profit and loss showed only what
--      had been posted directly to the heading, which is usually nothing. It
--      now matches the centre or any centre beneath it.
--
--   4. Profile → Document language and Reporting language, and the same two
--      fields on the company, resolve through erp.resolve_locale(). That
--      function had no callers at all. Every render passed the literal 'en': the
--      order form, the document renderer's own door, and the locale stamped on a
--      report extract. Each now resolves.
--
-- Three of the four are read by the rule engine or by a door, so each is fixed
-- where it is read rather than where it is written, and erp_test.wired_setting_suite()
-- proves all four from the outside.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. An approved change request can be applied
-- ═════════════════════════════════════════════════════════════════════════════

-- Last written whole in 20260830023322; made volatile in 20260830023056 and
-- never needle-patched since, so this re-states it with the status reconciled.
create or replace function public.erp_change_requests(p_object_type text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path to ''
as $function$
declare v_tenant uuid;
begin
  perform erp.authorise('master_data.read');
  v_tenant := erp.current_tenant_id();
  return coalesce((
    select jsonb_agg(x order by x_created_at desc) from (
      select jsonb_build_object(
        'change_request_id', cr.id, 'object_type', cr.object_type, 'object_id', cr.object_id,
        -- Two sources of truth for "is this approved" is one too many, and the
        -- screen was reading the wrong one. This is the answer the approval
        -- engine gives and the one erp.apply_change_request() acts on.
        'status', erp.change_request_effective_status(cr.id)::text,
        -- The column's own answer, kept because "nobody had to approve this" is
        -- a different fact from "somebody did", and a governance screen may
        -- want to say which.
        'stored_status', cr.status,
        'reason', cr.reason, 'proposed', cr.proposed,
        'before', cr.before_snapshot, 'requested_by', a.display_name,
        'created_at', cr.created_at, 'applied_at', cr.applied_at,
        'governance', coalesce((select jsonb_agg(to_jsonb(g)) from erp.change_request_governance(cr.id) g), '[]'::jsonb)
      ) as x, cr.created_at as x_created_at
        from erp.change_request cr
        left join erp.app_user a on a.tenant_id = cr.tenant_id and a.id = cr.created_by
       where cr.tenant_id = v_tenant
         and (p_object_type is null or cr.object_type = p_object_type)) t), '[]'::jsonb);
end;
$function$;

comment on function public.erp_change_requests(text) is
  'Lists governed change requests for the tenant. The status is the one the '
  'approval engine holds, reconciled by erp.change_request_effective_status(); '
  'stored_status is what the request''s own column says. A screen that branches '
  'on the column alone never sees an approval or a refusal.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A department's default cost centre is what a posting is charged to
-- ═════════════════════════════════════════════════════════════════════════════

-- The facts a derivation reads, from 20260906135000 and unchanged since, plus
-- one: the cost centre the department chose to be charged.
--
-- Which department. The one the document names if it names one, otherwise the
-- primary department of whoever raised it — the same department erp.approvers_for()
-- takes, so "spend this department approves" and "spend this department is
-- charged for" are the same department.
--
-- Offered only when finance holds that centre as a live COST_CENTRE value. The
-- door stores the department's centre unchecked, deliberately, so a centre may
-- be named before finance has created it; a derivation that produced a value
-- nobody has declared would refuse the posting outright, which is a worse
-- outcome than the fallback it replaces.
create or replace function erp.dimension_facts(p_document_id uuid, p_account_code text, p_line jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
           'document', jsonb_build_object(
             'id', d.id, 'document_number', d.document_number,
             'document_type', dt.code, 'base_type', dt.base_type_code,
             'entity_code', e.code, 'site_code', s.code,
             'party_code', p.code, 'party_name', p.name,
             'currency', d.currency, 'document_date', d.document_date,
             'posting_date', coalesce(d.posting_date, d.document_date),
             'our_reference', d.our_reference, 'their_reference', d.their_reference,
             'order_behaviour', d.order_behaviour_code,
             'department_cost_centre', (
               select upper(btrim(dep.default_cost_centre))
                 from erp.department dep
                where dep.tenant_id = d.tenant_id
                  and dep.status = 'active'
                  and nullif(btrim(coalesce(dep.default_cost_centre, '')), '') is not null
                  and dep.code = coalesce(
                        upper(btrim(nullif(d.attributes ->> 'department', ''))),
                        (select raiser.code
                           from erp.principal_department pd
                           join erp.department raiser
                             on raiser.tenant_id = pd.tenant_id and raiser.id = pd.department_id
                          where pd.tenant_id = d.tenant_id
                            and pd.app_user_id = d.created_by
                            and pd.is_primary
                            and pd.status = 'active'
                            and daterange(pd.valid_from, pd.valid_to, '[)')
                                @> coalesce(d.posting_date, d.document_date, current_date)
                          limit 1))
                  and exists (
                        select 1
                          from erp.dimension_value dv
                          join erp.dimension dm
                            on dm.tenant_id = dv.tenant_id and dm.id = dv.dimension_id
                         where dv.tenant_id = d.tenant_id
                           and dm.code = 'COST_CENTRE'
                           and dv.code = upper(btrim(dep.default_cost_centre))
                           and dv.status = 'active'
                           and (dv.valid_from is null
                                or dv.valid_from <= coalesce(d.posting_date, d.document_date, current_date))
                           and (dv.valid_to is null
                                or dv.valid_to >= coalesce(d.posting_date, d.document_date, current_date)))
                limit 1),
             'attributes', coalesce(d.attributes, '{}'::jsonb)),
           'account', coalesce((select jsonb_build_object('code', a.code, 'name', a.name,
                                                          'account_type', a.account_type,
                                                          'group_code', a.group_code)
                                  from erp.account a
                                 where a.tenant_id = d.tenant_id and a.entity_id = d.entity_id
                                   and a.code = p_account_code
                                 limit 1),
                               jsonb_build_object('code', p_account_code)),
           'line', coalesce(p_line, '{}'::jsonb),
           'entity', jsonb_build_object('code', e.code, 'name', e.name))
    from erp.document d
    join erp.document_type dt on dt.id = d.document_type_id
    join erp.entity e on e.id = d.entity_id
    left join erp.site s on s.id = d.site_id
    left join erp.party p on p.id = d.party_id
   where d.tenant_id = erp.current_tenant_id()
     and d.id = p_document_id
$$;

comment on function erp.dimension_facts(uuid, text, jsonb) is
  'What a dimension derivation sees: the document, the account, the line and '
  'the entity. document.department_cost_centre is the centre the raising '
  'department chose, offered only when finance holds it as a live COST_CENTRE '
  'value, so the derivation cannot produce a value the posting would be refused for.';

-- The chain, for organisations that already have it.
do $cc_derivation$
declare
  v_old constant jsonb := jsonb_build_object('coalesce', jsonb_build_array(
    jsonb_build_object('var', 'document.attributes.cost_centre'),
    jsonb_build_object('var', 'document.attributes.department'),
    jsonb_build_object('var', 'document.site_code')));
  v_new constant jsonb := jsonb_build_object('coalesce', jsonb_build_array(
    jsonb_build_object('var', 'document.attributes.cost_centre'),
    jsonb_build_object('var', 'document.department_cost_centre'),
    jsonb_build_object('var', 'document.attributes.department'),
    jsonb_build_object('var', 'document.site_code')));
  v_n integer;
begin
  -- Only the chain 20260911005120 wrote. An organisation that has since
  -- written its own derivation keeps it: this is their configuration.
  update erp.dimension
     set derivation = v_new, updated_at = now()
   where code = 'COST_CENTRE' and derivation = v_old;
  get diagnostics v_n = row_count;
  raise notice 'COST_CENTRE derivation extended for % organisation(s)', v_n;
end
$cc_derivation$;

-- And for organisations that have not created it yet.
create or replace function erp.ensure_cost_centre_dimension()
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin
  select d.id into v_id
    from erp.dimension d
   where d.tenant_id = v_tenant and d.code = 'COST_CENTRE';

  if v_id is null then
    insert into erp.dimension (tenant_id, code, name, derivation, is_mandatory_default)
    values (v_tenant, 'COST_CENTRE', 'Cost centre',
            jsonb_build_object('coalesce', jsonb_build_array(
              jsonb_build_object('var', 'document.attributes.cost_centre'),
              jsonb_build_object('var', 'document.department_cost_centre'),
              jsonb_build_object('var', 'document.attributes.department'),
              jsonb_build_object('var', 'document.site_code'))),
            false)
    returning id into v_id;
  end if;
  return v_id;
end $$;

comment on function erp.ensure_cost_centre_dimension is
  'The cost centre dimension for this organisation, created on first use. The '
  'derivation takes the document''s own answer, then the raising department''s '
  'default cost centre, then the department code, then the site.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A heading carries what was posted beneath it
-- ═════════════════════════════════════════════════════════════════════════════

-- From 20260911005223, never patched since. The only change is the last
-- predicate: a cost centre now matches itself or anything beneath it.
create or replace function erp.statement_lines(
  p_from date,
  p_to date,
  p_ledger text,
  p_cost_centre text)
returns table (
  account_code text,
  account_name text,
  account_type text,
  currency text,
  debit_minor bigint,
  credit_minor bigint)
language sql
stable
set search_path to ''
as $$
  with recursive beneath as (
    select dv.id, dv.code, 1 as depth
      from erp.dimension_value dv
      join erp.dimension dm on dm.tenant_id = dv.tenant_id and dm.id = dv.dimension_id
     where dv.tenant_id = erp.current_tenant_id()
       and dm.code = 'COST_CENTRE'
       and dv.code = upper(btrim(p_cost_centre))
    union all
    select child.id, child.code, beneath.depth + 1
      from erp.dimension_value child
      join beneath on child.parent_value_id = beneath.id
     where child.tenant_id = erp.current_tenant_id()
       -- A parent chain is a tree in the screen and nothing enforces that it is
       -- one in the table. Twenty levels is deeper than any chart of centres,
       -- and a loop stops rather than hanging the report.
       and beneath.depth < 20
  )
  select a.code, a.name, a.account_type::text,
         coalesce(led.currency, l.currency),
         sum(l.base_debit_minor)::bigint,
         sum(l.base_credit_minor)::bigint
    from erp.journal_line l
    join erp.journal j on j.id = l.journal_id and j.status = 'posted'
    join erp.ledger led on led.id = j.ledger_id
    join erp.account a on a.id = l.account_id
   where l.tenant_id = erp.current_tenant_id()
     and (p_from is null or j.posting_date >= p_from)
     and (p_to is null or j.posting_date <= p_to)
     and (p_ledger is null or led.code = upper(btrim(p_ledger)))
     and (p_cost_centre is null
          -- The centre itself, whether or not finance ever declared it as a
          -- dimension value, and then everything grouped under it.
          or l.dimensions ->> 'COST_CENTRE' = upper(btrim(p_cost_centre))
          or l.dimensions ->> 'COST_CENTRE' in (select b.code from beneath b))
   group by a.code, a.name, a.account_type, coalesce(led.currency, l.currency)
$$;

comment on function erp.statement_lines is
  'Posted movement per account, narrowed by period, ledger and cost centre. A '
  'cost centre carries what was posted to it and to every centre grouped '
  'beneath it, so a heading reads as the heading its parent field made it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The document and reporting languages reach a render
-- ═════════════════════════════════════════════════════════════════════════════

-- The renderer's door. Made volatile by 20260904670000 because it authorises,
-- and it stays volatile. The locale it is given used to default to English,
-- which is what /operations/output sent whenever nobody typed one in.
create or replace function public.erp_render_output_template(
  p_code text, p_document_id uuid default null, p_locale text default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure', null, null, null,
                        'output_template', null);
  return erp.render_output_template(p_code, p_document_id,
    coalesce(p_locale,
             erp.resolve_locale('document',
               (select d.entity_id from erp.document d where d.id = p_document_id))));
end;
$$;

comment on function public.erp_render_output_template(text, uuid, text) is
  'Resolves an output layout against a document. A caller that names no locale '
  'gets the company''s document language, or the person''s, rather than English.';

-- The order form. 20260914093000 needle-patched this body, so this patches the
-- body as it now stands rather than re-stating the one 20260904600000 wrote.
do $order_form_render$
declare
  v_sig    constant text := 'erp.issue_quote(uuid)';
  v_def    text := pg_get_functiondef('erp.issue_quote(uuid)'::regprocedure);
  v_needle constant text := $n$erp.render_output_template('order_form', p_document_id, 'en')$n$;
  v_new    constant text := $n$erp.render_output_template('order_form', p_document_id, erp.resolve_locale('document', (select dq.entity_id from erp.document dq where dq.id = p_document_id)))$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not render the order form in the literal English exactly once', v_sig
      using hint = 'A later migration changed how the order form is rendered. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position($n$erp.resolve_locale('document'$n$ in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$order_form_render$;

-- And the locale recorded against the archived order form, which is what the
-- output register is read back by.
do $order_form_request$
declare
  v_sig    constant text := 'erp.issue_quote(uuid)';
  v_def    text := pg_get_functiondef('erp.issue_quote(uuid)'::regprocedure);
  v_needle constant text := $n$'archive_only', null, 'en', 1, 'commercial.quote_issued'$n$;
  v_new    constant text := $n$'archive_only', null, erp.resolve_locale('document', (select dq.entity_id from erp.document dq where dq.id = p_document_id)), 1, 'commercial.quote_issued'$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not ask for the order form output in the literal English exactly once', v_sig
      using hint = 'A later migration changed how the order form is archived. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position($n$'archive_only', null, 'en'$n$ in pg_get_functiondef(v_sig::regprocedure)) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$order_form_request$;

-- The report extract, which stamped English on every extract any organisation
-- has ever produced.
do $extract_locale$
declare
  v_sig    constant text := 'erp.produce_report_extract(uuid)';
  v_def    text := pg_get_functiondef('erp.produce_report_extract(uuid)'::regprocedure);
  v_needle constant text := $n$'archive_only', 'en', 1, 'report.extract', v_run.run_by)$n$;
  v_new    constant text := $n$'archive_only', erp.resolve_locale('reporting'), 1, 'report.extract', v_run.run_by)$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not stamp the literal English on its output request exactly once', v_sig
      using hint = 'A later migration changed how an extract is requested. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position($n$erp.resolve_locale('reporting')$n$ in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$extract_locale$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.wired_setting_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases   integer := 0;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid; v_ccy char(3);
  v_ledger  uuid; v_ledger_code text;
  v_acc     uuid; v_acc_code text; v_acc2 uuid;
  v_party   uuid; v_supplier uuid; v_item uuid;
  v_cr      uuid; v_cr2 uuid; v_cr3 uuid; v_task uuid;
  v_status  erp.change_request_status;
  v_doc     uuid; v_doc2 uuid; v_doc3 uuid; v_doc4 uuid;
  v_dims    jsonb; v_dims2 jsonb; v_dims3 jsonb;
  v_journal uuid;
  v_render  jsonb; v_render_en jsonb;
  v_parent  bigint; v_child bigint; v_other bigint;
  v_doc_loc text; v_rep_loc text;
  v_person_doc_loc text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-wired-setting', 'Wired setting suite',
                              'admin@zz-wired-setting.test', 'Wired Setting Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f4', 'admin@zz-wired-setting.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f4')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.id, l.code, l.entity_id, l.currency
    into v_ledger, v_ledger_code, v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select i.id into v_item from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status order by i.code limit 1;
  select p.id into v_party from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
                          and pr.role_kind = 'customer'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_supplier from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
                          and pr.role_kind = 'supplier'
   where p.tenant_id = v_tenant order by p.code limit 1;
  -- The two operating-expense accounts the dimension suite has used since
  -- 20260906135000, and the lowest postable codes if a chart ever drops them.
  select a.id, a.code into v_acc, v_acc_code from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.is_postable
     and a.status = 'active'
   order by (a.code <> '8100'), a.code limit 1;
  select a.id into v_acc2 from erp.account a
   where a.tenant_id = v_tenant and a.entity_id = v_entity and a.is_postable
     and a.status = 'active' and a.id <> v_acc
   order by (a.code <> '8900'), a.code limit 1;

  -- ── 1. An approved change request reads as approved ───────────────────────
  -- tax_identifier is one of the three fields erp.configure_master_data()
  -- routes through the master_data_change chain.
  v_cases := v_cases + 1;
  v_cr := erp.open_change_request('party', v_party,
            jsonb_build_object('tax_identifier', 'GB424242424'), 'new registration');
  v_status := erp.submit_change_request(v_cr);
  select t.id into v_task from erp.approval_task t
    join erp.approval_request ar on ar.id = t.approval_request_id
   where ar.tenant_id = v_tenant and ar.object_type = 'change_request'
     and ar.object_id = v_cr and t.status = 'pending'
   order by (t.assignee_user_id <> erp.current_principal_id())
   limit 1;
  perform erp.decide_approval_task(v_task, true, 'seen the certificate');
  case_name := 'a change request somebody approved reads as approved on the governance screen, not as still pending';
  passed := v_status = 'pending'
        and v_task is not null
        and exists (select 1 from jsonb_array_elements(public.erp_change_requests('party')) x
                     where (x ->> 'change_request_id')::uuid = v_cr
                       and x ->> 'status' = 'approved'
                       and x ->> 'stored_status' = 'pending');
  detail := format('submitted as %s, the door now says %s', v_status,
                   coalesce((select x ->> 'status'
                               from jsonb_array_elements(public.erp_change_requests('party')) x
                              where (x ->> 'change_request_id')::uuid = v_cr), '(absent)'));
  return next;

  -- ── 2. And it can be applied, which is what the screen offers ─────────────
  v_cases := v_cases + 1;
  perform erp.apply_change_request(v_cr);
  case_name := 'and applying it writes the field, so the button the screen now shows does what it says';
  passed := (select p.tax_identifier from erp.party p where p.id = v_party) = 'GB424242424';
  detail := format('the party now carries %s',
                   coalesce((select p.tax_identifier from erp.party p where p.id = v_party), '(none)'));
  return next;

  -- ── 3. A refused request reads as refused ─────────────────────────────────
  v_cases := v_cases + 1;
  v_cr2 := erp.open_change_request('party', v_party,
             jsonb_build_object('country_code', 'IE'), 'moved');
  perform erp.submit_change_request(v_cr2);
  select t.id into v_task from erp.approval_task t
    join erp.approval_request ar on ar.id = t.approval_request_id
   where ar.tenant_id = v_tenant and ar.object_type = 'change_request'
     and ar.object_id = v_cr2 and t.status = 'pending'
   order by (t.assignee_user_id <> erp.current_principal_id())
   limit 1;
  perform erp.decide_approval_task(v_task, false, 'the registration says otherwise');
  case_name := 'a change request somebody refused reads as refused, rather than waiting for ever';
  passed := exists (select 1 from jsonb_array_elements(public.erp_change_requests('party')) x
                     where (x ->> 'change_request_id')::uuid = v_cr2
                       and x ->> 'status' = 'rejected'
                       and x ->> 'stored_status' = 'pending');
  detail := format('the door says %s',
                   coalesce((select x ->> 'status'
                               from jsonb_array_elements(public.erp_change_requests('party')) x
                              where (x ->> 'change_request_id')::uuid = v_cr2), '(absent)'));
  return next;

  -- ── 4. An ungoverned field still needs nobody ─────────────────────────────
  v_cases := v_cases + 1;
  v_cr3 := erp.open_change_request('party', v_party,
             jsonb_build_object('name', 'Northgate Retail Group'), 'trading name tidy-up');
  v_status := erp.submit_change_request(v_cr3);
  case_name := 'a change to a field nobody governs still reads as approved the moment it is submitted';
  passed := v_status = 'approved'
        and exists (select 1 from jsonb_array_elements(public.erp_change_requests('party')) x
                     where (x ->> 'change_request_id')::uuid = v_cr3
                       and x ->> 'status' = 'approved'
                       and x ->> 'stored_status' = 'approved');
  detail := '"nobody had to approve this" is a different fact from "somebody did", and both read as approved';
  return next;

  -- ── The cost centres ──────────────────────────────────────────────────────
  perform erp.ensure_cost_centre_dimension();
  perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-HEAD', 'Operations, all of it');
  perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-LEEDS', 'Leeds operations', 'ZZ-HEAD');
  perform erp.upsert_dimension_value('COST_CENTRE', 'ZZ-ELSEWHERE', 'Somewhere else entirely');
  perform erp.upsert_dimension_value('COST_CENTRE', 'ZZFIN', 'Finance department');
  perform erp.upsert_department('ZZOPS', 'Operations', null, null, 'ZZ-LEEDS');
  perform erp.upsert_department('ZZFIN', 'Finance');

  -- ── 5. The department's chosen centre is what the posting carries ─────────
  v_cases := v_cases + 1;
  v_doc := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
  update erp.document set attributes = jsonb_build_object('department', 'ZZOPS')
   where id = v_doc;
  perform erp.add_document_line(v_doc, v_item, 1, 10000, 'spend the operations department approves');
  v_dims := erp.derive_dimensions(v_doc, v_acc_code, '{}'::jsonb);
  case_name := 'a posting is charged to the cost centre the department chose, not to the department code';
  passed := v_dims ->> 'COST_CENTRE' = 'ZZ-LEEDS';
  detail := format('the department named ZZ-LEEDS and the posting carries %s',
                   coalesce(v_dims ->> 'COST_CENTRE', '(none)'));
  return next;

  -- ── 6. A department that chose none still falls back to its code ──────────
  v_cases := v_cases + 1;
  v_doc2 := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
  update erp.document set attributes = jsonb_build_object('department', 'ZZFIN')
   where id = v_doc2;
  perform erp.add_document_line(v_doc2, v_item, 1, 10000, 'a department with no default centre');
  v_dims2 := erp.derive_dimensions(v_doc2, v_acc_code, '{}'::jsonb);
  case_name := 'a department that has chosen no cost centre is still charged under its own code';
  passed := v_dims2 ->> 'COST_CENTRE' = 'ZZFIN';
  detail := format('no default chosen, so the department code stands: %s',
                   coalesce(v_dims2 ->> 'COST_CENTRE', '(none)'));
  return next;

  -- ── 7. And the document's own answer still wins ───────────────────────────
  v_cases := v_cases + 1;
  v_doc3 := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
  update erp.document set attributes = jsonb_build_object('department', 'ZZOPS',
                                                          'cost_centre', 'ZZ-ELSEWHERE')
   where id = v_doc3;
  perform erp.add_document_line(v_doc3, v_item, 1, 10000, 'the document knows better');
  v_dims3 := erp.derive_dimensions(v_doc3, v_acc_code, '{}'::jsonb);
  case_name := 'what the document itself names still beats the department''s default';
  passed := v_dims3 ->> 'COST_CENTRE' = 'ZZ-ELSEWHERE';
  detail := format('the document said ZZ-ELSEWHERE and the department said ZZ-LEEDS: %s',
                   coalesce(v_dims3 ->> 'COST_CENTRE', '(none)'));
  return next;

  -- ── 8. A heading carries what was posted beneath it ───────────────────────
  insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                           description, status, manual_reason)
  values (v_tenant, v_entity, v_ledger, 'manual', current_date,
          'wired setting suite', 'draft', 'the suite is proving the roll-up')
  returning id into v_journal;
  insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                credit_minor, currency, base_debit_minor, base_credit_minor,
                                exchange_rate, dimensions)
  values (v_tenant, v_journal, 1, v_acc,  75000, 0, v_ccy, 75000, 0, 1,
          jsonb_build_object('COST_CENTRE', 'ZZ-LEEDS')),
         (v_tenant, v_journal, 2, v_acc2, 0, 75000, v_ccy, 0, 75000, 1,
          jsonb_build_object('COST_CENTRE', 'ZZ-LEEDS'));
  update erp.journal set status = 'posted', posted_at = now() where id = v_journal;

  v_cases := v_cases + 1;
  select coalesce(sum(s.debit_minor), 0) into v_parent
    from erp.statement_lines(null, null, v_ledger_code, 'ZZ-HEAD') s;
  case_name := 'a cost centre that groups others carries what was posted to them, so the heading is a heading';
  passed := v_parent = 75000;
  detail := format('%s posted to ZZ-LEEDS, %s read under its heading ZZ-HEAD', 75000, v_parent);
  return next;

  -- ── 9. Without spilling into a centre outside the tree ────────────────────
  v_cases := v_cases + 1;
  select coalesce(sum(s.debit_minor), 0) into v_child
    from erp.statement_lines(null, null, v_ledger_code, 'ZZ-LEEDS') s;
  select coalesce(sum(s.debit_minor), 0) into v_other
    from erp.statement_lines(null, null, v_ledger_code, 'ZZ-ELSEWHERE') s;
  case_name := 'the centre itself still reads as itself, and a centre outside the heading carries none of it';
  passed := v_child = 75000 and v_other = 0;
  detail := format('ZZ-LEEDS %s, ZZ-ELSEWHERE %s', v_child, v_other);
  return next;

  -- ── 10. A document renders in the language the company chose ──────────────
  -- Two screens store a document language: the company's, on erp.entity, which
  -- is what a printed document follows, and the person's, on erp.app_user,
  -- which answers when no company is in play. Both were stored and read by
  -- nothing at all.
  v_cases := v_cases + 1;
  update erp.entity set document_locale = 'de', reporting_locale = 'de'
   where tenant_id = v_tenant and id = v_entity;
  perform public.erp_update_my_profile(null, null, 'Wired Setting Admin', null,
                                       'en', 'fr', 'fr');
  perform erp.upsert_output_template('zz_wired_note', 'output.template.zz_wired_note',
                                     'document', 'purchase_order', 'A4',
                                     '[{"kind":"title"}]'::jsonb);
  v_doc4 := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
  v_render := public.erp_render_output_template('zz_wired_note', v_doc4);
  v_render_en := public.erp_render_output_template('zz_wired_note', v_doc4, 'en');
  v_doc_loc := erp.resolve_locale('document', v_entity);
  v_person_doc_loc := erp.resolve_locale('document');
  case_name := 'a document renders in the document language the company chose, the person''s answers when no company does, and a caller that names one still gets it';
  passed := v_doc_loc = 'de'
        and v_person_doc_loc = 'fr'
        and v_render ->> 'locale' = 'de'
        and v_render_en ->> 'locale' = 'en';
  detail := format('the company says %s, the person says %s, the render says %s, an explicit request says %s',
                   v_doc_loc, v_person_doc_loc,
                   coalesce(v_render ->> 'locale', '(none)'),
                   coalesce(v_render_en ->> 'locale', '(none)'));
  return next;

  -- ── 11. And the reporting language is what an extract is stamped with ─────
  -- The extract itself needs reporting services installed and a deferred run;
  -- erp_test.reporting_services_suite() builds that. What is proved here is
  -- that the field resolves and that the stamp is the resolution rather than
  -- the literal every extract ever produced carried.
  v_cases := v_cases + 1;
  v_rep_loc := erp.resolve_locale('reporting');
  case_name := 'the reporting language a person stores is what a report extract is stamped with, rather than English';
  passed := v_rep_loc = 'fr'
        and erp.resolve_locale('reporting', v_entity) = 'de'
        and position($n$erp.resolve_locale('reporting')$n$ in
              pg_get_functiondef('erp.produce_report_extract(uuid)'::regprocedure)) > 0
        and position($n$'archive_only', 'en'$n$ in
              pg_get_functiondef('erp.produce_report_extract(uuid)'::regprocedure)) = 0;
  detail := format('the person says %s, the company says %s, and the extract no longer stamps the literal English',
                   v_rep_loc, erp.resolve_locale('reporting', v_entity));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 12. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-wired-setting')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f4');
  detail := 'zz-wired-setting rolled back with its change requests, cost centres and journal';
  return next;

  if v_cases <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: wired_setting_suite ran % cases, expected 12', v_cases;
  end if;
end;
$$;

comment on function erp_test.wired_setting_suite() is
  'The four settings a screen stored and nothing read: the change request''s '
  'status, the department''s default cost centre, the cost centre''s parent, '
  'and the document and reporting languages.';

create or replace function erp_test.assert_wired_setting_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _wired_setting on commit drop as
    select * from erp_test.wired_setting_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _wired_setting;
  drop table _wired_setting;
  if v_fail > 0 then
    raise exception E'CLOVEERP_WIRED_SETTING_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 12 then
    raise exception 'CLOVEERP_SUITE_SHRANK: wired_setting_suite ran % cases, expected 12', v_all;
  end if;
  return format('wired settings: %s/%s cases passed', v_all, v_all);
end;
$$;

select erp.apply_execute_grants();

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The assertions this migration must pass
-- ═════════════════════════════════════════════════════════════════════════════

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();
select erp_test.assert_wired_setting_suite();
