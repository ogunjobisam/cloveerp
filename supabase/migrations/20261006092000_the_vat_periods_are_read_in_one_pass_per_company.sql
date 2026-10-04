set lock_timeout = '30s';

-- =============================================================================
-- 20261006092000  The VAT periods are read in one pass per company
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-42). The VAT returns
-- screen (public.erp_vat_obligations) sat at the signed-in limit and was
-- cancelled.
--
-- It worked the periods out twice (erp.vat_obligations, once for which period
-- is next and once for the list), asked the reader's two permissions, the
-- VAT return setting and whether a VAT return is installed again for every
-- period, and for every period not finalised built the preview with
-- erp.vat_return_figures, each reading erp.vat_entries afresh. The next
-- period to finalise takes everything no return took since the
-- registration's first day, so its read alone covers the company's whole
-- VAT history, and every later period read its own months again on top.
-- Each entry is worked out per journal: its trade side, its determinations,
-- its lines and its tax control lines.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.vat_return_figures_for_periods(company, periods): the figures of
--      several periods of one company from one read of its VAT entries and
--      one read of what its finalised returns took. Each period's object is
--      exactly erp.vat_return_figures's: the boxes, the entries, the journals,
--      the digest and what was carried forward. erp.vat_return_figures is
--      unchanged; erp.finalise_vat_return and erp_vat_boxes keep using it,
--      and it is the answer the new one is held to.
--   B. erp_test.vat_obligations_reference(company): the door's body as it
--      stands, word for word after its two authorise calls, kept as the
--      answer the new one must give.
--   C. public.erp_vat_obligations(company), same signature, gate, grants and
--      answer: the periods are worked out once; the permissions, the setting
--      and the installed check once per company; and the previews of a
--      company's periods in one call of A.
--   D. erp_test.vat_periods_once_suite, on a demonstration registered for VAT
--      from the quarter before last, whose return for that quarter was
--      finalised by the builder, which then traded a week inside that quarter
--      (carried forward to the next), a week at the end of last quarter and
--      into this one; read quarterly, and again monthly. Every period not
--      finalised has the figures erp.vat_return_figures gives it; the door's
--      whole answer is the reference's, for every company and for the one;
--      and the door reads the entries once per company.
--
-- On production: one door is replaced and one function added. No table is
-- altered and no row is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The figures of several periods, from one read of the entries
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_figures_for_periods(p_entity_id uuid, p_periods jsonb)
returns table(period_end date, figures jsonb)
language sql
stable
set search_path = ''
as $$
  -- erp.vat_return_figures for each of p_periods ([{period_start, period_end,
  -- take_from}]) of one company (20261006092000, J-42), from one read of its
  -- VAT entries over the widest window the periods ask for and one read of
  -- the journals its finalised returns took. A take_from that is null takes
  -- from the first entry, as erp.vat_entries reads a null from. Each object
  -- is built exactly as erp.vat_return_figures builds it.
  with t as (select erp.require_tenant_id() as tenant_id),
  per as materialized (
    select distinct (p ->> 'period_start')::date as period_start,
                    (p ->> 'period_end')::date as period_end,
                    (p ->> 'take_from')::date as take_from
      from jsonb_array_elements(coalesce(p_periods, '[]'::jsonb)) p
  ),
  span as (
    select case when bool_or(per.take_from is null) then null else min(per.take_from) end as from_day,
           max(per.period_end) as to_day
      from per
  ),
  taken as materialized (
    select (j.value #>> '{}')::uuid as journal_id
      from t
      join erp.document d
        on d.tenant_id = t.tenant_id and d.entity_id = p_entity_id and not d.is_cancelled
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id and dt.base_type_code = 'vat_return'
      cross join lateral jsonb_array_elements(coalesce(d.attributes #> '{vat_return,journal_ids}', '[]'::jsonb)) j
     where erp.object_current_state('document', d.id) = 'finalised'
  ),
  -- The company's entries, read once, less what a return took.
  e as materialized (
    select e.journal_id, e.side, e.tax_minor, e.net_minor, e.vat_date
      from span
      cross join lateral erp.vat_entries(p_entity_id, span.from_day, span.to_day) e
     where exists (select 1 from per)
       and not exists (select 1 from taken k where k.journal_id = e.journal_id)
  ),
  -- Each entry in every period whose window holds its date.
  x as (
    select per.period_start, per.period_end, per.take_from,
           e.journal_id, e.side, e.tax_minor, e.net_minor,
           e.vat_date < per.period_start as carried
      from per
      left join e
        on (per.take_from is null or e.vat_date >= per.take_from)
       and e.vat_date <= per.period_end
  ),
  b as (
    select x.period_start, x.period_end, x.take_from,
           coalesce(sum(x.tax_minor) filter (where x.side = 'sale'), 0)::bigint as box1,
           coalesce(sum(x.tax_minor) filter (where x.side = 'purchase'), 0)::bigint as box4,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'sale'), 0) / 100.0)::bigint as box6,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'purchase'), 0) / 100.0)::bigint as box7,
           count(x.journal_id) as entries,
           count(*) filter (where x.carried) as carried,
           coalesce(sum(x.net_minor) filter (where x.carried), 0)::bigint as carried_net,
           coalesce(sum(case x.side when 'sale' then x.tax_minor when 'purchase' then -x.tax_minor else 0 end)
                      filter (where x.carried), 0)::bigint as carried_tax,
           coalesce(jsonb_agg(x.journal_id order by x.journal_id::text)
                      filter (where x.journal_id is not null), '[]'::jsonb) as journal_ids,
           md5(coalesce(string_agg(x.journal_id::text || ':' || x.tax_minor || ':' || x.net_minor, ','
                                   order by x.journal_id::text)
                          filter (where x.journal_id is not null), '')) as digest
      from x
     group by x.period_start, x.period_end, x.take_from
  )
  select b.period_end,
         jsonb_build_object(
           'boxes', jsonb_build_object(
             'box1_minor', b.box1, 'box2_minor', 0, 'box3_minor', b.box1 + 0, 'box4_minor', b.box4,
             'box5_minor', abs(b.box1 + 0 - b.box4),
             'box5_is', case when b.box1 + 0 >= b.box4 then 'payable' else 'repayable' end,
             'box6_pounds', b.box6, 'box7_pounds', b.box7, 'box8_pounds', 0, 'box9_pounds', 0),
           'entries', b.entries,
           'journal_ids', b.journal_ids,
           'entries_digest', b.digest,
           'carried_forward', jsonb_build_object(
             'entries', b.carried, 'net_minor', b.carried_net, 'tax_minor', b.carried_tax,
             'threshold_minor', greatest(1000000, least(5000000, b.box6)),
             'over_threshold', abs(b.carried_tax) > greatest(1000000, least(5000000, b.box6))))
    from b
$$;

revoke all on function erp.vat_return_figures_for_periods(uuid, jsonb) from public, anon;

comment on function erp.vat_return_figures_for_periods(uuid, jsonb) is
  'erp.vat_return_figures for several periods of one company, each object built exactly as it builds it, from one '
  'read of the company''s VAT entries and of what its finalised returns took (20261006092000, J-42). Read by the '
  'obligations door for its previews; erp.vat_return_figures stays the one a return is finalised from.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Today's door body, kept as the answer
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.vat_obligations_reference(p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $reference$
declare
  v_tenant uuid;
  v_next   jsonb := '{}'::jsonb;
begin
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
$reference$;

revoke all on function erp_test.vat_obligations_reference(uuid) from public, anon;

comment on function erp_test.vat_obligations_reference(uuid) is
  'public.erp_vat_obligations(uuid) as it was before 20261006092000, word for word after its two authorise calls: '
  'the answer the VAT periods must still give (J-42). Read only by erp_test.vat_periods_once_suite.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The periods once, each company once, the previews in one pass
-- ─────────────────────────────────────────────────────────────────────────────

do $guard$
declare
  v_src text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = 'public.erp_vat_obligations(uuid)'::regprocedure);
begin
  if strpos(v_src, '20261006092000') = 0 and md5(v_src) <> '1674da9ffba44f39a0868db96630a558' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: public.erp_vat_obligations(uuid) is not the body 20261006092000 expects (md5 %)', md5(v_src);
  end if;
end
$guard$;

create or replace function public.erp_vat_obligations(p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if p_entity_id is null then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('finance.read', p_entity_id);
  end if;
  v_tenant := erp.current_tenant_id();

  return (
    -- The periods, worked out once (20261006092000, J-42).
    with obl as materialized (
      select o.* from erp.vat_obligations(p_entity_id) o
    ),
    -- The period each company finalises next takes what no return took from
    -- the registration's first day; a later one, what is dated in it.
    nxt as (
      select o.entity_id, min(o.period_end) as period_end
        from obl o
       where o.status <> 'finalised'
       group by o.entity_id
    ),
    -- Asked for every company, the reader is answered for the companies
    -- they may read the books of: asked once per company, not per period.
    readable as materialized (
      select c.entity_id
        from (select distinct o.entity_id from obl o) c
       where erp.has_permission('finance.read', c.entity_id)
    ),
    -- What erp.finalise_vat_return() and erp.vat_return_export() ask, for
    -- this reader, in the order a person would put them right; asked once
    -- per company.
    co as materialized (
      select r.entity_id,
             e.base_currency::text as currency,
             (select g.valid_from from erp.entity_tax_registration g
               where g.tenant_id = v_tenant and g.entity_id = r.entity_id
                 and upper(g.registration_type) like 'VAT%' and g.valid_from <= current_date
               order by g.valid_from desc, g.created_at desc limit 1) as first_day,
             erp.has_permission('finance.close_period', r.entity_id) as may_close,
             exists (select 1 from erp.document_type dt
                      where dt.tenant_id = v_tenant and dt.base_type_code = 'vat_return'
                        and dt.status = 'active'
                        and (dt.entity_id is null or dt.entity_id = r.entity_id)) as installed,
             erp.vat_return_policy(r.entity_id) as policy
        from readable r
        join erp.entity e on e.tenant_id = v_tenant and e.id = r.entity_id
    ),
    ob as (
      select o.*,
             coalesce(n.period_end = o.period_end, false) as is_next,
             co.currency, co.first_day, co.may_close, co.installed, co.policy
        from obl o
        join co on co.entity_id = o.entity_id
        left join nxt n on n.entity_id = o.entity_id
    ),
    asked as (
      select ob.*,
             case when ob.status = 'finalised' then null
                  when ob.is_next then ob.first_day
                  else ob.period_start end as take_from
        from ob
    ),
    -- The preview: what finalising each period now would take. There is no
    -- stored draft (D14). A company's periods are read in one pass of its
    -- entries, where each period read them again.
    preview as materialized (
      select p.entity_id, f.period_end, f.figures
        from (select a.entity_id,
                     jsonb_agg(jsonb_build_object('period_start', a.period_start,
                                                  'period_end', a.period_end,
                                                  'take_from', a.take_from)) as periods
                from asked a
               where a.status <> 'finalised'
               group by a.entity_id) p
        cross join lateral erp.vat_return_figures_for_periods(p.entity_id, p.periods) f
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
                  pv.figures - 'journal_ids'
                end
             order by s.company, s.period_end), '[]'::jsonb)
      from said s
      left join erp.document d on d.tenant_id = v_tenant and d.id = s.return_document_id
      left join preview pv on pv.entity_id = s.entity_id and pv.period_end = s.period_end);
end
$$;

comment on function public.erp_vat_obligations(uuid) is
  'The VAT periods of each company the reader may read the books of, under finance.read (20261001100000): due dates '
  'and status, a finalised period''s frozen boxes, and for the rest the boxes finalising it now would take. Each says '
  'what the doors would take from this reader (20261001300000): take_from, can_finalise with finalise_blocked_by, '
  'and can_export. The periods are worked out once, each company''s permissions and setting once, and its previews '
  'from one read of its entries (20261006092000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.vat_periods_once_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 3;
  v_cases    integer := 0;
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1         uuid := gen_random_uuid();
  v_owner    text := current_user;
  v_step     text := 'provisioning';
  v_state    text;
  rb         record;
  r          record;
  v_entity   uuid;
  v_ppq_from date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_ppq_to   date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_pq_to    date := date_trunc('quarter', current_date)::date - 1;
  v_res      jsonb;
  v_setting  text;
  v_periods  integer := 0;
  v_carried  integer := 0;
  v_fig_differ text := '';
  v_new      jsonb;
  v_ref      jsonb;
  v_new_one  jsonb;
  v_ref_one  jsonb;
  v_door_differ text := '';
  v_shapes   text := '';
  v_src      text;
begin
  begin
    -- ── A demonstration registered from the quarter before last ─────────────
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzvp' || v_tag, 'VAT Periods Suite', 'admin@demo-zzvp' || v_tag || '.test', 'VAT Periods Admin');
    insert into auth.users (id, email) values (a1, 'admin@demo-zzvp' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select e.id into v_entity from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';

    v_step := 'the last week of the quarter before last, built and its return finalised';
    v_res := erp_test.build_demo_days(v_ppq_to - 6, v_ppq_to);
    if not exists (select 1 from jsonb_array_elements_text(v_res -> 'notes') n where n like 'VAT returns finalised:%') then
      raise exception 'the builder finalised no return: %', v_res -> 'notes';
    end if;
    -- Trading dated in the finalised quarter after its return: carried forward.
    v_step := 'a week inside the finalised quarter, built after its return';
    perform erp_test.build_demo_days(v_ppq_to - 13, v_ppq_to - 7);
    v_step := 'the last week of last quarter, and this quarter''s first day';
    perform erp_test.build_demo_days(v_pq_to - 6, v_pq_to + 1);

    for v_setting in select unnest(array['quarterly', 'monthly']) loop
      v_step := format('the %s periods', v_setting);
      if v_setting = 'monthly' then
        perform erp.set_config_value('tax.vat_return', jsonb_build_object('frequency', 'monthly'),
          null, null, v_entity, null, 'the VAT periods suite');
      end if;

      -- ── 1. Each period's figures, from the one read ──────────────────────
      for r in
        select a.entity_id, a.periods, f.period_end, f.figures,
               erp.vat_return_figures(a.entity_id, (p ->> 'period_start')::date, f.period_end,
                                      (p ->> 'take_from')::date) as oracle
          from (select o ->> 'entity_id' as entity_text, (o ->> 'entity_id')::uuid as entity_id,
                       jsonb_agg(jsonb_build_object('period_start', o -> 'period_start',
                                                    'period_end', o -> 'period_end',
                                                    'take_from', o -> 'take_from')) as periods
                  from jsonb_array_elements(public.erp_vat_obligations(null)) o
                 where o ->> 'status' <> 'finalised'
                 group by 1, 2) a
          cross join lateral erp.vat_return_figures_for_periods(a.entity_id, a.periods) f
          join lateral jsonb_array_elements(a.periods) p on (p ->> 'period_end')::date = f.period_end
      loop
        v_periods := v_periods + 1;
        v_carried := v_carried + coalesce((r.figures #>> '{carried_forward,entries}')::integer, 0);
        if r.figures is distinct from r.oracle then
          v_fig_differ := v_fig_differ || format('%s %s; ', v_setting, r.period_end);
        end if;
      end loop;

      -- ── 2. The door's whole answer, signed in as its administrator ───────
      -- Read by the suite's owner, as demonstration_vat_returns_suite reads
      -- it: every part of the answer names its organisation, so the row
      -- policies would not change it, and under them the unchanged
      -- erp.vat_exceptions asks who is signed in once per row it scans.
      v_new := public.erp_vat_obligations(null);
      v_new_one := public.erp_vat_obligations(v_entity);
      v_ref := erp_test.vat_obligations_reference(null);
      v_ref_one := erp_test.vat_obligations_reference(v_entity);
      if v_new is distinct from v_ref or v_new_one is distinct from v_ref_one then
        v_door_differ := v_door_differ || v_setting || '; ';
      end if;
      v_shapes := v_shapes || format('%s: %s; ', v_setting,
        (select string_agg(format('%s %s%s', o ->> 'period_end', o ->> 'status',
                                  case when (o ->> 'is_next')::boolean then ' next' else '' end), ', '
                           order by o ->> 'period_end')
           from jsonb_array_elements(v_ref) o));
    end loop;

    v_cases := v_cases + 1;
    case_name := 'every period not finalised has, from one read of its company''s entries, the figures a return would be finalised from';
    passed := v_fig_differ = '' and v_periods >= 6 and v_carried > 0;
    detail := format('%s period(s), %s entr(ies) carried forward; differing: %s',
                     v_periods, v_carried, coalesce(nullif(v_fig_differ, ''), 'none'));
    return next;

    v_cases := v_cases + 1;
    case_name := 'the VAT periods are the same as before, for every company and for the one, quarterly and monthly';
    passed := v_door_differ = ''
          and jsonb_array_length(v_ref) >= 5
          and exists (select 1 from jsonb_array_elements(v_ref) o where o ->> 'status' = 'finalised')
          and exists (select 1 from jsonb_array_elements(v_ref) o where (o ->> 'is_next')::boolean);
    detail := format('%sdiffering: %s', v_shapes, coalesce(nullif(v_door_differ, ''), 'none'));
    return next;

    -- ── 3. The body ─────────────────────────────────────────────────────────
    v_step := 'reading the body';
    select p.prosrc into v_src from pg_catalog.pg_proc p where p.oid = 'public.erp_vat_obligations(uuid)'::regprocedure;
    v_cases := v_cases + 1;
    case_name := 'the door works the periods out once and reads each company''s entries in one call';
    passed := (length(v_src) - length(replace(v_src, 'erp.vat_obligations(', ''))) / length('erp.vat_obligations(') = 1
          and (length(v_src) - length(replace(v_src, 'erp.vat_return_figures_for_periods(', ''))) / length('erp.vat_return_figures_for_periods(') = 1
          and strpos(v_src, 'erp.vat_return_figures(') = 0
          and (length(v_src) - length(replace(v_src, 'erp.has_permission(', ''))) / length('erp.has_permission(') = 2
          and (length(v_src) - length(replace(v_src, 'erp.vat_return_policy(', ''))) / length('erp.vat_return_policy(') = 1;
    detail := format('%s characters', length(v_src));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_PERIODS_ONCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.'),
            hint = 'Read where the fixture stopped; a case that cannot run is a case that fails.';
  end if;
  if exists (select 1 from erp.tenant t where t.code = 'demo-zzvp' || v_tag)
     or exists (select 1 from auth.users u where u.id = a1) then
    raise exception 'CLOVEERP_VAT_PERIODS_ONCE_SUITE_LEAKED: the fixture was not undone'
      using hint = 'The suite must raise CLOVEERP_SUITE_UNDO inside its block so everything it made rolls back.';
  end if;
end;
$$;

revoke all on function erp_test.vat_periods_once_suite() from public, anon;

comment on function erp_test.vat_periods_once_suite() is
  'The VAT periods are read in one pass per company (20261006092000, J-42): every period not finalised has the '
  'figures erp.vat_return_figures gives it, the door answers as the body it replaced did, quarterly and monthly, and '
  'it reads the entries once per company.';

create or replace function erp_test.assert_vat_periods_once_suite()
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
    from erp_test.vat_periods_once_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_PERIODS_ONCE_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'The VAT periods would say otherwise than before, or read the entries once per period again. Read the case that failed.';
  end if;
  if v_total <> 3 then
    raise exception 'CLOVEERP_VAT_PERIODS_ONCE_SUITE_SHRANK: % case(s), expected 3', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('VAT periods once: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_periods_once_suite() from public, anon;

comment on function erp_test.assert_vat_periods_once_suite() is
  'The VAT periods are what they were, and read each company''s entries once (20261006092000).';

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
