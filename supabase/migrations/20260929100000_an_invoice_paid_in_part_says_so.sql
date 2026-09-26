set lock_timeout = '30s';

-- =============================================================================
-- 20260929100000  An invoice paid in part says so
-- -----------------------------------------------------------------------------
-- PR12, M4 (docs/spec/simplification-review.md §7, node F4): a part_paid
-- state on the sales invoice's lifecycle and on the purchase invoice's,
-- delivered to an organisation already live as version 4 of sales-lifecycle
-- and version 6 of procurement-controls through the upgrade register, to a
-- demonstration through its catch-up, and to a new organisation at install.
-- Decision D11 as taken on 26 September: nothing is swept.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- On a database built from main (PR12 scoping, lc.out and E1/E2):
--
--   * An invoice with half its cash applied read Issued, exactly as one with
--     none did; a bill paid in part read Registered. The ageing knew, and the
--     document did not.
--   * The document page drew Settle, and Pay, over a document that still owed
--     money, which the door then refused (CLOVEERP_DOCUMENT_STILL_OWES, since
--     20260922150000): erp.transition_refusal() did not know the refusal.
--
-- ── WHAT VERSION 4 OF THE SALES INVOICE'S LIFECYCLE IS ──────────────────────
--
--   draft     → issued      issue        Issue the invoice (the door's)
--   issued    → paid        settle       the cash, when nothing is owed
--   issued    → part_paid   part_settle  derived: some settled, some owing
--   part_paid → paid        settle_rest  the cash, when nothing is owed
--   issued    → credited    credit       the credit note, credited in full
--   part_paid → credited    credit_rest  the credit note, credited in full
--   draft     → cancelled   cancel
--
-- ── WHAT VERSION 6 OF THE PURCHASE INVOICE'S LIFECYCLE IS ───────────────────
--
--   draft      → registered  register
--   registered → disputed    dispute      (and erp.dispute_unmatched_bill())
--   disputed   → registered  resolve      (erp.accept_match_exception())
--   registered → paid        pay          the payment run, when nothing is owed
--   registered → part_paid   part_pay     derived: some paid, some owing
--   part_paid  → paid        pay_rest     the payment run, when nothing is owed
--   draft      → cancelled   cancel
--
-- Transition codes are unique within a version of a machine (the constraint
-- is transition_tenant_id_state_machine_version_id_code_key), so the moves
-- out of part_paid are new codes and not settle, pay or credit again.
--
--   * Part paid is committed and not terminal: posting stays quiet (it asks
--     "already posted?" of each ledger), GRNI's committed filter and every
--     committed read hold, and erp.credit_position() still counts it open.
--   * The fact is erp.document_is_part_paid(): the document's receivable or
--     payable detail carries some settlement (settled_minor above nought) and
--     erp.ageing_balance still carries a penny owed on it. A credit note is
--     not a settlement: an invoice credited in part and paid nothing is
--     Issued.
--   * erp.settle_paid_document(), which every cash route already calls, makes
--     the move when the fact holds, naming it in erp.deriving_move, and
--     erp.derived_move_fact() reads the fact again with the document's state
--     locked. Anything that refuses the move is recorded as the document not
--     progressing and never rolls back the cash.
--   * Nobody presses it: part_settle and part_pay are refused outside their
--     fact (CLOVEERP_PART_PAID_IS_DERIVED), and the screens are told so.
--     settle_rest and pay_rest join settle and pay under the refusal of a
--     document that still owes. The menu (erp.transition_refusal()) now knows
--     both refusals, so the document page stops drawing Settle over money
--     owed (the spec's S7).
--   * The rest of the money moves it on to paid, by the same routine and the
--     same permission as settle and pay: a person who may not post leaves it
--     part paid with the refusal recorded, as an issued one is today.
--   * A full credit note moves a part-paid invoice to credited, by
--     erp.credit_invoices_for_credit_note(), which asks the lifecycle for the
--     move to credited out of where the invoice stands.
--   * The tax point of a part-paid invoice is fixed: erp.set_invoice_tax_point()
--     takes draft or issued only, as it takes nothing paid.
--
-- ── WHAT CHANGES FOR DOCUMENTS IN FLIGHT ─────────────────────────────────────
--
-- Nothing moves on its own (D11). An invoice or bill stays on the version it
-- started on: a version 1 invoice paid in part stays Issued, and its last
-- penny settles it as it always did. The demonstration's invoices paid in
-- part before its catch-up stay as they are. Two things reach version 1: its
-- Settle and Pay are no longer drawn over a document that owes, and the menu
-- says why.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No move back from part_paid (or paid) to issued or registered. No route
--     reduces a settlement: settled_minor is only ever added to, by the three
--     cash routes, and nothing reverses a receipt or a payment against the
--     document it settled. The day one exists it is a move of its own.
--   * No dispute of a bill once part of it is paid: disputed is a bill
--     nobody should pay, and one already paid in part is a supplier
--     conversation, not a lifecycle state.
--   * The settlement tolerance is M3's (finance.settlement_tolerance). This
--     changes erp.settle_paid_document() only as far as part paid needs, so
--     M3's write-off lands in the same routine: once it settles the whole
--     item, nothing is owed and the move is settle or settle_rest.
--   * No public function, so no allowance and no door.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusal this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_PART_PAID_IS_DERIVED',
  'Marking an invoice or a bill part paid by hand.',
  'Part paid is what the ledger says once some of the money has arrived and some is still owed. Nobody decides it: the cash that reaches the document moves it, and a label put on by hand would say something the ageing does not.',
  'Apply the cash against it: receive it from the customer, or pay it in a payment run. The document reads Part paid by itself while some of it is still owed, and Paid once nothing is.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. What the fact reads
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.document_is_part_paid(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- An invoice or bill some of whose money has arrived and some of which is
  -- still owed (20260929100000): its receivable or payable detail carries a
  -- settlement, which only the three cash routes write, and the one
  -- computation of what is owed (erp.ageing_balance) still carries a penny
  -- outstanding on it. Read by erp.settle_paid_document(), which makes the
  -- move, and again by erp.derived_move_fact() with the document's state
  -- locked. A credit is not a settlement.
  select exists (
           select 1 from erp.subledger_item si
            where si.tenant_id = erp.current_tenant_id()
              and si.document_id = p_document_id
              and si.control_kind in ('receivable', 'payable')
              and coalesce(si.settled_minor, 0) > 0)
     and exists (
           select 1 from erp.ageing_balance b
            where b.tenant_id = erp.current_tenant_id()
              and b.document_id = p_document_id
              and b.outstanding_minor > 0)
$$;

revoke all on function erp.document_is_part_paid(uuid) from public, anon;

comment on function erp.document_is_part_paid(uuid) is
  'True for an invoice or bill with some settlement against it and something still owed on the ageing '
  '(20260929100000): the fact its part_settle or part_pay is derived from.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The two lifecycles, each from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.sales_invoice_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 4 of the sales invoice's lifecycle (20260929100000), read by
  -- erp.configure_sales() for a new install and by the upgrade register for
  -- an organisation on sales-lifecycle 3 or earlier, so the two cannot
  -- disagree. Version 1's moves as they were, and part_paid between issued
  -- and paid. No move is a button but cancel: issue is the door's that
  -- numbers it; settle, part_settle and settle_rest the cash's, through
  -- erp.settle_paid_document(); credit and credit_rest the credit note's,
  -- through erp.credit_invoices_for_credit_note().
  select jsonb_build_object('kind', 'state_machine', 'key', 'sales_invoice', 'payload',
        jsonb_build_object(
          'code','sales_invoice','object_type','document','name','Sales invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','issued','name','Issued','is_committed',true,'sort_order',20),
            jsonb_build_object('code','part_paid','name','Part paid','is_committed',true,'sort_order',25),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','credited','name','Credited','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
            jsonb_build_object('code','settle','name','Record payment','from','issued','to','paid','required_permission','finance.post'),
            -- Derived from erp.document_is_part_paid(), asked for by
            -- erp.settle_paid_document() as the cash lands.
            jsonb_build_object('code','part_settle','name','Paid in part','from','issued','to','part_paid','required_permission','finance.post','is_automatic',true),
            jsonb_build_object('code','settle_rest','name','Record payment','from','part_paid','to','paid','required_permission','finance.post','is_automatic',true),
            jsonb_build_object('code','credit','name','Credit','from','issued','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','credit_rest','name','Credit','from','part_paid','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice'))))
$$;

comment on function erp.sales_invoice_lifecycle_item() is
  'The sales invoice''s lifecycle as sales-lifecycle version 4 installs it (20260929100000): version 1''s '
  'moves and part_paid, derived from the cash, the item erp.configure_sales() and the upgrade register both read.';

create or replace function erp.purchase_invoice_lifecycle_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 6 of the purchase invoice's lifecycle (20260929100000), read by
  -- erp.configure_procurement_controls() for a new install and by the
  -- upgrade register for an organisation on procurement-controls 5 or
  -- earlier, so the two cannot disagree. Version 1's moves as they were, and
  -- part_paid between registered and paid: pay, part_pay and pay_rest are
  -- the payment run's, through erp.settle_paid_document().
  select jsonb_build_object('kind', 'state_machine', 'key', 'purchase_invoice', 'payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','part_paid','name','Part paid','is_committed',true,'sort_order',25),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            -- Derived from erp.document_is_part_paid(), asked for by
            -- erp.settle_paid_document() as the payment run pays it.
            jsonb_build_object('code','part_pay','name','Paid in part','from','registered','to','part_paid','required_permission','finance.post','is_automatic',true),
            jsonb_build_object('code','pay_rest','name','Record payment','from','part_paid','to','paid','required_permission','finance.post','is_automatic',true),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match'))))
$$;

comment on function erp.purchase_invoice_lifecycle_item() is
  'The purchase invoice''s lifecycle as procurement-controls version 6 installs it (20260929100000): '
  'version 1''s moves and part_paid, derived from the payment, the item '
  'erp.configure_procurement_controls() and the upgrade register both read.';

-- The installers read them.
do $configure_sales$
declare
  v_sig constant text := 'erp.configure_sales(numeric,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      jsonb_build_object('kind','state_machine','key','sales_invoice','payload',
        jsonb_build_object(
          'code','sales_invoice','object_type','document','name','Sales invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','issued','name','Issued','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','credited','name','Credited','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
            jsonb_build_object('code','settle','name','Record payment','from','issued','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','credit','name','Credit','from','issued','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice')))),

$o$;
  v_new constant text := $n$      -- Version 4 (20260929100000), from its one helper: part paid is
      -- derived from the cash.
      erp.sales_invoice_lifecycle_item(),
$n$;
  n integer;
begin
  if position('erp.sales_invoice_lifecycle_item()' in v_def) > 0 then
    raise notice '% already installs version 4 of the sales invoice; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales invoice block found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure_sales$;

do $configure_controls$
declare
  v_sig constant text := 'erp.configure_procurement_controls(text,numeric,numeric,bigint)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$      jsonb_build_object('kind','state_machine','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice','object_type','document','name','Purchase invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','registered','name','Registered','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','disputed','name','Disputed','sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','register','name','Register','from','draft','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','dispute','name','Dispute','from','registered','to','disputed','required_permission','procurement.match'),
            jsonb_build_object('code','resolve','name','Resolve','from','disputed','to','registered','required_permission','procurement.match'),
            jsonb_build_object('code','pay','name','Record payment','from','registered','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','procurement.match')))),
$o$;
  v_new constant text := $n$      -- Version 6 (20260929100000), from its one helper: part paid is
      -- derived from the payment.
      erp.purchase_invoice_lifecycle_item(),
$n$;
  n integer;
begin
  if position('erp.purchase_invoice_lifecycle_item()' in v_def) > 0 then
    raise notice '% already installs version 6 of the purchase invoice; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % purchase invoice block found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure_controls$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The upgrade register: sales-lifecycle 4 and procurement-controls 6
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 4,
       description = description
         || ' Version 4 (20260929100000): an invoice paid in part says so, derived from the cash, '
         || 'and moves on to paid, or to credited, from there.'
 where install_code = 'sales-lifecycle' and current_version = 3;

update erp_ref.module_installer
   set current_version = 6,
       description = description
         || ' Version 6 (20260929100000): a bill paid in part says so, derived from the payment run, '
         || 'and moves on to paid from there.'
 where install_code = 'procurement-controls' and current_version = 5;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
values ('sales-lifecycle', 4, 'state_machine', 'sales_invoice',
        erp.sales_invoice_lifecycle_item() -> 'payload', 100),
       ('procurement-controls', 6, 'state_machine', 'purchase_invoice',
        erp.purchase_invoice_lifecycle_item() -> 'payload', 100)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'sales-lifecycle') is distinct from 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the sales lifecycle installer is not at version 4';
  end if;
  if (select current_version from erp_ref.module_installer
       where install_code = 'procurement-controls') is distinct from 6 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the procurement controls installer is not at version 6';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'sales-lifecycle' and ui.to_version = 4
         and ui.object_kind = 'state_machine' and ui.object_key = 'sales_invoice'
         and ui.payload = erp.sales_invoice_lifecycle_item() -> 'payload') <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'sales-lifecycle' and ui.to_version = 4) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 4 of the sales lifecycle is not the one item it ships';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       where ui.install_code = 'procurement-controls' and ui.to_version = 6
         and ui.object_kind = 'state_machine' and ui.object_key = 'purchase_invoice'
         and ui.payload = erp.purchase_invoice_lifecycle_item() -> 'payload') <> 1
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'procurement-controls' and ui.to_version = 6) <> 1 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 6 of procurement controls is not the one item it ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The demonstration takes procurement controls' newer version in its
--     catch-up
--
-- The sales lifecycle's block (20260923800000) already takes whatever
-- version the installer is at. Procurement controls had none, because every
-- version before this one shipped posting rules its installer re-ran; this
-- one ships a lifecycle. In a block of its own, before the trading, a
-- refusal a note.
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig constant text := 'erp.demonstration_catch_up()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- ── Trading, up to the day this runs or the time this statement has ────────
$o$;
  v_new constant text := $n$  -- ── Procurement controls' newer version (20260929100000) ──────────────────
  begin
    if exists (select 1 from erp.module_installation i
                where i.tenant_id = v_tenant and i.install_code = 'procurement-controls') then
      if exists (select 1 from erp.plan_module_upgrade('procurement-controls')) then
        perform erp.upgrade_module_configuration('procurement-controls');
        v_notes := v_notes || to_jsonb(format(
          'Procurement controls was upgraded to version %s.',
          (select mi.current_version from erp_ref.module_installer mi
            where mi.install_code = 'procurement-controls')));
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'Procurement controls was not upgraded, so its bills move as they did: %s', sqlerrm));
  end;

  -- ── Trading, up to the day this runs or the time this statement has ────────
$n$;
  n integer;
begin
  if position('Procurement controls'' newer version (20260929100000)' in v_def) > 0 then
    raise notice '% already takes procurement controls'' newer version; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % trading anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The fact, read again with the document's state locked
-- ─────────────────────────────────────────────────────────────────────────────

do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$           -- A sales order's close, from its settled invoices (20260923800000),
           -- asked for by erp.close_sales_order_when_settled().
$o$;
  v_new constant text := $n$           -- An invoice or bill paid in part (20260929100000), asked for by
           -- erp.settle_paid_document() as the cash lands: some settled,
           -- some still owed.
           when dt.base_type_code = 'invoice_reference' and p_transition_code in ('part_settle', 'part_pay')
            and erp.document_is_part_paid(p_object_id)
             then 'erp.document_is_part_paid'
           -- A sales order's close, from its settled invoices (20260923800000),
           -- asked for by erp.close_sales_order_when_settled().
$n$;
  n integer;
begin
  if position('erp.document_is_part_paid' in v_def) > 0 then
    raise notice '% already names the part paid fact; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales order close arm found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B2. The cash makes the move
--
-- Restated whole from 20260922150000's body, which it keeps: the two tests of
-- what owing nothing means, and the move read out of the lifecycle rather than
-- named, so an organisation that promoted its own lifecycle is answered by its
-- own. What is added is the branch for a document that still owes.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.settle_paid_document(p_document_id uuid, p_reason text default null)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  v_code      text;
  v_permitted boolean;
  v_guard     boolean;
  v_entity    uuid;
  v_site      uuid;
  v_part      text;
  v_prev      text;
begin
  if p_document_id is null then
    return false;
  end if;

  -- A document with no receivable or payable detail owes nothing because
  -- nothing was ever posted for it, which is not the same as having been paid.
  if not exists (
    select 1 from erp.subledger_item si
     where si.tenant_id = v_tenant and si.document_id = p_document_id
       and si.control_kind in ('receivable', 'payable'))
  then
    return false;
  end if;

  -- What it owes, from the one computation of what is owed (20260918500000).
  -- erp.ageing_balance carries a row only where that is not zero, so a row is
  -- a penny still outstanding and there is no tolerance in the comparison.
  if exists (
    select 1 from erp.ageing_balance b
     where b.tenant_id = v_tenant and b.document_id = p_document_id)
  then
    -- Still owing, and paid in part (20260929100000): the move out of where
    -- it stands to part_paid, when the version it is on declares one and
    -- some of the money has arrived. The move is the system's, derived from
    -- erp.document_is_part_paid(), named in erp.deriving_move immediately
    -- before it and put back after. Whatever refuses it is recorded against
    -- the document, and the cash already applied stands. A version 1
    -- document declares no such move and is left where it is (D11).
    select t.transition_code into v_part
      from erp.available_transitions('document', p_document_id) t
     where t.transition_code in ('part_settle', 'part_pay')
     order by t.transition_code
     limit 1;

    if v_part is not null and erp.document_is_part_paid(p_document_id) then
      v_prev := coalesce(current_setting('erp.deriving_move', true), '');
      begin
        perform set_config('erp.deriving_move', p_document_id::text || ':' || v_part, true);
        perform erp.transition_document(
          p_document_id, v_part,
          coalesce(p_reason, 'paid in part by the cash applied to it'));
        perform set_config('erp.deriving_move', v_prev, true);
      exception when others then
        perform set_config('erp.deriving_move', v_prev, true);
        perform erp.append_event(
          'document.progress_not_advanced', 'document', p_document_id,
          jsonb_build_object('transition', v_part, 'reason', sqlerrm),
          null, null);
      end;
    end if;
    return false;
  end if;

  -- The move this document's own lifecycle declares out of where it is:
  -- settle for a sales invoice, pay for a bill, settle_rest or pay_rest for
  -- one paid in part (20260929100000), and nothing at all for a document
  -- already paid, credited or cancelled. Read from the state machine rather
  -- than from a list here, so an organisation that promoted its own
  -- lifecycle is answered by its own.
  select t.transition_code, t.permitted, t.guard_passes
    into v_code, v_permitted, v_guard
    from erp.available_transitions('document', p_document_id) t
   where t.transition_code in ('settle', 'pay', 'settle_rest', 'pay_rest')
   order by t.transition_code
   limit 1;

  if v_code is null or not coalesce(v_guard, true) then
    return false;
  end if;

  if not coalesce(v_permitted, false) then
    -- The cash is applied and the document is left where it is, because the
    -- caller may post in this company and not at this site. Recorded where
    -- every other refusal of a permission is recorded, so that an invoice
    -- still open after a receipt has an answer somebody can find, rather than
    -- being caught and thrown away.
    select os.entity_id, os.site_id into v_entity, v_site
      from erp.object_state os
     where os.tenant_id = v_tenant and os.object_type = 'document'
       and os.object_id = p_document_id;

    perform erp.log_access_decision(
      'finance.post', false, v_entity, v_site, null, 'document', p_document_id,
      format('cash left nothing owing and the document was not %s: no matching grant', v_code));
    return false;
  end if;

  perform erp.transition_document(
    p_document_id, v_code,
    coalesce(p_reason, 'settled by the cash applied to it'));
  return true;
end;
$$;

revoke all on function erp.settle_paid_document(uuid, text) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- B3. erp.transition_document() refuses the moves nobody presses
--
-- The C2 guard (20260922150000) learns settle_rest and pay_rest, and part
-- paid is refused outside its fact. Applied once: a body that already names
-- the refusal is left alone.
-- ─────────────────────────────────────────────────────────────────────────────

do $transition_document$
declare
  v_sig constant text := 'erp.transition_document(uuid, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  if p_transition_code in ('settle', 'pay')
     and exists (select 1 from erp.subledger_item si
$o$;
  v_new constant text := $n$  -- Part paid is derived from the cash (20260929100000): made by
  -- erp.settle_paid_document() under erp.document_is_part_paid(), read
  -- again here, and refused to anybody who presses it.
  if p_transition_code in ('part_settle', 'part_pay')
     and erp.document_declares_move(p_document_id, p_transition_code)
     and erp.derived_move_fact('document', p_document_id, p_transition_code) is null
  then
    raise exception
      'CLOVEERP_PART_PAID_IS_DERIVED: % is part paid when the cash says so, not by hand (%)',
      coalesce(d.document_number, p_document_id::text), p_transition_code
      using errcode = '23514',
            hint = 'Apply the cash against it. It reads Part paid by itself while some of it is still owed, and Paid once nothing is.';
  end if;

  -- And the move on from part paid is paid, which is the cash's in the same
  -- way (20260929100000).
  if p_transition_code in ('settle', 'pay', 'settle_rest', 'pay_rest')
     and exists (select 1 from erp.subledger_item si
$n$;
  n integer;
begin
  if position('CLOVEERP_PART_PAID_IS_DERIVED' in v_def) > 0 then
    raise notice '% already refuses part paid by hand; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % paid guard found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition_document$;

-- The screens are told both refusals, so the document page draws neither
-- (20260929100000, the spec's S7).
do $refusal$
declare
  v_sig constant text := 'erp.transition_refusal(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).
  if p_transition_code = 'reject' then
$o$;
  v_new constant text := $n$  -- Paid, and part paid, are the cash's (20260929100000): part paid is
  -- never pressed, and paid is not pressed over a document that still
  -- owes, by the same two tests erp.transition_document() makes.
  if p_transition_code in ('part_settle', 'part_pay') then
    return 'CLOVEERP_PART_PAID_IS_DERIVED';
  end if;
  if p_transition_code in ('settle', 'pay', 'settle_rest', 'pay_rest')
     and exists (select 1 from erp.subledger_item si
                  where si.tenant_id = v_tenant and si.document_id = p_document_id
                    and si.control_kind in ('receivable', 'payable'))
     and exists (select 1 from erp.ageing_balance b
                  where b.tenant_id = v_tenant and b.document_id = p_document_id) then
    return 'CLOVEERP_DOCUMENT_STILL_OWES';
  end if;

  -- Reject, of a transfer order or stock adjustment waiting for approval,
  -- is the approvers' and the asker's (20260928500000).
  if p_transition_code = 'reject' then
$n$;
  n integer;
begin
  if position('CLOVEERP_PART_PAID_IS_DERIVED' in v_def) > 0 then
    raise notice '% already reads the paid refusals; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % reject anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, v_old, v_new);
end
$refusal$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C1. The register: part paid and the rest
--
-- Restated whole, from 20260928500000, so the register the screens are held
-- to is read from one place. Version 4 and version 6 keep every code version
-- 1 declares, so no row is kept only for documents in flight.
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
-- D1. The suites version 4 and version 6 change the answer for
--
-- The cash settlement suite's C2 cases (4, 4a, 4b) and its penny-short bill
-- (7) are re-pinned deliberately: a new install is version 4 and version 6,
-- so a document one penny short is Part paid, not Issued or Registered, and
-- the move the cash is left to make is settle_rest out of part_paid. What
-- each case proves is unchanged: a penny short is not settled, is not marked
-- paid by hand, and the penny settles it. The sales order progress suite
-- reads version 3 or later, since the sales invoice's lifecycle is version
-- 4's. Each keeps its cases.
-- ─────────────────────────────────────────────────────────────────────────────

do $cash$
declare
  v_sig constant text := 'erp_test.cash_settlement_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$    case_name := 'an invoice one penny short of paid is not settled, and the penny is still on the ageing and on the screen';
    passed := v_state is null and v_s1 = 'issued' and v_owed = 1 and v_scr = 1;$o$;
  b0 constant text := $n$    -- Re-pinned by 20260929100000 (PR12 M4): on version 4 it is Part paid.
    case_name := 'an invoice one penny short of paid is not settled but Part paid, and the penny is still on the ageing and on the screen';
    passed := v_state is null and v_s1 = 'part_paid' and v_owed = 1 and v_scr = 1;$n$;
  a1 constant text := $o$          and erp.object_current_state('document', v_inv2) = 'issued';$o$;
  b1 constant text := $n$          and erp.object_current_state('document', v_inv2) = 'part_paid';$n$;
  a2 constant text := $o$                       where t.transition_code = 'settle');$o$;
  b2 constant text := $n$                       -- Out of part_paid it is settle_rest since
                       -- 20260929100000.
                       where t.transition_code = 'settle_rest');$n$;
  a3 constant text := $o$    case_name := 'a bill paid all but a penny stays registered and still owes the penny, where the run used to count the payment twice and call it paid';
    passed := v_state is null and v_s1 = 'registered' and v_owed = 1$o$;
  b3 constant text := $n$    -- Re-pinned by 20260929100000 (PR12 M4): on version 6 it is Part paid.
    case_name := 'a bill paid all but a penny is Part paid and still owes the penny, where the run used to count the payment twice and call it paid';
    passed := v_state is null and v_s1 = 'part_paid' and v_owed = 1$n$;
  -- And the hand press of settle is now asked of the move the lifecycle
  -- declares out of part_paid, which the C2 guard refuses in the same words.
  a4 constant text := $o$      perform erp.transition_document(v_inv2, 'settle', 'marked paid by hand');$o$;
  b4 constant text := $n$      perform erp.transition_document(v_inv2, 'settle_rest', 'marked paid by hand');$n$;
  n integer;
begin
  if position('Re-pinned by 20260929100000' in v_def) > 0 then
    raise notice '% already re-pinned for part paid; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1),
      (length(v_def) - length(replace(v_def, a2, ''))) / length(a2),
      (length(v_def) - length(replace(v_def, a3, ''))) / length(a3),
      (length(v_def) - length(replace(v_def, a4, ''))) / length(a4)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % re-pin anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  v_def := replace(v_def, a0, b0);
  v_def := replace(v_def, a1, b1);
  v_def := replace(v_def, a2, b2);
  v_def := replace(v_def, a3, b3);
  v_def := replace(v_def, a4, b4);
  execute v_def;
end
$cash$;

do $sop$
declare
  v_sig constant text := 'erp_test.sales_order_progress_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$      v_ver = 3 and v_states like '%picking,partially_despatched,despatched%',$o$;
  b0 constant text := $n$      -- 3 or later: 4 since 20260929100000, the sales invoice's.
      v_ver >= 3 and v_states like '%picking,partially_despatched,despatched%',$n$;
  n integer;
begin
  if position('4 since 20260929100000' in v_def) > 0 then
    raise notice '% already reads a later version; left as it is', v_sig;
    return;
  end if;
  n := (length(v_def) - length(replace(v_def, a0, ''))) / length(a0);
  if n <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, n;
  end if;
  execute replace(v_def, a0, b0);
end
$sop$;

-- The demonstration's history pays invoices in part, and on version 4 they
-- read Part paid: an invoice's flow ends issued, part paid or paid, and what
-- a part delivery left is billed on any of the three.
do $dhs$
declare
  v_sig constant text := 'erp_test.demo_history_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  a0 constant text := $o$             or (dt.code = 'sales_invoice' and erp.object_current_state('document', x.id) not in ('issued', 'paid'))$o$;
  b0 constant text := $n$             -- Part paid since 20260929100000.
             or (dt.code = 'sales_invoice' and erp.object_current_state('document', x.id) not in ('issued', 'part_paid', 'paid'))$n$;
  a1 constant text := $o$                     and erp.object_current_state('document', iv.id) in ('issued', 'paid')) <> fr.quantity)),$o$;
  b1 constant text := $n$                     and erp.object_current_state('document', iv.id) in ('issued', 'part_paid', 'paid')) <> fr.quantity)),$n$;
  n integer;
begin
  if position('Part paid since 20260929100000' in v_def) > 0 then
    raise notice '% already expects part paid invoices; left as it is', v_sig;
    return;
  end if;
  foreach n in array array[
      (length(v_def) - length(replace(v_def, a0, ''))) / length(a0),
      (length(v_def) - length(replace(v_def, a1, ''))) / length(a1)] loop
    if n <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % invoice state anchor found % time(s)', v_sig, n;
    end if;
  end loop;
  execute replace(replace(v_def, a0, b0), a1, b1);
end
$dhs$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E1. Version 1, for the suite that walks invoices in flight on it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.sales_invoice_v1_item()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- Version 1 of the sales invoice's lifecycle, as erp.configure_sales()
  -- installed it until 20260929100000 and every organisation configured
  -- before then holds it. Nothing in the upgrade register carries it: sales-
  -- lifecycle shipped it only at install. For the suite that walks invoices
  -- in flight on it.
  select jsonb_build_object(
          'code','sales_invoice','object_type','document','name','Sales invoice',
          'states', jsonb_build_array(
            jsonb_build_object('code','draft','name','Draft','is_initial',true,'sort_order',10),
            jsonb_build_object('code','issued','name','Issued','is_committed',true,'sort_order',20),
            jsonb_build_object('code','paid','name','Paid','is_terminal',true,'is_committed',true,'sort_order',30),
            jsonb_build_object('code','credited','name','Credited','is_terminal',true,'is_committed',true,'sort_order',40),
            jsonb_build_object('code','cancelled','name','Cancelled','is_terminal',true,'sort_order',90)),
          'transitions', jsonb_build_array(
            jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','sales.invoice'),
            jsonb_build_object('code','settle','name','Record payment','from','issued','to','paid','required_permission','finance.post'),
            jsonb_build_object('code','credit','name','Credit','from','issued','to','credited','required_permission','sales.invoice'),
            jsonb_build_object('code','cancel','name','Cancel','from','draft','to','cancelled','required_permission','sales.invoice')))
$$;

revoke all on function erp_test.sales_invoice_v1_item() from public, anon;

comment on function erp_test.sales_invoice_v1_item() is
  'Version 1 of the sales invoice''s lifecycle, as installed before 20260929100000, for a suite.';

create or replace function erp_test.sales_invoice_on_version_1()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_cs uuid;
  v_version uuid;
begin
  -- Puts the organisation's sales invoices back on version 1 of their
  -- lifecycle, as one configured before 20260929100000 holds it, through a
  -- change set promoted the way an upgrade promotes one, and its installer
  -- back on version 3. Invoices raised after start on it. For a suite,
  -- inside its rolled-back block, in an organisation not yet live.
  v_cs := erp.create_change_set(
    format('zz-sales-invoice-v1-%s', substr(md5(gen_random_uuid()::text), 1, 8)),
    'Sales invoice, version 1',
    'Version 1 of the sales invoice''s lifecycle, for a suite that walks invoices in flight on it.');
  perform erp.add_change_set_item(v_cs, 'state_machine', 'sales_invoice',
                                  erp_test.sales_invoice_v1_item(), 'upsert', null,
                                  'version 1 of the sales invoice''s lifecycle');
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  update erp.module_installation set installer_version = 3
   where tenant_id = erp.require_tenant_id() and install_code = 'sales-lifecycle';

  select v.id into v_version
    from erp.state_machine m
    join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id
   where m.tenant_id = erp.require_tenant_id() and m.code = 'sales_invoice' and v.status = 'active'
   order by v.version desc
   limit 1;
  return v_version;
end;
$$;

revoke all on function erp_test.sales_invoice_on_version_1() from public, anon;

comment on function erp_test.sales_invoice_on_version_1() is
  'Puts the organisation''s sales invoices back on version 1 of their lifecycle, and sales-lifecycle '
  'on version 3, through a promoted change set, for a suite (20260929100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- E2. The proof: erp_test.settlement_is_derived_suite
--
-- An organisation installed today, with two administrators (a payment run is
-- not approved by its proposer), a customer, a supplier and a hundred widgets
-- at a tenner. Each case pays, presses or credits and reads the state the
-- invoice or bill is left in, the move its log names, and what the menu says.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.settlement_is_derived_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  rb       record;
  res      jsonb;
  v_second uuid;
  v_step   text := 'provisioning';
  v_state  text;
  v_entity uuid; v_site uuid; v_uom uuid; v_ccy char(3);
  v_cust uuid; v_supp uuid; v_item uuid; v_item5 uuid;
  v_inv uuid; v_inv2 uuid; v_inv3 uuid; v_inv4 uuid; v_inv5 uuid;
  v_gross bigint; v_gross3 bigint; v_gross4 bigint; v_gross5 bigint;
  v_po uuid; v_pol uuid; v_grn uuid; v_bill uuid; v_billed bigint;
  v_so uuid; v_dn uuid; v_ccn uuid;
  v_prop uuid; v_pay jsonb; v_pay2 jsonb;
  v_owed bigint;
  v_s1 text; v_s2 text; v_s3 text;
  v_codes text; v_codes2 text; v_log text;
  v_got text; v_got2 text; v_got3 text; v_got4 text;
  v_n integer; v_n2 integer;
  v_t1 text; v_t2 text; v_t3 text;
begin
  begin
    v_step := 'an organisation that can invoice, bill, bank a receipt, credit and pay a supplier';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzsid-' || v_tag, 'Settlement Is Derived Suite',
      'admin@zzsid-' || v_tag || '.test', 'Settlement Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzsid-' || v_tag || '.test'),
           (a2, 'second@zzsid-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);

    v_step := 'a second administrator, because a payment run is not approved by its proposer';
    res := public.erp_invite_principal('second@zzsid-' || v_tag || '.test', 'Settlement Second');
    v_second := (res ->> 'app_user_id')::uuid;
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_step := 'its site, places, customer, supplier and a hundred widgets on the shelf';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    select u.id into v_uom from erp.uom u
     where u.tenant_id = rb.tenant_id and u.is_base order by u.code limit 1;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (rb.tenant_id, v_entity, 'ZSIDSITE', 'Settlement suite site', 'warehouse', 'active')
    returning id into v_site;
    perform erp.create_location(v_site, 'ZSID-RECV', 'Goods in', 'receiving');
    perform erp.create_location(v_site, 'ZSID-BULK', 'Bulk', 'bulk');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZSIDCUST', 'Settlement Customer', 'active') returning id into v_cust;
    insert into erp.party_role (tenant_id, party_id, role_kind, attributes, status)
    values (rb.tenant_id, v_cust, 'customer', jsonb_build_object('credit_limit_minor', 100000000), 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (rb.tenant_id, 'ZSIDSUP', 'Settlement Supplier', 'active') returning id into v_supp;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (rb.tenant_id, v_supp, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (rb.tenant_id, 'ZSIDWID', 'Settlement Widget', v_uom, 'active') returning id into v_item;
    v_po := erp.open_document('purchase_order', v_supp, v_entity, v_site);
    v_pol := erp.add_document_line(v_po, v_item, 100, 1000, 'a hundred widgets');
    perform erp.transition_document(v_po, 'submit', null);
    perform erp_test.approve_document(v_po, 'settlement is derived suite');
    perform erp.transition_document(v_po, 'send', null);
    v_grn := erp.open_document('goods_receipt', v_supp, v_entity, v_site);
    perform erp.receive_against(v_grn, v_pol, 100, null);
    perform erp.transition_document(v_grn, 'post', null);

    -- ── 1. Installed today, both lifecycles have part paid ─────────────────
    v_step := 'the install';
    select string_agg(t.code, ',' order by t.code),
           count(*) - count(distinct t.code)
      into v_codes, v_n
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
     where m.tenant_id = rb.tenant_id and m.code = 'sales_invoice';
    select string_agg(t.code, ',' order by t.code),
           count(*) - count(distinct t.code)
      into v_codes2, v_n2
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.transition t on t.tenant_id = v.tenant_id and t.state_machine_version_id = v.id
     where m.tenant_id = rb.tenant_id and m.code = 'purchase_invoice';
    select string_agg(format('%s:%s/%s/%s', m.code, s.name, s.is_committed, s.is_terminal), ',' order by m.code)
      into v_got
      from erp.state_machine m
      join erp.state_machine_version v on v.tenant_id = m.tenant_id and v.state_machine_id = m.id and v.status = 'active'
      join erp.state s on s.tenant_id = v.tenant_id and s.state_machine_version_id = v.id
     where m.tenant_id = rb.tenant_id and m.code in ('sales_invoice', 'purchase_invoice')
       and s.code = 'part_paid';
    v_cases := v_cases + 1;
    case_name := 'a new organisation installs version 4 of the sales invoice and version 6 of the purchase invoice: each with a Part paid state, committed and not final, and every code once';
    passed := v_state is null
          and v_codes = 'cancel,credit,credit_rest,issue,part_settle,settle,settle_rest'
          and v_codes2 = 'cancel,dispute,part_pay,pay,pay_rest,register,resolve'
          and v_n = 0 and v_n2 = 0
          and v_got = 'purchase_invoice:Part paid/t/f,sales_invoice:Part paid/t/f'
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle') = 4
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'procurement-controls') = 6
          and not exists (select 1 from erp.plan_module_upgrade('sales-lifecycle'))
          and not exists (select 1 from erp.plan_module_upgrade('procurement-controls'));
    detail := coalesce(v_state, format('sales %s; purchase %s; %s repeated; part paid %s',
                                       v_codes, v_codes2, v_n + v_n2, coalesce(v_got, 'missing')));
    return next;

    -- ── 2. Half the cash, and nobody presses anything ───────────────────────
    v_step := 'an invoice issued and paid half';
    v_inv := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                 current_date, v_ccy, 'ZSID-INV-1', '{}'::jsonb);
    perform erp.add_document_line(v_inv, v_item, 1, 100000, 'a sale paid in two halves');
    perform erp.transition_document(v_inv, 'issue', 'settlement is derived suite');
    select dv.gross_minor::bigint into v_gross from erp.document_view dv where dv.id = v_inv;
    perform erp.apply_cash(v_cust, v_gross / 2, v_ccy, 'ZSID-RECEIPT-1', current_date);
    v_s1 := erp.object_current_state('document', v_inv);
    select coalesce(sum(b.outstanding_minor), 0) into v_owed
      from erp.ageing_balance b where b.tenant_id = rb.tenant_id and b.document_id = v_inv;
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.occurred_at, l.id)
      into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv;
    v_cases := v_cases + 1;
    case_name := 'half the cash makes an issued invoice Part paid with nobody pressing: the move is part_settle, derived from the cash, and the other half is still on the ageing';
    passed := v_state is null and v_s1 = 'part_paid'
          and v_log = 'issue,part_settle[erp.document_is_part_paid]'
          and v_owed = v_gross - v_gross / 2 and v_owed > 0;
    detail := coalesce(v_state, format('the invoice is %s, owing %s of %s; moves %s', v_s1, v_owed, v_gross, v_log));
    return next;

    -- ── 3. The menu on a part-paid invoice ──────────────────────────────────
    v_step := 'reading the menu of the part-paid invoice';
    select string_agg(x ->> 'code' || '=' || coalesce(x ->> 'refused', 'offered'), ',' order by x ->> 'code')
      into v_got
      from jsonb_array_elements(public.erp_available_transitions(v_inv)) x;
    v_cases := v_cases + 1;
    case_name := 'the menu of a part-paid invoice offers the credit and says the rest of the payment is the cash''s while money is owed';
    passed := v_state is null
          and v_got = 'credit_rest=offered,settle_rest=CLOVEERP_DOCUMENT_STILL_OWES';
    detail := coalesce(v_state, coalesce(v_got, 'nothing'));
    return next;

    -- ── 4. part_settle pressed is refused ──────────────────────────────────
    v_step := 'an issued invoice nobody has paid, and part_settle pressed';
    v_inv2 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZSID-INV-2', '{}'::jsonb);
    perform erp.add_document_line(v_inv2, v_item, 1, 20000, 'a sale nobody has paid');
    perform erp.transition_document(v_inv2, 'issue', 'settlement is derived suite');
    begin
      perform public.erp_transition_document(v_inv2, 'part_settle', 'marked part paid by hand');
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    -- And a routine that names the move over a fact that does not hold is
    -- refused the same: the fact is read again inside the door.
    begin
      perform set_config('erp.deriving_move', v_inv2::text || ':part_settle', true);
      perform erp.transition_document(v_inv2, 'part_settle', 'named, with nothing paid');
      v_got2 := 'went through';
    exception when others then v_got2 := sqlerrm; end;
    perform set_config('erp.deriving_move', '', true);
    select string_agg(x ->> 'code' || '=' || coalesce(x ->> 'refused', 'offered'), ',' order by x ->> 'code')
      into v_got3
      from jsonb_array_elements(public.erp_available_transitions(v_inv2)) x;
    v_cases := v_cases + 1;
    case_name := 'part_settle pressed by an administrator is refused, named by a routine over nothing paid is refused, and the menu says so of it and of settle';
    passed := v_state is null
          and v_got like 'CLOVEERP_PART_PAID_IS_DERIVED%'
          and v_got2 like 'CLOVEERP_PART_PAID_IS_DERIVED%'
          and erp.object_current_state('document', v_inv2) = 'issued'
          and v_got3 = 'credit=offered,part_settle=CLOVEERP_PART_PAID_IS_DERIVED,settle=CLOVEERP_DOCUMENT_STILL_OWES';
    detail := coalesce(v_state, format('pressed: %s; named: %s; the invoice is %s; menu %s',
                                       left(v_got, 70), left(v_got2, 70),
                                       erp.object_current_state('document', v_inv2), coalesce(v_got3, 'nothing')));
    return next;

    -- ── 5. settle_rest pressed while it owes is refused ─────────────────────
    v_step := 'settle_rest pressed on the part-paid invoice';
    begin
      perform public.erp_transition_document(v_inv, 'settle_rest', 'marked paid by hand');
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'the rest of the payment pressed by hand while half is owed is refused, and the invoice stays Part paid';
    passed := v_state is null and v_got like 'CLOVEERP_DOCUMENT_STILL_OWES%'
          and erp.object_current_state('document', v_inv) = 'part_paid';
    detail := coalesce(v_state, format('%s; the invoice is %s', left(v_got, 90), erp.object_current_state('document', v_inv)));
    return next;

    -- ── 6. The tax point of a part-paid invoice is fixed ────────────────────
    v_step := 'moving the tax point of the part-paid invoice';
    begin
      perform erp.set_invoice_tax_point(v_inv, current_date);
      v_got := 'went through';
    exception when others then v_got := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'the tax point of a part-paid invoice is not moved, as that of a paid one is not';
    passed := v_state is null and v_got like 'CLOVEERP_INVOICE_NOT_ISSUABLE%';
    detail := coalesce(v_state, left(v_got, 120));
    return next;

    -- ── 7. The rest makes it paid ───────────────────────────────────────────
    v_step := 'the other half';
    -- By the item route, against this invoice: the party route pays the
    -- oldest open item, and the unpaid one above is as old.
    select si.id into v_item5 from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    perform erp.apply_cash_to_item(v_item5, v_gross - v_gross / 2, 'ZSID-RECEIPT-2', current_date);
    v_s1 := erp.object_current_state('document', v_inv);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv;
    v_cases := v_cases + 1;
    case_name := 'the rest of the cash makes the part-paid invoice Paid, by settle_rest, and nothing is owed on it';
    passed := v_state is null and v_s1 = 'paid'
          and v_log = 'issue,part_settle,settle_rest'
          and not exists (select 1 from erp.ageing_balance b
                           where b.tenant_id = rb.tenant_id and b.document_id = v_inv);
    detail := coalesce(v_state, format('the invoice is %s; moves %s', v_s1, v_log));
    return next;

    -- ── 8. Paid in one go is paid, as before ────────────────────────────────
    v_step := 'an invoice paid in full at once';
    v_inv3 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZSID-INV-3', '{}'::jsonb);
    perform erp.add_document_line(v_inv3, v_item, 1, 30000, 'a sale paid at once');
    perform erp.transition_document(v_inv3, 'issue', 'settlement is derived suite');
    -- The unpaid one from case 4 is paid first, in full, against itself, so
    -- the party's receipt below meets one open invoice.
    select dv.gross_minor::bigint into v_gross3 from erp.document_view dv where dv.id = v_inv2;
    select si.id into v_item5 from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv2
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    perform erp.apply_cash_to_item(v_item5, v_gross3, 'ZSID-RECEIPT-3', current_date);
    select dv.gross_minor::bigint into v_gross3 from erp.document_view dv where dv.id = v_inv3;
    perform erp.apply_cash(v_cust, v_gross3, v_ccy, 'ZSID-RECEIPT-4', current_date);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv3;
    v_cases := v_cases + 1;
    case_name := 'an invoice paid in full at once goes straight to Paid by settle, never Part paid';
    passed := v_state is null
          and erp.object_current_state('document', v_inv3) = 'paid'
          and erp.object_current_state('document', v_inv2) = 'paid'
          and v_log = 'issue,settle';
    detail := coalesce(v_state, format('the invoice is %s by %s; the older one is %s',
                                       erp.object_current_state('document', v_inv3), v_log,
                                       erp.object_current_state('document', v_inv2)));
    return next;

    -- ── 9. A full credit note on a part-paid invoice credits it ─────────────
    v_step := 'ten widgets sold, despatched, invoiced and paid in part';
    v_so := erp.open_document('sales_order', v_cust, v_entity, v_site);
    perform erp.add_document_line(v_so, v_item, 10, 2500, 'ten widgets');
    perform erp.transition_document(v_so, 'submit', 'settlement is derived suite');
    perform erp_test.approve_document(v_so, 'settlement is derived suite');
    v_dn := (erp.create_delivery_from_order(v_so) ->> 'document_id')::uuid;
    perform erp.transition_document(v_dn, 'post', 'settlement is derived suite');
    v_inv4 := erp.invoice_from_delivery(v_dn, true);
    perform erp.transition_document(v_inv4, 'issue', 'settlement is derived suite');
    select dv.gross_minor::bigint into v_gross4 from erp.document_view dv where dv.id = v_inv4;
    perform erp.apply_cash(v_cust, 1000, v_ccy, 'ZSID-RECEIPT-5', current_date);
    v_s1 := erp.object_current_state('document', v_inv4);
    v_step := 'the whole invoice credited';
    v_ccn := erp.raise_customer_credit_note(v_inv4, 'damaged', 'All ten crushed in transit');
    perform erp.transition_document(v_ccn, 'issue', 'settlement is derived suite');
    v_s2 := erp.object_current_state('document', v_inv4);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv4;
    v_cases := v_cases + 1;
    case_name := 'a full credit note on a part-paid invoice reaches Credited, by credit_rest';
    passed := v_state is null and v_s1 = 'part_paid' and v_s2 = 'credited'
          and v_log = 'issue,part_settle,credit_rest';
    detail := coalesce(v_state, format('paid 1000 of %s it was %s; credited it is %s; moves %s',
                                       v_gross4, v_s1, v_s2, v_log));
    return next;

    -- ── 10. A payment run paying half a bill makes it part paid, then paid ──
    v_step := 'a bill for the hundred widgets, and a run that pays half of it';
    v_bill := erp.bill_from_receipt(v_grn, 'ZSID-BILL-1', current_date, current_date + 30, true);
    select dv.gross_minor::bigint into v_billed from erp.document_view dv where dv.id = v_bill;
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    update erp.payment_proposal_line
       set amount_minor = amount_minor / 2
     where tenant_id = rb.tenant_id and payment_proposal_id = v_prop and not is_held;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s1 := erp.object_current_state('document', v_bill);
    v_step := 'a second run for the rest';
    v_prop := erp.propose_payment_run(current_date, null, interval '60 days');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_payment_run(v_prop);
    v_pay2 := erp.pay_payment_run(v_prop);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_s2 := erp.object_current_state('document', v_bill);
    select string_agg(l.transition_code || coalesce('[' || (l.guard_data -> 'derived' ->> 'fact') || ']', ''), ',' order by l.occurred_at, l.id)
      into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_bill;
    v_cases := v_cases + 1;
    case_name := 'a payment run paying half a bill makes it Part paid, the next run is offered the rest, and paying it makes the bill Paid';
    passed := v_state is null and v_s1 = 'part_paid' and v_s2 = 'paid'
          and v_log = 'register,part_pay[erp.document_is_part_paid],pay_rest'
          and (v_pay ->> 'documents_settled')::integer = 0
          and (v_pay2 ->> 'documents_settled')::integer = 1
          and (v_pay ->> 'paid_minor')::bigint + (v_pay2 ->> 'paid_minor')::bigint = v_billed;
    detail := coalesce(v_state, format('after half the bill is %s, after the rest %s; moves %s; paid %s then %s of %s',
                                       v_s1, v_s2, v_log, v_pay ->> 'paid_minor', v_pay2 ->> 'paid_minor', v_billed));
    return next;

    -- ── 11. A version 1 invoice in flight keeps version 1's moves ───────────
    v_step := 'back to version 1 of the sales invoice';
    perform erp_test.sales_invoice_on_version_1();
    v_inv5 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZSID-INV-5', '{}'::jsonb);
    perform erp.add_document_line(v_inv5, v_item, 1, 40000, 'a sale raised before the upgrade');
    perform erp.transition_document(v_inv5, 'issue', 'settlement is derived suite');
    select dv.gross_minor::bigint into v_gross5 from erp.document_view dv where dv.id = v_inv5;
    -- Against the invoice itself, by the item route: the credited invoice
    -- above still carries its own item, and the party route pays the oldest.
    select si.id into v_item5 from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv5
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    perform erp.apply_cash_to_item(v_item5, v_gross5 / 2, 'ZSID-RECEIPT-6', current_date);
    v_s1 := erp.object_current_state('document', v_inv5);
    v_step := 'the upgrade';
    select string_agg(p.object_kind || ':' || p.object_key, ',' order by p.object_kind, p.object_key) into v_got
      from erp.plan_module_upgrade('sales-lifecycle') p;
    res := erp.upgrade_module_configuration('sales-lifecycle');
    v_s2 := erp.object_current_state('document', v_inv5);
    select string_agg(x ->> 'code' || '=' || coalesce(x ->> 'refused', 'offered'), ',' order by x ->> 'code')
      into v_got2
      from jsonb_array_elements(public.erp_available_transitions(v_inv5)) x;
    v_step := 'the rest of the version 1 invoice';
    perform erp.apply_cash_to_item(v_item5, v_gross5 - v_gross5 / 2, 'ZSID-RECEIPT-7', current_date);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l where l.tenant_id = rb.tenant_id and l.object_id = v_inv5;
    v_cases := v_cases + 1;
    case_name := 'a version 1 invoice paid in part stays Issued before and after the organisation takes version 4 (nothing is swept), is not offered Settle while it owes, and its last penny settles it by version 1''s settle';
    passed := v_state is null
          and v_s1 = 'issued' and v_s2 = 'issued'
          and v_got = 'state_machine:sales_invoice'
          and (res ->> 'promoted')::boolean
          and v_got2 = 'credit=offered,settle=CLOVEERP_DOCUMENT_STILL_OWES'
          and erp.object_current_state('document', v_inv5) = 'paid'
          and v_log = 'issue,settle'
          and not erp.document_declares_move(v_inv5, 'settle_rest')
          and (select i.installer_version from erp.module_installation i
                where i.tenant_id = rb.tenant_id and i.install_code = 'sales-lifecycle') = 4;
    detail := coalesce(v_state, format('half paid on version 1 it was %s; planned %s; upgraded %s, it was %s and offered %s; paid in full, moves %s',
                                       v_s1, coalesce(v_got, 'nothing'), res ->> 'promoted', v_s2,
                                       coalesce(v_got2, 'nothing'), v_log));
    return next;

    -- ── 12. And one raised after the upgrade is version 4's ─────────────────
    v_step := 'an invoice raised after the upgrade, paid in part';
    v_inv5 := erp.create_document('sales_invoice', v_entity, v_site, v_cust,
                                  current_date, v_ccy, 'ZSID-INV-6', '{}'::jsonb);
    perform erp.add_document_line(v_inv5, v_item, 1, 40000, 'a sale raised after the upgrade');
    perform erp.transition_document(v_inv5, 'issue', 'settlement is derived suite');
    select si.id into v_item5 from erp.subledger_item si
     where si.tenant_id = rb.tenant_id and si.document_id = v_inv5
       and si.control_kind = 'receivable' and si.debit_minor > 0;
    perform erp.apply_cash_to_item(v_item5, 100, 'ZSID-RECEIPT-8', current_date);
    v_cases := v_cases + 1;
    case_name := 'an invoice raised after the upgrade is version 4''s, and a pound of cash applied to it by the item route makes it Part paid';
    passed := v_state is null
          and erp.object_current_state('document', v_inv5) = 'part_paid';
    detail := coalesce(v_state, format('the invoice is %s', erp.object_current_state('document', v_inv5)));
    return next;

    -- ── 13. Every move has a driver, and the ties hold ──────────────────────
    v_step := 'the driver register and the ties';
    select string_agg(r.finding || ' ' || r.reference, '; ') into v_got
      from erp.undriven_transition_report() r
     where r.reference like 'sales_invoice%' or r.reference like 'purchase_invoice%';
    select string_agg(format('%s.%s=%s', x ->> 'machine_code', x ->> 'transition_code', x ->> 'detail'), ',' order by x ->> 'machine_code', x ->> 'transition_code')
      into v_got2
      from jsonb_array_elements(erp.transition_driver_register()) x
     where x ->> 'transition_code' in ('part_settle', 'settle_rest', 'credit_rest', 'part_pay', 'pay_rest');
    v_t1 := erp.assert_trial_balance_balances();
    v_t2 := erp.assert_subledger_reconciles();
    v_t3 := erp.assert_ageing_equals_control();
    v_cases := v_cases + 1;
    case_name := 'every new move names the routine that makes it, nothing in either lifecycle is undriven or unreachable, and the trial balance, the subledgers and the ageing still tie';
    passed := v_state is null and v_got is null
          and v_got2 = 'purchase_invoice.part_pay=erp.settle_paid_document(uuid,text),'
                    || 'purchase_invoice.pay_rest=erp.settle_paid_document(uuid,text),'
                    || 'sales_invoice.credit_rest=erp.credit_invoices_for_credit_note(uuid),'
                    || 'sales_invoice.part_settle=erp.settle_paid_document(uuid,text),'
                    || 'sales_invoice.settle_rest=erp.settle_paid_document(uuid,text)'
          and coalesce(v_t1, '') <> '' and coalesce(v_t2, '') <> '' and coalesce(v_t3, '') <> '';
    detail := coalesce(v_state, format('findings: %s; drivers %s; %s; %s; %s',
                                       coalesce(v_got, 'none'), coalesce(v_got2, 'none'),
                                       left(coalesce(v_t1, 'nothing'), 50), left(coalesce(v_t2, 'nothing'), 50),
                                       left(coalesce(v_t3, 'nothing'), 50)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.deriving_move', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzsid-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state, 'zzsid rolled back with its invoices, receipts, credit note, bill and payment runs');
  return next;

  -- The count guard says what stopped the fixture.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SETTLEMENT_IS_DERIVED_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere');
  end if;
end;
$$;

revoke all on function erp_test.settlement_is_derived_suite() from public, anon;

comment on function erp_test.settlement_is_derived_suite() is
  'Part paid is derived from the cash on version 4 of the sales invoice and version 6 of the purchase '
  'invoice, is never pressed, moves on to paid or credited, and leaves version 1 in flight as it was '
  '(20260929100000).';

create or replace function erp_test.assert_settlement_is_derived_suite()
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
    from erp_test.settlement_is_derived_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_SETTLEMENT_IS_DERIVED_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An invoice or bill moved to part paid, paid or credited other than its cash and its lifecycle say. Read the case that failed.';
  end if;
  if v_total <> 14 then
    raise exception 'CLOVEERP_SETTLEMENT_IS_DERIVED_SUITE_SHRANK: % case(s), expected 14', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('settlement is derived: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_settlement_is_derived_suite() from public, anon;

comment on function erp_test.assert_settlement_is_derived_suite() is
  'Raises unless every case of erp_test.settlement_is_derived_suite() passes (20260929100000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- F1. The words the screens say for it
--
-- The state's name and the move's are the lifecycle's, read from it; seeded
-- here so each can be renamed as every screen string can.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). An invoice or bill some of whose money has arrived (20260929100000).'
  from (values
    ('Part paid'),
    ('Paid in part')
  ) as v(text)
on conflict (key, locale) do nothing;

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
