set lock_timeout = '30s';

-- =============================================================================
-- 20260916510000  A setting that scopes something
-- -----------------------------------------------------------------------------
-- 20260916430000 registered thirty-eight columns a screen writes that nothing
-- reads, nineteen of them as defects. Six of those are answered here.
--
-- ── A. The marshalling area ──────────────────────────────────────────────────
--
-- /logistics/release-areas says an area is "a site, a location, and optionally
-- the channel, order type and product classes it serves", and offers the four
-- controls that say so. A wave is opened over an area BY ID, and allocation
-- read only location_id, replenishment_mode, max_quantity, gate_printing and
-- ageing_hours. So an area restricted to one product class took every class,
-- an area meant for one order type took every order, and a "Minimum" sat
-- beside a "Maximum" that worked.
--
--   * item_classes and order_type_code now decide whether the area may serve
--     the line at all. erp.admit_wave_line() is asked before a line is put on
--     a wave: the item's class must be one the area takes, and where the line
--     names the order it is for, that order's type must be the one the area
--     serves. The refusal names the areas at that site that DO serve the line,
--     so the answer to "which area serves this wave" arrives with the question.
--     The screen gains the control that makes the second half reachable: a
--     wave line may now name the order it is for.
--
--   * min_quantity is the floor the area is kept at, which is what a minimum
--     beside a maximum means and what the page's own summary — "minimum and
--     maximum levels" — has always claimed. erp.release_replenishment_target()
--     works out what a shortfall should move: a push area still tops up to its
--     maximum, and under both modes a replenishment raised for this wave never
--     leaves the area below its minimum. An area with no minimum, and the
--     demonstration's minimum of nought, move exactly what they moved before.
--
--   * channel_code is NOT wired, and that is the honest answer rather than a
--     contrived one. Nothing in this product records the channel a demand
--     arrived through: not the order, not the delivery, not the wave. The only
--     other channel in the schema is erp.forecast.channel_code, free text on a
--     forecast, matched against nothing. Making the area's channel scope
--     anything would mean first inventing a channel on demand — a vocabulary,
--     a control on every order, and a rule for what an unstated channel means.
--     That is a product decision, not a repair, so the field stays registered
--     and the screen now says plainly that it is a label. A box that says
--     "Leave empty to serve every channel" implies a filter; a box that says it
--     is a label for the people who work here does not.
--
-- ── B. The supplier's own code ───────────────────────────────────────────────
--
-- erp.item_supplier.supplier_item_code is typed in under "What the supplier
-- calls this product on their paperwork" and was printed on nothing the
-- supplier sees. It still would be if it were only resolved at print time,
-- because a supplier's code changes and an order is what it was when it was
-- placed. So it is STAMPED ON THE LINE: erp.document_line carries
-- supplier_item_code, a before-insert trigger fills it from the supplier row
-- for the document's own party, and erp_document() hands it to the screen
-- beside the description. erp_ref.output_field gains it as a line field, so a
-- purchase order printed through an output template carries the supplier's own
-- reference next to ours.
--
-- The trigger rather than erp.add_document_line() on purpose: a purchase order
-- line is created four ways — that routine, erp.convert_document() from a
-- requisition, erp.raise_drop_ship_order(), and erp.firm_planned_order(), which
-- inserts into erp.document_line raw. A rule that lives on the table is the
-- only one all four obey. It fills nothing on a sales line, because a customer
-- has no erp.item_supplier row for the product.
--
-- What this does NOT do, stated so nobody looks for it: there is no purchase
-- order PDF and no purchase order email in this product. The whole contract,
-- issue, archive and send path is sales-invoice only —
-- erp.sales_invoice_contract() refuses any other document type outright — and
-- a purchase order reaches its supplier as a state change ("Send to supplier")
-- and whatever the buyer does outside Clove. Building one is a piece of work
-- in its own right. Lines already raised keep a blank code: the trigger fires
-- on insert, and rewriting history to what a supplier calls the product today
-- would be the opposite of what an order is.
--
-- ── C. The sourcing split ────────────────────────────────────────────────────
--
-- erp.item_supplier.split_pct is offered as "Sourcing split (%)" under "Leave
-- empty unless the requirement is deliberately divided", and the page says
-- "the sourcing split may not exceed the whole requirement".
--
-- The second sentence is true and always was: erp_set_item_supplier() sums the
-- splits for the product and site and refuses a set that totals more than a
-- hundred. 20260916430000 cannot see that read, and says so in its own header
-- — "a reference inside a routine that writes the same column is not a read"
-- — so the register calls the column unread. That is the check being careful,
-- not the product lying.
--
-- The first sentence is the lie, and it is not repaired here. Dividing a
-- requirement across suppliers means firming a planned order into SEVERAL
-- purchase orders, and firming does not resolve a supplier at all today:
-- erp.run_planning() writes erp.planned_order without supplier_party_id, and
-- erp.firm_planned_order() hands that null straight to erp.create_document(),
-- so an MRP-firmed purchase order is raised with no supplier on it. Splitting
-- would mean teaching planning to resolve suppliers, changing what firming
-- returns from one document to many, and changing its door, its screen and its
-- process-flow step with it. That is a larger change than the field looks, and
-- it is a product decision about how a divided requirement is ordered, chased
-- and received.
--
-- So the field is made honest instead, which is what the register's own
-- instruction says to do with a gap: the hint says what it is — a share
-- recorded for the buyer, not a division the system performs — the page's
-- sentence is narrowed to the rule that is actually enforced, and the register
-- row stays with the whole of that as its reason.
--
-- Proof: erp_test.scoped_settings_suite() (9 cases, wrapper pinned) and the
-- build step "Every value a screen writes is read by something", which now
-- accounts for four fewer columns.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A marshalling area admits the line, or says which one would
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.admit_wave_line(
  p_wave_id     uuid,
  p_item_id     uuid,
  p_document_id uuid default null)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  a        erp.release_area%rowtype;
  v_class  text;
  v_type   text;
  v_served text;
begin
  -- The area the wave was opened over. A wave whose area has gone admits
  -- everything: erp_add_wave_line()'s own foreign key is what says otherwise.
  select ra.* into a
    from erp.release_area ra
    join erp.release_wave w
      on w.tenant_id = ra.tenant_id and w.release_area_id = ra.id
   where ra.tenant_id = v_tenant and w.id = p_wave_id;
  if not found then
    return;
  end if;

  select i.item_class into v_class
    from erp.item i
   where i.tenant_id = v_tenant and i.id = p_item_id;

  -- The order the line is for, where it names one. That is where an order type
  -- lives in this product: a document's type is its type.
  if p_document_id is not null then
    select dt.code into v_type
      from erp.document d
      join erp.document_type dt
        on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
     where d.tenant_id = v_tenant and d.id = p_document_id;
  end if;

  -- Which areas at this site would take this line. Computed before the
  -- refusals so the answer can be handed to whoever is being refused.
  select string_agg(ra.code, ', ' order by ra.code) into v_served
    from erp.release_area ra
   where ra.tenant_id = v_tenant
     and ra.site_id = a.site_id
     and ra.status = 'active'::erp.record_status
     and (ra.item_classes is null
          or coalesce(array_length(ra.item_classes, 1), 0) = 0
          or coalesce(v_class, '') = any (ra.item_classes))
     and (ra.order_type_code is null
          or v_type is null
          or ra.order_type_code = v_type);

  if a.item_classes is not null
     and coalesce(array_length(a.item_classes, 1), 0) > 0
     and not (coalesce(v_class, '') = any (a.item_classes)) then
    raise exception
      'CLOVEERP_RELEASE_AREA_CLASS: % takes %, and this product is %',
      a.code, array_to_string(a.item_classes, ', '),
      coalesce(nullif(v_class, ''), 'in no class at all')
      using errcode = '23514',
            hint = coalesce('Put the line on ' || v_served || ' instead, or widen the '
                            || 'product classes this marshalling area serves.',
                            'No marshalling area at this site serves this product''s '
                            || 'class. Widen one, or classify the product.');
  end if;

  if a.order_type_code is not null and v_type is not null
     and a.order_type_code <> v_type then
    raise exception
      'CLOVEERP_RELEASE_AREA_ORDER_TYPE: % serves % orders, and this line is on a % order',
      a.code, a.order_type_code, v_type
      using errcode = '23514',
            hint = coalesce('Put the line on ' || v_served || ' instead, or clear the '
                            || 'order type on this marshalling area so it serves every one.',
                            'No marshalling area at this site serves this order type. '
                            || 'Clear the order type on one of them.');
  end if;
end;
$$;

revoke all on function erp.admit_wave_line(uuid, uuid, uuid) from public, anon, authenticated;

comment on function erp.admit_wave_line(uuid, uuid, uuid) is
  'Whether the marshalling area a wave was opened over serves this line: the '
  'product''s class must be one the area takes, and where the line names the '
  'order it is for, that order''s type must be the one the area serves. '
  'Refuses with the areas at that site that would serve it, so the answer to '
  '"which area serves this wave" arrives with the question.';

select erp.register_refusal('CLOVEERP_RELEASE_AREA_CLASS',
  'Putting a product on a wave whose marshalling area does not serve that product''s class.',
  'A marshalling area states the product classes it serves. An area set up for chilled goods that quietly took ambient ones would be a scope that scopes nothing, which is what this setting was until 20260916510000.',
  'Open the wave over a marshalling area that serves this product''s class, or tick that class on the area — no classes ticked serves every product.');

select erp.register_refusal('CLOVEERP_RELEASE_AREA_ORDER_TYPE',
  'Putting a line for one kind of order on a wave whose marshalling area serves another.',
  'A marshalling area may be set up for one order type. Releasing another kind of order through it would mix runs the area was separated to keep apart.',
  'Open the wave over a marshalling area that serves this order type, or clear the order type on the area so it serves every one.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. A minimum is a floor, and a replenishment respects it
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.release_replenishment_target(
  p_release_area_id uuid,
  p_shortfall       numeric,
  p_in_area         numeric)
returns numeric
language plpgsql
stable
set search_path = ''
as $$
declare
  a      erp.release_area%rowtype;
  v_here numeric := greatest(coalesce(p_in_area, 0), 0);
  v_out  numeric := greatest(coalesce(p_shortfall, 0), 0);
begin
  select ra.* into a
    from erp.release_area ra
   where ra.tenant_id = erp.require_tenant_id() and ra.id = p_release_area_id;
  if not found then
    return v_out;
  end if;

  -- Push tops the area up to its maximum, exactly as it has since 20260830132704.
  if a.replenishment_mode = 'push' and a.max_quantity is not null then
    v_out := greatest(v_out, a.max_quantity - v_here);
  end if;

  -- And the minimum is a floor under both modes. "Minimum" sits beside
  -- "Maximum" on the marshalling area screen and the page promises "minimum
  -- and maximum levels"; a level is something stock is kept at, so a
  -- replenishment raised for this wave never leaves the area below it.
  if a.min_quantity is not null and a.min_quantity - v_here > v_out then
    v_out := a.min_quantity - v_here;
  end if;

  return v_out;
end;
$$;

revoke all on function erp.release_replenishment_target(uuid, numeric, numeric) from public, anon, authenticated;

comment on function erp.release_replenishment_target(uuid, numeric, numeric) is
  'How much a shortfall should move into a marshalling area: at least what the '
  'wave is short, up to the maximum where the area pushes, and never leaving '
  'the area below its minimum. An area with neither level moves the shortfall '
  'and nothing more.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The two live bodies, patched where they stand
-- -----------------------------------------------------------------------------
-- Both were last written in a file and then rewritten in place by
-- 20260904980000, so pg_get_functiondef() is the only honest source for what
-- they say today. Each needle is asserted to appear exactly once.
-- ═════════════════════════════════════════════════════════════════════════════

do $add_line$
declare
  v_sig    constant text := 'public.erp_add_wave_line(uuid,uuid,numeric,uuid)';
  v_def    text := pg_get_functiondef(
                     'public.erp_add_wave_line(uuid,uuid,numeric,uuid)'::regprocedure);
  v_needle constant text := $needle$  insert into erp.release_wave_line (tenant_id, wave_id, item_id, quantity, document_id)$needle$;
  v_new    constant text := $new$  -- The marshalling area's scope decides whether it serves this line
  -- (20260916510000). Before this, the four fields on the area tested nothing.
  perform erp.admit_wave_line(p_wave_id, p_item_id, p_document_id);

  insert into erp.release_wave_line (tenant_id, wave_id, item_id, quantity, document_id)$new$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not insert its wave line exactly once as 20260830132704 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$add_line$;

do $allocate$
declare
  v_sig    constant text := 'public.erp_allocate_release_wave(uuid)';
  v_def    text := pg_get_functiondef(
                     'public.erp_allocate_release_wave(uuid)'::regprocedure);
  v_needle constant text := $needle$      v_target := case
        when a.replenishment_mode = 'push' and a.max_quantity is not null
          then greatest(v_short, a.max_quantity - v_here)
        else v_short
      end;
$needle$;
  v_new    constant text := $new$      -- Push to the maximum, pull to the shortfall, and neither below the
      -- minimum the area is kept at (20260916510000).
      v_target := erp.release_replenishment_target(a.id, v_short, v_here);
$new$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not work out its replenishment target exactly once as 20260830134027 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$allocate$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A purchase order line carries the supplier's own code
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.document_line add column if not exists supplier_item_code text;

comment on column erp.document_line.supplier_item_code is
  'What the supplier calls this product on their own paperwork, as it stood '
  'when the line was raised. Stamped from erp.item_supplier by '
  'erp.stamp_supplier_item_code(); blank on a line whose party is not a '
  'supplier of the product, and never rewritten when their code changes.';

create or replace function erp.stamp_supplier_item_code()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_party uuid;
  v_site  uuid;
  v_code  text;
begin
  -- A code already given wins: an operator typing the supplier's reference on
  -- the line is saying something this rule has no business overwriting.
  if new.supplier_item_code is not null or new.item_id is null then
    return new;
  end if;

  select d.party_id, d.site_id into v_party, v_site
    from erp.document d
   where d.tenant_id = new.tenant_id and d.id = new.document_id;

  if v_party is null then
    return new;
  end if;

  -- The site's own row first, then the default, then by preference. A
  -- customer has no erp.item_supplier row for the product, so a sales line
  -- takes nothing from here and the stamp is silent.
  select s.supplier_item_code into v_code
    from erp.item_supplier s
   where s.tenant_id = new.tenant_id
     and s.item_id = new.item_id
     and s.party_id = v_party
     and s.status = 'active'::erp.record_status
     and s.valid_to is null
     and s.supplier_item_code is not null
     and btrim(s.supplier_item_code) <> ''
   order by (s.site_id is not null and s.site_id = v_site) desc,
            s.is_default desc, s.preference_rank
   limit 1;

  new.supplier_item_code := nullif(btrim(v_code), '');
  return new;
end;
$$;

revoke all on function erp.stamp_supplier_item_code() from public, anon, authenticated;

comment on function erp.stamp_supplier_item_code() is
  'Fills a document line''s supplier_item_code from the supplier row for the '
  'document''s own party, so a purchase order raised any of the four ways this '
  'product raises one carries what the supplier calls the product. A rule on '
  'the table rather than in a routine because erp.firm_planned_order() inserts '
  'the line raw.';

drop trigger if exists t_document_line_supplier_code on erp.document_line;
create trigger t_document_line_supplier_code
  before insert on erp.document_line
  for each row execute function erp.stamp_supplier_item_code();

-- ── The screen sees it ───────────────────────────────────────────────────────

do $document$
declare
  v_sig    constant text := 'public.erp_document(uuid)';
  v_def    text := pg_get_functiondef('public.erp_document(uuid)'::regprocedure);
  v_needle constant text := $needle$        'tax_minor', l.tax_minor) order by l.line_no)$needle$;
  v_new    constant text := $new$        'tax_minor', l.tax_minor,
        'supplier_item_code', l.supplier_item_code) order by l.line_no)$new$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not close its line object exactly once as 20260916030000 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$document$;

-- ── And it can be printed ────────────────────────────────────────────────────

insert into erp_ref.output_field (code, source, label_key, description, is_line, seq) values
  ('supplier_item_code', 'line', 'output.field.supplier_item_code',
   'What the supplier calls this product on their own paperwork.', true, 215)
on conflict (code) do update set
  source = excluded.source, label_key = excluded.label_key,
  description = excluded.description, is_line = excluded.is_line, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
  ('output.field.supplier_item_code', 'en', 'Their code',
   'The label an output template prints over the supplier''s own reference for '
   'a product, beside our own code and description.')
on conflict (key, locale) do nothing;

do $render$
declare
  v_sig    constant text := 'erp.render_output_template(text,uuid,text)';
  v_def    text := pg_get_functiondef(
                     'erp.render_output_template(text,uuid,text)'::regprocedure);
  v_needle constant text := $needle$                    when 'quantity_fulfilled' then to_jsonb(l.quantity_fulfilled)$needle$;
  v_new    constant text := $new$                    when 'quantity_fulfilled' then to_jsonb(l.quantity_fulfilled)
                    when 'supplier_item_code' then to_jsonb(l.supplier_item_code)$new$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not resolve quantity_fulfilled exactly once as 20260904170000 wrote it', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$render$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The register, brought up to date
-- -----------------------------------------------------------------------------
-- Four rows go because something now decides on the column; the register
-- refuses a row kept past its reason, so leaving them would fail the build.
-- Two stay, and their reasons are rewritten to say what was decided and why.
-- ═════════════════════════════════════════════════════════════════════════════

delete from erp_meta.write_only_column
 where (schema_name, table_name, column_name) in (
   ('erp', 'release_area', 'item_classes'),
   ('erp', 'release_area', 'order_type_code'),
   ('erp', 'release_area', 'min_quantity'),
   ('erp', 'item_supplier', 'supplier_item_code'));

update erp_meta.write_only_column
   set rationale =
     'Deliberate as at 16 September 2026, and a gap closed by saying so rather than by wiring it. '
     'Nothing in this product records the channel a demand arrived through: not the order, not the '
     'delivery, not the wave. The only other channel in the schema is erp.forecast.channel_code, '
     'free text on a forecast, matched against nothing. Scoping an area by channel would mean first '
     'inventing a channel on demand — a vocabulary, a control on every order, and a rule for what an '
     'unstated channel means — which is a product decision rather than a repair. So it is a label for '
     'the people who work in the area, and 20260916510000 made the screen say so instead of '
     '"Leave empty to serve every channel", which implied a filter. The area''s order type and product '
     'classes, which had the same defect, are wired.'
 where schema_name = 'erp' and table_name = 'release_area' and column_name = 'channel_code';

update erp_meta.write_only_column
   set rationale =
     'A KNOWN GAP as at 16 September 2026, narrowed and left open deliberately by 20260916510000. '
     'The split still divides nothing: firming a planned order raises one purchase order with one '
     'line, and erp.run_planning() does not resolve a supplier at all — it writes erp.planned_order '
     'with no supplier_party_id, so an MRP-firmed order is raised with no supplier on it. Dividing a '
     'requirement would mean teaching planning to resolve suppliers, changing what firming returns '
     'from one document to many, and changing its door and its screen with it. Worth knowing about '
     'this row: the column IS read — erp_set_item_supplier() sums the splits for the product and site '
     'and refuses a set totalling more than a hundred — but the read sits in the routine that writes '
     'the column, which this check does not count, and says so in its own header. The screen now '
     'calls the field a share recorded for the buyer rather than a division the system performs.'
 where schema_name = 'erp' and table_name = 'item_supplier' and column_name = 'split_pct';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The words
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string declared at its call site and rendered through ui(). ' || v.why
  from (values
    ('An area is a scope, not a place on a map: a site, a location, the order type and the product classes it serves. A wave will not take a line the area does not serve.',
     'Said over the marshalling area controls, because the order type and the classes now decide what an area takes.'),
    ('A label for the people who work in this area. Nothing is matched against it: the area serves every channel.',
     'Said under the channel, because the box used to say "Leave empty to serve every channel" and served every channel either way.'),
    ('The level the area is kept at. A replenishment raised for a wave never leaves it below this.',
     'Said under the minimum, because a minimum beside a maximum reads as a level and now is one.'),
    ('Order this line is for',
     'The control that lets a wave line name its order, so the marshalling area''s order type has something to be compared with.'),
    ('Optional. A marshalling area set up for one order type only takes lines from an order of that type.',
     'Said under that control, because naming the order is what makes the area''s order type bite.'),
    ('One supplier is the default for a product at a site; the rest are ranked alternatives. A regulated product cannot default to a supplier that is not on the approved list, and the shares recorded against a product''s suppliers may not add to more than the whole.',
     'The product-suppliers page''s opening sentence, narrowed to the rule that is actually enforced.'),
    ('A share recorded for the buyer, not a division the system performs: purchasing resolves one supplier. The shares against a product may not add to more than the whole.',
     'Said under the sourcing split, because "Leave empty unless the requirement is deliberately divided" implied a division that does not happen.')
) as v(text, why)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.scoped_settings_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases  integer := 0;
  v_tenant uuid; v_admin uuid; v_token text;
  v_entity uuid; v_site uuid; v_ccy char(3);
  v_chilled uuid; v_ambient uuid;
  v_supp uuid; v_cust uuid;
  v_area uuid; v_wave uuid; v_open uuid;
  v_po uuid; v_so uuid;
  v_code text; v_sales text;
  v_target numeric;
  v_ok boolean; v_msg text;
begin
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-scoped-settings', 'Scoped settings suite',
                              'admin@zz-scoped-settings.test', 'Scoped Settings Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000ef', 'admin@zz-scoped-settings.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000ef')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);

  select l.entity_id, l.currency into v_entity, v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
  select s.id into v_site from erp.site s where s.tenant_id = v_tenant order by s.code limit 1;
  select p.id into v_supp from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'supplier' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;
  select p.id into v_cust from erp.party p
    join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
     and pr.role_kind = 'customer' and pr.status = 'active'
   where p.tenant_id = v_tenant order by p.code limit 1;

  -- Two products in two classes, built rather than hoped for: the
  -- demonstration classifies nothing, so the fixture does.
  select i.id into v_chilled from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
   order by i.code limit 1;
  select i.id into v_ambient from erp.item i
   where i.tenant_id = v_tenant and i.status = 'active'::erp.record_status
     and i.id <> v_chilled
   order by i.code limit 1;
  update erp.item set item_class = 'ZZCHILLED' where tenant_id = v_tenant and id = v_chilled;
  update erp.item set item_class = 'ZZAMBIENT' where tenant_id = v_tenant and id = v_ambient;

  -- An area that serves chilled goods on purchase orders only, kept at 40.
  perform public.erp_upsert_release_area(
    v_site, 'ZZ-CHILL', 'Chilled marshalling', null, 'pull',
    null, 'purchase_order', 'ZZCHILLED', 40, 500, 24, true);
  select ra.id into v_area from erp.release_area ra
   where ra.tenant_id = v_tenant and ra.site_id = v_site and ra.code = 'ZZ-CHILL';

  -- And one that serves everything, so the refusals have something to name.
  perform public.erp_upsert_release_area(
    v_site, 'ZZ-OPEN', 'Open marshalling', null, 'pull',
    null, null, null, null, null, 24, true);
  select ra.id into v_open from erp.release_area ra
   where ra.tenant_id = v_tenant and ra.site_id = v_site and ra.code = 'ZZ-OPEN';

  v_wave := (public.erp_open_release_wave(v_area, 'ZZ-WAVE-1', 'scoped settings suite')
             ->> 'wave_id')::uuid;

  -- ── 1. A product the area's classes do not cover is refused ──────────────
  v_cases := v_cases + 1;
  begin
    perform public.erp_add_wave_line(v_wave, v_ambient, 5);
    v_ok := false; v_msg := 'an ambient product went onto a chilled area';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_RELEASE_AREA_CLASS%';
    v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a wave line the marshalling area''s product classes do not cover is refused';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 2. And one they do cover is not ──────────────────────────────────────
  v_cases := v_cases + 1;
  begin
    perform public.erp_add_wave_line(v_wave, v_chilled, 5);
    v_ok := true; v_msg := 'the chilled product was admitted';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a wave line whose product class the area serves is admitted';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 3. An order of the wrong type is refused ─────────────────────────────
  v_cases := v_cases + 1;
  v_so := erp.create_document('sales_order', v_entity, v_site, v_cust,
                              current_date, v_ccy, 'ZZSS-SO', '{}'::jsonb);
  begin
    perform public.erp_add_wave_line(v_wave, v_chilled, 5, v_so);
    v_ok := false; v_msg := 'a sales order line went onto a purchase-order area';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_RELEASE_AREA_ORDER_TYPE%';
    v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a wave line naming an order of a type the area does not serve is refused';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 4. And one of the right type is not ──────────────────────────────────
  v_cases := v_cases + 1;
  v_po := erp.create_document('purchase_order', v_entity, v_site, v_supp,
                              current_date, v_ccy, 'ZZSS-PO', '{}'::jsonb);
  begin
    perform public.erp_add_wave_line(v_wave, v_chilled, 5, v_po);
    v_ok := true; v_msg := 'the purchase order line was admitted';
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 120);
  end;
  case_name := 'a wave line naming an order of the type the area serves is admitted';
  passed := v_ok;
  detail := v_msg;
  return next;

  -- ── 5. The minimum is a floor a replenishment respects ───────────────────
  v_cases := v_cases + 1;
  -- Short 5, with 10 already in an area kept at 40: the move is 30, not 5.
  v_target := erp.release_replenishment_target(v_area, 5, 10);
  case_name := 'a replenishment moves enough to leave the area at its minimum, not merely the shortfall';
  passed := v_target = 30
        and erp.release_replenishment_target(v_open, 5, 10) = 5;
  detail := format('an area kept at 40 with 10 in it and 5 short moves %s; an area with no levels moves %s',
                   v_target, erp.release_replenishment_target(v_open, 5, 10));
  return next;

  -- ── 6. A purchase order line carries the supplier's own code ─────────────
  -- Built rather than assumed: whatever the demonstration seeded for this
  -- product goes first, so exactly one supplier row decides the answer.
  v_cases := v_cases + 1;
  delete from erp.item_supplier s
   where s.tenant_id = v_tenant and s.item_id = v_chilled;
  perform public.erp_set_item_supplier(
    v_chilled, v_supp, null, 1, false, null, true, 'NW-4471', 7, 1,
    'scoped settings suite');
  perform erp.add_document_line(v_po, v_chilled, 2, 1000, 'a line the supplier will read');
  select l.supplier_item_code into v_code
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = v_po and l.item_id = v_chilled
   order by l.line_no desc limit 1;
  case_name := 'a purchase order line carries what the supplier calls the product';
  passed := v_code = 'NW-4471';
  detail := format('the line says %s', coalesce(v_code, '(nothing)'));
  return next;

  -- ── 7. And a sales line does not invent one ──────────────────────────────
  v_cases := v_cases + 1;
  perform erp.add_document_line(v_so, v_chilled, 2, 1000, 'a line the customer will read');
  select l.supplier_item_code into v_sales
    from erp.document_line l
   where l.tenant_id = v_tenant and l.document_id = v_so and l.item_id = v_chilled
   order by l.line_no desc limit 1;
  case_name := 'a sales line takes no supplier code, because the customer is not a supplier of it';
  passed := v_sales is null;
  detail := format('the sales line says %s', coalesce(v_sales, '(nothing)'));
  return next;

  -- ── 8. The register says what was and was not wired ──────────────────────
  v_cases := v_cases + 1;
  case_name := 'the register accounts for the channel and the split, and no longer for the four that are read';
  passed := exists (select 1 from erp_meta.write_only_column g
                     where g.schema_name = 'erp' and g.table_name = 'release_area'
                       and g.column_name = 'channel_code')
        and exists (select 1 from erp_meta.write_only_column g
                     where g.schema_name = 'erp' and g.table_name = 'item_supplier'
                       and g.column_name = 'split_pct')
        and not exists (select 1 from erp_meta.write_only_column g
                         where g.schema_name = 'erp'
                           and ((g.table_name = 'release_area'
                                 and g.column_name in ('item_classes', 'order_type_code', 'min_quantity'))
                             or (g.table_name = 'item_supplier'
                                 and g.column_name = 'supplier_item_code')));
  detail := format('%s row(s) left in the register', (select count(*) from erp_meta.write_only_column));
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- ── 9. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-scoped-settings')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000ef');
  detail := 'zz-scoped-settings rolled back with its areas, its wave and its orders';
  return next;

  if v_cases <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: scoped_settings_suite ran % cases, expected 9', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.scoped_settings_suite() from public, anon;

create or replace function erp_test.assert_scoped_settings_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _scoped_settings on commit drop as
    select * from erp_test.scoped_settings_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _scoped_settings;
  drop table _scoped_settings;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SCOPED_SETTINGS_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 9 then
    raise exception 'CLOVEERP_SUITE_SHRANK: scoped_settings_suite ran % cases, expected 9', v_all;
  end if;
  return format('a setting that scopes something: %s/%s cases passed', v_all, v_all);
end;
$$;

revoke all on function erp_test.assert_scoped_settings_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_write_only_columns();
select erp_test.assert_write_only_column_suite();
select erp_test.assert_scoped_settings_suite();

select erp.assert_output_templates_sound();
select erp.assert_refusals_name_next_action();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_writes_name_their_rows();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
