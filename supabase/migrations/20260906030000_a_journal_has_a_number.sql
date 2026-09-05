-- A journal has a number.
--
-- erp.journal.journal_number has been nullable, defaultless and unassigned
-- since 0026. Eight routines insert journals; six of them never set it, and
-- the two that do (opening balances) write the migration batch code. Every
-- posting the product has ever made — 1,623 of them on the live
-- demonstration — is a journal with no number. A ledger whose journals cannot
-- be cited by number cannot support a statutory audit, and §6.4 is explicit
-- about what a statutory number is: allocated on commit, never on attempt;
-- never reused; per period where the legislation asks; declared gapless or
-- merely unique, and the declaration honoured.
--
-- What this builds:
--
--   * erp.numbering_series — the counter, one row per (series, period). The
--     numbering rule's next_value and current_period were one counter that
--     could only count the present: a journal dated last year would have
--     rewound it. A series per period is what "per-period series" means.
--     erp.allocate_number() is the one allocator, an upsert that takes the
--     row lock, so two allocations in the same period serialise and a
--     rolled-back one leaves nothing behind.
--
--   * erp.next_document_number() keeps its signature and its behaviour
--     (documents are numbered on creation, unique, not gapless) but allocates
--     from the series and mirrors the rule's counter for what reads it. A
--     rule declared is_gapless refuses this eager path: a gapless number is
--     allocated when the document is issued, at commit, which is Phase 4c's
--     work for invoices. Declaring is not the same as honouring, and this
--     refusal is the difference.
--
--   * Journals are numbered by a DEFERRABLE INITIALLY DEFERRED constraint
--     trigger when their status reaches posted: at commit, from the ledger's
--     series, in the period of the posting date. A rolled-back posting never
--     consumed a number. The ledger declares its own prefix, reset and
--     whether it is gapless (erp.ledger.journal_prefix, journal_reset,
--     journal_gapless), with defaults that need no row written on live —
--     which matters, because ledger rows exist on a live organisation and
--     configuration on a live organisation is not edited in place.
--
--   * The 1,623 live journals are numbered here, per ledger, in posting-date
--     order, from the same allocator. erp.check_period_open() learns that a
--     journal acquiring its number is not a journal being re-posted.
--
--   * erp.numbering_rule.is_gapless travels through promotion:
--     erp.upsert_numbering_rule() gains the argument, the promoter branch
--     passes it, the manifest carries it, each patched from the deployed body.
--     erp_ref.legislation_pack.requires_gapless is where a jurisdiction says
--     so; the packs that use it arrive with Phase 4c.
--
--   * erp.sequence_gap_report() — the body of the administration.sequence_gaps
--     job — reads the series rather than the rule's mirror, and reads journal
--     numbers as well as document numbers. erp.assert_journals_numbered()
--     refuses a posted journal without a number and a gap on anything
--     declared gapless; it is per organisation, so the whole-database
--     reconciliation drives it for every organisation at the end of the build.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The series
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp.numbering_series (
  tenant_id   uuid   not null references erp.tenant(id) on delete cascade,
  series_key  text   not null,   -- 'rule:<numbering_rule id>' or 'ledger:<ledger id>'
  period      text   not null,   -- '' for never, YYYY, YYYYMM or YYYYMMDD
  next_value  bigint not null check (next_value >= 1),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (tenant_id, series_key, period)
);

comment on table erp.numbering_series is
  'One counter per sequence and period. State, not configuration: the rule or '
  'ledger says how numbers look, the series says how many have been issued. '
  'erp.allocate_number() is its only writer.';

select erp_meta.register_table('erp', 'numbering_series', 'tenant_scoped',
  'Per-period counters behind document and journal numbers.');

-- Every allocation is an update; auditing them would record each number twice,
-- once here and once on the document or journal that carries it.
insert into erp_meta.audit_exemption (schema_name, table_name, rationale) values
  ('erp', 'numbering_series',
   'Counter state written on every allocation. The number itself is audited on the '
   'document or journal that carries it, which is the record a person reads.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

create or replace function erp.number_period(p_reset erp.number_reset, p_on date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_reset
    when 'never'   then ''
    when 'yearly'  then to_char(p_on, 'YYYY')
    when 'monthly' then to_char(p_on, 'YYYYMM')
    when 'daily'   then to_char(p_on, 'YYYYMMDD')
  end
$$;

create or replace function erp.allocate_number(
  p_series_key text, p_prefix text, p_suffix text, p_pad_to smallint,
  p_reset erp.number_reset, p_on date, p_seed bigint default 1)
returns table(number text, period text, value bigint)
language plpgsql
volatile
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tenant uuid := erp.require_tenant_id();
  v_period text := erp.number_period(p_reset, p_on);
  v_value  bigint;
begin
  -- The upsert takes the row lock. Two allocations in one period serialise on
  -- it; a transaction that rolls back releases it having issued nothing.
  insert into erp.numbering_series (tenant_id, series_key, period, next_value)
  values (v_tenant, p_series_key, v_period, greatest(coalesce(p_seed, 1), 1) + 1)
  on conflict (tenant_id, series_key, period)
    do update set next_value = erp.numbering_series.next_value + 1, updated_at = now()
  returning erp.numbering_series.next_value - 1 into v_value;

  number := coalesce(p_prefix, '')
         || case when v_period = '' then '' else v_period || '-' end
         || lpad(v_value::text, p_pad_to, '0')
         || coalesce(p_suffix, '');
  period := v_period;
  value  := v_value;
  return next;
end;
$$;

comment on function erp.allocate_number is
  'The one allocator. Issues the next value of a series in the period the date '
  'falls in, seeding a new period from p_seed. Locks the counter row until '
  'commit, so a rolled-back caller leaves no gap and concurrent callers serialise.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Documents: the same numbers, from the series
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.numbering_rule add column if not exists is_gapless boolean not null default false;

comment on column erp.numbering_rule.is_gapless is
  '§6.4: whether this sequence is statutorily gapless. A gapless number is '
  'allocated on commit, when the document is issued, never on creation; '
  'erp.next_document_number() refuses a gapless rule for that reason.';

-- Before replacing the eager allocator, be sure it is the one we read.
do $check$
declare v_src text := (select prosrc from pg_catalog.pg_proc where oid = 'erp.next_document_number(uuid)'::regprocedure);
begin
  if (select count(*) from regexp_matches(v_src, 'to_char\(current_date, ''YYYYMMDD''\)', 'g')) <> 1
     or (select count(*) from regexp_matches(v_src, 'set next_value = r\.next_value \+ 1', 'g')) <> 1
     or position('NUMBERING_RULE_NOT_FOUND' in v_src) = 0 then
    raise exception 'CLOVEERP_NUMBER_ALLOCATOR_UNRECOGNISED: erp.next_document_number(uuid) is not the body this migration replaces';
  end if;
end
$check$;

create or replace function erp.next_document_number(p_numbering_rule_id uuid)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        erp.numbering_rule%rowtype;
  v_period text;
  a        record;
begin
  -- Locked, as before: the rule row is the mirror everything else reads.
  select * into r from erp.numbering_rule
   where tenant_id = v_tenant and id = p_numbering_rule_id for update;

  if not found then
    raise exception 'CLOVEERP_NUMBERING_RULE_NOT_FOUND: %', p_numbering_rule_id
      using errcode = '23503',
            hint = 'The document type names a numbering rule that does not exist in this organisation; promote the rule or repoint the type.';
  end if;

  if r.is_gapless then
    raise exception 'CLOVEERP_GAPLESS_ALLOCATED_ON_ATTEMPT: rule % is statutorily gapless and cannot number a document on creation', r.code
      using errcode = '23514',
            hint = 'A gapless number is allocated when the document is issued, at commit. Use a rule that is not gapless for creation-time numbering.';
  end if;

  v_period := erp.number_period(r.reset_period, current_date);

  -- The first allocation in a period continues from the rule's own counter,
  -- so a sequence that has already issued numbers carries on rather than
  -- starting again.
  select * into a from erp.allocate_number(
    'rule:' || r.id::text, r.prefix, r.suffix, r.pad_to, r.reset_period, current_date,
    case when r.current_period = v_period then r.next_value else 1 end);

  update erp.numbering_rule
     set next_value = a.value + 1, current_period = a.period, updated_at = now()
   where id = r.id;

  return a.number;
end;
$$;

comment on function erp.next_document_number(uuid) is
  'Numbers a document on creation from its rule: unique, not gapless, mirrored '
  'onto the rule''s counter. Refuses a rule declared gapless, because a gapless '
  'number is allocated on commit, not on attempt.';

-- is_gapless through promotion: the upsert, the promoter branch, the manifest.
do $promo$
declare
  v_def text;
  v_n   integer;
begin
  v_def := pg_get_functiondef('erp.upsert_numbering_rule(text,text,text,text,text,smallint,erp.number_reset,bigint)'::regprocedure);
  if position('p_next_value bigint DEFAULT 1)' in v_def) = 0
     or position('(tenant_id, code, entity_id, site_id, prefix, suffix, pad_to, reset_period, next_value)' in v_def) = 0
     or position('p_pad_to, p_reset_period, p_next_value)' in v_def) = 0
     or position('pad_to = excluded.pad_to, reset_period = excluded.reset_period,' in v_def) = 0 then
    raise exception 'CLOVEERP_NUMBERING_UPSERT_UNRECOGNISED: erp.upsert_numbering_rule is not the body this migration extends';
  end if;
  v_def := replace(v_def, 'p_next_value bigint DEFAULT 1)',
                          'p_next_value bigint DEFAULT 1, p_is_gapless boolean DEFAULT false)');
  v_def := replace(v_def, '(tenant_id, code, entity_id, site_id, prefix, suffix, pad_to, reset_period, next_value)',
                          '(tenant_id, code, entity_id, site_id, prefix, suffix, pad_to, reset_period, next_value, is_gapless)');
  v_def := replace(v_def, 'p_pad_to, p_reset_period, p_next_value)',
                          'p_pad_to, p_reset_period, p_next_value, coalesce(p_is_gapless, false))');
  v_def := replace(v_def, 'pad_to = excluded.pad_to, reset_period = excluded.reset_period,',
                          'pad_to = excluded.pad_to, reset_period = excluded.reset_period, is_gapless = excluded.is_gapless,');
  -- A different argument list is a new overload under CREATE OR REPLACE; the
  -- old one goes first so a call by position resolves to one function.
  drop function erp.upsert_numbering_rule(text,text,text,text,text,smallint,erp.number_reset,bigint);
  execute v_def;

  -- The promoter passes it.
  select count(*) into v_n from pg_catalog.pg_proc p
   where p.proname = 'apply_change_set_item'
     and position('coalesce((p ->> ''next_value'')::bigint, 1));' in p.prosrc) > 0;
  if v_n <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the numbering_rule branch of erp.apply_change_set_item was not found exactly once';
  end if;
  v_def := pg_get_functiondef((select oid from pg_catalog.pg_proc where proname = 'apply_change_set_item'));
  v_def := replace(v_def, 'coalesce((p ->> ''next_value'')::bigint, 1));',
                          'coalesce((p ->> ''next_value'')::bigint, 1), coalesce((p ->> ''is_gapless'')::boolean, false));');
  execute v_def;

  -- The manifest carries it.
  select count(*) into v_n from pg_catalog.pg_proc p
   where p.proname = 'configuration_manifest'
     and position('''reset_period'', nr.reset_period)' in p.prosrc) > 0;
  if v_n <> 1 then
    raise exception 'CLOVEERP_MANIFEST_UNRECOGNISED: the numbering_rule arm of erp.configuration_manifest was not found exactly once';
  end if;
  v_def := pg_get_functiondef((select oid from pg_catalog.pg_proc where proname = 'configuration_manifest'));
  v_def := replace(v_def, '''reset_period'', nr.reset_period)',
                          '''reset_period'', nr.reset_period, ''is_gapless'', nr.is_gapless)');
  execute v_def;
end
$promo$;

alter table erp_ref.legislation_pack add column if not exists requires_gapless boolean not null default false;

comment on column erp_ref.legislation_pack.requires_gapless is
  '§6.4: the jurisdiction requires statutorily gapless numbering of journals '
  'and issued invoices. Read when a pack is bound to an entity.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Journals: numbered at commit, from the ledger's series
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.ledger add column if not exists journal_prefix  text not null default '';
alter table erp.ledger add column if not exists journal_reset   erp.number_reset not null default 'yearly';
alter table erp.ledger add column if not exists journal_gapless boolean not null default false;

comment on column erp.ledger.journal_prefix is
  'Prefix of this ledger''s journal numbers; empty means the ledger code and a hyphen.';
comment on column erp.ledger.journal_gapless is
  '§6.4: this ledger''s journals are statutorily gapless. Numbers are allocated '
  'on commit for every ledger; the declaration is what the gap report enforces.';

create unique index if not exists journal_number_per_ledger
  on erp.journal (tenant_id, ledger_id, journal_number)
  where journal_number is not null;

-- Acquiring a number is not being re-posted: the period check stands down for
-- an update that changes journal_number and nothing else that it judges.
do $period$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('erp.check_period_open()'::regprocedure);
  if (select count(*) from regexp_matches(v_def, 'if new\.status is distinct from ''posted'' then\s+return new;\s+end if;', 'g')) <> 1 then
    raise exception 'CLOVEERP_PERIOD_GUARD_UNRECOGNISED: erp.check_period_open() is not the body this migration patches';
  end if;
  v_def := regexp_replace(v_def,
    'if new\.status is distinct from ''posted'' then\s+return new;\s+end if;',
    E'if tg_op = ''UPDATE'' and new.journal_number is distinct from old.journal_number\n'
 || E'     and new.status = old.status and new.posting_date = old.posting_date\n'
 || E'     and new.ledger_id = old.ledger_id then\n'
 || E'    return new;\n'
 || E'  end if;\n\n'
 || E'  if new.status is distinct from ''posted'' then\n    return new;\n  end if;');
  execute v_def;
end
$period$;

create or replace function erp.journal_number_for(p_ledger_id uuid, p_on date)
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  l erp.ledger%rowtype;
  a record;
begin
  select * into l from erp.ledger where id = p_ledger_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_LEDGER: %', p_ledger_id using errcode = '23503',
      hint = 'The journal names a ledger that does not exist in this organisation.';
  end if;
  select * into a from erp.allocate_number(
    'ledger:' || l.id::text,
    coalesce(nullif(l.journal_prefix, ''), l.code || '-'), '', 6::smallint,
    l.journal_reset, p_on, 1);
  return a.number;
end;
$$;

create or replace function erp.number_journal_on_commit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status is distinct from 'posted' then
    return null;
  end if;
  -- Numbered already, by an earlier event in this transaction or by a caller
  -- that brought its own (opening balances carry the batch code).
  if exists (select 1 from erp.journal j where j.id = new.id and j.journal_number is not null) then
    return null;
  end if;
  update erp.journal
     set journal_number = erp.journal_number_for(new.ledger_id, new.posting_date)
   where id = new.id and journal_number is null;
  return null;
end;
$$;

comment on function erp.number_journal_on_commit is
  '§6.4: a journal takes its number when the transaction that posted it commits, '
  'from its ledger''s series in the period of its posting date. A posting that '
  'rolls back never consumed one.';

drop trigger if exists t_journal_number on erp.journal;
create constraint trigger t_journal_number
  after insert or update of status on erp.journal
  deferrable initially deferred
  for each row execute function erp.number_journal_on_commit();

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Every posted journal there already is
-- ═════════════════════════════════════════════════════════════════════════════

do $backfill$
declare
  t record;
  j record;
  v_n integer := 0;
  v_prev text := current_setting('erp.job_tenant_id', true);
begin
  for t in select distinct jn.tenant_id from erp.journal jn where jn.status = 'posted' and jn.journal_number is null loop
    perform set_config('erp.job_tenant_id', t.tenant_id::text, true);
    for j in
      select id, ledger_id, posting_date from erp.journal
       where tenant_id = t.tenant_id and status = 'posted' and journal_number is null
       order by ledger_id, posting_date, posted_at, id
    loop
      update erp.journal set journal_number = erp.journal_number_for(j.ledger_id, j.posting_date)
       where id = j.id;
      v_n := v_n + 1;
    end loop;
  end loop;
  perform set_config('erp.job_tenant_id', coalesce(v_prev, ''), true);
  raise notice 'numbered % posted journal(s) that had none', v_n;
  if exists (select 1 from erp.journal where status = 'posted' and journal_number is null) then
    raise exception 'CLOVEERP_JOURNAL_UNNUMBERED: a posted journal is still without a number after the backfill';
  end if;
end
$backfill$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The gap report reads the series, for documents and journals alike
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.sequence_gap_report()
returns table(finding text, rule_code text, expected text, issued bigint, gaps bigint)
language sql
stable
set search_path = ''
as $$
  with t as (select erp.require_tenant_id() as tenant_id),
  -- Documents: one row per rule and period the series has issued in.
  doc_series as (
    select nr.code as rule_code, nr.is_gapless,
           nr.prefix || case when s.period = '' then '' else s.period || '-' end as head,
           nr.suffix, nr.pad_to, s.next_value, s.tenant_id
      from erp.numbering_series s
      join t on t.tenant_id = s.tenant_id
      join erp.numbering_rule nr on nr.tenant_id = s.tenant_id
                                and s.series_key = 'rule:' || nr.id::text
     where s.next_value > 1
  ),
  doc_used as (
    select d.rule_code, d.is_gapless, d.head, d.next_value,
           count(x.id) as issued,
           count(distinct x.n) as distinct_numbers
      from doc_series d
      left join lateral (
        select doc.id,
               substring(doc.document_number from length(d.head) + 1 for d.pad_to)::bigint as n
          from erp.document doc
         where doc.tenant_id = d.tenant_id
           and doc.document_number like d.head || '%'
           and substring(doc.document_number from length(d.head) + 1 for d.pad_to) ~ '^[0-9]+$'
      ) x on true
     group by d.rule_code, d.is_gapless, d.head, d.next_value
  ),
  -- Journals: one row per ledger and period.
  jnl_series as (
    select 'ledger:' || l.code as rule_code, l.journal_gapless as is_gapless,
           coalesce(nullif(l.journal_prefix, ''), l.code || '-')
             || case when s.period = '' then '' else s.period || '-' end as head,
           s.next_value, s.tenant_id, l.id as ledger_id
      from erp.numbering_series s
      join t on t.tenant_id = s.tenant_id
      join erp.ledger l on l.tenant_id = s.tenant_id
                       and s.series_key = 'ledger:' || l.id::text
     where s.next_value > 1
  ),
  jnl_used as (
    select j.rule_code, j.is_gapless, j.head, j.next_value,
           count(x.id) as issued,
           count(distinct x.n) as distinct_numbers
      from jnl_series j
      left join lateral (
        select jn.id, substring(jn.journal_number from length(j.head) + 1 for 6)::bigint as n
          from erp.journal jn
         where jn.tenant_id = j.tenant_id and jn.ledger_id = j.ledger_id
           and jn.journal_number like j.head || '%'
           and substring(jn.journal_number from length(j.head) + 1 for 6) ~ '^[0-9]+$'
      ) x on true
     group by j.rule_code, j.is_gapless, j.head, j.next_value
  ),
  used as (
    select * from doc_used union all select * from jnl_used
  )
  select case
           when u.issued > u.distinct_numbers
             then 'the same number is on more than one record'
           when u.is_gapless
             then 'numbers are missing from a statutorily gapless series'
           else 'numbers are missing from the issued range'
         end,
         u.rule_code,
         format('%s1..%s%s', u.head, u.head, u.next_value - 1),
         u.issued,
         (u.next_value - 1) - u.distinct_numbers
    from used u
   where u.distinct_numbers < u.next_value - 1
      or u.issued > u.distinct_numbers
   order by 2, 3;
$$;

comment on function erp.sequence_gap_report is
  'Every document rule and every ledger whose issued numbers do not match its '
  'series: missing numbers, or the same number twice. A gap on a series declared '
  'gapless is named as such. The administration.sequence_gaps job reads this.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The assertion
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_journals_numbered()
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_unnumbered integer;
  v_gapless  integer;
  v_detail   text;
begin
  select count(*) into v_unnumbered
    from erp.journal j where j.tenant_id = v_tenant and j.status = 'posted' and j.journal_number is null;
  if v_unnumbered > 0 then
    raise exception 'CLOVEERP_JOURNAL_UNNUMBERED: % posted journal(s) carry no number', v_unnumbered
      using errcode = '23514';
  end if;

  select count(*), string_agg(format('  %s: %s (%s, %s gap(s))', r.rule_code, r.finding, r.expected, r.gaps), E'\n')
    into v_gapless, v_detail
    from erp.sequence_gap_report() r
   where r.finding like '%gapless%' or r.finding like 'the same number%';
  if v_gapless > 0 then
    raise exception E'CLOVEERP_GAPLESS_SERIES_BROKEN: % series\n%', v_gapless, v_detail
      using errcode = '23514';
  end if;

  return format('journals: %s posted, every one numbered; %s gapless series intact',
    (select count(*) from erp.journal j where j.tenant_id = v_tenant and j.status = 'posted'),
    (select count(*) from erp.ledger l where l.tenant_id = v_tenant and l.journal_gapless)
      + (select count(*) from erp.numbering_rule nr where nr.tenant_id = v_tenant and nr.is_gapless));
end;
$$;

comment on function erp.assert_journals_numbered is
  'Every posted journal in this organisation has a number, no number is on two '
  'records, and no series declared gapless has a gap. Per organisation; the '
  'whole-database reconciliation drives it for every one.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq) values
  ('journals_numbered', 'Every posted journal has a number', 'assertion', 'tenant',
   'assert_journals_numbered', '', 'sequence_gap_report', '',
   'Every posted journal carries a number from its ledger''s series, and every series declared gapless is intact.', true, 91)
on conflict (code) do update
  set title = excluded.title, function_name = excluded.function_name, scope = excluded.scope,
      detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.numbering_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_cases    integer := 0;
  v_tenant   uuid;
  v_admin    uuid;
  v_token    text;
  v_from     date := (date_trunc('month', current_date) - interval '13 months')::date;
  v_msg      text;
  v_n        integer;
  v_m        integer;
  v_before   bigint;
  v_after    bigint;
  v_gl       uuid;
  v_rule     uuid;
  v_number   text;
begin
  -- Fixture: a provisioned organisation with the demonstration configuration
  -- and one five-day slice of trading, dated thirteen months ago. Everything
  -- runs inside one block that is rolled back at the end: a tenant with an
  -- access log cannot be deleted, and should not need to be.
  begin
  select t.tenant_id, t.admin_user_id, t.admin_token into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-numbering', 'Numbering suite', 'admin@zz-numbering.test', 'Numbering Admin') t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  -- The builders authorise, so the fixture acts as the invited administrator.
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000b2', 'admin@zz-numbering.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000b2')::text, true);
  perform erp.claim_invitation(v_token);
  perform erp.ensure_demo_configuration(v_tenant, v_admin);
  perform erp.seed_demo_history(v_from, null, 1);
  set constraints all immediate;

  select l.id into v_gl from erp.ledger l where l.tenant_id = v_tenant and l.code = 'GL';

  -- 1. Every posted journal has a number in its ledger's series; no draft does.
  v_cases := v_cases + 1;
  select count(*) filter (where j.status = 'posted' and j.journal_number is null),
         count(*) filter (where j.status = 'posted'),
         count(*) filter (where j.status <> 'posted' and j.journal_number is not null)
    into v_n, v_m, v_before
    from erp.journal j where j.tenant_id = v_tenant;
  case_name := 'every posted journal has a number and no unposted one does';
  passed := v_n = 0 and v_m > 10 and v_before = 0
        and not exists (select 1 from erp.journal j join erp.ledger l on l.id = j.ledger_id
                         where j.tenant_id = v_tenant and j.status = 'posted'
                           and j.journal_number not like l.code || '-' || to_char(j.posting_date, 'YYYY') || '-%');
  detail := format('%s posted journals, %s without a number, %s unposted with one', v_m, v_n, v_before);
  return next;

  -- 2. The series are contiguous.
  v_cases := v_cases + 1;
  select count(*) into v_n from erp.sequence_gap_report();
  case_name := 'every series is contiguous after a slice of trading';
  passed := v_n = 0;
  detail := format('%s gap finding(s)', v_n);
  return next;

  -- 3. A rolled-back posting leaves no gap.
  v_cases := v_cases + 1;
  select s.next_value into v_before from erp.numbering_series s
   where s.tenant_id = v_tenant and s.series_key = 'ledger:' || v_gl::text order by s.period desc limit 1;
  begin
    perform erp.seed_demo_history(v_from + 5, null, 1);
    set constraints all immediate;
    select s.next_value into v_after from erp.numbering_series s
     where s.tenant_id = v_tenant and s.series_key = 'ledger:' || v_gl::text order by s.period desc limit 1;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;
  select s.next_value into v_n from erp.numbering_series s
   where s.tenant_id = v_tenant and s.series_key = 'ledger:' || v_gl::text order by s.period desc limit 1;
  case_name := 'a posting that rolls back consumes no number';
  passed := v_after > v_before and v_n = v_before;
  detail := format('counter %s before, %s inside the rolled-back posting, %s after', v_before, v_after, v_n);
  return next;

  -- 4. Numbers issued in the same transaction are consecutive.
  v_cases := v_cases + 1;
  perform erp.seed_demo_history(v_from + 5, null, 1);
  set constraints all immediate;
  select count(*) into v_n from erp.sequence_gap_report();
  case_name := 'a second slice numbers consecutively with no gap';
  passed := v_n = 0 and (select s.next_value from erp.numbering_series s
                          where s.tenant_id = v_tenant and s.series_key = 'ledger:' || v_gl::text
                          order by s.period desc limit 1) > v_before;
  detail := format('%s gap finding(s) after two slices', v_n);
  return next;

  -- 5. A journal dated in another year takes that year's series.
  v_cases := v_cases + 1;
  perform erp.seed_demo_history((date_trunc('month', current_date) - interval '1 month')::date, null, 1);
  set constraints all immediate;
  select count(distinct s.period) into v_n from erp.numbering_series s
   where s.tenant_id = v_tenant and s.series_key = 'ledger:' || v_gl::text;
  select count(*) into v_m from erp.sequence_gap_report();
  case_name := 'journals dated in different years number in different series, each contiguous';
  passed := v_n >= 2 and v_m = 0;
  detail := format('%s period(s) on the general ledger, %s gap finding(s)', v_n, v_m);
  return next;

  -- 6. The same number twice is refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp.journal j set journal_number = (select x.journal_number from erp.journal x
                                                where x.tenant_id = v_tenant and x.ledger_id = j.ledger_id
                                                  and x.id <> j.id and x.journal_number is not null limit 1)
     where j.id = (select id from erp.journal where tenant_id = v_tenant and ledger_id = v_gl and journal_number is not null order by id limit 1);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
  end;
  case_name := 'the same number on two journals of one ledger is refused';
  passed := v_msg like '%journal_number_per_ledger%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 7. A gapless rule refuses eager allocation.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    select id into v_rule from erp.numbering_rule where tenant_id = v_tenant order by code limit 1;
    update erp.numbering_rule set is_gapless = true where id = v_rule;
    begin
      v_number := erp.next_document_number(v_rule);
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a rule declared gapless refuses to number on attempt';
  passed := v_msg like 'CLOVEERP_GAPLESS_ALLOCATED_ON_ATTEMPT:%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 8. A gap on a gapless ledger is reported and refused.
  v_cases := v_cases + 1;
  v_msg := null;
  begin
    update erp.ledger set journal_gapless = true where id = v_gl;
    update erp.numbering_series set next_value = next_value + 1
     where tenant_id = v_tenant and series_key = 'ledger:' || v_gl::text;
    begin
      perform erp.assert_journals_numbered();
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  case_name := 'a gap in a gapless ledger series is refused';
  passed := v_msg like 'CLOVEERP_GAPLESS_SERIES_BROKEN:%' and v_msg like '%ledger:GL%';
  detail := left(coalesce(v_msg, 'no refusal'), 200);
  return next;

  -- 9. Document numbering continues from the rule's counter and mirrors back.
  v_cases := v_cases + 1;
  select id, next_value into v_rule, v_before from erp.numbering_rule
   where tenant_id = v_tenant and code = (select nr.code from erp.numbering_rule nr
                                            join erp.document_type dt on dt.numbering_rule_id = nr.id
                                           where dt.tenant_id = v_tenant and dt.code = 'purchase_order');
  v_number := erp.next_document_number(v_rule);
  select next_value into v_after from erp.numbering_rule where id = v_rule;
  case_name := 'a document number continues the rule''s counter and the counter follows';
  passed := v_number like '%' || lpad(v_before::text, 6, '0') and v_after = v_before + 1;
  detail := format('rule at %s issued %s, counter now %s', v_before, v_number, v_after);
  return next;

  -- 10. is_gapless travels through the upsert and the manifest.
  v_cases := v_cases + 1;
  perform erp.upsert_numbering_rule('zz_gapless', 'ZG-', null, null, null, 6::smallint, 'yearly'::erp.number_reset, 1, true);
  case_name := 'is_gapless is promotable and appears in the manifest';
  passed := exists (select 1 from erp.numbering_rule where tenant_id = v_tenant and code = 'zz_gapless' and is_gapless)
        and exists (select 1 from erp.configuration_manifest() m
                     where m.object_kind = 'numbering_rule' and m.object_key = 'zz_gapless'
                       and (m.content ->> 'is_gapless')::boolean);
  detail := 'upsert_numbering_rule(..., p_is_gapless => true) and configuration_manifest() agree';
  return next;

  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then raise; end if;
  end;

  -- 11. The fixture went with the rollback.
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := not exists (select 1 from erp.tenant where code = 'zz-numbering')
        and not exists (select 1 from auth.users where id = '00000000-0000-4000-8000-0000000000b2');
  detail := 'zz-numbering and its auth row rolled back with everything they owned';
  return next;

  if v_cases <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: numbering_suite ran % cases, expected 11', v_cases;
  end if;
end;
$$;

create or replace function erp_test.assert_numbering_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _numbering on commit drop as
    select * from erp_test.numbering_suite();
  select count(*), count(*) filter (where not passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_all, v_fail, v_detail
    from _numbering;
  drop table _numbering;
  if v_fail > 0 then
    raise exception E'CLOVEERP_NUMBERING_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> 11 then
    raise exception 'CLOVEERP_SUITE_SHRANK: numbering_suite ran % cases, expected 11', v_all;
  end if;
  return format('numbering: %s/%s cases passed', v_all, v_all);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. Prove it
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_numbering_suite();
select erp.assert_whole_database_reconciles();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_configuration_promotable();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- And the whole console, green.
do $console$
declare v_bad text;
begin
  select string_agg(c ->> 'code' || ': ' || left(c ->> 'detail', 80), '; ')
    into v_bad
    from jsonb_array_elements(erp.platform_assurance()) c
   where not (c ->> 'ok')::boolean;
  if v_bad is not null then
    raise exception 'CLOVEERP_ASSURANCE_NOT_GREEN: %', v_bad;
  end if;
end
$console$;
