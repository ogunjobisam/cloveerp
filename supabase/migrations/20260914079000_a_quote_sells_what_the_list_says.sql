-- =============================================================================
-- A quote sells what the list says, and a contract is made wherever you are
--
-- 20260914077000 loaded the price list the platform owner set on 14 September
-- and left four things a quote could not yet say. This migration says them,
-- and fixes a fault in every console routine that works inside another
-- organisation.
--
--   1. The console borrowed an organisation by setting erp.job_tenant_id. That
--      context is honoured only when nobody is signed in: erp.current_tenant_id()
--      prefers the signed-in person's own organisation. So a platform owner who
--      belonged to any organisation and pressed "Create contract" had the
--      quote read from their own organisation (CLOVEERP_QUOTE_HAS_NO_PLAN),
--      and "contract signed", "invoice issued" and the rest were appended to
--      their own organisation's event stream rather than the customer's. The
--      suites never saw it because their platform owner belonged to none.
--      erp_meta.act_in_tenant() sets the person aside for the duration, the
--      way a sweep runs, and erp_meta.stop_acting_in_tenant() puts them back;
--      every commercial routine that borrowed an organisation now uses them.
--      The platform log still names who did it.
--   2. One-off charges. Onboarding and the pilot are charged once, not every
--      year: a price item says whether it recurs, a quote totals the two
--      apart, a contract's annual value is the recurring part, and a one-off
--      charge rides on the first invoice issued after it. A renewal does not
--      carry one-off lines forward.
--   3. Extras raise limits. An extra company or site is sold against the
--      plan's allowance and the contract provisions the plan's limit plus the
--      quantity sold.
--   4. Priority support is ten per cent of the recurring subscription and never
--      less than its rate. A price item can be priced as a share of the
--      recurring lines, and a quote is repriced whenever its lines change.
--   5. The founding customer programme. A quote may belong to it. A discount
--      is refused above 25%, or above 35% on a founding customer quote, and a
--      revised quote keeps its programme.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Acting inside another organisation
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_meta.act_in_tenant(p_tenant_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  -- Only a session that may declare a tenant at all. A signed-in caller reaches
  -- this only from inside a security definer routine, which is that session.
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not act inside an organisation', current_user
      using errcode = '42501';
  end if;
  -- The person is set aside once; a second call only moves to another
  -- organisation, so a routine that walks several keeps the first identity.
  if coalesce(current_setting('erp.acting_set_aside', true), '') = '' then
    perform set_config('erp.acting_claims', coalesce(current_setting('request.jwt.claims', true), ''), true);
    perform set_config('erp.acting_claim_sub', coalesce(current_setting('request.jwt.claim.sub', true), ''), true);
    perform set_config('erp.acting_set_aside', 'yes', true);
  end if;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('erp.job_tenant_id', coalesce(p_tenant_id::text, ''), true);
end;
$$;

comment on function erp_meta.act_in_tenant(uuid) is
  'Works inside one organisation from a platform routine: sets the signed-in '
  'person aside for the rest of the call, so erp.current_tenant_id() is the '
  'organisation named rather than the person''s own, and names that '
  'organisation as the job context. Transaction-local. Pair with '
  'erp_meta.stop_acting_in_tenant().';

create or replace function erp_meta.stop_acting_in_tenant()
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  perform set_config('erp.job_tenant_id', '', true);
  if coalesce(current_setting('erp.acting_set_aside', true), '') <> '' then
    perform set_config('request.jwt.claims', coalesce(current_setting('erp.acting_claims', true), ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(current_setting('erp.acting_claim_sub', true), ''), true);
    perform set_config('erp.acting_set_aside', '', true);
    perform set_config('erp.acting_claims', '', true);
    perform set_config('erp.acting_claim_sub', '', true);
  end if;
end;
$$;

comment on function erp_meta.stop_acting_in_tenant() is
  'Ends erp_meta.act_in_tenant(): clears the job context and gives the '
  'signed-in person back to the rest of the call.';

revoke all on function erp_meta.act_in_tenant(uuid) from public, anon, authenticated;
revoke all on function erp_meta.stop_acting_in_tenant() from public, anon, authenticated;

-- Every commercial routine that borrowed an organisation.
do $acting$
declare
  v_sig text;
  v_def text;
  v_new text;
begin
  foreach v_sig in array array[
    'erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)',
    'erp.sign_contract(uuid,text,text,text)',
    'erp.sign_amendment(uuid,text,text,text)',
    'erp.raise_contract_key_dates()',
    'erp.renew_contract(uuid,text,text,text)',
    'erp.decline_renewal(uuid,text)',
    'erp.expire_contracts()',
    'erp.issue_contract_invoice(uuid)',
    'erp.revenue_report()']
  loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    v_new := regexp_replace(v_def,
      $r$perform set_config\('erp\.job_tenant_id', '', true\);$r$,
      'perform erp_meta.stop_acting_in_tenant();', 'g');
    v_new := regexp_replace(v_new,
      $r$perform set_config\('erp\.job_tenant_id', ([a-z_.]+)::text, true\);$r$,
      'perform erp_meta.act_in_tenant(\1);', 'g');
    if v_new = v_def or position('erp.job_tenant_id' in v_new) > 0 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not borrow an organisation the way the commercial routines were written', v_sig;
    end if;
    execute v_new;
  end loop;
end
$acting$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2–4. What a price item says about how it is charged
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.price_item add column if not exists charge text not null default 'recurring';
alter table erp.price_item drop constraint if exists price_item_charge_known;
alter table erp.price_item add constraint price_item_charge_known check (charge in ('recurring', 'one_off'));

alter table erp.price_item add column if not exists percent_of_recurring numeric;
alter table erp.price_item drop constraint if exists price_item_percent_is_a_share;
alter table erp.price_item add constraint price_item_percent_is_a_share check (
  percent_of_recurring is null or (percent_of_recurring > 0 and percent_of_recurring <= 100 and charge = 'recurring'));

comment on column erp.price_item.charge is
  'recurring: charged every term and part of a contract''s annual value. '
  'one_off: charged once, on the first invoice issued after the contract.';
comment on column erp.price_item.percent_of_recurring is
  'Priced as this share of a quote''s other recurring lines, and never less than '
  'its rate on the price book. Priority support is 10.';

-- The list as already loaded, where it has been.
update erp.price_item pi
   set charge = 'one_off', updated_at = now()
  from erp.item x
 where x.tenant_id = pi.tenant_id and x.id = pi.item_id
   and x.code in ('ONBOARD-GUIDED', 'ONBOARD-STANDARD', 'PILOT-30') and pi.kind = 'service'
   and pi.tenant_id in (select po.tenant_id from erp_meta.platform_organisation po);
update erp.price_item pi
   set entitlement_code = case x.code when 'COMPANY-EXTRA' then 'companies' else 'sites' end, updated_at = now()
  from erp.item x
 where x.tenant_id = pi.tenant_id and x.id = pi.item_id
   and x.code in ('COMPANY-EXTRA', 'SITE-EXTRA') and pi.kind = 'service'
   and pi.tenant_id in (select po.tenant_id from erp_meta.platform_organisation po);
update erp.price_item pi
   set percent_of_recurring = 10, updated_at = now()
  from erp.item x
 where x.tenant_id = pi.tenant_id and x.id = pi.item_id
   and x.code = 'SUPPORT-PRIORITY' and pi.kind = 'support_tier'
   and pi.tenant_id in (select po.tenant_id from erp_meta.platform_organisation po);

-- And as it will be loaded.
do $selling$
declare
  v_sig    constant text := 'erp.set_up_selling()';
  v_def    text := pg_get_functiondef('erp.set_up_selling()'::regprocedure);
  v_needle constant text := $n$      if i.included_users is not null then$n$;
  v_new    constant text := $n$      -- One-off, an extra that raises a limit, or a share of the subscription.
      if i.one_off or i.code in ('COMPANY-EXTRA', 'SITE-EXTRA', 'SUPPORT-PRIORITY') then
        update erp.price_item pi
           set charge = case when i.one_off then 'one_off' else pi.charge end,
               entitlement_code = case i.code when 'COMPANY-EXTRA' then 'companies'
                                              when 'SITE-EXTRA' then 'sites'
                                              else pi.entitlement_code end,
               percent_of_recurring = case when i.code = 'SUPPORT-PRIORITY' then 10 else pi.percent_of_recurring end,
               updated_at = now()
          from erp.item x
         where x.tenant_id = v_tenant and x.code = i.code
           and pi.tenant_id = x.tenant_id and pi.item_id = x.id;
      end if;
      if i.included_users is not null then$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914077000 body', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$selling$;

-- The price book shows it.
do $book$
declare
  v_sig    constant text := 'erp.price_book_report()';
  v_def    text := pg_get_functiondef('erp.price_book_report()'::regprocedure);
  v_needle constant text := $n$'included_users', pi.included_users,$n$;
  v_new    constant text := $n$'included_users', pi.included_users, 'charge', pi.charge, 'percent_of_recurring', pi.percent_of_recurring,$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260914077000 body', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$book$;

-- A quote totals what recurs and what does not.
do $margin$
declare
  v_sig text := 'erp.quote_margin(uuid)';
  v_def text := pg_get_functiondef('erp.quote_margin(uuid)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$pi.support_severity_code, pi.legislation_pack_code$n$,
          $n$pi.support_severity_code, pi.legislation_pack_code, pi.charge$n$],
    array[$n$'legislation_pack_code', p.legislation_pack_code)$n$,
          $n$'legislation_pack_code', p.legislation_pack_code, 'charge', p.charge)$n$],
    array[$n$'max_discount_pct', coalesce(max(discount_pct), 0),$n$,
          $n$'recurring_minor', coalesce(sum(quoted_minor) filter (where coalesce(charge, 'recurring') = 'recurring'), 0),
               'one_off_minor', coalesce(sum(quoted_minor) filter (where charge = 'one_off'), 0),
               'max_discount_pct', coalesce(max(discount_pct), 0),$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, v_pairs[i][1];
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
end
$margin$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The founding customer programme and the discount ceiling
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.commercial_quote add column if not exists programme text;
alter table erp.commercial_quote drop constraint if exists commercial_quote_programme_known;
alter table erp.commercial_quote add constraint commercial_quote_programme_known check (
  programme is null or programme = 'founding');

comment on column erp.commercial_quote.programme is
  'founding: a founding customer quote, which may carry a discount of up to 35% '
  'in return for a case study, a monthly feedback call and being a reference. '
  'Every other quote may carry up to 25%.';

create or replace function erp.quote_discount_ceiling(p_document_id uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  -- The owner's rule, 14 September 2026: up to 10% the writer decides, beyond
  -- it the approval chain, beyond 25% only a founding customer, never beyond 35%.
  select case when cq.programme = 'founding' then 35::numeric else 25::numeric end
    from erp.commercial_quote cq
   where cq.tenant_id = erp.require_tenant_id() and cq.document_id = p_document_id
$$;

create or replace function erp.reprice_quote(p_document_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp.commercial_quote;
  l        record;
  v_base   bigint;
  v_price  bigint;
begin
  select * into q from erp.commercial_quote cq where cq.tenant_id = v_tenant and cq.document_id = p_document_id;
  if not found then
    return;
  end if;
  -- The recurring subscription the share is taken of: every recurring line
  -- that is not itself a share, after its discount.
  select coalesce(sum(round(dl.unit_price_minor * (1 - coalesce(dl.discount_pct, 0) / 100.0) * dl.quantity)), 0)::bigint
    into v_base
    from erp.document_line dl
    join erp.price_item pi on pi.tenant_id = dl.tenant_id and pi.item_id = dl.item_id
   where dl.tenant_id = v_tenant and dl.document_id = p_document_id and not dl.is_cancelled
     and pi.charge = 'recurring' and pi.percent_of_recurring is null;
  for l in
    select dl.id, dl.item_id, dl.unit_price_minor, pi.percent_of_recurring
      from erp.document_line dl
      join erp.price_item pi on pi.tenant_id = dl.tenant_id and pi.item_id = dl.item_id
     where dl.tenant_id = v_tenant and dl.document_id = p_document_id and not dl.is_cancelled
       and pi.percent_of_recurring is not null
  loop
    v_price := greatest(coalesce(erp.rate_for(l.item_id, q.price_book_code, q.term_kind, q.currency), 0),
                        round(v_base * l.percent_of_recurring / 100.0)::bigint);
    if v_price is distinct from l.unit_price_minor then
      update erp.document_line set unit_price_minor = v_price, updated_at = now() where id = l.id;
    end if;
  end loop;
end;
$$;

comment on function erp.reprice_quote(uuid) is
  'Prices every line that is a share of the recurring subscription, such as '
  'Priority support, at that share of the other recurring lines after '
  'discount, and never below its rate. Run whenever a quote''s lines change.';

create or replace function erp.set_quote_programme(p_document_id uuid, p_programme text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_programme text := nullif(btrim(coalesce(p_programme, '')), '');
begin
  perform erp.require_platform_organisation();
  perform erp.authorise('sales.order', null, null, null, 'commercial_quote', p_document_id);
  perform erp.require_quote_in_draft(p_document_id);
  if v_programme is not null and v_programme <> 'founding' then
    raise exception 'CLOVEERP_UNKNOWN_PROGRAMME: % is not a programme a quote can belong to', v_programme
      using errcode = '23514';
  end if;
  update erp.commercial_quote set programme = v_programme, updated_at = now()
   where tenant_id = v_tenant and document_id = p_document_id;
  if exists (select 1 from erp.document_line l
              where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                and coalesce(l.discount_pct, 0) > erp.quote_discount_ceiling(p_document_id)) then
    raise exception 'CLOVEERP_DISCOUNT_ABOVE_CEILING: a line is discounted by more than the % per cent this quote may carry',
      erp.quote_discount_ceiling(p_document_id) using errcode = '23514';
  end if;
  return v_programme;
end;
$$;

comment on function erp.set_quote_programme(uuid, text) is
  'Puts a draft quote in the founding customer programme, or takes it out. '
  'Refused when a line would then carry more discount than the quote may.';

create or replace function public.erp_set_quote_programme(p_document_id uuid, p_programme text)
returns text
language sql
volatile
set search_path = ''
as $$ select erp.set_quote_programme(p_document_id, p_programme); $$;

revoke all on function public.erp_set_quote_programme(uuid, text) from public, anon;
grant execute on function public.erp_set_quote_programme(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_set_quote_programme', 'erp.set_quote_programme',
   'Puts a draft quote in the founding customer programme. Refused outside the platform''s organisation; sales.order.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/commercial/quotes', array['erp_set_quote_programme']);

-- The quote writers: extras, the ceiling, and repricing.
do $quote_writers$
declare
  v_sig  text;
  v_def  text;
  v_pair text[];
  v_list jsonb := jsonb_build_array(
    jsonb_build_object('sig', 'erp.add_quote_line(uuid,text,numeric,numeric)', 'pairs', jsonb_build_array(
      jsonb_build_array(E'    else\n      null;\n  end case;',
        $n$    when 'service' then
      -- An extra company or site adds to the plan's allowance: sold for a plan
      -- with a limit to add to, once, and provisioned as that limit plus the
      -- quantity.
      if pi.entitlement_code is not null then
        if v_plan is null then
          raise exception 'CLOVEERP_QUOTE_EXTRA_BEFORE_PLAN: add the plan before the % it adds to', pi.entitlement_code
            using errcode = '23514';
        end if;
        select pe.limit_value into v_limit from erp_meta.plan_entitlement pe
         where pe.plan_code = v_plan and pe.entitlement_code = pi.entitlement_code;
        if v_limit is null then
          raise exception 'CLOVEERP_QUOTE_EXTRA_WITHIN_PLAN: the % plan has no limit on %, so there is nothing to add', v_plan, pi.entitlement_code
            using errcode = '23514';
        end if;
        if exists (select 1 from erp.document_line l
                    join erp.price_item x on x.tenant_id = l.tenant_id and x.item_id = l.item_id
                   where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                     and x.entitlement_code = pi.entitlement_code) then
          raise exception 'CLOVEERP_QUOTE_HAS_THIS_EXTRA: this quote already adds to %', pi.entitlement_code
            using errcode = '23514';
        end if;
      end if;
    else
      null;
  end case;$n$),
      jsonb_build_array($n$raise exception 'CLOVEERP_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;$n$,
        $n$raise exception 'CLOVEERP_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;
  if pi.kind <> 'legislation_pack'
     and coalesce(p_discount_pct, 0) > coalesce(erp.quote_discount_ceiling(p_document_id), 25) then
    raise exception 'CLOVEERP_DISCOUNT_ABOVE_CEILING: % per cent is more than the % per cent this quote may carry',
      p_discount_pct, coalesce(erp.quote_discount_ceiling(p_document_id), 25) using errcode = '23514';
  end if;$n$),
      jsonb_build_array(E'  return v_line;',
        E'  perform erp.reprice_quote(p_document_id);\n  return v_line;'))),
    jsonb_build_object('sig', 'erp.set_quote_line_discount(uuid,numeric)', 'pairs', jsonb_build_array(
      jsonb_build_array($n$raise exception 'CLOVEERP_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;$n$,
        $n$raise exception 'CLOVEERP_DISCOUNT_OUT_OF_RANGE: % is not a percentage', p_discount_pct using errcode = '23514';
  end if;
  if coalesce(v_kind, '') <> 'legislation_pack'
     and coalesce(p_discount_pct, 0) > coalesce(erp.quote_discount_ceiling(v_doc), 25) then
    raise exception 'CLOVEERP_DISCOUNT_ABOVE_CEILING: % per cent is more than the % per cent this quote may carry',
      p_discount_pct, coalesce(erp.quote_discount_ceiling(v_doc), 25) using errcode = '23514';
  end if;$n$),
      jsonb_build_array(E'   where id = p_line_id;\nend;',
        E'   where id = p_line_id;\n  perform erp.reprice_quote(v_doc);\nend;'))),
    jsonb_build_object('sig', 'erp.remove_quote_line(uuid)', 'pairs', jsonb_build_array(
      jsonb_build_array($n$where id = p_line_id;
end;$n$,
        $n$where id = p_line_id;
  perform erp.reprice_quote(v_doc);
end;$n$))),
    jsonb_build_object('sig', 'erp.submit_quote(uuid)', 'pairs', jsonb_build_array(
      jsonb_build_array(E'  perform erp.require_quote_in_draft(p_document_id);',
        $n$  perform erp.require_quote_in_draft(p_document_id);
  perform erp.reprice_quote(p_document_id);
  if exists (select 1 from erp.document_line l
              where l.tenant_id = v_tenant and l.document_id = p_document_id and not l.is_cancelled
                and coalesce(l.discount_pct, 0) > erp.quote_discount_ceiling(p_document_id)) then
    raise exception 'CLOVEERP_DISCOUNT_ABOVE_CEILING: a line is discounted by more than the % per cent this quote may carry',
      erp.quote_discount_ceiling(p_document_id) using errcode = '23514';
  end if;$n$))),
    jsonb_build_object('sig', 'erp.revise_quote(uuid,text)', 'pairs', jsonb_build_array(
      jsonb_build_array(E'     currency, valid_until, version, supersedes_document_id, notes)',
                        E'     currency, valid_until, version, supersedes_document_id, notes, programme)'),
      jsonb_build_array(E'q.currency, current_date + 30, q.version + 1, p_document_id, coalesce(p_reason, q.notes));',
                        E'q.currency, current_date + 30, q.version + 1, p_document_id, coalesce(p_reason, q.notes), q.programme);'))),
    jsonb_build_object('sig', 'erp.open_renewal_quote(uuid)', 'pairs', jsonb_build_array(
      jsonb_build_array(E'where x.tenant_id = v_tenant and x.document_id = c.quote_document_id and not x.is_cancelled',
        E'where x.tenant_id = v_tenant and x.document_id = c.quote_document_id and not x.is_cancelled\n       and not exists (select 1 from erp.price_item pi where pi.tenant_id = x.tenant_id and pi.item_id = x.item_id and pi.charge = ''one_off'')'))),
    jsonb_build_object('sig', 'erp.commercial_quote_detail(uuid)', 'pairs', jsonb_build_array(
      jsonb_build_array($n$'valid_until', cq.valid_until, 'notes', cq.notes,$n$,
                        $n$'valid_until', cq.valid_until, 'notes', cq.notes, 'programme', cq.programme,$n$))),
    jsonb_build_object('sig', 'erp.commercial_quotes_report()', 'pairs', jsonb_build_array(
      jsonb_build_array($n$'valid_until', cq.valid_until, 'state', erp.object_current_state('document', cq.document_id),$n$,
                        $n$'valid_until', cq.valid_until, 'programme', cq.programme, 'state', erp.object_current_state('document', cq.document_id),$n$))),
    jsonb_build_object('sig', 'erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)', 'pairs', jsonb_build_array(
      jsonb_build_array($n$v_annual := (m -> 'totals' ->> 'quoted_minor')::bigint * case q.term_kind when 'monthly' then 12 else 1 end;$n$,
                        $n$v_annual := (m -> 'totals' ->> 'recurring_minor')::bigint * case q.term_kind when 'monthly' then 12 else 1 end;$n$),
      jsonb_build_array($n$values (v_id, l ->> 'entitlement_code', (l ->> 'band_to')::numeric, p_commencement);$n$,
                        $n$values (v_id, l ->> 'entitlement_code',
              coalesce((l ->> 'band_to')::numeric,
                       (select pe.limit_value from erp_meta.plan_entitlement pe
                         where pe.plan_code = v_plan and pe.entitlement_code = l ->> 'entitlement_code')
                       + (l ->> 'quantity')::numeric),
              p_commencement);$n$),
      jsonb_build_array(E'  perform erp_meta.platform_log(\n    v_staff, ''platform.contract_created''',
        E'  -- What is charged once, to ride on the first invoice issued.\n  insert into erp_meta.contract_charge (contract_id, item_code, description, quantity, amount_minor, currency)\n  select v_id, x ->> ''item_code'', x ->> ''name'', (x ->> ''quantity'')::numeric, (x ->> ''quoted_minor'')::bigint, q.currency\n    from jsonb_array_elements(m -> ''lines'') x\n   where x ->> ''charge'' = ''one_off'';\n\n  perform erp_meta.platform_log(\n    v_staff, ''platform.contract_created'''))),
    jsonb_build_object('sig', 'erp.renew_contract(uuid,text,text,text)', 'pairs', jsonb_build_array(
      jsonb_build_array($n$v_annual := (m -> 'totals' ->> 'quoted_minor')::bigint * case c.term_kind when 'monthly' then 12 else 1 end;$n$,
                        $n$v_annual := (m -> 'totals' ->> 'recurring_minor')::bigint * case c.term_kind when 'monthly' then 12 else 1 end;$n$))));
  v_item jsonb;
  v_p    jsonb;
  v_from text;
  v_to   text;
begin
  for v_item in select * from jsonb_array_elements(v_list) loop
    v_sig := v_item ->> 'sig';
    v_def := pg_get_functiondef(v_sig::regprocedure);
    for v_p in select * from jsonb_array_elements(v_item -> 'pairs') loop
      v_from := v_p ->> 0;
      v_to := v_p ->> 1;
      if (length(v_def) - length(replace(v_def, v_from, ''))) / length(v_from) <> 1 then
        raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_from, 80);
      end if;
      v_def := replace(v_def, v_from, v_to);
    end loop;
    execute v_def;
  end loop;
end
$quote_writers$;

-- erp_test.commercial_quote_suite shows a below-cost line by discounting
-- implementation 30%, which is now a founding customer discount. The quote
-- joins the programme for that case and leaves it once the discount is back
-- to 5%.
do $quote_suite$
declare
  v_sig  constant text := 'erp_test.commercial_quote_suite()';
  v_def  text := pg_get_functiondef('erp_test.commercial_quote_suite()'::regprocedure);
  v_30   constant text := E'  perform erp.set_quote_line_discount(v_line, 30);';
  v_5    constant text := E'  perform erp.set_quote_line_discount(v_line, 5);';
begin
  if (length(v_def) - length(replace(v_def, v_30, ''))) / length(v_30) <> 1
     or (length(v_def) - length(replace(v_def, v_5, ''))) / length(v_5) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not discount implementation to 30%% and back to 5%% exactly once', v_sig;
  end if;
  v_def := replace(v_def, v_30, E'  perform erp.set_quote_programme(v_q, ''founding'');\n' || v_30);
  v_def := replace(v_def, v_5, v_5 || E'\n  perform erp.set_quote_programme(v_q, null);');
  execute v_def;
end
$quote_suite$;

-- ═════════════════════════════════════════════════════════════════════════════
-- One-off charges on the contract and its first invoice
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_meta.contract_charge (
  id            uuid primary key default gen_random_uuid(),
  contract_id   uuid not null references erp_meta.contract (id) on delete cascade,
  item_code     text not null,
  description   text not null,
  quantity      numeric not null default 1,
  amount_minor  bigint not null,
  currency      char(3) not null,
  invoice_id    uuid references erp_meta.contract_invoice (id) on delete set null,
  created_at    timestamptz not null default now(),
  constraint contract_charge_amount_non_negative check (amount_minor >= 0)
);

comment on table erp_meta.contract_charge is
  'What a contract charges once, such as onboarding or a pilot, from the one-off '
  'lines of the quote it was made from. Each rides on the first invoice issued '
  'after it and names that invoice. No foreign key to erp.tenant: billing '
  'outlives a purge.';

select erp_meta.register_table('erp_meta', 'contract_charge', 'platform_internal',
  'What a contract charges once, invoiced with the first invoice issued after it.');

alter table erp_meta.contract_invoice add column if not exists one_off_minor bigint not null default 0;

do $invoice$
declare
  v_sig text := 'erp.issue_contract_invoice(uuid)';
  v_def text := pg_get_functiondef('erp.issue_contract_invoice(uuid)'::regprocedure);
  v_n   integer;
begin
  if (length(v_def) - length(replace(v_def, 'v_over_minor bigint; v_lines jsonb;', ''))) / length('v_over_minor bigint; v_lines jsonb;') <> 1
     or (length(v_def) - length(replace(v_def, $n$'net_minor', i.subscription_minor)) || v_over;$n$, ''))) / length($n$'net_minor', i.subscription_minor)) || v_over;$n$) <> 1
     or (length(v_def) - length(replace(v_def, 'overage_minor = v_over_minor,', ''))) / length('overage_minor = v_over_minor,') <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260904620000 body', v_sig;
  end if;
  v_n := (length(v_def) - length(replace(v_def, 'i.subscription_minor + v_over_minor', ''))) / length('i.subscription_minor + v_over_minor');
  if v_n < 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not total the invoice', v_sig;
  end if;
  v_def := replace(v_def, 'v_over_minor bigint; v_lines jsonb;',
                          'v_over_minor bigint; v_lines jsonb; v_one_off jsonb; v_one_off_minor bigint := 0;');
  v_def := replace(v_def, 'i.subscription_minor + v_over_minor', 'i.subscription_minor + v_over_minor + v_one_off_minor');
  v_def := replace(v_def, 'overage_minor = v_over_minor,', 'overage_minor = v_over_minor, one_off_minor = v_one_off_minor,');
  v_def := replace(v_def, $n$'net_minor', i.subscription_minor)) || v_over;$n$,
    $n$'net_minor', i.subscription_minor)) || v_over;
  -- One-off charges not yet invoiced ride on this invoice, and say so.
  select coalesce(jsonb_agg(jsonb_build_object('kind', 'one_off', 'item_code', ch.item_code, 'description', ch.description,
                                               'quantity', ch.quantity, 'net_minor', ch.amount_minor)
                            order by ch.created_at), '[]'::jsonb),
         coalesce(sum(ch.amount_minor), 0)::bigint
    into v_one_off, v_one_off_minor
    from erp_meta.contract_charge ch
   where ch.contract_id = c.id and ch.invoice_id is null;
  update erp_meta.contract_charge set invoice_id = p_invoice_id where contract_id = c.id and invoice_id is null;
  v_lines := v_lines || v_one_off;$n$);
  execute v_def;
end
$invoice$;

-- ═════════════════════════════════════════════════════════════════════════════
-- Refusals
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_QUOTE_EXTRA_BEFORE_PLAN',
  'Adding an extra company or site to a quote that has no plan on it yet.',
  'An extra company or site adds to what a plan includes, so the plan comes first.',
  'Add the plan to the quote, then add the extra companies or sites.');

select erp.register_refusal('CLOVEERP_QUOTE_EXTRA_WITHIN_PLAN',
  'Adding an extra company or site to a plan that has no limit on them.',
  'The plan already includes as many as the customer needs, so an extra one would be charged for nothing.',
  'Remove the extra from the quote, or choose a plan that has a limit.');

select erp.register_refusal('CLOVEERP_QUOTE_HAS_THIS_EXTRA',
  'Adding a second line of extra companies, or of extra sites, to one quote.',
  'A quote carries one line for each, and the quantity on the line is how many are added.',
  'Remove the line and add it again with the number you want.');

select erp.register_refusal('CLOVEERP_DISCOUNT_ABOVE_CEILING',
  'Discounting a quote by more than it may carry.',
  'A quote may carry up to 25% off. More than that is kept for founding customers, who may have up to 35% in return for a case study, a monthly feedback call and being a reference.',
  'Lower the discount to 25% or less, or mark the quote as a founding customer quote and keep the discount to 35% or less.');

select erp.register_refusal('CLOVEERP_UNKNOWN_PROGRAMME',
  'Putting a quote in a programme that does not exist.',
  'The founding customer programme is the only programme a quote can belong to.',
  'Choose the founding customer programme, or leave the quote out of any programme.');

-- ═════════════════════════════════════════════════════════════════════════════
-- The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.quote_sells_the_list_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rp record; rc record; ro record;
  ad uuid := gen_random_uuid(); ow uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_platform uuid; v_pcode text := 'zzqsp-' || substr(md5(random()::text), 1, 6);
  v_customer uuid; v_ccode text := 'zzqsc-' || substr(md5(random()::text), 1, 6);
  v_own uuid;      v_ocode text := 'zzqso-' || substr(md5(random()::text), 1, 6);
  v_prior erp_meta.platform_organisation;
  v_q0 uuid; v_q1 uuid; v_q2 uuid; v_q3 uuid; v_line uuid; v_contract uuid; v_inv1 uuid; v_inv2 uuid;
  v_ok boolean; v_msg text; m jsonb; res jsonb; v_price bigint;
begin
  select po.* into v_prior from erp_meta.platform_organisation po;

  select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform List', 'admin@zzqsp.test', 'Platform Admin');
  v_platform := rp.tenant_id;
  select * into rc from erp.provision_tenant(v_ccode, 'Acme Foods Ltd', 'admin@zzqsc.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  -- The platform owner belongs to an organisation of their own, which is the
  -- case the console got wrong.
  select * into ro from erp.provision_tenant(v_ocode, 'Owner''s Own Company', 'owner@zzqsp.test', 'Platform Owner');
  v_own := ro.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzqsp.test'), (ow, 'owner@zzqsp.test'), (ca, 'admin@zzqsc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzqsp.test', ow, 'Platform Owner', 'owner');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(rp.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);
  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  perform erp.claim_invitation(ro.admin_token);
  perform erp.designate_platform_organisation(v_pcode, 'the quote sells the list suite');

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp_test.reopen_bootstrap_window(v_platform);
  perform erp.set_up_selling();
  perform erp_test.close_bootstrap_window(v_platform);

  return query select 'the list says what is charged once, what adds to a limit and what is a share of the subscription',
    (select pi.charge from erp.price_item pi join erp.item i on i.id = pi.item_id where pi.tenant_id = v_platform and i.code = 'ONBOARD-GUIDED') = 'one_off'
    and (select pi.entitlement_code from erp.price_item pi join erp.item i on i.id = pi.item_id where pi.tenant_id = v_platform and i.code = 'COMPANY-EXTRA') = 'companies'
    and (select pi.percent_of_recurring from erp.price_item pi join erp.item i on i.id = pi.item_id where pi.tenant_id = v_platform and i.code = 'SUPPORT-PRIORITY') = 10
    and (select pi.charge from erp.price_item pi join erp.item i on i.id = pi.item_id where pi.tenant_id = v_platform and i.code = 'PLAN-STANDARD') = 'recurring',
    'onboarding one-off, extra company adds to companies, Priority support 10%';

  -- ── Extras ───────────────────────────────────────────────────────────────

  v_q0 := erp.open_commercial_quote('BETA', 'Beta Group', 'CLOVE-LIST', 'annual', 12, 'GBP', 30);
  begin
    perform erp.add_quote_line(v_q0, 'COMPANY-EXTRA', 2);
    v_ok := false; v_msg := 'an extra company went on before a plan';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_EXTRA_BEFORE_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an extra company needs the plan it adds to', v_ok, v_msg;

  perform erp.add_quote_line(v_q0, 'PLAN-ENTERPRISE');
  begin
    perform erp.add_quote_line(v_q0, 'COMPANY-EXTRA', 2);
    v_ok := false; v_msg := 'an extra company was sold on a plan with no company limit';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_EXTRA_WITHIN_PLAN%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'and a plan with no limit has nothing to add to', v_ok, v_msg;

  v_q1 := erp.open_commercial_quote('ACME', 'Acme Foods Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_ccode);
  perform erp.add_quote_line(v_q1, 'PLAN-STANDARD');
  perform erp.add_quote_line(v_q1, 'COMPANY-EXTRA', 2);
  begin
    perform erp.add_quote_line(v_q1, 'COMPANY-EXTRA', 1);
    v_ok := false; v_msg := 'two lines of extra companies';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_QUOTE_HAS_THIS_EXTRA%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'one line of extra companies, its quantity the number added', v_ok, v_msg;

  -- ── Priority support ─────────────────────────────────────────────────────

  perform erp.add_quote_line(v_q1, 'USER-STANDARD', 10);
  perform erp.add_quote_line(v_q1, 'ONBOARD-GUIDED');
  v_line := erp.add_quote_line(v_q1, 'SUPPORT-PRIORITY');
  select l.unit_price_minor into v_price from erp.document_line l where l.id = v_line;
  return query select 'Priority support is ten per cent of the recurring subscription, not of one-off charges',
    v_price = round((1314000 + 2 * 180000 + 10 * 58800) * 0.10)::bigint,
    format('%s, from 1,314,000 + 360,000 + 588,000 recurring', v_price);

  perform erp.remove_quote_line((select l.id from erp.document_line l join erp.item i on i.id = l.item_id
                                  where l.document_id = v_q1 and i.code = 'USER-STANDARD' and not l.is_cancelled));
  select l.unit_price_minor into v_price from erp.document_line l where l.id = v_line;
  return query select 'and never less than its rate when the subscription shrinks',
    v_price = 180000, format('%s after the users were removed', v_price);

  m := erp.quote_margin(v_q1);
  return query select 'a quote totals what recurs apart from what is charged once',
    (m -> 'totals' ->> 'recurring_minor')::bigint = 1314000 + 360000 + 180000
    and (m -> 'totals' ->> 'one_off_minor')::bigint = 250000
    and (m -> 'totals' ->> 'quoted_minor')::bigint = 1314000 + 360000 + 180000 + 250000,
    format('recurring %s, one-off %s', m -> 'totals' ->> 'recurring_minor', m -> 'totals' ->> 'one_off_minor');

  -- ── The ceiling and the founding customer programme ─────────────────────

  v_q2 := erp.open_commercial_quote('GAMMA', 'Gamma Bakery', 'CLOVE-LIST', 'annual', 24, 'GBP', 30);
  v_line := erp.add_quote_line(v_q2, 'PLAN-STARTER');
  begin
    perform erp.set_quote_line_discount(v_line, 26);
    v_ok := false; v_msg := '26% was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DISCOUNT_ABOVE_CEILING%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a quote may carry up to 25% off', v_ok, v_msg;

  perform public.erp_set_quote_programme(v_q2, 'founding');
  perform erp.set_quote_line_discount(v_line, 35);
  begin
    perform erp.set_quote_line_discount(v_line, 36);
    v_ok := false; v_msg := '36% was accepted on a founding customer quote';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DISCOUNT_ABOVE_CEILING%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a founding customer quote may carry up to 35%, and no more',
    v_ok and (select l.discount_pct from erp.document_line l where l.id = v_line) = 35, v_msg;

  begin
    perform public.erp_set_quote_programme(v_q2, null);
    v_ok := false; v_msg := 'the programme was removed from a quote carrying 35%';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_DISCOUNT_ABOVE_CEILING%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a quote carrying 35% cannot leave the programme', v_ok, v_msg;

  v_q3 := erp.revise_quote(v_q2, 'second conversation');
  return query select 'a revised quote stays in its programme',
    (select cq.programme from erp.commercial_quote cq where cq.document_id = v_q3) = 'founding',
    'version 2 founding';

  -- ── A contract made by an owner who belongs to another organisation ──────

  perform erp.submit_quote(v_q1);
  perform erp.issue_quote(v_q1);
  perform erp.quote_transition(v_q1, 'accept', 'order form returned signed');

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  begin
    v_contract := erp.create_contract_from_quote(v_q1, v_ccode, 'Acme Foods Ltd', 'Clove ERP Ltd', current_date,
                                                 12, 'automatic', 90, 'England and Wales', 'monthly');
    v_msg := 'created';
  exception when others then
    v_msg := left(sqlerrm, 120);
  end;
  return query select 'an owner who belongs to another organisation makes a contract from the platform''s quote',
    v_contract is not null
    and erp.current_tenant_id() = v_own
    and (select c.annual_value_minor from erp_meta.contract c where c.id = v_contract) = 1314000 + 360000 + 180000,
    coalesce(v_msg, 'nothing');

  return query select 'the contract adds the extra companies to the plan''s limit and charges onboarding once',
    exists (select 1 from erp_meta.contract_entitlement ce
             where ce.contract_id = v_contract and ce.entitlement_code = 'companies'
               and ce.limit_value = (select pe.limit_value from erp_meta.plan_entitlement pe
                                      where pe.plan_code = 'standard' and pe.entitlement_code = 'companies') + 2)
    and (select count(*) from erp_meta.contract_charge ch where ch.contract_id = v_contract) = 1
    and (select ch.amount_minor from erp_meta.contract_charge ch where ch.contract_id = v_contract) = 250000,
    'companies = plan + 2; one charge of 250,000';

  perform erp.sign_contract(v_contract, 'A. Customer, director', 'Platform Owner, director', 'agreement to the order form');
  return query select 'signing tells the customer''s organisation, not the owner''s own',
    exists (select 1 from erp.event e where e.tenant_id = v_customer and e.event_type = 'commercial.contract_signed')
    and not exists (select 1 from erp.event e where e.tenant_id = v_own and e.event_type like 'commercial.%')
    and erp.current_tenant_id() = v_own,
    'contract_signed in the customer''s stream; the owner is themselves again afterwards';

  perform erp.generate_invoice_schedule(v_contract);
  select i.id into v_inv1 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq limit 1;
  select i.id into v_inv2 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq offset 1 limit 1;
  res := erp.issue_contract_invoice(v_inv1);
  perform erp.issue_contract_invoice(v_inv2);
  return query select 'the first invoice carries the one-off charge and the second does not',
    (select i.one_off_minor from erp_meta.contract_invoice i where i.id = v_inv1) = 250000
    and (select i.total_minor from erp_meta.contract_invoice i where i.id = v_inv1)
        = (select i.subscription_minor from erp_meta.contract_invoice i where i.id = v_inv1) + 250000
    and (select i.one_off_minor from erp_meta.contract_invoice i where i.id = v_inv2) = 0
    and (select ch.invoice_id from erp_meta.contract_charge ch where ch.contract_id = v_contract) = v_inv1
    and exists (select 1 from jsonb_array_elements(res -> 'lines') x where x ->> 'kind' = 'one_off'),
    format('first %s, second %s',
      (select i.total_minor from erp_meta.contract_invoice i where i.id = v_inv1),
      (select i.total_minor from erp_meta.contract_invoice i where i.id = v_inv2));

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.contract where id = v_contract;
  delete from erp_meta.subscription where tenant_id = v_customer;
  delete from erp_meta.platform_organisation where tenant_id = v_platform;
  perform erp.begin_tenant_purge(v_platform);
  delete from erp.tenant where id = v_platform;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_own);
  delete from erp.tenant where id = v_own;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzqsp.test';
  delete from auth.users where id in (ad, ow, ca);
  if v_prior.tenant_id is not null then
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_platform, v_customer, v_own))
    and not exists (select 1 from erp_meta.contract c where c.tenant_id = v_customer)
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'organisations, contract and staff gone, and any designation that was there before is back';
end;
$$;

create or replace function erp_test.assert_quote_sells_the_list_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _quote_sells_the_list_result on commit drop as
    select * from erp_test.quote_sells_the_list_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _quote_sells_the_list_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_QUOTE_SELLS_THE_LIST_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('a quote sells the list: %s/%s', v_passed, v_total);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_commercial_sound();
select erp.assert_commercial_quotes_sound();
select erp.assert_resource_coverage('en');
select erp.assert_guidance_sound();
select erp_test.assert_quote_sells_the_list_suite();
