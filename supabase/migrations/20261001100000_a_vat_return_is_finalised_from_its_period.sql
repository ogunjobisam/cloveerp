set lock_timeout = '30s';

-- =============================================================================
-- 20261001100000  A VAT return is finalised from its period
-- -----------------------------------------------------------------------------
-- PR14 M2 (docs/spec/simplification-review.md §7 VAT, node V1, the write
-- side), on top of the nine boxes of 20261001000000.
--
-- ── WHAT WAS THERE ───────────────────────────────────────────────────────────
--
-- The nine boxes could be read for any company and any two dates, and nothing
-- said which dates a return is for, when it is due, or that one had been made.
-- A company's VAT registration was a row with a number and a date, and no
-- product routine asked what periods it gave.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * A setting, tax.vat_return, per organisation or company: how often the
--     company returns (quarterly or monthly), its stagger (1, 2 or 3: the
--     quarters ending March, April or May and every third month after), its
--     scheme (standard, cash or flat rate) and whether it is in Northern
--     Ireland. The product default is quarterly, stagger 1, standard and not
--     Northern Ireland (D6). erp.vat_return_policy() reads it layered as the
--     procurement policy is.
--   * erp.vat_obligations(): the periods a company must return, derived from
--     its VAT registration and the setting, never stored. The first begins on
--     the registration's effective date; each ends on the next month end the
--     frequency and stagger name; the last listed is the one holding the day
--     asked about. Each is due a calendar month and seven days after it ends
--     (the last day of the next month, and seven days), and reads open until
--     it ends, due until that date, overdue after it, and finalised once a
--     return holds it. A finalised return's period is its own, so a company
--     that changes its stagger continues from the last one it made.
--   * A base type, vat_return: finance, no flow, moves no stock and reaches no
--     ledger, needs no party, raised under finance.close_period (D13). Shipped
--     from one helper, erp.vat_return_pack_items(): a lifecycle (draft, then
--     finalised by one move, finalise), a numbering rule (VAT-, never reset),
--     the document type and the setting at its defaults. Installed by
--     erp.configure_tax() and offered as version 2 of tax, its first upgrade.
--     Finalised is terminal and not committed, so the billed documents_posted
--     meter does not move.
--   * erp.finalise_vat_return(company, period end): one press. It authorises
--     finance.close_period in the company, finds the obligation and refuses
--     one that does not exist, has not ended, follows one not yet finalised or
--     is finalised already; refuses a scheme other than standard, and Northern
--     Ireland (D7); takes the entries by the inclusion rule; refuses any
--     blocking exception of 20261001000000 (a side it cannot tell, a figure not
--     in sterling (D9), a determination the ledger disagrees with, tax control
--     moved outside an entry); opens the return through erp.open_document(),
--     dated the period end, due on the due date, with the boxes, the entries,
--     what was carried forward and a digest of the entries frozen in its
--     attributes (D4); and moves it to finalised as the system's move, derived
--     from erp.vat_return_is_computed(). There is no un-finalise and no filed
--     state (D14): an error in a finalised return is corrected on the next.
--   * The inclusion rule: a return takes every entry dated up to its period
--     end, and on or after the registration's first day, that no earlier
--     return of the company took. What an earlier return took is the journals
--     it names, so an entry posted late into a finalised quarter carries
--     forward to the next return and is in neither twice (D15: no VAT lock
--     date). The fiscal close stays the lock on postings. Where what was
--     carried forward is more than VAT Notice 700/45 lets a return correct,
--     the return says so; it does not refuse, because whether to notify HMRC
--     separately is the person's decision.
--   * The finalised return is frozen: a trigger refuses any change to it but
--     to its notes (its figures, dates, company, reference and cancellation
--     among them), and any line at all on a VAT return, an administrator
--     included, outside a purge. The notes stay writable, which is where a
--     filing reference goes (D14).
--   * Nobody opens a return, adds a line to one or finalises one by hand: the
--     two doors that open a named type refuse it, as does the line door, and
--     the move is refused while its fact does not hold.
--   * The reversal register: posts_nothing.
--   * Doors, api-only until the VAT screen (M4): erp_vat_obligations under
--     finance.read, each unfinalised period with the boxes finalising it would
--     take now (the preview; there is no stored draft, D14), and
--     erp_finalise_vat_return under finance.close_period.
--   * An organisation still on tax version 1 has obligations, which are
--     derived, and cannot finalise until it takes the upgrade.
--
-- ── A CALL MADE HERE, FOR THE PR DESCRIPTION ─────────────────────────────────
--
--   * D4 said the inclusion rule reads journal.posted_at against the time the
--     previous return was finalised. Every posting route writes posted_at as
--     now(), which is when its transaction began, so a journal posted in the
--     same transaction as a finalise, or committed by one that began before
--     it, reads as taken by a return that never saw it and would fall out of
--     every return for ever. So what an earlier return took is read from the
--     journals it names, which it stores beside the digest. Still derived and
--     not marked: nothing is written to a journal or a determination, and the
--     closed-period guard is never met.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * The export (M3), the screen (M4) and the demonstration's returns (M4,
--     D12). The demonstration keeps tax version 1 until an Upgrade, as every
--     organisation does; the catch-up is not taught to take it here.
--   * Flat rate, cash accounting and Northern Ireland are declared by the
--     setting and refused by name (D7); boxes 2, 8 and 9 stay nought.
--   * VAT groups: a return is per company and per registration (D18).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NO_VAT_OBLIGATION',
  'Finalising a VAT return for a period the company does not have to return.',
  'A return is made for one of the periods the company''s VAT registration and its return setting give; a period that is not one of them, or a company with no VAT registration, has no return to make.',
  'Open VAT returns and finalise one of the periods it lists. A company with no VAT registration is given one on its record first.');

select erp.register_refusal('CLOVEERP_VAT_PERIOD_NOT_ENDED',
  'Finalising a VAT return for a period that has not ended.',
  'A return says what the period''s sales and purchases were, and until the period ends more of them can happen.',
  'Wait for the period to end. Until then VAT returns shows the boxes as they stand.');

select erp.register_refusal('CLOVEERP_EARLIER_VAT_RETURN_OPEN',
  'Finalising a VAT return while an earlier period''s is not finalised.',
  'Each return takes what the returns before it did not, so the earlier one has to be made first or its entries would be taken by the later one.',
  'Finalise the earlier period first; VAT returns lists them in order.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_ALREADY_FINALISED',
  'Finalising a VAT return for a period that already has one.',
  'A period is returned once. A finalised return is not changed or replaced: an error in it is corrected on the next return, or notified to HMRC.',
  'Open the finalised return from VAT returns. Correct anything wrong in it by posting the correction, which the next return takes.');

select erp.register_refusal('CLOVEERP_VAT_SCHEME_NOT_BUILT',
  'Finalising a VAT return for a company on the flat rate or cash accounting scheme.',
  'The boxes are computed from invoices and bills as they are posted, which is the standard scheme. Flat rate and cash accounting compute them otherwise, and the product does not.',
  'Make this company''s returns outside the product, or set its VAT return scheme to standard in Configuration if it is on the standard scheme.');

select erp.register_refusal('CLOVEERP_VAT_NORTHERN_IRELAND_NOT_BUILT',
  'Finalising a VAT return for a company in Northern Ireland.',
  'A Northern Ireland return reports goods moved to and from the EU in boxes 2, 8 and 9, and the product records no such movements.',
  'Make this company''s returns outside the product, or clear Northern Ireland in its VAT return setting in Configuration if it trades from Great Britain.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_HAS_EXCEPTIONS',
  'Finalising a VAT return while something it would take cannot be filed as it stands.',
  'A return is final, so it is not made over an entry whose side cannot be told, a figure not in the company''s own currency, tax determined that the ledger did not carry, or tax control moved outside an invoice, credit note or bill.',
  'Open the document the refusal names and put it right: reverse the posting and post it again, or state the tax before it posts. VAT returns lists every finding.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD',
  'Opening a VAT return, adding a line to one, or finalising one by hand.',
  'A VAT return is the record of a period''s nine boxes as the ledger gave them when it was finalised. One opened or finalised by hand would carry figures no entry gave, and a return has no lines.',
  'Finalise the period from VAT returns. The return is opened and finalised in the same press.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_IS_FINAL',
  'Changing a finalised VAT return.',
  'A finalised return is what the company says it owes for the period, and its figures, dates and company stay as they were finalised. There is no un-finalise.',
  'Correct an error on the next return by posting the correction, or notify HMRC. A filing reference can be written in the return''s notes.');

select erp.register_refusal('CLOVEERP_VAT_RETURN_NOT_INSTALLED',
  'Finalising a VAT return in an organisation whose tax module has no VAT return.',
  'The VAT return arrived with version 2 of the tax module, and an organisation on version 1 has no document to finalise one into.',
  'Upgrade the tax module from Administration, Configuration. Its obligations are listed already.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The base type
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.document_type
  (code, name_key, module_code, flow, affects_stock, affects_finance, requires_party,
   requires_site, description, create_permission)
values
  ('vat_return', 'document.vat_return', 'finance', 'none', false, false, false, false,
   'A VAT return: one company''s nine boxes for one period, frozen as they were when it was '
   'finalised, with the entries it took. Opened and finalised in one press by '
   'erp.finalise_vat_return(); it posts nothing (20261001100000).',
   'finance.close_period')
on conflict (code) do update
  set name_key = excluded.name_key, module_code = excluded.module_code, flow = excluded.flow,
      affects_stock = excluded.affects_stock, affects_finance = excluded.affects_finance,
      requires_party = excluded.requires_party, requires_site = excluded.requires_site,
      description = excluded.description, create_permission = excluded.create_permission;

do $base$
begin
  if (select count(*) from erp_ref.document_type bt
       where bt.code = 'vat_return' and bt.module_code = 'finance' and bt.flow = 'none'
         and not bt.affects_stock and not bt.affects_finance and not bt.requires_party
         and not bt.requires_site and bt.create_permission = 'finance.close_period') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type vat_return is not the row this migration declares';
  end if;
end
$base$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, module_code, description) values
  ('document.vat_return', 'en', 'VAT return', 'finance', 'Document base type name (20261001100000).'),
  ('document.vat_return', 'de', 'Umsatzsteuererklärung', 'finance', null),
  ('config.tax.vat_return', 'en', 'VAT return', 'finance',
   'The name of the tax.vat_return configuration type: how often a company returns, its stagger, scheme and whether it is in Northern Ireland.'),
  ('config.tax.vat_return', 'de', 'Umsatzsteuererklärung', 'finance',
   'Der Name des Konfigurationstyps tax.vat_return.'),
  ('event.vat_return.finalised', 'en', 'VAT return finalised', 'finance',
   'Event raised when a company''s VAT return for a period is finalised with its nine boxes.'),
  ('event.vat_return.finalised', 'de', 'Umsatzsteuererklärung abgeschlossen', 'finance',
   'Ereignis, wenn die Umsatzsteuererklärung eines Zeitraums mit ihren neun Feldern abgeschlossen wird.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.event_type (code, version, aggregate_type, module_code, name_key, description, payload_schema, is_current)
values ('vat_return.finalised', 1, 'document', 'finance', 'event.vat_return.finalised',
        'A company''s VAT return for a period was finalised, with its nine boxes frozen.',
        '{"type":"object","required":["period_start","period_end","box5_minor","box5_is","entries","entries_digest"],
          "properties":{"period_start":{"type":"string"},"period_end":{"type":"string"},
                        "box5_minor":{"type":"integer"},"box5_is":{"type":"string"},
                        "entries":{"type":"integer"},"entries_digest":{"type":"string"},
                        "carried_forward":{"type":"integer"}}}'::jsonb,
        true)
on conflict do nothing;

do $event$
begin
  if (select count(*) from erp_ref.event_type et
       where et.code = 'vat_return.finalised' and et.is_current and et.version = 1
         and et.aggregate_type = 'document' and et.name_key = 'event.vat_return.finalised') <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: vat_return.finalised is declared already, and not as 20261001100000 declares it';
  end if;
end
$event$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The setting, and what reads it
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('tax.vat_return', 'policy', 'finance', 'config.tax.vat_return',
   'How a company returns VAT: quarterly or monthly; for quarterly, its stagger, 1 for quarters '
   'ending March, June, September and December, 2 for April, July, October and January, 3 for May, '
   'August, November and February; its scheme; and whether it is in Northern Ireland. The periods '
   'it must return start on its VAT registration''s effective date.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'frequency', jsonb_build_object('type','string','enum', jsonb_build_array('quarterly','monthly')),
       'stagger', jsonb_build_object('type','integer','enum', jsonb_build_array(1, 2, 3)),
       'scheme', jsonb_build_object('type','string','enum', jsonb_build_array('standard','cash','flat_rate')),
       'northern_ireland', jsonb_build_object('type','boolean'))),
   'entity', true,
   jsonb_build_object('frequency','quarterly','stagger',1,'scheme','standard','northern_ireland',false),
   'the periods VAT returns lists, and so what each return takes, follow the frequency and stagger; '
   'a scheme other than standard, or Northern Ireland, is refused at finalise, because the product '
   'computes the standard scheme''s boxes only.')
on conflict (code) do nothing;

do $config_type$
begin
  if (select ct.default_value from erp_ref.config_type ct where ct.code = 'tax.vat_return')
     is distinct from '{"frequency": "quarterly", "stagger": 1, "scheme": "standard", "northern_ireland": false}'::jsonb
     or (select ct.module_code from erp_ref.config_type ct where ct.code = 'tax.vat_return') is distinct from 'finance' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: tax.vat_return is declared already, and not as 20261001100000 declares it';
  end if;
end
$config_type$;

create or replace function erp.vat_return_policy(p_entity_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The VAT return setting in force at a company (20261001100000), layered key
  -- by key as the procurement policy is: the product's default, then what the
  -- organisation set, then the company. Read by erp.vat_obligations() for the
  -- frequency and stagger and by erp.finalise_vat_return() for the scheme and
  -- Northern Ireland.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('tax.vat_return', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('tax.vat_return', null, null, p_entity_id, null), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'tax.vat_return'
$$;

revoke all on function erp.vat_return_policy(uuid) from public, anon;

comment on function erp.vat_return_policy(uuid) is
  'tax.vat_return at a company, over its defaults (20261001100000): frequency, stagger, scheme and '
  'Northern Ireland. Read by erp.vat_obligations() and erp.finalise_vat_return().';

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The return, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The VAT return (20261001100000), read by erp.configure_tax() for a new
  -- install and by the upgrade register for an organisation on version 1, so
  -- the two cannot disagree. In the order a change set applies them: the
  -- lifecycle and the sequence before the type that names them, and the
  -- setting at the product's defaults.
  --
  -- The lifecycle is the period's, not a person's: opened and finalised in one
  -- press by erp.finalise_vat_return(), the move derived from
  -- erp.vat_return_is_computed(). Finalised is terminal and not committed: a
  -- return posts nothing and is not a document posted on the billed meter.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'vat_return', 'payload',
      jsonb_build_object(
        'code', 'vat_return', 'object_type', 'document', 'name', 'VAT return',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','finalised','name','Finalised','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',20)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','finalise','name','Finalise','from','draft','to','finalised','required_permission','finance.close_period','sort_order',10)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'vat_return', 'payload',
      jsonb_build_object('code','vat_return','prefix','VAT-','pad_to',6,
                         'reset_period','never','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'vat_return', 'payload',
      jsonb_build_object('code','vat_return','base_type','vat_return',
                         'name','VAT return','numbering_rule','vat_return',
                         'state_machine','vat_return',
                         'create_permission','finance.close_period')),
    -- The key is the configuration manifest's, so the upgrade can tell it is
    -- held (20260923100000).
    jsonb_build_object('kind', 'config', 'key', 'tax.vat_return||-|-', 'payload',
      jsonb_build_object('config_type','tax.vat_return','value',
        jsonb_build_object('frequency','quarterly','stagger',1,'scheme','standard','northern_ireland',false))))
$$;

comment on function erp.vat_return_pack_items() is
  'The VAT return (20261001100000): its lifecycle, numbering rule, document type and the tax.vat_return '
  'setting, the items erp.configure_tax() and the tax upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_tax(character,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                                            'treatment','standard')))))));$o$;
  v_new constant text := $n$                                            'treatment','standard'))))))
      -- The VAT return (20261001100000), from its one helper.
      || erp.vat_return_pack_items());$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.vat_return_pack_items()') > 0 then
    raise notice '% already installs the VAT return; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % rule set anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The upgrade register: version 2 for an organisation on version 1
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 2,
       description = description
         || ' Version 2 (20261001100000): the VAT return, finalised from a period the company''s '
         || 'registration gives, with its nine boxes frozen, and the tax.vat_return setting.'
 where install_code = 'tax' and current_version = 1;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'tax', 2, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       100 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.vat_return_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'tax') is distinct from 2 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the tax installer is not at version 2';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.vat_return_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'tax' and ui.to_version = 2) <> 4
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'tax') <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 2 of tax is not the four items the VAT return ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The obligations, derived
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_due_on(p_period_end date)
returns date
language sql
immutable
set search_path = ''
as $$
  -- One calendar month and seven days after the period ends (VAT Notice 700
  -- §21, the VAT Regulations 1995 reg 25): the last day of the month after
  -- the one the period ends in, and seven days (20261001100000). A quarter
  -- ending 30 September is due on 7 November.
  select ((date_trunc('month', p_period_end) + interval '2 months')::date - 1 + 7)
$$;

revoke all on function erp.vat_return_due_on(date) from public, anon;

comment on function erp.vat_return_due_on(date) is
  'When a VAT return for a period ending on this day is due (20261001100000): the last day of the next month, and seven days.';

create or replace function erp.vat_obligations(p_entity_id uuid default null, p_on date default null)
returns table(entity_id uuid, company text, vrn text, frequency text, stagger integer,
              period_start date, period_end date, due_on date, status text,
              return_document_id uuid, return_number text)
language sql
stable
set search_path = ''
as $$
  -- The periods a company must return VAT for (20261001100000), derived from
  -- its VAT registration and its tax.vat_return setting and never stored. One
  -- row per company per period, every active company when none is named, as
  -- of p_on (today when it is null):
  --
  --   * every return the company finalised, with the period it was made for;
  --   * then, from the day after the last of them, or from the registration's
  --     effective date when there is none, each period to the next month end
  --     the frequency and stagger name, up to the one holding the day, and no
  --     further than the registration's end.
  --
  -- A company with no VAT registration in force has none.
  with t as (select erp.require_tenant_id() as tenant_id, coalesce(p_on, current_date) as on_day),
  co as (
    select e.id, e.code, t.tenant_id, t.on_day, reg.registration_number, reg.valid_from, reg.valid_to,
           erp.vat_return_policy(e.id) as policy
      from t
      join erp.entity e on e.tenant_id = t.tenant_id
      cross join lateral (
        select g.registration_number, g.valid_from, g.valid_to
          from erp.entity_tax_registration g
         where g.tenant_id = e.tenant_id and g.entity_id = e.id
           and upper(g.registration_type) like 'VAT%'
           and g.valid_from <= t.on_day
         order by g.valid_from desc, g.created_at desc
         limit 1) reg
     where (p_entity_id is null and e.status = 'active') or e.id = p_entity_id
  ),
  -- The setting, read so that nothing outside its shape widens it: anything
  -- but monthly is quarterly, and a stagger that is not 1, 2 or 3 is 1.
  pol as (
    select co.*,
           case when co.policy ->> 'frequency' = 'monthly' then 'monthly' else 'quarterly' end as freq,
           case when co.policy ->> 'stagger' in ('1', '2', '3') then (co.policy ->> 'stagger')::integer
                else 1 end as stag
      from co
  ),
  fin as (
    select d.entity_id, d.id, d.document_number,
           (d.attributes #>> '{vat_return,period_start}')::date as period_start,
           (d.attributes #>> '{vat_return,period_end}')::date as period_end
      from pol
      join erp.document d on d.tenant_id = pol.tenant_id and d.entity_id = pol.id and not d.is_cancelled
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id and dt.base_type_code = 'vat_return'
     where erp.object_current_state('document', d.id) = 'finalised'
  ),
  nxt as (
    select pol.*,
           coalesce((select max(f.period_end) from fin f where f.entity_id = pol.id) + 1, pol.valid_from) as from_day
      from pol
  ),
  -- Every month end the frequency and stagger close a period on: stagger 1
  -- ends in months 3, 6, 9 and 12, stagger 2 a month later, stagger 3 two.
  ends as (
    select n.id, (g + interval '1 month')::date - 1 as e
      from nxt n
      cross join lateral generate_series(date_trunc('month', n.from_day),
                                         date_trunc('month', greatest(n.on_day, n.from_day)) + interval '3 months',
                                         interval '1 month') g
     where n.freq = 'monthly' or extract(month from g)::integer % 3 = n.stag - 1
  ),
  periods as (
    select x.id,
           coalesce(lag(x.e) over (partition by x.id order by x.e) + 1, n.from_day) as period_start,
           least(x.e, coalesce(n.valid_to, x.e)) as period_end
      from ends x
      join nxt n on n.id = x.id
     where x.e >= n.from_day
  )
  select r.entity_id, r.company, r.vrn, r.frequency, r.stagger, r.period_start, r.period_end,
         r.due_on, r.status, r.return_document_id, r.return_number
    from (
      select pol.id as entity_id, pol.code as company, pol.registration_number as vrn,
             pol.freq as frequency, case when pol.freq = 'quarterly' then pol.stag end as stagger,
             f.period_start, f.period_end, erp.vat_return_due_on(f.period_end) as due_on,
             'finalised'::text as status, f.id as return_document_id, f.document_number as return_number
        from fin f join pol on pol.id = f.entity_id
      union all
      select n.id, n.code, n.registration_number, n.freq, case when n.freq = 'quarterly' then n.stag end,
             p.period_start, p.period_end, erp.vat_return_due_on(p.period_end),
             case when p.period_end >= n.on_day then 'open'
                  when n.on_day <= erp.vat_return_due_on(p.period_end) then 'due'
                  else 'overdue' end,
             null::uuid, null::text
        from periods p join nxt n on n.id = p.id
       where p.period_start <= n.on_day
         and p.period_start <= coalesce(n.valid_to, p.period_start)
    ) r
   order by r.company, r.period_end
$$;

revoke all on function erp.vat_obligations(uuid, date) from public, anon;

comment on function erp.vat_obligations(uuid, date) is
  'The periods a company must return VAT for, as of a day (20261001100000): derived from its VAT '
  'registration and its tax.vat_return setting, each with its due date and whether it is open, due, '
  'overdue or finalised, and the return that holds it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. What a return takes
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_figures(p_entity_id uuid, p_period_start date, p_period_end date,
                                                  p_take_from date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What a return for this period would take, and its nine boxes
  -- (20261001100000). The inclusion rule: every VAT entry dated from p_take_from
  -- (the registration's first day, for the next return to be made) up to the
  -- period end that no finalised return of the company names. An entry dated
  -- before the period start is carried forward: posted after the return for
  -- its own period was finalised, it is this one's.
  --
  -- The boxes are erp.vat_return_boxes()'s arithmetic over those entries. The
  -- digest is of each entry's journal, tax and net, in journal order, so the
  -- records a return was made from can be told from any others. What was
  -- carried forward is set beside VAT Notice 700/45's limit on the errors a
  -- return may correct: £10,000 of net tax, or 1% of box 6 up to £50,000.
  with t as (select erp.require_tenant_id() as tenant_id),
  taken as (
    select (j.value #>> '{}')::uuid as journal_id
      from t
      join erp.document d
        on d.tenant_id = t.tenant_id and d.entity_id = p_entity_id and not d.is_cancelled
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id and dt.base_type_code = 'vat_return'
      cross join lateral jsonb_array_elements(coalesce(d.attributes #> '{vat_return,journal_ids}', '[]'::jsonb)) j
     where erp.object_current_state('document', d.id) = 'finalised'
  ),
  x as (
    select e.*, e.vat_date < p_period_start as carried
      from erp.vat_entries(p_entity_id, p_take_from, p_period_end) e
     where not exists (select 1 from taken k where k.journal_id = e.journal_id)
  ),
  b as (
    select coalesce(sum(x.tax_minor) filter (where x.side = 'sale'), 0)::bigint as box1,
           coalesce(sum(x.tax_minor) filter (where x.side = 'purchase'), 0)::bigint as box4,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'sale'), 0) / 100.0)::bigint as box6,
           trunc(coalesce(sum(x.net_minor) filter (where x.side = 'purchase'), 0) / 100.0)::bigint as box7,
           count(*) as entries,
           count(*) filter (where x.carried) as carried,
           coalesce(sum(x.net_minor) filter (where x.carried), 0)::bigint as carried_net,
           coalesce(sum(case x.side when 'sale' then x.tax_minor when 'purchase' then -x.tax_minor else 0 end)
                      filter (where x.carried), 0)::bigint as carried_tax,
           coalesce(jsonb_agg(x.journal_id order by x.journal_id::text), '[]'::jsonb) as journal_ids,
           md5(coalesce(string_agg(x.journal_id::text || ':' || x.tax_minor || ':' || x.net_minor, ','
                                   order by x.journal_id::text), '')) as digest
      from x
  )
  select jsonb_build_object(
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

revoke all on function erp.vat_return_figures(uuid, date, date, date) from public, anon;

comment on function erp.vat_return_figures(uuid, date, date, date) is
  'What a VAT return for a period takes and its nine boxes (20261001100000): every entry dated from a '
  'day to the period end that no finalised return names, what of it was carried forward, and a digest '
  'of the entries. Read by erp.finalise_vat_return(), which freezes it, and by the obligations door as '
  'the preview.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. When a return is computed, and the one press that finalises it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.vat_return_is_computed(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A VAT return is computed when it is a draft whose attributes carry the
  -- period, the boxes and the digest of the entries it took
  -- (20261001100000). Read by the routine that finalises it and again by the
  -- engine, with the return's state locked, as the fact the move is derived
  -- from.
  select coalesce((
    select erp.object_current_state('document', d.id) = 'draft'
       and d.attributes #>> '{vat_return,period_end}' is not null
       and d.attributes #>> '{vat_return,entries_digest}' is not null
       and jsonb_typeof(d.attributes #> '{vat_return,boxes}') = 'object'
       and jsonb_typeof(d.attributes #> '{vat_return,journal_ids}') = 'array'
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
       and dt.base_type_code = 'vat_return' and not d.is_cancelled), false)
$$;

revoke all on function erp.vat_return_is_computed(uuid) from public, anon;

comment on function erp.vat_return_is_computed(uuid) is
  'True when a VAT return is a draft carrying its period, boxes, entries and digest (20261001100000).';

create or replace function erp.finalise_vat_return(p_entity_id uuid, p_period_end date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_type    text;
  ob        record;
  v_first   date;
  v_earlier text;
  v_policy  jsonb;
  v_scheme  text;
  v_n       integer;
  v_finding text;
  v_calc    jsonb;
  v_before  record;
  v_doc     uuid;
  v_number  text;
  v_prev    text;
  v_to      text;
  v_company text;
begin
  -- One press (20261001100000): the period's return opened, its boxes and the
  -- entries it took frozen in it, and finalised, or nothing at all. Every
  -- refusal is raised: a return half made would be neither.
  perform erp.authorise('finance.close_period', p_entity_id);

  -- One finalise at a time per company, and none while a posting for it is
  -- in flight: every journal and document names its company, so this waits
  -- for the ones already writing and holds the next until it commits.
  select e.code into v_company from erp.entity e
   where e.tenant_id = v_tenant and e.id = p_entity_id
     for update;

  select dt.code into v_type
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'vat_return' and dt.status = 'active'
     and (dt.entity_id is null or dt.entity_id = p_entity_id)
   order by (dt.entity_id is not null) desc, dt.code
   limit 1;
  if v_type is null then
    raise exception 'CLOVEERP_VAT_RETURN_NOT_INSTALLED: this organisation''s tax module has no VAT return'
      using errcode = '23514',
            hint = 'Upgrade the tax module from Administration, Configuration. Its obligations are listed already.';
  end if;

  select * into ob from erp.vat_obligations(p_entity_id) o where o.period_end = p_period_end;
  if not found then
    raise exception 'CLOVEERP_NO_VAT_OBLIGATION: % has no VAT return to make for a period ending %',
      coalesce(v_company, p_entity_id::text), p_period_end
      using errcode = '23503',
            hint = 'Open VAT returns and finalise one of the periods it lists. A company with no VAT registration is given one on its record first.';
  end if;
  if ob.status = 'finalised' then
    raise exception 'CLOVEERP_VAT_RETURN_ALREADY_FINALISED: % returned the period % to % on %',
      ob.company, ob.period_start, ob.period_end, ob.return_number
      using errcode = '23505',
            hint = 'Open the finalised return from VAT returns. Correct anything wrong in it by posting the correction, which the next return takes.';
  end if;
  if ob.status = 'open' then
    raise exception 'CLOVEERP_VAT_PERIOD_NOT_ENDED: % to % ends on %, and it is %',
      ob.period_start, ob.period_end, ob.period_end, current_date
      using errcode = '23514',
            hint = 'Wait for the period to end. Until then VAT returns shows the boxes as they stand.';
  end if;
  select format('%s to %s', o.period_start, o.period_end) into v_earlier
    from erp.vat_obligations(p_entity_id) o
   where o.period_end < p_period_end and o.status <> 'finalised'
   order by o.period_end limit 1;
  if v_earlier is not null then
    raise exception 'CLOVEERP_EARLIER_VAT_RETURN_OPEN: % has not returned % yet', ob.company, v_earlier
      using errcode = '23514',
            hint = 'Finalise the earlier period first; VAT returns lists them in order.';
  end if;

  -- The scheme and the place (D7): the product computes the standard
  -- scheme's boxes for Great Britain, and refuses the rest by name. Anything
  -- outside the setting's shape is refused, not read as standard.
  v_policy := erp.vat_return_policy(p_entity_id);
  v_scheme := coalesce(v_policy ->> 'scheme', 'standard');
  if v_scheme <> 'standard' then
    raise exception 'CLOVEERP_VAT_SCHEME_NOT_BUILT: % returns VAT on the % scheme, and the product computes the standard scheme only',
      ob.company, v_scheme
      using errcode = '0A000',
            hint = 'Make this company''s returns outside the product, or set its VAT return scheme to standard in Configuration if it is on the standard scheme.';
  end if;
  if coalesce(v_policy -> 'northern_ireland', 'false'::jsonb) <> 'false'::jsonb then
    raise exception 'CLOVEERP_VAT_NORTHERN_IRELAND_NOT_BUILT: % is set as in Northern Ireland, whose boxes 2, 8 and 9 the product does not compute',
      ob.company
      using errcode = '0A000',
            hint = 'Make this company''s returns outside the product, or clear Northern Ireland in its VAT return setting in Configuration if it trades from Great Britain.';
  end if;

  -- The first day any return of the company can take, which is the first
  -- period's: the registration's effective date.
  select g.valid_from into v_first
    from erp.entity_tax_registration g
   where g.tenant_id = v_tenant and g.entity_id = p_entity_id
     and upper(g.registration_type) like 'VAT%' and g.valid_from <= current_date
   order by g.valid_from desc, g.created_at desc
   limit 1;

  -- Nothing that blocks, over everything this return could take.
  select count(*), min(format('%s: %s', x.reference, x.detail))
    into v_n, v_finding
    from erp.vat_exceptions(p_entity_id, v_first, p_period_end) x
   where x.blocks;
  if v_n > 0 then
    raise exception 'CLOVEERP_VAT_RETURN_HAS_EXCEPTIONS: % blocking finding(s) for % to %, the first %',
      v_n, ob.period_start, ob.period_end, v_finding
      using errcode = '23514',
            hint = 'Open the document the refusal names and put it right: reverse the posting and post it again, or state the tax before it posts. VAT returns lists every finding.';
  end if;

  v_calc := erp.vat_return_figures(p_entity_id, ob.period_start, p_period_end, v_first);

  -- Entries dated before the registration's first day no return takes; the
  -- return says how many there are.
  select count(*) as entries,
         coalesce(sum(case e.side when 'sale' then e.tax_minor when 'purchase' then -e.tax_minor else 0 end), 0)::bigint as tax_minor
    into v_before
    from erp.vat_entries(p_entity_id, null, v_first - 1) e;

  -- Opened through the door every document is opened by, which authorises
  -- the type's create permission in the company; dated the period end and
  -- due on the due date.
  v_doc := erp.open_document(v_type, null, p_entity_id, null, null, null, null);
  update erp.document d
     set document_date = p_period_end,
         due_date = ob.due_on,
         our_reference = format('VAT %s–%s', ob.period_start, ob.period_end),
         attributes = d.attributes || jsonb_build_object('vat_return',
           jsonb_build_object(
             'period_start', ob.period_start, 'period_end', ob.period_end, 'due_on', ob.due_on,
             'frequency', ob.frequency, 'stagger', ob.stagger, 'scheme', v_scheme, 'vrn', ob.vrn,
             'first_day', v_first,
             'before_registration', jsonb_build_object('entries', v_before.entries, 'tax_minor', v_before.tax_minor),
             'computed_at', clock_timestamp(),
             'finalised_by', erp.current_principal_id())
           || v_calc),
         updated_at = now()
   where d.tenant_id = v_tenant and d.id = v_doc
  returning d.document_number into v_number;

  -- The system's move, derived from erp.vat_return_is_computed(), named in
  -- erp.deriving_move immediately before it and put back after.
  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', v_doc::text || ':finalise', true);
  v_to := erp.transition_document(v_doc, 'finalise', 'the period''s boxes are computed');
  perform set_config('erp.deriving_move', v_prev, true);

  perform erp.append_event(
    'vat_return.finalised', 'document', v_doc,
    jsonb_build_object('period_start', ob.period_start, 'period_end', ob.period_end,
                       'box5_minor', (v_calc #>> '{boxes,box5_minor}')::bigint,
                       'box5_is', v_calc #>> '{boxes,box5_is}',
                       'entries', (v_calc ->> 'entries')::integer,
                       'entries_digest', v_calc ->> 'entries_digest',
                       'carried_forward', (v_calc #>> '{carried_forward,entries}')::integer),
    p_entity_id, null);

  return jsonb_build_object(
    'document_id', v_doc, 'document_number', v_number, 'state', v_to,
    'period_start', ob.period_start, 'period_end', ob.period_end, 'due_on', ob.due_on,
    'boxes', v_calc -> 'boxes', 'entries', v_calc -> 'entries',
    'carried_forward', v_calc -> 'carried_forward',
    'before_registration', jsonb_build_object('entries', v_before.entries, 'tax_minor', v_before.tax_minor));
end;
$$;

revoke all on function erp.finalise_vat_return(uuid, date) from public, anon;

comment on function erp.finalise_vat_return(uuid, date) is
  'Finalises a company''s VAT return for the period ending on a day, in one press (20261001100000): '
  'under finance.close_period, for a period that has ended and follows none still open, on the standard '
  'scheme outside Northern Ireland, with no blocking exception; the boxes, the entries taken and their '
  'digest frozen in a vat_return document the system moves to finalised.';

-- The fact the move is derived from, read again with the return's state
-- locked. Deployed body, asserted needle: one arm more in the document case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.count_sheet_is_finished'
$o$;
  v_new constant text := $n$             then 'erp.count_sheet_is_finished'
           -- A VAT return's finalise, once its boxes and entries are computed
           -- (20261001100000), asked for by erp.finalise_vat_return().
           when dt.base_type_code = 'vat_return' and p_transition_code = 'finalise'
            and erp.vat_return_is_computed(p_object_id)
             then 'erp.vat_return_is_computed'
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'erp.vat_return_is_computed') > 0 then
    raise notice '% already derives a VAT return''s finalise; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count sheet arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- By hand, a VAT return does not move at all: its one move is the period's.
do $transition$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$o$;
  v_new constant text := $n$  -- A VAT return is finalised by the press that computes it
  -- (20261001100000): erp.finalise_vat_return() makes the move when its fact
  -- holds, and this refuses it to anybody else, an administrator included.
  if dt.base_type_code = 'vat_return'
     and erp.derived_move_fact('document', p_document_id, p_transition_code) is null then
    raise exception
      'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD: % is a VAT return, finalised only by finalising its period (%)',
      coalesce(d.document_number, p_document_id::text), p_transition_code
      using errcode = '23514',
            hint = 'Finalise the period from VAT returns. The return is opened and finalised in the same press.';
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD') > 0 then
    raise notice '% already refuses a VAT return moved by hand; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % context anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C2. Nobody opens a return or writes its lines by hand
-- ─────────────────────────────────────────────────────────────────────────────

do $create$
declare
  v_doors constant text[] := array[
    'public.erp_create_document(text,uuid,uuid,text,date,uuid,text,uuid)',
    'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)'];
  v_old constant text := $o$            hint = 'Pay an approved run from Pay. Its payments are opened and posted with it.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Pay an approved run from Pay. Its payments are opened and posted with it.';
  end if;
  -- A VAT return is opened by finalising its period (20261001100000).
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = erp.current_tenant_id() and dt.code = p_type_code
                and dt.base_type_code = 'vat_return') then
    raise exception
      'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD: % is a VAT return, opened when its period is finalised',
      p_type_code
      using errcode = '23514',
            hint = 'Finalise the period from VAT returns. The return is opened and finalised in the same press.';
  end if;
$n$;
  v_door text;
  v_body text;
  v_hits integer;
begin
  foreach v_door in array v_doors loop
    v_body := pg_get_functiondef(v_door::regprocedure);
    if strpos(v_body, 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD') > 0 then
      raise notice '% already refuses a VAT return; left as it is', v_door;
      continue;
    end if;
    v_hits := (length(v_body) - length(replace(v_body, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % supplier payment refusal found % time(s)', v_door, v_hits;
    end if;
    execute replace(v_body, v_old, v_new);
  end loop;
end
$create$;

do $lines$
declare
  v_sig constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$            hint = 'Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.';
  end if;
$o$;
  v_new constant text := $n$            hint = 'Pay the further bills from Pay, or correct a misapplied payment with a journal on the Journals screen.';
  end if;

  -- A VAT return has no lines: it is its period's boxes (20261001100000).
  if v_base = 'vat_return' then
    raise exception
      'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD: % is a VAT return, and a return has no lines',
      d.document_number
      using errcode = '23514',
            hint = 'Finalise the period from VAT returns. The return is opened and finalised in the same press.';
  end if;
$n$;
  v_hits integer;
begin
  if strpos(v_def, 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD') > 0 then
    raise notice '% already refuses a line on a VAT return; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % supplier payment refusal found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lines$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C3. A finalised return is frozen
--
-- One trigger function, on the document and on its lines. A return stays as
-- it was finalised, its figures, dates, company, reference and cancellation
-- with it; only its notes do not, because that is where a filing reference is
-- written (D14). A line is refused on a return in any state, because a return
-- has none. A purge is let through, as every other freeze lets it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.protect_vat_return()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_doc    uuid;
  v_tenant uuid;
  v_number text;
begin
  if nullif(current_setting('erp.purge_tenant_id', true), '') is not null then
    return coalesce(new, old);
  end if;

  if tg_table_name = 'document_line' then
    v_doc := coalesce(new.document_id, old.document_id);
    v_tenant := coalesce(new.tenant_id, old.tenant_id);
    select d.document_number into v_number
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant and d.id = v_doc and dt.base_type_code = 'vat_return';
    if found then
      raise exception
        'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD: % is a VAT return, and a return has no lines',
        coalesce(v_number, v_doc::text)
        using errcode = '23514',
              hint = 'Finalise the period from VAT returns. The return is opened and finalised in the same press.';
    end if;
    return coalesce(new, old);
  end if;

  -- erp.document, before update.
  if not exists (select 1 from erp.document_type dt
                  where dt.tenant_id = old.tenant_id and dt.id = old.document_type_id
                    and dt.base_type_code = 'vat_return')
     or coalesce(erp.object_current_state('document', old.id), 'draft') = 'draft' then
    return new;
  end if;
  -- Everything but the notes and who last touched it.
  if (to_jsonb(new) - array['notes', 'updated_at', 'updated_by'])
     is distinct from (to_jsonb(old) - array['notes', 'updated_at', 'updated_by']) then
    raise exception 'CLOVEERP_VAT_RETURN_IS_FINAL: % is finalised, and its figures, dates and company stay as they were',
      old.document_number
      using errcode = '23514',
            hint = 'Correct an error on the next return by posting the correction, or notify HMRC. A filing reference can be written in the return''s notes.';
  end if;
  return new;
end;
$$;

revoke all on function erp.protect_vat_return() from public, anon;

comment on function erp.protect_vat_return() is
  'Holds a finalised VAT return as it was finalised, and refuses any line on a VAT return '
  '(20261001100000). Its notes stay writable, for a filing reference; a purge is let through.';

drop trigger if exists t_document_vat_return_frozen on erp.document;
create trigger t_document_vat_return_frozen
  before update on erp.document
  for each row
  when (old.attributes ? 'vat_return')
  execute function erp.protect_vat_return();

drop trigger if exists t_document_line_vat_return on erp.document_line;
create trigger t_document_line_vat_return
  before insert or update or delete on erp.document_line
  for each row execute function erp.protect_vat_return();

-- ─────────────────────────────────────────────────────────────────────────────
-- C4. The reversal register: a return posts nothing
-- ─────────────────────────────────────────────────────────────────────────────

do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$unsettles what the payment paid, is PR13 D10.')
    ) as v(base_type_code, route, next_action, rationale)$o$;
  v_new constant text := $n$unsettles what the payment paid, is PR13 D10.'),

      ('vat_return', 'posts_nothing',
       'A return posts nothing. An error in a finalised return is corrected on the next one, by posting the correction, which the next return takes, or notified to HMRC.',
       'A VAT return is the nine boxes of a period as the ledger gave them when it was finalised (20261001100000). erp_ref.document_type says it moves no stock and reaches no ledger, and there is no un-finalise (PR14 D14); erp.document_reversal_coverage_report() holds the claim.')
    ) as v(base_type_code, route, next_action, rationale)$n$;
  v_hits integer;
begin
  if strpos(v_def, $x$('vat_return', 'posts_nothing',$x$) > 0 then
    raise notice '% already routes a VAT return; left as it is', v_sig;
    return;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % last row anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$route$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D1. The doors
--
-- Volatile, as a door that authorises is: PostgREST opens a read-only
-- transaction for a stable one, and erp.authorise() writes its access-log row.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_vat_obligations(p_entity_id uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_next jsonb := '{}'::jsonb;
begin
  if p_entity_id is null then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('finance.read', p_entity_id);
  end if;

  -- The period each company finalises next takes what no return took from
  -- the registration's first day; a later one, what is dated in it.
  select coalesce(jsonb_object_agg(x.entity_id::text, x.period_end), '{}'::jsonb) into v_next
    from (select o.entity_id, min(o.period_end) as period_end
            from erp.vat_obligations(p_entity_id) o
           where o.status <> 'finalised'
           group by o.entity_id) x;

  return (
    select coalesce(jsonb_agg(
             to_jsonb(o)
             || case when o.status = 'finalised' then
                  jsonb_build_object('boxes', d.attributes #> '{vat_return,boxes}',
                                     'entries', d.attributes #> '{vat_return,entries}',
                                     'carried_forward', d.attributes #> '{vat_return,carried_forward}',
                                     'is_next', false)
                else
                  -- The preview: what finalising it now would take. There is no
                  -- stored draft (D14).
                  (erp.vat_return_figures(
                     o.entity_id, o.period_start, o.period_end,
                     case when (v_next ->> o.entity_id::text)::date = o.period_end
                          then (select g.valid_from from erp.entity_tax_registration g
                                 where g.tenant_id = erp.current_tenant_id() and g.entity_id = o.entity_id
                                   and upper(g.registration_type) like 'VAT%' and g.valid_from <= current_date
                                 order by g.valid_from desc, g.created_at desc limit 1)
                          else o.period_start end) - 'journal_ids')
                  || jsonb_build_object('is_next', (v_next ->> o.entity_id::text)::date = o.period_end)
                end
             order by o.company, o.period_end), '[]'::jsonb)
      from erp.vat_obligations(p_entity_id) o
      left join erp.document d on d.tenant_id = erp.current_tenant_id() and d.id = o.return_document_id
     -- Asked for every company, the reader is answered for the companies they
     -- may read the books of.
     where erp.has_permission('finance.read', o.entity_id));
end
$$;

revoke all on function public.erp_vat_obligations(uuid) from public, anon;
grant execute on function public.erp_vat_obligations(uuid) to authenticated, service_role;

comment on function public.erp_vat_obligations(uuid) is
  'The VAT periods of each company the reader may read the books of, under finance.read '
  '(20261001100000): due dates and status, a finalised period''s frozen boxes, and for the rest the '
  'boxes finalising it now would take.';

create or replace function public.erp_finalise_vat_return(p_entity_id uuid, p_period_end date)
returns jsonb
language sql
set search_path = ''
as $$ select erp.finalise_vat_return(p_entity_id, p_period_end) $$;

revoke all on function public.erp_finalise_vat_return(uuid, date) from public, anon;
grant execute on function public.erp_finalise_vat_return(uuid, date) to authenticated, service_role;

comment on function public.erp_finalise_vat_return(uuid, date) is
  'Finalises a company''s VAT return for the period ending on a day, in one press, under '
  'finance.close_period (20261001100000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_vat_obligations', 'erp.authorise',
   'Reads the VAT periods and their boxes under finance.read. Writes only the access-log row erp.authorise() raises.'),
  ('erp_finalise_vat_return', 'erp.finalise_vat_return',
   'Opens and finalises a VAT return for a period that has ended, freezing its boxes and the entries it took, and appends vat_return.finalised; authorises finance.close_period in the company. Posts nothing.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Until the VAT returns screen offers them (PR14 M4).
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_vat_obligations', 'pending_screen', '/finance/vat',
   'The VAT periods of each company with their due dates and status, and the boxes each would take. The VAT returns screen that lists them is PR14 M4.'),
  ('erp_finalise_vat_return', 'pending_screen', '/finance/vat',
   'Finalises a period''s VAT return in one press. Belongs as Finalise on a due or overdue row of the VAT returns screen, PR14 M4.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

select erp_meta.add_help_actions('/finance', array['erp_vat_obligations', 'erp_finalise_vat_return']);

-- ─────────────────────────────────────────────────────────────────────────────
-- E1. The driver register, restated whole as every change to it is
--
-- The return's one move is a routine's, so it is not a button
-- (src/components/erp/available-transitions.ts reads the newest restatement).
-- Otherwise as 20260930200000 left it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.transition_driver_register()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      -- Version 6 (20260929100000): paid in part, and then the rest, both
      -- the payment run's through erp.settle_paid_document(). Part paid is
      -- derived from erp.document_is_part_paid() and refused by hand.
      ('purchase_invoice',   'part_pay',               'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'pay_rest',               'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      -- Version 4 (20260929100000): paid in part and then the rest, both the
      -- cash's through erp.settle_paid_document(), part paid derived from
      -- erp.document_is_part_paid() and refused by hand; and credited in full
      -- out of part paid, the credit note's.
      ('sales_invoice',      'part_settle',            'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'settle_rest',            'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit_rest',            'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      -- Version 1 (20260917130000) and version 2 (20260928200000) of the
      -- transfer order. Documents in flight stay on version 1, so its rows
      -- stay while an organisation holds it; the moves both versions share
      -- are the despatch and receive doors', which is where the goods move.
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'in_transit',             'routine', 'erp.despatch_transfer(uuid)'),
      ('transfer_order',     'received',               'routine', 'erp.receive_transfer(uuid)'),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),
      -- Version 2: submitted as it is raised, and again by hand after a
      -- rejection; approved by somebody the chain asked, or derived from
      -- erp.approval_asked_nobody() when it asked nobody; closed derived from
      -- erp.transfer_is_received_in_full(), which a close asked for by hand
      -- also reaches, through the receiving site's routine. Neither derived
      -- move is a button.
      ('transfer_order',     'submit',                 'screen', ''),
      ('transfer_order',     'approve',                'screen', ''),
      ('transfer_order',     'reject',                 'screen', ''),
      ('transfer_order',     'approve_within_threshold', 'routine', 'erp.approve_transfer_within_threshold(uuid)'),
      ('transfer_order',     'close',                  'routine', 'erp.close_transfer_when_received(uuid,text,boolean)'),
      ('transfer_order',     'cancel',                 'screen', ''),
      ('transfer_order',     'cancel_approved',        'screen', ''),

      -- Version 1 (20260918810000) and version 2 (20260928500000) of the
      -- stock adjustment. A count's own adjustment is approved and posted by
      -- erp.post_count(), through erp.raise_count_adjustment(), both moves
      -- derived from erp.count_task_is_approved() whatever permission the
      -- organisation puts on them (20260927200000): version 1's approve from
      -- draft, version 2's approve_with_count. A hand-typed version 1
      -- adjustment is approved here and confirmed on the Stock adjustments
      -- screen; a version 2 one is submitted as it is raised, approved within
      -- its threshold derived from erp.approval_asked_nobody() or here by
      -- somebody the chain asked, and posted by the approval. The post is
      -- the line routine's on either version: the move is refused over stock
      -- nothing has written (20260928000000), so it is never a button.
      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'routine', 'erp.post_adjustment_lines(uuid,timestamp with time zone,date)'),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),
      ('stock_adjustment',   'submit',                 'screen', ''),
      ('stock_adjustment',   'reject',                 'screen', ''),
      ('stock_adjustment',   'approve_within_threshold', 'routine', 'erp.approve_adjustment_within_threshold(uuid)'),
      ('stock_adjustment',   'approve_with_count',     'routine', 'erp.raise_count_adjustment(uuid)'),
      ('stock_adjustment',   'cancel_approved',        'screen', ''),

      -- ── The count sheet (20260927100000) ──────────────────────────────────
      -- Issued by the raise that opens it, once every place is on it; closed
      -- by the last of its counts to be posted or cancelled, derived from
      -- erp.count_sheet_is_finished() whatever permission the organisation
      -- puts on the move. Neither is a button.
      ('count_sheet',        'issue',                  'routine', 'erp.raise_count_tasks(text)'),
      ('count_sheet',        'close',                  'routine', 'erp.close_count_sheet_when_finished(uuid)'),

      -- ── The cash receipt (20260930000000) ─────────────────────────────────
      -- Opened by the cash route that applies it and posted by that route once
      -- its lines total what its journals banked, derived from
      -- erp.cash_document_is_applied(). Not a button: refused by hand.
      ('cash_receipt',       'post',                   'routine', 'erp.post_cash_document(uuid)'),

      -- ── The supplier payment (20260930200000) ─────────────────────────────
      -- Opened by the payment run that pays it and posted by that run once
      -- its lines total what its journals paid, derived from
      -- erp.cash_document_is_applied(). Not a button: refused by hand.
      ('cash_payment',       'post',                   'routine', 'erp.post_cash_document(uuid)'),

      -- ── The VAT return (20261001100000) ───────────────────────────────────
      -- Opened and finalised in one press by the routine that computes its
      -- period's boxes, derived from erp.vat_return_is_computed(). Not a
      -- button: refused by hand.
      ('vat_return',         'finalise',               'routine', 'erp.finalise_vat_return(uuid,date)'),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which only the inventory
      -- installer ships since 20260928200000 (D8). None of them is left to a
      -- door, so the document page draws every move each one declares. An
      -- organisation that applied the pack before then keeps them.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
   -- Version 1 of the transfer order's moves that version 2 does not declare
   -- are kept only while a version in use declares them (20260928200000): an
   -- organisation still on version 1, or a transfer still on it. Once none is,
   -- the rows go, and the register reads as version 2's alone.
   -- And version 1 of the stock adjustment's one move version 2 does not
   -- declare, the same way (20260928500000).
   where not ((x.machine_code = 'transfer_order'
               and x.transition_code in ('approved', 'closed',
                                         'draft_to_discrepancy', 'approved_to_discrepancy', 'issued_to_discrepancy',
                                         'in_transit_to_discrepancy', 'received_to_discrepancy', 'discrepancy_to_received',
                                         'draft_to_cancelled', 'approved_to_cancelled', 'issued_to_cancelled',
                                         'in_transit_to_cancelled', 'received_to_cancelled'))
              or (x.machine_code = 'stock_adjustment'
                  and x.transition_code = 'approved_to_cancelled'))
      or erp.transition_in_use(x.machine_code, x.transition_code)
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- F1. The proof: erp_test.vat_obligation_suite
--
-- One organisation configured from now on, so it is on tax version 2, whose
-- company is registered for VAT from the first day of the quarter before
-- last: two quarters that have ended, and this one, open.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.vat_obligation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant integer := 17;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  s_ware   uuid := gen_random_uuid();
  s_read   uuid := gen_random_uuid();
  v_step   text := 'provisioning';
  v_state  text;
  rb       record;
  res      jsonb;
  res2     jsonb;
  bx       record;
  v_entity uuid; v_ccy char(3); v_site uuid; v_item uuid; v_cust uuid;
  v_inv_a  uuid; v_inv_b uuid; v_inv_c uuid;
  v_ret1   uuid; v_ret2 uuid; v_draft uuid;
  v_today  date := current_date;
  v_q_from date := date_trunc('quarter', current_date)::date;
  v_q_to   date := (date_trunc('quarter', current_date) + interval '3 months')::date - 1;
  v_pq_from date := (date_trunc('quarter', current_date) - interval '3 months')::date;
  v_pq_to  date := date_trunc('quarter', current_date)::date - 1;
  v_ppq_from date := (date_trunc('quarter', current_date) - interval '6 months')::date;
  v_ppq_to date := (date_trunc('quarter', current_date) - interval '3 months')::date - 1;
  v_reg_from date;
  v_n integer; v_n2 integer; v_m0 numeric; v_m1 numeric;
  v_ends text; v_ends2 text; v_ends3 text; v_ends4 text; v_rows text;
  v_err text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text; v_hint text;
  v_planned text;
begin
  begin
    v_step := 'an organisation configured as the demonstration is, with a reader and a warehouse seat';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzvo-' || v_tag, 'VAT Obligation Suite',
      'admin@zzvo-' || v_tag || '.test', 'VAT Obligation Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzvo-' || v_tag || '.test'),
           (s_ware, 'ware@zzvo-' || v_tag || '.test'),
           (s_read, 'reader@zzvo-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    res := public.erp_invite_principal('ware@zzvo-' || v_tag || '.test', 'Wes Warehouse');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'warehouse', null, null, 'moves the stock');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('reader@zzvo-' || v_tag || '.test', 'Rhea Reader');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'observer', null, null, 'reads the books');
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its company, registered for VAT from the first day of the quarter before last';
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    select s.id into v_site from erp.site s where s.tenant_id = rb.tenant_id order by s.code limit 1;
    select i.id into v_item from erp.item i
     where i.tenant_id = rb.tenant_id and i.status = 'active'::erp.record_status order by i.code limit 1;
    insert into erp.party (tenant_id, code, name, country_code, status)
    values (rb.tenant_id, 'ZZVOCUST', 'VAT obligation suite customer', 'GB', 'active')
    returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    update erp.entity_tax_registration g set valid_from = v_ppq_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity and upper(g.registration_type) like 'VAT%';
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'the fixture''s company has % VAT registration(s), expected one', v_n;
    end if;

    v_step := 'a sale of five hundred pounds supplied in the quarter before last';
    v_inv_a := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVO-A', '{}'::jsonb);
    perform erp.add_document_line(v_inv_a, v_item, 1, 50000, 'supplied in the quarter before last');
    perform erp.set_invoice_tax_point(v_inv_a, v_ppq_to);
    perform erp.transition_document(v_inv_a, 'issue', 'vat obligation suite');

    -- ── 1. Declared, installed at tax version 2, and alive ──────────────────
    v_step := 'the type, its installer and the configuration checks';
    select count(*) into v_n from erp.dead_configuration_report() c
     where c.reference like '%vat\_return%' or c.detail like '%vat\_return%';
    select count(*) into v_n2 from erp.undriven_transition_report() c
     where c.reference like 'vat\_return%';
    v_cases := v_cases + 1;
    case_name := 'the VAT return is declared, installed with tax at version 2 from one helper of four items, driven by a routine, and nothing of it is dead configuration';
    passed := v_state is null
          and (select count(*) from erp_ref.module_upgrade_item ui
                 join jsonb_array_elements(erp.vat_return_pack_items()) i
                   on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
                  and i.value -> 'payload' = ui.payload
                where ui.install_code = 'tax' and ui.to_version = 2) = 4
          and (select mi.current_version from erp_ref.module_installer mi where mi.install_code = 'tax') = 2
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'tax') = 2
          and exists (select 1 from erp.document_type dt
                        join erp.numbering_rule nr on nr.id = dt.numbering_rule_id and nr.prefix = 'VAT-'
                       where dt.tenant_id = rb.tenant_id and dt.code = 'vat_return' and dt.status = 'active'
                         and dt.base_type_code = 'vat_return' and dt.state_machine_code = 'vat_return'
                         and dt.create_permission = 'finance.close_period'
                         and dt.stock_movement_type is null and dt.posting_rule_code is null)
          and exists (select 1 from jsonb_array_elements(erp.transition_driver_register()) x
                       where x ->> 'machine_code' = 'vat_return' and x ->> 'transition_code' = 'finalise'
                         and x ->> 'driver' = 'routine' and x ->> 'detail' = 'erp.finalise_vat_return(uuid,date)')
          and exists (select 1 from erp.config_object co
                       where co.tenant_id = rb.tenant_id and co.config_type_code = 'tax.vat_return'
                         and co.entity_id is null and co.status = 'active')
          and erp.vat_return_policy(v_entity)
              = '{"frequency": "quarterly", "stagger": 1, "scheme": "standard", "northern_ireland": false}'::jsonb
          and v_n = 0 and v_n2 = 0;
    detail := coalesce(v_state, format('%s dead, %s undriven; policy %s', v_n, v_n2, erp.vat_return_policy(v_entity)));
    return next;

    -- ── 2. The periods from a registration of 23 August ─────────────────────
    v_step := 'the registration moved to 23 August 2025, and read as of three days';
    select g.valid_from into v_reg_from from erp.entity_tax_registration g
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
    update erp.entity_tax_registration g set valid_from = date '2025-08-23'
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
    select string_agg(format('%s..%s due %s %s', o.period_start, o.period_end, o.due_on, o.status), '; ' order by o.period_end)
      into v_ends from erp.vat_obligations(v_entity, date '2025-10-15') o;
    select string_agg(o.status, ',' order by o.period_end) into v_ends2
      from erp.vat_obligations(v_entity, date '2025-11-07') o;
    select string_agg(o.status, ',' order by o.period_end) into v_ends3
      from erp.vat_obligations(v_entity, date '2025-11-08') o;
    update erp.entity_tax_registration g set valid_from = v_reg_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
    v_cases := v_cases + 1;
    case_name := 'a registration of 23 August on stagger 1 gives 23 August to 30 September and then October to December; the first is due on 7 November, and reads due on the day and overdue the day after';
    passed := v_state is null
          and v_ends = '2025-08-23..2025-09-30 due 2025-11-07 due; 2025-10-01..2025-12-31 due 2026-02-07 open'
          and v_ends2 = 'due,open'
          and v_ends3 = 'overdue,open';
    detail := coalesce(v_state, format('as of 15 October: %s; 7 November: %s; 8 November: %s', v_ends, v_ends2, v_ends3));
    return next;

    -- ── 3. Monthly, and staggers 2 and 3 ────────────────────────────────────
    v_step := 'the same registration read monthly and on each stagger, as of 15 March 2026';
    update erp.entity_tax_registration g set valid_from = date '2025-08-23'
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('frequency', 'monthly'),
                                 null, null, v_entity, null, 'the vat obligation suite returns monthly');
    select string_agg(o.period_end::text, ',' order by o.period_end) into v_ends
      from erp.vat_obligations(v_entity, date '2026-03-15') o;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('frequency', 'quarterly', 'stagger', 2),
                                 null, null, v_entity, null, 'the vat obligation suite, stagger 2');
    select string_agg(o.period_start::text || '..' || o.period_end::text, ',' order by o.period_end) into v_ends2
      from erp.vat_obligations(v_entity, date '2026-03-15') o;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('frequency', 'quarterly', 'stagger', 3),
                                 null, null, v_entity, null, 'the vat obligation suite, stagger 3');
    select string_agg(o.period_end::text, ',' order by o.period_end) into v_ends3
      from erp.vat_obligations(v_entity, date '2026-03-15') o;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('frequency', 'quarterly', 'stagger', 1),
                                 null, null, v_entity, null, 'the vat obligation suite, back to stagger 1');
    select string_agg(o.period_end::text, ',' order by o.period_end) into v_ends4
      from erp.vat_obligations(v_entity, date '2026-03-15') o;
    update erp.entity_tax_registration g set valid_from = v_reg_from
     where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
    v_cases := v_cases + 1;
    case_name := 'monthly returns end every month, stagger 2 ends in January, April, July and October, stagger 3 in February, May, August and November, and stagger 1 in the calendar quarters';
    passed := v_state is null
          and v_ends = '2025-08-31,2025-09-30,2025-10-31,2025-11-30,2025-12-31,2026-01-31,2026-02-28,2026-03-31'
          and v_ends2 = '2025-08-23..2025-10-31,2025-11-01..2026-01-31,2026-02-01..2026-04-30'
          and v_ends3 = '2025-08-31,2025-11-30,2026-02-28,2026-05-31'
          and v_ends4 = '2025-09-30,2025-12-31,2026-03-31';
    detail := coalesce(v_state, format('monthly %s; stagger 2 %s; stagger 3 %s; stagger 1 %s', v_ends, v_ends2, v_ends3, v_ends4));
    return next;

    -- ── 4. Refused out of order, before its end, and for no period ──────────
    v_step := 'finalising last quarter first, this quarter, and a day that ends no period';
    select string_agg(o.period_end::text || ' ' || o.status, ',' order by o.period_end) into v_rows
      from erp.vat_obligations(v_entity) o;
    begin
      perform public.erp_finalise_vat_return(v_entity, v_pq_to);
      v_err := 'finalised';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform public.erp_finalise_vat_return(v_entity, v_q_to);
      v_err2 := 'finalised';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to - 1);
      v_err3 := 'finalised';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    v_cases := v_cases + 1;
    case_name := 'the obligations are the two ended quarters and this one, and finalising the second before the first, the open one, or a day that ends no period is refused by name';
    passed := v_state is null
          and v_rows = format('%s %s,%s %s,%s open', v_ppq_to,
                              case when v_today > erp.vat_return_due_on(v_ppq_to) then 'overdue' else 'due' end,
                              v_pq_to,
                              case when v_today > erp.vat_return_due_on(v_pq_to) then 'overdue' else 'due' end,
                              v_q_to)
          and v_err like 'CLOVEERP_EARLIER_VAT_RETURN_OPEN:%'
          and v_err2 like 'CLOVEERP_VAT_PERIOD_NOT_ENDED:%'
          and v_err3 like 'CLOVEERP_NO_VAT_OBLIGATION:%'
          and not exists (select 1 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                           where d.tenant_id = rb.tenant_id and dt.base_type_code = 'vat_return');
    detail := coalesce(v_state, concat_ws(' / ', v_rows, v_err, v_err2, v_err3));
    return next;

    -- ── 5. A blocking exception refuses, naming the document ────────────────
    v_step := 'the sale''s determination edited after it posted';
    update erp.tax_determination set tax_minor = tax_minor + 1
     where id = (select td.id from erp.tax_determination td
                  where td.tenant_id = rb.tenant_id and td.document_id = v_inv_a order by td.id limit 1);
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err := 'finalised';
    exception when others then v_err := sqlerrm; end;
    update erp.tax_determination set tax_minor = tax_minor - 1
     where id = (select td.id from erp.tax_determination td
                  where td.tenant_id = rb.tenant_id and td.document_id = v_inv_a order by td.id limit 1);
    v_cases := v_cases + 1;
    case_name := 'tax determined on a sale that its journal did not carry refuses the return, naming the document, and opens nothing';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_RETURN_HAS_EXCEPTIONS:%'
          and strpos(v_err, (select d.document_number from erp.document d where d.id = v_inv_a)) > 0
          and not exists (select 1 from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                           where d.tenant_id = rb.tenant_id and dt.base_type_code = 'vat_return');
    detail := coalesce(v_state, left(v_err, 240));
    return next;

    -- ── 6. Flat rate, cash accounting and Northern Ireland ──────────────────
    v_step := 'the company set to each scheme the product does not compute';
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('scheme', 'flat_rate'),
                                 null, null, v_entity, null, 'the vat obligation suite, flat rate');
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err := 'finalised';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('scheme', 'cash'),
                                 null, null, v_entity, null, 'the vat obligation suite, cash accounting');
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err2 := 'finalised';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('scheme', 'standard', 'northern_ireland', true),
                                 null, null, v_entity, null, 'the vat obligation suite, Northern Ireland');
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err3 := 'finalised';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    perform erp.set_config_value('tax.vat_return', jsonb_build_object('scheme', 'standard', 'northern_ireland', false),
                                 null, null, v_entity, null, 'the vat obligation suite, back to standard in Great Britain');
    v_cases := v_cases + 1;
    case_name := 'a company on the flat rate or cash accounting scheme, or in Northern Ireland, is refused the return by name';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_SCHEME_NOT_BUILT:%flat_rate%'
          and v_err2 like 'CLOVEERP_VAT_SCHEME_NOT_BUILT:%cash%'
          and v_err3 like 'CLOVEERP_VAT_NORTHERN_IRELAND_NOT_BUILT:%';
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
    return next;

    -- ── 7. Finalised in one press ───────────────────────────────────────────
    v_step := 'the quarter before last finalised';
    select coalesce(sum(m.quantity), 0) into v_m0 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    res := public.erp_finalise_vat_return(v_entity, v_ppq_to);
    v_ret1 := (res ->> 'document_id')::uuid;
    select coalesce(sum(m.quantity), 0) into v_m1 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    select * into bx from erp.vat_return_boxes(v_entity, v_ppq_from, v_ppq_to);
    select string_agg(o.status || ' ' || coalesce(o.return_number, '-'), ',' order by o.period_end) into v_rows
      from erp.vat_obligations(v_entity) o;
    v_cases := v_cases + 1;
    case_name := 'finalising the quarter makes VAT-000001, finalised by the system with nobody pressing, dated its period end and due on its due date, whose frozen boxes are the nine boxes of the quarter';
    passed := v_state is null
          and res ->> 'document_number' = 'VAT-000001'
          and erp.object_current_state('document', v_ret1) = 'finalised'
          and (select l.guard_data #>> '{derived,fact}' from erp.state_transition_log l
                where l.tenant_id = rb.tenant_id and l.object_type = 'document' and l.object_id = v_ret1
                  and l.transition_code = 'finalise') = 'erp.vat_return_is_computed'
          and (select d.document_date = v_ppq_to and d.due_date = erp.vat_return_due_on(v_ppq_to)
                      and d.entity_id = v_entity and d.party_id is null
                      and d.our_reference = format('VAT %s–%s', v_ppq_from, v_ppq_to)
                      and d.attributes #> '{vat_return,boxes}' = res -> 'boxes'
                      and d.attributes #>> '{vat_return,vrn}' is not null
                      and (d.attributes #>> '{vat_return,entries}')::bigint = bx.entries
                      and d.attributes #>> '{vat_return,entries_digest}' ~ '^[0-9a-f]{32}$'
                 from erp.document d where d.id = v_ret1)
          and (res #>> '{boxes,box1_minor}')::bigint = bx.box1_minor and bx.box1_minor = 10000
          and (res #>> '{boxes,box2_minor}')::bigint = bx.box2_minor
          and (res #>> '{boxes,box3_minor}')::bigint = bx.box3_minor
          and (res #>> '{boxes,box4_minor}')::bigint = bx.box4_minor
          and (res #>> '{boxes,box5_minor}')::bigint = bx.box5_minor
          and res #>> '{boxes,box5_is}' = bx.box5_is
          and (res #>> '{boxes,box6_pounds}')::bigint = bx.box6_pounds and bx.box6_pounds = 500
          and (res #>> '{boxes,box7_pounds}')::bigint = bx.box7_pounds
          and (res #>> '{boxes,box8_pounds}')::bigint = 0 and (res #>> '{boxes,box9_pounds}')::bigint = 0
          and (res #>> '{carried_forward,entries}')::integer = 0
          and v_rows like 'finalised VAT-000001,%'
          and (select count(*) from erp.event e
                where e.tenant_id = rb.tenant_id and e.aggregate_id = v_ret1
                  and e.event_type = 'vat_return.finalised') = 1
          and v_m1 = v_m0;
    detail := coalesce(v_state, format('%s; meter %s then %s; obligations %s',
                                       left(coalesce(res::text, 'nothing'), 300), v_m0, v_m1, v_rows));
    return next;

    -- ── 8. Twice is refused ─────────────────────────────────────────────────
    v_step := 'the same quarter finalised again';
    begin
      perform public.erp_finalise_vat_return(v_entity, v_ppq_to);
      v_err := 'finalised';
    exception when others then v_err := left(sqlerrm, 160); end;
    v_cases := v_cases + 1;
    case_name := 'a period is finalised once, and a second press is refused by name naming the return';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_RETURN_ALREADY_FINALISED:%VAT-000001%'
          and (select count(*) from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                where d.tenant_id = rb.tenant_id and dt.base_type_code = 'vat_return') = 1;
    detail := coalesce(v_state, v_err);
    return next;

    -- ── 9. Frozen ───────────────────────────────────────────────────────────
    v_step := 'the finalised return edited, by its administrator';
    begin
      update erp.document set attributes = jsonb_set(attributes, '{vat_return,boxes,box1_minor}', '0'::jsonb)
       where id = v_ret1;
      v_err := 'edited';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      update erp.document set document_date = v_today where id = v_ret1;
      v_err2 := 'redated';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      update erp.document set is_cancelled = true, cancelled_at = now(), cancellation_reason = 'wrong'
       where id = v_ret1;
      v_err3 := 'cancelled';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    begin
      update erp.document set attributes = attributes - 'vat_return' where id = v_ret1;
      v_err4 := 'stripped';
    exception when others then v_err4 := left(sqlerrm, 160); end;
    begin
      update erp.document set their_reference = 'a reference nobody gave' where id = v_ret1;
      v_err5 := 'referenced';
    exception when others then v_err5 := left(sqlerrm, 160); end;
    update erp.document set notes = 'Filed through bridging software, receipt 123' where id = v_ret1;
    v_cases := v_cases + 1;
    case_name := 'a finalised return''s boxes, date, references and cancellation cannot be changed, even by an administrator, and its notes can take a filing reference';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_RETURN_IS_FINAL:%'
          and v_err2 like 'CLOVEERP_VAT_RETURN_IS_FINAL:%'
          and v_err3 like 'CLOVEERP_VAT_RETURN_IS_FINAL:%'
          and v_err4 like 'CLOVEERP_VAT_RETURN_IS_FINAL:%'
          and v_err5 like 'CLOVEERP_VAT_RETURN_IS_FINAL:%'
          and (select d.notes like 'Filed through%' and not d.is_cancelled and d.document_date = v_ppq_to
                      and (d.attributes #>> '{vat_return,boxes,box1_minor}')::bigint = 10000
                 from erp.document d where d.id = v_ret1);
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5));
    return next;

    -- ── 10. Nothing by hand ─────────────────────────────────────────────────
    -- In a block of its own that is undone, so the draft it opens past the
    -- doors takes no number from the returns the next cases make.
    v_step := 'a return opened, written and finalised by hand';
    begin
      begin
        perform public.erp_create_document('vat_return', null, null, 'by hand', null, v_entity, null, null);
        v_err := 'opened';
      exception when others then v_err := left(sqlerrm, 160); end;
      begin
        perform erp.create_document_full('vat_return', null, null, 'by hand', null, null, '[]'::jsonb, null);
        v_err2 := 'opened';
      exception when others then v_err2 := left(sqlerrm, 160); end;
      v_draft := erp.open_document('vat_return', null, v_entity, null, 'by hand', null, v_ccy);
      begin
        perform erp.add_document_line(v_draft, v_item, 1, 100, 'by hand');
        v_err3 := 'added';
      exception when others then v_err3 := left(sqlerrm, 160); end;
      begin
        insert into erp.document_line (tenant_id, document_id, line_no, item_id, description, quantity,
                                       unit_price_minor, net_minor, currency)
        values (rb.tenant_id, v_draft, 10, null, 'past the door', 1, 100, 100, v_ccy);
        v_err4 := 'inserted';
      exception when others then v_err4 := left(sqlerrm, 160); end;
      begin
        perform erp.transition_document(v_draft, 'finalise', 'by hand');
        v_err5 := 'finalised';
      exception when others then v_err5 := left(sqlerrm, 160); end;
      begin
        -- Its attributes written by hand to look computed: the move still
        -- names no fact, because nobody asked for it through the routine.
        update erp.document set attributes = (select d.attributes from erp.document d where d.id = v_ret1)
         where id = v_draft;
        perform erp.transition_document(v_draft, 'finalise', 'by hand, dressed as computed');
        v_err6 := 'finalised';
      exception when others then v_err6 := left(sqlerrm, 160); end;
      raise exception 'CLOVEERP_BY_HAND_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_BY_HAND_ROLLED_BACK' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'opening a return, adding a line to one, or finalising one by hand is refused by name, to an administrator, even a draft dressed as computed';
    passed := v_state is null
          and v_err like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and v_err2 like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and v_err3 like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and v_err4 like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and v_err5 like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and v_err6 like 'CLOVEERP_VAT_RETURN_IS_FINALISED_FROM_ITS_PERIOD:%'
          and (select count(*) from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                where d.tenant_id = rb.tenant_id and dt.base_type_code = 'vat_return') = 1;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_err6));
    return next;

    -- ── 11. The reader, the warehouse, and the preview ──────────────────────
    v_step := 'a late sale into the finalised quarter and a sale of last quarter, read by a reader of the books';
    v_inv_b := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVO-B', '{}'::jsonb);
    perform erp.add_document_line(v_inv_b, v_item, 1, 20000, 'supplied in the finalised quarter, invoiced late');
    perform erp.set_invoice_tax_point(v_inv_b, v_ppq_to);
    perform erp.transition_document(v_inv_b, 'issue', 'vat obligation suite');
    v_inv_c := erp.create_document('sales_invoice', v_entity, v_site, v_cust, v_today, v_ccy, 'ZZVO-C', '{}'::jsonb);
    perform erp.add_document_line(v_inv_c, v_item, 1, 30050, 'supplied last quarter, and fifty pence');
    perform erp.set_invoice_tax_point(v_inv_c, v_pq_to);
    perform erp.transition_document(v_inv_c, 'issue', 'vat obligation suite');
    perform set_config('request.jwt.claims', json_build_object('sub', s_ware)::text, true);
    begin
      perform public.erp_vat_obligations(null);
      v_err := 'answered';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform set_config('request.jwt.claims', json_build_object('sub', s_read)::text, true);
    res := public.erp_vat_obligations(v_entity);
    -- This quarter, which has not ended: the permission is asked before
    -- anything about the period is, so the refusal says nothing of it.
    begin
      perform public.erp_finalise_vat_return(v_entity, v_q_to);
      v_err2 := 'finalised';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'a reader of the books sees the periods, the finalised one''s frozen boxes and the next one''s preview with what it carries forward, and cannot finalise; a warehouse seat sees none';
    passed := v_state is null
          and v_err like 'CLOVEERP_PERMISSION_DENIED: finance.read%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED: finance.close_period%'
          and jsonb_array_length(res) = 3
          and res -> 0 ->> 'status' = 'finalised' and res -> 0 ->> 'return_number' = 'VAT-000001'
          and (res -> 0 #>> '{boxes,box1_minor}')::bigint = 10000
          and (res -> 1 ->> 'is_next')::boolean
          and (res -> 1 #>> '{boxes,box1_minor}')::bigint = 10010
          and (res -> 1 #>> '{carried_forward,entries}')::integer = 1
          and (res -> 1 #>> '{carried_forward,tax_minor}')::bigint = 4000
          and not (res -> 1 ? 'journal_ids')
          and res -> 2 ->> 'status' = 'open' and not (res -> 2 ->> 'is_next')::boolean
          and (select count(*) from erp.document d join erp.document_type dt on dt.id = d.document_type_id
                where d.tenant_id = rb.tenant_id and dt.base_type_code = 'vat_return') = 1;
    detail := coalesce(v_state, format('warehouse: %s; reader finalising: %s; reader sees %s', v_err, v_err2,
                                       left(coalesce(res::text, 'nothing'), 400)));
    return next;

    -- ── 12. A late entry carries forward, and is in neither twice ───────────
    v_step := 'last quarter finalised, with the late sale in it';
    select coalesce(sum(m.quantity), 0) into v_m0 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    res2 := public.erp_finalise_vat_return(v_entity, v_pq_to);
    v_ret2 := (res2 ->> 'document_id')::uuid;
    select coalesce(sum(m.quantity), 0) into v_m1 from erp_meta.usage_meter m
     where m.tenant_id = rb.tenant_id and m.meter_code = 'documents_posted';
    select * into bx from erp.vat_return_boxes(v_entity, v_ppq_from, v_pq_to);
    v_cases := v_cases + 1;
    case_name := 'a sale posted into a finalised quarter is in the next return''s boxes and its carried forward, the finalised return is unchanged, the two together are the half year once, and the billed meter does not move';
    passed := v_state is null
          and res2 ->> 'document_number' = 'VAT-000002'
          and (res2 #>> '{boxes,box1_minor}')::bigint = 10010
          -- Five hundred pounds and fifty pence, the pence dropped.
          and (res2 #>> '{boxes,box6_pounds}')::bigint = 500
          and (res2 #>> '{carried_forward,entries}')::integer = 1
          and (res2 #>> '{carried_forward,tax_minor}')::bigint = 4000
          and not (res2 #>> '{carried_forward,over_threshold}')::boolean
          and (select (d.attributes #>> '{vat_return,boxes,box1_minor}')::bigint from erp.document d where d.id = v_ret1) = 10000
          and (select (r1.attributes #>> '{vat_return,boxes,box1_minor}')::bigint
                    + (r2.attributes #>> '{vat_return,boxes,box1_minor}')::bigint
                 from erp.document r1, erp.document r2 where r1.id = v_ret1 and r2.id = v_ret2) = bx.box1_minor
          and bx.box1_minor = 20010
          and (select (r1.attributes #>> '{vat_return,boxes,box6_pounds}')::bigint
                    + (r2.attributes #>> '{vat_return,boxes,box6_pounds}')::bigint
                 from erp.document r1, erp.document r2 where r1.id = v_ret1 and r2.id = v_ret2) = bx.box6_pounds
          -- The late sale's journal is the second return's and not the first's,
          -- and nothing is in both.
          and exists (select 1 from erp.journal j, erp.document r2
                       where j.document_id = v_inv_b and r2.id = v_ret2
                         and r2.attributes #> '{vat_return,journal_ids}' ? j.id::text)
          and not exists (select 1 from erp.journal j, erp.document r1
                           where j.document_id = v_inv_b and r1.id = v_ret1
                             and r1.attributes #> '{vat_return,journal_ids}' ? j.id::text)
          and not exists (select 1 from erp.document r1, erp.document r2,
                                        jsonb_array_elements_text(r1.attributes #> '{vat_return,journal_ids}') a
                           where r1.id = v_ret1 and r2.id = v_ret2
                             and r2.attributes #> '{vat_return,journal_ids}' ? a)
          and (select r.box1_minor from erp.vat_return_boxes(v_entity, v_pq_from, v_pq_to) r) = 6010
          and v_m1 = v_m0;
    detail := coalesce(v_state, format('%s; half year box 1 %s; meter %s then %s',
                                       left(coalesce(res2::text, 'nothing'), 300), bx.box1_minor, v_m0, v_m1));
    return next;

    -- ── 13. An organisation on tax version 1, and its upgrade ───────────────
    v_step := 'putting the organisation back to tax version 1';
    update erp.document_type set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'vat_return';
    update erp.state_machine set status = 'inactive'
     where tenant_id = rb.tenant_id and code = 'vat_return';
    update erp.module_installation i set installer_version = 1
     where i.tenant_id = rb.tenant_id and i.install_code = 'tax';
    select count(*) into v_n from erp.vat_obligations(v_entity);
    begin
      perform public.erp_finalise_vat_return(v_entity, v_q_to);
      v_err := 'finalised';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_err := left(sqlerrm, 160);
    end;
    v_step := 'upgrading tax to version 2';
    select string_agg(p.object_kind || ' ' || p.object_key, ', ' order by p.seq) into v_planned
      from erp.plan_module_upgrade('tax') p;
    res := erp.upgrade_module_configuration('tax');
    begin
      perform public.erp_finalise_vat_return(v_entity, v_q_to);
      v_err2 := 'finalised';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    v_cases := v_cases + 1;
    case_name := 'an organisation still on tax version 1 has its obligations and cannot finalise, the refusal naming Upgrade; the upgrade installs the return';
    passed := v_state is null
          and v_n = 3
          and v_err like 'CLOVEERP_VAT_RETURN_NOT_INSTALLED:%'
          and v_hint like 'Upgrade the tax module%'
          and strpos(coalesce(v_planned, ''), 'document_type vat_return') > 0
          and (res ->> 'to_version')::integer = 2 and (res ->> 'promoted')::boolean
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'tax') = 2
          and not exists (select 1 from erp.plan_module_upgrade('tax'))
          and v_err2 like 'CLOVEERP_VAT_PERIOD_NOT_ENDED:%';
    detail := coalesce(v_state, format('%s obligation(s); %s (%s); planned %s; then %s', v_n, v_err, v_hint,
                                       coalesce(v_planned, 'nothing'), v_err2));
    return next;

    -- ── 14. No registration, no obligation ──────────────────────────────────
    v_step := 'the company''s VAT registration taken away';
    begin
      delete from erp.entity_tax_registration g where g.tenant_id = rb.tenant_id and g.entity_id = v_entity;
      select count(*) into v_n from erp.vat_obligations(v_entity);
      select count(*) into v_n2 from erp.vat_obligations(null) o where o.entity_id = v_entity;
      begin
        perform public.erp_finalise_vat_return(v_entity, v_q_to);
        v_err := 'finalised';
      exception when others then v_err := left(sqlerrm, 160); end;
      raise exception 'CLOVEERP_REGISTRATION_ROLLED_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_REGISTRATION_ROLLED_BACK' then raise; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'a company with no VAT registration has no obligations, and nothing to finalise';
    passed := v_state is null and v_n = 0 and v_n2 = 0
          and v_err like 'CLOVEERP_NO_VAT_OBLIGATION:%'
          and (select count(*) from erp.vat_obligations(v_entity)) = 3;
    detail := coalesce(v_state, format('%s and %s obligation(s); %s', v_n, v_n2, v_err));
    return next;

    -- ── 15. Not reversed ────────────────────────────────────────────────────
    v_step := 'a return reversed';
    begin
      perform erp.reverse_document_posting(v_ret1, 'the return was wrong');
      v_err := 'reversed';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_err := left(sqlerrm, 160);
    end;
    v_cases := v_cases + 1;
    case_name := 'a return is not reversed, the refusal says an error is corrected on the next one, and the reversal register holds';
    passed := v_state is null
          and v_err like 'CLOVEERP_DOCUMENT_NOT_REVERSIBLE:%'
          and v_hint like 'A return posts nothing%'
          and (select r.route from erp.document_reversal_route() r where r.base_type_code = 'vat_return') = 'posts_nothing'
          and not exists (select 1 from erp.document_reversal_coverage_report());
    detail := coalesce(v_state, v_err || ' / ' || coalesce(v_hint, 'no hint'));
    return next;

    -- ── 16. The checks, with returns finalised ──────────────────────────────
    v_step := 'the configuration and ledger checks, with returns finalised';
    begin
      v_err := erp.assert_every_transition_is_driven();
      v_err := erp.assert_no_dead_configuration();
      v_err := erp.assert_every_posting_can_be_undone();
      v_err := erp_test.assert_no_state_side_doors();
      v_err := erp.assert_vat_agrees_with_ledger();
      v_err := erp.assert_document_create_permissions();
      v_err := 'passed';
    exception when others then v_err := 'refused: ' || left(sqlerrm, 200); end;
    v_cases := v_cases + 1;
    case_name := 'the driver register, dead configuration, reversal, side doors, create permissions and the VAT ledger agreement all pass with returns finalised';
    passed := v_state is null and v_err = 'passed';
    detail := coalesce(v_state, v_err);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 17. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzvo-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_ware, s_read));
  detail := coalesce(v_state, 'the organisation rolled back with its invoices, returns and settings');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_OBLIGATION_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.vat_obligation_suite() from public, anon;

comment on function erp_test.vat_obligation_suite() is
  'The VAT return''s periods and its one press (20261001100000): tax version 2 of four items, the '
  'periods from a registration on every frequency and stagger with their due dates and status, the '
  'refusals out of order, before the end, twice, over a disagreement and for the schemes not built, a '
  'return finalised by the system with its boxes frozen, nothing by hand, the reader and the '
  'preview, a late entry carried forward once, tax version 1 and its upgrade, no registration, and '
  'no reversal.';

create or replace function erp_test.assert_vat_obligation_suite()
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
    from erp_test.vat_obligation_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_VAT_OBLIGATION_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A VAT return would be made for the wrong period, from the wrong entries, or changed after it was final. Read the case that failed.';
  end if;
  if v_total <> 17 then
    raise exception 'CLOVEERP_VAT_OBLIGATION_SUITE_SHRANK: % case(s), expected 17', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat obligation: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_obligation_suite() from public, anon;

comment on function erp_test.assert_vat_obligation_suite() is
  'A company''s VAT periods are derived from its registration and setting, and each is finalised once, '
  'in order, in one press, with its boxes frozen and late entries carried forward (20261001100000).';

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
-- Every move every lifecycle declares still has something that fires it, a
-- type ships nothing dead, and every posting kind has a way back, in whatever
-- database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
select erp.assert_no_dead_configuration();
select erp.assert_every_posting_can_be_undone();
