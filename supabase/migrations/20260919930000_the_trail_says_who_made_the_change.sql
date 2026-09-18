-- ─────────────────────────────────────────────────────────────────────────────
-- The trail says who made the change.
--
-- "Every action audited" is one of the three claims on the marketing site, and
-- erp.audit_entry carries a `source` column to make it mean something: which
-- entry point caused the change. It has never meant anything.
--
-- The column is filled from a session setting, erp.source, which nothing in
-- this repository sets. Counted over the installed routine bodies rather than
-- the migration text: erp.source is read in four places by three routines —
-- erp.audit_row_change(), erp.audit_read() and erp.append_event() — and
-- written in none. Every other context setting this product reads is written
-- by something: erp.job_tenant_id 25 reads against 132 writes,
-- erp.job_principal_id 5 against 25, erp.purge_tenant_id 9 against 14,
-- erp.promotion_id, erp.ledger_write, erp.correlation_id, the rest. One
-- setting, alone, is read by three writers of the record of record and set by
-- nobody.
--
-- So the coalesce always falls through, and the live distribution of
-- erp.audit_entry.source is two values, neither of them a fact:
--
--   'api'     — every row with an acting principal. Nobody called an API.
--   'system'  — every row without one, since 20260904910000, where the trigger
--               overwrote the fallback with a second fallback.
--
-- Which is to say: a change a person made on a screen, a change the dispatch
-- worker made draining a queue, a change an Edge Function made on a trusted
-- connection, a change the deploy made replaying a migration and a change an
-- operator made from a runbook are indistinguishable in the audit trail. The
-- column looks like evidence and is decoration. An auditor asking "did a
-- person do this, or did a machine?" gets 'api' either way.
--
-- 'system' deserves its own note, because it is the worse of the two. It was
-- written to be honest — a change with no principal is not an API call — but
-- it is the audit trigger inventing an origin the session never stated. The
-- mechanism behind such a change is already recorded, properly, in
-- actor_label ('system: erp.provision_tenant'), read from the PL/pgSQL call
-- stack. Saying it again in the source column, in a word that looks like a
-- real entry point, buys nothing and costs the column its meaning.
--
-- This migration closes it:
--
--   1. The vocabulary is a table. erp_ref.audit_source holds the small closed
--      set of entry points this product actually has, and a foreign key from
--      erp.audit_entry.source to it means a word outside the set is refused by
--      the database rather than by a convention. NOT VALID, because the
--      column is append-only and the history cannot be corrected — an audit
--      trail that can be rewritten to agree with a later rule is not one.
--
--   2. The declaration is at the entry point, not at the trigger. The trigger
--      can only record what the session tells it; a trigger that guesses is
--      how this defect was written in the first place. erp.declare_source()
--      is called where a session begins: erp.authorise() for a request
--      carrying a person's token, and worker/src/core/db.ts for the worker and
--      the Edge Functions, which share one connection helper.
--
--   3. The default is honest. A session that declares nothing gets
--      'undeclared' — a word a person reading the trail understands as "this
--      record does not know", not a word that looks like an answer. Nothing
--      may declare it: it is what the absence of a declaration looks like.
--
--   4. The class is closed, not the instance. "A setting that is read and
--      never written" is the shape of this defect, and it is checkable
--      statically: erp.assert_settings_are_written() refuses any erp.* GUC
--      that some installed routine reads and no installed routine writes. It
--      would have refused this build the day erp.source was written. It is the
--      check that matters more than the column.
--
-- What this migration deliberately does not do, so the trail is not half set:
-- the deploy, the operator runbooks and the seed scripts still declare
-- nothing, and their changes therefore record 'undeclared'. All three drive
-- the database from psql statement by statement, outside any transaction this
-- product controls, and erp.declare_source() writes transaction-locally on
-- purpose — every sibling context setting does, and
-- erp.assert_session_context_hygiene() exists to keep it that way (a session
-- -scoped setting outlives the request under a transaction-mode pooler and is
-- inherited by whoever the connection serves next). Declaring them needs the
-- connection itself to carry the setting, which is a change to how migrations
-- are applied, not a change to the schema. So rather than leave that silent,
-- erp_meta.audit_source_entry_point names every entry point the product has
-- and says which of them declare and which do not: the trail says which paths
-- declare, which is the only honest way to have a column set on some paths.
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The vocabulary
-- ═════════════════════════════════════════════════════════════════════════════

create table if not exists erp_ref.audit_source (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  name        text not null check (length(btrim(name)) > 0),
  description text not null check (length(btrim(description)) > 0),
  -- False for a word the trail used before there was a vocabulary. It stays in
  -- the table so the report can name what the history says instead of calling
  -- it unknown; nothing may declare it again.
  is_current  boolean not null default true,
  seq         integer not null
);

comment on table erp_ref.audit_source is
  'The closed set of entry points a change to this database can come through, '
  'and the words erp.audit_entry.source is allowed to hold. A word outside it '
  'is refused by foreign key, so a new source cannot be invented by typo.';

select erp_meta.register_table('erp_ref', 'audit_source', 'product_content',
  'The entry points a change can come through. erp.audit_entry.source and '
  'erp.event.source are foreign-keyed to it.');

insert into erp_ref.audit_source (code, name, description, is_current, seq) values
  ('screen', 'A person working in the application',
   'A request that arrived carrying a person''s sign-in token and passed a '
   'permission gate. Somebody was looking at a screen when this happened.',
   true, 10),
  ('public_door', 'A member of the public',
   'The unauthenticated public ingress — the enquiry form. Nobody signed in; '
   'the door itself is the only thing that vouched for the request.',
   true, 20),
  ('dispatch_worker', 'The dispatch worker',
   'The worker process draining the job, command and email queues. No person '
   'was present; the work was due.',
   true, 30),
  ('edge_function', 'An Edge Function',
   'One of the functions Supabase runs at the edge — dispatch, invite, the '
   'Resend webhook — on a trusted connection with no organisation context of '
   'its own, which declares its tenant per transaction.',
   true, 40),
  ('undeclared', 'Nothing declared it',
   'The session that made this change said nothing about what it was. This is '
   'not an entry point: it is the record admitting it does not know, and it is '
   'what the deploy, the operator runbooks and the seed scripts still record. '
   'Nothing may declare it.',
   true, 90),
  ('api', 'An API call (retired)',
   'What every audited change said until 20260919930000, because the setting '
   'the trigger read was never set by anything. It named no entry point and '
   'distinguished nothing. Kept so the history can be read; never written again.',
   false, 900),
  ('system', 'The system (retired)',
   'What a change with no acting principal said between 20260904910000 and '
   '20260919930000. The mechanism behind such a change is recorded in '
   'actor_label, read from the call stack; repeating it here as though it were '
   'an entry point is what cost the column its meaning. Never written again.',
   false, 910)
on conflict (code) do update set
  name = excluded.name, description = excluded.description,
  is_current = excluded.is_current, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The entry points, and which of them declare
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A column set on some paths and not others is worse than one nobody trusts,
-- unless the trail itself says which paths declare. This is that register. It
-- is the first thing to read when a row says 'undeclared': the question is not
-- "what went wrong" but "which entry point was it, and has it been taught to
-- say so yet".

create table if not exists erp_meta.audit_source_entry_point (
  entry_point text primary key check (length(btrim(entry_point)) > 0),
  records     text not null references erp_ref.audit_source (code),
  declares    boolean not null,
  -- Where in the product the declaration is made, or null when none is.
  declared_at text,
  note        text not null check (length(btrim(note)) >= 40),
  constraint audit_source_entry_point_declaration
    check (declares = (declared_at is not null))
);

comment on table erp_meta.audit_source_entry_point is
  'Every way a change reaches this database, the source it records, and '
  'whether it declares that source or falls through to undeclared. Written so '
  'a reader of the audit trail can tell "the entry point does not say" from '
  '"the entry point said nothing happened".';

select erp_meta.register_table('erp_meta', 'audit_source_entry_point',
  'platform_internal',
  'The entry points a change can arrive through and whether each declares its '
  'source. Not tenant data.');

insert into erp_meta.audit_source_entry_point
  (entry_point, records, declares, declared_at, note) values
  ('a person working in the application', 'screen', true, 'erp.authorise()',
   'Every public write door asks erp.authorise() before it changes anything, '
   'and a request carrying a sign-in token can be nothing but the product''s '
   'own screen. Declared at the gate rather than in each of the doors, because '
   'a declaration repeated in forty places is a declaration forty places can '
   'forget.'),
  ('the public enquiry ingress', 'public_door', true,
   'supabase/functions/enquiry/index.ts, through connect()',
   'The one door that serves somebody who has not signed in. It reduces its '
   'own privilege with SET LOCAL ROLE inside a transaction, and declares its '
   'source in the same transaction, before the role changes.'),
  ('the dispatch worker', 'dispatch_worker', true,
   'worker/src/core/db.ts, through connect()',
   'The worker names itself once, where it opens its connection, and every '
   'unit of work it does declares that source as the first statement of its '
   'own transaction — the same place it declares its tenant.'),
  ('an Edge Function', 'edge_function', true,
   'worker/src/core/db.ts, through connect()',
   'dispatch, invite and the Resend webhook share the worker''s connection '
   'helper, so they declare through the same code path. An Edge Function has '
   'no organisation context of its own and resolves a tenant per transaction, '
   'which is why the declaration is transaction-local too. The two statements '
   'that do not declare are the vault reads dispatch and the webhook make '
   'before the caller has proved anything; they change nothing and are '
   'audited by nothing.'),
  ('the deploy replaying migrations', 'undeclared', false, null,
   'Does not declare. .github/workflows/deploy.yml applies migrations with '
   '`supabase db push`, which runs each file in a transaction this product '
   'does not open and cannot inject a statement into. Teaching it to declare '
   'means carrying the setting on the connection itself, which is a change to '
   'how migrations are applied. Its changes carry the mechanism in actor_label '
   'and the release in erp.release_report() instead.'),
  ('an operator running a routine from supabase/ops', 'undeclared', false, null,
   'Does not declare. The runbooks are psql scripts that mostly run statement '
   'by statement outside an explicit transaction, so a transaction-local '
   'declaration would not survive to the write it is meant to label. Same '
   'remedy as the deploy: the connection would have to carry it.'),
  ('seed and demonstration data', 'undeclared', false, null,
   'Does not declare. supabase/ci/seed_demo.sql and the demonstration builders '
   'run inside provisioning, which has no session of its own to declare from; '
   'the mechanism is on the row already, in actor_label, read from the call '
   'stack by erp.audit_row_change().')
on conflict (entry_point) do update set
  records = excluded.records, declares = excluded.declares,
  declared_at = excluded.declared_at, note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. Reading and declaring the source
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.current_source()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(nullif(current_setting('erp.source', true), ''), 'undeclared')
$$;

comment on function erp.current_source() is
  'The entry point this session declared itself to be, or ''undeclared'' when '
  'it declared nothing. The single reader of the erp.source setting: three '
  'routines used to read it separately and each carried its own fallback, '
  'which is how two different fallbacks ended up in the same column.';

create or replace function erp.declare_source(p_source text)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_row erp_ref.audit_source%rowtype;
begin
  select * into v_row from erp_ref.audit_source s where s.code = p_source;

  if not found or not v_row.is_current then
    raise exception
      'CLOVEERP_UNKNOWN_AUDIT_SOURCE: % is not an entry point this product has',
      coalesce(p_source, '(null)')
      using errcode = '23503',
            hint = 'Declare one of the words in erp_ref.audit_source. A new '
                   'entry point is a row in that table, added by a migration, '
                   'before any code declares it.';
  end if;

  if p_source = 'undeclared' then
    raise exception
      'CLOVEERP_UNDECLARABLE_AUDIT_SOURCE: undeclared is what the trail says '
      'when nothing declared anything, so nothing may declare it'
      using errcode = '22023',
            hint = 'Declare the entry point this session actually is, or '
                   'declare nothing and the trail records undeclared by '
                   'itself.';
  end if;

  -- A session that does not bypass row security arrived through PostgREST, and
  -- the only thing it can be is the product's own screen. Letting it say
  -- otherwise would put the forgery inside the audit trail rather than keep it
  -- out, which is the one place a forgery must not be able to reach.
  if p_source <> 'screen' and not erp.session_is_trusted() then
    raise exception
      'CLOVEERP_AUDIT_SOURCE_NOT_YOURS: a session on this connection may '
      'declare itself the screen and nothing else, not %', p_source
      using errcode = '42501',
            hint = 'The worker, the Edge Functions and the deploy declare from '
                   'a trusted connection. From the application, let '
                   'erp.authorise() declare the screen.';
  end if;

  -- Transaction-local, like every other context setting this product carries:
  -- a session-scoped one outlives the request under a transaction-mode pooler
  -- and mislabels whatever that connection serves next.
  perform set_config('erp.source', p_source, true);
end;
$$;

comment on function erp.declare_source(text) is
  'Says which entry point this transaction is, for the audit trail to record. '
  'Refuses a word outside erp_ref.audit_source, refuses the ''undeclared'' '
  'default, and refuses any word but ''screen'' from an untrusted session.';

revoke all on function erp.current_source() from public, anon;
revoke all on function erp.declare_source(text) from public, anon;

select erp.register_refusal(
  'CLOVEERP_UNKNOWN_AUDIT_SOURCE',
  'Declaring the audit trail''s source to be an entry point this product does not have.',
  'The source column on the audit trail says which entry point caused a change — a person on a screen, the dispatch worker, an Edge Function. It is a closed vocabulary held in erp_ref.audit_source and enforced by a foreign key, because a column filled from free text is a column where one typo becomes a source nobody can account for and nobody notices. That is how the column spent its first fortnight saying nothing: it read a setting nothing wrote.',
  'Use one of the entry points listed in erp_ref.audit_source. If this really is a new way into the database, add it to that table in a migration first, with the entry point that declares it.');

select erp.register_refusal(
  'CLOVEERP_UNDECLARABLE_AUDIT_SOURCE',
  'Declaring a change''s source to be "undeclared".',
  'Undeclared is not an entry point. It is what the audit trail records when the session that made a change said nothing about what it was, and it is deliberately a word a person reading the trail understands as "this record does not know". A session that declares it is claiming to be an absence, which would make the one honest value in the column indistinguishable from a chosen one.',
  'Declare the entry point this session actually is, or declare nothing at all — the trail records undeclared by itself.');

select erp.register_refusal(
  'CLOVEERP_AUDIT_SOURCE_NOT_YOURS',
  'A session reached through the application declaring itself to be the worker, an Edge Function or another trusted entry point.',
  'A request that arrives over the application''s connection is the application, whatever it says. If such a session could name itself the dispatch worker, an audit trail would record a person''s change as a machine''s, and the one record the product asks an auditor to trust would be the one record anybody could forge. Trusted entry points declare from a connection that bypasses row security; the application''s does not.',
  'Nothing to do from the application: erp.authorise() declares the screen at the gate. If this is a backend job, connect as a trusted role and declare there.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The declaration where a request from a person begins
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.authorise() is the gate forty public write doors ask before they change
-- anything, and it is the first thing a request from the application reaches
-- inside the database. That makes it the beginning of that entry point's
-- session, and the right place for it to say what it is. Declaring in each
-- door instead would be forty declarations, thirty-nine of which would survive
-- the next door being written and one of which would not.
--
-- What is already declared wins: the worker and the Edge Functions declare
-- before any of their work, and a trusted session that has named itself knows
-- better than a gate does.

do $authorise$
declare
  v_def text := pg_get_functiondef('erp.authorise(text,uuid,uuid,text,text,uuid,uuid)'::regprocedure);
  v_old text := $p$  v_mutates boolean;
begin
  if erp.is_platform_owner() then$p$;
  v_new text := $q$  v_mutates boolean;
begin
  -- The entry point says what it is before anything it does is recorded. A
  -- request carrying a person's token is the product's own screen and can be
  -- nothing else; the worker, the Edge Functions and any other trusted caller
  -- declare at the start of their own transaction, and what they declared
  -- stands (20260919930000).
  if erp.current_source() = 'undeclared' and (select auth.uid()) is not null then
    perform erp.declare_source('screen');
  end if;

  if erp.is_platform_owner() then$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.authorise() does not open where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$authorise$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The three readers become one
-- ═════════════════════════════════════════════════════════════════════════════

do $readers$
declare
  v_trig text := pg_get_functiondef('erp.audit_row_change()'::regprocedure);
  v_read text := pg_get_functiondef('erp.audit_read(text,uuid,text,text,uuid,uuid)'::regprocedure);
  v_evt  text := pg_get_functiondef(
    'erp.append_event(text,text,uuid,jsonb,uuid,uuid,timestamptz,integer,integer,uuid,text)'::regprocedure);

  t_old1 text := $p$  v_source := coalesce(nullif(current_setting('erp.source', true), ''), 'api');$p$;
  t_new1 text := $q$  v_source := erp.current_source();$q$;

  t_old2 text := $p$    -- And the source says the mechanism too, rather than claiming an API call
    -- nobody made. An explicitly set erp.source still wins: a caller that has
    -- said what it is knows better than this does.
    if nullif(current_setting('erp.source', true), '') is null then
      v_source := 'system';
    end if;$p$;
  t_new2 text := $q$    -- The source is not touched here. Which entry point ran is a fact about
    -- the session, and a trigger that invents one when the session said
    -- nothing is exactly how this column came to say 'api' for work no API
    -- made. The mechanism is already on the row, in actor_label above, read
    -- from the call stack; the source stays whatever the session declared, or
    -- 'undeclared' when it declared nothing (20260919930000).$q$;

  r_old text := $p$    coalesce(nullif(current_setting('erp.source', true), ''), 'api'));$p$;
  r_new text := $q$    erp.current_source());$q$;

  e_old text := $p$    coalesce(p_source, nullif(current_setting('erp.source', true), ''), 'api'))$p$;
  e_new text := $q$    coalesce(p_source, erp.current_source()))$q$;
begin
  if (length(v_trig) - length(replace(v_trig, t_old1, ''))) / length(t_old1) <> 1
     or (length(v_trig) - length(replace(v_trig, t_old2, ''))) / length(t_old2) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.audit_row_change() does not read erp.source where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  if (length(v_read) - length(replace(v_read, r_old, ''))) / length(r_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.audit_read() does not read erp.source where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  if (length(v_evt) - length(replace(v_evt, e_old, ''))) / length(e_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.append_event() does not read erp.source where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;

  execute replace(replace(v_trig, t_old1, t_new1), t_old2, t_new2);
  execute replace(v_read, r_old, r_new);
  execute replace(v_evt, e_old, e_new);
end
$readers$;

-- The new setting joins the ones that may never be written session-wide. It is
-- not a security context — a leaked source mislabels rather than exposes — but
-- it is inherited by the next request on a pooled connection exactly the same
-- way, and a mislabelled audit trail is the thing this migration exists to
-- stop.
do $hygiene$
declare
  v_def text := pg_get_functiondef('erp.session_context_hygiene_report()'::regprocedure);
  v_old text := $p$|correlation_id|ledger_write)''$p$;
  v_new text := $q$|correlation_id|ledger_write|source)''$q$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_PATCH_UNRECOGNISED: erp.session_context_hygiene_report() does not list the context settings where this migration expects'
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
end
$hygiene$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The default stops lying, and the vocabulary becomes a constraint
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.audit_entry alter column source set default 'undeclared';
alter table erp.event       alter column source set default 'undeclared';

-- NOT VALID, and never validated. erp.audit_entry is append-only for every
-- role including the owner, so the rows already written cannot be corrected —
-- and correcting them would be the same fault as the one being repaired: an
-- origin invented after the fact. The constraint governs what is written from
-- here; the history is read through erp.audit_source_report(), which names the
-- two retired words rather than pretending they were entry points.
alter table erp.audit_entry drop constraint if exists audit_entry_source_known;
alter table erp.audit_entry
  add constraint audit_entry_source_known
  foreign key (source) references erp_ref.audit_source (code) not valid;

alter table erp.event drop constraint if exists event_source_known;
alter table erp.event
  add constraint event_source_known
  foreign key (source) references erp_ref.audit_source (code) not valid;

-- When the vocabulary started. Written with clock_timestamp() rather than the
-- transaction's now(), and written here rather than beside the table, so it is
-- after the patches above: an entry this migration's own earlier statements
-- produced is history, not a judgement of the new rule.
create table if not exists erp_meta.audit_source_epoch (
  only_row    boolean primary key default true check (only_row),
  started_at  timestamptz not null default now()
);

insert into erp_meta.audit_source_epoch (only_row, started_at)
values (true, clock_timestamp())
on conflict (only_row) do nothing;

comment on table erp_meta.audit_source_epoch is
  'When erp.audit_entry.source stopped being filled from a setting nothing '
  'wrote. erp.assert_audit_source_vocabulary() judges entries from this '
  'instant on; earlier ones are append-only and say ''api'' or ''system''.';

select erp_meta.register_table('erp_meta', 'audit_source_epoch',
  'platform_internal',
  'One row, recording when the audit source vocabulary began. Not tenant data.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. What an operator reads
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.audit_source_report()
returns table (stream text, source text, meaning text, is_current boolean,
               entries bigint, since_the_vocabulary bigint,
               first_seen timestamptz, last_seen timestamptz)
language sql
stable
set search_path = ''
as $$
  with epoch as (select e.started_at from erp_meta.audit_source_epoch e)
  select 'audit'::text, a.source,
         coalesce(s.name, 'not a word this product has'),
         coalesce(s.is_current, false),
         count(*),
         count(*) filter (where a.occurred_at >= (select started_at from epoch)),
         min(a.occurred_at), max(a.occurred_at)
    from erp.audit_entry a
    left join erp_ref.audit_source s on s.code = a.source
   group by a.source, s.name, s.is_current
  union all
  select 'event'::text, v.source,
         coalesce(s.name, 'not a word this product has'),
         coalesce(s.is_current, false),
         count(*),
         count(*) filter (where v.occurred_at >= (select started_at from epoch)),
         min(v.occurred_at), max(v.occurred_at)
    from erp.event v
    left join erp_ref.audit_source s on s.code = v.source
   group by v.source, s.name, s.is_current
   order by 1, 5 desc, 2
$$;

comment on function erp.audit_source_report() is
  'The spread of the audit trail and the event store by the entry point each '
  'change came through, with how many arrived since the vocabulary existed. '
  'The one place to see how much of the trail can still say only ''api''.';

create or replace function erp.undeclared_entry_point_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'an entry point does not declare its source',
         e.entry_point,
         e.note
    from erp_meta.audit_source_entry_point e
   where not e.declares
   order by 2
$$;

comment on function erp.undeclared_entry_point_report() is
  'The ways into this database that still record ''undeclared''. Not a '
  'failure: a register, so that a reader of the audit trail can tell which '
  'silences are known and accounted for.';

revoke all on function erp.audit_source_report() from public, anon, authenticated;
revoke all on function erp.undeclared_entry_point_report() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. The vocabulary, asserted
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_audit_source_vocabulary()
returns text
language plpgsql
stable
set search_path = ''
as $$
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

  -- 3. A source nothing ever writes is the defect this migration exists to
  --    close, so the vocabulary may not grow one. Every current word but the
  --    default is declared by a named entry point.
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
  for r in
    select 'erp.audit_entry' as rel, a.source, count(*) as n
      from erp.audit_entry a
     where a.occurred_at >= v_epoch
       and a.source not in (select s.code from erp_ref.audit_source s where s.is_current)
     group by a.source
    union all
    select 'erp.event', v.source, count(*)
      from erp.event v
     where v.occurred_at >= v_epoch
       and v.source not in (select s.code from erp_ref.audit_source s where s.is_current)
     group by v.source
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
$$;

comment on function erp.assert_audit_source_vocabulary is
  'The source on an audited change names an entry point this product has. The '
  'vocabulary is foreign-keyed, the honest default exists, every word in it is '
  'declared by something, and nothing written since it existed falls outside '
  'it. Dated, because the history says ''api'' and cannot be rewritten.';

revoke all on function erp.assert_audit_source_vocabulary() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. The class: a setting that is read and never written
-- ═════════════════════════════════════════════════════════════════════════════
--
-- This is the check that matters more than the column. erp.source was read by
-- three routines for the whole life of the product and written by none, and
-- nothing could see it: every assertion in the build judges what the database
-- holds, and a column uniformly filled with a plausible-looking default holds
-- exactly what a correct one would look like from a distance. The defect is
-- not in the data, it is in the wiring, and the wiring is readable.
--
-- So: every erp.* session setting that some installed routine reads must be
-- written by some installed routine. Both halves are read from pg_proc.prosrc,
-- which is what the database actually has — needle-patched bodies included,
-- which matters here, because erp.applying_device_action is written only by a
-- patch and would otherwise read as a second finding.

create or replace function erp.unwritten_setting_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with routine as (
    select p.prosrc
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
       and p.prokind in ('f', 'p')
  ),
  reader as (
    select distinct m[1] as guc, r.prosrc
      from routine r
      cross join lateral regexp_matches(r.prosrc, 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m
  ),
  writer as (
    select distinct m[1] as guc
      from routine r
      cross join lateral regexp_matches(r.prosrc, 'set_config\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m
  )
  select 'a session setting is read and never written',
         d.guc,
         'every reader falls through to its own default, so the column it '
         'feeds holds one value for every path and distinguishes none of them'
    from (select distinct guc from reader) d
   where not exists (select 1 from writer w where w.guc = d.guc)
   order by 2
$$;

comment on function erp.unwritten_setting_report() is
  'Session settings some routine reads and no routine sets. erp.source was one '
  'for the life of the product, which made erp.audit_entry.source decoration: '
  'every row said ''api'', whatever made it.';

create or replace function erp.assert_settings_are_written()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
  v_read   integer;
begin
  select count(*), string_agg(format('  %s — %s', r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.unwritten_setting_report() r;

  if v_count > 0 then
    raise exception E'CLOVEERP_SETTING_NEVER_WRITTEN: % setting(s)\n%', v_count, v_detail
      using errcode = 'P0001',
            hint = 'Either set it where the entry point that owns it begins, '
                   'or stop reading it. A read with no writer is a column of '
                   'defaults dressed as evidence.';
  end if;

  -- A check that passes by finding nothing must say how much it looked at,
  -- or a regular expression that has stopped matching reads as health.
  select count(distinct m[1]) into v_read
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(p.prosrc, 'current_setting\s*\(\s*''(erp\.[a-z0-9_]+)''', 'g') m
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test', 'public')
     and p.prokind in ('f', 'p');

  if v_read < 10 then
    raise exception 'CLOVEERP_SETTING_SCRAPER_BLIND: only % session setting(s) are read anywhere', v_read
      using errcode = 'P0001',
            hint = 'This check passes by finding nothing, so it must first '
                   'find something. Read the regular expression against '
                   'pg_proc.prosrc by hand.';
  end if;

  return format('session settings: %s read across the product, every one of them written by something', v_read);
end;
$$;

comment on function erp.assert_settings_are_written is
  'Every erp.* session setting a routine reads is set by a routine. The shape '
  'of the defect that made erp.audit_entry.source decoration for the life of '
  'the product, closed as a class rather than as an instance.';

revoke all on function erp.assert_settings_are_written() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 10. The registers that drive them
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('audit_source_vocabulary', 'An audited change names an entry point that exists',
   'assertion', 'platform', 'erp', 'assert_audit_source_vocabulary', '',
   'audit_source_report', '',
   'The source on an audited change says which way into the database caused it — a person on a screen, the dispatch worker, an Edge Function. This refuses a word outside the vocabulary, a vocabulary word nothing ever declares, and an entry point still claiming one of the two retired words. Dated: entries written before the vocabulary existed say ''api'' and are append-only.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('settings_are_written', 'A session setting that is read is set by something',
   'assertion', 'platform', 'erp', 'assert_settings_are_written', '',
   'unwritten_setting_report', '',
   'The shape of the defect that made the audit trail''s source column decoration: erp.source was read by three routines and written by none, so every audited change in the product carried the same fallback. A setting with no writer is a column of defaults dressed as evidence, and it is readable from the routine bodies without running anything.',
   true, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('undeclared_entry_points', 'The ways in that do not yet say what they are',
   'report', 'platform', 'erp', 'undeclared_entry_point_report', '', null, '',
   'The deploy, the operator runbooks and the seed scripts still record ''undeclared'' on the changes they make, because all three drive the database statement by statement outside a transaction the product opens. Read this beside erp.audit_source_report() before concluding that an undeclared change is unexplained.',
   false, (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

-- ═════════════════════════════════════════════════════════════════════════════
-- 11. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.audit_source_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 10;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1        uuid := gen_random_uuid();
  rb        record;
  v_tenant  uuid;
  v_party   uuid;
  v_src     text;
  v_msg     text;
  v_found   integer;
  v_missing integer;
  v_silent  integer;
  v_listed  integer;
  v_named   integer;
  v_broken  text;
  v_tie     text;
begin
  begin
    v_step := 'an organisation with an administrator who has signed in';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.source', '', true);
    select * into rb from erp.provision_tenant(
      'zzsrc-' || v_tag, 'Audit Source Suite',
      'admin@zzsrc-' || v_tag || '.test', 'Audit Source Admin');
    v_tenant := rb.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email) values (a1, 'admin@zzsrc-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);

    -- ── 1. Through a public door ──────────────────────────────────────────
    v_step := 'a party created through the public door';
    perform set_config('erp.source', '', true);
    perform public.erp_create_party('ZZSRC-SCREEN', 'Audit Source Screen', 'customer');
    select a.source into v_src
      from erp.audit_entry a
     where a.tenant_id = v_tenant and a.object_type = 'party'
     order by a.id desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'a change made through a public door records the door''s source';
    passed := v_state is null and v_src = 'screen';
    detail := coalesce(v_state, format('the door recorded %L', v_src), 'no answer');
    return next;

    -- ── 2. A declared entry point, and the gate leaves it alone ───────────
    v_step := 'a trusted caller declaring itself before going through the same door';
    perform set_config('erp.source', '', true);
    perform erp.declare_source('dispatch_worker');
    perform public.erp_create_party('ZZSRC-WORKER', 'Audit Source Worker', 'customer');
    select a.source into v_src
      from erp.audit_entry a
     where a.tenant_id = v_tenant and a.object_type = 'party'
     order by a.id desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'an entry point that has declared itself is recorded as that, and the gate does not overwrite it';
    passed := v_state is null and v_src = 'dispatch_worker';
    detail := coalesce(v_state, format('the trail recorded %L, not screen', v_src), 'no answer');
    return next;

    -- ── 3. The honest default ─────────────────────────────────────────────
    v_step := 'a write by a session that declares nothing';
    perform set_config('erp.source', '', true);
    insert into erp.party (tenant_id, code, name, status)
    values (v_tenant, 'ZZSRC-QUIET', 'Audit Source Quiet', 'active'::erp.record_status)
    returning id into v_party;
    select a.source into v_src
      from erp.audit_entry a
     where a.tenant_id = v_tenant and a.object_id = v_party
     order by a.id desc limit 1;

    v_cases := v_cases + 1;
    case_name := 'a session that declares nothing is recorded as undeclared, not as a source that looks real';
    passed := v_state is null and v_src = 'undeclared'
          and v_src <> 'api' and v_src <> 'system';
    detail := coalesce(v_state, format('the trail recorded %L where it used to record ''api''', v_src), 'no answer');
    return next;

    -- ── 4. A word outside the vocabulary ──────────────────────────────────
    v_step := 'declaring a source this product does not have';
    begin
      perform erp.declare_source('sales_desk');
      v_msg := 'accepted';
    exception when others then
      v_msg := left(sqlerrm, 90);
    end;

    v_cases := v_cases + 1;
    case_name := 'a source outside the vocabulary is refused by name';
    passed := v_state is null and v_msg like 'CLOVEERP_UNKNOWN_AUDIT_SOURCE%';
    detail := coalesce(v_state, v_msg, 'no answer');
    return next;

    -- ── 5. The default is nobody's to claim ───────────────────────────────
    v_step := 'declaring the honest default';
    begin
      perform erp.declare_source('undeclared');
      v_msg := 'accepted';
    exception when others then
      v_msg := left(sqlerrm, 90);
    end;

    v_cases := v_cases + 1;
    case_name := 'nothing may declare itself undeclared: the default is what the absence of a declaration looks like';
    passed := v_state is null and v_msg like 'CLOVEERP_UNDECLARABLE_AUDIT_SOURCE%';
    detail := coalesce(v_state, v_msg, 'no answer');
    return next;

    -- ── 6. The retired words stay retired ─────────────────────────────────
    v_step := 'declaring one of the two words the trail used to carry';
    begin
      perform erp.declare_source('api');
      v_msg := 'accepted';
    exception when others then
      v_msg := left(sqlerrm, 90);
    end;

    v_cases := v_cases + 1;
    case_name := 'the retired words cannot be written again, so the history stays readable and separate';
    passed := v_state is null and v_msg like 'CLOVEERP_UNKNOWN_AUDIT_SOURCE%'
          and exists (select 1 from erp_ref.audit_source s
                       where s.code in ('api', 'system') and not s.is_current);
    detail := coalesce(v_state, v_msg, 'no answer');
    return next;

    -- ── 7. The database, not the convention ───────────────────────────────
    v_step := 'writing an audit entry whose source is not in the vocabulary';
    perform set_config('erp.source', '', true);
    begin
      insert into erp.audit_entry
        (tenant_id, action, object_schema, object_type, source)
      values (v_tenant, 'insert'::erp.audit_action, 'erp', 'party', 'sales_desk');
      v_msg := 'accepted';
    exception when others then
      v_msg := left(sqlerrm, 120);
    end;

    v_cases := v_cases + 1;
    case_name := 'the database itself refuses an audit row whose source is outside the vocabulary';
    passed := v_state is null and v_msg like '%audit_entry_source_known%';
    detail := coalesce(v_state, v_msg, 'no answer');
    return next;

    -- ── 8. Every word is declared, and the silences are named ─────────────
    v_step := 'the two registers, read against each other';
    select count(*) into v_missing
      from erp_ref.audit_source s
     where s.is_current and s.code <> 'undeclared'
       and not exists (select 1 from erp_meta.audit_source_entry_point e
                        where e.records = s.code and e.declares);
    select count(*) into v_silent
      from erp_meta.audit_source_entry_point e where not e.declares;
    select count(*) into v_listed from erp.undeclared_entry_point_report();
    select count(*) into v_named
      from erp_meta.audit_source_entry_point e
     where e.declares and coalesce(btrim(e.declared_at), '') <> '';
    v_tie := erp.assert_audit_source_vocabulary();

    v_cases := v_cases + 1;
    case_name := 'no word in the vocabulary is written by nothing, every declaring entry point says where, and every silent one is named';
    passed := v_state is null and v_missing = 0 and v_silent > 0 and v_listed = v_silent
          and v_named = (select count(*) from erp_meta.audit_source_entry_point e where e.declares)
          and v_named > 0
          and v_tie like 'audit source:%';
    detail := coalesce(v_state, format(
      '%s word(s) declared by nothing, %s entry point(s) still undeclared and all %s named, %s declaring and each saying where; %s',
      v_missing, v_silent, v_listed, v_named, left(v_tie, 90)), 'no answer');
    return next;

    -- ── 9. The class, falsified ───────────────────────────────────────────
    --
    -- A check that refuses a setting with no writer is only worth having if it
    -- would have refused the build that shipped this defect. So one is made,
    -- here, and taken away again.
    v_step := 'a routine that reads a setting nothing writes';
    execute $fn$create function erp_test.zz_reads_an_unwritten_setting()
             returns text language sql stable set search_path = ''
             as $inner$
               select coalesce(nullif(current_setting('erp.nobody_ever_writes_this', true), ''), 'fallback')
             $inner$$fn$;
    select count(*) into v_found from erp.unwritten_setting_report() r
     where r.reference = 'erp.nobody_ever_writes_this';
    begin
      v_broken := 'passed: ' || erp.assert_settings_are_written();
    exception when others then
      v_broken := left(sqlerrm, 90);
    end;
    execute 'drop function erp_test.zz_reads_an_unwritten_setting()';

    v_cases := v_cases + 1;
    case_name := 'a setting that is read and never written is refused, which is what nothing could see before';
    passed := v_state is null and v_found = 1
          and v_broken like 'CLOVEERP_SETTING_NEVER_WRITTEN%'
          and erp.assert_settings_are_written() like 'session settings:%';
    detail := coalesce(v_state, format('%s finding; %s', v_found, v_broken), 'no answer');
    return next;

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

  -- ── 10. Undone ──────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzsrc-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1)
        and not exists (select 1 from pg_catalog.pg_proc p
                         join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'erp_test'
                          and p.proname = 'zz_reads_an_unwritten_setting');
  detail := coalesce(v_state, 'zzsrc rolled back with its parties, its audit entries and the routine case 9 made');
  return next;

  -- The count guard says what stopped the fixture, so the message this suite
  -- caught — and the step that produced it — reaches the build log.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_AUDIT_SOURCE_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.audit_source_suite() from public, anon;

comment on function erp_test.audit_source_suite() is
  'The audit trail''s source, proved and falsified. A change through a public '
  'door records the screen; an entry point that declared itself keeps what it '
  'declared through the same gate; a session that declares nothing is recorded '
  'as undeclared rather than as ''api''; a word outside the vocabulary, the '
  'default itself and the two retired words are each refused by name; the '
  'database refuses an audit row outside the vocabulary by foreign key; no '
  'word is written by nothing and every silent entry point is named; and a '
  'routine reading a setting nothing writes is refused, which is the check '
  'that would have caught this on the day it was written. Rolls back '
  'everything it made.';

create or replace function erp_test.assert_audit_source_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 10;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _audit_source on commit drop as
    select * from erp_test.audit_source_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _audit_source;
  drop table _audit_source;
  if v_fail > 0 then
    raise exception E'CLOVEERP_AUDIT_SOURCE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_AUDIT_SOURCE_SUITE_SHRANK: % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('the trail says who made the change: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_audit_source_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 12. The generators, then the checks that read what changed
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
select erp.assert_governed_views_are_safe();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_audit_attributed();

-- The two new ones, proved here rather than on the next build: an ungoverned
-- column must not survive its own transaction either.
select erp.assert_settings_are_written();
select erp.assert_audit_source_vocabulary();

select erp_test.assert_audit_source_suite();
