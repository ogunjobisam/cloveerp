-- ─────────────────────────────────────────────────────────────────────────────
-- Specification v1.5 Part 22, D34: a refusal must always name the next action.
--
-- "Every refusal states what was refused, why in plain language, and what to
--  do about it. Why: this platform refuses by design, and a refusal a user
--  cannot act on is indistinguishable from a fault."
--
-- §21.1 says how: "Refusal messages resolve through the resource layer like
-- everything else, so an organisation can add its own local guidance to a
-- standard message."
--
-- A refusal here is a `raise exception 'ERPWARE_…'`. Two mechanisms carry the
-- next action to the person who was refused, and either satisfies D34:
--
--   1. The raise itself carries `using hint = …`, which the friendly-error
--      layer already shows as the next step.
--   2. The token is registered in erp_ref.refusal with what was refused, why,
--      and the next action — and the next action is also a resource key,
--      `refusal.<TOKEN>.next_action`, so it resolves through erp.text() and
--      erp_resources() with the organisation's own override on top. The
--      screens read it from the same dictionary as every other string.
--
-- D34 is universal, and the platform raises 600-odd distinct tokens, of which
-- 52 carried a hint before this migration. Registering next actions for all
-- of them is not one migration's work, and a register that claimed to be
-- complete when it was not would be exactly the fault D34 describes. So the
-- enforcement is scoped by a second register, erp_ref.refusal_scope: the
-- token families under D34 today. The assertion fails any in-scope refusal
-- that names no next action, any registered next action that is blank, and
-- any registered token that nothing raises; and its message reports the
-- whole platform's coverage so the number is visible on every CI run. The
-- scope starts with everything Part 17 raises, because that is what v1.5
-- added, and grows as families are registered.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── The register ─────────────────────────────────────────────────────────────

create table erp_ref.refusal (
  code           text primary key,
  refused        text not null,
  why            text not null,
  next_action    text not null,
  spec_reference text not null default 'v1.5 §21.1, Part 22 D34',
  registered_at  timestamptz not null default now(),
  constraint refusal_code_is_a_token check (code ~ '^ERPWARE_[A-Z0-9_]+%?$'),
  constraint refusal_names_the_next_action check (length(btrim(next_action)) > 0),
  constraint refusal_says_what check (length(btrim(refused)) > 0 and length(btrim(why)) > 0)
);

comment on table erp_ref.refusal is
  'v1.5 §21.1, D34. What each refusal refused, why in plain language, and the '
  'next action. next_action is mirrored into erp_ref.resource as '
  'refusal.<CODE>.next_action so an organisation can add its own guidance. A '
  'code ending in % is a family raised with a suffix, such as '
  'ERPWARE_QUOTE_IS_ACCEPTED.';

create table erp_ref.refusal_scope (
  token_prefix   text primary key,
  note           text not null,
  registered_at  timestamptz not null default now(),
  constraint refusal_scope_is_a_prefix check (token_prefix ~ '^ERPWARE_[A-Z0-9_]+$')
);

comment on table erp_ref.refusal_scope is
  'The token families D34 is enforced over today. A refusal whose token starts '
  'with a registered prefix must carry a hint or a register row; one outside '
  'the scope is reported, not failed. Add a prefix when its family is '
  'registered; the assertion then holds it.';

alter table erp_ref.refusal enable row level security;
alter table erp_ref.refusal force row level security;
alter table erp_ref.refusal_scope enable row level security;
alter table erp_ref.refusal_scope force row level security;

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp_ref','refusal','product_content','v1.5 §21.1, D34. What each refusal refused, why, and the next action.'),
  ('erp_ref','refusal_scope','product_content','D34. The token families the refusal assertion is enforced over.')
on conflict (schema_name, table_name) do nothing;

-- The resource key for one part of a refusal. Keys are lower case and a
-- family's trailing % is dropped: ERPWARE_QUOTE_IS_% mirrors as
-- refusal.erpware_quote_is_.next_action.
create or replace function erp_ref.refusal_key(p_code text, p_part text)
returns text
language sql
immutable
set search_path = ''
as $$ select 'refusal.' || replace(lower(p_code), '%', '') || '.' || p_part $$;

-- ── The report ───────────────────────────────────────────────────────────────

-- Every refusal the platform raises, read from the function bodies themselves
-- rather than from a list somebody maintains. Assertions and test suites are
-- excluded: what they raise is addressed to whoever builds the platform, and
-- the build is the person who acts on it.
create or replace function erp.refusal_report()
returns table(token text, raised_in integer, hinted boolean, registered boolean, in_scope boolean, named boolean, finding text)
language sql
stable
set search_path = ''
as $$
  with raised as (
    select m[1] as token,
           position('hint' in lower(m[2])) > 0 as hinted,
           n.nspname || '.' || p.proname as routine
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      -- A statement ends at the first semicolon that ends a line; a semicolon
      -- inside the message text is followed by more words, not a newline.
      -- Written without a non-greedy quantifier, because in a Postgres
      -- regular expression the first quantifier sets the whole pattern's
      -- greed and a greedy pattern would swallow every raise to the last.
      cross join lateral regexp_matches(p.prosrc, 'raise exception\s+E?''(ERPWARE_[A-Z0-9_%]+)((?:[^;]|;[ \t]*[^ \t\n])*);', 'gi') m
     where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'public')
       and p.proname not like 'assert\_%'
       and p.proname not like '%\_suite'
  ),
  per_token as (
    select r.token,
           count(*)::integer as raised_in,
           bool_and(r.hinted) as hinted
      from raised r
     group by r.token
  ),
  judged as (
    select t.token, t.raised_in, t.hinted,
           exists (select 1 from erp_ref.refusal f where f.code = t.token) as registered,
           exists (select 1 from erp_ref.refusal_scope s where t.token like s.token_prefix || '%') as in_scope
      from per_token t
  )
  select j.token, j.raised_in, j.hinted, j.registered, j.in_scope,
         (j.hinted or j.registered) as named,
         case when j.in_scope and not (j.hinted or j.registered)
              then 'an in-scope refusal names no next action: neither a hint on the raise nor a row in erp_ref.refusal'
              end as finding
    from judged j
  union all
  -- A registered token nothing raises is a stale row, and a stale register
  -- misleads the terminology screen that offers its keys for renaming.
  select f.code, 0, false, true,
         exists (select 1 from erp_ref.refusal_scope s where f.code like s.token_prefix || '%'),
         true,
         'a registered refusal is raised nowhere'
    from erp_ref.refusal f
   where not exists (select 1 from per_token t where t.token = f.code)
  union all
  -- The register mirrors into the resource layer; a row without its key is a
  -- next action no screen can resolve or an organisation override.
  select f.code, 0, false, true, true, true,
         'a registered refusal has no resource key for its next action'
    from erp_ref.refusal f
   where not exists (select 1 from erp_ref.resource r where r.locale = 'en' and r.key = erp_ref.refusal_key(f.code, 'next_action'))
  order by 7 nulls last, 1;
$$;

comment on function erp.refusal_report is
  'D34. Every ERPWARE_ token raised by a function in the product schemas, with '
  'whether the raise carries a hint, whether the token is registered, whether '
  'its family is under enforcement, and the finding when an in-scope refusal '
  'names no next action or a register row is stale or unmirrored.';

create or replace function erp.assert_refusals_name_next_action()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_findings text;
  v_count    integer;
  v_raised   integer;
  v_named    integer;
  v_scoped   integer;
begin
  select count(*), string_agg(format('  %s [%s]', r.finding, r.token), E'\n' order by r.token)
    into v_count, v_findings
    from erp.refusal_report() r
   where r.finding is not null;
  if v_count > 0 then
    raise exception E'ERPWARE_REFUSAL_WITHOUT_NEXT_ACTION: % finding(s)\n%', v_count, v_findings
      using errcode = 'P0001',
            hint = 'Add using hint = … to the raise, or register the token in erp_ref.refusal with its next action and mirror the resource key (see erp.register_refusal).';
  end if;
  select count(*), count(*) filter (where r.named), count(*) filter (where r.in_scope)
    into v_raised, v_named, v_scoped
    from erp.refusal_report() r
   where r.raised_in > 0;
  return format('refusals: %s raised, %s name a next action, %s in scope and all named', v_raised, v_named, v_scoped);
end;
$$;

comment on function erp.assert_refusals_name_next_action is
  'D34. Fails when an in-scope refusal names no next action, when a registered '
  'next action is blank or unmirrored, or when a registered token is raised '
  'nowhere. Reports the platform-wide coverage in its message so the number is '
  'seen on every run.';

-- ── The writer ───────────────────────────────────────────────────────────────

-- One call registers the row and mirrors its next action into the resource
-- layer, so the two cannot be written apart.
create or replace function erp.register_refusal(
  p_code text, p_refused text, p_why text, p_next_action text
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  insert into erp_ref.refusal (code, refused, why, next_action)
  values (p_code, p_refused, p_why, p_next_action)
  on conflict (code) do update set refused = excluded.refused, why = excluded.why, next_action = excluded.next_action;
  insert into erp_ref.resource (key, locale, value, description) values
    (erp_ref.refusal_key(p_code, 'refused'), 'en', p_refused, 'D34. What the refusal ' || p_code || ' refused.'),
    (erp_ref.refusal_key(p_code, 'why'), 'en', p_why, 'D34. Why ' || p_code || ' refuses, in plain language.'),
    (erp_ref.refusal_key(p_code, 'next_action'), 'en', p_next_action, 'D34. What to do about ' || p_code || '. An organisation may add its own guidance by overriding this key.')
  on conflict (key, locale) do update set value = excluded.value, description = excluded.description;
end;
$$;

-- ── The door ─────────────────────────────────────────────────────────────────

-- The register, resolved through the resource layer so an organisation's own
-- wording wins. The friendly-error layer reads the same keys from
-- erp_resources(); this door exists for the terminology and guidance screens
-- that list refusals as a set.
create or replace function public.erp_refusals(p_locale text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', f.code,
           'refused', erp.text(erp_ref.refusal_key(f.code, 'refused'), p_locale),
           'why', erp.text(erp_ref.refusal_key(f.code, 'why'), p_locale),
           'next_action', erp.text(erp_ref.refusal_key(f.code, 'next_action'), p_locale))
           order by f.code), '[]'::jsonb)
    from erp_ref.refusal f;
$$;

revoke all on function public.erp_refusals(text) from public, anon;
grant execute on function public.erp_refusals(text) to authenticated, service_role;

-- ── The scope: everything Part 17 raises ─────────────────────────────────────

insert into erp_ref.refusal_scope (token_prefix, note) values
  ('ERPWARE_AMENDMENT_', 'Part 17 §17.8 contract amendments, and §5.3 batch attribute amendments.'),
  ('ERPWARE_BAND_', 'Part 17 §17.6–17.7 volume and user bands, and Addendum B approval bands.'),
  ('ERPWARE_CONTRACT_', 'Part 17 §17.8–17.9 the contract record.'),
  ('ERPWARE_CURRENCY_NOT_ON_BOOK', 'Part 17 §17.6 rate cards.'),
  ('ERPWARE_DISCOUNT_OUT_OF_RANGE', 'Part 17 §17.7 the pricing builder.'),
  ('ERPWARE_DOCUMENT_IS_EMPTY', 'Part 17 §17.8 a contract document with no content.'),
  ('ERPWARE_FEATURE_ON_PLAN', 'Part 17 §17.7 a feature the plan already includes.'),
  ('ERPWARE_INVOICE_', 'Part 17 §17.10 the invoice schedule.'),
  ('ERPWARE_LEGISLATION_IS_NOT_PRICED', 'Part 17 §17.6 legislation packs at nil.'),
  ('ERPWARE_NEGATIVE_RATE', 'Part 17 §17.6 rate cards.'),
  ('ERPWARE_NON_RENEWAL_HAS_NO_NOTE', 'Part 17 §17.10 non-renewal.'),
  ('ERPWARE_NOT_A_PRICE_ITEM', 'Part 17 §17.6–17.7 price items.'),
  ('ERPWARE_NOT_THE_PLATFORM_ORGANISATION', 'Part 17 §17.5 the platform organisation.'),
  ('ERPWARE_NO_ENTITY', 'Part 17 §17.7 a quote opened in an organisation with no legal entity.'),
  ('ERPWARE_NO_PLATFORM_ORGANISATION', 'Part 17 §17.5 the platform organisation.'),
  ('ERPWARE_NO_RATE_ON_BOOK', 'Part 17 §17.7 a price item with no rate on the book.'),
  ('ERPWARE_PLATFORM_CANNOT_CONTRACT_WITH_ITSELF', 'Part 17 §17.8 the contract record.'),
  ('ERPWARE_QUOTE_', 'Part 17 §17.7 the quote and pricing builder.'),
  ('ERPWARE_RENEWAL_', 'Part 17 §17.10 renewals.'),
  ('ERPWARE_SIGNATURE_INCOMPLETE', 'Part 17 §17.8 signatures; §9.3.'),
  ('ERPWARE_UNKNOWN_AMENDMENT', 'Part 17 §17.8.'),
  ('ERPWARE_UNKNOWN_CONTRACT', 'Part 17 §17.8.'),
  ('ERPWARE_UNKNOWN_INVOICE', 'Part 17 §17.10.'),
  ('ERPWARE_UNKNOWN_LEGISLATION_PACK', 'Part 17 §17.6.'),
  ('ERPWARE_UNKNOWN_PRICE_BOOK', 'Part 17 §17.6.'),
  ('ERPWARE_UNKNOWN_PRICE_ITEM_KIND', 'Part 17 §17.6.'),
  ('ERPWARE_UNKNOWN_QUOTE', 'Part 17 §17.7.'),
  ('ERPWARE_UNKNOWN_QUOTE_LINE', 'Part 17 §17.7.'),
  ('ERPWARE_UNKNOWN_RENEWAL', 'Part 17 §17.10.'),
  ('ERPWARE_UNKNOWN_TERM', 'Part 17 §17.6 term kinds.'),
  ('ERPWARE_UNTRUSTED_SWEEP', 'Part 17 sweeps; refused to any session that does not already bypass row-level security.')
on conflict (token_prefix) do update set note = excluded.note;

-- ── The register: every Part 17 refusal, and the three the screens knew ──────

select erp.register_refusal('ERPWARE_AMENDMENT_ACTION_UNKNOWN',
  'An amendment named a feature action that is not add or remove.',
  'A feature change is one of two things, and an action the platform does not recognise cannot be provisioned.',
  'Use action "add" or "remove" for each feature in the amendment.');
select erp.register_refusal('ERPWARE_AMENDMENT_ALREADY_SIGNED',
  'Signing an amendment that is already signed.',
  'A signature is recorded once; a second one would change what was signed.',
  'Nothing to do. Draft a new amendment if the terms need to change again.');
select erp.register_refusal('ERPWARE_AMENDMENT_CHANGES_NOTHING',
  'Drafting an amendment with no change in it.',
  'An amendment is a change to the agreement; one that changes nothing cannot be signed or provisioned.',
  'State at least one change: plan, an entitlement band, a feature, the term end, the annual value, the renewal kind, the notice period or the uplift rule.');
select erp.register_refusal('ERPWARE_AMENDMENT_TERM_ENDS_BEFORE_IT_STARTS',
  'An amendment setting the term end before the current term starts.',
  'A term ends after it starts.',
  'Choose a term end after the current term start.');
select erp.register_refusal('ERPWARE_BAND_HAS_NO_CEILING',
  'A band price item without an upper bound.',
  'A band prices a range; without a ceiling it cannot be matched to usage or priced per unit.',
  'Give the band an upper bound.');
select erp.register_refusal('ERPWARE_BAND_WITHIN_PLAN',
  'Adding a band the plan already includes.',
  'A band on a quote raises the plan''s figure; one at or below it would charge for nothing.',
  'Choose a band above the plan''s own figure for that entitlement, or leave the plan''s figure as it is.');
select erp.register_refusal('ERPWARE_CONTRACT_ALREADY_SIGNED',
  'Signing a contract that is already signed.',
  'The signature is what brought the contract into force; a second signature would change what was signed.',
  'Nothing to do. Draft an amendment if the terms need to change.');
select erp.register_refusal('ERPWARE_CONTRACT_HAS_NO_ORDER_FORM',
  'Creating a contract from a quote with no order form.',
  'The order form is the document the customer signs; without it there is nothing to sign.',
  'Issue the quote so the order form renders, then create the contract.');
select erp.register_refusal('ERPWARE_CONTRACT_IN_FORCE',
  'Changing a contract in force directly.',
  'A contract in force changes by amendment, with a signature, or not at all.',
  'Draft an amendment with the change and have both parties sign it.');
select erp.register_refusal('ERPWARE_CONTRACT_NOT_IN_FORCE',
  'An action that needs a contract in force, on one that is not.',
  'Amendments, invoices and renewals belong to a contract that is active or terminating.',
  'Sign the contract first, or open the contract that is in force.');
select erp.register_refusal('ERPWARE_CONTRACT_TERMS_UNKNOWN',
  'A renewal kind or billing frequency the platform does not recognise.',
  'The contract''s terms drive the sweeps and the invoice schedule; an unknown term would drive nothing.',
  'Choose a renewal kind of automatic, by agreement or none, and a billing frequency of annual, quarterly or monthly.');
select erp.register_refusal('ERPWARE_CURRENCY_NOT_ON_BOOK',
  'A rate in a currency the price book does not carry.',
  'A price book names the currencies it prices in; a rate outside them cannot be quoted.',
  'Open a price book version that includes the currency, or set the rate in one it carries.');
select erp.register_refusal('ERPWARE_DISCOUNT_OUT_OF_RANGE',
  'A discount below zero or of 100% or more.',
  'A discount reduces a price; it cannot raise it or give the line away.',
  'Enter a discount between 0 and 99.99%.');
select erp.register_refusal('ERPWARE_DOCUMENT_IS_EMPTY',
  'Attaching a contract document with no content.',
  'A document is signed by its checksum; an empty one has nothing to sign.',
  'Attach the document''s content.');
select erp.register_refusal('ERPWARE_FEATURE_ON_PLAN',
  'Adding a feature the plan on the quote already includes.',
  'A feature add-on prices what the plan does not; one the plan includes would charge for nothing.',
  'Leave it off the quote; the plan already provides it.');
select erp.register_refusal('ERPWARE_INVOICE_NOT_ISSUED',
  'Recording payment against an invoice that has not been issued.',
  'Payment settles an issued invoice; a scheduled one has no amount reconciled yet.',
  'Issue the invoice first, then record the payment.');
select erp.register_refusal('ERPWARE_INVOICE_NOT_SCHEDULED',
  'Issuing an invoice that is not in the scheduled state.',
  'An invoice is issued once; issuing it again would reconcile the period twice.',
  'Nothing to do if it is already issued or paid. If it was cancelled, generate the schedule again.');
select erp.register_refusal('ERPWARE_LEGISLATION_IS_NOT_PRICED',
  'A non-nil rate on a legislation pack.',
  'Legislation packs are priced at nil by default (§17.6): a jurisdiction is not a product.',
  'Set the rate to zero, or price the plan rather than the pack.');
select erp.register_refusal('ERPWARE_NEGATIVE_RATE',
  'A rate below zero.',
  'A rate is what the platform charges; a negative one is a discount, which is a different thing with its own approval.',
  'Enter a rate of zero or more; apply a discount on the quote line instead.');
select erp.register_refusal('ERPWARE_NON_RENEWAL_HAS_NO_NOTE',
  'Recording a non-renewal without a note.',
  'Why an organisation did not renew is the most useful thing the platform can know about it.',
  'Say who declined and why.');
select erp.register_refusal('ERPWARE_NOT_A_PRICE_ITEM',
  'A quote line naming a product that is not a price item.',
  'A quote is assembled from the price book, not from the product catalogue at large.',
  'Choose a price item, or register the product as one on the price book screen.');
select erp.register_refusal('ERPWARE_NOT_THE_PLATFORM_ORGANISATION',
  'A commercial action from an organisation that is not the platform''s.',
  'The price book, quotes and contracts belong to the one organisation a platform owner designates as the platform itself.',
  'Switch to the platform organisation, or ask a platform owner to designate one.');
select erp.register_refusal('ERPWARE_NO_ENTITY',
  'Opening a quote in an organisation with no legal entity.',
  'A quotation is issued by a legal entity; without one there is nobody to quote from.',
  'Create the organisation''s legal entity under Administration, then open the quote.');
select erp.register_refusal('ERPWARE_NO_PLATFORM_ORGANISATION',
  'A commercial action before a platform organisation is designated.',
  'The platform runs its own commercial process on its own primitives (D37); until an organisation is the platform, there is nowhere to run it.',
  'A platform owner designates the platform organisation on the console''s Contracts view.');
select erp.register_refusal('ERPWARE_NO_RATE_ON_BOOK',
  'A quote line for a price item with no rate on the book in that currency and term.',
  'A quote prices from the rate card; a line with no rate would be a number somebody typed.',
  'Set the rate for the price item on the price book in the quote''s currency and term.');
select erp.register_refusal('ERPWARE_PLATFORM_CANNOT_CONTRACT_WITH_ITSELF',
  'A contract whose customer is the platform organisation.',
  'A contract has two parties.',
  'Choose the customer organisation.');
select erp.register_refusal('ERPWARE_QUOTE_ALREADY_SUPERSEDED',
  'Revising a quote version that a later version already supersedes.',
  'Every version is retained and each is superseded once, so the chain stays a chain.',
  'Open the latest version and revise that.');
select erp.register_refusal('ERPWARE_QUOTE_EXPIRED',
  'Issuing a quote past its validity date.',
  'An order form is an offer; one past its date would be an offer nobody made.',
  'Revise the quote; the next version takes a new validity date.');
select erp.register_refusal('ERPWARE_QUOTE_HAS_A_PLAN',
  'Adding a second plan to a quote.',
  'A quote carries one plan; the bands and features on it are priced against that plan.',
  'Remove the existing plan line first, or open a separate quote.');
select erp.register_refusal('ERPWARE_QUOTE_HAS_NO_ORDER_FORM',
  'Reading an order form from a quote that has not been issued.',
  'The order form is the quote rendered at issue; before that there is nothing rendered.',
  'Issue the quote.');
select erp.register_refusal('ERPWARE_QUOTE_HAS_NO_PLAN',
  'A band, feature or submission on a quote with no plan line.',
  'Bands and features price against the plan; without one there is nothing to price against.',
  'Add the plan line first.');
select erp.register_refusal('ERPWARE_QUOTE_IS_%',
  'An action on a quote whose state does not permit it.',
  'A quote moves through draft, approval, issue and acceptance in order; the action asked for belongs to a different state.',
  'Read the quote''s state and the transitions it offers; revise it to start a new version.');
select erp.register_refusal('ERPWARE_QUOTE_IS_EMPTY',
  'Submitting a quote with no lines.',
  'A quote with nothing on it has no price, no margin and nothing to approve.',
  'Add at least the plan line.');
select erp.register_refusal('ERPWARE_QUOTE_NOT_ACCEPTED',
  'Creating a contract, or renewing, from a quote the customer has not accepted.',
  'A contract records what was agreed; a quote not yet accepted has not been.',
  'Record the customer''s acceptance on the quote first.');
select erp.register_refusal('ERPWARE_QUOTE_NEEDS_PREREQUISITE',
  'A feature add-on whose prerequisite is not on the quote or the plan.',
  'A feature that depends on another cannot be provisioned alone.',
  'Add the prerequisite feature to the quote, or choose a plan that includes it.');
select erp.register_refusal('ERPWARE_RENEWAL_NOT_PROPOSED',
  'Raising a renewal quote from a renewal that is not in the proposed state.',
  'A renewal is quoted once from its proposal; after that its quote is the record.',
  'Open the renewal quote already raised, or wait for the sweep to propose the next term.');
select erp.register_refusal('ERPWARE_RENEWAL_NOT_QUOTED',
  'Renewing a contract from a renewal that has no accepted quote.',
  'The renewal quote carries the uplifted terms the customer agreed to; without it there is nothing to sign.',
  'Raise the renewal quote from the proposal, have the customer accept it, then renew.');
select erp.register_refusal('ERPWARE_SIGNATURE_INCOMPLETE',
  'A signature without both signers and what signing means.',
  'A signature is meaning, signers and a checksum (§9.3); one missing any of them proves nothing.',
  'Name the customer signer, the platform signer and what the signature means.');
select erp.register_refusal('ERPWARE_UNKNOWN_AMENDMENT',
  'An amendment that does not exist.',
  'Nothing is recorded under that identifier.',
  'Open the contract and choose an amendment from its list.');
select erp.register_refusal('ERPWARE_UNKNOWN_CONTRACT',
  'A contract that does not exist.',
  'Nothing is recorded under that identifier.',
  'Choose a contract from the console''s Contracts view.');
select erp.register_refusal('ERPWARE_UNKNOWN_INVOICE',
  'An invoice that does not exist.',
  'Nothing is recorded under that identifier.',
  'Open the contract and choose an invoice from its schedule.');
select erp.register_refusal('ERPWARE_UNKNOWN_LEGISLATION_PACK',
  'A legislation pack price item naming a pack the platform does not ship.',
  'Legislation is data (D5); a pack that does not exist cannot be entitled.',
  'Choose a legislation pack from the ones the platform ships.');
select erp.register_refusal('ERPWARE_UNKNOWN_PRICE_BOOK',
  'A price book with no version in force.',
  'Rates are read from the version in force on the day; a book without one prices nothing.',
  'Open a price book version effective today, or choose one that is.');
select erp.register_refusal('ERPWARE_UNKNOWN_PRICE_ITEM_KIND',
  'A price item of a kind the platform does not recognise.',
  'Each kind is priced and provisioned differently; an unknown kind would be neither.',
  'Choose one of the price item kinds the price book screen offers.');
select erp.register_refusal('ERPWARE_UNKNOWN_QUOTE',
  'A quote that does not exist in this organisation.',
  'Nothing is recorded under that identifier.',
  'Choose a quote from the Quotes screen.');
select erp.register_refusal('ERPWARE_UNKNOWN_QUOTE_LINE',
  'A quote line that does not exist on this quote.',
  'Nothing is recorded under that identifier, or the line was removed.',
  'Refresh the quote and choose a line from it.');
select erp.register_refusal('ERPWARE_UNKNOWN_RENEWAL',
  'A renewal that does not exist.',
  'Nothing is recorded under that identifier.',
  'Choose a renewal from the Renewals list.');
select erp.register_refusal('ERPWARE_UNKNOWN_TERM',
  'A term kind the platform does not recognise.',
  'Rates are set per term; an unknown term has no rate card.',
  'Choose annual, multi-year or monthly.');
select erp.register_refusal('ERPWARE_UNTRUSTED_SWEEP',
  'Running a platform sweep from a session that does not bypass row-level security.',
  'A sweep reads every organisation; only the platform''s own scheduler and its operators may.',
  'Let the scheduled job run it, or run it from the platform console as an operator.');
-- Three older refusals the Part 17 prefixes also cover: registered rather
-- than carved out, because a family under D34 is under it whole.
select erp.register_refusal('ERPWARE_AMENDMENT_NEEDS_REASON',
  'Changing a batch attribute without a reason.',
  'A batch attribute is not changed silently; the reason is part of the batch''s record.',
  'Give the reason for the change.');
select erp.register_refusal('ERPWARE_BAND_UNRESOLVABLE',
  'An approval band that names no way to find an approver.',
  'A band routes a request to somebody; one that names no role, department, person or rule routes it nowhere.',
  'Name at least one of a role, a department, a named approver or a resolution rule on the band.');
select erp.register_refusal('ERPWARE_QUOTE_HAS_A_BAND',
  'Adding a second band for the same entitlement to a quote.',
  'A quote carries one band per entitlement; the contract provisions one limit, not two.',
  'Remove the existing band line for that entitlement first, or change its quantity.');
select erp.register_refusal('ERPWARE_PERMISSION_DENIED',
  'An action the account holds no permission for.',
  'Absence of a grant is a refusal, not a default.',
  'An administrator can grant the missing permission on the Permissions screen.');
select erp.register_refusal('ERPWARE_PERIOD_CLOSED',
  'A posting into a closed accounting period.',
  'A closed period''s figures were reported; a posting into it would change what was reported.',
  'Reopen the period, or post the entry into an open one.');

-- ── Registration: the decision, its check, the diagnostic ────────────────────

insert into erp_ref.product_decision (code, seq, title, decision, rationale, cost, spec_reference) values
  ('D34', 34, 'A refusal must always name the next action',
   'Every refusal states what was refused, why in plain language, and what to do about it. A raise carries the next action as its hint, or the token is registered with one that resolves through the resource layer.',
   'This platform refuses by design, and a refusal a user cannot act on is indistinguishable from a fault.',
   'Enforcement is scoped by erp_ref.refusal_scope and grows family by family; the assertion reports the platform-wide coverage on every run so the gap is visible rather than assumed closed.',
   'v1.5 §21.1, Part 22 D34')
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost, spec_reference = excluded.spec_reference;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D34', 'erp', 'assert_refusals_name_next_action',
   'D34 says every refusal names the next action. The assertion reads every raise in the product schemas, fails an in-scope refusal with neither a hint nor a register row, a registered next action that is blank or unmirrored, and a registered token nothing raises; its message carries the platform-wide count.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('refusals', 'Refusals name the next action', 'assertion', 'platform',
   'erp', 'assert_refusals_name_next_action', '', 'refusal_report', '',
   'D34: every refusal under enforcement carries a hint or a registered next action that resolves through the resource layer; the register has no stale or unmirrored row. The message reports how many of the platform''s refusals name a next action.',
   true, 74)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function, detail_arguments = excluded.detail_arguments,
  blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.refusal_register_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_findings integer;
  v_named    integer;
  v_raised   integer;
  v_scoped   integer;
  v_json     jsonb;
begin
  select count(*) filter (where finding is not null),
         count(*) filter (where raised_in > 0 and named),
         count(*) filter (where raised_in > 0),
         count(*) filter (where raised_in > 0 and in_scope)
    into v_findings, v_named, v_raised, v_scoped
    from erp.refusal_report();

  return query select 'the report reads the raises from the function bodies, not from a list', v_raised > 500,
    format('%s distinct tokens raised', v_raised);
  return query select 'every in-scope refusal names a next action', v_findings = 0, format('%s finding(s)', v_findings);
  return query select 'the scope covers everything Part 17 raises',
    not exists (select 1 from erp.refusal_report() r
                 where r.raised_in > 0 and not r.in_scope
                   and r.token in ('ERPWARE_NOT_THE_PLATFORM_ORGANISATION', 'ERPWARE_QUOTE_IS_EMPTY', 'ERPWARE_RENEWAL_NOT_QUOTED', 'ERPWARE_INVOICE_NOT_SCHEDULED')),
    'the four sentinel tokens are in scope';
  return query select 'a hinted raise names its next action without a register row',
    exists (select 1 from erp.refusal_report() r where r.hinted and not r.registered and r.named),
    'the 52 hinted raises that predate the register count';
  return query select 'the assertion reports the coverage rather than claiming completeness',
    erp.assert_refusals_name_next_action() ~ '^refusals: \d+ raised, \d+ name a next action, \d+ in scope and all named$',
    erp.assert_refusals_name_next_action();
  return query select 'and the coverage is honest: fewer than every refusal names one today',
    v_named < v_raised and v_named >= v_scoped, format('%s of %s', v_named, v_raised);

  -- The register mirrors into the resource layer.
  return query select 'every registered next action is a resource key an organisation can override',
    not exists (select 1 from erp_ref.refusal f
                 where not exists (select 1 from erp_ref.resource r where r.locale = 'en' and r.key = erp_ref.refusal_key(f.code, 'next_action'))),
    'refusal.<CODE>.next_action';
  v_json := public.erp_refusals('en');
  return query select 'the door returns the register resolved through the resource layer',
    jsonb_array_length(v_json) = (select count(*) from erp_ref.refusal)
    and exists (select 1 from jsonb_array_elements(v_json) x
                 where x ->> 'code' = 'ERPWARE_QUOTE_NOT_ACCEPTED'
                   and x ->> 'next_action' = 'Record the customer''s acceptance on the quote first.'),
    'erp_refusals()';

  -- A stale row is a finding: register a token nothing raises, inside a
  -- savepoint so the suite leaves the register as it found it.
  begin
    perform erp.register_refusal('ERPWARE_NOBODY_RAISES_THIS', 'a test', 'a test', 'a test');
    return query select 'a registered token nothing raises is a finding',
      exists (select 1 from erp.refusal_report() r where r.token = 'ERPWARE_NOBODY_RAISES_THIS' and r.finding like 'a registered refusal is raised nowhere%'),
      'stale rows mislead the terminology screen';
    raise exception 'ERPWARE_TEST_ROLLBACK' using errcode = 'P0001';
  exception when others then
    if sqlerrm not like 'ERPWARE_TEST_ROLLBACK%' then raise; end if;
  end;
  return query select 'and the savepoint left the register as it was',
    not exists (select 1 from erp_ref.refusal where code = 'ERPWARE_NOBODY_RAISES_THIS'), 'rolled back';

  -- A blank next action cannot be registered at all.
  begin
    perform erp.register_refusal('ERPWARE_QUOTE_IS_EMPTY', 'a test', 'a test', '   ');
    return query select 'a blank next action is refused by the register itself', false, 'the check constraint did not fire';
  exception when check_violation then
    return query select 'a blank next action is refused by the register itself', true, sqlerrm;
  end;

  -- D34 is bound.
  return query select 'D34 is registered with this assertion as its check',
    exists (select 1 from erp_ref.product_decision_check where decision_code = 'D34' and routine_name = 'assert_refusals_name_next_action'),
    'erp_ref.product_decision_check';
end;
$$;

create or replace function erp_test.assert_refusal_register_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _refusal_register_result on commit drop as
    select * from erp_test.refusal_register_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _refusal_register_result;
  drop table _refusal_register_result;
  if v_passed < v_total then
    raise exception E'ERPWARE_REFUSAL_REGISTER_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('refusal register: %s/%s', v_passed, v_total);
end;
$$;

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_refusals_name_next_action();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
