-- =============================================================================
-- Starter Content Packs §4 and §6 — the vocabularies a pack installs from
--
-- §1's governing rule is that content is tenant-neutral: the same catalogue for
-- every organisation, copied in rather than invented per deployment. So each of
-- these lives in erp_ref as product content, and the pack machinery that
-- follows copies from here into the tenant-scoped tables that already exist.
--
-- Four collisions with the schema as built are flagged rather than reconciled,
-- each at the point where it bites. Two are worth stating up front:
--
--   §4.7 names twenty location types. erp.location_type is a PostgreSQL enum
--   with eleven values and is read by the allocation and picking code. Widening
--   an enum whose new values nothing reads would be a schema change dressed as
--   content, so erp_ref.location_type carries §4.7's twenty PURPOSES with the
--   default attributes §4.7 asks for, and names which of the eleven each
--   materialises as. Nothing is dropped and nothing is invented.
--
--   §4.2's payment terms and Incoterms have nowhere to be. erp.party_role_terms
--   carries payment_terms_code and incoterms_code as free text with no
--   vocabulary behind them — so today any string is a valid Incoterm. These
--   catalogues are that vocabulary. They arrive as a REPORT rather than a
--   foreign key, because a deployment already holding free text would fail the
--   build on data nobody has had the chance to correct yet.
-- =============================================================================

-- ── §4.1 Units of measure, UNECE Recommendation 20 ───────────────────────────

create table if not exists erp_ref.uom (
  code       text primary key,
  name       text not null,
  uom_class  erp.uom_class not null,
  decimals   smallint not null default 0 check (decimals between 0 and 6),
  is_base    boolean not null default false,
  unece_code text,
  seq        integer not null default 100
);

create table if not exists erp_ref.uom_conversion (
  from_code text not null references erp_ref.uom(code) on delete cascade,
  to_code   text not null references erp_ref.uom(code) on delete cascade,
  factor    numeric(20,10) not null check (factor > 0),
  primary key (from_code, to_code),
  check (from_code <> to_code)
);

comment on table erp_ref.uom is
  'The starter unit catalogue, UNECE Recommendation 20 codes where one exists. '
  'Product content: erp.uom is the tenant-scoped copy an organisation actually '
  'uses, and may diverge from this the moment it wants to.';

comment on table erp_ref.uom_conversion is
  'Within-family conversions, §4.1. Cross-family conversions are deliberately '
  'absent: kilograms to litres depends on the item, and erp.uom_conversion '
  'carries an item_id for exactly that reason.';

-- Every factor is "how many of from_code make one to_code", stated against the
-- family's base so a chain never has to be walked.
insert into erp_ref.uom (code, name, uom_class, decimals, is_base, unece_code, seq) values
  -- count
  ('EA',    'Each',      'quantity',  0, true,  'EA',  10),
  ('PR',    'Pair',      'quantity',  0, false, 'PR',  11),
  ('DZ',    'Dozen',     'quantity',  0, false, 'DZN', 12),
  ('PK',    'Pack',      'quantity',  0, false, 'PK',  13),
  ('CS',    'Case',      'quantity',  0, false, 'CS',  14),
  ('CT',    'Carton',    'quantity',  0, false, 'CT',  15),
  ('PF',    'Pallet',    'quantity',  0, false, 'PF',  16),
  -- §4.1 puts pack, case, carton and pallet under "count", and the first draft
  -- of this file put them in the packaging class instead. The assertion below
  -- caught it: a packaging family with no base unit, which erp.ensure_base_uom()
  -- would have had no answer for. They are counts of a thing, and the thing is
  -- an item property — which is why they carry no global factor.
  -- mass
  ('MGM',   'Milligram', 'mass',      3, false, 'MGM', 20),
  ('GRM',   'Gram',      'mass',      3, false, 'GRM', 21),
  ('KGM',   'Kilogram',  'mass',      3, true,  'KGM', 22),
  ('TNE',   'Tonne',     'mass',      3, false, 'TNE', 23),
  -- volume
  ('MLT',   'Millilitre','volume',    3, false, 'MLT', 30),
  ('CLT',   'Centilitre','volume',    3, false, 'CLT', 31),
  ('LTR',   'Litre',     'volume',    3, true,  'LTR', 32),
  ('MTQ',   'Cubic metre','volume',   4, false, 'MTQ', 33),
  -- length
  ('MMT',   'Millimetre','length',    2, false, 'MMT', 40),
  ('CMT',   'Centimetre','length',    2, false, 'CMT', 41),
  ('MTR',   'Metre',     'length',    3, true,  'MTR', 42),
  -- area
  ('MTK',   'Square metre','area',    3, true,  'MTK', 50),
  -- time
  ('MIN',   'Minute',    'time',      0, false, 'MIN', 60),
  ('HUR',   'Hour',      'time',      2, true,  'HUR', 61),
  ('DAY',   'Day',       'time',      2, false, 'DAY', 62)
on conflict (code) do update set
  name = excluded.name, uom_class = excluded.uom_class,
  decimals = excluded.decimals, is_base = excluded.is_base,
  unece_code = excluded.unece_code, seq = excluded.seq;

insert into erp_ref.uom_conversion (from_code, to_code, factor) values
  ('PR',  'EA',  2),
  ('DZ',  'EA',  12),
  ('MGM', 'KGM', 0.000001),
  ('GRM', 'KGM', 0.001),
  ('TNE', 'KGM', 1000),
  ('MLT', 'LTR', 0.001),
  ('CLT', 'LTR', 0.01),
  ('MTQ', 'LTR', 1000),
  ('MMT', 'MTR', 0.001),
  ('CMT', 'MTR', 0.01),
  ('MIN', 'HUR', 0.0166666667),
  ('DAY', 'HUR', 24)
on conflict (from_code, to_code) do update set factor = excluded.factor;
-- Pack, case, carton and pallet carry no factor on purpose. How many eaches are
-- in a case is a property of the item, not of the word "case", and erp.uom_conversion
-- carries item_id so an organisation states it once per item rather than once
-- globally and wrongly.

-- ── §4.2 Commercial terms ────────────────────────────────────────────────────
--
-- Currencies and countries already exist as product content (erp_ref.currency,
-- erp_ref.country), so §4.2's third and fifth bullets are met. Its first, second
-- and fourth are not: payment terms, Incoterms and delivery terms have no
-- vocabulary anywhere, only free-text columns on erp.party_role_terms.

create table if not exists erp_ref.payment_term (
  code             text primary key,
  name             text not null,
  -- The three fields a due date actually needs. Anything that computes a due
  -- date from a term computes it from these, so a new term is a row rather
  -- than a branch in a function.
  net_days         integer not null default 0,
  day_basis        text not null default 'invoice_date'
                     check (day_basis in ('invoice_date','end_of_month','delivery_date','prepaid')),
  discount_percent numeric(6,3) not null default 0 check (discount_percent >= 0),
  discount_days    integer not null default 0 check (discount_days >= 0),
  seq              integer not null default 100
);

insert into erp_ref.payment_term (code, name, net_days, day_basis, discount_percent, discount_days, seq) values
  ('NET7',      'Net 7 days',                  7,  'invoice_date',  0,     0, 10),
  ('NET14',     'Net 14 days',                14,  'invoice_date',  0,     0, 11),
  ('NET30',     'Net 30 days',                30,  'invoice_date',  0,     0, 12),
  ('NET45',     'Net 45 days',                45,  'invoice_date',  0,     0, 13),
  ('NET60',     'Net 60 days',                60,  'invoice_date',  0,     0, 14),
  ('NET90',     'Net 90 days',                90,  'invoice_date',  0,     0, 15),
  ('EOM',       'End of month',                0,  'end_of_month',  0,     0, 20),
  ('EOM30',     'End of month plus 30 days',  30,  'end_of_month',  0,     0, 21),
  ('PREPAID',   'Prepaid',                     0,  'prepaid',       0,     0, 30),
  ('COD',       'On delivery',                 0,  'delivery_date', 0,     0, 31),
  ('2_10_N30',  '2% 10 days, net 30',         30,  'invoice_date',  2.000, 10, 40)
on conflict (code) do update set
  name = excluded.name, net_days = excluded.net_days, day_basis = excluded.day_basis,
  discount_percent = excluded.discount_percent, discount_days = excluded.discount_days,
  seq = excluded.seq;

create table if not exists erp_ref.incoterm (
  code                text primary key check (code ~ '^[A-Z]{3}$'),
  name                text not null,
  edition             text not null default '2020',
  transport_mode      text not null check (transport_mode in ('any','sea_inland_waterway')),
  -- §4.2 asks for these two by name, "so landed cost and revenue recognition
  -- rules can reference them". They are the whole reason the catalogue is
  -- structured rather than a list of eleven strings.
  cost_transfers_at   text not null,
  risk_transfers_at   text not null,
  seller_arranges_carriage  boolean not null default false,
  seller_arranges_insurance boolean not null default false,
  seq                 integer not null default 100
);

insert into erp_ref.incoterm
  (code, name, transport_mode, cost_transfers_at, risk_transfers_at,
   seller_arranges_carriage, seller_arranges_insurance, seq) values
  ('EXW', 'Ex Works',                     'any',
   'seller premises', 'seller premises',                       false, false, 10),
  ('FCA', 'Free Carrier',                 'any',
   'named place of delivery', 'named place of delivery',       false, false, 11),
  ('CPT', 'Carriage Paid To',             'any',
   'named place of destination', 'first carrier',              true,  false, 12),
  ('CIP', 'Carriage and Insurance Paid To','any',
   'named place of destination', 'first carrier',              true,  true,  13),
  ('DAP', 'Delivered at Place',           'any',
   'named place of destination', 'named place of destination', true,  false, 14),
  ('DPU', 'Delivered at Place Unloaded',  'any',
   'named place, unloaded', 'named place, unloaded',           true,  false, 15),
  ('DDP', 'Delivered Duty Paid',          'any',
   'named place of destination, duty paid', 'named place of destination', true, false, 16),
  ('FAS', 'Free Alongside Ship',          'sea_inland_waterway',
   'alongside the vessel', 'alongside the vessel',             false, false, 20),
  ('FOB', 'Free on Board',                'sea_inland_waterway',
   'on board the vessel', 'on board the vessel',               false, false, 21),
  ('CFR', 'Cost and Freight',             'sea_inland_waterway',
   'port of destination', 'on board the vessel',               true,  false, 22),
  ('CIF', 'Cost, Insurance and Freight',  'sea_inland_waterway',
   'port of destination', 'on board the vessel',               true,  true,  23)
on conflict (code) do update set
  name = excluded.name, transport_mode = excluded.transport_mode,
  cost_transfers_at = excluded.cost_transfers_at,
  risk_transfers_at = excluded.risk_transfers_at,
  seller_arranges_carriage = excluded.seller_arranges_carriage,
  seller_arranges_insurance = excluded.seller_arranges_insurance, seq = excluded.seq;

comment on table erp_ref.incoterm is
  'Incoterms 2020, all eleven, each stating where cost and where risk transfer. '
  'CPT, CIP, CFR and CIF are the four where those two differ, which is the '
  'whole reason landed cost and revenue recognition need to read them '
  'separately rather than reading "the Incoterm".';

create table if not exists erp_ref.delivery_term (
  code text primary key,
  name text not null,
  description text not null,
  seq  integer not null default 100
);

insert into erp_ref.delivery_term (code, name, description, seq) values
  ('STANDARD',   'Standard',   'The default service for the lane.', 10),
  ('EXPRESS',    'Express',    'Expedited against the standard lead time.', 11),
  ('NEXT_DAY',   'Next day',   'Delivered the next working day.', 12),
  ('TIMED',      'Timed',      'Delivered within an agreed window on the day.', 13),
  ('COLLECTION', 'Collection', 'Collected by the customer or their carrier.', 14),
  ('DROP_SHIP',  'Drop-ship',  'Shipped by the supplier direct to the customer.', 15)
on conflict (code) do update set
  name = excluded.name, description = excluded.description, seq = excluded.seq;

-- ── §4.7 Location types ──────────────────────────────────────────────────────
--
-- Twenty purposes over eleven enum values. base_type is what a location of this
-- purpose IS to the allocation and picking code; the rest is what §4.7 asks
-- each type to carry.

create table if not exists erp_ref.location_type (
  code                      text primary key,
  name                      text not null,
  base_type                 erp.location_type not null,
  holds_available_stock     boolean not null,
  is_countable              boolean not null,
  allocation_scope          text not null
                              check (allocation_scope in ('available','reserved','inspection','none')),
  default_storage_condition text
                              check (default_storage_condition in
                                ('ambient','cool','refrigerated','frozen','controlled','hazardous')),
  requires_capability       text references erp_ref.capability(code),
  seq                       integer not null default 100
);

comment on table erp_ref.location_type is
  '§4.7''s twenty location purposes with their default attributes, each naming '
  'the erp.location_type it materialises as. Widening that enum for the nine '
  'purposes it does not distinguish would have been a schema change dressed as '
  'content — nothing reads the new values, and allocation would treat quarantine '
  'cold and quarantine identically anyway, which is correct.';

insert into erp_ref.location_type
  (code, name, base_type, holds_available_stock, is_countable, allocation_scope,
   default_storage_condition, requires_capability, seq) values
  ('RECEIVING',            'Receiving',            'receiving',  false, true,  'none',       'ambient',     null, 10),
  ('QUARANTINE',           'Quarantine',           'quarantine', false, true,  'inspection', 'ambient',     'quality_inspection', 11),
  ('QUARANTINE_COLD',      'Quarantine cold',      'quarantine', false, true,  'inspection', 'refrigerated','quality_inspection', 12),
  ('BULK',                 'Bulk storage',         'bulk',       true,  true,  'available',  'ambient',     null, 20),
  ('COLD',                 'Cold storage',         'bulk',       true,  true,  'available',  'refrigerated',null, 21),
  ('FROZEN',               'Frozen storage',       'bulk',       true,  true,  'available',  'frozen',      null, 22),
  ('CONTROLLED',           'Controlled storage',   'bulk',       true,  true,  'available',  'controlled',  null, 23),
  ('PICK_FACE',            'Pick face',            'pick',       true,  true,  'available',  'ambient',     null, 30),
  ('REPLEN_STAGING',       'Replenishment staging','staging',    true,  true,  'reserved',   'ambient',     null, 31),
  ('RELEASE_AREA',         'Release area',         'staging',    true,  true,  'reserved',   'ambient',     'release_areas', 32),
  ('PACKING',              'Packing',              'staging',    false, true,  'reserved',   'ambient',     null, 33),
  ('DESPATCH_STAGING',     'Despatch staging',     'despatch',   false, true,  'reserved',   'ambient',     null, 34),
  ('RETURNS',              'Returns',              'receiving',  false, true,  'none',       'ambient',     'returns', 40),
  ('DAMAGES',              'Damages',              'damages',    false, true,  'none',       'ambient',     null, 41),
  ('QUARANTINE_RETURNS',   'Quarantine returns',   'quarantine', false, true,  'inspection', 'ambient',     'returns', 42),
  ('PRODUCTION_INPUT',     'Production input',     'production', false, true,  'reserved',   'ambient',     'production', 50),
  ('PRODUCTION_OUTPUT',    'Production output',    'production', false, true,  'none',       'ambient',     'production', 51),
  ('IN_TRANSIT',           'In transit',           'transit',    false, false, 'none',       null,          null, 60),
  ('CONSIGNMENT',          'Consignment',          'virtual',    true,  true,  'available',  'ambient',     'consignment_stock', 61),
  ('THIRD_PARTY_CUSTODY',  'Third-party custody',  'virtual',    true,  false, 'available',  'ambient',     'third_party_custody', 62)
on conflict (code) do update set
  name = excluded.name, base_type = excluded.base_type,
  holds_available_stock = excluded.holds_available_stock,
  is_countable = excluded.is_countable, allocation_scope = excluded.allocation_scope,
  default_storage_condition = excluded.default_storage_condition,
  requires_capability = excluded.requires_capability, seq = excluded.seq;
-- IN_TRANSIT and THIRD_PARTY_CUSTODY are the two that are not countable, and
-- for the same reason in both cases: nobody with a scanner can stand in front
-- of the stock. Marking them countable would put a variance nobody can resolve
-- on every count sheet.

-- ── §6 Reason codes ──────────────────────────────────────────────────────────
--
-- Four columns in this schema carry a reason_code today — erp.stock_movement,
-- erp.customer_return, erp.location.block_reason_code and
-- erp.account_determination — and not one of them has a vocabulary behind it.
-- Any string is a valid reason for writing off stock, which means the write-off
-- report cannot be grouped, and "system correction" and "System Correction" and
-- "sys corr" are three separate causes.
--
-- Tenant-scoped as well as product content, because §1 requires content that
-- can be extended: an organisation adds its own codes and switches off the ones
-- it does not use, without the catalogue changing for anybody else.

create table if not exists erp_ref.reason_category (
  code        text primary key,
  name        text not null,
  description text not null,
  seq         integer not null default 100
);

create table if not exists erp_ref.reason_code (
  category_code  text not null references erp_ref.reason_category(code) on delete cascade,
  code           text not null,
  name           text not null,
  -- §7's tolerances and §8's determination both want to know whether a reason
  -- needs a person to say more, and whether it is the kind of thing somebody
  -- above the person doing it should see.
  requires_note  boolean not null default false,
  requires_approval boolean not null default false,
  seq            integer not null default 100,
  primary key (category_code, code)
);

create table if not exists erp.reason_code (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant(id) on delete cascade,
  category_code  text not null references erp_ref.reason_category(code),
  code           text not null,
  name           text not null,
  requires_note  boolean not null default false,
  requires_approval boolean not null default false,
  status         erp.record_status not null default 'active',
  seq            integer not null default 100,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  unique (tenant_id, category_code, code)
);

comment on table erp.reason_code is
  'The reasons this organisation accepts, by category. Seeded from '
  'erp_ref.reason_code by the base pack and extended from there — an '
  'organisation that adds "storm damage" is not waiting for the product to '
  'ship it.';

select erp_meta.register_table('erp_ref', 'reason_category', 'product_content',
  'The eleven §6 reason categories.');
select erp_meta.register_table('erp_ref', 'reason_code', 'product_content',
  'The starter reason vocabulary.');
select erp_meta.register_table('erp_ref', 'uom', 'product_content',
  'The starter unit catalogue.');
select erp_meta.register_table('erp_ref', 'uom_conversion', 'product_content',
  'Within-family unit conversions.');
select erp_meta.register_table('erp_ref', 'payment_term', 'product_content',
  'The starter payment term catalogue.');
select erp_meta.register_table('erp_ref', 'incoterm', 'product_content',
  'Incoterms 2020.');
select erp_meta.register_table('erp_ref', 'delivery_term', 'product_content',
  'The starter delivery term catalogue.');
select erp_meta.register_table('erp_ref', 'location_type', 'product_content',
  'The §4.7 location purposes and their default attributes.');
select erp_meta.register_table('erp', 'reason_code', 'tenant_scoped',
  'The reasons this organisation accepts.');

insert into erp_ref.reason_category (code, name, description, seq) values
  ('STOCK_ADJUSTMENT',  'Stock adjustment',
   'Why a stock figure changed without a document movement behind it.', 10),
  ('SCRAP',             'Scrap and destruction',
   'Why stock was destroyed rather than sold, returned or reworked.', 20),
  ('RETURN_SUPPLIER',   'Return to supplier',
   'Why goods went back to the party they came from.', 30),
  ('RETURN_CUSTOMER',   'Customer return',
   'Why a customer sent goods back.', 40),
  ('ORDER_HOLD',        'Order hold',
   'Why an order stopped progressing.', 50),
  ('ORDER_CANCEL',      'Order cancellation',
   'Why an order will not be fulfilled at all.', 60),
  ('APPROVAL_REJECT',   'Approval rejection',
   'Why an approver refused.', 70),
  ('BATCH_AMENDMENT',   'Batch amendment',
   'Why a batch record was changed after creation. Regulated ground: the '
   'reason is often the audit finding.', 80),
  ('ALLOCATION_OVERRIDE','Allocation override',
   'Why somebody overrode what allocation chose.', 90),
  ('PRICE_OVERRIDE',    'Price and discount override',
   'Why a price differs from the one the price list produced.', 100),
  ('PERIOD_REOPEN',     'Period reopen',
   'Why a closed accounting period was opened again.', 110)
on conflict (code) do update set
  name = excluded.name, description = excluded.description, seq = excluded.seq;

insert into erp_ref.reason_code (category_code, code, name, requires_note, requires_approval, seq) values
  ('STOCK_ADJUSTMENT','COUNT_VARIANCE',   'Count variance',                false, false, 10),
  ('STOCK_ADJUSTMENT','DAMAGE_STORAGE',   'Damage in storage',             true,  false, 11),
  ('STOCK_ADJUSTMENT','DAMAGE_TRANSIT',   'Damage in transit',             true,  false, 12),
  ('STOCK_ADJUSTMENT','THEFT_LOSS',       'Theft or loss',                 true,  true,  13),
  ('STOCK_ADJUSTMENT','FOUND',            'Found stock',                   true,  false, 14),
  ('STOCK_ADJUSTMENT','SYSTEM_CORRECTION','System correction',             true,  true,  15),
  ('STOCK_ADJUSTMENT','SAMPLE',           'Sample taken',                  false, false, 16),
  ('STOCK_ADJUSTMENT','QUALITY_FAILURE',  'Quality failure',               true,  false, 17),
  ('STOCK_ADJUSTMENT','EXPIRY_WRITE_OFF', 'Expiry write-off',              false, false, 18),
  ('STOCK_ADJUSTMENT','MEASURE_CORRECTION','Weight or measure correction', true,  false, 19),

  ('SCRAP','EXPIRED',            'Expired',                    false, false, 10),
  ('SCRAP','DAMAGED_BEYOND_USE', 'Damaged beyond use',         true,  false, 11),
  ('SCRAP','FAILED_INSPECTION',  'Failed inspection',          true,  false, 12),
  ('SCRAP','CONTAMINATED',       'Contaminated',               true,  true,  13),
  ('SCRAP','RECALLED',           'Recalled',                   true,  true,  14),
  ('SCRAP','OBSOLETE',           'Obsolete',                   false, true,  15),
  ('SCRAP','RETURN_UNFIT',       'Customer return unfit',      true,  false, 16),

  ('RETURN_SUPPLIER','WRONG_ITEM',        'Wrong item',                false, false, 10),
  ('RETURN_SUPPLIER','WRONG_QUANTITY',    'Wrong quantity',            false, false, 11),
  ('RETURN_SUPPLIER','DAMAGED_ARRIVAL',   'Damaged on arrival',        true,  false, 12),
  ('RETURN_SUPPLIER','QUALITY_REJECTION', 'Quality rejection',         true,  false, 13),
  ('RETURN_SUPPLIER','SHORT_DATED',       'Short-dated on receipt',    true,  false, 14),
  ('RETURN_SUPPLIER','OVER_DELIVERY',     'Over-delivery',             false, false, 15),
  ('RETURN_SUPPLIER','ORDERED_IN_ERROR',  'Ordered in error',          true,  false, 16),

  ('RETURN_CUSTOMER','DAMAGED_TRANSIT',   'Damaged in transit',        true,  false, 10),
  ('RETURN_CUSTOMER','WRONG_ITEM_SENT',   'Wrong item despatched',     false, false, 11),
  ('RETURN_CUSTOMER','WRONG_QUANTITY',    'Wrong quantity',            false, false, 12),
  ('RETURN_CUSTOMER','QUALITY_COMPLAINT', 'Quality complaint',         true,  false, 13),
  ('RETURN_CUSTOMER','ORDERED_IN_ERROR',  'Ordered in error',          false, false, 14),
  ('RETURN_CUSTOMER','NO_LONGER_REQUIRED','No longer required',        false, false, 15),
  ('RETURN_CUSTOMER','DELIVERY_REFUSED',  'Delivery refused',          true,  false, 16),

  ('ORDER_HOLD','CREDIT_LIMIT',        'Credit limit',              false, false, 10),
  ('ORDER_HOLD','PAYMENT_PENDING',     'Payment pending',           false, false, 11),
  ('ORDER_HOLD','STOCK_SHORTAGE',      'Stock shortage',            false, false, 12),
  ('ORDER_HOLD','ADDRESS_VERIFICATION','Address verification',      false, false, 13),
  ('ORDER_HOLD','QUALITY_HOLD',        'Quality hold',              true,  false, 14),
  ('ORDER_HOLD','COMPLIANCE_CHECK',    'Compliance check',          true,  false, 15),
  ('ORDER_HOLD','CUSTOMER_REQUEST',    'Customer request',          false, false, 16),
  ('ORDER_HOLD','DUPLICATE_SUSPECTED', 'Duplicate suspected',       false, false, 17),

  ('ORDER_CANCEL','CUSTOMER_REQUEST',  'Customer request',          false, false, 10),
  ('ORDER_CANCEL','UNABLE_TO_SUPPLY',  'Unable to supply',          true,  false, 11),
  ('ORDER_CANCEL','DUPLICATE_ORDER',   'Duplicate order',           false, false, 12),
  ('ORDER_CANCEL','PRICING_ERROR',     'Pricing error',             true,  true,  13),
  ('ORDER_CANCEL','CREDIT_REFUSAL',    'Credit refusal',            true,  false, 14),
  ('ORDER_CANCEL','PAST_CUT_OFF',      'Past cut-off',              false, false, 15),

  ('APPROVAL_REJECT','INSUFFICIENT_JUSTIFICATION','Insufficient justification', true, false, 10),
  ('APPROVAL_REJECT','BUDGET_EXCEEDED',           'Budget exceeded',            false, false, 11),
  ('APPROVAL_REJECT','INCORRECT_SUPPLIER',        'Incorrect supplier',         true,  false, 12),
  ('APPROVAL_REJECT','INCORRECT_CODING',          'Incorrect coding',           true,  false, 13),
  ('APPROVAL_REJECT','DUPLICATE_REQUEST',         'Duplicate request',          false, false, 14),
  ('APPROVAL_REJECT','ALTERNATIVE_SOURCING',      'Requires alternative sourcing', true, false, 15),

  ('BATCH_AMENDMENT','DATA_ENTRY_CORRECTION','Data entry correction',       true, true, 10),
  ('BATCH_AMENDMENT','RETEST_RESULT',        'Retest result',               true, true, 11),
  ('BATCH_AMENDMENT','SUPPLIER_DOCUMENTATION','Supplier documentation update', true, true, 12),
  ('BATCH_AMENDMENT','REGULATORY_REQUIREMENT','Regulatory requirement',      true, true, 13),
  ('BATCH_AMENDMENT','SHELF_LIFE_REASSESSMENT','Shelf-life reassessment',    true, true, 14),

  ('ALLOCATION_OVERRIDE','URGENCY',            'Customer or clinical urgency', true,  false, 10),
  ('ALLOCATION_OVERRIDE','BATCH_SPECIFIED',    'Batch specified by customer',  true,  false, 11),
  ('ALLOCATION_OVERRIDE','NEAREST_EXPIRY',     'Nearest expiry first',         false, false, 12),
  ('ALLOCATION_OVERRIDE','OPERATIONAL',        'Operational instruction',      true,  false, 13),
  ('ALLOCATION_OVERRIDE','SYSTEM_CORRECTION',  'System correction',            true,  true,  14),

  ('PRICE_OVERRIDE','CONTRACT_PRICE',    'Contract price',        false, false, 10),
  ('PRICE_OVERRIDE','VOLUME_AGREEMENT',  'Volume agreement',      false, false, 11),
  ('PRICE_OVERRIDE','PROMOTIONAL',       'Promotional',           false, false, 12),
  ('PRICE_OVERRIDE','GOODWILL',          'Goodwill',              true,  true,  13),
  ('PRICE_OVERRIDE','PRICE_CORRECTION',  'Price correction',      true,  true,  14),
  ('PRICE_OVERRIDE','COMPETITIVE_MATCH', 'Competitive match',     true,  false, 15),

  ('PERIOD_REOPEN','LATE_INVOICE',           'Late invoice',              true, true, 10),
  ('PERIOD_REOPEN','AUDIT_ADJUSTMENT',       'Audit adjustment',          true, true, 11),
  ('PERIOD_REOPEN','CORRECTION_OF_ERROR',    'Correction of error',       true, true, 12),
  ('PERIOD_REOPEN','CONSOLIDATION_ADJUSTMENT','Consolidation adjustment', true, true, 13)
on conflict (category_code, code) do update set
  name = excluded.name, requires_note = excluded.requires_note,
  requires_approval = excluded.requires_approval, seq = excluded.seq;
-- Every BATCH_AMENDMENT and PERIOD_REOPEN reason requires both a note and an
-- approval. Neither is in §6's text: §6 lists the reasons and §7 is where
-- tolerances live. But a batch record amended without a note is the finding an
-- inspector writes up, and a period reopened without one is the finding an
-- auditor writes up, so defaulting them off would ship a compliance failure as
-- a default.

-- ── Writing ──────────────────────────────────────────────────────────────────

create or replace function erp.upsert_reason_code(
  p_category text, p_code text, p_name text,
  p_requires_note boolean default false,
  p_requires_approval boolean default false,
  p_seq integer default 100)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_code   text := upper(btrim(p_code));
  v_cat    text := upper(btrim(p_category));
  v_id     uuid;
begin
  if not exists (select 1 from erp_ref.reason_category where code = v_cat) then
    raise exception 'ERPWARE_UNKNOWN_REASON_CATEGORY: %', v_cat
      using errcode = '23503',
            hint = 'A reason belongs to one of the eleven §6 categories. A new '
                   'category is a product change, not a tenant one — otherwise '
                   'the write-off report cannot be grouped across organisations.';
  end if;

  insert into erp.reason_code
    (tenant_id, category_code, code, name, requires_note, requires_approval, seq)
  values (v_tenant, v_cat, v_code, p_name, p_requires_note, p_requires_approval, p_seq)
  on conflict (tenant_id, category_code, code) do update set
    name = excluded.name,
    requires_note = excluded.requires_note,
    requires_approval = excluded.requires_approval,
    seq = excluded.seq,
    status = 'active',
    updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function erp.set_reason_code_status(
  p_category text, p_code text, p_active boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); n integer;
begin
  update erp.reason_code
     set status = (case when p_active then 'active' else 'inactive' end)::erp.record_status,
         updated_at = now()
   where tenant_id = v_tenant
     and category_code = upper(btrim(p_category))
     and code = upper(btrim(p_code));
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'ERPWARE_UNKNOWN_REASON_CODE: %.%',
      upper(btrim(p_category)), upper(btrim(p_code)) using errcode = '23503';
  end if;
  -- Retired rather than deleted, because documents already carry the code and
  -- a report that cannot resolve it prints a blank where a reason was.
  return jsonb_build_object('category', upper(btrim(p_category)),
                            'code', upper(btrim(p_code)), 'active', p_active);
end;
$$;

-- ── Reading ──────────────────────────────────────────────────────────────────

create or replace function public.erp_vocabularies()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'uoms', coalesce((select jsonb_agg(jsonb_build_object(
        'code', u.code, 'name', u.name, 'class', u.uom_class,
        'decimals', u.decimals, 'is_base', u.is_base, 'unece', u.unece_code,
        'converts_to', (select jsonb_agg(jsonb_build_object(
             'to', c.to_code, 'factor', c.factor) order by c.to_code)
           from erp_ref.uom_conversion c where c.from_code = u.code))
      order by u.seq, u.code) from erp_ref.uom u), '[]'::jsonb),
    'payment_terms', coalesce((select jsonb_agg(to_jsonb(p) order by p.seq, p.code)
      from erp_ref.payment_term p), '[]'::jsonb),
    'incoterms', coalesce((select jsonb_agg(to_jsonb(i) order by i.seq, i.code)
      from erp_ref.incoterm i), '[]'::jsonb),
    'delivery_terms', coalesce((select jsonb_agg(to_jsonb(d) order by d.seq, d.code)
      from erp_ref.delivery_term d), '[]'::jsonb),
    'location_types', coalesce((select jsonb_agg(to_jsonb(l) order by l.seq, l.code)
      from erp_ref.location_type l), '[]'::jsonb),
    'reason_categories', coalesce((select jsonb_agg(jsonb_build_object(
        'code', rc.code, 'name', rc.name, 'description', rc.description,
        'codes', (select jsonb_agg(jsonb_build_object(
             'code', r.code, 'name', r.name,
             'requires_note', r.requires_note,
             'requires_approval', r.requires_approval)
           order by r.seq, r.code)
           from erp_ref.reason_code r where r.category_code = rc.code))
      order by rc.seq, rc.code) from erp_ref.reason_category rc), '[]'::jsonb))
$$;

comment on function public.erp_vocabularies is
  'The whole starter vocabulary as product content — what a pack would install, '
  'readable before installing it. Tenant-neutral, so it needs no tenant context.';

create or replace function public.erp_reason_codes(p_category text default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'category', r.category_code,
           'category_name', c.name,
           'code', r.code, 'name', r.name,
           'requires_note', r.requires_note,
           'requires_approval', r.requires_approval,
           'status', r.status)
         order by c.seq, r.seq, r.code), '[]'::jsonb)
    from erp.reason_code r
    join erp_ref.reason_category c on c.code = r.category_code
   where r.tenant_id = erp.current_tenant_id()
     and (p_category is null or r.category_code = upper(btrim(p_category)))
$$;

create or replace function public.erp_upsert_reason_code(
  p_category text, p_code text, p_name text,
  p_requires_note boolean default false,
  p_requires_approval boolean default false,
  p_seq integer default 100)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_id uuid;
begin
  perform erp.authorise('administration.configure');
  v_id := erp.upsert_reason_code(p_category, p_code, p_name,
                                 p_requires_note, p_requires_approval, p_seq);
  return jsonb_build_object('reason_code_id', v_id);
end;
$$;

create or replace function public.erp_set_reason_code_status(
  p_category text, p_code text, p_active boolean)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.set_reason_code_status(p_category, p_code, p_active);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_vocabularies()',
    'public.erp_reason_codes(text)',
    'public.erp_upsert_reason_code(text, text, text, boolean, boolean, integer)',
    'public.erp_set_reason_code_status(text, text, boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_upsert_reason_code', 'erp.authorise',
   'Adds or amends a reason this organisation accepts. §1 requires content that '
   'can be extended; without this door the vocabulary would be the product''s '
   'to change and nobody else''s.'),
  ('erp_set_reason_code_status', 'erp.authorise',
   'Retires a reason without deleting it, because documents already carry the '
   'code and a report that cannot resolve it prints a blank where a reason was.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── The assertion, and the report that is deliberately not one ───────────────
--
-- The catalogues are product content, so what can go wrong with them is
-- internal consistency: a location type naming a base type that is not in the
-- enum (impossible — the column is typed), a conversion crossing families, a
-- reason code in no category (impossible — foreign key). What is left is the
-- part no constraint can express.

create or replace function erp.assert_starter_vocabularies_sound()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare v_detail text := ''; v_count integer := 0; r record;
begin
  -- A conversion between families is a number that means nothing. Kilograms to
  -- litres depends on the item, which is why erp.uom_conversion carries item_id
  -- and this catalogue does not.
  for r in
    select c.from_code, c.to_code, f.uom_class as from_class, t.uom_class as to_class
      from erp_ref.uom_conversion c
      join erp_ref.uom f on f.code = c.from_code
      join erp_ref.uom t on t.code = c.to_code
     where f.uom_class <> t.uom_class
     order by c.from_code
  loop
    v_detail := v_detail || format(E'  %s to %s crosses %s and %s — that factor depends on the item\n',
      r.from_code, r.to_code, r.from_class, r.to_class);
    v_count := v_count + 1;
  end loop;

  -- Every conversion has to land on its family's base, or a chain has to be
  -- walked and two routes can disagree.
  for r in
    select c.from_code, c.to_code from erp_ref.uom_conversion c
      join erp_ref.uom t on t.code = c.to_code
     where not t.is_base
     order by c.from_code
  loop
    v_detail := v_detail || format(E'  %s converts to %s, which is not its family''s base unit\n',
      r.from_code, r.to_code);
    v_count := v_count + 1;
  end loop;

  -- Exactly one base per family, or ensure_base_uom has a choice to make.
  for r in
    select u.uom_class, count(*) filter (where u.is_base) as bases
      from erp_ref.uom u group by u.uom_class having count(*) filter (where u.is_base) <> 1
  loop
    v_detail := v_detail || format(E'  the %s family has %s base units, and it needs exactly one\n',
      r.uom_class, r.bases);
    v_count := v_count + 1;
  end loop;

  -- A location type gated on a capability nobody can enable is a type nobody
  -- can use. The foreign key catches a misspelling; this catches a capability
  -- that was removed from the catalogue after the type started naming it.
  for r in
    select lt.code, lt.requires_capability from erp_ref.location_type lt
     where lt.requires_capability is not null
       and not exists (select 1 from erp_ref.capability c where c.code = lt.requires_capability)
  loop
    v_detail := v_detail || format(E'  location type %s needs capability %s, which is not in the catalogue\n',
      r.code, r.requires_capability);
    v_count := v_count + 1;
  end loop;

  -- And a tenant reason code whose category has gone.
  for r in
    select t.code as tenant_code, rc.category_code, rc.code
      from erp.reason_code rc
      join erp.tenant t on t.id = rc.tenant_id
     where not exists (select 1 from erp_ref.reason_category c where c.code = rc.category_code)
  loop
    v_detail := v_detail || format(E'  %s has reason %s.%s in a category that no longer exists\n',
      r.tenant_code, r.category_code, r.code);
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    raise exception E'ERPWARE_VOCABULARY_UNSOUND: % finding(s)\n%', v_count, v_detail
      using errcode = '23514';
  end if;

  return format('vocabularies: %s units (%s conversions), %s payment terms, '
                '%s incoterms, %s delivery terms, %s location types, '
                '%s reasons in %s categories',
    (select count(*) from erp_ref.uom),
    (select count(*) from erp_ref.uom_conversion),
    (select count(*) from erp_ref.payment_term),
    (select count(*) from erp_ref.incoterm),
    (select count(*) from erp_ref.delivery_term),
    (select count(*) from erp_ref.location_type),
    (select count(*) from erp_ref.reason_code),
    (select count(*) from erp_ref.reason_category));
end;
$$;

-- A REPORT, not an assertion, and the distinction is the point.
--
-- erp.party_role_terms.payment_terms_code and .incoterms_code are free text on
-- a table that already holds rows. Turning them into foreign keys, or asserting
-- over them, would fail the build on data that was valid when it was written
-- and that nobody has been given the means to correct. So this says what does
-- not resolve, and the correcting is a decision rather than a build failure.
create or replace function erp.term_vocabulary_report(p_tenant_id uuid default null)
returns table (tenant_code text, finding text, reference text)
language sql
stable
set search_path = ''
as $$
  select t.code, 'payment term is not in the catalogue',
         coalesce(prt.payment_terms_code, '(null)')
    from erp.party_role_terms prt
    join erp.tenant t on t.id = prt.tenant_id
   where (p_tenant_id is null or prt.tenant_id = p_tenant_id)
     and prt.payment_terms_code is not null
     and not exists (select 1 from erp_ref.payment_term pt
                      where pt.code = prt.payment_terms_code)
  union all
  select t.code, 'incoterm is not in Incoterms 2020',
         coalesce(prt.incoterms_code, '(null)')
    from erp.party_role_terms prt
    join erp.tenant t on t.id = prt.tenant_id
   where (p_tenant_id is null or prt.tenant_id = p_tenant_id)
     and prt.incoterms_code is not null
     and not exists (select 1 from erp_ref.incoterm i
                      where i.code = prt.incoterms_code)
  union all
  -- The other half: a reason recorded on a movement that the organisation does
  -- not have in its own list. This is how "sys corr" is found.
  select t.code, 'stock movement reason is not in this organisation''s list',
         sm.reason_code
    from erp.stock_movement sm
    join erp.tenant t on t.id = sm.tenant_id
   where (p_tenant_id is null or sm.tenant_id = p_tenant_id)
     and sm.reason_code is not null
     and not exists (select 1 from erp.reason_code rc
                      where rc.tenant_id = sm.tenant_id and rc.code = sm.reason_code)
   group by t.code, sm.reason_code
$$;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function,
   detail_arguments, blurb, runs_in_ci, seq)
values
  ('starter_vocabularies', 'Starter vocabularies', 'assertion', 'platform',
   'assert_starter_vocabularies_sound', '', null, '',
   'Unit conversions stay within a family and land on its base, every family '
   'has exactly one base, and no location type or reason code names something '
   'that has since been removed.', true, 21),
  ('term_vocabulary', 'Commercial terms in use', 'report', 'tenant',
   'term_vocabulary_report', '', null, '',
   'Payment terms, Incoterms and movement reasons recorded against values that '
   'are not in any catalogue. A report rather than an assertion: these columns '
   'were free text before there was a vocabulary, so correcting them is a '
   'decision rather than a build failure.', false, 22)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb,
  function_name = excluded.function_name, kind = excluded.kind, scope = excluded.scope;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_starter_vocabularies_sound();
select erp.assert_capabilities_sound();
select erp.assert_diagnostics_registered();
select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
