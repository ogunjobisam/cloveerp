set lock_timeout = '30s';

-- =============================================================================
-- 20260918200000  The demonstration gives money back
-- -----------------------------------------------------------------------------
-- The Definition of Done's master gate asks for a seeded trading month holding
-- one of each of seven transactions. Two of them are a supplier credit note and
-- a customer credit note. 20260918170000 built both mechanisms — the types, the
-- doors, the postings, the reason on the movement — and the seeded month used
-- neither, so the demonstration could sell and buy and could not give anybody
-- their money back. Nothing said so, because nothing asked.
--
-- ── 1. THE REASONS A RETURN MAY GIVE ─────────────────────────────────────────
--
-- Six of the eighteen erp_ref.movement_type rows declare requires_reason and
-- both return types are among them; erp.apply_stock_movement() refuses a
-- movement of such a type without one, and both doors ask
-- erp.check_reason_code('RETURN_CUSTOMER' / 'RETURN_SUPPLIER', …) as well.
--
-- The demonstration had no reason codes at all. erp.reason_code is tenant data
-- filled by the base content pack, and erp.ensure_demo_configuration() has
-- never applied a pack — it calls the installers directly. So the movement
-- would have been written with a code the organisation does not keep, and the
-- returns report would have grouped by words nobody chose. The two return
-- categories are now installed with the demonstration, generated from
-- erp_ref.reason_code — the same catalogue erp_ref.pack_item is generated from,
-- so the demonstration and the pack cannot drift apart. Only what is missing is
-- added, so a demonstration somebody has shaped keeps the list it has, and a
-- second call installs nothing.
--
-- Both document types were already reaching the demonstration: 20260918170000
-- needled erp.ensure_demo_configuration() to take the sales-lifecycle and
-- procurement-controls upgrades, and both blocks sit above the numbering rule
-- that strips the year, so CN- and PCN- numbers carry no year like every other
-- demonstration number. That was read rather than assumed.
--
-- ── 2. TWO MORE DAYS OF THE WEEK ─────────────────────────────────────────────
--
-- erp.seed_demo_history() builds one day at a time (20260914072000), and
-- 20260918100000 hung the trunk run to the other site on Wednesday. Two more
-- named weekdays, for the same reasons that one was named rather than drawn:
-- any run of seven days holds each of them, so the month always holds four or
-- five of each, and neither block draws on random(), so every other document a
-- day builds is the document it built before this migration.
--
--   TUESDAY — what should not have come goes back. The goods-in team picks the
--   most recent posted receipt still whole, returns a tenth of one line through
--   erp.raise_supplier_credit_note() under DAMAGED_ARRIVAL, and issues it: the
--   goods leave the bulk store at what they cost and what we owe the supplier
--   falls. Tuesday because a return to a supplier is the week's first tidying
--   up, and because the lorry to the distribution centre runs on Wednesday and
--   the two should not share a day — the transfer sizes its load from what the
--   bulk store holds, and a return out of the same shelf on the same morning
--   would make one day's arithmetic depend on the other's.
--
--   FRIDAY — the week's returns are credited. A quarter of one line of the
--   most recent sales invoice comes back through
--   erp.raise_customer_credit_note() under DAMAGED_TRANSIT, and the note is
--   issued: revenue reverses, the customer owes less, and the goods return to
--   the shelf at what they cost rather than at what they sold for. Friday
--   because by then the week's despatches and invoices are behind it, and
--   because it shares a day with neither of the other two.
--
-- Both are dated the day they ran and given that day's DEMO- reference, the way
-- the builder dates and references its invoices, which is what keeps a slice
-- idempotent. Both go through the doors a person uses and neither writes a
-- table directly. Both choose nothing at all if the month has nothing to credit
-- yet, which is the honest answer on the first day of a month: a credit note
-- needs a document behind it, and the first days of a month have none.
--
-- The returned goods land in the site's goods-in place, which is where a
-- receiving bay is for, and where the builder's own despatches never look — it
-- picks from the bulk store by name. So a customer return sits at goods in and
-- is not sold again, and the sales the month builds are the sales it built
-- before.
--
-- Deployed bodies, asserted needles. erp.ensure_demo_configuration() carries
-- ten patches since 20260905010000 defined it whole and erp.seed_demo_history()
-- six; a re-emission from any file would drop them. Each needle is counted
-- before it is replaced and the patches the body already had are asserted
-- afterwards.
--
-- ── 3. PROOF ─────────────────────────────────────────────────────────────────
--
-- erp_test.demo_history_suite() gains four cases and a second five-day call, so
-- it seeds the ten days the build seeds first rather than five: five
-- consecutive days can miss two weekdays, and a month that holds a credit note
-- by luck is exactly what the DoD audit found for part despatch. Ten days hold
-- every weekday. The suite now says the register is there, that the month
-- credits a customer and returns goods to a supplier — each issued, on its own
-- weekday, under that day's reference, with the reason on the movement and the
-- journal against it — and that stock, the subledger and inventory still
-- reconcile with both in the month. Its count is pinned at fourteen in the
-- suite and in the wrapper.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The demonstration keeps the reasons a return may give
-- ═════════════════════════════════════════════════════════════════════════════

do $reasons$
declare
  v_sig  constant text := 'erp.ensure_demo_configuration(uuid,uuid)';
  v_def  text := pg_get_functiondef('erp.ensure_demo_configuration(uuid,uuid)'::regprocedure);
  -- The head of the master data section. Reason codes are master data, and the
  -- unit is the first thing the section makes.
  v_n    constant text := E'  v_uom := erp.ensure_base_uom(p_tenant_id, p_principal);\n';
  v_r    constant text := $r$  -- The reasons a return is allowed to give (20260918200000). Six of the
  -- eighteen movement types refuse a movement without a reason code and both
  -- return types are among them, so an organisation that credits anybody needs
  -- a register to choose from, and erp.ensure_demo_configuration() applies no
  -- content pack. Generated from erp_ref.reason_code, the catalogue the base
  -- pack itself is generated from, so the two cannot drift. Only what is
  -- missing is added: a demonstration somebody has shaped keeps its list, and
  -- a code somebody switched off stays off.
  if exists (select 1 from erp_ref.reason_code rc
              where rc.category_code in ('RETURN_CUSTOMER', 'RETURN_SUPPLIER')
                and not exists (select 1 from erp.reason_code x
                                 where x.tenant_id = p_tenant_id
                                   and x.category_code = rc.category_code
                                   and x.code = rc.code)) then
    for r in
      select rc.category_code, rc.code, rc.name,
             rc.requires_note, rc.requires_approval, rc.seq
        from erp_ref.reason_code rc
       where rc.category_code in ('RETURN_CUSTOMER', 'RETURN_SUPPLIER')
         and not exists (select 1 from erp.reason_code x
                          where x.tenant_id = p_tenant_id
                            and x.category_code = rc.category_code
                            and x.code = rc.code)
       order by rc.category_code, rc.seq
    loop
      perform erp.upsert_reason_code(r.category_code, r.code, r.name,
                                     r.requires_note, r.requires_approval, r.seq);
    end loop;
    v_did := v_did || '"return reasons"'::jsonb;
  end if;

  v_uom := erp.ensure_base_uom(p_tenant_id, p_principal);
$r$;
  v_hits integer;
begin
  if position('RETURN_CUSTOMER' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % already keeps return reasons; this migration would keep them twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: expected the base unit to be made once in %, found %',
      v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and the register took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('RETURN_SUPPLIER' in v_def) = 0
     or position('''MAIN-WH'', ''Main warehouse''' in v_def) = 0
     or position('chart_8_1' in v_def) = 0                                   -- 20260905020000
     or position('renamed ACME' in v_def) = 0                                -- 20260905030000
     or position('"inventory upgraded"' in v_def) = 0                        -- 20260906141000
     or position('"procurement controls"' in v_def) = 0                      -- 20260909212619
     or position('erp.seed_demo_item_suppliers(p_tenant_id)' in v_def) = 0   -- 20260914076000
     or position('erp.configure_tax(''GB'', 20)' in v_def) = 0               -- 20260916030000
     or position('entity_tax_registration' in v_def) = 0                     -- 20260916090000
     or position('"site transfers"' in v_def) = 0                            -- 20260917130000
     or position('''NORTH-DC'', ''Northern distribution centre''' in v_def) = 0  -- 20260918100000
     or position('"customer credit note"' in v_def) = 0                      -- 20260918170000
     or position('"supplier credit note"' in v_def) = 0 then                 -- 20260918170000
    raise exception
      'CLOVEERP_DEMO_CONFIGURATION_UNRECOGNISED: % dropped a patch it already had, or did not take its return reasons', v_sig;
  end if;
end
$reasons$;

comment on function erp.ensure_demo_configuration(uuid, uuid) is
  'Takes a demonstration organisation from provisioned to able to trade, once: '
  'sandbox, the installers, four years of periods, posting rules in force '
  'from two years back, numbering without the year, two sites of the trading '
  'company — a main warehouse and a distribution centre, each with its '
  'locations — the reasons a return may give, and master data to trade with. '
  'Idempotent; refused in a live environment.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Tuesday goods go back, Friday the customer is credited
-- ═════════════════════════════════════════════════════════════════════════════

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def  text := pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure);
  -- The end of the day, after the Wednesday lorry. What is built last in a day
  -- is built from what the day left on the shelf and on the ledger.
  v_n    constant text := E'  end loop days;\n';
  v_r    constant text := $r$  -- ── What should not have come, going back ────────────────────────────────
  -- Every Tuesday the goods-in team sends a tenth of one receipt line back to
  -- the supplier it came from (20260918200000): raised against the receipt
  -- through erp.raise_supplier_credit_note() under a reason the organisation
  -- keeps in its register, and issued, so the goods leave the bulk store at
  -- what they cost and what we owe the supplier falls by what is credited.
  --
  -- Tuesday, so the return and the Wednesday lorry never share a day: both
  -- size themselves against the bulk store, and one day's arithmetic should
  -- not depend on the other's. Only a line whose goods are still on the shelf
  -- in the quantity it wants is chosen, and nothing is built if there is none.
  -- Nothing here draws on random(), so the rest of the day is what it was.
  if extract(isodow from v_day) = 2 then
    declare
      v_receipt uuid;
      v_rline   uuid;
      v_back    numeric;
      v_scn     uuid;
    begin
      select gl.document_id, gl.id, floor(gl.quantity / 10)
        into v_receipt, v_rline, v_back
        from erp.document g
        join erp.document_type gt
          on gt.tenant_id = g.tenant_id and gt.id = g.document_type_id
        join erp.document_line gl
          on gl.tenant_id = g.tenant_id and gl.document_id = g.id
       cross join lateral (
         select coalesce(sum(b.quantity), 0) as on_hand
           from erp.stock_balance b
          where b.tenant_id = v_tenant and b.site_id = v_site
            and b.location_id = v_bulk and b.item_id = gl.item_id
            and b.batch_id is null and b.serial_id is null and b.container_id is null
            and b.stock_status = 'available'::erp.stock_status) sb
       where v_bulk is not null
         and g.tenant_id = v_tenant
         and gt.code = 'goods_receipt'
         and g.site_id = v_site
         and g.their_reference like 'DEMO-%'
         and g.document_date <= v_day
         and not coalesce(gl.is_cancelled, false)
         and gl.quantity >= 10
         and gl.batch_id is null
         and floor(gl.quantity / 10) <= sb.on_hand
         and erp.object_current_state('document', g.id) = 'posted'
         and not exists (select 1 from erp.document_relation rr
                          where rr.tenant_id = v_tenant
                            and rr.to_line_id = gl.id
                            and rr.relation_kind = 'returns')
       order by g.document_date desc, gl.line_no
       limit 1;

      if v_receipt is not null and v_back >= 1 then
        v_scn := erp.raise_supplier_credit_note(
                   v_receipt, 'DAMAGED_ARRIVAL',
                   'Crushed on the pallet and refused at goods in',
                   jsonb_build_array(jsonb_build_object(
                     'line_id', v_rline, 'quantity', v_back)));
        -- Opened today and dated the day it went back, as the invoices above
        -- are, and under that day's reference, which is what keeps the slice
        -- idempotent.
        v_seq := v_seq + 1;
        update erp.document
           set document_date = v_day,
               their_reference = v_prefix || lpad(v_seq::text, 3, '0')
         where tenant_id = v_tenant and id = v_scn;
        perform erp.transition_document(v_scn, 'issue', 'demonstration');
        v_built := v_built + 1;
      end if;
    end;
  end if;

  -- ── The week's returns, credited ─────────────────────────────────────────
  -- Every Friday a quarter of one line of the week's most recent sales invoice
  -- comes back (20260918200000): raised through
  -- erp.raise_customer_credit_note() under a reason the organisation keeps,
  -- and issued, so revenue reverses, the customer owes less, and the goods
  -- return to the shelf at what they cost rather than at what they sold for.
  --
  -- Friday, because by the end of the week the despatches and invoices it
  -- credits are behind it, and because it shares a day with neither the lorry
  -- nor the supplier return. Only an invoice line that reaches a despatch and
  -- has not been credited already is chosen — a line that reaches no despatch
  -- is refused by the door, rightly, because what the goods cost would be
  -- unknown. Nothing here draws on random().
  if extract(isodow from v_day) = 5 then
    declare
      v_billed uuid;
      v_bline  uuid;
      v_credit numeric;
      v_ccn    uuid;
    begin
      select il.document_id, il.id, floor(il.quantity / 4)
        into v_billed, v_bline, v_credit
        from erp.document i
        join erp.document_type it
          on it.tenant_id = i.tenant_id and it.id = i.document_type_id
        join erp.document_line il
          on il.tenant_id = i.tenant_id and il.document_id = i.id
        join erp.document_relation gr
          on gr.tenant_id = il.tenant_id and gr.from_line_id = il.id
         and gr.relation_kind = 'invoices'
       where i.tenant_id = v_tenant
         and it.code = 'sales_invoice'
         and i.their_reference like 'DEMO-%'
         and i.document_date <= v_day
         and not coalesce(il.is_cancelled, false)
         and il.quantity >= 4
         and erp.object_current_state('document', i.id) in ('issued', 'paid')
         and not exists (select 1 from erp.document_relation rr
                          where rr.tenant_id = v_tenant
                            and rr.to_line_id = gr.to_line_id
                            and rr.relation_kind = 'returns')
       order by i.document_date desc, il.line_no
       limit 1;

      if v_billed is not null and v_credit >= 1 then
        v_ccn := erp.raise_customer_credit_note(
                   v_billed, 'DAMAGED_TRANSIT',
                   'Crushed in transit; the customer sent photographs',
                   jsonb_build_array(jsonb_build_object(
                     'line_id', v_bline, 'quantity', v_credit)));
        v_seq := v_seq + 1;
        update erp.document
           set document_date = v_day,
               their_reference = v_prefix || lpad(v_seq::text, 3, '0')
         where tenant_id = v_tenant and id = v_ccn;
        perform erp.transition_document(v_ccn, 'issue', 'demonstration');
        v_built := v_built + 1;
      end if;
    end;
  end if;

  end loop days;
$r$;
  v_hits integer;
  v_secdef boolean;
begin
  if position('erp.raise_customer_credit_note(' in v_def) > 0
     or position('erp.raise_supplier_credit_note(' in v_def) > 0 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % already credits somebody; this migration would credit them twice', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: expected the day to end once in %, found %', v_sig, v_hits;
  end if;

  execute replace(v_def, v_n, v_r);

  -- What the body already carried is still in it, and both credit notes took.
  v_def := pg_get_functiondef(v_sig::regprocedure);
  select p.prosecdef into v_secdef from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure;
  if position('erp.raise_customer_credit_note(' in v_def) = 0
     or position('erp.raise_supplier_credit_note(' in v_def) = 0
     or position('0.92 + random()::numeric * 0.16' in v_def) = 0                         -- 20260906050000
     or position('Close only what actually arrived in Received.' in v_def) = 0           -- 20260912190000
     or (length(v_def) - length(replace(v_def, 'erp.approve_my_document_tasks(v_doc, ''demonstration'')', '')))
        / length('erp.approve_my_document_tasks(v_doc, ''demonstration'')') <> 2         -- 20260914062000
     or position('<<days>>' in v_def) = 0                                                -- 20260914072000
     or position('erp.receive_transfer(v_transfer)' in v_def) = 0                        -- 20260918100000
     or (length(v_def) - length(replace(v_def, E'  end loop days;\n', ''))) / length(E'  end loop days;\n') <> 1
     or not coalesce(v_secdef, false) then                                               -- 20260914030000
    raise exception
      'CLOVEERP_DEMO_BUILDER_UNRECOGNISED: % dropped a patch it already had, or did not take its credit notes', v_sig;
  end if;
end
$history$;

comment on function erp.seed_demo_history(date, date, numeric) is
  'Builds demonstration trading one day at a time through the spine — purchase '
  'orders and receipts, sales orders, despatches, invoices and cash, quotations, '
  'requisitions, every Tuesday a return to a supplier, every Wednesday a '
  'transfer from the main warehouse to the company''s other site and every '
  'Friday a credit note to a customer — at most five days per call, starting no '
  'new day once a quarter of the caller''s statement timeout has gone, and says '
  'where the next call should start. A day already built, or inside a five-day '
  'slice built before, is skipped; refused in a live environment; every journal '
  'and movement is raised by the same bridges and doors a person''s document '
  'goes through.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The suite says the month holds both
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Four cases and a second five-day call, needled on to the deployed body:
-- 20260914062000 put erp_test.approve_document() into it and a re-emission from
-- the file would drop that, so it is asserted still present afterwards.
--
-- The second call is what the extra cases need. The suite built five days, and
-- five consecutive days can miss two weekdays entirely; ten hold every one. It
-- is the same call the build makes — supabase/ci/seed_demo.sql seeds six of
-- them — so the days are built exactly as the demonstration's are.

do $cases$
declare
  v_sig  constant text := 'erp_test.demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.demo_history_suite()'::regprocedure);

  -- The last of the declarations.
  v_o1 constant text := $o1$  v_old_at timestamptz; v_old_on date; v_new_at timestamptz;
$o1$;
  v_r1 constant text := $q1$  v_old_at timestamptz; v_old_on date; v_new_at timestamptz;
  -- What the month gave back (20260918200000)
  v_back   numeric; v_gone numeric; v_dr bigint; v_cr bigint;
$q1$;

  -- The head of the ninth case, which is where the new ones go: after the
  -- slice has been asked for twice and before the sandbox is taken away.
  v_o2 constant text := $o2$  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$o2$;
  v_r2 constant text := $q2$  -- ── 8a. The reasons a return may give ──────────────────────────────────────
  -- Both return movement types declare requires_reason, so a demonstration
  -- that could not name a reason could not have moved the goods at all. Seven
  -- of each in erp_ref.reason_code; the figure moves when that catalogue does,
  -- and it is a floor rather than a total because an organisation may add its
  -- own.
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.reason_code rc
   where rc.tenant_id = v_tenant and rc.status = 'active'
     and rc.category_code in ('RETURN_CUSTOMER', 'RETURN_SUPPLIER');
  return query select 'the demonstration keeps a register of return reasons in both categories, and the two the month uses ask for a note'::text,
    v_n >= 14
    and exists (select 1 from erp.reason_code rc
                 where rc.tenant_id = v_tenant and rc.status = 'active'
                   and rc.category_code = 'RETURN_CUSTOMER' and rc.code = 'DAMAGED_TRANSIT'
                   and rc.requires_note)
    and exists (select 1 from erp.reason_code rc
                 where rc.tenant_id = v_tenant and rc.status = 'active'
                   and rc.category_code = 'RETURN_SUPPLIER' and rc.code = 'DAMAGED_ARRIVAL'
                   and rc.requires_note),
    format('%s return reason(s); erp_ref.reason_code holds seven of each', v_n);

  -- Five more days, in the call the build makes. A credit note hangs on a
  -- named weekday and five consecutive days can miss two of them; ten hold
  -- every one.
  perform erp.seed_demo_history(v_slice + 5, v_slice + 9, 1);
  set constraints all immediate;

  -- ── 8b. The month credits a customer ───────────────────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_n
    from erp.document x
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where x.tenant_id = v_tenant and dt.code = 'sales_credit_note';
  select coalesce(sum(m.quantity), 0) into v_back
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.movement_type = 'return_from_customer'
     and not m.is_reversal;
  select coalesce(sum(jl.credit_minor - jl.debit_minor), 0)::bigint into v_cr
    from erp.journal_line jl
    join erp.journal j on j.id = jl.journal_id
    join erp.account a on a.id = jl.account_id
    join erp.document x on x.id = j.document_id
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where j.tenant_id = v_tenant and dt.code = 'sales_credit_note'
     and a.control_kind = 'receivable';
  return query select 'the month credits a customer: a credit note on a Friday, issued under that day''s reference, the goods back on the shelf under the reason they came back for, and the receivable down'::text,
    v_n >= 1 and v_back > 0 and v_cr > 0
    and not exists (
      select 1 from erp.document x
        join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
       where x.tenant_id = v_tenant and dt.code = 'sales_credit_note'
         and (   extract(isodow from x.document_date) <> 5
              or x.their_reference not like 'DEMO-' || to_char(x.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', x.id) <> 'issued'
              or not exists (select 1 from erp.stock_movement m
                              where m.tenant_id = x.tenant_id and m.document_id = x.id
                                and m.movement_type = 'return_from_customer'
                                and not m.is_reversal and m.quantity > 0
                                and m.reason_code = 'DAMAGED_TRANSIT')
              or not exists (select 1 from erp.journal j
                              where j.tenant_id = x.tenant_id and j.document_id = x.id
                                and j.status = 'posted'))),
    format('%s customer credit note(s), %s unit(s) back on the shelf, %s off the receivable',
           v_n, v_back, v_cr);

  -- ── 8c. The month sends goods back to a supplier ───────────────────────────
  v_cases := v_cases + 1;
  select count(*) into v_m
    from erp.document x
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where x.tenant_id = v_tenant and dt.code = 'purchase_credit_note';
  select coalesce(sum(m.quantity), 0) into v_gone
    from erp.stock_movement m
   where m.tenant_id = v_tenant and m.movement_type = 'return_to_supplier'
     and not m.is_reversal;
  select coalesce(sum(jl.debit_minor - jl.credit_minor), 0)::bigint into v_dr
    from erp.journal_line jl
    join erp.journal j on j.id = jl.journal_id
    join erp.account a on a.id = jl.account_id
    join erp.document x on x.id = j.document_id
    join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
   where j.tenant_id = v_tenant and dt.code = 'purchase_credit_note'
     and a.control_kind = 'payable';
  return query select 'the month sends goods back to a supplier: a credit note on a Tuesday, issued under that day''s reference, the goods off the shelf under the reason they went back for, and what we owe down'::text,
    v_m >= 1 and v_gone > 0 and v_dr > 0
    and not exists (
      select 1 from erp.document x
        join erp.document_type dt on dt.tenant_id = x.tenant_id and dt.id = x.document_type_id
       where x.tenant_id = v_tenant and dt.code = 'purchase_credit_note'
         and (   extract(isodow from x.document_date) <> 2
              or x.their_reference not like 'DEMO-' || to_char(x.document_date, 'YYYYMMDD') || '-%'
              or erp.object_current_state('document', x.id) <> 'issued'
              or not exists (select 1 from erp.stock_movement m
                              where m.tenant_id = x.tenant_id and m.document_id = x.id
                                and m.movement_type = 'return_to_supplier'
                                and not m.is_reversal and m.quantity > 0
                                and m.reason_code = 'DAMAGED_ARRIVAL')
              or not exists (select 1 from erp.journal j
                              where j.tenant_id = x.tenant_id and j.document_id = x.id
                                and j.status = 'posted'))),
    format('%s supplier credit note(s), %s unit(s) sent back, %s off the payable',
           v_m, v_gone, v_dr);

  -- ── 8d. And nothing is relaxed by either of them ───────────────────────────
  v_cases := v_cases + 1;
  begin
    v_msg := erp.assert_stock_reconciles() || '; ' || erp.assert_subledger_reconciles()
             || '; ' || erp.assert_inventory_reconciles();
    v_ok := true;
  exception when others then
    v_ok := false; v_msg := left(sqlerrm, 200);
  end;
  return query select 'stock, the subledger and inventory still reconcile with the month''s credit notes in them'::text,
    v_ok, v_msg;

  v_cases := v_cases + 1;
  delete from erp.environment where tenant_id = v_tenant and code = 'sandbox';
$q2$;

  -- The count, pinned in the suite as well as in the wrapper.
  v_o3 constant text := $o3$  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 10', v_cases;
  end if;
$o3$;
  v_r3 constant text := $q3$  if v_cases <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % cases, expected 14', v_cases
      using detail = 'A case was added or lost. Update the count deliberately, here and in the wrapper.';
  end if;
$q3$;
  v_hits integer;
begin
  if position('sales_credit_note' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % already reads the month''s credit notes', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_o1, ''))) / length(v_o1);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % declares its clocks % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o2, ''))) / length(v_o2);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % takes the sandbox away % time(s), not once', v_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_o3, ''))) / length(v_o3);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % pins its count % time(s), not once', v_sig, v_hits;
  end if;

  v_def := replace(v_def, v_o1, v_r1);
  v_def := replace(v_def, v_o2, v_r2);
  v_def := replace(v_def, v_o3, v_r3);
  execute v_def;

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('erp_test.approve_document(v_po, ''suite'')' in v_def) = 0   -- 20260914062000
     or position('purchase_credit_note' in v_def) = 0
     or position('v_cases <> 14' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_SUITE_UNRECOGNISED: % dropped a patch it already had, or did not take its cases', v_sig;
  end if;
end
$cases$;

-- The wrapper, needled too: 20260906050000 rewrote every suite wrapper to count
-- a null verdict as a failure, and erp.assert_suite_verdicts_strict() refuses a
-- wrapper that has lost that. All this adds is the other end of the count.
do $wrapper$
declare
  v_sig  constant text := 'erp_test.assert_demo_history_suite()';
  v_def  text := pg_get_functiondef('erp_test.assert_demo_history_suite()'::regprocedure);
  v_o constant text := $o$  return format('demo history: %s/%s cases pass', v_all - v_fail, v_all);
$o$;
  v_r constant text := $q$  if v_all <> 14 then
    raise exception 'CLOVEERP_SUITE_SHRANK: demo_history_suite ran % case(s), expected 14', v_all
      using detail = 'A case was added or lost. Update the count deliberately, here and in the suite.';
  end if;
  return format('demo history: %s/%s cases pass', v_all - v_fail, v_all);
$q$;
  v_hits integer;
begin
  if position('v_all <> 14' in v_def) > 0 then
    raise exception 'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % already pins its count', v_sig;
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_o, ''))) / length(v_o);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % answers % time(s), not once', v_sig, v_hits;
  end if;

  execute replace(v_def, v_o, v_r);

  v_def := pg_get_functiondef(v_sig::regprocedure);
  if position('not coalesce(passed, false)' in v_def) = 0                     -- 20260906050000
     or position('v_all <> 14' in v_def) = 0 then
    raise exception
      'CLOVEERP_DEMO_HISTORY_WRAPPER_UNRECOGNISED: % lost its null-verdict count, or did not take its pin', v_sig;
  end if;
end
$wrapper$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_demo_history_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_isolation();
