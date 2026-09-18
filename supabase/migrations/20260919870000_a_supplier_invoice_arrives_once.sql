set lock_timeout = '30s';

-- =============================================================================
-- 20260919870000  A supplier invoice arrives once
-- -----------------------------------------------------------------------------
-- What was checked first, because the claim was a claim and not a fact.
--
--   Where the supplier's own number is kept.  erp.document.their_reference,
--   laid down with the spine in 0025_b7_document_spine.sql and never moved.
--   The procurement screen's "Bill a receipt" form types into it under the
--   label "Supplier's invoice number", through public.erp_bill_from_receipt()
--   into erp.bill_from_receipt() into erp.open_document(). It is the right
--   column and there is no other.
--
--   What refuses a second copy of it today.  Nothing. erp.document carries
--   unique (tenant_id, document_type_id, document_number) — OUR number, taken
--   from a locked numbering rule — and four indexes for reading, none of them
--   unique and none of them over their_reference. No trigger on erp.document
--   looks at it: t_document_order_behaviour guards the order behaviour,
--   t_document_no_delete refuses a delete. erp.bill_from_receipt() refuses a
--   second bill against the same RECEIPT with CLOVEERP_ALREADY_BILLED, which
--   is a different question: the same invoice arriving twice on paper, against
--   two receipts or against none, walks straight through it.
--
--   What reports one.  Nothing. their_reference appears in output templates,
--   in the demonstration seeder and in erp.document_view. No report, no
--   diagnostic and no assertion counts two documents that share it.
--
-- So the claim holds. An invoice can be entered, approved and paid twice, and
-- paying a supplier twice is the commonest loss in accounts payable.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is done here
--
--   1. erp.document gains supplier_reference_key: the supplier's number as it
--      is compared, or null when the row is not a supplier bill that has one.
--      A partial unique index cannot join to erp.document_type to ask what a
--      document is, and a predicate must be immutable, so the question is
--      answered once on the way in and the index reads the answer.
--
--   2. erp.supplier_invoice_reference_key() is that question, in one place:
--      a live supplier invoice, with a party, with a reference that is not
--      blank. Anything else keys to null and the index ignores it.
--
--   3. A guard on erp.document sets the key and refuses a second document that
--      would carry it, naming the document that already holds it and what to
--      do. A bare 23505 tells an accounts clerk nothing.
--
--   4. The partial unique index, which is what actually holds under two
--      clerks typing the same invoice at the same moment. The guard reads
--      before it writes and two concurrent readers both find nothing.
--
--   5. A sweep of what is already there, then the backfill. In that order and
--      never the other way about: the index is created while every key is
--      still null, so it builds on any database whatever its history holds,
--      and the backfill then claims the key for the first document of each
--      group and leaves the later copies keyed null and named in a report.
--      Nothing is cancelled, renamed or merged — a migration guessing at an
--      accounts-payable duplicate is worse than the duplicate.
--
--   6. erp.supplier_invoice_duplicates() is that report, re-runnable.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What the key deliberately does not cover
--
--   Cancelled documents.  A bill raised in error and cancelled must give its
--   number back, or the correction cannot be entered.
--
--   Blank references.  Two bills entered with nothing in the box are two
--   bills, not one entered twice. Null keys, and a unique index ignores nulls.
--
--   Credit notes.  A supplier's credit note commonly quotes the number of the
--   invoice it credits, and refusing that would refuse the correction as well
--   as the duplicate. purchase_credit_note is built on base type
--   return_to_supplier and erp.raise_supplier_credit_note() puts OUR receipt
--   number in their_reference anyway, so it is outside the key twice over.
--
--   The customer side.  A sales invoice's own number is already unique:
--   erp.document's unique (tenant_id, document_type_id, document_number) over
--   a number taken from a locked erp.numbering_rule. their_reference on a
--   sales document is the CUSTOMER's order number, and one purchase order
--   properly covers many call-offs, deliveries and invoices — so uniqueness
--   there would refuse ordinary trade. Nothing is changed on that side, and
--   the suite below proves it stayed unchanged rather than leaving it to
--   inspection.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The key, and the question behind it
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.document
  add column if not exists supplier_reference_key text;

comment on column erp.document.supplier_reference_key is
  'The supplier''s own invoice number as it is compared — trimmed and upper-'
  'cased — on a live supplier bill that names a party and carries one; null on '
  'everything else, including a cancelled bill and a blank reference, so the '
  'unique index over it ignores them. Set by erp.guard_supplier_invoice_'
  'reference() and by nothing else; never typed.';

create or replace function erp.supplier_invoice_reference_key(
  p_tenant_id        uuid,
  p_document_type_id uuid,
  p_party_id         uuid,
  p_their_reference  text,
  p_is_cancelled     boolean
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  -- Trimmed and folded, because "INV-88213", "inv-88213" and " INV-88213 " are
  -- one invoice from one supplier however the keyboard delivered them. Not
  -- narrowed further than that: collapsing what is inside the number would
  -- start deciding that INV 1 and INV1 are the same, which is the supplier's
  -- business and not ours.
  select case
           when p_party_id is null then null
           when coalesce(p_is_cancelled, false) then null
           when coalesce(btrim(p_their_reference), '') = '' then null
           when not exists (
                  select 1 from erp.document_type dt
                   where dt.tenant_id = p_tenant_id
                     and dt.id = p_document_type_id
                     and dt.base_type_code = 'invoice_reference'
                     and erp.document_type_party_role_kind(p_tenant_id, dt.id) = 'supplier')
             then null
           else upper(btrim(p_their_reference))
         end;
$$;

revoke all on function erp.supplier_invoice_reference_key(uuid, uuid, uuid, text, boolean)
  from public, anon, authenticated;

comment on function erp.supplier_invoice_reference_key(uuid, uuid, uuid, text, boolean) is
  'What a document''s their_reference is compared as, or null when it is not '
  'compared at all. A supplier bill is a document on base type '
  'invoice_reference whose type stands its party in the supplier role — which '
  'is what tells purchase_invoice from sales_invoice, since both are built on '
  'the same base type and only the permission the type requires says which '
  'side of the trade it is.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The guard
-- ═════════════════════════════════════════════════════════════════════════════
--
-- On the table rather than in one door, because there is more than one way in:
-- erp.bill_from_receipt() raises the bill the procurement screen raises,
-- erp.open_document() and erp.create_document() raise one directly, and the
-- demonstration seeder raises one a fourth way. A guard on the door the screen
-- happens to use protects the screen; this protects the ledger.
--
-- Fired on insert, and on the updates that can change the answer. An update
-- that names none of those columns cannot move the key, and making every
-- update of every document pay for this read would be a cost with no reason.

create or replace function erp.guard_supplier_invoice_reference()
returns trigger
language plpgsql
set search_path = ''
as $fn$
declare
  v_holder   text;
  v_party    text;
  v_when     date;
begin
  new.supplier_reference_key := erp.supplier_invoice_reference_key(
    new.tenant_id, new.document_type_id, new.party_id,
    new.their_reference, new.is_cancelled);

  if new.supplier_reference_key is null then
    return new;
  end if;

  -- Nothing moved: a document rewritten for another reason is not a second
  -- arrival of the invoice it already is.
  if tg_op = 'UPDATE'
     and old.supplier_reference_key is not distinct from new.supplier_reference_key
     and old.party_id is not distinct from new.party_id then
    return new;
  end if;

  select d.document_number, d.document_date
    into v_holder, v_when
    from erp.document d
   where d.tenant_id = new.tenant_id
     and d.party_id = new.party_id
     and d.supplier_reference_key = new.supplier_reference_key
     and d.id <> new.id
   order by d.document_date, d.document_number
   limit 1;

  if v_holder is not null then
    select p.name into v_party
      from erp.party p
     where p.tenant_id = new.tenant_id and p.id = new.party_id;

    raise exception
      'CLOVEERP_SUPPLIER_INVOICE_ALREADY_REGISTERED: invoice % from % is already registered on %, dated %. Entering it again is how a supplier is paid twice.',
      btrim(new.their_reference), coalesce(v_party, 'this supplier'), v_holder, v_when
      using errcode = '23505',
            hint = format(
              'Open %s and check it against the paper before entering this one. '
              'If the supplier really has sent a second bill, ask them for its own '
              'number — two bills with one number is their error to correct. If %s '
              'was raised in error, cancel it and the number is free again.',
              v_holder, v_holder);
  end if;

  return new;
end;
$fn$;

revoke all on function erp.guard_supplier_invoice_reference() from public, anon, authenticated;

comment on function erp.guard_supplier_invoice_reference() is
  'Keeps erp.document.supplier_reference_key in step with the reference, the '
  'party, the type and the cancellation, and refuses a second live supplier '
  'bill carrying a number one already has — naming the document that holds it, '
  'the date it was raised and what to do. The unique index underneath is what '
  'holds against two clerks typing at once; this is what a person can read.';

drop trigger if exists t_document_supplier_reference on erp.document;
create trigger t_document_supplier_reference
  before insert
      or update of their_reference, party_id, document_type_id, is_cancelled
      on erp.document
  for each row execute function erp.guard_supplier_invoice_reference();

-- The refusal in the register, so the screen has a title for it and an
-- organisation can put the refusal in its own words. The hint the raise
-- carries wins over the registered next action wherever it is more specific,
-- which it is: it names the bill. Written in the words of the person refused —
-- erp_test.plain_words_suite() refuses a register row that is not.
select erp.register_refusal(
  'CLOVEERP_SUPPLIER_INVOICE_ALREADY_REGISTERED',
  'This supplier''s invoice number is already on another bill.',
  'One supplier does not send one invoice number on two bills. Registering it '
  'twice is how a supplier comes to be paid twice, which is the commonest loss '
  'in accounts payable and the one an ERP is bought to stop.',
  'Open the bill that already holds the number and check it against the paper. '
  'If the supplier really has sent a second invoice, ask them for its own '
  'number. If the first bill was raised in error, cancel it and the number is '
  'free to use again.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The index
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Created here, before anything is keyed, so it builds on an empty cluster and
-- on a database with three organisations of history in it alike: at this point
-- every supplier_reference_key in the world is null and a partial unique index
-- over "not null" has nothing to reject. The backfill below is what meets the
-- history, and it is written to survive it.

create unique index if not exists document_supplier_invoice_reference_once
  on erp.document (tenant_id, party_id, supplier_reference_key)
  where supplier_reference_key is not null;

comment on index erp.document_supplier_invoice_reference_once is
  'One supplier, one invoice number, once — per organisation. Cancelled bills, '
  'blank references, credit notes and every document that is not a supplier '
  'bill key to null and are ignored.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The sweep, and then the backfill
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Three things this must not do, in the order they would hurt.
--
--   It must not fail the deploy. A duplicate already in the data is a fact
--   about a company's accounts payable, not a defect in this migration, and
--   rolling a release back over one helps nobody.
--
--   It must not mangle the data. Cancelling the later copy, renaming its
--   reference or merging the two are all guesses, and the one case where the
--   guess is wrong is the case where the second bill was real.
--
--   It must not leave the finding in a log nobody reads. So the sweep counts
--   what it found, names the first of them in the deploy's own output, and
--   leaves erp.supplier_invoice_duplicates() behind for the rest.
--
-- The first document of each group — earliest date, then earliest raised —
-- takes the key. The later copies stay exactly as they are, keyed null, which
-- means the number is still claimed and a THIRD arrival is refused against the
-- first. Nothing is lost and nothing is invented.

do $sweep$
declare
  v_keyed   bigint;
  v_groups  bigint;
  v_extra   bigint;
  v_names   text;
begin
  create temp table _supplier_reference_sweep on commit drop as
  with keyed as (
    select d.tenant_id, d.party_id, d.id, d.document_number, d.document_date,
           d.created_at, d.their_reference,
           erp.supplier_invoice_reference_key(
             d.tenant_id, d.document_type_id, d.party_id,
             d.their_reference, d.is_cancelled) as k
      from erp.document d
  )
  select k.*,
         row_number() over (partition by k.tenant_id, k.party_id, k.k
                            order by k.document_date, k.created_at, k.document_number) as rn,
         count(*) over (partition by k.tenant_id, k.party_id, k.k) as n
    from keyed k
   where k.k is not null;

  -- Naming supplier_reference_key and nothing the guard watches: the guard is
  -- not the thing that should decide this, and a backfill that tripped it
  -- would refuse the very rows it exists to describe.
  update erp.document d
     set supplier_reference_key = s.k
    from _supplier_reference_sweep s
   where d.tenant_id = s.tenant_id and d.id = s.id and s.rn = 1;
  get diagnostics v_keyed = row_count;

  select count(*) filter (where s.n > 1 and s.rn = 1),
         count(*) filter (where s.n > 1 and s.rn > 1)
    into v_groups, v_extra
    from _supplier_reference_sweep s;

  if coalesce(v_groups, 0) > 0 then
    select string_agg(format('%s on %s (also %s)', x.their_reference, x.first_doc, x.rest),
                      '; ' order by x.first_doc)
      into v_names
      from (
        select min(s.their_reference) as their_reference,
               min(s.document_number) filter (where s.rn = 1) as first_doc,
               string_agg(s.document_number, ', ' order by s.rn)
                 filter (where s.rn > 1) as rest
          from _supplier_reference_sweep s
         where s.n > 1
         group by s.tenant_id, s.party_id, s.k
         order by 2
         limit 10
      ) x;

    raise warning
      'Supplier invoice duplicates found and left alone: % supplier invoice number(s) are on more than one live bill, % extra bill(s) in all. First of them: %',
      v_groups, v_extra, coalesce(v_names, 'none nameable');
    raise warning
      'Next action: run select * from erp.supplier_invoice_duplicates() in each organisation, decide bill by bill whether the later copy is a second invoice or a second entry of the first, and cancel the ones that are duplicates with a reason. Nothing has been changed here. From now on a NEW duplicate is refused.';
  end if;

  raise notice 'supplier invoice numbers claimed: % (of which % group(s) had more than one claimant)',
    v_keyed, coalesce(v_groups, 0);
end
$sweep$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The report, so the finding outlives the deploy log
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.supplier_invoice_duplicates()
returns table(party_code text, party_name text, their_reference text,
              bills bigint, registered_on text, also_on text)
language sql
stable
security invoker
set search_path = ''
as $$
  with keyed as (
    select d.tenant_id, d.party_id, d.document_number, d.document_date,
           d.created_at, d.their_reference, d.supplier_reference_key,
           erp.supplier_invoice_reference_key(
             d.tenant_id, d.document_type_id, d.party_id,
             d.their_reference, d.is_cancelled) as k
      from erp.document d
     -- Named rather than left to row security, because the build and the
     -- operator both read this from a privileged role that row security does
     -- not filter, and a report that quietly answered for every organisation
     -- at once would be the one thing this must never do.
     where d.tenant_id = erp.current_tenant_id()
  ),
  ranked as (
    select k.*,
           row_number() over (partition by k.tenant_id, k.party_id, k.k
                              order by k.document_date, k.created_at, k.document_number) as rn,
           count(*) over (partition by k.tenant_id, k.party_id, k.k) as n
      from keyed k
     where k.k is not null
  )
  select p.code, p.name, min(r.their_reference), count(*),
         -- The one holding the key is the one the index counts as registered.
         min(r.document_number) filter (where r.supplier_reference_key is not null),
         string_agg(r.document_number, ', ' order by r.rn)
           filter (where r.supplier_reference_key is null)
    from ranked r
    join erp.party p on p.tenant_id = r.tenant_id and p.id = r.party_id
   where r.n > 1
   group by r.tenant_id, r.party_id, r.k, p.code, p.name
   order by p.code, min(r.their_reference);
$$;

revoke all on function erp.supplier_invoice_duplicates() from public, anon, authenticated;

comment on function erp.supplier_invoice_duplicates() is
  'Every supplier invoice number carried by more than one live bill of the same '
  'supplier, with the bill that holds the number and the ones that repeat it. '
  'Empty is the answer this expects; anything else is a payment somebody should '
  'look at before it is made. Scoped to the organisation in context, so it '
  'answers for the one asking and never across them.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.supplier_invoice_once_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 12;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_uom uuid; v_site uuid; v_sup uuid; v_sup2 uuid; v_cust uuid; v_item uuid;
  v_bill uuid; v_second uuid; v_blank1 uuid; v_blank2 uuid;
  v_grn uuid; v_si1 uuid; v_si2 uuid; v_again uuid;
  v_ccy    char(3);
  v_ok     boolean;
  v_msg    text;
  v_hint   text;
  v_n      bigint;
begin
  begin
    v_step := 'an organisation with finance, procurement, sales, inventory and controls';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzsir-' || v_tag, 'Supplier Reference Suite',
      'admin@zzsir-' || v_tag || '.test', 'Supplier Reference Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzsir-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_procurement(100000000);
    perform erp.configure_sales(15);
    perform erp.configure_inventory('average');
    perform erp.configure_procurement_controls();

    select e.base_currency into v_ccy from erp.entity e where e.id = rb.entity_id;

    v_step := 'its own unit, site, two suppliers, a customer and a product';
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    if v_uom is null then
      insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
      values (rb.tenant_id, 'ZREA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    end if;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, rb.entity_id, 'ZRSITE', 'Supplier reference suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZR-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZR-BULK', 'Bulk', 'bulk');

    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRSUP', 'Supplier Reference Suite Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup, 'supplier', 'active');

    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRSUP2', 'Supplier Reference Suite Other Supplier', 'active') returning id into v_sup2;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_sup2, 'supplier', 'active');

    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZRCUST', 'Supplier Reference Suite Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_cust, 'customer', 'active');

    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZRWID', 'Supplier Reference Suite Widget', v_uom, 'active')
    returning id into v_item;

    -- ── 1. The number is registered ─────────────────────────────────────────
    v_step := 'the supplier''s bill, entered with the number printed on it';
    v_bill := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                  current_date, v_ccy, 'INV-88213', '{}'::jsonb);
    perform erp.add_document_line(v_bill, v_item, 1, 10000, 'a widget');

    v_cases := v_cases + 1;
    case_name := 'a supplier bill registers the number printed on it';
    passed := v_state is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_bill) = 'INV-88213';
    detail := format('%s holds %s',
                     (select d.document_number from erp.document d where d.id = v_bill),
                     coalesce((select d.supplier_reference_key from erp.document d where d.id = v_bill), 'nothing'));
    return next;

    -- ── 2, 3. And the same number is refused, in words ──────────────────────
    v_step := 'the same invoice, entered a second time';
    begin
      v_second := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                      current_date, v_ccy, 'INV-88213', '{}'::jsonb);
      v_ok := false; v_msg := 'the same invoice was registered twice'; v_hint := '';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SUPPLIER_INVOICE_ALREADY_REGISTERED:%';
      v_msg := left(sqlerrm, 240);
      get stacked diagnostics v_hint = pg_exception_hint;
    end;

    v_cases := v_cases + 1;
    case_name := 'the same invoice number from the same supplier is refused';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    v_cases := v_cases + 1;
    case_name := 'and the refusal names the bill that already holds it, and what to do about it';
    passed := v_state is null
          and position((select d.document_number from erp.document d where d.id = v_bill) in v_msg) > 0
          and position((select d.document_number from erp.document d where d.id = v_bill) in coalesce(v_hint, '')) > 0
          and position('cancel' in lower(coalesce(v_hint, ''))) > 0;
    detail := format('next action: %s', left(coalesce(v_hint, 'none given'), 140));
    return next;

    -- ── 4. Case and space are the same number ───────────────────────────────
    v_step := 'the same number typed in lower case with a space either side';
    begin
      perform erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                  current_date, v_ccy, '  inv-88213 ', '{}'::jsonb);
      v_ok := false; v_msg := 'a difference of case and space made it a second invoice';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SUPPLIER_INVOICE_ALREADY_REGISTERED:%';
      v_msg := left(sqlerrm, 120);
    end;

    v_cases := v_cases + 1;
    case_name := 'a difference of case or surrounding space is not a different invoice';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    -- ── 5. Another supplier may use the same number ─────────────────────────
    v_step := 'another supplier whose own numbering happens to reach 88213';
    v_second := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup2,
                                    current_date, v_ccy, 'INV-88213', '{}'::jsonb);

    v_cases := v_cases + 1;
    case_name := 'two suppliers may each send their own invoice 88213';
    passed := v_state is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_second) = 'INV-88213';
    detail := format('%s from %s alongside %s from %s',
                     (select d.document_number from erp.document d where d.id = v_second), 'ZRSUP2',
                     (select d.document_number from erp.document d where d.id = v_bill), 'ZRSUP');
    return next;

    -- ── 6. Two blanks do not collide ────────────────────────────────────────
    v_step := 'two bills entered with nothing in the box, and one with only spaces';
    v_blank1 := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                    current_date, v_ccy, null, '{}'::jsonb);
    v_blank2 := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                    current_date, v_ccy, '   ', '{}'::jsonb);

    v_cases := v_cases + 1;
    case_name := 'two bills with no supplier number at all are two bills, not one entered twice';
    passed := v_state is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_blank1) is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_blank2) is null;
    detail := 'a blank reference keys to null, and a unique index ignores nulls';
    return next;

    -- ── 7. A cancelled bill gives its number back ───────────────────────────
    v_step := 'the first bill cancelled, and the invoice entered again';
    perform erp.cancel_document(v_bill, 'supplier reference suite: raised in error');
    v_again := erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                   current_date, v_ccy, 'INV-88213', '{}'::jsonb);

    v_cases := v_cases + 1;
    case_name := 'a cancelled bill gives its number back, so the correction can be entered';
    passed := v_state is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_bill) is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_again) = 'INV-88213';
    detail := format('%s cancelled, %s now holds INV-88213',
                     (select d.document_number from erp.document d where d.id = v_bill),
                     (select d.document_number from erp.document d where d.id = v_again));
    return next;

    -- ── 8. And it is still held once ────────────────────────────────────────
    v_step := 'the invoice entered a third time, against the replacement';
    begin
      perform erp.create_document('purchase_invoice', rb.entity_id, v_site, v_sup,
                                  current_date, v_ccy, 'INV-88213', '{}'::jsonb);
      v_ok := false; v_msg := 'the replacement did not claim the number';
    exception when others then
      v_ok := sqlerrm like 'CLOVEERP_SUPPLIER_INVOICE_ALREADY_REGISTERED:%';
      v_msg := left(sqlerrm, 120);
    end;

    v_cases := v_cases + 1;
    case_name := 'the bill that replaced it holds the number in its turn';
    passed := v_state is null and v_ok;
    detail := v_msg;
    return next;

    -- ── 9. A document that is not a supplier bill is untouched ──────────────
    v_step := 'a goods receipt from the same supplier quoting the same number';
    v_grn := erp.create_document('goods_receipt', rb.entity_id, v_site, v_sup,
                                 current_date, v_ccy, 'INV-88213', '{}'::jsonb);

    v_cases := v_cases + 1;
    case_name := 'a receipt from the same supplier may quote the invoice number, because a receipt is not a bill';
    passed := v_state is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_grn) is null
          and (select d.their_reference from erp.document d where d.id = v_grn) = 'INV-88213';
    detail := 'the key is scoped to the supplier bill, not to every document a supplier touches';
    return next;

    -- ── 10. The customer side is not narrowed ───────────────────────────────
    v_step := 'two sales invoices to one customer against one purchase order of theirs';
    v_si1 := erp.create_document('sales_invoice', rb.entity_id, v_site, v_cust,
                                 current_date, v_ccy, 'PO-4471', '{}'::jsonb);
    v_si2 := erp.create_document('sales_invoice', rb.entity_id, v_site, v_cust,
                                 current_date, v_ccy, 'PO-4471', '{}'::jsonb);

    v_cases := v_cases + 1;
    case_name := 'a customer''s order number may be quoted on every invoice it covers';
    passed := v_state is null
          and v_si1 is not null and v_si2 is not null
          and (select d.supplier_reference_key from erp.document d where d.id = v_si1) is null
          and (select d.supplier_reference_key from erp.document d where d.id = v_si2) is null
          and (select count(*) from erp.document d
                where d.tenant_id = rb.tenant_id and d.party_id = v_cust
                  and d.their_reference = 'PO-4471') = 2;
    detail := 'one purchase order covers many call-offs; uniqueness there would refuse ordinary trade';
    return next;

    -- ── 11. And the report agrees ───────────────────────────────────────────
    v_step := 'the duplicate report over an organisation with no duplicates in it';
    select count(*) into v_n from erp.supplier_invoice_duplicates();

    v_cases := v_cases + 1;
    case_name := 'the duplicate report finds nothing, because nothing got through';
    passed := v_state is null and v_n = 0;
    detail := format('%s duplicate group(s) across everything this suite raised', v_n);
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzsir-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzsir rolled back with its suppliers and its bills');
  return next;

  -- The count guard prints what the fixture caught. Without it a break inside
  -- the block costs a whole build to name.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_INVOICE_ONCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.supplier_invoice_once_suite() from public, anon;

create or replace function erp_test.assert_supplier_invoice_once_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 12;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _supplier_invoice_once on commit drop as
    select * from erp_test.supplier_invoice_once_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _supplier_invoice_once;
  drop table _supplier_invoice_once;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SUPPLIER_INVOICE_ONCE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUPPLIER_INVOICE_ONCE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a supplier invoice arrives once: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_supplier_invoice_once_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_audit_coverage();

select erp_test.assert_supplier_invoice_once_suite();
