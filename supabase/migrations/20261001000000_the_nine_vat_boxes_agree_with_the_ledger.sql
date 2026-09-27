-- PR14 M1 — the nine VAT boxes, from the posted journals, and a tax report that
-- agrees with the ledger (V1, the read side).
--
-- What was there. erp.tax_report() grouped erp.tax_determination by the
-- document's date, whatever had become of the document since, and added every
-- determination with a positive sign. So on the demonstration its output tax
-- was more than tax control had moved: each customer credit note was added
-- to the tax charged rather than taken from it, which overstates box 1 by
-- twice the note's tax, and an invoice whose posting was reversed
-- stayed on the report at its full tax. erp_ref.statutory_output declared
-- boxes 1, 4 and 5 of the gb_vat return, and nothing computed any of them:
-- the definition was read by nothing but the provenance check.
--
-- What this does.
--
--   A. erp.vat_entries(): a VAT entry is a posted journal, on a statutory
--      ledger, that a sales invoice, a customer credit note, a supplier bill
--      or a supplier credit note raised (base types invoice_reference,
--      credit_reference and return_to_supplier), or the contra journal that
--      reversed one. Each carries its side, a sign (minus for a reversal,
--      minus again for a credit or a return), its VAT date (a reversal's own
--      posting date; otherwise the tax point where the invoice has one, else
--      the posting date), the tax the ledger carried on tax control in the
--      direction its side uses, the tax its determinations say signed the
--      same way, and its net, signed.
--   B. erp.vat_return_boxes(): the nine boxes per company and period. Boxes 1
--      and 4 are the ledger's (D1), so box 1 less box 4 is what tax control
--      moved on those journals by construction. Boxes 6 and 7 are the nets,
--      sales outside the scope left out of box 6 and every purchase in box 7
--      (D5), in whole pounds with the pence dropped. Boxes 2, 8 and 9 are
--      nought: they are Northern Ireland's, and the product records no
--      movement of goods with the EU. Box 5 is the difference, never
--      negative, with whether it is payable or repayable beside it.
--   C. erp.vat_exceptions(): what a person checks before filing. Four block:
--      an entry whose side cannot be told, one not in the company's own
--      currency, one whose determinations and ledger disagree, and tax
--      control moved by a journal a document raised that is not an entry.
--      A journal naming no document (a manual journal, a payment to HMRC) is
--      listed for information, and two things are flagged: a purchase from
--      abroad with no tax stated (reverse charge is not built) and an exempt
--      supply (partial exemption is not computed).
--   D. erp.tax_report() rebuilt over the same entries, signature and columns
--      unchanged (D2): credit notes and reversals subtract, the period is the
--      VAT date, and only what posted is on it. A posted entry with no
--      determination appears with no code, so the bills in box 7 are visible.
--   E. public.erp_tax_report() authorises finance.read (D11), as
--      erp_trial_balance does; it was the one finance report any seat could
--      read. public.erp_vat_boxes() is the boxes' door, under the same
--      permission, api-only until the VAT screen (M4).
--   F. erp.assert_vat_agrees_with_ledger(): every organisation's blocking
--      exceptions are empty, run for every organisation by the whole-database
--      reconciliation.
--   G. gb_vat v1's vat_return restated in place with its nine boxes (D3).
--   H. The four suites that read tax_report re-pinned where they read a
--      document that never posted, and erp_test.vat_return_suite.
--
-- Found on the way, for the PR description: posting refuses a document in any
-- currency but its ledger's (CLOVEERP_NO_TRANSLATION), so the non-sterling
-- exception can only be met by a ledger kept in another currency than its
-- company's; and a door that authorises is volatile with an allow-list row, so
-- erp_vat_boxes is not the stable read the plan described.

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The entries
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.vat_entries(p_entity_id uuid default null,
                                           p_from date default null,
                                           p_to date default null)
returns table(journal_id uuid, journal_number text, entity_id uuid,
              document_id uuid, document_number text, type_code text, base_type_code text,
              party_id uuid, side text, is_reversal boolean, sign integer,
              vat_date date, posted_at timestamptz,
              tax_minor bigint, determined boolean, determined_tax_minor bigint,
              net_minor bigint, currency char(3), in_base_currency boolean)
language sql
stable
set search_path = ''
as $$
  -- One row per journal, not per document: a reversed invoice is two entries,
  -- its own on its own date and the contra journal on the reversal's, so the
  -- return a reversal lands in is the one that takes it back. Only
  -- document.* journals count, because those are the ones erp.post_document_finance()
  -- and erp.reverse_document_posting() write; a cash journal naming an invoice
  -- would carry no tax and be read here as a disagreement of its whole tax.
  with t as (select erp.require_tenant_id() as tenant_id),
  j as (
    select j.tenant_id, j.id, j.journal_number, j.entity_id, j.document_id,
           d.document_number, dt.code as type_code, dt.base_type_code, d.party_id,
           j.reverses_journal_id is not null as is_reversal,
           ((case when j.reverses_journal_id is not null then -1 else 1 end)
            * (case when dt.base_type_code in ('credit_reference', 'return_to_supplier')
                    then -1 else 1 end))::integer as sign,
           case when j.reverses_journal_id is not null then j.posting_date
                else coalesce(d.tax_point, j.posting_date) end as vat_date,
           j.posted_at,
           coalesce(d.currency, l.currency)::char(3) as currency,
           (coalesce(d.currency, l.currency) = e.base_currency
            and l.currency = e.base_currency) as in_base_currency
      from t
      join erp.journal j
        on j.tenant_id = t.tenant_id and j.status = 'posted' and j.document_id is not null
      join erp.ledger l
        on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
      join erp.entity e
        on e.tenant_id = j.tenant_id and e.id = j.entity_id
      join erp.document d
        on d.tenant_id = j.tenant_id and d.id = j.document_id
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where dt.base_type_code in ('invoice_reference', 'credit_reference', 'return_to_supplier')
       and j.source_code like 'document.%'
       and (p_entity_id is null or j.entity_id = p_entity_id)
  ),
  dated as (
    select * from j
     where (p_from is null or j.vat_date >= p_from)
       and (p_to is null or j.vat_date <= p_to)
  )
  select x.id, x.journal_number, x.entity_id, x.document_id, x.document_number,
         x.type_code, x.base_type_code, x.party_id, s.side, x.is_reversal, x.sign,
         x.vat_date, x.posted_at,
         -- The ledger's figure, in the company's currency. A credit to tax
         -- control is tax charged and a debit tax suffered, so a sale reads
         -- credit less debit and a purchase debit less credit; a credit note
         -- or a reversal then comes out negative of itself.
         coalesce((select sum(case when s.side = 'purchase'
                                   then jl.base_debit_minor - jl.base_credit_minor
                                   else jl.base_credit_minor - jl.base_debit_minor end)
                     from erp.journal_line jl
                     join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
                    where jl.tenant_id = x.tenant_id and jl.journal_id = x.id
                      and a.control_kind = 'tax'), 0)::bigint,
         dd.determined,
         (x.sign * dd.tax_minor)::bigint,
         -- The net: what the determinations call taxable, a sale outside the
         -- scope left out, and a line nothing determined at its own net.
         (x.sign * (dd.net_minor + ln.net_minor))::bigint,
         x.currency, x.in_base_currency
    from dated x
   cross join lateral (select erp.document_trade_side(x.document_id) as side) s
   cross join lateral (
     select count(*) > 0 as determined,
            coalesce(sum(td.tax_minor), 0) as tax_minor,
            coalesce(sum(td.taxable_minor)
                       filter (where s.side <> 'sale'
                                  or td.treatment is distinct from 'outside_scope'), 0) as net_minor
       from erp.tax_determination td
      where td.tenant_id = x.tenant_id and td.document_id = x.document_id) dd
   cross join lateral (
     select coalesce(sum(dl.net_minor), 0) as net_minor
       from erp.document_line dl
      where dl.tenant_id = x.tenant_id and dl.document_id = x.document_id
        and not coalesce(dl.is_cancelled, false)
        and not exists (select 1 from erp.tax_determination td
                         where td.tenant_id = dl.tenant_id and td.document_line_id = dl.id)) ln
$$;

revoke all on function erp.vat_entries(uuid, date, date) from public, anon;

comment on function erp.vat_entries(uuid, date, date) is
  'The VAT entries of a company and period (20261001000000): every posted statutory journal a sales '
  'invoice, credit note, supplier bill or supplier credit note raised, and every reversal of one, with '
  'its side, sign, VAT date, the tax the ledger carried, the tax its determinations say and its net. '
  'The one reading the nine boxes and the tax report both take.';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. The nine boxes
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.vat_return_boxes(p_entity_id uuid default null,
                                                p_from date default null,
                                                p_to date default null)
returns table(entity_id uuid, company text, period_from date, period_to date,
              box1_minor bigint, box2_minor bigint, box3_minor bigint, box4_minor bigint,
              box5_minor bigint, box5_is text,
              box6_pounds bigint, box7_pounds bigint, box8_pounds bigint, box9_pounds bigint,
              entries bigint, unknown_side bigint, not_in_base_currency bigint,
              ledger_disagreements bigint)
language sql
stable
set search_path = ''
as $$
  -- One row per company: every active company when none is named. Boxes 1
  -- to 5 are in pence, as HMRC takes them; 6 to 9 in whole pounds with the
  -- pence dropped (VAT Notice 700/12 §4), towards nought.
  with t as (select erp.require_tenant_id() as tenant_id),
  co as (
    select e.id, e.code
      from t join erp.entity e on e.tenant_id = t.tenant_id
     where (p_entity_id is null and e.status = 'active') or e.id = p_entity_id
  ),
  x as (select * from erp.vat_entries(p_entity_id, p_from, p_to)),
  b as (
    select co.id, co.code,
           coalesce(sum(x.tax_minor) filter (where x.side = 'sale'), 0)::bigint     as box1,
           coalesce(sum(x.tax_minor) filter (where x.side = 'purchase'), 0)::bigint as box4,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'sale'), 0) / 100.0)::bigint     as box6,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'purchase'), 0) / 100.0)::bigint as box7,
           count(x.journal_id)                                                    as entries,
           count(x.journal_id) filter (where x.side not in ('sale', 'purchase'))  as unknown_side,
           count(x.journal_id) filter (where not x.in_base_currency)              as not_in_base,
           count(x.journal_id) filter (where x.determined_tax_minor <> x.tax_minor) as disagreements
      from co left join x on x.entity_id = co.id
     group by co.id, co.code
  )
  select b.id, b.code, p_from, p_to,
         b.box1, 0::bigint, b.box1 + 0, b.box4,
         abs(b.box1 + 0 - b.box4),
         case when b.box1 + 0 >= b.box4 then 'payable' else 'repayable' end,
         b.box6, b.box7, 0::bigint, 0::bigint,
         b.entries, b.unknown_side, b.not_in_base, b.disagreements
    from b
   order by b.code
$$;

revoke all on function erp.vat_return_boxes(uuid, date, date) from public, anon;

comment on function erp.vat_return_boxes(uuid, date, date) is
  'The nine boxes of the VAT return (form VAT 100) per company and period (20261001000000). Boxes 1 and 4 '
  'are the tax control lines of the period''s VAT entries, so box 1 less box 4 is what the ledger moved; '
  '6 and 7 the entries'' nets in whole pounds, sales outside the scope left out; 2, 8 and 9 nought, being '
  'Northern Ireland''s; 5 the difference, never negative, with box5_is saying payable or repayable.';

-- ═════════════════════════════════════════════════════════════════════════════
-- C. What a person checks before filing
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.vat_exceptions(p_entity_id uuid default null,
                                              p_from date default null,
                                              p_to date default null)
returns table(entity_id uuid, finding text, blocks boolean, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  x as (select * from erp.vat_entries(p_entity_id, p_from, p_to)),
  -- Tax control moved by a posted statutory journal that is not an entry, in
  -- the period by its posting date.
  other as (
    select j.id, j.entity_id, j.journal_number, j.source_code, j.document_id,
           j.reverses_journal_id, d.document_number,
           sum(jl.base_credit_minor - jl.base_debit_minor)::bigint as moved_minor
      from t
      join erp.journal j on j.tenant_id = t.tenant_id and j.status = 'posted'
      join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id and a.control_kind = 'tax'
      left join erp.document d on d.tenant_id = j.tenant_id and d.id = j.document_id
      left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where (p_entity_id is null or j.entity_id = p_entity_id)
       and (p_from is null or j.posting_date >= p_from)
       and (p_to is null or j.posting_date <= p_to)
       and not (j.document_id is not null
                and j.source_code like 'document.%'
                and dt.base_type_code in ('invoice_reference', 'credit_reference', 'return_to_supplier'))
     group by j.id, j.entity_id, j.journal_number, j.source_code, j.document_id,
              j.reverses_journal_id, d.document_number
  )
  -- (a) Blocks: neither box 1 nor box 4 can take it.
  select x.entity_id, 'the product cannot tell whether this is a sale or a purchase', true,
         x.document_number,
         format('%s is raised against a party that both buys and sells and names neither role, so its %s of tax is in neither box 1 nor box 4',
                x.document_number, x.tax_minor)
    from x where x.side not in ('sale', 'purchase')
  union all
  -- (b) Blocks: a return is in sterling (VAT Notice 700 §7.5).
  select x.entity_id, 'an entry is not in the company''s own currency', true,
         x.document_number,
         format('%s is in %s on journal %s; a return is made in the company''s own currency',
                x.document_number, x.currency, coalesce(x.journal_number, x.journal_id::text))
    from x where not x.in_base_currency
  union all
  -- (c) Blocks: the gate. The return and the ledger are two accounts of one tax.
  select x.entity_id, 'the tax determined is not the tax the ledger carries', true,
         x.document_number,
         format('%s determined %s and journal %s moved tax control by %s',
                x.document_number, x.determined_tax_minor,
                coalesce(x.journal_number, x.journal_id::text), x.tax_minor)
    from x where x.determined_tax_minor <> x.tax_minor
  union all
  -- (d) Blocks where a document raised it or it reverses one that did; a
  --     journal naming no document is listed for information.
  select o.entity_id,
         case when o.document_id is not null
                or exists (select 1 from t join erp.journal r on r.tenant_id = t.tenant_id
                            where r.id = o.reverses_journal_id and r.document_id is not null)
              then 'tax control was moved by a journal that is not a VAT entry'
              else 'tax control was moved by a journal that names no document' end,
         o.document_id is not null
           or exists (select 1 from t join erp.journal r on r.tenant_id = t.tenant_id
                       where r.id = o.reverses_journal_id and r.document_id is not null),
         coalesce(o.journal_number, o.id::text),
         format('journal %s (%s%s) moved tax control by %s; it is in no box',
                coalesce(o.journal_number, o.id::text), o.source_code,
                coalesce(', ' || o.document_number, ''), o.moved_minor)
    from other o
  union all
  -- (e) Flag: reverse charge is not built.
  select x.entity_id, 'a purchase from abroad states no tax, and may need the reverse charge', false,
         x.document_number,
         format('%s is from a supplier in %s; the reverse charge is not computed, so nothing of it is in box 1 or box 4',
                x.document_number, p.country_code)
    from t
    join x on true
    join erp.party p on p.tenant_id = t.tenant_id and p.id = x.party_id
    join erp.entity e on e.tenant_id = t.tenant_id and e.id = x.entity_id
   where x.side = 'purchase' and x.determined_tax_minor = 0 and x.tax_minor = 0
     and p.country_code is not null and e.country_code is not null
     and p.country_code <> e.country_code
  union all
  -- (f) Flag: partial exemption is not computed, and box 4 claims all input tax.
  select x.entity_id, 'an exempt supply is in the period, and box 4 claims all input tax', false,
         x.document_number,
         format('%s carries %s of exempt supplies; partial exemption is not computed',
                x.document_number, x.sign * sum(td.taxable_minor))
    from t
    join x on true
    join erp.tax_determination td
      on td.tenant_id = t.tenant_id and td.document_id = x.document_id and td.treatment = 'exempt'
   where x.side = 'sale'
   group by x.entity_id, x.document_number, x.sign, x.journal_id
$$;

revoke all on function erp.vat_exceptions(uuid, date, date) from public, anon;

comment on function erp.vat_exceptions(uuid, date, date) is
  'What a person checks before filing a VAT return (20261001000000). Blocking: an entry whose side cannot '
  'be told, one not in the company''s currency, one whose determinations and ledger disagree, and tax '
  'control moved by a journal a document raised that is not an entry. For information: tax control moved '
  'by a journal naming no document. Flagged: a purchase from abroad stating no tax, and an exempt supply.';

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The tax report, over the same entries
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.tax_report(p_from date, p_to date, p_entity_id uuid default null)
returns table(direction text, jurisdiction text, treatment text, tax_code text, rate_pct numeric,
              taxable_minor bigint, tax_minor bigint, currency character, transactions bigint)
language sql
stable
set search_path = ''
as $$
  -- By jurisdiction and code, because that is the shape of every return; by
  -- direction, because tax charged and tax suffered are different boxes; and
  -- by treatment, because zero-rated, exempt and outside the scope all carry
  -- no tax and go in different places.
  --
  -- Over the VAT entries (20261001000000), so what posted is on it and
  -- nothing else, on its VAT date, signed: a credit note takes back what its
  -- invoice charged, and a reversal takes back its journal on its own date.
  -- Its output tax is box 1 and its input tax box 4 wherever the
  -- determinations and the ledger agree, which erp.vat_exceptions() says.
  -- An entry nothing determined, a bill with no tax stated, is a row of its
  -- own with no code, at its net and the tax its journal carried.
  with x as (select * from erp.vat_entries(p_entity_id, p_from, p_to)),
  r as (
    select x.side, td.jurisdiction, td.treatment, td.tax_code, td.rate_pct,
           x.sign * td.taxable_minor as taxable_minor, x.sign * td.tax_minor as tax_minor,
           td.currency
      from x
      join erp.tax_determination td
        on td.tenant_id = erp.current_tenant_id() and td.document_id = x.document_id
    union all
    select x.side, null, null, null, null, x.net_minor, x.tax_minor, x.currency
      from x where not x.determined
  )
  select case r.side when 'sale' then 'output' when 'purchase' then 'input' else 'unknown' end,
         r.jurisdiction, r.treatment, r.tax_code, r.rate_pct,
         sum(r.taxable_minor)::bigint, sum(r.tax_minor)::bigint, r.currency, count(*)
    from r
   group by 1, r.jurisdiction, r.treatment, r.tax_code, r.rate_pct, r.currency
   order by 1, 2, 3, 5 desc
$$;

revoke all on function erp.tax_report(date, date, uuid) from public, anon;

comment on function erp.tax_report(date, date, uuid) is
  'Tax by direction, jurisdiction, treatment, code and rate over the VAT entries of the period '
  '(20261001000000): posted documents only, on their VAT date, credit notes and reversals subtracting. '
  'Its output tax is box 1 and its input tax box 4 where erp.vat_exceptions() finds no disagreement.';

-- ═════════════════════════════════════════════════════════════════════════════
-- E. The doors, under finance.read
-- ═════════════════════════════════════════════════════════════════════════════

-- The report every seat of an organisation could read, the one finance report
-- that asked nobody (D11). Volatile, as a door that authorises is: PostgREST
-- opens a read-only transaction for a stable one, and erp.authorise() writes
-- its access-log row.
create or replace function public.erp_tax_report(p_from date, p_to date)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('finance.read');
  return (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
            from erp.tax_report(p_from, p_to) t);
end
$$;

revoke all on function public.erp_tax_report(date, date) from public, anon;
grant execute on function public.erp_tax_report(date, date) to authenticated, service_role;

comment on function public.erp_tax_report(date, date) is
  'The Tax report on the Finance screen, under finance.read (20261001000000): signed, posted documents '
  'only, on their VAT date.';

create or replace function public.erp_vat_boxes(p_from date, p_to date, p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  if p_entity_id is null then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('finance.read', p_entity_id);
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(b)
             || jsonb_build_object('exceptions',
                  (select coalesce(jsonb_agg(to_jsonb(x) - 'entity_id'
                                             order by x.blocks desc, x.finding, x.reference), '[]'::jsonb)
                     from erp.vat_exceptions(b.entity_id, p_from, p_to) x))
             order by b.company), '[]'::jsonb)
      from erp.vat_return_boxes(p_entity_id, p_from, p_to) b
     -- Asked for every company, the reader is answered for the companies they
     -- may read the books of, and not for one they may not.
     where erp.has_permission('finance.read', b.entity_id));
end
$$;

revoke all on function public.erp_vat_boxes(date, date, uuid) from public, anon;
grant execute on function public.erp_vat_boxes(date, date, uuid) to authenticated, service_role;

comment on function public.erp_vat_boxes(date, date, uuid) is
  'The nine VAT boxes per company for a period, with what to check before filing, under finance.read '
  '(20261001000000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_tax_report', 'erp.authorise',
   'Reads the tax report under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_vat_boxes', 'erp.authorise',
   'Reads the nine VAT boxes and their exceptions under finance.read. Writes only the access-log row erp.authorise() raises.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_vat_boxes', 'pending_screen', '/finance/vat',
   'The nine VAT boxes of a period with the exceptions to check before filing. The VAT returns screen '
   'that shows them beside each obligation, and finalises and exports a return, is PR14 M4.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- ═════════════════════════════════════════════════════════════════════════════
-- F. The return and the ledger agree
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_vat_agrees_with_ledger()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n        integer;
  v_entries  integer;
  v_findings text;
begin
  select count(*), string_agg(format('  %s [%s] %s', x.finding, x.reference, x.detail), E'\n'
                              order by x.finding, x.reference)
    into v_n, v_findings
    from erp.vat_exceptions(null, null, null) x
   where x.blocks;
  if v_n > 0 then
    raise exception E'CLOVEERP_VAT_DISAGREES_WITH_LEDGER: % finding(s)\n%', v_n, v_findings
      using errcode = '23514',
            hint = 'Open the document each finding names. A disagreement is tax determined on it that its journal did not carry, or the other way round: reverse the posting and post it again, or state the tax before it posts. A journal that is not a VAT entry moved tax control: reverse it and post the tax through the document.';
  end if;
  select count(*) into v_entries from erp.vat_entries(null, null, null);
  return format('vat: %s entr(y/ies), every one in the ledger as the return reads it', v_entries);
end;
$$;

revoke all on function erp.assert_vat_agrees_with_ledger() from public, anon;

comment on function erp.assert_vat_agrees_with_ledger() is
  'Every VAT entry of the organisation agrees with the ledger, and nothing a document raised moves tax '
  'control outside one (20261001000000). Run for every organisation by the whole-database reconciliation.';

-- CLOVEERP_VAT_DISAGREES_WITH_LEDGER is raised only by an assert_ routine and so
-- is not registered in erp_ref.refusal, as 20260920200000 explains; its next
-- action travels as the hint.

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('vat_agrees_with_ledger', 'The VAT return agrees with the ledger', 'assertion', 'tenant', 'erp',
   'assert_vat_agrees_with_ledger', '', 'vat_exceptions', '',
   'Boxes 1 and 4 are the tax control lines of the posted invoices, credit notes and bills, and the tax '
   'report the determinations on them. Every entry''s determinations equal what its journal carried, '
   'every entry says whether it is a sale or a purchase and is in the company''s currency, and nothing a '
   'document raised moves tax control outside an entry.',
   true, 114)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- G. gb_vat v1's return, with its nine boxes (D3)
-- ═════════════════════════════════════════════════════════════════════════════

-- In place: nothing reads the definition but the provenance check, no
-- organisation's figure moves, and a v2 pack would copy every rule, parameter
-- and conformance case to rebind entities for a declaration.
do $gb_vat$
declare
  v_n integer;
begin
  update erp_ref.statutory_output
     set definition = jsonb_build_object(
           'computed_by', 'erp.vat_return_boxes',
           'sections', jsonb_build_array(
             jsonb_build_object('box', '1', 'source', 'box1_minor', 'unit', 'minor', 'label_key', 'output.gb_vat.box1'),
             jsonb_build_object('box', '2', 'source', 'box2_minor', 'unit', 'minor', 'label_key', 'output.gb_vat.box2'),
             jsonb_build_object('box', '3', 'source', 'box3_minor', 'unit', 'minor', 'label_key', 'output.gb_vat.box3'),
             jsonb_build_object('box', '4', 'source', 'box4_minor', 'unit', 'minor', 'label_key', 'output.gb_vat.box4'),
             jsonb_build_object('box', '5', 'source', 'box5_minor', 'unit', 'minor', 'label_key', 'output.gb_vat.box5'),
             jsonb_build_object('box', '6', 'source', 'box6_pounds', 'unit', 'pounds', 'label_key', 'output.gb_vat.box6'),
             jsonb_build_object('box', '7', 'source', 'box7_pounds', 'unit', 'pounds', 'label_key', 'output.gb_vat.box7'),
             jsonb_build_object('box', '8', 'source', 'box8_pounds', 'unit', 'pounds', 'label_key', 'output.gb_vat.box8'),
             jsonb_build_object('box', '9', 'source', 'box9_pounds', 'unit', 'pounds', 'label_key', 'output.gb_vat.box9'))),
         description = 'The VAT Return (form VAT 100), all nine boxes, computed by erp.vat_return_boxes() from '
                       'the posted journals: boxes 1 and 4 from tax control, 6 and 7 from the nets in whole '
                       'pounds, 2, 8 and 9 nought outside Northern Ireland, and 5 the difference.'
   where pack_code = 'gb_vat' and pack_version = 1 and code = 'vat_return';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: gb_vat v1 vat_return found % time(s)', v_n;
  end if;
end
$gb_vat$;

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('output.gb_vat.box2', 'en', 'Box 2: VAT due on acquisitions from the EU (Northern Ireland)', null, null),
  ('output.gb_vat.box3', 'en', 'Box 3: total VAT due', null, null),
  ('output.gb_vat.box6', 'en', 'Box 6: total value of sales, excluding VAT', null, null),
  ('output.gb_vat.box7', 'en', 'Box 7: total value of purchases, excluding VAT', null, null),
  ('output.gb_vat.box8', 'en', 'Box 8: goods supplied to the EU, excluding VAT (Northern Ireland)', null, null),
  ('output.gb_vat.box9', 'en', 'Box 9: goods acquired from the EU, excluding VAT (Northern Ireland)', null, null),
  ('output.gb_vat.box2', 'de', 'Feld 2: Umsatzsteuer auf Erwerbe aus der EU (Nordirland)', null, null),
  ('output.gb_vat.box3', 'de', 'Feld 3: Umsatzsteuer insgesamt', null, null),
  ('output.gb_vat.box6', 'de', 'Feld 6: Umsätze insgesamt, ohne Umsatzsteuer', null, null),
  ('output.gb_vat.box7', 'de', 'Feld 7: Einkäufe insgesamt, ohne Umsatzsteuer', null, null),
  ('output.gb_vat.box8', 'de', 'Feld 8: Lieferungen in die EU, ohne Umsatzsteuer (Nordirland)', null, null),
  ('output.gb_vat.box9', 'de', 'Feld 9: Erwerbe aus der EU, ohne Umsatzsteuer (Nordirland)', null, null)
on conflict (key, locale) do update set value = excluded.value;

-- ═════════════════════════════════════════════════════════════════════════════
-- H. The proof
-- ═════════════════════════════════════════════════════════════════════════════

-- H1. erp_test.zero_rated_supply_suite, re-pinned on purpose. Cases 8 and 9
--     read the tax report over two invoices that were determined line by line
--     and never issued. The report reads what posted now, so the two are
--     issued before it is read; the cases ask what they always asked. The
--     other three suites that read the report (invoice_tax_suite cases 4 and
--     8, supplier_tax_suite case 5, finance_depth_suite's "the tax lands on
--     the line and in the return") read documents they had issued or
--     registered, and read the same figures from the rebuilt report.

do $zero_rated$
declare
  v_sig constant text := 'erp_test.zero_rated_supply_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_anchor constant text := $o$    -- ── 8. Three zeroes, three rows on the return ─────────────────────────
$o$;
  v_new constant text := $n$    -- The return reads what posted, on the date it posted (20261001000000),
    -- and these two invoices were determined and never issued. Issued here,
    -- so the report is read the way a return is.
    v_step := 'issuing both invoices, because the return reads what posted';
    for r in select d.id from erp.document d
              where d.tenant_id = rb.tenant_id
                and (d.their_reference in ('ZV-HOME', 'ZV-AWAY') or d.our_reference in ('ZV-HOME', 'ZV-AWAY'))
              order by d.created_at, d.id
    loop
      perform erp.transition_document(r.id, 'issue', 'zero rated supply suite');
    end loop;

    -- ── 8. Three zeroes, three rows on the return ─────────────────────────
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'because the return reads what posted') > 0 then
    raise notice '% already issues its invoices before reading the return; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_anchor, v_new);
end
$zero_rated$;

-- H1b. erp_test.trial_balance_tie_suite and erp_test.ageing_tie_suite, re-pinned
--      on purpose. Each counts the per-organisation assertions the whole-database
--      reconciliation loops over, and there are thirteen now: the VAT return's
--      agreement with the ledger is one.

do $tie_suites$
declare
  v_sig    text;
  v_def    text;
  v_anchor constant text := $o$and d.function_name <> 'assert_whole_database_reconciles') = 12$o$;
  v_new    constant text := $n$and d.function_name <> 'assert_whole_database_reconciles') = 13 /* thirteen since 20261001000000: the VAT return agrees with the ledger */$n$;
  v_hits   integer;
begin
  foreach v_sig in array array['erp_test.trial_balance_tie_suite()', 'erp_test.ageing_tie_suite()'] loop
    v_def := pg_get_functiondef(v_sig::regprocedure);
    if strpos(v_def, 'thirteen since 20261001000000') > 0 then
      raise notice '% already counts thirteen; left as it is', v_sig;
      continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found % time(s)', v_sig, v_hits;
    end if;
    execute replace(v_def, v_anchor, v_new);
  end loop;
end
$tie_suites$;

-- H2. erp_test.vat_return_suite

create or replace function erp_test.vat_return_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 16;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  s_ware   uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  res      jsonb;
  b0 record; b1 record; b2 record; bq record;
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_uom uuid;
  v_zero uuid; v_exempt uuid; v_out uuid;
  v_supplier uuid; v_cust uuid;
  v_po uuid; v_pol uuid; v_pol2 uuid; v_grn uuid; v_grn2 uuid; v_bill uuid; v_bill2 uuid;
  v_so uuid; v_sol uuid; v_dn uuid; v_inv uuid; v_invline uuid; v_cn uuid;
  v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_inv5 uuid;
  v_tax_acct uuid; v_cost_acct uuid; v_ledger uuid; v_journal uuid;
  v_today  date := current_date;
  v_wide_from date := current_date - 400;
  v_q_from date := date_trunc('quarter', current_date)::date;
  v_pq_to  date := (date_trunc('quarter', current_date)::date - 1);
  v_pq_from date := (date_trunc('quarter', current_date)::date - interval '3 months')::date;
  v_n integer; v_m integer; v_x bigint; v_y bigint; v_z bigint;
  v_ok boolean; v_msg text; v_msg2 text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is, with a reader and a warehouse seat';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvr-' || v_tag, 'VAT Return Suite',
      'admin@zzvr-' || v_tag || '.test', 'VAT Return Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzvr-' || v_tag || '.test'),
           (s_ware, 'ware@zzvr-' || v_tag || '.test'),
           (s_read, 'reader@zzvr-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    res := public.erp_invite_principal('ware@zzvr-' || v_tag || '.test', 'Wes Warehouse');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'warehouse', null, null, 'moves the stock');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzvr-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, site, products, a supplier and a customer of its own';
    select l.entity_id, l.currency, l.id into v_entity, v_ccy, v_ledger
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id order by s.code limit 1;
    select i.id, i.stock_uom_id into v_item, v_uom from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    select p.id into v_supplier from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
       and pr.role_kind = 'supplier' and pr.status = 'active'
     where p.tenant_id = rb.tenant_id and p.country_code = 'GB' order by p.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZVRCUST', 'VAT return suite customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.item (tenant_id, code, name, item_class, tax_class, stock_uom_id, lifecycle, status)
    values (rb.tenant_id, 'ZZVR-ZERO',    'A loaf of bread',           'finished_good', 'zero_rated',    v_uom, 'active', 'active'),
           (rb.tenant_id, 'ZZVR-EXEMPT',  'A letting',                 'finished_good', 'exempt',        v_uom, 'active', 'active'),
           (rb.tenant_id, 'ZZVR-OUTSIDE', 'A grant that buys nothing', 'finished_good', 'outside_scope', v_uom, 'active', 'active');
    select i.id into v_zero   from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZZVR-ZERO';
    select i.id into v_exempt from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZZVR-EXEMPT';
    select i.id into v_out    from erp.item i where i.tenant_id = rb.tenant_id and i.code = 'ZZVR-OUTSIDE';

    v_step := 'an order for a hundred and fifty, and a receipt of a hundred';
    v_po := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'billed with the supplier''s VAT');
    v_pol2 := erp.add_document_line(v_po, v_item, 50, 1000, 'billed with none');
    perform erp.transition_document(v_po, 'submit', 'vat return suite');
    perform erp_test.approve_document(v_po, 'vat return suite');
    perform erp.transition_document(v_po, 'send', 'vat return suite');
    v_grn := erp.open_document('goods_receipt', v_supplier, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', 'vat return suite');

    -- ── 1. The §10 gate, on the one-button bill route ───────────────────────
    v_step := 'the receipt billed with one press, stating the supplier''s VAT';
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_bill := erp.bill_from_receipt(v_grn, 'ZZVR-SUP-1', v_today, v_today + 30, true, 20000, 'S');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0) into v_x
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_bill and a.control_kind = 'tax';
    -- And the ledger: what tax control moved over the window is box 1 less box 4.
    select coalesce(sum(jl.base_credit_minor - jl.base_debit_minor), 0) into v_y
      from erp.journal j
      join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.entity_id = v_entity and j.status = 'posted'
       and j.posting_date between v_wide_from and v_today and a.control_kind = 'tax';
    select count(*) into v_n from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks;
    v_cases := v_cases + 1;
    case_name := 'the one-button bill puts the supplier''s VAT in box 4, the ledger carries the same figure, and the VAT report and the ledger agree';
    passed := v_state is null
          and b1.box4_minor - b0.box4_minor = 20000
          and v_x = 20000
          and b1.box1_minor - b1.box4_minor = v_y
          and b1.ledger_disagreements = 0
          and exists (select 1 from erp.vat_entries(v_entity, v_wide_from, v_today) e
                       where e.document_id = v_bill and e.side = 'purchase'
                         and e.tax_minor = 20000 and e.determined_tax_minor = 20000)
          and v_n = 0;
    detail := coalesce(v_state, format('box 4 moved %s, tax control debited %s; box 1 less box 4 is %s and tax control moved %s; %s blocking finding(s)',
                                       b1.box4_minor - b0.box4_minor, v_x, b1.box1_minor - b1.box4_minor, v_y, v_n));
    return next;

    -- ── 2. A standard-rated sale ────────────────────────────────────────────
    v_step := 'ten sold at a hundred pounds each, delivered and invoiced';
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    v_sol := erp.add_document_line(v_so, v_item, 10, 10000, 'ten at a hundred pounds');
    perform erp.transition_document(v_so, 'submit', 'vat return suite');
    perform erp_test.approve_document(v_so, 'vat return suite');
    v_dn := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'vat return suite');
    v_inv := erp.invoice_from_delivery(v_dn, true);
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    perform erp.transition_document(v_inv, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'a standard-rated invoice of a thousand pounds puts two hundred in box 1 and a thousand in box 6';
    passed := v_state is null
          and b1.box1_minor - b0.box1_minor = 20000
          and b1.box6_pounds - b0.box6_pounds = 1000;
    detail := coalesce(v_state, format('box 1 moved %s, box 6 moved %s', b1.box1_minor - b0.box1_minor,
                                       b1.box6_pounds - b0.box6_pounds));
    return next;

    -- ── 3. A credit note for half of it subtracts ───────────────────────────
    -- S1 pinned: the report added a credit note's tax to what was charged.
    v_step := 'a credit note for five of the ten';
    select l.id into v_invline from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_inv and not coalesce(l.is_cancelled, false)
     order by l.line_no limit 1;
    v_cn := erp.raise_customer_credit_note(v_inv, 'damaged', 'five crushed in transit',
                                           jsonb_build_array(jsonb_build_object('line_id', v_invline, 'quantity', 5)));
    perform erp.transition_document(v_cn, 'issue', 'vat return suite');
    select * into b2 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0) into v_x
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_cn and a.control_kind = 'tax';
    v_cases := v_cases + 1;
    case_name := 'a credit note for half the invoice takes half its tax out of box 1 and half its net out of box 6, as the ledger does';
    passed := v_state is null
          and b2.box1_minor - b0.box1_minor = 10000
          and b2.box6_pounds - b0.box6_pounds = 500
          and v_x = 10000
          and b2.ledger_disagreements = 0
          and (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_wide_from, v_today, v_entity) t
                where t.direction = 'output') = b2.box1_minor;
    detail := coalesce(v_state, format('box 1 moved %s over the invoice and its credit note, box 6 %s; tax control debited %s for the credit note; the report says %s of output against box 1''s %s',
                                       b2.box1_minor - b0.box1_minor, b2.box6_pounds - b0.box6_pounds, v_x,
                                       (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_wide_from, v_today, v_entity) t
                                         where t.direction = 'output'), b2.box1_minor));
    return next;

    -- ── 4. A reversed posting leaves on the reversal's own date ─────────────
    -- S2 pinned: a reversed invoice stayed on the report at its whole tax.
    v_step := 'an invoice with yesterday''s tax point, its posting reversed today';
    v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVR-REVERSED', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 50000, 'reversed later');
    perform erp.set_invoice_tax_point(v_inv2, v_today - 1);
    select * into b0 from erp.vat_return_boxes(v_entity, v_today - 1, v_today - 1);
    select * into bq from erp.vat_return_boxes(v_entity, v_today, v_today);
    perform erp.transition_document(v_inv2, 'issue', 'vat return suite');
    perform erp.reverse_document_posting(v_inv2, 'vat return suite: raised in error', v_today);
    select * into b1 from erp.vat_return_boxes(v_entity, v_today - 1, v_today - 1);
    select * into b2 from erp.vat_return_boxes(v_entity, v_today, v_today);
    v_cases := v_cases + 1;
    case_name := 'an invoice''s posting reversed takes its tax out of box 1 on the day of the reversal, and the tax report takes it out with it';
    passed := v_state is null
          and b1.box1_minor - b0.box1_minor = 10000
          and b2.box1_minor - bq.box1_minor = -10000
          and b2.box6_pounds - bq.box6_pounds = -500
          and b2.ledger_disagreements = 0
          and (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_today, v_today, v_entity) t
                where t.direction = 'output') = b2.box1_minor
          and (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_today - 1, v_today, v_entity) t
                where t.direction = 'output')
              = (select r.box1_minor from erp.vat_return_boxes(v_entity, v_today - 1, v_today) r);
    detail := coalesce(v_state, format('box 1 on its tax point moved %s, on the reversal''s day %s, box 6 that day %s; the report says %s of output today against box 1''s %s',
                                       b1.box1_minor - b0.box1_minor, b2.box1_minor - bq.box1_minor,
                                       b2.box6_pounds - bq.box6_pounds,
                                       (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_today, v_today, v_entity) t
                                         where t.direction = 'output'), b2.box1_minor));
    return next;

    -- ── 5. Zero-rated, exempt and outside the scope ─────────────────────────
    v_step := 'an invoice of bread, a letting and a grant';
    v_inv3 := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVR-UNTAXED', '{}'::jsonb);
    perform erp.add_document_line(v_inv3, v_zero, 1, 10000, 'bread');
    perform erp.add_document_line(v_inv3, v_exempt, 1, 10000, 'a letting');
    perform erp.add_document_line(v_inv3, v_out, 1, 10000, 'a grant');
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    perform erp.transition_document(v_inv3, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'box 6 counts a zero-rated and an exempt supply and not one outside the scope, box 1 does not move, and the exempt supply is flagged';
    passed := v_state is null
          and b1.box6_pounds - b0.box6_pounds = 200
          and b1.box1_minor = b0.box1_minor
          and exists (select 1 from erp.vat_exceptions(v_entity, v_wide_from, v_today) x
                       where x.reference = (select d.document_number from erp.document d where d.id = v_inv3)
                         and not x.blocks and x.finding like 'an exempt supply%');
    detail := coalesce(v_state, format('box 6 moved %s, box 1 moved %s', b1.box6_pounds - b0.box6_pounds,
                                       b1.box1_minor - b0.box1_minor));
    return next;

    -- ── 6. A bill with no tax stated ────────────────────────────────────────
    v_step := 'the other fifty received and billed with no tax';
    v_grn2 := erp.open_document('goods_receipt', v_supplier, v_entity, v_site);
    perform erp.receive_against(v_grn2, v_pol2, 50, null);
    perform erp.transition_document(v_grn2, 'post', 'vat return suite');
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_bill2 := erp.bill_from_receipt(v_grn2, 'ZZVR-SUP-2', v_today, v_today + 30, true);
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'a bill with no tax stated is in box 7 at its net and not in box 4, and the tax report shows it with no code';
    passed := v_state is null
          and b1.box7_pounds - b0.box7_pounds = 500
          and b1.box4_minor = b0.box4_minor
          and exists (select 1 from erp.tax_report(v_wide_from, v_today, v_entity) t
                       where t.direction = 'input' and t.tax_code is null and t.taxable_minor >= 50000);
    detail := coalesce(v_state, format('box 7 moved %s, box 4 moved %s', b1.box7_pounds - b0.box7_pounds,
                                       b1.box4_minor - b0.box4_minor));
    return next;

    -- ── 7. The arithmetic of the form ───────────────────────────────────────
    v_step := 'reading the boxes';
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'box 3 is box 1 plus box 2, box 5 is the difference of 3 and 4 and never negative, and boxes 2, 8 and 9 are nought';
    passed := v_state is null
          and b1.box3_minor = b1.box1_minor + b1.box2_minor
          and b1.box5_minor = abs(b1.box3_minor - b1.box4_minor)
          and b1.box5_minor >= 0
          and b1.box5_is = case when b1.box3_minor >= b1.box4_minor then 'payable' else 'repayable' end
          and b1.box2_minor = 0 and b1.box8_pounds = 0 and b1.box9_pounds = 0
          -- Ten thousand of output against twenty thousand of input: a repayment.
          and b1.box1_minor = 10000 and b1.box4_minor = 20000
          and b1.box5_minor = 10000 and b1.box5_is = 'repayable';
    detail := coalesce(v_state, format('1 %s, 2 %s, 3 %s, 4 %s, 5 %s %s, 8 %s, 9 %s',
                                       b1.box1_minor, b1.box2_minor, b1.box3_minor, b1.box4_minor,
                                       b1.box5_minor, b1.box5_is, b1.box8_pounds, b1.box9_pounds));
    return next;

    -- ── 8. Whole pounds, the pence dropped ──────────────────────────────────
    v_step := 'an invoice of 123.99 on a day of its own';
    v_inv4 := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVR-PENCE', '{}'::jsonb);
    perform erp.add_document_line(v_inv4, v_zero, 1, 12399, 'bread and pence');
    perform erp.set_invoice_tax_point(v_inv4, v_today - 2);
    perform erp.transition_document(v_inv4, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_today - 2, v_today - 2);
    v_cases := v_cases + 1;
    case_name := 'box 6 is in whole pounds with the pence dropped, not rounded';
    passed := v_state is null and b1.box6_pounds = 123 and b1.entries = 1;
    detail := coalesce(v_state, format('%s entr(y/ies), box 6 %s', b1.entries, b1.box6_pounds));
    return next;

    -- ── 9. The tax point decides the quarter ────────────────────────────────
    v_step := 'an invoice raised today for a supply on the last day of last quarter';
    v_inv5 := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVR-LASTQ', '{}'::jsonb);
    perform erp.add_document_line(v_inv5, v_item, 1, 30000, 'supplied last quarter');
    perform erp.set_invoice_tax_point(v_inv5, v_pq_to);
    select * into b0 from erp.vat_return_boxes(v_entity, v_pq_from, v_pq_to);
    select * into bq from erp.vat_return_boxes(v_entity, v_q_from, v_today);
    perform erp.transition_document(v_inv5, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_pq_from, v_pq_to);
    select * into b2 from erp.vat_return_boxes(v_entity, v_q_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'an invoice posted today with a tax point in the previous quarter falls in that quarter''s return and not in this one';
    passed := v_state is null
          and b1.box1_minor - b0.box1_minor = 6000
          and b2.box1_minor = bq.box1_minor;
    detail := coalesce(v_state, format('last quarter''s box 1 moved %s, this quarter''s %s',
                                       b1.box1_minor - b0.box1_minor, b2.box1_minor - bq.box1_minor));
    return next;

    -- ── 10. A manual journal to tax control ─────────────────────────────────
    -- A payment to HMRC, or a correction somebody posted by hand: it names no
    -- document, so it is in no box, and it is listed for the person filing.
    v_step := 'a manual journal debiting tax control';
    select a.id into v_tax_acct from erp.account a
     where a.tenant_id = rb.tenant_id and a.entity_id = v_entity and a.control_kind = 'tax'
     order by a.code limit 1;
    select a.id into v_cost_acct from erp.account a
     where a.tenant_id = rb.tenant_id and a.entity_id = v_entity and a.account_type = 'expense'
       and a.control_kind is null
     order by a.code limit 1;
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date, description,
                             status, manual_reason)
    values (rb.tenant_id, v_entity, v_ledger, 'manual', v_today, 'VAT return suite correction',
            'draft', 'vat return suite: a correction by hand')
    returning id into v_journal;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor, credit_minor,
                                  currency, base_debit_minor, base_credit_minor, exchange_rate, description)
    values (rb.tenant_id, v_journal, 1, v_tax_acct, 700, 0, v_ccy, 700, 0, 1, 'by hand'),
           (rb.tenant_id, v_journal, 2, v_cost_acct, 0, 700, v_ccy, 0, 700, 1, 'by hand');
    update erp.journal set status = 'posted', posted_at = now() where id = v_journal;
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'a manual journal to tax control is listed for information and changes no box';
    passed := v_state is null
          and b1.box1_minor = b0.box1_minor and b1.box4_minor = b0.box4_minor
          and b1.entries = b0.entries
          and exists (select 1 from erp.vat_exceptions(v_entity, v_wide_from, v_today) x
                       where not x.blocks and x.finding like '%names no document'
                         and x.detail like '%by -700%')
          and not exists (select 1 from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks);
    detail := coalesce(v_state, format('box 1 %s to %s, box 4 %s to %s; %s finding(s)', b0.box1_minor, b1.box1_minor,
                                       b0.box4_minor, b1.box4_minor,
                                       (select count(*) from erp.vat_exceptions(v_entity, v_wide_from, v_today))));
    return next;

    -- ── 11. The tax report is the boxes' breakdown ──────────────────────────
    v_step := 'the tax report beside the boxes';
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(t.tax_minor) filter (where t.direction = 'output'), 0),
           coalesce(sum(t.tax_minor) filter (where t.direction = 'input'), 0)
      into v_x, v_y
      from erp.tax_report(v_wide_from, v_today, v_entity) t;
    v_cases := v_cases + 1;
    case_name := 'the tax report''s output tax is box 1 and its input tax box 4 for the same company and period, and another company''s report holds none of it';
    passed := v_state is null and v_x = b1.box1_minor and v_y = b1.box4_minor
          and b1.box1_minor <> 0 and b1.box4_minor <> 0
          and not exists (select 1 from erp.tax_report(v_wide_from, v_today, gen_random_uuid()))
          and not exists (select 1 from erp.vat_entries(gen_random_uuid(), null, null));
    detail := coalesce(v_state, format('report %s output and %s input; boxes 1 %s and 4 %s', v_x, v_y,
                                       b1.box1_minor, b1.box4_minor));
    return next;

    -- ── 12. Every journal a document posted names it ────────────────────────
    -- A journal that did not would drop out of every box without a word.
    v_step := 'reading the journals the documents posted';
    select count(*) filter (where j.document_id is null), count(*) into v_n, v_m
      from erp.journal j
     where j.tenant_id = rb.tenant_id and j.status = 'posted' and j.source_code like 'document.%';
    v_cases := v_cases + 1;
    case_name := 'every journal a document posted names the document, so no posting falls out of the return';
    passed := v_state is null and v_n = 0 and v_m >= 8
          and (select count(*) from erp.vat_entries(v_entity, null, null)) >= 8;
    detail := coalesce(v_state, format('%s of %s document journal(s) name no document', v_n, v_m));
    return next;

    -- ── 13. The gate refuses a disagreement ─────────────────────────────────
    -- A determination edited after its document posted, and put back.
    v_step := 'a determination on the first invoice edited after it posted';
    update erp.tax_determination set tax_minor = tax_minor + 1
     where id = (select td.id from erp.tax_determination td
                  where td.tenant_id = rb.tenant_id and td.document_id = v_inv order by td.id limit 1);
    select count(*) into v_n from erp.vat_exceptions(v_entity, null, null) x
     where x.blocks and x.finding like 'the tax determined is not%'
       and x.reference = (select d.document_number from erp.document d where d.id = v_inv);
    v_msg := null;
    begin
      perform erp.assert_vat_agrees_with_ledger();
    exception when others then v_msg := sqlerrm; end;
    update erp.tax_determination set tax_minor = tax_minor - 1
     where id = (select td.id from erp.tax_determination td
                  where td.tenant_id = rb.tenant_id and td.document_id = v_inv order by td.id limit 1);
    v_msg2 := null;
    begin
      perform erp.assert_vat_agrees_with_ledger();
    exception when others then v_msg2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'tax determined on a posted invoice that its journal did not carry is a blocking finding, and the ledger agreement refuses it by name';
    passed := v_state is null and v_n = 1
          and v_msg like 'CLOVEERP_VAT_DISAGREES_WITH_LEDGER%'
          and v_msg2 is null;
    detail := coalesce(v_state, format('%s finding(s); edited: %s; put back: %s', v_n,
                                       coalesce(left(v_msg, 120), 'passed'), coalesce(left(v_msg2, 120), 'passed')));
    return next;

    -- ── 14. finance.read, at both doors ─────────────────────────────────────
    v_step := 'the doors, for a warehouse seat and for a reader of the books';
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    v_msg := null; v_msg2 := null;
    begin
      perform public.erp_vat_boxes(v_wide_from, v_today, null);
      v_msg := 'answered';
    exception when others then v_msg := sqlerrm; end;
    begin
      perform public.erp_tax_report(v_wide_from, v_today);
      v_msg2 := 'answered';
    exception when others then v_msg2 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    res := public.erp_vat_boxes(v_wide_from, v_today, v_entity);
    v_x := (select coalesce(sum((t ->> 'tax_minor')::bigint) filter (where t ->> 'direction' = 'output'), 0)
              from jsonb_array_elements(public.erp_tax_report(v_wide_from, v_today)) t);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_cases := v_cases + 1;
    case_name := 'the VAT boxes and the tax report are refused to a seat without finance.read and answered to one with it';
    passed := v_state is null
          and v_msg like 'CLOVEERP_PERMISSION_DENIED: finance.read%'
          and v_msg2 like 'CLOVEERP_PERMISSION_DENIED: finance.read%'
          and jsonb_array_length(res) = 1
          and (res -> 0 ->> 'box1_minor')::bigint = b1.box1_minor
          and (res -> 0 ->> 'box6_pounds')::bigint = b1.box6_pounds
          and jsonb_typeof(res -> 0 -> 'exceptions') = 'array'
          and v_x = b1.box1_minor;
    detail := coalesce(v_state, format('warehouse: %s / %s; reader: %s company row(s), box 1 %s, report output %s',
                                       left(v_msg, 60), left(v_msg2, 60), jsonb_array_length(res),
                                       res -> 0 ->> 'box1_minor', v_x));
    return next;

    -- ── 15. The whole organisation agrees ───────────────────────────────────
    v_step := 'the ledger agreement, over everything the suite posted';
    v_msg := null;
    begin
      v_msg2 := erp.assert_vat_agrees_with_ledger();
    exception when others then v_msg := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'every entry the suite posted agrees with the ledger, and the build''s reconciliation says so for this organisation';
    passed := v_state is null and v_msg is null and v_msg2 like 'vat: %'
          and exists (select 1 from erp_meta.diagnostic_check d
                       where d.function_name = 'assert_vat_agrees_with_ledger'
                         and d.kind = 'assertion' and d.scope = 'tenant');
    detail := coalesce(v_state, coalesce(left(v_msg, 200), v_msg2));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 16. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzvr-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_ware, s_read));
  detail := coalesce(v_state, 'the organisation rolled back with its bills, invoices, credit note and journals');
  return next;

  -- The count guard says what stopped the fixture.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.vat_return_suite() from public, anon;

comment on function erp_test.vat_return_suite() is
  'The nine VAT boxes and the tax report (20261001000000): the one-button bill in box 4 and in the '
  'ledger alike, a sale in boxes 1 and 6, a credit note and a reversal subtracting on their own dates, '
  'zero-rated and exempt in box 6 and outside the scope not, an untaxed bill in box 7, the form''s '
  'arithmetic, whole pounds, the tax point''s quarter, a manual journal listed and in no box, the '
  'report equal to boxes 1 and 4, a disagreement refused, and finance.read at both doors.';

create or replace function erp_test.assert_vat_return_suite()
returns text
language plpgsql
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
    from erp_test.vat_return_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'The VAT return would say what the ledger does not. Read the case that failed.';
  end if;
  if v_total <> 16 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 16', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat return: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_return_suite() from public, anon;

comment on function erp_test.assert_vat_return_suite() is
  'The nine VAT boxes are computed from the posted journals and agree with the ledger, and the tax '
  'report subtracts credit notes and reversals (20261001000000).';

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
