set lock_timeout = '30s';

-- =============================================================================
-- 20260919900000  A journal line names a real event
-- -----------------------------------------------------------------------------
-- 0026_b7_finance.sql gave erp.journal and erp.journal_line a source_event_id
-- and no foreign key. Every other reference on those two tables has one —
-- entity, ledger, fiscal period, document, the journal a reversal reverses, the
-- account, the posting rule — and the one column that carries the ledger's
-- answer to "what caused this posting" does not.
--
-- What was already true, and why it was not enough
--
--   * erp.check_journal_line_posting() refuses a machine-generated line whose
--     source_event_id is null. That is presence, not existence: the column has
--     to be filled in, and nothing has ever asked whether what it names is
--     there. A line could carry gen_random_uuid() and pass.
--   * erp.event is registered tenant_scoped_append_only, so a delete is refused
--     for every role outside the one window a whole-tenant purge opens. That
--     protects the event from being removed; it says nothing about a pointer
--     that never resolved in the first place, and nothing about what happens
--     inside that window.
--   * erp.explain_posting() — the drill-down from a figure to the event that
--     produced it, spec 5.7 — is a left join. A pointer at nothing comes back
--     as a posting with a null payload and a null occurred_at: the trail simply
--     stops, and the screen shows a gap rather than a fault.
--
-- So the audit trail from a pound in the ledger back to the thing that moved it
-- was a convention every writer happened to keep, not a guarantee the database
-- made. This migration makes it the second.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What was swept before anything was built
--
-- A foreign key does not validate against a row that already points at nothing,
-- and a journal line is immutable financial record: the repair for an orphan is
-- never to delete the line or to blank the pointer. So section 1 counts them
-- first and refuses with the list, naming what to do. On an empty build it
-- finds nothing; on a database with organisations and a traded month in it, it
-- is the only thing standing between a real orphan and a constraint quietly
-- built over a hole.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Why RESTRICT, and why the tenant purge survives it
--
-- ON DELETE CASCADE would mean that removing an event removes the postings it
-- caused, which is the accident the key exists to prevent. ON DELETE SET NULL
-- would rewrite the line. RESTRICT is the only answer that keeps the record:
-- while a journal line names an event, that event stays.
--
-- Both sides hang off erp.tenant with ON DELETE CASCADE, so the question is
-- whether an organisation can still be erased. It can, for the same reason
-- erp.journal.entity_id has been ON DELETE RESTRICT against erp.entity since
-- 0026 and the hundred and forty-five tenant deletions in the suites have never
-- minded: deleting the tenant row queues every direct child's cascade first,
-- and the restrict check raised by a nested delete is appended behind them. The
-- journal lines are gone before anything asks whether they still point at an
-- event. Every table keyed here is a direct child of erp.tenant, which is the
-- condition that argument rests on.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- The siblings, and where the line is drawn
--
-- Nine uuid columns in the product schemas name a row of the event store or a
-- ledger line. Two are the pair above. One — erp.event_outbox.event_id — has
-- had a key since 0009. Five more had none:
--
--   erp.stock_movement.event_id          never written; the stock ledger's
--                                        provenance column, declared and empty
--   erp.notification.event_id            written on every routed notification
--                                        from the erp.event it announces
--   erp.command.causation_event_id       never written; "what caused this",
--                                        says the comment above it in 0030
--   erp.event_cursor.last_event_id       the consumer watermark
--   erp.tax_determination.journal_line_id  never written; the tax answer's
--                                        pointer at the posting that carries it
--
-- All five are keyed here. Four of them restrict nothing that was ever possible
-- — erp.event is append-only, and a column nothing writes has nothing to break
-- — which is exactly why this is the cheapest moment they will ever have.
--
-- The ninth, erp_meta.contract_notice.event_id, is left and registered with its
-- reason. It is the vendor console's record that a notice was raised, it has no
-- tenant_id, and it is not a child of erp.tenant: a RESTRICT there would make
-- erasing a customer organisation fail on the console's own reminder, and a
-- SET NULL would have the customer's erasure quietly edit a vendor record. It
-- crosses the boundary, so it is named in the register rather than keyed.
--
-- Deliberately out of scope, and said plainly rather than left silent: the
-- source_%_document_id family (erp.fixed_asset, erp.document_preview) is the
-- same shape but a different fact. A draft document is deletable by design, so
-- a key there would forbid something the product currently allows, and that is
-- a decision about documents rather than a repair to the ledger's provenance.
-- The polymorphic pointers — erp.audit_entry.object_id, erp.event.aggregate_id,
-- erp.command.source_object_id — have no single target and never can.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- So the next one cannot accumulate silently
--
-- erp.assert_provenance_pointers_resolve() is catalogue arithmetic, not a data
-- scan: every uuid column in the product schemas whose name ends in event_id or
-- journal_line_id must either carry a foreign key to the row it names, or be a
-- row in erp.provenance_pointer_register() with a written reason. A register
-- entry naming a column that does not exist, or one that has since been keyed,
-- fails too — a register that rots reports green over nothing.
-- =============================================================================


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The register: which column names which row, and which cannot
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.provenance_pointer_register()
returns table(schema_name text, table_name text, column_name text,
              target_schema text, target_table text, rationale text)
language sql
immutable
set search_path = ''
as $$
  select v.schema_name, v.table_name, v.column_name,
         v.target_schema, v.target_table, v.rationale
    from (values
      ('erp'::text, 'journal'::text, 'source_event_id'::text,
       'erp'::text, 'event'::text, null::text),
      ('erp', 'journal_line', 'source_event_id', 'erp', 'event', null),
      ('erp', 'event_outbox', 'event_id', 'erp', 'event', null),
      ('erp', 'stock_movement', 'event_id', 'erp', 'event', null),
      ('erp', 'notification', 'event_id', 'erp', 'event', null),
      ('erp', 'command', 'causation_event_id', 'erp', 'event', null),
      ('erp', 'event_cursor', 'last_event_id', 'erp', 'event', null),
      ('erp', 'tax_determination', 'journal_line_id', 'erp', 'journal_line', null),
      ('erp_meta', 'contract_notice', 'event_id', null, null,
       'The vendor console''s record that a notice was raised against a '
       'customer''s contract. It has no tenant_id and is not a child of '
       'erp.tenant, so a restricting key would make erasing that organisation '
       'fail on the console''s own reminder, and a nulling one would have the '
       'erasure edit a vendor record. The pointer crosses the boundary between '
       'the customer''s event store and the vendor''s books, and only one side '
       'of it is erased.')
    ) as v(schema_name, table_name, column_name, target_schema, target_table, rationale);
$$;

revoke all on function erp.provenance_pointer_register() from public, anon;

comment on function erp.provenance_pointer_register is
  'Every uuid column in the product schemas that names a row of the event store '
  'or a ledger line: the row it names, or — where no key is possible — the '
  'written reason. Read by erp.assert_provenance_pointers_resolve(), which '
  'refuses a column of that shape that is in neither state.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The report: what the catalogue says about each of them
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.provenance_pointer_report()
returns table(pointer text, target text, keyed boolean, exempt boolean, finding text)
language sql
stable
set search_path = ''
as $$
  with shaped as (
    select n.nspname::text as schema_name,
           c.relname::text as table_name,
           a.attname::text as column_name,
           c.oid            as relid,
           a.attnum         as attnum
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class c on c.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname in ('erp', 'erp_meta', 'erp_ref', 'erp_ai', 'erp_ingress')
       and c.relkind = 'r'
       and a.attnum > 0
       and not a.attisdropped
       and a.atttypid = 'pg_catalog.uuid'::regtype
       and a.attname ~ '(^|_)event_id$|(^|_)journal_line_id$'
  ),
  declared as (
    select r.*,
           (select s.relid  from shaped s
             where s.schema_name = r.schema_name and s.table_name = r.table_name
               and s.column_name = r.column_name) as relid,
           (select s.attnum from shaped s
             where s.schema_name = r.schema_name and s.table_name = r.table_name
               and s.column_name = r.column_name) as attnum
      from erp.provenance_pointer_register() r
  ),
  judged as (
    select d.schema_name || '.' || d.table_name || '.' || d.column_name as pointer,
           case when d.target_table is null then null
                else d.target_schema || '.' || d.target_table end as target,
           d.relid is not null as column_exists,
           d.rationale is not null as exempt,
           coalesce(d.relid is not null and exists (
             select 1
               from pg_catalog.pg_constraint k
              where k.conrelid = d.relid
                and k.contype = 'f'
                and d.attnum = any (k.conkey)
                and k.confrelid = (
                  select c2.oid from pg_catalog.pg_class c2
                    join pg_catalog.pg_namespace n2 on n2.oid = c2.relnamespace
                   where n2.nspname = d.target_schema and c2.relname = d.target_table)
           ), false) as keyed
      from declared d
  )
  select j.pointer, j.target, j.keyed, j.exempt,
         case
           when not j.column_exists
             then 'the register names a column that does not exist'
           when j.exempt and j.keyed
             then 'the register excuses a column that now carries a key; take the row out'
           when j.exempt
             then null
           when not j.keyed
             then 'a provenance pointer with no key: it may name a row that is not there'
         end
    from judged j
  union all
  select s.schema_name || '.' || s.table_name || '.' || s.column_name,
         null, false, false,
         'a column that names an event or a ledger line and is in no register: '
         'give it a foreign key, or a row in erp.provenance_pointer_register() '
         'saying why it cannot have one'
    from shaped s
   where not exists (
     select 1 from erp.provenance_pointer_register() r
      where r.schema_name = s.schema_name and r.table_name = s.table_name
        and r.column_name = s.column_name)
   order by 5 nulls last, 1;
$$;

revoke all on function erp.provenance_pointer_report() from public, anon;

comment on function erp.provenance_pointer_report is
  'Each column that names a row of the event store or a ledger line, with '
  'whether it carries a key, whether it is excused, and the finding when it is '
  'neither — or when the register has gone stale around it.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The sweep: does anything already point at nothing?
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Data, not catalogue, and the one part of this migration that has to be true
-- of a database with real money in it rather than of an empty build. It is a
-- report and not an assertion because an operator has to be able to ask the
-- question again afterwards, on a live database, without a deploy.

create or replace function erp.provenance_orphan_report()
returns table(pointer text, enforced boolean, pointing bigint, orphans bigint, sample uuid)
language sql
stable
set search_path = ''
as $$
  select 'erp.journal.source_event_id', true,
         count(*) filter (where j.source_event_id is not null),
         count(*) filter (where j.source_event_id is not null and e.id is null),
         min(j.source_event_id) filter (where j.source_event_id is not null and e.id is null)
    from erp.journal j
    left join erp.event e on e.tenant_id = j.tenant_id and e.id = j.source_event_id
  union all
  select 'erp.journal_line.source_event_id', true,
         count(*) filter (where l.source_event_id is not null),
         count(*) filter (where l.source_event_id is not null and e.id is null),
         min(l.source_event_id) filter (where l.source_event_id is not null and e.id is null)
    from erp.journal_line l
    left join erp.event e on e.tenant_id = l.tenant_id and e.id = l.source_event_id
  union all
  select 'erp.stock_movement.event_id', true,
         count(*) filter (where m.event_id is not null),
         count(*) filter (where m.event_id is not null and e.id is null),
         min(m.event_id) filter (where m.event_id is not null and e.id is null)
    from erp.stock_movement m
    left join erp.event e on e.tenant_id = m.tenant_id and e.id = m.event_id
  union all
  select 'erp.notification.event_id', true,
         count(*) filter (where nt.event_id is not null),
         count(*) filter (where nt.event_id is not null and e.id is null),
         min(nt.event_id) filter (where nt.event_id is not null and e.id is null)
    from erp.notification nt
    left join erp.event e on e.tenant_id = nt.tenant_id and e.id = nt.event_id
  union all
  select 'erp.command.causation_event_id', true,
         count(*) filter (where cm.causation_event_id is not null),
         count(*) filter (where cm.causation_event_id is not null and e.id is null),
         min(cm.causation_event_id) filter (where cm.causation_event_id is not null and e.id is null)
    from erp.command cm
    left join erp.event e on e.tenant_id = cm.tenant_id and e.id = cm.causation_event_id
  union all
  select 'erp.event_cursor.last_event_id', true,
         count(*) filter (where cu.last_event_id is not null),
         count(*) filter (where cu.last_event_id is not null and e.id is null),
         min(cu.last_event_id) filter (where cu.last_event_id is not null and e.id is null)
    from erp.event_cursor cu
    left join erp.event e on e.tenant_id = cu.tenant_id and e.id = cu.last_event_id
  union all
  select 'erp.tax_determination.journal_line_id', true,
         count(*) filter (where td.journal_line_id is not null),
         count(*) filter (where td.journal_line_id is not null and jl.id is null),
         min(td.journal_line_id) filter (where td.journal_line_id is not null and jl.id is null)
    from erp.tax_determination td
    left join erp.journal_line jl on jl.tenant_id = td.tenant_id and jl.id = td.journal_line_id
  union all
  -- Reported and not enforced: section 1 of this migration says why the console's
  -- notice cannot carry a key. Reporting it is what keeps "cannot" honest.
  select 'erp_meta.contract_notice.event_id', false,
         count(*) filter (where cn.event_id is not null),
         count(*) filter (where cn.event_id is not null and e.id is null),
         min(cn.event_id) filter (where cn.event_id is not null and e.id is null)
    from erp_meta.contract_notice cn
    left join erp.event e on e.id = cn.event_id;
$$;

revoke all on function erp.provenance_orphan_report() from public, anon;

comment on function erp.provenance_orphan_report is
  'Every provenance pointer with a target, how many rows carry one, and how many '
  'of those name a row that is not there. Zero on a database whose keys are in '
  'place; the one column that carries no key is reported rather than enforced.';

do $sweep$
declare
  v_findings text;
  v_total    bigint;
begin
  select string_agg(format('  %s: %s of %s row(s) name nothing, first %s',
                           r.pointer, r.orphans, r.pointing, r.sample), E'\n' order by r.pointer),
         sum(r.orphans)
    into v_findings, v_total
    from erp.provenance_orphan_report() r
   where r.enforced and r.orphans > 0;

  if v_total > 0 then
    raise exception
      E'CLOVEERP_PROVENANCE_ORPHANED: % pointer(s) name a row that is not there, so the keys below it cannot be built\n%',
      v_total, v_findings
      using errcode = '23503',
            hint = 'Do not delete the rows and do not blank the pointers: a journal line '
                   'is immutable financial record and an event is a fact. Take the list '
                   'above, find for each named row whether the event was lost or the '
                   'pointer was mistyped, and repair it forward — replay the missing '
                   'event with erp.append_event() under its own correlation, or raise a '
                   'correcting journal that names a real one and reverse the line that '
                   'does not. Then run this deploy again; erp.provenance_orphan_report() '
                   'answers the same question at any time afterwards.';
  end if;
end
$sweep$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The keys the references need
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Every tenant-scoped reference in this schema is written (tenant_id, thing) →
-- (tenant_id, id), so that a row of one organisation cannot name a row of
-- another however the query is written. erp.event and erp.journal_line are
-- referenced for the first time here and so need that key to point at.

do $keys$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'event_tenant_scoped_key'
       and conrelid = 'erp.event'::regclass)
  then
    alter table erp.event add constraint event_tenant_scoped_key unique (tenant_id, id);
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'journal_line_tenant_scoped_key'
       and conrelid = 'erp.journal_line'::regclass)
  then
    alter table erp.journal_line
      add constraint journal_line_tenant_scoped_key unique (tenant_id, id);
  end if;
end
$keys$;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The keys themselves
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Nullable on every one of them, and deliberately: a manual journal is the
-- stated exception in spec 4.7 — it carries a reason instead of an event, and
-- erp.check_journal_line_posting() has enforced that division since 0026. The
-- key says what a pointer must mean when there is one, not that there must be
-- one.

do $keys$
declare
  r record;
begin
  for r in
    select * from (values
      ('erp.journal',            'journal_source_event_fk',
       'foreign key (tenant_id, source_event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.journal_line',       'journal_line_source_event_fk',
       'foreign key (tenant_id, source_event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.stock_movement',     'stock_movement_event_fk',
       'foreign key (tenant_id, event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.notification',       'notification_event_fk',
       'foreign key (tenant_id, event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.command',            'command_causation_event_fk',
       'foreign key (tenant_id, causation_event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.event_cursor',       'event_cursor_last_event_fk',
       'foreign key (tenant_id, last_event_id) references erp.event (tenant_id, id) on delete restrict'),
      ('erp.tax_determination',  'tax_determination_journal_line_fk',
       'foreign key (tenant_id, journal_line_id) references erp.journal_line (tenant_id, id) on delete restrict')
    ) as v(relation, constraint_name, clause)
  loop
    if not exists (
      select 1 from pg_catalog.pg_constraint
       where conname = r.constraint_name
         and conrelid = r.relation::regclass)
    then
      execute format('alter table %s add constraint %I %s',
                     r.relation, r.constraint_name, r.clause);
    end if;
  end loop;
end
$keys$;

-- The reading side. A key gives the planner no index on the referencing column,
-- and RESTRICT has to answer "does anything still name this event" on every
-- delete that reaches the one window where a delete is possible. erp.journal
-- already carries the partial index it needs from 0026; the line did not.
create index if not exists journal_line_source_event_idx
  on erp.journal_line (tenant_id, source_event_id) where source_event_id is not null;

comment on constraint journal_line_source_event_fk on erp.journal_line is
  'Spec 4.7: every posting traces to the operational event that produced it. '
  'Restricting, because deleting an event must never take the postings it '
  'caused with it, and nullable, because a manual journal carries a reason '
  'instead.';


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The assertion
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_provenance_pointers_resolve()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count    integer;
  v_findings text;
  v_keyed    integer;
  v_exempt   integer;
begin
  select count(*), string_agg(format('  %s — %s', r.pointer, r.finding), E'\n' order by r.pointer)
    into v_count, v_findings
    from erp.provenance_pointer_report() r
   where r.finding is not null;

  if v_count > 0 then
    raise exception E'CLOVEERP_PROVENANCE_POINTER_UNGUARDED: % finding(s)\n%', v_count, v_findings
      using errcode = '23514',
            hint = 'A column that names an event or a ledger line must carry a foreign '
                   'key to it — restricting, so the row it names cannot be deleted from '
                   'under it. Where no key is possible, add the column to '
                   'erp.provenance_pointer_register() with the reason, and take the row '
                   'out again the day a key becomes possible.';
  end if;

  select count(*) filter (where r.keyed), count(*) filter (where r.exempt)
    into v_keyed, v_exempt
    from erp.provenance_pointer_report() r;

  return format('provenance: %s pointer(s) keyed to the row they name, %s excused with a reason',
                v_keyed, v_exempt);
end;
$$;

revoke all on function erp.assert_provenance_pointers_resolve() from public, anon;

comment on function erp.assert_provenance_pointers_resolve is
  'Every uuid column in the product schemas whose name ends in event_id or '
  'journal_line_id either carries a foreign key to the row it names or is in '
  'erp.provenance_pointer_register() with a written reason, and the register '
  'names nothing that has gone. Catalogue arithmetic: it reads no table data, '
  'because once the keys are there the data cannot disagree with them.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, function_name, arguments, detail_function, detail_arguments,
   blurb, runs_in_ci, seq) values
  ('provenance_pointers_resolve', 'Every provenance pointer names a real row',
   'assertion', 'platform', 'assert_provenance_pointers_resolve', '',
   'provenance_pointer_report', '',
   'The ledger''s trail back to what caused a posting is a key the database keeps, '
   'not a convention its writers happen to follow.', true, 46)
on conflict (code) do update
  set title = excluded.title, kind = excluded.kind, scope = excluded.scope,
      function_name = excluded.function_name, detail_function = excluded.detail_function,
      blurb = excluded.blurb, runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.provenance_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 9;
  v_cases   integer := 0;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_step    text := 'provisioning';
  v_state   text;
  v_msg     text;
  v_msg2    text;
  v_tenant  uuid;
  v_entity  uuid; v_ledger uuid; v_ccy char(3);
  v_bank    uuid; v_rev uuid;
  v_from    date := (date_trunc('month', current_date) - interval '13 months')::date;
  v_event   uuid;
  v_lonely  uuid;
  v_j       uuid;
  v_lines   bigint; v_orphans bigint;
  v_null_ok boolean;
  v_report  text;
  v_deleted boolean;
begin
  begin
    -- ── The fixture: a configured organisation and a slice of real trading ─
    v_step := 'an organisation configured as the demonstration is';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzprov-' || v_tag, 'Provenance Suite',
      'admin@zzprov-' || v_tag || '.test', 'Provenance Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzprov-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(v_tenant, rb.admin_user_id);

    v_step := 'the company, its ledger and two accounts to post between';
    select l.entity_id, l.id, l.currency into v_entity, v_ledger, v_ccy
      from erp.ledger l where l.tenant_id = v_tenant and l.is_primary order by l.code limit 1;
    select a.id into strict v_bank from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity and a.control_kind = 'bank'
       and a.status = 'active' and a.is_postable order by a.code limit 1;
    select a.id into strict v_rev from erp.account a
     where a.tenant_id = v_tenant and a.entity_id = v_entity
       and a.code = erp.tenant_account_code('revenue');

    v_step := 'a slice of trading through the spine';
    perform erp.seed_demo_history(v_from, null, 1);
    set constraints all immediate;

    -- ── 1. The real posting path produces provenance that resolves ──────────
    select count(*) filter (where l.source_event_id is not null),
           count(*) filter (where l.source_event_id is not null and e.id is null)
      into v_lines, v_orphans
      from erp.journal_line l
      join erp.journal j on j.id = l.journal_id
      left join erp.event e on e.tenant_id = l.tenant_id and e.id = l.source_event_id
     where l.tenant_id = v_tenant;

    v_cases := v_cases + 1;
    case_name := 'a slice of trading writes lines that name events, and every one of them is there';
    passed := v_state is null and v_lines > 10 and v_orphans = 0;
    detail := coalesce(v_state, format('%s line(s) name an event, %s of them name nothing',
                                       v_lines, v_orphans), 'no answer');
    return next;

    -- ── 2. A line naming an event that does not exist is refused ────────────
    -- On a manual journal, because that is the one shape the posting trigger
    -- lets through with a source event it has never checked: the key is the
    -- only thing standing between this insert and a pound with no cause.
    v_step := 'a manual journal line naming an event that was never appended';
    v_msg := null;
    begin
      insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                               description, status, manual_reason)
      values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPROV-GHOST', 'draft',
              'suite: a line that names an event nobody appended')
      returning id into v_j;
      begin
        insert into erp.journal_line (tenant_id, journal_id, line_no, account_id,
                                      debit_minor, credit_minor, currency,
                                      base_debit_minor, base_credit_minor, exchange_rate,
                                      source_event_id)
        values (v_tenant, v_j, 1, v_bank, 500, 0, v_ccy, 500, 0, 1, gen_random_uuid());
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'a journal line naming an event that does not exist is refused by the database';
    passed := v_state is null and coalesce(v_msg like '%journal_line_source_event_fk%', false);
    detail := coalesce(v_state, left(coalesce(v_msg, 'no refusal: the line was written'), 200), 'no answer');
    return next;

    -- ── 3. So is a journal header ──────────────────────────────────────────
    v_step := 'a journal header naming an event that was never appended';
    v_msg := null;
    begin
      insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, source_event_id,
                               posting_date, description, status, manual_reason)
      values (v_tenant, v_entity, v_ledger, 'manual', gen_random_uuid(), current_date,
              'ZZPROV-GHOST-HEAD', 'draft', 'suite: a journal that names an event nobody appended');
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'and so is a journal header naming one';
    passed := v_state is null and coalesce(v_msg like '%journal_source_event_fk%', false);
    detail := coalesce(v_state, left(coalesce(v_msg, 'no refusal: the journal was written'), 200), 'no answer');
    return next;

    -- ── 4. A manual line may still name no event at all ────────────────────
    v_step := 'a manual journal that names no event, which spec 4.7 allows';
    v_null_ok := false;
    begin
      insert into erp.journal (tenant_id, entity_id, ledger_id, source_code, posting_date,
                               description, status, manual_reason)
      values (v_tenant, v_entity, v_ledger, 'manual', current_date, 'ZZPROV-MANUAL', 'draft',
              'suite: a correction posted by hand, with a reason and no event')
      returning id into v_j;
      insert into erp.journal_line (tenant_id, journal_id, line_no, account_id,
                                    debit_minor, credit_minor, currency,
                                    base_debit_minor, base_credit_minor, exchange_rate)
      values (v_tenant, v_j, 1, v_bank, 500, 0, v_ccy, 500, 0, 1),
             (v_tenant, v_j, 2, v_rev, 0, 500, v_ccy, 0, 500, 1);
      update erp.journal set status = 'posted', posted_at = now(),
                             posted_by = erp.current_principal_id() where id = v_j;
      set constraints all immediate;
      v_null_ok := (select count(*) from erp.journal_line l
                     where l.journal_id = v_j and l.source_event_id is null) = 2;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := sqlerrm; end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'a manual journal still posts with no event at all, which is what the key being nullable is for';
    passed := v_state is null and v_null_ok;
    detail := coalesce(v_state, case when v_null_ok
                                     then 'two lines posted by hand naming no event, and a reason on the journal'
                                     else 'a manual journal could not post without an event' end, 'no answer');
    return next;

    -- ── 5. The event behind a line cannot be deleted ────────────────────────
    -- erp.event is append-only, so the only window in which a delete is
    -- possible at all is the one a whole-tenant purge opens. The case is in
    -- that window deliberately: outside it the append-only guard would refuse
    -- first and would prove nothing about the reference.
    v_step := 'the event behind a posted line, deleted inside the purge window';
    select l.source_event_id into v_event
      from erp.journal_line l
     where l.tenant_id = v_tenant and l.source_event_id is not null
     order by l.source_event_id limit 1;
    v_msg := null;
    begin
      perform set_config('request.jwt.claims', '', true);
      perform erp.begin_tenant_purge(v_tenant);
      begin
        delete from erp.event where id = v_event;
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;
    perform erp.end_tenant_purge();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'the event behind a posted line cannot be deleted, even in the one window where a delete is possible';
    -- Either key may be the one that raises: the line names the event and so
    -- does the journal above it, and nothing orders the two checks.
    passed := v_state is null and v_event is not null
          and coalesce(v_msg like '%source_event_fk%', false);
    detail := coalesce(v_state, left(coalesce(v_msg, 'no refusal: the event was deleted'), 200), 'no answer');
    return next;

    -- ── 6. And an event with nothing behind it still can ────────────────────
    -- Otherwise case 5 proves only that the window is shut, not that the ledger
    -- is what holds the event.
    v_step := 'an event nothing points at, deleted in the same window';
    v_msg2 := null;
    v_deleted := false;
    begin
      v_lonely := erp.append_event('document.posted', 'document', gen_random_uuid(),
        jsonb_build_object('document_number', 'ZZPROV-LONELY', 'posting_rule', 'manual',
                           'value_minor', 0, 'currency', v_ccy),
        v_entity, null);
      perform set_config('request.jwt.claims', '', true);
      perform erp.begin_tenant_purge(v_tenant);
      begin
        delete from erp.event where id = v_lonely;
        v_deleted := not exists (select 1 from erp.event e where e.id = v_lonely);
      exception when others then v_msg2 := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg2 := coalesce(v_msg2, sqlerrm); end if;
    end;
    perform erp.end_tenant_purge();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_cases := v_cases + 1;
    case_name := 'an event nothing points at is still removable in that window, so what refuses above is the ledger and not the door';
    passed := v_state is null and v_deleted;
    detail := coalesce(v_state, case when v_deleted then 'the lonely event went; the one behind a line did not'
                                     else left(coalesce(v_msg2, 'it did not go and said nothing'), 200) end, 'no answer');
    return next;

    -- ── 7. The assertion is not vacuous ────────────────────────────────────
    v_step := 'the key dropped, to see whether the assertion notices';
    v_msg := null;
    begin
      alter table erp.journal_line drop constraint journal_line_source_event_fk;
      begin
        perform erp.assert_provenance_pointers_resolve();
      exception when others then v_msg := sqlerrm;
      end;
      raise exception 'CLOVEERP_SUITE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
    end;

    v_cases := v_cases + 1;
    case_name := 'take the key off the line and the assertion refuses by name, so it is checking and not merely passing';
    passed := v_state is null
          and coalesce(v_msg like 'CLOVEERP_PROVENANCE_POINTER_UNGUARDED:%', false)
          and coalesce(v_msg like '%erp.journal_line.source_event_id%', false);
    detail := coalesce(v_state, left(coalesce(v_msg, 'the assertion passed over a pointer with no key'), 240), 'no answer');
    return next;

    -- ── 8. Every pointer of that shape is accounted for ────────────────────
    v_step := 'the whole census, keyed or excused';
    v_report := erp.assert_provenance_pointers_resolve();

    v_cases := v_cases + 1;
    case_name := 'every column that names an event or a ledger line is keyed to it, or registered with the reason it cannot be';
    passed := v_state is null
          and coalesce(v_report like 'provenance: 8 pointer(s) keyed%', false)
          and (select count(*) from erp.provenance_pointer_report() r where r.finding is not null) = 0
          and (select count(*) from erp.provenance_pointer_report() r where r.exempt and r.finding is null) = 1;
    detail := coalesce(v_state, v_report, 'no answer');
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzprov-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'zzprov rolled back with its trading, its journals and its events');
  return next;

  -- The count guard says what stopped the fixture, so the message this suite
  -- caught — and the step that produced it — reaches the build log rather than
  -- costing a whole build to find again.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_PROVENANCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %; the last refusal it caught was %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost'),
      coalesce(left(v_msg, 200), 'none')
      using detail = coalesce(v_state, v_msg, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.provenance_suite() from public, anon;

comment on function erp_test.provenance_suite() is
  'The ledger''s trail back to what caused it, proved and falsified. A slice of '
  'trading writes lines that name events and every one of them is there; a line '
  'and a journal naming an event nobody appended are both refused by name; a '
  'manual journal still posts naming no event at all; the event behind a posted '
  'line cannot be deleted even inside a tenant purge, while one with nothing '
  'behind it still can. Then the key is dropped to prove the assertion notices, '
  'and the whole census is counted. Rolls back everything it made.';

create or replace function erp_test.assert_provenance_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 9;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _provenance on commit drop as
    select * from erp_test.provenance_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _provenance;
  drop table _provenance;
  if v_fail > 0 then
    raise exception E'CLOVEERP_PROVENANCE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_PROVENANCE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a journal line names a real event: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_provenance_suite() from public, anon;


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two unique constraints and seven foreign keys are new on six tables, so the
-- generators are re-run and the assertions that read what they emit follow:
-- append-only guards and audit coverage are keyed off erp_meta.table_policy and
-- not off a table's constraints, and this proves nothing else moved with them.

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_governed_views_are_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();

-- The new one, against the database this migration just changed.
select erp.assert_provenance_pointers_resolve();
select erp_test.assert_provenance_suite();

-- The ledger, read the way the keys now bind it. If a posted month does not
-- reconcile after seven new references, this migration does not land.
select erp.assert_whole_database_reconciles();
