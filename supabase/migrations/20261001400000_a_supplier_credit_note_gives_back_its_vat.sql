set lock_timeout = '30s';

-- =============================================================================
-- 20261001400000  A supplier's credit note gives back the VAT it credits
-- -----------------------------------------------------------------------------
-- PR14 M5 (docs/spec/simplification-review.md §7 VAT, node V1; plan D12, D17):
-- input tax on the goods that go back to a supplier, and the demonstration's
-- bills stating the VAT their suppliers charged.
--
-- ── WHAT WAS THERE ───────────────────────────────────────────────────────────
--
-- A supplier credit note (base type return_to_supplier) could never state tax
-- (S4). erp.state_supplier_tax() took an invoice or a credit reference and
-- nothing else, and erp.raise_supplier_credit_note() had no way to carry the
-- figure. The posting rule purchase_credit_note has always credited tax
-- control with document_tax, and erp.vat_entries() (20261001000000) has always
-- read a return with sign -1, so both ends were waiting for a figure that was
-- nought every time. A company that returned goods to a supplier who had
-- charged VAT on them kept the whole of that VAT in box 4: the return claimed
-- back tax the supplier had given back.
--
-- And the payable was not ready for it either, which the plan did not know:
-- the rule debits trade payable with basis billed_return_value, which was the
-- note's net less the accrual it reverses, and balances on price variance
-- (9100). A credit note carrying VAT would have credited tax control and
-- debited 9100 with it, an expense, where the supplier owes it back.
--
-- And the demonstration's Thursday bill was registered with no tax at all
-- (S5), so its box 4 was nought in every quarter and a prospect saw a VAT
-- return with no input tax on it.
--
-- ── WHAT THIS DOES ───────────────────────────────────────────────────────────
--
--   A. erp.state_supplier_tax() takes a supplier's credit note as it takes
--      their bill: a purchase, stated before the ledger has it
--      (CLOVEERP_TAX_AFTER_THE_LEDGER, 20260922170000), apportioned across the
--      lines, recorded as supplier_stated. The figure is stated as the
--      supplier's paperwork shows it, a positive amount; the note's base type
--      is what makes it come off box 4. A supplier gives back VAT only on what
--      they billed, so VAT on a note for goods nobody had billed is refused
--      (CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED): it would take out of box 4 tax
--      that was never put into it. Anchored on the base-type test and on the
--      net's sum, which the deployed body holds once each.
--      erp.document_billed_return_minor(), the basis billed_return_value, is
--      what the supplier credits less the accrual: the VAT is in it, so the
--      payable falls by the gross and 9100 keeps only the cost difference it
--      was for. Every return posted so far carries no tax, so no figure moves
--      and no posting rule or installer version changes.
--   B. erp.raise_supplier_credit_note() takes p_tax_minor and p_tax_code,
--      defaulted, and states the tax on the draft it raises, before anything
--      can issue it. Dropped and made again with the two arguments, as
--      erp.bill_from_receipt() was (20260922170000 §2), because Postgres
--      cannot tell a four-argument call from a six-argument one with two
--      defaults. Null is not zero, as there: null states nothing and the
--      lines keep what they carry. The door public.erp_raise_supplier_credit_note()
--      follows, and answers the tax the note carries. No posting rule
--      changes: the rule already credits tax control with it, A's basis
--      takes it off the payable, and the entry's sign takes it off box 4.
--   C. The demonstration's Thursday bill and its Tuesday return to a supplier
--      state the supplier's VAT before they post, through
--      erp.state_demonstration_input_tax(): 20% of the net, code S, where the
--      supplier is in the company's own country, the company is in the United
--      Kingdom and every line is of a standard-rated product. A supplier
--      abroad states nothing and stays flagged for the reverse charge, which
--      is not built (D8). Demonstration only (D12): nothing is done in a live
--      organisation, and no day already built is rebuilt.
--
-- ── CALLS MADE HERE, FOR THE PR DESCRIPTION ──────────────────────────────────
--
--   * The rate is the United Kingdom's standard rate, written here rather
--     than read from the rule set. The rules are written for supplies the
--     company makes (20260916410000), and the demonstration's supplier is the
--     one deciding what it charged; the helper is the supplier's invoice, not
--     a determination.
--   * A note with any line that is not standard-rated states nothing, rather
--     than put VAT on a zero-rated line by apportionment. Every product the
--     demonstration holds is standard-rated, so this changes nothing there.
--   * Every supplier abroad states nothing: Germany and the Netherlands as
--     asked, and Ireland with them, since it is abroad on the same terms.
--   * A supplier credit note's tax is stated under procurement.match at
--     public.erp_state_supplier_tax(), as a bill's is, and under
--     procurement.order when it is stated as the note is raised, which is
--     that door's permission. The document screen offers "State their tax"
--     on a draft supplier credit note as it does on a draft bill.
--   * The code defaults to S when a figure is given without one, where
--     erp.bill_from_receipt() passes a null code through.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * No backfill. Posted documents are unchanged; a credit note that posted
--     without tax is corrected by the supplier's next paperwork, as any error
--     in a filed return is (D14).
--   * The demonstration's days already built keep a box 4 of nought; only the
--     days built from now on carry VAT on their bills and returns (D12). Its
--     Tuesday return takes the newest receipt, which its Thursday bill has
--     usually not reached, so most returns state none.
--   * No table, column, lifecycle or posting rule. One refusal.
--   * A note whose bill is cancelled between stating its VAT and issuing it
--     posts the VAT against the payable with no bill behind it; the check is
--     made when the figure is stated, as the ledger guard is.
--   * Box 7 falls by the whole of a return's net, the part nobody billed
--     included, as it did before this (20261001000000); only box 4 is
--     limited to what was billed.
--
-- Proved by erp_test.vat_return_suite cases 15 to 19 and
-- erp_test.demonstration_vat_returns_suite case 2.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- A. The supplier's credit note states its tax
-- ═════════════════════════════════════════════════════════════════════════════

do $state_supplier_tax$
declare
  v_sig constant text := 'erp.state_supplier_tax(uuid, bigint, text, text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  if coalesce(v_base, '') not in ('invoice_reference', 'credit_reference') then$o$,
    $n$  -- A supplier's credit note states the tax it gives back as their bill
  -- states what it charged (20261001400000): positive, as their paperwork
  -- shows it, and taken off box 4 by the note's base type.
  if coalesce(v_base, '') not in ('invoice_reference', 'credit_reference', 'return_to_supplier') then$n$,
    $o$  select coalesce(sum(l.net_minor), 0) into v_net
    from erp.document_line l
$o$,
    $n$  -- A supplier gives back VAT only on what they billed. Goods returned
  -- before anybody billed them unmake the accrual, and no VAT was ever
  -- claimed on them to give back (20261001400000).
  if v_base = 'return_to_supplier' and coalesce(p_tax_minor, 0) > 0
     and erp.document_value_minor(p_document_id)
         - erp.document_unbilled_return_minor(p_document_id) <= 0 then
    raise exception
      'CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED: % returns goods nobody has billed, so there is no VAT on it to give back',
      d.document_number
      using errcode = '23514',
            hint = 'Enter the supplier''s bill for the goods first, then state the VAT their credit note gives back. '
                   'Where they never billed them, issue the credit note with no VAT.';
  end if;

  select coalesce(sum(l.net_minor), 0) into v_net
    from erp.document_line l
$n$];
  v_hits integer;
begin
  if position('CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$state_supplier_tax$;

select erp.register_refusal('CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED',
  'Stating VAT on a supplier credit note for goods nobody had billed.',
  'A supplier gives back VAT only on what they billed. Goods sent back before their bill was entered unmake the accrual for them, and no VAT was claimed on them, so VAT on that credit note would take out of the VAT return tax that was never put into it.',
  'Enter the supplier''s bill for the goods first and then state the VAT their credit note gives back. Where they never billed the goods, issue the credit note with no VAT.');

-- A2. What the note takes off the payable is what the supplier credits,
--     VAT and all. The posting rule purchase_credit_note debits trade payable
--     with basis billed_return_value and balances on price variance (9100):
--     taken as value less accrual, the VAT it credits to tax control was
--     balanced by a debit to 9100, an expense, where the supplier owes it
--     back. Found on this milestone's build (the plan read the rule as
--     crediting tax against the payable). Every return posted so far carried
--     no tax, so no figure any organisation has moves, and no rule changes.

create or replace function erp.document_billed_return_minor(p_document_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  -- The rest of what the supplier is crediting: the part of the return whose
  -- goods had already been billed, so the claim it reduces is the payable and
  -- not the accrual, with the VAT the supplier gives back on it
  -- (20261001400000), which erp.state_supplier_tax() takes only where a part
  -- was billed. Taken as the remainder rather than summed again, so the two
  -- measures add to what the supplier credits by construction and it is
  -- accounted for exactly once.
  select (erp.document_value_minor(p_document_id)
          + erp.document_tax_minor(p_document_id)
          - erp.document_unbilled_return_minor(p_document_id))::bigint
$$;

revoke all on function erp.document_billed_return_minor(uuid) from public, anon;

comment on function erp.document_billed_return_minor(uuid) is
  'What a supplier credit note takes off the payable: what it credits, VAT included (20261001400000), '
  'less the accrual it reverses. The measure a posting line names as basis billed_return_value. A return '
  'of goods nobody had billed measures nothing here and raises no line, because no claim had crystallised '
  'to reduce, and carries no VAT (CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED).';

comment on function erp.state_supplier_tax(uuid, bigint, text, text) is
  'Records the tax a supplier''s invoice or credit note states, apportioned across its lines by '
  'what each is worth, before the ledger has the document (20260922170000). Not determined: what a '
  'supplier charged is a fact about their supply under their obligations. A credit note''s figure is '
  'stated positive and comes off box 4 by its base type (20261001400000).';

-- ═════════════════════════════════════════════════════════════════════════════
-- B. And the note is raised with it
-- ═════════════════════════════════════════════════════════════════════════════

do $raise_supplier_credit_note$
declare
  v_old_sig constant text := 'erp.raise_supplier_credit_note(uuid, text, text, jsonb)';
  v_def text;
  v_head_old constant text := 'p_lines jsonb DEFAULT NULL::jsonb)';
  v_head_new constant text :=
    'p_lines jsonb DEFAULT NULL::jsonb, p_tax_minor bigint DEFAULT NULL::bigint, p_tax_code text DEFAULT NULL::text)';
  v_old constant text := $o$  return v_cn;
end;$o$;
  v_new constant text := $n$  -- The tax the supplier credits, on the draft and before anything can
  -- issue it (20261001400000): the ledger reads the figure once, as the note
  -- posts. Null states nothing, and the lines keep what they carry; zero
  -- says the supplier credited none.
  if p_tax_minor is not null then
    perform erp.state_supplier_tax(v_cn, p_tax_minor, coalesce(nullif(btrim(p_tax_code), ''), 'S'),
                                   'credited against ' || d.document_number);
  end if;

  return v_cn;
end;$n$;
  v_hits integer;
begin
  if to_regprocedure('erp.raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text)') is not null then
    return;
  end if;
  v_def := pg_get_functiondef(v_old_sig::regprocedure);
  v_hits := (length(v_def) - length(replace(v_def, v_head_old, ''))) / length(v_head_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % argument list found % time(s)', v_old_sig, v_hits;
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % closing return found % time(s)', v_old_sig, v_hits;
  end if;
  execute 'drop function ' || v_old_sig;
  execute replace(replace(v_def, v_head_old, v_head_new), v_old, v_new);
end
$raise_supplier_credit_note$;

revoke all on function erp.raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text) from public, anon;

comment on function erp.raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text) is
  'A credit note against a goods receipt: the goods leave at what they cost, '
  'what we owe the supplier goes down by what they are crediting, and the '
  'purchase order''s history shows the return. Takes the tax the supplier '
  'credits and states it on the draft, because the ledger reads the figure once, '
  'as the note posts (20261001400000). Left in draft; issuing it posts.';

-- The desk door, which had the same shape and the same gap.

drop function if exists public.erp_raise_supplier_credit_note(uuid, text, text, jsonb);

create or replace function public.erp_raise_supplier_credit_note(
  p_document_id uuid,
  p_reason_code text,
  p_reason      text   default null,
  p_lines       jsonb  default null,
  p_tax_minor   bigint default null,
  p_tax_code    text   default null)
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid := erp.raise_supplier_credit_note(p_document_id, p_reason_code, p_reason, p_lines,
                                              p_tax_minor, p_tax_code);
begin
  return (select jsonb_build_object(
            'document_id', d.id,
            'document_number', d.document_number,
            'lines', (select count(*) from erp.document_line l
                       where l.tenant_id = d.tenant_id and l.document_id = d.id),
            'tax_minor', erp.document_tax_minor(d.id))
            from erp.document d
           where d.tenant_id = erp.current_tenant_id() and d.id = v_id);
end;
$$;

revoke all on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text)
  from public, anon;
grant execute on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text)
  to authenticated, service_role;

comment on function public.erp_raise_supplier_credit_note(uuid, text, text, jsonb, bigint, text) is
  'Raises a credit note against a goods receipt, in draft, with the goods on it and the tax the '
  'supplier credits stated where it is given.';

-- The allowance keys on the name, so it still names this door; its rationale
-- is restated because what the door writes has moved.
insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_supplier_credit_note', 'erp.raise_supplier_credit_note',
   'Raises a purchase credit note in draft against the goods receipt it reverses, under '
   'procurement.order — the permission erp_ref.document_type already gives the return_to_supplier '
   'base type — and states the tax the supplier credits where it is given, before the note can '
   'post. It writes erp.document, erp.document_line, erp.document_relation and '
   'erp.tax_determination; nothing leaves the shelf until the credit note is issued.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- C. The demonstration's bills and returns state their suppliers' VAT (D12)
-- ═════════════════════════════════════════════════════════════════════════════

-- C1. What the demonstration's supplier charged.

create or replace function erp.state_demonstration_input_tax(p_document_id uuid)
returns bigint
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_net     bigint;
  v_tax     bigint;
begin
  -- The VAT a demonstration's supplier charged on a bill, or gave back on a
  -- credit note, stated before either posts (20261001400000, D12): the United
  -- Kingdom's standard rate of 20% on the net, code S, where the supplier is
  -- in the company's own country, the company is in the United Kingdom, and
  -- every line is of a product rated standard (a product with no class is
  -- standard, as erp.determine_tax() reads it). Anything else states nothing
  -- and answers null: a supplier abroad is left to the reverse charge, which
  -- is flagged and not built (D8), and a line rated otherwise is not given
  -- VAT by apportionment. On a return, the rate is taken of the part that
  -- was billed. Nothing in a live organisation.
  if erp.environment_is_live() then
    return null;
  end if;

  select coalesce(sum(l.net_minor), 0) into v_net
    from erp.document d
    join erp.entity e on e.tenant_id = d.tenant_id and e.id = d.entity_id
    join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
    join erp.document_line l
      on l.tenant_id = d.tenant_id and l.document_id = d.id and not coalesce(l.is_cancelled, false)
   where d.tenant_id = v_tenant and d.id = p_document_id
     and e.country_code = 'GB' and p.country_code = e.country_code
     and not exists (select 1 from erp.document_line l2
                       left join erp.item i on i.tenant_id = l2.tenant_id and i.id = l2.item_id
                      where l2.tenant_id = d.tenant_id and l2.document_id = d.id
                        and not coalesce(l2.is_cancelled, false)
                        and coalesce(i.tax_class, 'standard') <> 'standard');
  -- A return gives back VAT only on the part that was billed: goods sent
  -- back before their bill carry none (CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED).
  if v_net > 0 and exists (select 1 from erp.document d
                             join erp.document_type dt
                               on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
                            where d.tenant_id = v_tenant and d.id = p_document_id
                              and dt.base_type_code = 'return_to_supplier') then
    v_net := v_net - erp.document_unbilled_return_minor(p_document_id);
  end if;
  if v_net <= 0 then
    return null;
  end if;

  v_tax := round(v_net * 0.20)::bigint;
  perform erp.state_supplier_tax(p_document_id, v_tax, 'S', 'demonstration');
  return v_tax;
end;
$$;

revoke all on function erp.state_demonstration_input_tax(uuid) from public, anon;

comment on function erp.state_demonstration_input_tax(uuid) is
  'The VAT a demonstration''s supplier charged on a bill or credited on a return (20261001400000, D12): '
  '20% of the net, code S, stated through erp.state_supplier_tax() before the document posts, where the '
  'supplier and the company are both in the United Kingdom and every line is standard-rated. Null, and '
  'nothing stated, otherwise or in a live organisation. Called by erp.seed_demo_history().';

-- C2. The builder states it on the Thursday bill and the Tuesday return.

do $seed_demo_history$
declare
  v_sig constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        perform erp.transition_document(v_bill, 'register', 'demonstration');
$o$,
    $n$        -- What the supplier charged, stated before the bill posts
        -- (20261001400000): the ledger reads the figure once, as it posts.
        perform erp.state_demonstration_input_tax(v_bill);
        perform erp.transition_document(v_bill, 'register', 'demonstration');
$n$,
    $o$        perform erp.transition_document(v_scn, 'issue', 'demonstration');
$o$,
    $n$        -- And what the supplier gives back of it, before the note posts.
        perform erp.state_demonstration_input_tax(v_scn);
        perform erp.transition_document(v_scn, 'issue', 'demonstration');
$n$];
  v_hits integer;
begin
  if position('erp.state_demonstration_input_tax(' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$seed_demo_history$;

-- ═════════════════════════════════════════════════════════════════════════════
-- D. The suites
-- ═════════════════════════════════════════════════════════════════════════════

-- D1. erp_test.vat_return_suite, restated whole with cases 15 to 19: goods
--     returned to a supplier who charged VAT on them, and the
--     demonstration's suppliers charging it. The whole organisation's
--     agreement is now case 20, over the returns as well, and the undo 21.

create or replace function erp_test.vat_return_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c_expected constant integer := 21;
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
  v_rl uuid; v_scn uuid; v_scn2 uuid; v_abroad uuid; v_dh uuid; v_da uuid; v_db uuid;
  v_po3 uuid; v_pol3 uuid; v_grn3 uuid; v_rl3 uuid; v_scn3 uuid;
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

    -- ── 15. Goods returned to a supplier who charged VAT on them ────────────
    -- S4 pinned (20261001400000): a supplier credit note could never state
    -- tax, so the whole of the VAT on returned goods stayed in box 4.
    v_step := 'ten of the hundred returned against the receipt, the supplier crediting their VAT';
    select l.id into v_rl from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_grn and not coalesce(l.is_cancelled, false)
     order by l.line_no limit 1;
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_scn := erp.raise_supplier_credit_note(v_grn, 'damaged', 'ten crushed on the pallet',
                                            jsonb_build_array(jsonb_build_object('line_id', v_rl, 'quantity', 10)),
                                            2000);
    v_z := erp.document_tax_minor(v_scn);
    perform erp.transition_document(v_scn, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    select coalesce(sum(jl.base_credit_minor - jl.base_debit_minor), 0) into v_x
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn and a.control_kind = 'tax';
    v_cases := v_cases + 1;
    case_name := 'a supplier credit note of a hundred pounds giving back twenty of VAT takes twenty out of box 4 and a hundred out of box 7, at the standard code where the figure came without one, and tax control is credited with it';
    passed := v_state is null
          and v_z = 2000
          and b1.box4_minor - b0.box4_minor = -2000
          and b1.box7_pounds - b0.box7_pounds = -100
          and b1.box1_minor = b0.box1_minor
          and v_x = 2000
          and exists (select 1 from erp.vat_entries(v_entity, v_wide_from, v_today) e
                       where e.document_id = v_scn and e.side = 'purchase' and e.sign = -1
                         and e.tax_minor = -2000 and e.determined_tax_minor = -2000
                         and e.net_minor = -10000)
          and exists (select 1 from erp.tax_determination td
                       where td.tenant_id = rb.tenant_id and td.document_id = v_scn
                         and td.rule_code = 'supplier_stated' and td.tax_code = 'S' and td.rate_pct = 20);
    detail := coalesce(v_state, format('the note carries %s; box 4 moved %s, box 7 %s, box 1 %s; tax control credited %s',
                                       v_z, b1.box4_minor - b0.box4_minor, b1.box7_pounds - b0.box7_pounds,
                                       b1.box1_minor - b0.box1_minor, v_x));
    return next;

    -- ── 16. And box 4 is the net of the bill and its return ─────────────────
    v_step := 'the bill, its return and the ledger read together';
    select coalesce(sum(jl.base_credit_minor - jl.base_debit_minor), 0) into v_y
      from erp.journal j
      join erp.ledger l on l.tenant_id = j.tenant_id and l.id = j.ledger_id and l.ledger_kind = 'statutory'
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.entity_id = v_entity and j.status = 'posted'
       and j.document_id is not null
       and j.posting_date between v_wide_from and v_today and a.control_kind = 'tax';
    select coalesce(sum(e.tax_minor), 0) into v_x
      from erp.vat_entries(v_entity, v_wide_from, v_today) e
     where e.document_id in (v_bill, v_scn);
    select count(*) into v_n from erp.vat_exceptions(v_entity, v_wide_from, v_today) x where x.blocks;
    select count(*) into v_m from erp.tax_outside_the_ledger_report() t
     where t.reference in (select d.document_number from erp.document d where d.id in (v_bill, v_scn));
    select coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0) into v_z
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
      join erp.account a on a.tenant_id = jl.tenant_id and a.id = jl.account_id
     where j.tenant_id = rb.tenant_id and j.document_id = v_scn and a.control_kind = 'payable';
    v_cases := v_cases + 1;
    case_name := 'box 4 holds the bill''s VAT less what its return gave back, box 1 less box 4 is what the documents moved on tax control, the tax report says the same, the payable falls by what the supplier credits with its VAT and not by the net, and nothing blocks';
    passed := v_state is null
          and v_x = 18000
          and b1.box1_minor - b1.box4_minor = v_y
          and b1.ledger_disagreements = 0
          and v_n = 0 and v_m = 0
          and v_z = 12000
          and (select coalesce(sum(t.tax_minor), 0) from erp.tax_report(v_wide_from, v_today, v_entity) t
                where t.direction = 'input') = b1.box4_minor;
    detail := coalesce(v_state, format('the bill and its return %s in box 4; box 1 less box 4 %s, tax control %s; payable debited %s; %s blocking, %s outside the ledger',
                                       v_x, b1.box1_minor - b1.box4_minor, v_y, v_z, v_n, v_m));
    return next;

    -- ── 17. Stated once, before it posts, and only on what was billed ──────
    v_step := 'the returned VAT restated after the note posted, and VAT on goods nobody billed';
    v_msg := null;
    begin
      perform erp.state_supplier_tax(v_scn, 3000, 'S', 'they sent a second credit note');
    exception when others then v_msg := sqlerrm; end;
    v_po3 := erp.open_document('purchase_order', v_supplier, v_entity, v_site);
    v_pol3 := erp.add_document_line(v_po3, v_item, 20, 1000, 'received and never billed');
    perform erp.transition_document(v_po3, 'submit', 'vat return suite');
    perform erp_test.approve_document(v_po3, 'vat return suite');
    perform erp.transition_document(v_po3, 'send', 'vat return suite');
    v_grn3 := erp.open_document('goods_receipt', v_supplier, v_entity, v_site);
    perform erp.receive_against(v_grn3, v_pol3, 20, null);
    perform erp.transition_document(v_grn3, 'post', 'vat return suite');
    select l.id into v_rl3 from erp.document_line l
     where l.tenant_id = rb.tenant_id and l.document_id = v_grn3 and not coalesce(l.is_cancelled, false)
     order by l.line_no limit 1;
    v_msg2 := null;
    begin
      perform erp.raise_supplier_credit_note(v_grn3, 'damaged', 'two of twenty, never billed',
                                             jsonb_build_array(jsonb_build_object('line_id', v_rl3, 'quantity', 2)),
                                             400, 'S');
    exception when others then v_msg2 := sqlerrm; end;
    v_scn3 := erp.raise_supplier_credit_note(v_grn3, 'damaged', 'two of twenty, never billed',
                                             jsonb_build_array(jsonb_build_object('line_id', v_rl3, 'quantity', 2)));
    v_cases := v_cases + 1;
    case_name := 'stating the returned VAT again once the credit note has posted is refused, and the note keeps its figure; VAT on a return of goods nobody billed is refused by name, and the same return raised with none is';
    passed := v_state is null
          and v_msg like 'CLOVEERP_TAX_AFTER_THE_LEDGER%'
          and erp.document_tax_minor(v_scn) = 2000
          and v_msg2 like 'CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED%'
          and exists (select 1 from erp_ref.refusal f where f.code = 'CLOVEERP_TAX_ON_WHAT_WAS_NEVER_BILLED')
          and v_scn3 is not null and erp.document_tax_minor(v_scn3) = 0;
    detail := coalesce(v_state, format('%s; the note carries %s; never billed: %s', coalesce(left(v_msg, 110), 'it was restated'),
                                       erp.document_tax_minor(v_scn), coalesce(left(v_msg2, 110), 'accepted')));
    return next;

    -- ── 18. The desk: raised without a figure, stated on the draft ──────────
    -- Null is not zero: the door raises a note with none, and the document
    -- screen states it on the draft, through the door that states a bill's.
    v_step := 'five more returned at the door, the VAT stated on the draft';
    res := public.erp_raise_supplier_credit_note(
             v_grn, 'damaged', 'five more crushed',
             jsonb_build_array(jsonb_build_object('line_id', v_rl, 'quantity', 5)));
    v_scn2 := (res ->> 'document_id')::uuid;
    v_z := (res ->> 'tax_minor')::bigint;
    select * into b0 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    res := public.erp_state_supplier_tax(v_scn2, 1000, 'S', 'their credit note');
    perform erp.transition_document(v_scn2, 'issue', 'vat return suite');
    select * into b1 from erp.vat_return_boxes(v_entity, v_wide_from, v_today);
    v_msg := null;
    begin
      perform public.erp_raise_supplier_credit_note(
                v_grn, 'damaged', 'one more, a negative figure',
                jsonb_build_array(jsonb_build_object('line_id', v_rl, 'quantity', 1)), -200, 'S');
    exception when others then v_msg := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a credit note raised at the door with no figure carries none, its VAT stated on the draft comes out of box 4 as it issues, and a negative figure is refused';
    passed := v_state is null
          and v_z = 0
          and (res ->> 'tax_minor')::bigint = 1000
          and b1.box4_minor - b0.box4_minor = -1000
          and b1.box7_pounds - b0.box7_pounds = -50
          and b1.ledger_disagreements = 0
          and v_msg like 'CLOVEERP_TAX_IS_NOT_NEGATIVE%';
    detail := coalesce(v_state, format('raised carrying %s, stated %s; box 4 moved %s, box 7 %s; negative: %s',
                                       v_z, res ->> 'tax_minor', b1.box4_minor - b0.box4_minor,
                                       b1.box7_pounds - b0.box7_pounds, coalesce(left(v_msg, 80), 'accepted')));
    return next;

    -- ── 19. The demonstration's suppliers charge VAT ─────────────────────────
    -- D12: what the builder states on its Thursday bill and its Tuesday
    -- return, on the demonstration's own suppliers and products.
    v_step := 'bills from a supplier at home, one abroad, and one for bread, stated as the demonstration states them';
    select p.id into v_abroad from erp.party p
      join erp.party_role pr on pr.tenant_id = p.tenant_id and pr.party_id = p.id
       and pr.role_kind = 'supplier' and pr.status = 'active'
     where p.tenant_id = rb.tenant_id and p.country_code in ('DE', 'NL') order by p.code limit 1;
    v_dh := erp.create_document('purchase_invoice', v_entity, v_site, v_supplier, v_today, v_ccy, 'ZZVR-DEMO-HOME', '{}'::jsonb);
    perform erp.add_document_line(v_dh, v_item, 3, 3333, 'at home');
    v_da := erp.create_document('purchase_invoice', v_entity, v_site, v_abroad, v_today, v_ccy, 'ZZVR-DEMO-ABROAD', '{}'::jsonb);
    perform erp.add_document_line(v_da, v_item, 3, 3333, 'from abroad');
    v_db := erp.create_document('purchase_invoice', v_entity, v_site, v_supplier, v_today, v_ccy, 'ZZVR-DEMO-BREAD', '{}'::jsonb);
    perform erp.add_document_line(v_db, v_item, 1, 1000, 'standard');
    perform erp.add_document_line(v_db, v_zero, 1, 1000, 'bread');
    v_x := erp.state_demonstration_input_tax(v_dh);
    v_y := erp.state_demonstration_input_tax(v_da);
    v_z := erp.state_demonstration_input_tax(v_db);
    v_n := coalesce(erp.state_demonstration_input_tax(v_scn3), -1);
    update erp.environment set is_live = true where tenant_id = rb.tenant_id and is_self;
    v_ok := erp.state_demonstration_input_tax(v_dh) is null;
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    select pg_get_functiondef('erp.seed_demo_history(date,date,numeric)'::regprocedure) into v_msg;
    v_cases := v_cases + 1;
    case_name := 'the demonstration''s bill from a supplier at home states 20% of its net as the builder states it before registering, one from abroad, one with a zero-rated line and a return of goods nobody billed state nothing, a live organisation states nothing, and the builder states it before its bill and its return post';
    passed := v_state is null
          and v_x = 2000 and erp.document_tax_minor(v_dh) = 2000
          and v_y is null and erp.document_tax_minor(v_da) = 0
          and v_z is null and erp.document_tax_minor(v_db) = 0
          and v_n = -1 and erp.document_tax_minor(v_scn3) = 0
          and v_ok
          and position('erp.state_demonstration_input_tax(v_bill);' in v_msg) > 0
          and position('erp.state_demonstration_input_tax(v_bill);' in v_msg)
              < position('erp.transition_document(v_bill, ''register''' in v_msg)
          and position('erp.state_demonstration_input_tax(v_scn);' in v_msg) > 0
          and position('erp.state_demonstration_input_tax(v_scn);' in v_msg)
              < position('erp.transition_document(v_scn, ''issue''' in v_msg);
    detail := coalesce(v_state, format('at home %s (carries %s), abroad %s (carries %s), with bread %s (carries %s), the unbilled return %s; live %s',
                                       v_x, erp.document_tax_minor(v_dh), coalesce(v_y::text, 'none'),
                                       erp.document_tax_minor(v_da), coalesce(v_z::text, 'none'),
                                       erp.document_tax_minor(v_db), case when v_n = -1 then 'none' else v_n::text end, case when v_ok then 'none' else 'stated' end));
    return next;

    -- ── 20. The whole organisation agrees ───────────────────────────────────
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

  -- ── 21. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzvr-' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, s_ware, s_read));
  detail := coalesce(v_state, 'the organisation rolled back with its bills, invoices, credit notes and journals');
  return next;

  -- The count guard says what stopped the fixture.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$function$;

revoke all on function erp_test.vat_return_suite() from public, anon;

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
  if v_total <> 21 then
    raise exception 'CLOVEERP_VAT_RETURN_SUITE_SHRANK: % case(s), expected 21', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('vat return: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_vat_return_suite() from public, anon;

-- D2. erp_test.demonstration_vat_returns_suite case 2, re-pinned: the
--     demonstration's return holds in box 4 what the week's bills and
--     returns to suppliers stated, each by the demonstration's rule, where it
--     had held nought (M4). Its count is unchanged.

do $demonstration_vat_returns_suite$
declare
  v_sig constant text := 'erp_test.demonstration_vat_returns_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_notes text; v_ok boolean; v_msg text;
$o$,
    $n$  v_notes text; v_ok boolean; v_msg text;
  v_input bigint; v_home integer; v_abroad integer; v_wrong integer;
$n$,
    $o$    v_exp := public.erp_vat_return_export(v_ret, 'csv');
$o$,
    $n$    -- What the week's supplier documents stated (20261001400000): 20% of
    -- the net from a supplier at home, of a return's billed part, nothing
    -- from abroad, a return negative. Read from their lines, not from the
    -- entries box 4 is.
    select coalesce(sum(case when dt.base_type_code = 'return_to_supplier' then -1 else 1 end
                        * erp.document_tax_minor(d.id)), 0),
           count(*) filter (where p.country_code = 'GB'),
           count(*) filter (where p.country_code <> 'GB'),
           count(*) filter (where erp.document_tax_minor(d.id)
                                  <> case when p.country_code = 'GB'
                                          then round((erp.document_value_minor(d.id)
                                                      - case when dt.base_type_code = 'return_to_supplier'
                                                             then erp.document_unbilled_return_minor(d.id)
                                                             else 0 end) * 0.20)::bigint
                                          else 0 end)
      into v_input, v_home, v_abroad, v_wrong
      from erp.document d
      join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      join erp.party p on p.tenant_id = d.tenant_id and p.id = d.party_id
     where d.tenant_id = v_ta and dt.code in ('purchase_invoice', 'purchase_credit_note')
       and d.document_date between v_ppq_from and v_ppq_to
       and exists (select 1 from erp.journal j
                    where j.tenant_id = d.tenant_id and j.document_id = d.id and j.status = 'posted');
    v_exp := public.erp_vat_return_export(v_ret, 'csv');
$n$,
    $o$nothing blocks, every finding is a flag the product raises for a judgement, and it exports';$o$,
    $n$nothing blocks, every finding is a flag the product raises for a judgement, and it exports; its box 4 is the VAT the week''s bills and returns to suppliers stated, 20% of the net from a supplier at home and nothing from abroad';$n$,
    $o$          and v_blocks = 0 and v_odd = 0
$o$,
    $n$          and v_blocks = 0 and v_odd = 0
          and (bx ->> 'box4_minor')::bigint = v_input
          and v_wrong = 0
$n$,
    $o$                                       v_entries, bx, v_ledger, v_blocks, v_odd));$o$,
    $n$                                       v_entries, bx, v_ledger, v_blocks, v_odd)
                                || format('; %s from home and %s from abroad stated %s, %s against the rule',
                                          v_home, v_abroad, v_input, v_wrong));$n$];
  v_hits integer;
begin
  if position('v_input bigint;' in v_def) > 0 then
    return;
  end if;
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$demonstration_vat_returns_suite$;


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
select erp.assert_no_dead_configuration();
select erp.assert_every_posting_can_be_undone();
