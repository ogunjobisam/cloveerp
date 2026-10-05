set lock_timeout = '30s';

-- =============================================================================
-- 20261006160000  A demonstration pays its suppliers
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-142). Its customers
-- pay (erp.seed_demo_history() applies their cash), but nothing ever pays a
-- supplier: neither the history builder nor erp.demonstration_catch_up()
-- raises a payment run. So the bank account is never credited, what the
-- demonstration owes its suppliers only grows, and every bill ages past its
-- due date. A new demonstration is built the same way.
--
-- A supplier is paid in one way only: a payment run proposed by one person,
-- approved by another, then paid (erp.approve_payment_run() refuses the
-- person who proposed it). Until #419 a demonstration had one person who
-- could do either. It now has a second, Priya Shah of Finance
-- (20261006150000), whom the person who signed in may act as
-- (20261006152000). This uses her. The rule is not touched: the run is
-- proposed as the person who signed in, and approved and paid as her, through
-- the same substitution erp.principal_context() makes for a visitor who
-- chooses her under Act as.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. erp.demonstration_pay_day(day): the last working day (Monday to
--      Friday) of the day's month, the day a demonstration pays its
--      suppliers.
--   B. erp.pay_demonstration_suppliers(on, due_by): in a demonstration that
--      is not live, and only when something billed on or before the day is
--      owed and due by due_by, proposes a payment run dated that day as the
--      person who signed in, then approves and pays it as the demonstration's
--      other person, and puts that person's own Act as choice back as it was.
--      A bill registered after the day is not that day's to pay. Without a
--      second person who may approve and post, or a signed-in person who may
--      give people their roles, nothing is paid and it says so. A refusal is
--      a note, and leaves nothing behind.
--   C. erp.seed_demo_history() pays on each month's last working day it
--      builds, for what falls due within the week after: the journal, the
--      bank line and the payments are dated that day.
--   D. erp.demonstration_catch_up() pays what the month ends it never paid
--      left owing: once trading is done, before the months are closed, one
--      run dated the last day traded for what fell due by a week after the
--      last pay day the trading has passed. On a demonstration that has been
--      paying, that is nothing. It names the runs it paid in its notes and in
--      supplier_runs_paid.
--   E. erp_test.demonstration_pays_suppliers_suite, eight cases.
--
-- Decided, and why. The batch asked for erp_test.demo_history_suite to be
-- extended. Its fixture (zzdemo) is not a demonstration, so it has no second
-- person and cannot show a run being approved; a suite of its own stands up a
-- demonstration instead. Bills on a run somebody left proposed or approved
-- are left to that run (20261006040000). Paying at the month's last working
-- day, for a week ahead, is how a small company pays: one run a month.
--
-- On production: functions only. No row is written by this migration and no
-- table is altered. The deploy's catch-up then pays, in organisations whose
-- address begins demo- and that are not live and nowhere else, what is owed
-- and due, dated the last day it has traded.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The day a demonstration pays
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.demonstration_pay_day(p_day date)
returns date
language sql
immutable
set search_path = ''
as $$
  -- The last Monday-to-Friday of p_day's month (20261006160000).
  select m - case extract(isodow from m)::integer when 6 then 1 when 7 then 2 else 0 end
    from (select (date_trunc('month', p_day) + interval '1 month - 1 day')::date as m) x
$$;

revoke all on function erp.demonstration_pay_day(date) from public, anon;

comment on function erp.demonstration_pay_day(date) is
  'The last working day (Monday to Friday) of the month a day falls in: the day a demonstration pays its '
  'suppliers (20261006160000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Proposed by one person, approved and paid by the other
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.pay_demonstration_suppliers(p_on date, p_due_by date)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_aside   constant text := coalesce(current_setting('erp.persona_set_aside', true), '');
  v_ccy     char(3);
  v_self    uuid;
  v_persona uuid;
  v_had     boolean;
  v_prev    uuid;
  v_prev_at timestamptz;
  v_run     uuid;
  v_total   bigint;
  v_paid    jsonb;
  v_out     jsonb;
begin
  -- A demonstration pays its suppliers (20261006160000, J-142). Only a
  -- demonstration that is not live has somebody else to approve with.
  if not erp.tenant_is_demonstration(v_tenant) or erp.environment_is_live() then
    return null;
  end if;

  select l.currency into v_ccy
    from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;

  -- Something to pay: owed, billed on or before the day, due by p_due_by, and
  -- on no run being put together, proposed or approved (20261006040000).
  if v_ccy is null or not exists (
       select 1
         from erp.subledger_item si
        where si.tenant_id = v_tenant
          and si.control_kind = 'payable'
          and si.currency = v_ccy
          and si.credit_minor - si.debit_minor - coalesce(si.settled_minor, 0) > 0
          and si.posting_date <= p_on
          and si.due_date <= p_due_by
          and not exists (select 1
                            from erp.payment_proposal_line ol
                            join erp.payment_proposal op
                              on op.tenant_id = ol.tenant_id and op.id = ol.payment_proposal_id
                           where ol.tenant_id = v_tenant
                             and ol.subledger_item_id = si.id
                             and op.status in ('draft', 'proposed', 'approved'))) then
    return null;
  end if;

  -- Who proposes is the person who signed in, as themselves, whatever they
  -- chose under Act as. Who approves is somebody else.
  perform set_config('erp.persona_set_aside', 'yes', true);
  v_self := erp.current_principal_id();
  select dp.app_user_id into v_persona
    from erp.demonstration_persona dp
    join erp.app_user u on u.tenant_id = dp.tenant_id and u.id = dp.app_user_id
   where dp.tenant_id = v_tenant
     and u.kind = 'person'::erp.principal_kind
     and u.status = 'active'::erp.principal_status
     and u.auth_user_id is null
     and u.id is distinct from v_self
     and erp.has_permission('finance.approve_payment', null, null, null, u.id)
     and erp.has_permission('finance.post', null, null, null, u.id)
   order by dp.code, dp.app_user_id
   limit 1;

  if v_self is null or v_persona is null
     or not erp.has_permission('administration.roles', null, null, null, v_self) then
    perform set_config('erp.persona_set_aside', v_aside, true);
    return jsonb_build_object('note', format(
      'No supplier was paid on %s. A payment run is approved by somebody other than the person who '
      'proposed it, and the demonstration has nobody else who may approve and pay one.',
      to_char(p_on, 'DD Mon YYYY')));
  end if;

  begin
    v_run := erp.propose_payment_run(p_on, v_ccy, make_interval(days => p_due_by - p_on));

    -- A bill registered after the day is not that day's to pay: it is paid by
    -- the next run.
    delete from erp.payment_proposal_line l
     using erp.subledger_item si
     where l.tenant_id = v_tenant and l.payment_proposal_id = v_run
       and si.tenant_id = l.tenant_id and si.id = l.subledger_item_id
       and si.posting_date > p_on;
    select coalesce(sum(l.amount_minor) filter (where not l.is_held), 0) into v_total
      from erp.payment_proposal_line l
     where l.tenant_id = v_tenant and l.payment_proposal_id = v_run;
    update erp.payment_proposal
       set total_minor = v_total, updated_at = now()
     where tenant_id = v_tenant and id = v_run;
    if v_total <= 0 then
      -- Everything due is held (a dispute, a match exception): no run.
      raise exception 'CLOVEERP_DEMO_NOTHING_TO_PAY: everything due on % is held', p_on
        using hint = 'Resolve the dispute or the match exception, and the next run pays the bill.';
    end if;

    -- The other person, by the choice a visitor makes under Act as, read by
    -- erp.principal_context() with every condition it sets. The signed-in
    -- person's own choice is put back below.
    select c.persona_id, c.chosen_at into v_prev, v_prev_at
      from erp.demonstration_persona_choice c
     where c.tenant_id = v_tenant and c.app_user_id = v_self;
    v_had := found;
    insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
    values (v_tenant, v_self, v_persona, now())
    on conflict (tenant_id, app_user_id)
    do update set persona_id = excluded.persona_id, chosen_at = excluded.chosen_at;
    perform set_config('erp.persona_set_aside', '', true);
    if erp.current_principal_id() is distinct from v_persona then
      raise exception 'CLOVEERP_DEMO_PERSONA_NOT_IN_FORCE: the demonstration''s other person could not be acted as'
        using hint = 'Act as the other person from the account menu, approve the run on Pay, then pay it.';
    end if;

    -- The rule is the rule: erp.approve_payment_run() refuses whoever
    -- proposed the run, and she did not.
    perform erp.approve_payment_run(v_run);
    v_paid := erp.pay_payment_run(v_run);

    perform set_config('erp.persona_set_aside', 'yes', true);
    if v_had then
      update erp.demonstration_persona_choice c
         set persona_id = v_prev, chosen_at = v_prev_at
       where c.tenant_id = v_tenant and c.app_user_id = v_self;
    else
      delete from erp.demonstration_persona_choice c
       where c.tenant_id = v_tenant and c.app_user_id = v_self;
    end if;

    v_out := jsonb_build_object(
      'proposal_id', v_run,
      'reference', (select p.reference from erp.payment_proposal p
                     where p.tenant_id = v_tenant and p.id = v_run),
      'payment_date', p_on,
      'paid_minor', coalesce((v_paid ->> 'paid_minor')::bigint, 0),
      'lines_paid', coalesce((v_paid ->> 'lines_paid')::integer, 0),
      'payments', coalesce(jsonb_array_length(v_paid -> 'payments'), 0),
      'proposed_by', v_self,
      'approved_by', v_persona);
  exception when others then
    v_out := case when sqlerrm like 'CLOVEERP_DEMO_NOTHING_TO_PAY%' then null
                  else jsonb_build_object('note', format(
                    'No supplier was paid on %s, because paying refused. %s',
                    to_char(p_on, 'DD Mon YYYY'), sqlerrm)) end;
  end;

  perform set_config('erp.persona_set_aside', v_aside, true);
  return v_out;
end;
$$;

revoke all on function erp.pay_demonstration_suppliers(date, date) from public, anon;

comment on function erp.pay_demonstration_suppliers(date, date) is
  'A demonstration pays its suppliers (20261006160000, J-142): a payment run dated the day, for what was billed '
  'by then and falls due by the second date, proposed as the person who signed in and approved and paid as the '
  'demonstration''s other person, whose own choice under Act as is put back. Nothing outside a demonstration '
  'that is not live; a note, and nothing paid, without a second person.';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The history builder pays on each month's last working day
-- ─────────────────────────────────────────────────────────────────────────────

do $history$
declare
  v_sig  constant text := 'erp.seed_demo_history(date,date,numeric)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$
  end loop days;
$o$;
  v_new  constant text := $n$
  -- ── The month's supplier payments ────────────────────────────────────────
  -- On the month's last working day the demonstration pays what it owes its
  -- suppliers that falls due within the week (20261006160000, J-142): one
  -- run, proposed as the person building and approved and paid as the
  -- demonstration's other person, dated the day. After everything else the
  -- day builds, so what it billed is there to be paid. Nothing here draws on
  -- random(), so the rest of the day is what it was.
  if v_day = erp.demonstration_pay_day(v_day) then
    declare
      v_payrun jsonb;
    begin
      v_payrun := erp.pay_demonstration_suppliers(v_day, v_day + 7);
      if v_payrun ? 'note' then
        v_notes := v_notes || to_jsonb(v_payrun ->> 'note');
      elsif v_payrun ? 'reference' then
        v_built := v_built + coalesce((v_payrun ->> 'payments')::integer, 0);
      end if;
    end;
  end if;

  end loop days;
$n$;
begin
  if strpos(v_src, '20261006160000') > 0 then
    raise notice '% already pays the month''s suppliers; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '94dcace50fe4d93649dce56e08089990' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006160000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$history$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. The catch-up pays what the month ends left owing
-- ─────────────────────────────────────────────────────────────────────────────

do $catch_up$
declare
  v_sig  constant text := 'erp.demonstration_catch_up()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  -- What it declares.
  v_old1 constant text := $o$  v_vat_before uuid[] := '{}'::uuid[];
$o$;
  v_new1 constant text := $n$  v_vat_before uuid[] := '{}'::uuid[];
  -- The supplier payments (20261006160000).
  v_runs_before uuid[] := '{}'::uuid[];
  v_runs     jsonb := '[]'::jsonb;
  v_pay_day  date;
  v_payrun   jsonb;
$n$;
  -- The runs there are before it trades.
  v_old2 constant text := $o$  select coalesce(array_agg(d.id), '{}'::uuid[]) into v_vat_before
$o$;
  v_new2 constant text := $n$  select coalesce(array_agg(pp.id), '{}'::uuid[]) into v_runs_before
    from erp.payment_proposal pp where pp.tenant_id = v_tenant;

  select coalesce(array_agg(d.id), '{}'::uuid[]) into v_vat_before
$n$;
  -- What the month ends never paid, before the months close.
  v_old3 constant text := $o$  -- ── The months whose trading is finished $o$;
  v_new3 constant text := $n$  -- ── What the month ends left owing (20261006160000, J-142) ────────────────
  --
  -- The builder pays on each month's last working day it builds. A day built
  -- before it did, or a bill that arrived after its month end, is still owed:
  -- paid here in one run dated the last day traded, for what fell due by a
  -- week after the last pay day the trading has passed, which is what that
  -- pay day would have paid. On a demonstration that has been paying, there
  -- is nothing. Before the close, so the month it is dated in is still open.
  begin
    if v_frontier is not null
       and (v_finish_by is null or clock_timestamp() < v_finish_by) then
      v_pay_day := erp.demonstration_pay_day(v_frontier);
      if v_pay_day > v_frontier then
        v_pay_day := erp.demonstration_pay_day((date_trunc('month', v_frontier) - interval '1 day')::date);
      end if;
      v_payrun := erp.pay_demonstration_suppliers(v_frontier, v_pay_day + 7);
      if v_payrun ? 'note' then
        v_notes := v_notes || to_jsonb(v_payrun ->> 'note');
      end if;
    end if;
  exception when others then
    v_notes := v_notes || to_jsonb(format(
      'What its suppliers are owed was left as it was, because paying refused. %s', sqlerrm));
  end;

  -- ── The months whose trading is finished $n$;
  -- And says which runs it paid.
  v_old4 constant text := $o$  return jsonb_build_object(
    'organisation',     v_code,
$o$;
  v_new4 constant text := $n$  select coalesce(jsonb_agg(pp.reference order by pp.payment_date, pp.reference), '[]'::jsonb)
    into v_runs
    from erp.payment_proposal pp
   where pp.tenant_id = v_tenant and pp.status = 'paid'
     and not (pp.id = any (v_runs_before));
  if jsonb_array_length(v_runs) > 0 then
    v_notes := v_notes || to_jsonb(format('Its suppliers were paid in %s run(s): %s.',
      jsonb_array_length(v_runs),
      (select string_agg(n, ', ') from jsonb_array_elements_text(v_runs) n)));
  end if;

  return jsonb_build_object(
    'organisation',     v_code,
    -- The payment runs it proposed and paid (20261006160000).
    'supplier_runs_paid', v_runs,
$n$;
begin
  if strpos(v_src, '20261006160000') > 0 then
    raise notice '% already pays what the month ends left owing; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '24a29cb4815a93734f0cac4232db4b85' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006160000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1
     or (length(v_def) - length(replace(v_def, v_old4, ''))) / length(v_old4) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % an anchor was found other than once', v_sig;
  end if;
  execute replace(replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3), v_old4, v_new4);
end
$catch_up$;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.demonstration_pays_suppliers_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'provisioning';
  v_state   text;
  -- The last pay day of the month before this one: the day the fixture pays.
  v_pay     date := erp.demonstration_pay_day((date_trunc('month', current_date) - interval '1 day')::date);
  v_priya   uuid;
  v_ccy     char(3);
  v_entity  uuid;
  v_bank    uuid;
  v_bank_code text;
  v_res     jsonb;
  v_calls   integer := 0;
  v_receipts uuid[];
  v_due     uuid;    -- billed before the pay day, due before it
  v_later   uuid;    -- billed before the pay day, due a month after it
  v_missed  uuid;    -- billed before the pay day after it was built
  v_chosen_at constant timestamptz := '2026-01-05 09:00+00';
  pp        record;
  v_runs    integer;
  v_runs2   integer;
  v_bank_cr bigint;
  v_paid_dr bigint;
  v_bad     integer;
  v_refused text;
  v_note    jsonb;
  v_cu      jsonb;
  v_who     uuid;
  v_choice  record;
begin
  begin
    -- ── The fixture: a demonstration that has traded the days before a pay day
    v_step := 'a demonstration configured from nothing';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'demo-zzpay' || v_tag, 'Demo Pays Suppliers Suite',
      'admin@demo-zzpay' || v_tag || '.test', 'Pays Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@demo-zzpay' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    select dp.app_user_id into v_priya from erp.demonstration_persona dp where dp.tenant_id = rb.tenant_id;
    select l.entity_id, l.currency into v_entity, v_ccy
      from erp.ledger l where l.tenant_id = rb.tenant_id and l.is_primary order by l.code limit 1;
    v_bank := erp.company_bank_account(v_entity);
    select a.code into v_bank_code from erp.account a where a.tenant_id = rb.tenant_id and a.id = v_bank;

    v_step := 'building the days before the pay day';
    v_res := erp.seed_demo_history(v_pay - 9, v_pay - 1, 1);
    while not coalesce((v_res ->> 'done')::boolean, true) and v_calls < 5 loop
      v_res := erp.seed_demo_history((v_res ->> 'next_from')::date, v_pay - 1, 1);
      v_calls := v_calls + 1;
    end loop;

    -- The receipts nobody has billed, oldest first. The first is billed due
    -- before the pay day, the second due a month after it; the third is kept
    -- for a bill that arrives after the pay day is built.
    v_step := 'billing the receipts';
    select array_agg(g.id order by g.document_date, g.document_number) into v_receipts
      from erp.document g
      join erp.document_type gt on gt.tenant_id = g.tenant_id and gt.id = g.document_type_id
     where g.tenant_id = rb.tenant_id and gt.code = 'goods_receipt' and not g.is_cancelled
       and erp.object_current_state('document', g.id) = 'posted'
       and exists (select 1 from erp.document_relation fr
                    where fr.tenant_id = g.tenant_id and fr.from_document_id = g.id
                      and fr.relation_kind = 'fulfils' and fr.to_line_id is not null)
       and not exists (select 1 from erp.document_relation fr
                         join erp.document_line ol on ol.tenant_id = fr.tenant_id and ol.id = fr.to_line_id
                        where fr.tenant_id = g.tenant_id and fr.from_document_id = g.id
                          and fr.relation_kind = 'fulfils' and coalesce(ol.quantity_invoiced, 0) > 0)
       and not exists (select 1 from erp.document_line gl
                         join erp.document_relation rr
                           on rr.tenant_id = gl.tenant_id and rr.to_line_id = gl.id and rr.relation_kind = 'returns'
                        where gl.tenant_id = g.tenant_id and gl.document_id = g.id);
    if coalesce(array_length(v_receipts, 1), 0) < 3 then
      raise exception 'CLOVEERP_DEMONSTRATION_PAYS_SUPPLIERS_FIXTURE: the days built % receipt(s) nobody billed, and the fixture needs three',
        coalesce(array_length(v_receipts, 1), 0);
    end if;
    v_due   := erp.bill_from_receipt(v_receipts[1], 'SUITE-DUE',   v_pay - 2, v_pay - 1, true);
    v_later := erp.bill_from_receipt(v_receipts[2], 'SUITE-LATER', v_pay - 2, v_pay + 30, true);

    -- The visitor once chose somebody and came back to themselves.
    insert into erp.demonstration_persona_choice (tenant_id, app_user_id, persona_id, chosen_at)
    values (rb.tenant_id, rb.admin_user_id, null, v_chosen_at);

    -- ── The pay day ─────────────────────────────────────────────────────────
    v_step := 'building the pay day';
    v_res := erp.seed_demo_history(v_pay, v_pay, 1);
    set constraints all immediate;
    select count(*) into v_runs from erp.payment_proposal p where p.tenant_id = rb.tenant_id;
    select p.* into pp from erp.payment_proposal p
     where p.tenant_id = rb.tenant_id and p.payment_date = v_pay
     order by p.created_at limit 1;

    -- ── 1. Proposed by one person, approved and paid by the other ───────────
    v_cases := v_cases + 1;
    case_name := 'on the month''s last working day the demonstration pays its suppliers: one run dated that day, proposed by the person building it and approved by the other person, and paid';
    passed := v_state is null and v_runs = 1
          and pp.status = 'paid' and pp.payment_date = v_pay
          and pp.created_by = rb.admin_user_id
          and pp.approved_by = v_priya
          and pp.created_by <> pp.approved_by
          and pp.total_minor > 0
          and not exists (select 1 from jsonb_array_elements_text(v_res -> 'notes') n
                           where n like 'No supplier was paid%');
    detail := coalesce(v_state, format('%s run(s); %s on %s, %s, proposed by %s, approved by %s, total %s; notes %s',
                       v_runs, pp.reference, pp.payment_date, pp.status,
                       case when pp.created_by = rb.admin_user_id then 'the visitor' else coalesce(pp.created_by::text, 'nobody') end,
                       case when pp.approved_by = v_priya then 'the other person' else coalesce(pp.approved_by::text, 'nobody') end,
                       pp.total_minor, v_res -> 'notes'));
    return next;

    -- ── 2. The money moved, and only what was due ───────────────────────────
    v_step := 'reading what the run moved';
    select coalesce(sum(jl.credit_minor - jl.debit_minor) filter (where jl.account_id = v_bank), 0)
      into v_bank_cr
      from erp.journal j
      join erp.journal_line jl on jl.tenant_id = j.tenant_id and jl.journal_id = j.id
     where j.tenant_id = rb.tenant_id and j.source_code = 'payment.made'
       and j.description = format('Supplier payment %s', pp.reference)
       and j.status = 'posted' and j.posting_date = v_pay;
    select coalesce(sum(si.debit_minor - si.credit_minor), 0) into v_paid_dr
      from erp.subledger_item si
      join erp.journal j on j.tenant_id = si.tenant_id and j.id = si.journal_id
     where si.tenant_id = rb.tenant_id and si.control_kind = 'payable'
       and j.source_code = 'payment.made'
       and j.description = format('Supplier payment %s', pp.reference);
    select count(*) into v_bad
      from erp.payment_proposal_line l
     where l.tenant_id = rb.tenant_id and l.payment_proposal_id = pp.id and not l.is_held
       and l.document_id is not null
       and erp.object_current_state('document', l.document_id) <> 'paid';
    v_cases := v_cases + 1;
    case_name := 'the bank account is credited and what is owed to suppliers falls by the run''s total, on the run''s day; the bill that was due is paid, and the bill due a month later is not on the run';
    passed := v_state is null
          and v_bank_cr = pp.total_minor and v_paid_dr = pp.total_minor and v_bad = 0
          and erp.object_current_state('document', v_due) = 'paid'
          and exists (select 1 from erp.payment_proposal_line l
                       where l.tenant_id = rb.tenant_id and l.payment_proposal_id = pp.id
                         and l.document_id = v_due)
          and not exists (select 1 from erp.payment_proposal_line l
                           where l.tenant_id = rb.tenant_id and l.document_id = v_later)
          and erp.object_current_state('document', v_later) <> 'paid'
          and not exists (select 1 from erp.journal j join erp.document x on x.id = j.document_id
                           where j.tenant_id = rb.tenant_id and j.source_code = 'payment.made'
                             and j.posting_date <> coalesce(x.posting_date, x.document_date));
    detail := coalesce(v_state, format('bank %s credited %s, payables down %s, run total %s; %s paid line(s) unsettled; due bill %s, later bill %s',
                       v_bank_code, v_bank_cr, v_paid_dr, pp.total_minor, v_bad,
                       erp.object_current_state('document', v_due), erp.object_current_state('document', v_later)));
    return next;

    -- ── 3. The visitor is themselves again ──────────────────────────────────
    v_step := 'reading who the visitor is';
    v_who := erp.current_principal_id();
    select c.persona_id, c.chosen_at into v_choice
      from erp.demonstration_persona_choice c
     where c.tenant_id = rb.tenant_id and c.app_user_id = rb.admin_user_id;
    v_cases := v_cases + 1;
    case_name := 'afterwards the person building is themselves again, and their own choice under Act as is as they left it';
    passed := v_state is null and v_who = rb.admin_user_id
          and v_choice.persona_id is null and v_choice.chosen_at = v_chosen_at
          and coalesce(current_setting('erp.persona_set_aside', true), '') = '';
    detail := coalesce(v_state, format('acting as %s; choice %s chosen at %s',
                       case when v_who = rb.admin_user_id then 'themselves' else coalesce(v_who::text, 'nobody') end,
                       coalesce(v_choice.persona_id::text, 'nobody'), v_choice.chosen_at));
    return next;

    -- ── 4. The rule is not weakened ─────────────────────────────────────────
    v_step := 'the visitor approving a run they proposed';
    begin
      perform erp.approve_payment_run(erp.propose_payment_run(v_pay, v_ccy, interval '60 days'));
      v_refused := 'approved';
      -- Put back: the run it proposed is not the fixture's.
      raise exception 'CLOVEERP_SUITE_PUT_BACK';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_PUT_BACK' then v_refused := sqlerrm; end if;
    end;
    v_cases := v_cases + 1;
    case_name := 'the person who proposes a run still cannot approve it';
    passed := v_state is null and v_refused like 'CLOVEERP_SEGREGATION_OF_DUTIES%';
    detail := coalesce(v_state, left(v_refused, 200));
    return next;

    -- ── 5. The pay day built again pays nothing more ────────────────────────
    v_step := 'building the pay day again';
    v_res := erp.seed_demo_history(v_pay, v_pay, 1);
    select count(*) into v_runs2 from erp.payment_proposal p where p.tenant_id = rb.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'building the pay day again proposes and pays nothing more';
    passed := v_state is null and v_runs2 = v_runs and (v_res ->> 'built')::integer = 0;
    detail := coalesce(v_state, format('%s run(s) before, %s after; built %s', v_runs, v_runs2, v_res ->> 'built'));
    return next;

    -- ── 6. With nobody else, nothing is paid, and it says so ────────────────
    v_step := 'a bill arriving after the pay day was built';
    v_missed := erp.bill_from_receipt(v_receipts[3], 'SUITE-MISSED', v_pay - 1, v_pay + 3, true);
    v_step := 'paying with the other person away';
    update erp.app_user set status = 'disabled' where tenant_id = rb.tenant_id and id = v_priya;
    v_note := erp.pay_demonstration_suppliers(v_pay, v_pay + 7);
    select count(*) into v_runs2 from erp.payment_proposal p where p.tenant_id = rb.tenant_id;
    update erp.app_user set status = 'active' where tenant_id = rb.tenant_id and id = v_priya;
    v_cases := v_cases + 1;
    case_name := 'with nobody else who may approve, nothing is proposed or paid, and it says why';
    passed := v_state is null and v_runs2 = v_runs
          and coalesce(v_note ->> 'note', '') like 'No supplier was paid on %nobody else who may approve%'
          and erp.object_current_state('document', v_missed) <> 'paid';
    detail := coalesce(v_state, format('%s run(s); %s', v_runs2, coalesce(v_note::text, 'no answer')));
    return next;

    -- ── 7. The catch-up pays what the month end missed ──────────────────────
    v_step := 'catching up to today';
    v_cu := erp.demonstration_catch_up();
    set constraints all immediate;
    select p.* into pp
      from erp.payment_proposal p
      join erp.payment_proposal_line l on l.tenant_id = p.tenant_id and l.payment_proposal_id = p.id
     where p.tenant_id = rb.tenant_id and l.document_id = v_missed and p.status = 'paid'
     limit 1;
    v_cases := v_cases + 1;
    case_name := 'the catch-up pays the bill the month end missed, in a run proposed by the person building and approved by the other person, and names the run';
    passed := v_state is null
          and erp.object_current_state('document', v_missed) = 'paid'
          and pp.created_by = rb.admin_user_id and pp.approved_by = v_priya
          and pp.payment_date between v_pay and current_date
          and (v_cu -> 'supplier_runs_paid') ? pp.reference
          and erp.current_principal_id() = rb.admin_user_id;
    detail := coalesce(v_state, format('missed bill %s; run %s on %s; catch-up paid %s; notes %s',
                       erp.object_current_state('document', v_missed), pp.reference, pp.payment_date,
                       v_cu -> 'supplier_runs_paid', left((v_cu -> 'notes')::text, 300)));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 8. Nothing is left behind ─────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone, and nothing in it stopped early';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'demo-zzpay' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the demonstration rolled back with its runs and its payments');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_DEMONSTRATION_PAYS_SUPPLIERS_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.demonstration_pays_suppliers_suite() from public, anon;

comment on function erp_test.demonstration_pays_suppliers_suite() is
  'A demonstration pays its suppliers (20261006160000, J-142): on the month''s last working day a run proposed by '
  'the person building and approved and paid by the other person, the bank credited and the payables down by its '
  'total, the visitor themselves again, the rule unweakened, nothing paid twice or without a second person, and '
  'the catch-up paying what a month end missed.';

create or replace function erp_test.assert_demonstration_pays_suppliers_suite()
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
    from erp_test.demonstration_pays_suppliers_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_DEMONSTRATION_PAYS_SUPPLIERS_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A demonstration would never pay a supplier, or would pay on one signature. Read the case that failed.';
  end if;
  if v_total <> 8 then
    raise exception 'CLOVEERP_DEMONSTRATION_PAYS_SUPPLIERS_SUITE_SHRANK: % case(s), expected 8', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('demonstration pays suppliers: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_demonstration_pays_suppliers_suite() from public, anon;

comment on function erp_test.assert_demonstration_pays_suppliers_suite() is
  'A demonstration pays its suppliers on two signatures, the second its other person''s (20261006160000).';

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
