-- =============================================================================
-- §9.1's remaining scheduled jobs
--
-- The Starter Content Packs work shipped five of §9.1's eleven and recorded the
-- other six as an open decision, because "nothing in this schema computes a
-- suspense balance, a sequence gap, an approval age or a count schedule, so a
-- handler for any of them would be a function to write rather than a row to
-- add", and registering one against a stub reports success every night over
-- work nobody did.
--
-- Four of the six are written here. Measuring first turned up one thing that
-- changed the shape of this file:
--
--   APPROVAL AGEING AND ESCALATION ALREADY EXISTED.
--   erp.escalate_overdue_approvals() has been in the schema since B4 and
--   nothing ever called it. It needed a handler row, not a function — the same
--   finding as erp.job itself, one layer down.
--
-- The fifth, count schedule generation, is deliberately still absent. It is
-- different in kind from the other four: they read and report, it would WRITE
-- count documents from a programme. A job that creates documents is a
-- different risk and belongs with counting rather than with a batch of
-- reports, and pretending otherwise by putting it in this file would be
-- choosing tidiness over the distinction.
-- =============================================================================

-- ── §8.1's two flags, which the suspense check needs to exist ────────────────
--
-- §8.1 says the 9000–9999 range is "suspense and clearing, each flagged
-- reconciliation-required and close-blocking". There was nowhere to put either
-- flag, so a suspense balance check had nothing to select on: erp.account
-- carries account_type and control_kind, and neither says "this is an account
-- that should be empty at the close".
--
-- Both columns default false, so nothing changes for an existing organisation
-- until it says which of its accounts these are.

alter table erp.account
  add column if not exists reconciliation_required boolean not null default false,
  add column if not exists close_blocking boolean not null default false;

comment on column erp.account.reconciliation_required is
  'Starter Content Packs §8.1. This account holds amounts that are supposed to '
  'clear, so a balance on it is an item of work rather than a position.';

comment on column erp.account.close_blocking is
  '§8.1, and §13''s last clause — "close a period with suspense empty". A '
  'balance here stops the close rather than being noted in it.';

-- ── Suspense balance check ──────────────────────────────────────────────────

create or replace function erp.suspense_balance_report()
returns table (finding text, account_code text, account_name text,
               balance_minor bigint, blocks_close boolean)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  flagged as (
    select a.* from erp.account a, t
     where a.tenant_id = t.tenant_id and a.status = 'active'
       and (a.reconciliation_required or a.close_blocking)
  ),
  balances as (
    select f.code, f.name, f.close_blocking,
           coalesce(sum(jl.base_debit_minor - jl.base_credit_minor), 0)::bigint as bal
      from flagged f
      left join erp.journal_line jl on jl.tenant_id = f.tenant_id and jl.account_id = f.id
      left join erp.journal j on j.tenant_id = jl.tenant_id and j.id = jl.journal_id
                             and j.status = 'posted'
     group by f.code, f.name, f.close_blocking
  )
  select case when b.close_blocking
              then 'a close-blocking account is not empty'
              else 'a reconciliation-required account is not empty' end,
         b.code, b.name, b.bal, b.close_blocking
    from balances b
   where b.bal <> 0

  union all

  -- Nothing flagged is not the same as nothing wrong, and a job that returned
  -- no rows would read as the second. §5 refuses a default-to-suspense, so a
  -- posting never LANDS in suspense by accident — which makes an undeclared
  -- suspense account a gap in the chart rather than a clean bill of health.
  select 'no account is flagged reconciliation-required or close-blocking, so '
         'this check has nothing to look at', null, null, null, null
    from t
   where not exists (
     select 1 from erp.account a
      where a.tenant_id = t.tenant_id and a.status = 'active'
        and (a.reconciliation_required or a.close_blocking))
$$;

comment on function erp.suspense_balance_report is
  'Starter Content Packs §9.1. Accounts an organisation has declared should '
  'clear, that have not. Says so when nothing is declared, because a silent '
  'pass over an unflagged chart is the same output as a clean one.';

-- ── Document sequence gap check ─────────────────────────────────────────────
--
-- A gapless sequence is a statutory requirement in several jurisdictions and a
-- reconciliation aid everywhere. §4.8 puts the statutory-gapless flag on the
-- numbering rule; this is the check that tells you whether the sequence is in
-- fact gapless, which is a different question from whether it was required to
-- be.

create or replace function erp.sequence_gap_report()
returns table (finding text, rule_code text, expected text, issued bigint,
               gaps bigint)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  rule as (
    select nr.* from erp.numbering_rule nr, t
     where nr.tenant_id = t.tenant_id and nr.status = 'active'
       and nr.next_value > 1
  ),
  -- Every number this rule has actually put on a document. The prefix is what
  -- ties a document number back to the rule that issued it, so a rule whose
  -- prefix has changed mid-life reads as a gap — correctly: the old numbers
  -- are no longer attributable to it.
  used as (
    select r.code as rule_code, r.prefix, r.next_value,
           count(d.id) as issued,
           count(distinct substring(d.document_number from '([0-9]+)$')::bigint) as distinct_numbers
      from rule r
      left join erp.document d
        on d.tenant_id = r.tenant_id
       and d.document_number like r.prefix || '%'
       and d.document_number ~ '[0-9]+$'
     group by r.code, r.prefix, r.next_value
  )
  select case
           when u.issued > u.distinct_numbers
             then 'the same number is on more than one document'
           else 'numbers are missing from the issued range'
         end,
         u.rule_code,
         format('%s1..%s%s', u.prefix, u.prefix, u.next_value - 1),
         u.issued,
         (u.next_value - 1) - u.distinct_numbers
    from used u
   where u.distinct_numbers < u.next_value - 1
      or u.issued > u.distinct_numbers
$$;

comment on function erp.sequence_gap_report is
  'Starter Content Packs §9.1. Numbers a rule has issued that no document '
  'carries, and numbers more than one document carries. A cancelled document '
  'keeps its number in this product, so a genuine gap means a number was '
  'consumed and lost.';

-- ── Reservation and staging ageing ──────────────────────────────────────────
--
-- Two thresholds, from two places, on purpose. The allocation side reads the
-- stock.reservation_ageing config type the Starter Content Packs work added;
-- the staging side reads erp.release_area.ageing_hours, which has been on the
-- release area since Addendum B.6 and is per-area — a marshalling area at a
-- gate clears faster than one behind a pick face, and one number for both
-- would be wrong for one of them.

create or replace function erp.reservation_ageing_report()
returns table (finding text, reference text, aged_hours integer,
               threshold_hours integer)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  cfg as (
    select coalesce(
             (erp.config_value('stock.reservation_ageing') ->> 'detailed_allocation_hours')::integer,
             24) as alloc_hours
  )
  select 'a detailed allocation has held stock longer than the policy allows',
         a.id::text,
         (extract(epoch from (now() - a.updated_at)) / 3600)::integer,
         c.alloc_hours
    from t
    cross join cfg c
    join erp.allocation a on a.tenant_id = t.tenant_id
   where a.status = 'committed'
     and a.updated_at < now() - make_interval(hours => c.alloc_hours)

  union all

  select 'stock has been staged in a marshalling area longer than its ageing '
         'threshold allows',
         ra.code,
         (extract(epoch from (now() - sb.updated_at)) / 3600)::integer,
         ra.ageing_hours
    from t
    join erp.release_area ra
      on ra.tenant_id = t.tenant_id and ra.status = 'active'
     and ra.location_id is not null
    join erp.stock_balance sb
      on sb.tenant_id = ra.tenant_id and sb.location_id = ra.location_id
     and sb.quantity > 0
   where sb.updated_at < now() - make_interval(hours => ra.ageing_hours)
$$;

comment on function erp.reservation_ageing_report is
  'Starter Content Packs §9.1. Allocations holding stock past the policy, and '
  'marshalling areas holding it past their own ageing threshold. Both are '
  'stock that is committed to nothing and available to nobody.';

-- ── The handlers ────────────────────────────────────────────────────────────

insert into erp_ref.job_handler
  (code, name_key, description, module_code, sql_function, default_timeout_seconds)
values
  ('finance.suspense_balance', 'job_handler.suspense_balance.name',
   'Accounts declared to clear, that have not.', 'finance',
   'suspense_balance_report', 120),
  ('administration.sequence_gaps', 'job_handler.sequence_gaps.name',
   'Numbers a rule issued that no document carries.', 'administration',
   'sequence_gap_report', 180),
  ('administration.approval_ageing', 'job_handler.approval_ageing.name',
   'Approvals past their band''s escalation window, escalated.', 'administration',
   'escalate_overdue_approvals', 120),
  ('inventory.reservation_ageing', 'job_handler.reservation_ageing.name',
   'Allocations and staged stock held past their thresholds.', 'inventory',
   'reservation_ageing_report', 120)
on conflict (code) do update set
  name_key = excluded.name_key, description = excluded.description,
  module_code = excluded.module_code, sql_function = excluded.sql_function,
  default_timeout_seconds = excluded.default_timeout_seconds;

insert into erp_ref.resource (key, locale, value, description) values
  ('job_handler.suspense_balance.name', 'en', 'Suspense balance check',
   'Starter Content Packs §9.1.'),
  ('job_handler.sequence_gaps.name', 'en', 'Document sequence gap check',
   'Starter Content Packs §9.1.'),
  ('job_handler.approval_ageing.name', 'en', 'Approval ageing and escalation',
   'Starter Content Packs §9.1.'),
  ('job_handler.reservation_ageing.name', 'en', 'Reservation and staging ageing',
   'Starter Content Packs §9.1.')
on conflict (key, locale) do update set value = excluded.value;

-- ── The jobs, on the base pack ──────────────────────────────────────────────
--
-- Shipped disabled like the other five, and slotted into the same daily
-- sequence: reconciliation first, then the things that read what it found.
-- Approval ageing is the exception — it runs hourly, because an escalation
-- that waits until tomorrow morning has already failed the person waiting on
-- it.

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, requires_capability, provenance, seq)
values
  ('base', 'job', 'suspense_balance',
   jsonb_build_object('code','suspense_balance','name','Suspense balance check',
     'handler_code','finance.suspense_balance','schedule_kind','daily',
     'at_time','05:30','timezone','UTC','is_enabled', false),
   null,
   'Starter Content Packs §9.1. After stock-to-ledger at 05:00, because a '
   'difference there is often what put an amount in a clearing account.', 5060),
  ('base', 'job', 'sequence_gaps',
   jsonb_build_object('code','sequence_gaps','name','Document sequence gap check',
     'handler_code','administration.sequence_gaps','schedule_kind','daily',
     'at_time','09:30','timezone','UTC','is_enabled', false),
   null,
   'Starter Content Packs §9.1. Late, because a gap is a finding rather than '
   'something that blocks the day''s work.', 5070),
  ('base', 'job', 'approval_ageing',
   jsonb_build_object('code','approval_ageing','name','Approval ageing and escalation',
     'handler_code','administration.approval_ageing','schedule_kind','interval',
     'interval_seconds', 3600, 'timezone','UTC','is_enabled', false),
   null,
   'Starter Content Packs §9.1. Hourly rather than daily: §3.4''s bands carry '
   'an escalation window in hours, and a job that checked once a day could not '
   'honour one shorter than a day.', 5080),
  ('base', 'job', 'reservation_ageing',
   jsonb_build_object('code','reservation_ageing','name','Reservation and staging ageing',
     'handler_code','inventory.reservation_ageing','schedule_kind','interval',
     'interval_seconds', 3600, 'timezone','UTC','is_enabled', false),
   null,
   'Starter Content Packs §9.1. Hourly, because the base pack''s own default '
   'reservation window is 24 hours and distribution shortens it to 8 — a daily '
   'sweep would miss most of what it is for.', 5090)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, requires_capability = excluded.requires_capability,
  provenance = excluded.provenance, seq = excluded.seq;

-- ── The decision, settled ───────────────────────────────────────────────────

update erp_meta.policy_decision set
  decision =
    'Nine of §9.1''s eleven jobs ship. Count schedule generation is not '
    'shipped and remains open on its own terms.',
  rationale =
    'Four of the six were written: suspense balance, document sequence gaps, '
    'reservation and staging ageing, and — after measuring rather than '
    'assuming — approval ageing, which turned out to need only a handler row '
    'because erp.escalate_overdue_approvals() had been in the schema since B4 '
    'with nothing calling it. Count schedule generation is different in kind '
    'from the other four: they read and report, it would write count documents '
    'from a programme, and a job that creates documents is a different risk '
    'that belongs with counting work.',
  evidence =
    'erp_ref.job_handler holds eleven handlers. §9.1 lists eleven jobs; nine '
    'ship, all disabled. §8.1''s reconciliation_required and close_blocking '
    'flags were added to erp.account so the suspense check had something to '
    'select on, and it reports when nothing is flagged rather than returning '
    'no rows.',
  status = 'accepted', decided_at = now()
 where code = 'unimplemented_scheduled_jobs';

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'count_schedule_generation',
  'Count schedule generation writes rather than reports',
  'Starter Content Packs §9.1',
  'Not shipped. The other ten §9.1 jobs are in the base pack.',
  'Every other scheduled job in this product reads and reports; '
  'erp.run_due_jobs() calls the handler and records what it returned. Count '
  'schedule generation would create count documents from erp.count_programme '
  'on a schedule — a job that writes business documents nobody asked for on '
  'that day, which is a different risk from one that reports. It needs the '
  'counting work''s own attention: which locations, on what cadence, and what '
  'happens when yesterday''s count is still open.',
  'open',
  'erp.count_programme carries kind, selector and tolerances; nothing turns a '
  'programme into a count.')
on conflict (code) do update set
  decision = excluded.decision, rationale = excluded.rationale,
  evidence = excluded.evidence, status = excluded.status;

-- ── Prove it ────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();

select erp.assert_job_handlers_resolvable();
select erp.assert_packs_installable();
select erp.assert_resource_coverage('en');
select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
