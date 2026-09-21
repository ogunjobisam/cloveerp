set lock_timeout = '30s';

-- =============================================================================
-- 20260921700000  The trail is read through an index
-- -----------------------------------------------------------------------------
-- erp.platform_assurance() took 48.7 s on live on 21 September (deploy run
-- 35642695510, 19:08 UTC). Its function-level statement_timeout is 55 s, the
-- deploy warns above 35, and the step that runs it — "Prove the live database"
-- — is the last gate before a release is recorded. Two of the registered
-- assertions were 28.5 s of the 48.7:
--
--   21799.4 ms  audit_attributed
--    6746.4 ms  audit_source_vocabulary
--    2549.8 ms  setup_walkthrough
--    1961.1 ms  caller_reachable_internals
--    1592.6 ms  public_api_safe
--
-- and everything else together was 20.2 s, which is roughly where
-- 20260914090000 left it. So this is not "assurance got slow". Two checks read
-- an append-only table from one end to the other, and that table grew.
--
-- 20260914090000 predicted this in writing. It took live assurance from 63.3 s
-- to 16.9 s and recorded that the slowest survivor was audit_attributed at
-- 3.9 s, because it "sequentially scans erp.audit_entry from the epoch, twice,
-- and grows with the data". It is now 21.8 s: 45 per cent of the budget on its
-- own. Today's demonstration catch-up traded five months forward and wrote 243
-- documents, every one of which is audit entries, and it will do the same
-- again tomorrow.
--
-- ── WHAT THE TWO WERE ACTUALLY DOING ─────────────────────────────────────────
--
--   audit_attributed reads erp.audit_entry twice. Once through
--   erp.audit_attribution_report(), which looks for an entry with neither a
--   principal nor a mechanism since the attribution epoch; once more in its own
--   closing sentence, to count the entries it had judged. Neither read has an
--   index it can use: all five indexes on the table lead with tenant_id, and
--   both questions are asked of every tenant at once. So both are sequential
--   scans of a table whose rows carry before_state and after_state as jsonb —
--   wide rows, many pages, and two passes over all of them.
--
--   audit_source_vocabulary is five register reads and one table read. The
--   register reads are the vocabulary itself: the foreign key exists, the
--   honest default exists, every current word is declared by an entry point, no
--   entry point claims a retired word, every declaring one says where. Those
--   are small and cost nothing. The sixth asks whether anything written since
--   the vocabulary existed carries a word outside it, and it asked by grouping
--   the whole of erp.audit_entry and the whole of erp.event by source. Two more
--   sequential scans of tables that only ever grow.
--
-- ── WHAT WAS NOT DONE, AND WHY ───────────────────────────────────────────────
--
-- The cheap repair is to look at less: judge the last month, or the last ten
-- thousand entries, and leave the rest. That is faster, it proves less, and it
-- proves less silently — the sentence would read the same. An audit trail that
-- is checked for a month is not an audit trail that is checked.
--
-- The honest version of looking at less is a watermark: record that everything
-- up to a point has been verified and verify only what is past it. It is the
-- right shape for an append-only table and it is not available here. Both
-- assertions are stable, as are erp.run_diagnostic() and erp.platform_assurance()
-- above them, and PostgreSQL will not let a non-volatile function write. Making
-- the assurance path volatile so that a check could advance a mark would turn
-- every read-only proof of this database into a writer — a far larger change
-- than the one being paid for — and it would put a row the build maintains in
-- front of the trail the build is there to read.
--
-- So nothing here looks at less. What changed is what the looking costs.
--
-- ── WHAT CHANGED ─────────────────────────────────────────────────────────────
--
--   1. erp.audit_attribution_report() is not touched at all. Its query is the
--      one it has always been, character for character. A partial index now
--      holds exactly the rows it looks for — the ones with no principal and no
--      mechanism — so the read is over the findings rather than over the trail.
--      There are no findings, which is the point: the index is nearly empty and
--      stays nearly empty, because a row entering it is a refusal. An index
--      whose predicate is the finding is not a narrowing of the claim. It is
--      the same claim, evaluated as each row is written rather than months
--      later, by the same database that refuses the row.
--
--   2. audit_attributed's closing sentence no longer counts every entry since
--      the epoch. That count was the second sequential scan and was never part
--      of the claim — the claim is that nothing unattributed exists, and the
--      count was scale, printed so that a reader could see the check had
--      something to look at rather than an empty table. It still says that,
--      from the newest entry's identity, which the primary key answers in one
--      probe. This is the one thing in this file that says less than it did: an
--      exact population where there is now a high-water mark. It cost a
--      sequential scan of the whole trail on every deploy, and what it bought
--      was "every one of 1,4xx,xxx entries" instead of "the trail has reached
--      entry 1,4xx,xxx".
--
--   3. audit_source_vocabulary's sixth finding no longer groups the two tables.
--      It walks the distinct values of source through an index — the ordinary
--      skip scan, a minimum and then the minimum above it, until they run out —
--      and asks, of each word that is not a current entry point, whether that
--      word appears since the epoch. The first is a handful of index probes;
--      the second is one empty range scan per retired word.
--
--      The candidates are a superset of what the old grouping could produce: a
--      word that appears since the epoch appears at all, so it is in the walk.
--      The test applied to each candidate is the old test, unchanged. A count
--      is taken only for a word that has already failed it, and a word with
--      nothing since the epoch yields no row, exactly as an empty group did.
--
--   4. Three indexes:
--
--        audit_entry_unattributed_idx     (occurred_at) where the row names
--                                         neither a principal nor a mechanism
--        audit_entry_source_occurred_idx  (source, occurred_at)
--        event_source_occurred_idx        (source, occurred_at)
--
--      The first is small by construction. The other two lead with a column of
--      perhaps half a dozen values on tables whose second column arrives in
--      order, so an insert lands on a rightmost page.
--
-- ── WHICH PLANS THIS CHANGES, AND WHY I BELIEVE IT ───────────────────────────
--
-- Live cannot be queried from here — the MCP groups that would write or explain
-- are deliberately not requested — so the plan claims are reasoned and then
-- falsified in fixtures, not measured:
--
--   The attribution report's restriction is `actor_id is null and (actor_label
--   is null or actor_label = '')`, which is the index predicate written the
--   same way, so the predicate is implied clause for clause; occurred_at is the
--   index's only key and the epoch arrives as an InitPlan parameter, which is a
--   legal index bound. A sequential scan of erp.audit_entry becomes a scan of a
--   partial index holding the historical unattributed rows — the 208 that
--   20260904910000 was written for — and nothing since.
--
--   The per-word probe is `source = <a constant> and occurred_at >= <epoch>`: a
--   prefix of (source, occurred_at) and then a range on the second column, so
--   one descent, and for a retired word with nothing since the epoch an empty
--   range. A HashAggregate over a sequential scan becomes a few index pages.
--
--   The step of the walk is `source > <the last word>` ordered by source, which
--   is the index's own order.
--
-- erp_test.audit_scan_suite() does not take that on trust. It plans each shape
-- with sequential scans and sorts made expensive and refuses unless the plan
-- names the index, and it writes each probe so that the answer cannot turn on
-- how much the fixture happens to hold: the finding is asked as the index
-- predicate alone, so the estimate comes from the index's own tuple count; the
-- walk asks for an order no other index on the table can give; the two probes
-- name a word no trail contains. What live chooses between a usable index and
-- a scan of a table this size is not in doubt. Whether the index is usable at
-- all is the question an offline session can answer, and it is the one that
-- bites: a predicate that stops matching clause for clause takes the check
-- quietly back to reading the whole trail.
--
-- ── WHY THE BUILD CANNOT SHOW THE IMPROVEMENT ────────────────────────────────
--
-- It cannot, and that is worth saying rather than leaving to be discovered. On
-- the build the two checks are 19–24 ms and 30–44 ms (jobs 106460527471,
-- 106428297612 and 106434146134, three separate restores), because a build
-- stands the database up from empty and its trail is 4,492 entries a few hours
-- old. Live's is the same trail after a demonstration organisation has traded
-- for months. CI green is evidence about the build. What CI can prove is what
-- this file asks of it: that the new readings find exactly what the old ones
-- find, on fixtures built to be found and fixtures built not to be, and that
-- the indexes are usable for the shapes that now depend on them.
--
-- ── WHAT HAPPENS ON A RESTORE, AND WHEN THE MARK IS WRONG ────────────────────
--
-- There is no mark. That is the reason this shape was preferred to a watermark:
-- nothing here is state that can be stale, missing or quietly corrupted by the
-- build. An index is not a record that a row was checked — it is where the row
-- is, maintained by the same insert that writes the row and rebuilt with the
-- database by any restore. If one were dropped by hand the readings would still
-- be correct and merely slow again. The first run after a restore reads
-- everything it would ever read, because every run reads everything.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The indexes
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The predicate of the first is the finding. A row that matches it is a row
-- erp.assert_audit_attributed() refuses, so the index holds the entries written
-- before attribution existed and nothing after them. It is built on a table
-- that every write in the product appends to; a plain build takes a ShareLock
-- for its duration, which on a trail of this size is seconds, and it is taken
-- inside the deploy that already holds the release.

create index if not exists audit_entry_unattributed_idx
  on erp.audit_entry (occurred_at)
  where actor_id is null and (actor_label is null or actor_label = '');

comment on index erp.audit_entry_unattributed_idx is
  'The rows erp.audit_attribution_report() looks for, and only those: an entry '
  'naming neither a principal nor a mechanism. The check reads its findings '
  'rather than the trail, so it costs what it finds.';

create index if not exists audit_entry_source_occurred_idx
  on erp.audit_entry (source, occurred_at);

comment on index erp.audit_entry_source_occurred_idx is
  'Walks the distinct entry points the trail holds, and answers whether one of '
  'them appears since the vocabulary existed, without reading the trail.';

create index if not exists event_source_occurred_idx
  on erp.event (source, occurred_at);

comment on index erp.event_source_occurred_idx is
  'The same question of the event store that audit_entry_source_occurred_idx '
  'answers of the audit trail.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. What the database holds today, before it is replaced
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Neither function below is re-emitted from the migration that created it. The
-- body of erp.assert_audit_attributed() on any live database is not the body in
-- 20260904910000: 20260904980000 rewrote every routine in the product from its
-- own definition, to move ERPWARE_ to CLOVEERP_, and that function was one of
-- them. Re-emitting the file would put the retired prefix back and
-- refusal_prefix_current would find it forty minutes later.
--
-- So each replacement states what it expects to be replacing, in anchors taken
-- from the definition the database actually holds, and refuses if it finds
-- anything else. The anchors are the lines being changed and the refusal codes
-- being kept.

do $anchors$
declare
  v_def  text;
  v_hits integer;
  r      record;
begin
  for r in
    select * from (values
      ('erp.assert_audit_attributed()',
       'CLOVEERP_AUDIT_UNATTRIBUTED', 1,
       'the refusal code this file keeps unchanged'),
      ('erp.assert_audit_attributed()',
       'audit attribution: every one of %s entries since %s names a principal or a mechanism', 1,
       'the closing sentence whose count is the second sequential scan'),
      ('erp.assert_audit_attributed()',
       'from erp.audit_attribution_report() r', 1,
       'the finding query, which this file does not touch'),
      ('erp.assert_audit_source_vocabulary()',
       'and a.source not in (select s.code from erp_ref.audit_source s where s.is_current)', 1,
       'the grouping of the whole audit trail'),
      ('erp.assert_audit_source_vocabulary()',
       'and v.source not in (select s.code from erp_ref.audit_source s where s.is_current)', 1,
       'the grouping of the whole event store'),
      ('erp.assert_audit_source_vocabulary()',
       'CLOVEERP_AUDIT_SOURCE_OUTSIDE_VOCABULARY', 1,
       'the refusal code this file keeps unchanged')
    ) x(sig, anchor, want, why)
  loop
    v_def := pg_catalog.pg_get_functiondef(r.sig::regprocedure);
    v_hits := (length(v_def) - length(replace(v_def, r.anchor, ''))) / length(r.anchor);
    if v_hits <> r.want then
      raise exception
        'CLOVEERP_ANCHOR_NOT_FOUND: % holds % occurrence(s) of an anchor this migration expects % of — %',
        r.sig, v_hits, r.want, r.why
        using errcode = '23514',
              hint = 'The body in the database is not the body this file was written '
                     'against. Read the current definition before replacing it; do not '
                     're-emit the migration that created it.';
    end if;
  end loop;
  raise notice 'six anchors, each found once: the two definitions are the ones this file was written against';
end
$anchors$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Every audit entry says who or what — read from the findings
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.audit_attribution_report() is deliberately absent from this file. The
-- finding query is unchanged; what answers it has changed.

create or replace function erp.assert_audit_attributed()
returns text
language plpgsql
stable
set search_path to ''
as $fn$
declare v_rows bigint; v_groups int; v_detail text;
begin
  select coalesce(sum(r.entries), 0), count(*),
         string_agg(format('  %s: %s on %s x%s', r.tenant_code, r.action,
                           r.object_type, r.entries), E'\n')
    into v_rows, v_groups, v_detail
    from erp.audit_attribution_report() r;

  if v_groups > 0 then
    raise exception E'CLOVEERP_AUDIT_UNATTRIBUTED: % entr(ies) in % group(s) name neither a principal nor a mechanism\n%',
      v_rows, v_groups, v_detail
      using errcode = '23502',
      hint = 'erp.audit_row_change() reads the call stack when there is no '
             'principal. A row that still says nothing was written round the '
             'trigger, or by a path that suppresses it.';
  end if;

  -- The population of the trail was counted here, and counting it was a second
  -- sequential scan of every entry since the epoch. The claim never rested on
  -- it. What it was for — showing a reader that the check had something in
  -- front of it rather than an empty table — the newest entry's identity says
  -- as well, from the primary key, in one probe that does not grow.
  return format('audit attribution: every entry since %s names a principal or a mechanism; the trail has reached entry %s',
                (select e.started_at::date from erp_meta.audit_attribution_epoch e),
                coalesce((select max(a.id) from erp.audit_entry a)::text, 'none'));
end;
$fn$;

comment on function erp.assert_audit_attributed() is
  'A change with no signed-in principal still names the mechanism that made it. '
  'Dated from erp_meta.audit_attribution_epoch, because entries written before '
  'attribution existed are append-only and cannot be corrected. Answered from '
  'audit_entry_unattributed_idx, whose predicate is the finding, so the check '
  'costs what it finds rather than what the trail holds.';

revoke all on function erp.assert_audit_attributed() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. An audited change names an entry point that exists — walked, not grouped
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Findings 1 to 5 read the registers and are unchanged, character for
-- character. Finding 6 is the one that read the tables.

create or replace function erp.assert_audit_source_vocabulary()
returns text
language plpgsql
stable
set search_path = ''
as $fn$
declare
  v_findings text := '';
  v_count    integer := 0;
  v_epoch    timestamptz;
  r          record;
begin
  select e.started_at into v_epoch from erp_meta.audit_source_epoch e;

  -- 1. The vocabulary is enforced by the database, not by a convention.
  for r in
    select x.rel from (values ('erp.audit_entry', 'audit_entry_source_known'),
                              ('erp.event', 'event_source_known')) x(rel, con)
     where not exists (
       select 1 from pg_catalog.pg_constraint c
        where c.conrelid = x.rel::regclass and c.contype = 'f' and c.conname = x.con)
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s.source is not foreign-keyed to erp_ref.audit_source, so any word can be written\n', r.rel);
  end loop;

  -- 2. The honest default exists and is the only word nothing declares.
  if not exists (select 1 from erp_ref.audit_source s
                  where s.code = 'undeclared' and s.is_current) then
    v_count := v_count + 1;
    v_findings := v_findings ||
      E'  the vocabulary has no current ''undeclared'', so a session that declares nothing has no honest word\n';
  end if;

  -- 3. A source nothing ever writes is the defect this check exists to close,
  --    so the vocabulary may not grow one. Every current word but the default
  --    is declared by a named entry point.
  for r in
    select s.code from erp_ref.audit_source s
     where s.is_current and s.code <> 'undeclared'
       and not exists (select 1 from erp_meta.audit_source_entry_point e
                        where e.records = s.code and e.declares)
     order by s.seq
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s is in the vocabulary and no entry point declares it — a source nothing writes is decoration\n', r.code);
  end loop;

  -- 4. An entry point may not claim a retired word.
  for r in
    select e.entry_point, e.records from erp_meta.audit_source_entry_point e
     join erp_ref.audit_source s on s.code = e.records
    where not s.is_current
    order by 1
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s records %s, which is retired\n', r.entry_point, r.records);
  end loop;

  -- 5. A declaring entry point says where. "Something declares it" with no
  --    place to look is the same silence in a different column.
  for r in
    select e.entry_point from erp_meta.audit_source_entry_point e
     where e.declares and coalesce(btrim(e.declared_at), '') = ''
     order by 1
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s is recorded as declaring its source and names nowhere it does so\n', r.entry_point);
  end loop;

  -- 6. And nothing written since the vocabulary existed is outside it.
  --
  --    This grouped both tables by source and kept the groups whose word is not
  --    current. It now walks the distinct words each table holds through
  --    (source, occurred_at) — a minimum, then the minimum above it — and asks
  --    the old question of each. A word that appears since the epoch appears at
  --    all, so the walk is a superset of what the grouping could produce; the
  --    test on each candidate is the old test; and a candidate with nothing
  --    since the epoch yields no row, as an empty group did. The count is taken
  --    only for a word that has already failed, so the only reading here whose
  --    cost is the size of the data is a reading on a database about to refuse.
  --
  --    Each candidate set is fenced behind OFFSET 0 and each count asked in a
  --    lateral, for the reason 20260914090000 records: written as plain joins,
  --    the planner is free to put the expensive side first and the narrowing
  --    does nothing.
  for r in
    with recursive audit_word(src) as (
        select (select min(a.source) from erp.audit_entry a)
      union all
        select (select min(a.source) from erp.audit_entry a where a.source > w.src)
          from audit_word w where w.src is not null
    ),
    event_word(src) as (
        select (select min(v.source) from erp.event v)
      union all
        select (select min(v.source) from erp.event v where v.source > w.src)
          from event_word w where w.src is not null
    )
    select 'erp.audit_entry'::text as rel, w.src as source, x.n
      from (select a.src from audit_word a
             where a.src is not null
               and a.src not in (select c.code from erp_ref.audit_source c where c.is_current)
             offset 0) w
      cross join lateral (
        select count(*) as n from erp.audit_entry a
         where a.source = w.src and a.occurred_at >= v_epoch) x
     where x.n > 0
    union all
    select 'erp.event'::text, w.src, x.n
      from (select e.src from event_word e
             where e.src is not null
               and e.src not in (select c.code from erp_ref.audit_source c where c.is_current)
             offset 0) w
      cross join lateral (
        select count(*) as n from erp.event v
         where v.source = w.src and v.occurred_at >= v_epoch) x
     where x.n > 0
     order by 1, 2
  loop
    v_count := v_count + 1;
    v_findings := v_findings || format(
      E'  %s entr(ies) in %s carry the source "%s", which is not a current entry point\n',
      r.n, r.rel, r.source);
  end loop;

  if v_count > 0 then
    raise exception E'CLOVEERP_AUDIT_SOURCE_OUTSIDE_VOCABULARY: % finding(s)\n%',
      v_count, v_findings
      using errcode = '23514',
            hint = 'Add the entry point to erp_ref.audit_source and the code '
                   'that declares it to erp_meta.audit_source_entry_point in '
                   'one migration, or stop writing the word. A source nothing '
                   'declares tells an auditor nothing.';
  end if;

  return format(
    'audit source: %s current entry point(s), %s of which declare, %s still undeclared, vocabulary held since %s',
    (select count(*) from erp_ref.audit_source s where s.is_current),
    (select count(*) from erp_meta.audit_source_entry_point e where e.declares),
    (select count(*) from erp_meta.audit_source_entry_point e where not e.declares),
    v_epoch::date);
end;
$fn$;

comment on function erp.assert_audit_source_vocabulary is
  'The source on an audited change names an entry point this product has. The '
  'vocabulary is foreign-keyed, the honest default exists, every word in it is '
  'declared by something, and nothing written since it existed falls outside '
  'it. Dated, because the history says ''api'' and cannot be rewritten. The '
  'last of those walks the distinct words through an index rather than '
  'grouping two tables that only grow.';

revoke all on function erp.assert_audit_source_vocabulary() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite: the old readings, kept as they were, beside the new ones
-- ═════════════════════════════════════════════════════════════════════════════
--
-- 20260914090000's rule, followed here. A faster check that passes where the
-- old one refused is the worst outcome available and it looks exactly like
-- success. So the old queries are kept verbatim, run beside the new ones and
-- compared with EXCEPT ALL in both directions: over fixtures built to be found,
-- over fixtures built not to be, and over both tables from the beginning of
-- time, where the two retired words are a real finding on any database that has
-- ever been written to.
--
-- Every case does its work inside the fixture block and reports afterwards, so
-- that a fixture that fails half way through says which step and why rather
-- than returning too few rows and reporting only that it shrank.
--
-- It lives in the catalogue and not at the end of this file: the old readings
-- it keeps are the cost this file takes out of live, and rule A of
-- supabase/ci/preflight.sh is the other reason — this fixture provisions an
-- organisation of its own.

create or replace function erp_test.audit_scan_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected   constant integer := 11;
  v_cases      integer := 0;
  v_step       text := 'before the fixture started';
  v_state      text;
  v_tag        text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1           uuid := gen_random_uuid();
  rb           record;
  v_tenant     uuid;
  v_att_epoch  timestamptz;
  v_src_epoch  timestamptz;
  v_base       integer;
  v_groups     integer;
  v_idx        text[];
  v_seq        text[];
  v_only_idx   text;
  v_only_seq   text;
  v_found      text;
  v_since      bigint;
  v_only_new   text;
  v_only_old   text;
  v_all        bigint;
  v_only_new_a text;
  v_only_old_a text;
  v_walk_only  text;
  v_dist_only  text;
  v_unattr     text;
  v_vocab      text;
  v_summary    text;
  v_plan_a     text;
  v_plan_b     text;
  v_plan_c     text;
  v_plan_d     text;
  v_def        text;
  v_old_shape  integer;
  v_new_shape  integer;
  v_left       integer;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    --
    -- Seven entries in an organisation of its own. Four for the attribution
    -- check — two findings, one that names a mechanism, one written before the
    -- epoch — and three for the vocabulary check, two carrying a retired word
    -- since its epoch and one carrying it before. Nothing is written to
    -- erp.event: its half is proved from the beginning of time instead, where
    -- the history the two retired words were written under is the fixture.
    v_step := 'an organisation with an administrator who has signed in';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.source', '', true);
    select * into rb from erp.provision_tenant(
      'zzscan-' || v_tag, 'Audit Scan Suite',
      'admin@zzscan-' || v_tag || '.test', 'Audit Scan Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzscan-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    select e.started_at into v_att_epoch from erp_meta.audit_attribution_epoch e;
    select e.started_at into v_src_epoch from erp_meta.audit_source_epoch e;
    select count(*)::integer into v_base from erp.audit_attribution_report() r;

    v_step := 'seven audit entries, each written to be judged one way';
    insert into erp.audit_entry
      (tenant_id, occurred_at, actor_id, actor_label, action,
       object_schema, object_type, source)
    values
      -- Findings: no principal, no mechanism, since the epoch.
      (v_tenant, clock_timestamp(), null, null,
       'insert'::erp.audit_action, 'erp', 'zzscan_silent', 'undeclared'),
      (v_tenant, clock_timestamp(), null, '',
       'insert'::erp.audit_action, 'erp', 'zzscan_blank', 'undeclared'),
      -- Not a finding: a mechanism is named.
      (v_tenant, clock_timestamp(), null, 'the catch-up',
       'insert'::erp.audit_action, 'erp', 'zzscan_named', 'undeclared'),
      -- Not a finding: older than the epoch, and append-only.
      (v_tenant, v_att_epoch - interval '1 day', null, null,
       'insert'::erp.audit_action, 'erp', 'zzscan_ancient', 'undeclared'),
      -- Findings for the vocabulary: the two retired words, since its epoch.
      (v_tenant, clock_timestamp(), null, 'audit scan suite',
       'insert'::erp.audit_action, 'erp', 'zzscan_api', 'api'),
      (v_tenant, clock_timestamp(), null, 'audit scan suite',
       'insert'::erp.audit_action, 'erp', 'zzscan_system', 'system'),
      -- Not a finding: a retired word from before the vocabulary existed.
      (v_tenant, v_src_epoch - interval '1 day', null, 'audit scan suite',
       'insert'::erp.audit_action, 'erp', 'zzscan_old_api', 'api');

    -- ── The report, from the index and from a sequential scan ───────────────
    --
    -- The same query text twice; only the plan differs. If the partial index
    -- ever answered a question other than the one the heap answers, this is
    -- where it would show.
    v_step := 'the attribution report, answered two ways';
    select array_agg(format('%s|%s|%s|%s', r.tenant_code, r.object_type, r.action, r.entries)
                     order by r.tenant_code, r.object_type, r.action)
      into v_idx
      from erp.audit_attribution_report() r;

    execute 'set local enable_indexscan = off';
    execute 'set local enable_bitmapscan = off';
    execute $q$
      select array_agg(format('%s|%s|%s|%s', x.code, x.object_type, x.action, x.entries)
                       order by x.code, x.object_type, x.action)
        from (select t.code, a.object_type, a.action::text as action, count(*) as entries
                from erp.audit_entry a
                join erp.tenant t on t.id = a.tenant_id
               where a.actor_id is null
                 and (a.actor_label is null or a.actor_label = '')
                 and a.occurred_at >= (select e.started_at from erp_meta.audit_attribution_epoch e)
               group by t.code, a.object_type, a.action) x
    $q$ into v_seq;
    execute 'set local enable_indexscan = on';
    execute 'set local enable_bitmapscan = on';

    select string_agg(y.v, '; ') into v_only_idx
      from (select unnest(coalesce(v_idx, '{}'::text[]))
            except all
            select unnest(coalesce(v_seq, '{}'::text[]))) y(v);
    select string_agg(y.v, '; ') into v_only_seq
      from (select unnest(coalesce(v_seq, '{}'::text[]))
            except all
            select unnest(coalesce(v_idx, '{}'::text[]))) y(v);

    -- ── What it found, and what it left alone ───────────────────────────────
    v_step := 'the two silent entries, the named one and the ancient one';
    select string_agg(r.object_type, ', ' order by r.object_type) into v_found
      from erp.audit_attribution_report() r
     where r.object_type like 'zzscan\_%';
    select count(*)::integer into v_groups from erp.audit_attribution_report() r;

    -- ── The partial index is usable for the shape that depends on it ────────
    --
    -- Not "live will choose it" — that cannot be known from here — but "it can
    -- be used at all", which is the failure that would otherwise be silent: a
    -- predicate that stops matching clause for clause and a check quietly back
    -- to reading the trail.
    --
    -- Each probe is written so that the answer does not turn on how much data
    -- the fixture happens to hold. The first asks only what the index predicate
    -- says, so the planner takes its row estimate from the index's own tuple
    -- count — a handful — where any other index must read the rows and filter.
    -- The walk asks for an order no index on the table can give but one leading
    -- with source, and sorting is made expensive. The two probes name a word
    -- that is in no trail, so the estimate cannot depend on how common a real
    -- word is.
    v_step := 'planning the finding the way the report asks it';
    execute 'set local enable_seqscan = off';
    execute 'set local enable_sort = off';
    execute $q$
      explain (format json)
      select count(*) from erp.audit_entry a
       where a.actor_id is null and (a.actor_label is null or a.actor_label = '')
    $q$ into v_plan_a;

    v_step := 'planning the step of the walk and the probe on either table';
    execute $q$
      explain (format json)
      select a.source from erp.audit_entry a
       where a.source > 'api'
       order by a.source
       limit 1
    $q$ into v_plan_b;
    execute format($q$
      explain (format json)
      select count(*) from erp.audit_entry a
       where a.source = 'zzscan_no_such_word' and a.occurred_at >= %L
    $q$, v_src_epoch) into v_plan_c;
    execute format($q$
      explain (format json)
      select count(*) from erp.event v
       where v.source = 'zzscan_no_such_word' and v.occurred_at >= %L
    $q$, v_src_epoch) into v_plan_d;
    execute 'set local enable_sort = on';
    execute 'set local enable_seqscan = on';

    -- ── It still refuses, and names what it found ───────────────────────────
    v_step := 'the attribution assertion, with two findings in front of it';
    begin
      v_unattr := 'passed: ' || erp.assert_audit_attributed();
    exception when others then
      v_unattr := left(sqlerrm, 400);
    end;

    -- ── The sixth finding, new against old, at the vocabulary's epoch ───────
    v_step := 'the source reading, new against old, since the epoch';
    with old_rows as materialized (
      select 'erp.audit_entry'::text as rel, a.source, count(*) as n
        from erp.audit_entry a
       where a.occurred_at >= v_src_epoch
         and a.source not in (select s.code from erp_ref.audit_source s where s.is_current)
       group by a.source
      union all
      select 'erp.event'::text, v.source, count(*)
        from erp.event v
       where v.occurred_at >= v_src_epoch
         and v.source not in (select s.code from erp_ref.audit_source s where s.is_current)
       group by v.source
    ),
    new_rows as materialized (
      with recursive audit_word(src) as (
          select (select min(a.source) from erp.audit_entry a)
        union all
          select (select min(a.source) from erp.audit_entry a where a.source > w.src)
            from audit_word w where w.src is not null
      ),
      event_word(src) as (
          select (select min(v.source) from erp.event v)
        union all
          select (select min(v.source) from erp.event v where v.source > w.src)
            from event_word w where w.src is not null
      )
      select 'erp.audit_entry'::text as rel, w.src as source, x.n
        from (select a.src from audit_word a
               where a.src is not null
                 and a.src not in (select c.code from erp_ref.audit_source c where c.is_current)
               offset 0) w
        cross join lateral (
          select count(*) as n from erp.audit_entry a
           where a.source = w.src and a.occurred_at >= v_src_epoch) x
       where x.n > 0
      union all
      select 'erp.event'::text, w.src, x.n
        from (select e.src from event_word e
               where e.src is not null
                 and e.src not in (select c.code from erp_ref.audit_source c where c.is_current)
               offset 0) w
        cross join lateral (
          select count(*) as n from erp.event v
           where v.source = w.src and v.occurred_at >= v_src_epoch) x
       where x.n > 0
    )
    select (select coalesce(sum(z.n), 0) from new_rows z),
           (select string_agg(z.rel || ' ' || z.source || ' x' || z.n, '; ')
              from (select * from new_rows except all select * from old_rows) z),
           (select string_agg(z.rel || ' ' || z.source || ' x' || z.n, '; ')
              from (select * from old_rows except all select * from new_rows) z)
      into v_since, v_only_new, v_only_old;

    -- ── And from the beginning of time, where the history is the fixture ────
    --
    -- Every database that has been written to at all carries entries under the
    -- two retired words, because that is what the column held for the life of
    -- the product. Asked from -infinity, the two readings have real work to do
    -- on both tables — including erp.event, which this fixture never writes to
    -- — and the entry written before the epoch is in scope, so the total must
    -- exceed the total since the epoch.
    v_step := 'the same two readings from before there was anything to read';
    with old_rows as materialized (
      select 'erp.audit_entry'::text as rel, a.source, count(*) as n
        from erp.audit_entry a
       where a.occurred_at >= '-infinity'::timestamptz
         and a.source not in (select s.code from erp_ref.audit_source s where s.is_current)
       group by a.source
      union all
      select 'erp.event'::text, v.source, count(*)
        from erp.event v
       where v.occurred_at >= '-infinity'::timestamptz
         and v.source not in (select s.code from erp_ref.audit_source s where s.is_current)
       group by v.source
    ),
    new_rows as materialized (
      with recursive audit_word(src) as (
          select (select min(a.source) from erp.audit_entry a)
        union all
          select (select min(a.source) from erp.audit_entry a where a.source > w.src)
            from audit_word w where w.src is not null
      ),
      event_word(src) as (
          select (select min(v.source) from erp.event v)
        union all
          select (select min(v.source) from erp.event v where v.source > w.src)
            from event_word w where w.src is not null
      )
      select 'erp.audit_entry'::text as rel, w.src as source, x.n
        from (select a.src from audit_word a
               where a.src is not null
                 and a.src not in (select c.code from erp_ref.audit_source c where c.is_current)
               offset 0) w
        cross join lateral (
          select count(*) as n from erp.audit_entry a
           where a.source = w.src and a.occurred_at >= '-infinity'::timestamptz) x
       where x.n > 0
      union all
      select 'erp.event'::text, w.src, x.n
        from (select e.src from event_word e
               where e.src is not null
                 and e.src not in (select c.code from erp_ref.audit_source c where c.is_current)
               offset 0) w
        cross join lateral (
          select count(*) as n from erp.event v
           where v.source = w.src and v.occurred_at >= '-infinity'::timestamptz) x
       where x.n > 0
    )
    select (select coalesce(sum(z.n), 0) from new_rows z),
           (select string_agg(z.rel || ' ' || z.source || ' x' || z.n, '; ')
              from (select * from new_rows except all select * from old_rows) z),
           (select string_agg(z.rel || ' ' || z.source || ' x' || z.n, '; ')
              from (select * from old_rows except all select * from new_rows) z)
      into v_all, v_only_new_a, v_only_old_a;

    -- ── The walk reaches every word the table holds ─────────────────────────
    --
    -- The narrowing rests on one property: a minimum, then the minimum above
    -- it, reaches every distinct value. A walk that skipped one would agree
    -- with the old reading about every word it did reach and be silent about
    -- the one it never asked after.
    v_step := 'the walk against select distinct';
    with recursive audit_word(src) as (
        select (select min(a.source) from erp.audit_entry a)
      union all
        select (select min(a.source) from erp.audit_entry a where a.source > w.src)
          from audit_word w where w.src is not null
    )
    select string_agg(z.v, '; ') into v_walk_only
      from ((select w.src from audit_word w where w.src is not null)
            except all
            (select distinct a.source from erp.audit_entry a)) z(v);

    with recursive audit_word(src) as (
        select (select min(a.source) from erp.audit_entry a)
      union all
        select (select min(a.source) from erp.audit_entry a where a.source > w.src)
          from audit_word w where w.src is not null
    )
    select string_agg(z.v, '; ') into v_dist_only
      from ((select distinct a.source from erp.audit_entry a)
            except all
            (select w.src from audit_word w where w.src is not null)) z(v);

    -- ── It refuses, names both words, and keeps its dating ──────────────────
    v_step := 'the vocabulary assertion, with two retired words in front of it';
    begin
      v_vocab := 'passed: ' || erp.assert_audit_source_vocabulary();
    exception when others then
      v_vocab := left(sqlerrm, 500);
    end;

    -- ── The assertion callers reach holds the new shape, not the old ────────
    --
    -- Everything above compares queries written here. This reads the function
    -- the deploy actually runs, so that a revert of the assertion cannot leave
    -- a green suite behind it.
    v_step := 'the assertion body, read back';
    v_def := pg_catalog.pg_get_functiondef('erp.assert_audit_source_vocabulary()'::regprocedure);
    v_new_shape := (length(v_def) - length(replace(v_def, 'a.source > w.src', '')))
                   / length('a.source > w.src');
    v_old_shape := (length(v_def) - length(replace(v_def,
      'a.source not in (select s.code from erp_ref.audit_source s where s.is_current)', '')))
      / length('a.source not in (select s.code from erp_ref.audit_source s where s.is_current)');
    v_summary := erp.assert_audit_attributed();

    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.source', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.source', '', true);

  -- 1
  v_cases := v_cases + 1;
  case_name := 'the unattributed report answered from the index finds exactly what a sequential scan finds';
  passed := v_state is null and v_only_idx is null and v_only_seq is null
        and coalesce(array_length(v_idx, 1), 0) > 0;
  detail := coalesce(v_state, format('%s group(s); only from the index: %s; only from the scan: %s',
    coalesce(array_length(v_idx, 1), 0), coalesce(v_only_idx, 'none'), coalesce(v_only_seq, 'none')));
  return next;

  -- 2
  v_cases := v_cases + 1;
  case_name := 'an entry naming neither a principal nor a mechanism is a finding; one that names a mechanism, and one older than the epoch, are not';
  passed := v_state is null and v_found = 'zzscan_blank, zzscan_silent'
        and v_groups = v_base + 2;
  detail := coalesce(v_state, format('found %s; %s group(s) against a baseline of %s',
    coalesce(v_found, 'nothing'), v_groups, v_base));
  return next;

  -- 3
  v_cases := v_cases + 1;
  case_name := 'the partial index whose predicate is the finding is usable for the reading that looks for it';
  passed := v_state is null and v_plan_a like '%audit_entry_unattributed_idx%';
  detail := coalesce(v_state, case when v_plan_a like '%audit_entry_unattributed_idx%'
    then 'the plan reads audit_entry_unattributed_idx'
    else 'the plan does not name it: ' || left(coalesce(v_plan_a, 'no plan'), 220) end);
  return next;

  -- 4
  v_cases := v_cases + 1;
  case_name := 'the attribution check still refuses the entries that say nothing, and names them';
  passed := v_state is null and v_unattr like 'CLOVEERP_AUDIT_UNATTRIBUTED%'
        and v_unattr like '%zzscan_silent%' and v_unattr like '%zzscan_blank%'
        and v_unattr not like '%zzscan_named%' and v_unattr not like '%zzscan_ancient%';
  detail := coalesce(v_state, left(coalesce(v_unattr, 'no answer'), 220));
  return next;

  -- 5
  v_cases := v_cases + 1;
  case_name := 'the words walked through the index are exactly the words the grouping found, since the epoch';
  passed := v_state is null and v_only_new is null and v_only_old is null and v_since >= 2;
  detail := coalesce(v_state, format('%s entr(ies) found; only new: %s; only old: %s',
    v_since, coalesce(v_only_new, 'none'), coalesce(v_only_old, 'none')));
  return next;

  -- 6
  v_cases := v_cases + 1;
  case_name := 'read from the beginning of time, over both tables, the two readings still agree and have more to find than since the epoch';
  passed := v_state is null and v_only_new_a is null and v_only_old_a is null
        and v_all > v_since;
  detail := coalesce(v_state, format('%s entr(ies) since the epoch, %s from the beginning; only new: %s; only old: %s',
    v_since, v_all, coalesce(v_only_new_a, 'none'), coalesce(v_only_old_a, 'none')));
  return next;

  -- 7
  v_cases := v_cases + 1;
  case_name := 'the walk reaches every distinct word in the trail, no more and none missing';
  passed := v_state is null and v_walk_only is null and v_dist_only is null;
  detail := coalesce(v_state, format('only walked: %s; only distinct: %s',
    coalesce(v_walk_only, 'none'), coalesce(v_dist_only, 'none')));
  return next;

  -- 8
  v_cases := v_cases + 1;
  case_name := 'the vocabulary check refuses both retired words written since the epoch, and leaves out the one written before it';
  passed := v_state is null
        and v_vocab like 'CLOVEERP_AUDIT_SOURCE_OUTSIDE_VOCABULARY%'
        and v_vocab like '%1 entr(ies) in erp.audit_entry carry the source "system"%'
        and v_vocab like '%1 entr(ies) in erp.audit_entry carry the source "api"%';
  detail := coalesce(v_state, left(coalesce(v_vocab, 'no answer'), 300));
  return next;

  -- 9
  v_cases := v_cases + 1;
  case_name := 'the two source indexes are usable for the step of the walk and for the probe, on the trail and on the event store';
  passed := v_state is null
        and v_plan_b like '%audit_entry_source_occurred_idx%'
        and v_plan_c like '%audit_entry_source_occurred_idx%'
        and v_plan_d like '%event_source_occurred_idx%';
  detail := coalesce(v_state, format('walk: %s; trail probe: %s; event probe: %s',
    case when v_plan_b like '%audit_entry_source_occurred_idx%' then 'indexed' else left(coalesce(v_plan_b, 'no plan'), 90) end,
    case when v_plan_c like '%audit_entry_source_occurred_idx%' then 'indexed' else left(coalesce(v_plan_c, 'no plan'), 90) end,
    case when v_plan_d like '%event_source_occurred_idx%' then 'indexed' else left(coalesce(v_plan_d, 'no plan'), 90) end));
  return next;

  -- 10
  v_cases := v_cases + 1;
  case_name := 'the check the deploy runs walks the words and no longer groups the trail, and the attribution sentence says what it judged';
  passed := v_state is null and v_new_shape = 1 and v_old_shape = 0
        and v_summary like 'audit attribution: every entry since %'
        and v_summary like '%the trail has reached entry %';
  detail := coalesce(v_state, format('walk anchors: %s, grouping anchors: %s; %s',
    v_new_shape, v_old_shape, left(coalesce(v_summary, 'no summary'), 130)));
  return next;

  -- 11
  select (select count(*) from erp.tenant t where t.code like 'zzscan-%')
       + (select count(*) from erp.audit_entry a where a.object_type like 'zzscan\_%')
    into v_left;

  v_cases := v_cases + 1;
  case_name := 'the fixtures were undone: no organisation and no entry the suite wrote is left behind';
  passed := v_left = 0;
  detail := case when v_state is null
                 then format('%s row(s) left behind; seven entries and one organisation rolled back', v_left)
                 else format('%s row(s) left behind, rolled back after %s', v_left, v_state) end;
  return next;

  -- The suite already knows what went wrong, so the count guard says it. A
  -- build log that reports only that the count is wrong costs another forty
  -- minutes to find out why.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_AUDIT_SCAN_SUITE_SHRANK: the suite produced % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere — a case was added or lost')
      using hint = 'The fixture behind the count is seven audit entries, of which two are '
                   'unattributed findings, two carry a retired word since the epoch, and '
                   'three are written to be left alone.';
  end if;
end;
$suite$;

revoke all on function erp_test.audit_scan_suite() from public, anon, authenticated;

comment on function erp_test.audit_scan_suite() is
  'The readings 20260921700000 replaced, kept verbatim and run beside the ones '
  'that replaced them: the same findings, on fixtures built to be found and '
  'fixtures built to be left alone, and the indexes named in the plans that '
  'the new shapes depend on.';

create or replace function erp_test.assert_audit_scan_suite()
returns text
language plpgsql
set search_path = ''
as $fn$
declare
  c_expected constant integer := 11;
  v_all    integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n')
           filter (where not coalesce(s.passed, false))
    into v_all, v_passed, v_detail
    from erp_test.audit_scan_suite() s;

  if v_all <> c_expected then
    raise exception 'CLOVEERP_AUDIT_SCAN_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. The fixture behind the count is seven audit '
                     'entries, of which two are unattributed findings and two carry a retired '
                     'word since the epoch; move the number deliberately.';
  end if;
  if v_passed <> v_all then
    raise exception E'CLOVEERP_AUDIT_SCAN_SUITE_FAILED: %/% case(s) failed\n%',
      v_all - v_passed, v_all, v_detail;
  end if;
  return format('audit scan: %s/%s cases passed', v_passed, v_all);
end;
$fn$;

revoke all on function erp_test.assert_audit_scan_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The build runs it, so this file does not
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.ci_check_catalogue() gathers every assert_% routine in erp and erp_test
-- that takes no arguments, and supabase/ci/run_checks.sh runs the catalogue on
-- every build. A suite that stands up its own organisation cannot be run from a
-- migration tail — 20260919010000, 20260920300000 and 20260921120000 are what
-- that costs — so what this file owes instead is the claim that something else
-- runs it.

do $covered$
declare
  v_check constant text := 'assert_audit_scan_suite';
  v_call  text;
begin
  select c.call into v_call
    from erp.ci_check_catalogue() c
   where c.schema_name = 'erp_test' and c.function_name = v_check;

  if v_call is null then
    raise exception
      'CLOVEERP_SUITE_NOT_IN_CATALOGUE: erp_test.%() is not in erp.ci_check_catalogue(), so nothing runs it', v_check
      using errcode = '23503',
            hint = 'The catalogue gathers assert_% routines in erp and erp_test that take '
                   'no arguments. Give it back that shape rather than calling it from a '
                   'migration.';
  end if;

  raise notice 'the build runs erp_test.%() from the catalogue as "%"', v_check, v_call;
end
$covered$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

-- The two this file rewrote, run on the database it rewrote them on, and the
-- register checks that would see a routine which had lost its governance or an
-- index the linter does not recognise. No suite is called from here; the
-- catalogue runs that.

select erp.assert_audit_attributed();
select erp.assert_audit_source_vocabulary();
select erp.assert_no_public_execute();
select erp.assert_invoker_doors_executable();
select erp.assert_public_api_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_linter_clean();
