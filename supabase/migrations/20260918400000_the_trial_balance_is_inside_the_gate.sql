-- The trial balance is inside the gate, and a tie may not be waived.
--
-- The v1 Definition of Done has one master gate: after a seeded month is
-- posted and the period closed, four ties hold or v1 is not done. The trial
-- balance balances; stock valuation equals the general ledger's inventory
-- control; the receivables ageing equals debtors control; the payables ageing
-- equals creditors control.
--
-- Two things were wrong with that, and this migration fixes both.
--
-- ── One: the trial balance was not in the gate ────────────────────────────────
--
-- erp.assert_whole_database_reconciles() is the gate. It walks every
-- organisation and runs every row of erp_meta.diagnostic_check that is an
-- assertion at tenant scope. Nine such rows; three organisations; twenty-seven
-- of the forty-eight checks the deploy line reports, the rest being the
-- posting-rule and legislation families it drives per rule and per company.
--
-- erp.assert_posted_journals_balance() (20260911005223) does prove that debits
-- equal credits in base currency for every posted journal in every
-- organisation — but it is registered at PLATFORM scope, so it runs once in the
-- structural phase and is not one of the nine. The gate never asked about the
-- ledger at all.
--
-- And per-journal balance is not the claim the Definition of Done makes. A
-- trial balance is drawn per ledger, for a company. erp.journal carries one
-- ledger_id and one entity_id, so lines cannot span two journals — but
-- erp.journal_line names an account, erp.account carries its own entity_id, and
-- NOTHING in the schema requires a line's account to belong to the journal's
-- company or to the company that owns the journal's ledger. So this is possible
-- today, and every existing check passes over it:
--
--     journal in GL (company A):  Dr A.cost_of_sales 2500
--                                 Cr B.revenue       2500
--
-- The journal balances within itself, in transaction currency and in base. The
-- trigger is satisfied. erp.assert_posted_journals_balance() is satisfied. And
-- company A's trial balance is 2500 long while company B's is 2500 short — two
-- wrong sets of accounts, and not one check in the build that says so.
--
-- erp.assert_trial_balance_balances() below makes the claim the Definition of
-- Done actually names: FOR EACH LEDGER AND EACH COMPANY, the debits and the
-- credits of the posted journals are equal, in the ledger's own currency. It is
-- registered at tenant scope, so it joins the per-organisation loop and the
-- reported count goes from forty-eight to fifty-one.
--
-- erp.assert_posted_journals_balance() stays exactly where it is. Per journal
-- and per ledger are different claims and both are worth having: the first
-- says which journal is wrong, the second says that one exists.
--
-- ── Two: a period could close with three ties broken ──────────────────────────
--
-- erp.configure_period_close() ships five close tasks. Three carry a blocking
-- check; grni_reviewed and — remarkably — trial_balance ("Trial balance
-- reviewed and signed") carry none. The trial balance was a manual tick.
--
-- And every blocking check was waivable. erp.complete_close_task() catches the
-- failure and, given any waiver reason at all, records 'FAILED: ' || sqlerrm and
-- marks the task waived; erp.close_period() then accepts waived alongside
-- complete. A period closed with a broken tie provided somebody typed a reason.
--
-- So: the trial balance task gets the assertion above as its blocking check,
-- and the close-task model gets an is_waivable column, true by default so
-- nothing else changes, false for the three tasks that carry the four ties:
--
--     trial_balance        erp.assert_trial_balance_balances()   tie 1
--     inventory_valued     erp.assert_inventory_reconciles()     tie 2
--     subledgers_reconcile erp.assert_subledger_reconciles()     ties 3 and 4
--
-- (The receivables and payables ties are both carried by the subledger
-- reconciliation: it walks every control account against its own detail, which
-- is what "the ageing equals the control" means.)
--
-- Everything else stays waivable, including stock_reconciles, which proves the
-- stock ledger agrees with itself rather than with the general ledger — a
-- precondition of tie 2 rather than tie 2 itself, and inventory_valued's own
-- check has to pass unwaivably whatever happened to it.
--
-- The flag is not written by whoever writes the task. erp.set_close_task_tie()
-- stamps it, on the template and on the raised task, from the task's code and
-- its blocking check — so a checklist promoted by the people being checked
-- cannot shorten itself, and an organisation that has never heard of this
-- migration gets the tie at its next close because the task is stamped as it
-- is raised.
--
-- ── Whether this locks somebody out ───────────────────────────────────────────
--
-- A lock nobody can cut off is worse than a soft refusal if a tie can be broken
-- by something outside the closer's control. It cannot be, here. Every one of
-- the three checks is made true by posting a correcting journal, which needs
-- only an open period somewhere in the organisation — not the period being
-- closed, and not a period in a year that has been closed for good. The
-- refusals name the report that says where the difference is. The escape that
-- already exists — erp.reopen_period() — is untouched, and every close task
-- that is a judgement rather than a tie is still waivable with a reason.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The trial balance, per ledger and per company
-- ═════════════════════════════════════════════════════════════════════════════

-- The population is erp.statement_lines()' population — posted journals, base
-- minor units — because the assertion and the report a person reads have to be
-- talking about the same thing. Grouped by the ledger and by the company whose
-- account the line hit, which is the grain at which a trial balance is drawn
-- and the grain at which the cross-company defect above becomes visible.
create or replace function erp.assert_trial_balance_balances()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_count   integer;
  v_detail  text;
  v_ledgers integer;
begin
  select count(*),
         string_agg(format('  %s / %s (%s): debits %s, credits %s, out by %s',
                           s.ledger_code, s.entity_code, s.currency,
                           s.debit_minor, s.credit_minor,
                           s.debit_minor - s.credit_minor),
                    E'\n' order by s.ledger_code, s.entity_code)
    into v_count, v_detail
    from (
      select lg.code as ledger_code,
             en.code as entity_code,
             lg.currency::text as currency,
             sum(l.base_debit_minor)  as debit_minor,
             sum(l.base_credit_minor) as credit_minor
        from erp.journal_line l
        join erp.journal j on j.tenant_id = l.tenant_id and j.id = l.journal_id
        join erp.ledger lg on lg.tenant_id = j.tenant_id and lg.id = j.ledger_id
        join erp.account a on a.tenant_id = l.tenant_id and a.id = l.account_id
        join erp.entity en on en.tenant_id = a.tenant_id and en.id = a.entity_id
       where l.tenant_id = v_tenant
         and j.status = 'posted'
       group by lg.code, en.code, lg.currency
      having sum(l.base_debit_minor) <> sum(l.base_credit_minor)
    ) s;

  if v_count > 0 then
    raise exception
      E'CLOVEERP_TRIAL_BALANCE_DOES_NOT_BALANCE: % trial balance(s) do not balance\n%',
      v_count, v_detail
      using errcode = '23514',
            hint = 'Open the trial balance for the ledger and the company named, '
                   'find the journal that put one side where the other side is '
                   'not, and post the correction. A ledger that does not balance '
                   'is a wrong set of accounts, not a formality.';
  end if;

  select count(*) into v_ledgers
    from erp.ledger lg where lg.tenant_id = v_tenant and lg.status = 'active';

  return format('trial balance: %s ledger(s), debits equal credits for every company',
                v_ledgers);
end;
$$;

comment on function erp.assert_trial_balance_balances is
  'For every ledger of this organisation and every company whose accounts its '
  'posted journals reach, the debits equal the credits in the ledger''s own '
  'currency. Stronger than erp.assert_posted_journals_balance(): a journal '
  'balances within itself while putting one side on one company''s account and '
  'the other side on another''s, and only a trial balance drawn per company '
  'sees that. Per organisation; the whole-database reconciliation drives it '
  'for every one.';

revoke all on function erp.assert_trial_balance_balances() from public, anon;

-- Registered at tenant scope, which does three things at once: the
-- whole-database reconciliation drives it for every organisation,
-- erp.ci_check_catalogue() leaves it out of the structural phase where it would
-- have no organisation to answer for, and the assurance console can run it.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('trial_balance', 'The trial balance balances', 'assertion', 'tenant', 'erp',
   'assert_trial_balance_balances', '', null, '',
   'For every ledger and every company, the debits and credits of the posted journals are equal in the ledger''s own currency. A journal that balances within itself can still leave one company''s books long and another''s short, and only the trial balance sees that.',
   true, 96)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Which close tasks carry a tie, and what they carry
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.close_task_template
  add column if not exists is_waivable boolean not null default true;

alter table erp.close_task
  add column if not exists is_waivable boolean not null default true;

comment on column erp.close_task_template.is_waivable is
  'False on a task carrying one of the four v1 ties. Stamped by '
  'erp.set_close_task_tie() rather than written by whoever writes the task: a '
  'close checklist the people being checked can shorten is not a control.';

comment on column erp.close_task.is_waivable is
  'False on a task carrying one of the four v1 ties; erp.complete_close_task() '
  'refuses a waiver on it by name.';

-- The task codes that carry a tie, and the check each one carries. Named here
-- once, so the trigger below, the installer and the upgrade all say the same
-- thing and cannot drift apart.
create or replace function erp.close_tie_check(p_task_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case lower(btrim(coalesce(p_task_code, '')))
           when 'trial_balance'        then 'erp.assert_trial_balance_balances()'
           when 'inventory_valued'     then 'erp.assert_inventory_reconciles()'
           when 'subledgers_reconcile' then 'erp.assert_subledger_reconciles()'
         end
$$;

comment on function erp.close_tie_check(text) is
  'The blocking check a close task of this code carries because it is one of '
  'the four v1 ties, or null where the task is not one. Three tasks for four '
  'ties: the subledger reconciliation carries both the debtors and the '
  'creditors tie, because it walks every control account against its detail.';

create or replace function erp.close_check_is_a_tie(p_blocking_check text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(coalesce(p_blocking_check, ''), '\s', '', 'g')) in (
           'erp.assert_trial_balance_balances()',
           'erp.assert_inventory_reconciles()',
           'erp.assert_subledger_reconciles()')
$$;

comment on function erp.close_check_is_a_tie(text) is
  'Whether a close task''s blocking check is one of the four v1 ties, whatever '
  'the task is called. Whitespace and case are ignored, so a check written with '
  'a space in it is still a tie.';

-- The gate lives on the door. A tie task carries its tie's check and is not
-- waivable, whoever wrote the row and by whatever route — the installer, a
-- promoted change set, a hand-written insert, or erp.open_period_close()
-- copying a template into a period. An organisation that has never upgraded
-- gets the tie the moment the task is raised.
create or replace function erp.set_close_task_tie()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_tie text := erp.close_tie_check(new.code);
begin
  if v_tie is not null then
    new.blocking_check := v_tie;
  end if;

  -- An organisation may make something of its own unwaivable; it may not make
  -- a tie waivable.
  new.is_waivable := coalesce(new.is_waivable, true)
                     and not erp.close_check_is_a_tie(new.blocking_check);
  return new;
end;
$$;

comment on function erp.set_close_task_tie() is
  'Stamps a close task with the tie it carries: the check its code implies, and '
  'is_waivable false when that check is one of the four v1 ties. On the '
  'template and on the raised task, before insert and before update.';

drop trigger if exists t_close_task_template_tie on erp.close_task_template;
create trigger t_close_task_template_tie
  before insert or update on erp.close_task_template
  for each row execute function erp.set_close_task_tie();

drop trigger if exists t_close_task_tie on erp.close_task;
create trigger t_close_task_tie
  before insert or update on erp.close_task
  for each row execute function erp.set_close_task_tie();

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The three routines that read it
-- ═════════════════════════════════════════════════════════════════════════════

-- The live bodies, before they are replaced. Two of the three were rewritten
-- after they were written — the refusal-prefix sweep of 20260904980000 rebuilt
-- every routine raising the retired prefix — so the body in the repository is
-- not the body in the database, and a replacement written against the file
-- would quietly drop whatever else had landed since. These needles are read
-- from the catalogue rather than from a file, and the block after the
-- replacements says the refusals survived it.
do $anchors$
declare
  v_open   text := pg_catalog.pg_get_functiondef('erp.open_period_close(uuid)'::regprocedure);
  v_done   text := pg_catalog.pg_get_functiondef('erp.complete_close_task(uuid,text)'::regprocedure);
  v_status text := pg_catalog.pg_get_functiondef('erp.close_status(uuid)'::regprocedure);
begin
  if position('CLOVEERP_NO_CLOSE_TEMPLATE' in v_open) = 0
     or position('erp.close_task_template' in v_open) = 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.open_period_close() is not the body this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and write the replacement against it under a new migration version.';
  end if;

  if position('CLOVEERP_UNKNOWN_CLOSE_TASK' in v_done) = 0
     or position('CLOVEERP_CLOSE_DEPENDENCY_OPEN' in v_done) = 0
     or position('CLOVEERP_CLOSE_CHECK_FAILED' in v_done) = 0
     or position('erp.authorise(''finance.close_period''' in v_done) = 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.complete_close_task() is not the body this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and write the replacement against it under a new migration version.';
  end if;

  if position('check_passes' in v_status) = 0
     or position('blocked_by' in v_status) = 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_UNRECOGNISED: erp.close_status() is not the body this migration replaces'
      using hint = 'Read the live body with pg_get_functiondef and write the replacement against it under a new migration version.';
  end if;
end
$anchors$;

-- Raising the checklist carries the flag through from the template. Same
-- signature and return type as 20260829300000, so the grants stay.
create or replace function erp.open_period_close(p_fiscal_period_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_n      integer;
begin
  perform erp.authorise('finance.close_period', null, null, null,
                        'fiscal_period', p_fiscal_period_id);

  insert into erp.close_task (
    tenant_id, fiscal_period_id, code, name, seq, depends_on, blocking_check,
    is_waivable)
  select v_tenant, p_fiscal_period_id, t.code, t.name, t.seq, t.depends_on,
         t.blocking_check, t.is_waivable
    from erp.close_task_template t
   where t.tenant_id = v_tenant and t.status = 'active'
  on conflict (tenant_id, fiscal_period_id, code) do nothing;

  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception
      'CLOVEERP_NO_CLOSE_TEMPLATE: nothing to do at close, which is not the same '
      'as nothing to check'
      using errcode = '23503',
      hint = 'erp.configure_period_close() installs the tasks.';
  end if;

  update erp.fiscal_period set status = 'closing', updated_at = now()
   where tenant_id = v_tenant and id = p_fiscal_period_id;

  return v_n;
end;
$$;

comment on function erp.open_period_close(uuid) is
  'Raises this period''s close checklist from the organisation''s templates and '
  'puts the period into closing. Each task is raised carrying its blocking '
  'check and whether it may be waived; erp.set_close_task_tie() stamps a tie '
  'task as it lands, so an organisation configured before 20260918400000 gets '
  'the four ties at its next close.';

-- Completing a task. The change is the block marked "a tie is not waived": the
-- waiver route was a single text argument away from closing a period over a
-- difference nobody had looked at.
--
-- Two smaller things go with it. An empty waiver reason now means "complete"
-- rather than "waived with no reason recorded", which is what it always should
-- have meant and is what a form with an untouched optional field sends. And the
-- two older refusals gain the hint that says what to do about them.
--
-- Same signature and return type as 20260829300000, so the grants stay.
create or replace function erp.complete_close_task(
  p_task_id uuid,
  p_waiver_reason text default null
) returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_waiver text;
  t        erp.close_task%rowtype;
  v_open   text;
  v_out    text;
begin
  v_waiver := nullif(btrim(coalesce(p_waiver_reason, '')), '');

  select * into t from erp.close_task
   where tenant_id = v_tenant and id = p_task_id for update;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_CLOSE_TASK: %', p_task_id
      using errcode = '23503',
            hint = 'Open the period''s close again and choose a task from the checklist it shows.';
  end if;

  perform erp.authorise('finance.close_period', null, null, null,
                        'close_task', p_task_id);

  -- Dependencies. Ticking a task whose predecessor is open is how a close is
  -- signed off in an order nobody intended.
  select string_agg(d.code, ', ') into v_open
    from erp.close_task d
   where d.tenant_id = v_tenant and d.fiscal_period_id = t.fiscal_period_id
     and d.code = any (t.depends_on)
     and d.status not in ('complete', 'waived');

  if v_open is not null then
    raise exception 'CLOVEERP_CLOSE_DEPENDENCY_OPEN: % must be finished first', v_open
      using errcode = '23514',
            hint = 'Finish the task named above and come back to this one. The checklist is in the order it is in because each task reads what the one before it settled.';
  end if;

  -- A tie is not waived. Refused before the check runs rather than after,
  -- because the answer does not depend on whether the difference happens to be
  -- zero this minute: these three tasks are the four ties the Definition of
  -- Done names, and a tie is either true or the books are wrong.
  if v_waiver is not null and not t.is_waivable then
    raise exception 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE: % is one of the four ties the accounts are proved by, and is not waived', t.name
      using errcode = '42501',
            hint = format('Run %s, read the difference it names, and post the correction; then complete this task. Everything on the close that is a judgement rather than a tie can still be waived with a reason.',
                          coalesce(t.blocking_check, 'the task''s check'));
  end if;

  -- The blocking check. Run here, not remembered: the whole difference between
  -- a checklist and a control is that this cannot be ticked past.
  if t.blocking_check is not null then
    begin
      execute format('select %s', t.blocking_check) into v_out;
    exception when others then
      if v_waiver is null then
        raise exception
          'CLOVEERP_CLOSE_CHECK_FAILED: % — %', t.blocking_check, sqlerrm
          using errcode = '23514',
                hint = 'Fix the difference the check names, or — where the task '
                       'is not one of the four ties — waive it with a reason '
                       'that will be read at audit.';
      end if;
      v_out := 'FAILED: ' || sqlerrm;
    end;
  end if;

  update erp.close_task
     set status = case when v_waiver is null then 'complete' else 'waived' end,
         completed_at = now(), completed_by = erp.current_principal_id(),
         waiver_reason = v_waiver, check_output = v_out,
         updated_at = now()
   where id = p_task_id;

  return coalesce(v_out, 'complete');
end;
$$;

comment on function erp.complete_close_task(uuid, text) is
  'Marks one close task complete under finance.close_period, running its '
  'blocking check first and refusing to be ticked past a failure. A task '
  'carrying one of the four v1 ties is refused a waiver by name '
  '(CLOVEERP_CLOSE_TIE_NOT_WAIVABLE); everything else is still waived with a '
  'reason that is recorded against the task.';

do $survived$
declare
  v_done text := pg_catalog.pg_get_functiondef('erp.complete_close_task(uuid,text)'::regprocedure);
  v_open text := pg_catalog.pg_get_functiondef('erp.open_period_close(uuid)'::regprocedure);
begin
  if position('CLOVEERP_UNKNOWN_CLOSE_TASK' in v_done) = 0
     or position('CLOVEERP_CLOSE_DEPENDENCY_OPEN' in v_done) = 0
     or position('CLOVEERP_CLOSE_CHECK_FAILED' in v_done) = 0
     or position('CLOVEERP_CLOSE_TIE_NOT_WAIVABLE' in v_done) = 0
     or position('erp.authorise(''finance.close_period''' in v_done) = 0
     or position('CLOVEERP_NO_CLOSE_TEMPLATE' in v_open) = 0 then
    raise exception 'CLOVEERP_CLOSE_BODY_LOST: the replacement dropped a refusal the close carried'
      using hint = 'Compare the needles above with pg_get_functiondef() of the two routines.';
  end if;
end
$survived$;

-- The close screen says which tasks cannot be waived before anybody tries one.
-- A returns-table function cannot change shape through create or replace, so it
-- is dropped and re-created; public.erp_close_status() is to_jsonb() over it
-- and carries the new key without being touched, and erp.apply_execute_grants()
-- at the foot of this migration puts the grant back.
drop function if exists erp.close_status(uuid);

create function erp.close_status(p_fiscal_period_id uuid)
returns table (code text, name text, seq integer, status text,
               blocking_check text, is_waivable boolean, blocked_by text,
               check_passes boolean)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  t        record;
  v_out    text;
begin
  for t in
    select * from erp.close_task ct
     where ct.tenant_id = v_tenant and ct.fiscal_period_id = p_fiscal_period_id
     order by ct.seq, ct.code
  loop
    code := t.code; name := t.name; seq := t.seq; status := t.status;
    blocking_check := t.blocking_check; is_waivable := t.is_waivable;

    select string_agg(d.code, ', ') into blocked_by
      from erp.close_task d
     where d.tenant_id = v_tenant and d.fiscal_period_id = p_fiscal_period_id
       and d.code = any (t.depends_on)
       and d.status not in ('complete', 'waived');

    -- Shown before it is needed, so a close can be worked rather than
    -- discovered one refusal at a time.
    if t.blocking_check is null then
      check_passes := null;
    else
      begin
        execute format('select %s', t.blocking_check) into v_out;
        check_passes := true;
      exception when others then check_passes := false;
      end;
    end if;

    return next;
  end loop;
end;
$$;

comment on function erp.close_status(uuid) is
  'Spec 5.7: the close, worked rather than discovered. Every task with its '
  'dependencies, whether its blocking check would pass right now, and whether '
  'it may be waived at all — so the three tasks carrying the four ties are '
  'visible as unwaivable before anybody types a reason into one.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The refusal names the real next action
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_CLOSE_TIE_NOT_WAIVABLE',
  'Waiving a close task that carries one of the four ties the accounts are proved by.',
  'The trial balance, the inventory valuation against its control account and the subledgers against theirs are not opinions about the month: each is either true or the accounts are wrong. A period closed over one of them is a set of books that says something nobody checked.',
  'Post the correction. Run the check the task names — it says which ledger, company or control account is out and by how much — put the difference right, and complete the task. A close task that is a judgement rather than a tie can still be waived with a reason.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The checklist the product ships
-- ═════════════════════════════════════════════════════════════════════════════

-- trial_balance gains the blocking check it never had. The waivability of the
-- three tie tasks is not written into the payload: erp.set_close_task_tie()
-- stamps it as the item lands, so a promoted change set that leaves it out or
-- sets it true still produces an unwaivable task.
create or replace function erp.configure_period_close()
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_cs     uuid;
begin
  v_cs := erp.install_module_config(
    'period-close', 'Period close',
    'What has to be true before a period is closed, in the order it has to '
    'become true, with the checks that cannot be ticked past.',
    jsonb_build_array(
      jsonb_build_object('kind','close_task','key','stock_reconciles','payload',
        jsonb_build_object(
          'code','stock_reconciles','name','Stock ledger reconciles',
          'seq',10, 'blocking_check','erp.assert_stock_reconciles()')),
      jsonb_build_object('kind','close_task','key','inventory_valued','payload',
        jsonb_build_object(
          'code','inventory_valued','name','Inventory valuation agrees with the ledger',
          'seq',20, 'depends_on', jsonb_build_array('stock_reconciles'),
          'blocking_check','erp.assert_inventory_reconciles()')),
      jsonb_build_object('kind','close_task','key','subledgers_reconcile','payload',
        jsonb_build_object(
          'code','subledgers_reconcile','name','Subledgers agree with their control accounts',
          'seq',30, 'blocking_check','erp.assert_subledger_reconciles()')),
      jsonb_build_object('kind','close_task','key','grni_reviewed','payload',
        jsonb_build_object(
          'code','grni_reviewed','name','Goods received not invoiced reviewed',
          'seq',40, 'depends_on', jsonb_build_array('subledgers_reconcile'))),
      jsonb_build_object('kind','close_task','key','trial_balance','payload',
        jsonb_build_object(
          'code','trial_balance','name','Trial balance reviewed and signed',
          'seq',90,
          'depends_on', jsonb_build_array('inventory_valued','subledgers_reconcile','grni_reviewed'),
          'blocking_check','erp.assert_trial_balance_balances()'))));

  return v_cs;
end;
$$;

comment on function erp.configure_period_close() is
  'The five close tasks the product ships, as one promoted change set. Three of '
  'them carry the four v1 ties and are stamped unwaivable as they land: the '
  'trial balance (20260918400000), the inventory valuation against its control '
  'account, and the subledgers against theirs.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. And the organisations already configured get it
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Not through erp_ref.module_upgrade_item. erp.plan_module_upgrade() decides
-- whether an organisation already holds a non-posting-rule item by containment
-- in erp.configuration_manifest(), and the manifest does not carry close_task —
-- so an upgrade item of that kind would come back as missing on every plan, for
-- ever, on an organisation that already had it. Adding close_task to the
-- manifest is a change to what every promotion, diff, snapshot and pack
-- acceptance compares, which is not a thing to do sideways inside this
-- migration.
--
-- So the register records the version and the sweep below does the work, once,
-- for every organisation that holds the checklist. It is complete: after it
-- there is no organisation at version 1, so nothing is left to plan.

update erp_ref.module_installer
   set current_version = 2,
       description = 'Close tasks and the calendar. Version 2 (20260918400000) '
                     'gives the trial balance task the assertion that proves it, '
                     'and makes the three tasks carrying the four v1 ties '
                     'unwaivable.'
 where install_code = 'period-close';

-- The templates. The trigger would stamp these anyway on any update, and the
-- values are set here as well so the sweep says in the migration what it did
-- rather than leaving it to be inferred from a trigger.
update erp.close_task_template t
   set blocking_check = erp.close_tie_check(t.code),
       is_waivable    = false,
       updated_at     = now()
 where erp.close_tie_check(t.code) is not null;

update erp.close_task_template t
   set is_waivable = false,
       updated_at  = now()
 where erp.close_check_is_a_tie(t.blocking_check)
   and t.is_waivable;

-- The tasks already raised into a period that has not shut. A period that is
-- closed or closed for good is history and is left alone.
update erp.close_task ct
   set blocking_check = coalesce(erp.close_tie_check(ct.code), ct.blocking_check),
       is_waivable    = false,
       updated_at     = now()
  from erp.fiscal_period fp
 where fp.tenant_id = ct.tenant_id
   and fp.id = ct.fiscal_period_id
   and fp.status in ('future', 'open', 'closing')
   and (erp.close_tie_check(ct.code) is not null
        or erp.close_check_is_a_tie(ct.blocking_check));

-- A tie already waived in a period still open goes back to the checklist. It is
-- the one place this migration takes something away from somebody mid-task, and
-- it is the point: the waiver was the defect. A tie already COMPLETED is left
-- alone — its check actually ran and passed.
update erp.close_task ct
   set status        = 'open',
       completed_at  = null,
       completed_by  = null,
       waiver_reason = null,
       check_output  = null,
       updated_at    = now()
  from erp.fiscal_period fp
 where fp.tenant_id = ct.tenant_id
   and fp.id = ct.fiscal_period_id
   and fp.status in ('future', 'open', 'closing')
   and ct.status = 'waived'
   and not ct.is_waivable;

update erp.module_installation i
   set installer_version = 2,
       upgraded_at       = now(),
       updated_at        = now()
 where i.install_code = 'period-close'
   and i.installer_version < 2;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite that counted the checks
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp_test.finance_depth_suite() has counted the close tasks whose blocking
-- check would pass right now since 20260829300000, and the answer was three
-- because the trial balance had no check. It is four now. The case is restated
-- with the reason rather than the count being loosened: it is still the claim
-- that the close can be worked rather than discovered one refusal at a time.
--
-- The suite lives in a migration that was written once, and it has been patched
-- twice since (20260914062000), so the patch is written against the live body
-- and not against the file.

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_old text := $p$      where cs.check_passes is not null) = 3,
    'every task shows whether its check would pass right now';$p$;
  v_new text := $q$      where cs.check_passes is not null) = 4,
    'every task shows whether its check would pass right now, the trial balance among them since 20260918400000';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_depth_suite() does not count the close checks where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

do $patch$
declare
  v_def text := pg_get_functiondef('erp_test.finance_depth_suite()'::regprocedure);
  v_old text := $p$    'five tasks, three of them with a check that cannot be ticked past';$p$;
  v_new text := $q$    'five tasks, four of them with a check that cannot be ticked past, and three of those a tie that is not waived at all';$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp_test.finance_depth_suite() does not describe the close checklist where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.trial_balance_tie_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 13;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  rb       record;
  v_step   text := 'provisioning';
  v_state  text;
  v_a uuid; v_b uuid; v_gl uuid; v_period uuid;
  v_rev text; v_cos text;
  v_a_rev uuid; v_a_cos uuid; v_b_rev uuid; v_b_cos uuid;
  v_j uuid;
  v_tb text; v_pj text; v_tb2 text;
  v_tmpl record;
  v_raised integer;
  v_task_stock uuid; v_task_inv uuid; v_task_sub uuid;
  v_task_grni uuid; v_task_tb uuid;
  v_tie_refusal text; v_tie_hint text;
  v_waived text;
  v_failed text; v_notclose text;
  v_status record;
  v_catalogued integer; v_registered integer;
  v_next text;
begin
  begin
    -- ── The fixture: one organisation, two companies, one general ledger ──
    v_step := 'an organisation with finance and the close checklist';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zztbt-' || v_tag, 'Trial Balance Tie Suite',
      'admin@zztbt-' || v_tag || '.test', 'Trial Balance Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zztbt-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.configure_finance();
    perform erp.configure_period_close();

    v_step := 'a second company on the same organisation';
    select e.id into v_a from erp.entity e where e.tenant_id = rb.tenant_id order by e.code limit 1;
    v_b := erp.create_entity('ZZTB-B', 'Zz Tie Sub', 'Zz Tie Sub Ltd', 'GBP', 'GB',
                             'en-GB', 'en-GB', 1::smallint);
    perform erp.configure_finance(null, 'GBP', v_b);

    select l.id into v_gl from erp.ledger l
     where l.tenant_id = rb.tenant_id and l.entity_id = v_a and l.code = 'GL';
    select fp.id into v_period from erp.fiscal_period fp
     where fp.tenant_id = rb.tenant_id and fp.ledger_id = v_gl
       and current_date between fp.starts_on and fp.ends_on;

    v_rev := erp.tenant_account_code('revenue');
    v_cos := erp.tenant_account_code('cost_of_sales');
    select a.id into v_a_rev from erp.account a where a.tenant_id = rb.tenant_id and a.entity_id = v_a and a.code = v_rev;
    select a.id into v_a_cos from erp.account a where a.tenant_id = rb.tenant_id and a.entity_id = v_a and a.code = v_cos;
    select a.id into v_b_rev from erp.account a where a.tenant_id = rb.tenant_id and a.entity_id = v_b and a.code = v_rev;
    select a.id into v_b_cos from erp.account a where a.tenant_id = rb.tenant_id and a.entity_id = v_b and a.code = v_cos;

    -- ── 1. A balanced month ────────────────────────────────────────────────
    v_step := 'a balanced month posted into the general ledger';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (rb.tenant_id, v_a, v_gl, 'manual', current_date, 'the month, as it should be',
            'draft', 'suite: a balanced month')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (rb.tenant_id, v_j, 1, v_a_cos, 10000, 0, 'GBP', 10000, 0, 1),
           (rb.tenant_id, v_j, 2, v_a_rev, 0, 10000, 'GBP', 0, 10000, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tb := erp.assert_trial_balance_balances();

    v_cases := v_cases + 1;
    case_name := 'a balanced month posted, the trial balance balances for every ledger and every company';
    passed := v_state is null and v_tb like 'trial balance:%debits equal credits%';
    detail := coalesce(v_state, v_tb, 'no answer');
    return next;

    -- ── 2. The falsification ───────────────────────────────────────────────
    --
    -- One journal, balanced within itself in both currencies, with one side on
    -- one company's account and the other on the other's. Every check that
    -- existed before today passes over it.
    v_step := 'a journal whose two sides belong to two companies';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (rb.tenant_id, v_a, v_gl, 'manual', current_date, 'one side in the wrong company',
            'draft', 'suite: the falsification')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (rb.tenant_id, v_j, 1, v_a_cos, 2500, 0, 'GBP', 2500, 0, 1),
           (rb.tenant_id, v_j, 2, v_b_rev, 0, 2500, 'GBP', 0, 2500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    begin
      v_pj := 'passed: ' || erp.assert_posted_journals_balance();
    exception when others then
      v_pj := 'refused: ' || left(sqlerrm, 160);
    end;
    begin
      v_tb := 'passed: ' || erp.assert_trial_balance_balances();
    exception when others then
      v_tb := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'a journal that balances within itself still breaks a company''s trial balance, and the per-journal check cannot see it';
    passed := v_state is null
          and v_pj like 'passed:%'
          and v_tb like 'CLOVEERP_TRIAL_BALANCE_DOES_NOT_BALANCE:%2 trial balance(s)%'
          and v_tb like '%out by 2500%'
          and v_tb like '%out by -2500%';
    detail := coalesce(v_state, format('per journal %s; per ledger and company %s',
                                       left(v_pj, 60), left(v_tb, 220)), 'no answer');
    return next;

    -- ── 3. The close will not let it through ───────────────────────────────
    v_step := 'the close checklist raised on the period';
    v_raised := erp.open_period_close(v_period);
    select t.id into v_task_stock from erp.close_task t where t.fiscal_period_id = v_period and t.code = 'stock_reconciles';
    select t.id into v_task_inv   from erp.close_task t where t.fiscal_period_id = v_period and t.code = 'inventory_valued';
    select t.id into v_task_sub   from erp.close_task t where t.fiscal_period_id = v_period and t.code = 'subledgers_reconcile';
    select t.id into v_task_grni  from erp.close_task t where t.fiscal_period_id = v_period and t.code = 'grni_reviewed';
    select t.id into v_task_tb    from erp.close_task t where t.fiscal_period_id = v_period and t.code = 'trial_balance';

    select ct.code, ct.blocking_check, ct.is_waivable into v_tmpl
      from erp.close_task_template ct
     where ct.tenant_id = rb.tenant_id and ct.code = 'trial_balance';

    v_cases := v_cases + 1;
    case_name := 'the close the product ships gives the trial balance the assertion that proves it';
    passed := v_state is null
          and v_tmpl.blocking_check = 'erp.assert_trial_balance_balances()'
          and v_tmpl.is_waivable is false
          and v_raised = 5;
    detail := coalesce(v_state, format('template %s: %s, waivable %s; %s tasks raised',
                                       v_tmpl.code, v_tmpl.blocking_check,
                                       v_tmpl.is_waivable, v_raised), 'no answer');
    return next;

    v_cases := v_cases + 1;
    case_name := 'three tasks carry the four ties and are unwaivable; everything else on the close still is';
    passed := v_state is null
          and (select count(*) from erp.close_task t
                where t.fiscal_period_id = v_period and not t.is_waivable) = 3
          and (select bool_and(not t.is_waivable) from erp.close_task t
                where t.fiscal_period_id = v_period
                  and t.code in ('trial_balance', 'inventory_valued', 'subledgers_reconcile'))
          and (select bool_and(t.is_waivable) from erp.close_task t
                where t.fiscal_period_id = v_period
                  and t.code in ('stock_reconciles', 'grni_reviewed'));
    detail := coalesce(v_state,
      (select string_agg(format('%s %s', t.code, case when t.is_waivable then 'waivable' else 'tied' end),
                         ', ' order by t.seq)
         from erp.close_task t where t.fiscal_period_id = v_period), 'no answer');
    return next;

    v_step := 'the close screen before anybody tries a waiver';
    select cs.is_waivable, cs.check_passes into v_status
      from erp.close_status(v_period) cs where cs.code = 'trial_balance';

    v_cases := v_cases + 1;
    case_name := 'the close screen says a tie cannot be waived, and that its check would not pass right now';
    passed := v_state is null
          and v_status.is_waivable is false
          and v_status.check_passes is false;
    detail := coalesce(v_state, format('trial balance: waivable %s, check passes %s',
                                       v_status.is_waivable, v_status.check_passes), 'no answer');
    return next;

    -- A task that is not a tie: waived with a reason, exactly as before.
    v_step := 'a task that is not a tie is waived';
    perform erp.complete_close_task(v_task_stock, 'The stock ledger was reviewed against the count sheets by hand');
    select t.status || ' — ' || coalesce(t.waiver_reason, 'no reason') into v_waived
      from erp.close_task t where t.id = v_task_stock;

    v_cases := v_cases + 1;
    case_name := 'a close task that is not one of the four ties is still waived with a reason';
    passed := v_state is null and v_waived like 'waived — The stock ledger was reviewed%';
    detail := coalesce(v_state, v_waived, 'no answer');
    return next;

    -- A tie whose check passes: still not waivable. The lock is on the task,
    -- not on whether the difference happens to be zero.
    v_step := 'a tie whose check passes is refused a waiver anyway';
    begin
      perform erp.complete_close_task(v_task_sub, 'Agreed with the ageing outside the system');
      v_tie_refusal := 'the waiver went through';
      v_tie_hint := '';
    exception when others then
      v_tie_refusal := sqlerrm;
      get stacked diagnostics v_tie_hint = pg_exception_hint;
    end;

    v_cases := v_cases + 1;
    case_name := 'a tie is refused a waiver by name, and the refusal names the check to run and the correction to post';
    passed := v_state is null
          and v_tie_refusal like 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE:%Subledgers agree with their control accounts%'
          and v_tie_hint like '%erp.assert_subledger_reconciles()%'
          and v_tie_hint like '%post the correction%'
          and (select t.status from erp.close_task t where t.id = v_task_sub) = 'open';
    detail := coalesce(v_state, left(v_tie_refusal || ' / ' || v_tie_hint, 260), 'no answer');
    return next;

    -- The two ties whose checks do pass are completed properly.
    v_step := 'the ties that hold are completed';
    perform erp.complete_close_task(v_task_inv);
    perform erp.complete_close_task(v_task_sub);
    perform erp.complete_close_task(v_task_grni);

    v_step := 'the broken tie refuses to be ticked and the period refuses to close';
    begin
      perform erp.complete_close_task(v_task_tb);
      v_failed := 'the tie was ticked over a difference';
    exception when others then
      v_failed := sqlerrm;
    end;
    begin
      perform erp.complete_close_task(v_task_tb, 'Signed by the finance manager on the printed copy');
      v_tie_refusal := 'the waiver went through';
    exception when others then
      v_tie_refusal := sqlerrm;
    end;
    begin
      perform erp.close_period(v_period);
      v_notclose := 'the period closed with a broken tie';
    exception when others then
      v_notclose := sqlerrm;
    end;

    v_cases := v_cases + 1;
    case_name := 'while the trial balance is out the tie will not be ticked, will not be waived, and the period will not close';
    passed := v_state is null
          and v_failed like 'CLOVEERP_CLOSE_CHECK_FAILED: erp.assert_trial_balance_balances()%CLOVEERP_TRIAL_BALANCE_DOES_NOT_BALANCE%'
          and v_tie_refusal like 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE:%'
          and v_notclose like 'CLOVEERP_CLOSE_TASKS_OPEN:%Trial balance reviewed and signed%'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_period) = 'closing';
    detail := coalesce(v_state, left(format('tick: %s; waive: %s; close: %s',
                                            left(v_failed, 90), left(v_tie_refusal, 70),
                                            left(v_notclose, 90)), 300), 'no answer');
    return next;

    -- ── 4. The falsification undone ────────────────────────────────────────
    v_step := 'the correction posted';
    insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                             description, status, manual_reason)
    values (rb.tenant_id, v_a, v_gl, 'manual', current_date, 'the correction',
            'draft', 'suite: putting the two companies back')
    returning id into v_j;
    insert into erp.journal_line (tenant_id, journal_id, line_no, account_id, debit_minor,
                                  credit_minor, currency, base_debit_minor, base_credit_minor, exchange_rate)
    values (rb.tenant_id, v_j, 1, v_b_cos, 2500, 0, 'GBP', 2500, 0, 1),
           (rb.tenant_id, v_j, 2, v_a_rev, 0, 2500, 'GBP', 0, 2500, 1);
    update erp.journal set status = 'posted', posted_at = now(),
                           posted_by = erp.current_principal_id() where id = v_j;

    v_tb2 := erp.assert_trial_balance_balances();

    v_cases := v_cases + 1;
    case_name := 'the correction posted, the trial balance balances again';
    passed := v_state is null and v_tb2 like 'trial balance:%debits equal credits%';
    detail := coalesce(v_state, v_tb2, 'no answer');
    return next;

    v_step := 'the tie completes and the period closes';
    perform erp.complete_close_task(v_task_tb);
    perform erp.close_period(v_period);

    v_cases := v_cases + 1;
    case_name := 'once the difference is corrected the tie completes and the period closes';
    passed := v_state is null
          and (select t.status from erp.close_task t where t.id = v_task_tb) = 'complete'
          and (select fp.status::text from erp.fiscal_period fp where fp.id = v_period) = 'closed';
    detail := coalesce(v_state,
      format('trial balance %s, period %s',
             (select t.status from erp.close_task t where t.id = v_task_tb),
             (select fp.status::text from erp.fiscal_period fp where fp.id = v_period)), 'no answer');
    return next;

    -- ── 5. The registers ───────────────────────────────────────────────────
    v_step := 'the registers that drive it';
    select count(*) into v_registered
      from erp_meta.diagnostic_check d
     where d.code = 'trial_balance' and d.kind = 'assertion' and d.scope = 'tenant'
       and d.schema_name = 'erp' and d.function_name = 'assert_trial_balance_balances'
       and d.runs_in_ci;
    select count(*) into v_catalogued
      from erp.ci_check_catalogue() c
     where c.qualified_name = 'erp.assert_trial_balance_balances';

    v_cases := v_cases + 1;
    case_name := 'the register drives the trial balance for every organisation, and the structural phase does not run it without one';
    passed := v_state is null and v_registered = 1 and v_catalogued = 0
          and (select count(*) from erp_meta.diagnostic_check d
                where d.kind = 'assertion' and d.scope = 'tenant'
                  and d.function_name <> 'assert_whole_database_reconciles') = 10;
    detail := coalesce(v_state, format('%s register row, %s catalogue rows, %s tenant assertions in the loop',
      v_registered, v_catalogued,
      (select count(*) from erp_meta.diagnostic_check d
        where d.kind = 'assertion' and d.scope = 'tenant'
          and d.function_name <> 'assert_whole_database_reconciles')), 'no answer');
    return next;

    select f.next_action into v_next from erp_ref.refusal f
     where f.code = 'CLOVEERP_CLOSE_TIE_NOT_WAIVABLE';

    v_cases := v_cases + 1;
    case_name := 'the refusal is registered and says to post the correction rather than to try again';
    passed := v_state is null
          and v_next like '%Post the correction%'
          and exists (select 1 from erp_ref.resource r
                       where r.locale = 'en'
                         and r.key = erp_ref.refusal_key('CLOVEERP_CLOSE_TIE_NOT_WAIVABLE', 'next_action'));
    detail := coalesce(v_state, left(coalesce(v_next, 'nothing registered'), 200), 'no answer');
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
        and not exists (select 1 from erp.tenant t where t.code = 'zztbt-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zztbt rolled back with its two companies, its ledgers and its journals');
  return next;

  -- The count guard says what stopped the fixture. Without this the wrapper
  -- never sees a row and the message this suite caught into v_state — and the
  -- step that produced it — never reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_TRIAL_BALANCE_TIE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.trial_balance_tie_suite() from public, anon;

comment on function erp_test.trial_balance_tie_suite() is
  'The trial balance tie, proved and falsified: a balanced month passes; a '
  'journal split across two companies balances within itself, passes the '
  'per-journal check and is refused by the trial balance naming both companies '
  'and the difference; the correction makes it true again. And the close: a tie '
  'is refused a waiver by name whether its check passes or fails, a task that '
  'is not a tie is still waived with a reason, and the period will not close '
  'while a tie is broken but does once it is fixed. Rolls back everything it '
  'made.';

create or replace function erp_test.assert_trial_balance_tie_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 13;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _trial_balance_tie on commit drop as
    select * from erp_test.trial_balance_tie_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _trial_balance_tie;
  drop table _trial_balance_tie;
  if v_fail > 0 then
    raise exception E'CLOVEERP_TRIAL_BALANCE_TIE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_TRIAL_BALANCE_TIE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the trial balance is inside the gate: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_trial_balance_tie_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

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
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_invoker_doors_executable();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_session_context_hygiene();
-- erp.close_status(uuid) is one of Part 5's named artefacts, and it was dropped
-- and re-created above under the same signature; this says the register still
-- finds it.
select erp.assert_part5_coverage();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_finance_depth_sane();
select erp.assert_posted_journals_balance();

select erp_test.assert_trial_balance_tie_suite();
-- The suite whose close-check count this migration restated, run here so the
-- patch and the proof that it landed are in one transaction.
select erp_test.assert_finance_depth_suite();
-- The suite that closes a period by waiving a task. It waives 'Suite journals
-- reviewed', a task of its own making with no blocking check, so the new rule
-- does not touch it — but a close that used to go through a waiver is exactly
-- the thing this migration changed, and it is proved here rather than left to
-- the catalogue.
select erp_test.assert_journal_and_close_suite();
