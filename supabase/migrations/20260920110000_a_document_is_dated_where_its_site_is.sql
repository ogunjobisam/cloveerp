set lock_timeout = '30s';

-- =============================================================================
-- 20260920110000  A document is dated where it is raised
-- -----------------------------------------------------------------------------
-- A goods receipt raised at ten to one in the morning of 18 September, British
-- Summer Time, was written with document date 2026-09-17. The "Required by"
-- field on the same record, typed by hand as 18/09/2026, stored 2026-09-18. So
-- one record carried two days, and the one the ledger follows was the wrong one.
--
-- The cause is one word. erp.create_document() defaults the date with
-- current_date, and erp.open_document() — which every screen raises through —
-- does not even leave it to the default: it passes current_date itself. A
-- PostgREST session runs at UTC, so current_date is the UTC day. Between
-- midnight and one in the morning BST that is yesterday. In New Zealand it is
-- yesterday for half the working day.
--
-- What it costs, stated plainly, because "an hour a day" reads as harmless:
--
--   * document_date drives the GRNI accrual and the period cut-off. A receipt
--     raised at 00:30 on the first of the month accrues in the month before.
--     Nothing warns; the accrual is simply in the prior period, and the prior
--     period closes.
--   * It is the date on the paper the supplier gets.
--   * It is what every ageing, every days-outstanding and every
--     days-since-receipt report measures from.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Whose day is it
--
-- Three answers were available and only one of them is a day anybody works in:
--
--   * The session's day. What we have. It is the day of whichever region the
--     database happens to sit in, which is a fact about hosting.
--   * The user's day. erp.app_user carries a timezone and the emails already
--     read it. But two people keying receipts for the same warehouse from two
--     countries would date the same shelf's stock two ways, and the second one
--     would be wrong about the shelf.
--   * The site's day. A goods receipt is an assertion about a place: this
--     arrived here. The place has a timezone — erp.site.timezone has carried
--     one since 0002 and, until now, only the alert window read it.
--
-- So: the site's timezone where the document names a site, the organisation's
-- default where it does not (a requisition names no site), and UTC where
-- neither is set. erp.local_timezone() and erp.local_today() are that chain,
-- and they are the only place it is written down.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- Why the whole chain and not the default
--
-- Changing the default alone would have moved the defect one step downstream
-- rather than fixing it, which is worth spelling out because the second step
-- is not obvious:
--
--   erp.post_document_stock() stamps the movement's occurred_at as
--   clock_timestamp() when the document is dated today and as noon UTC of the
--   document's day when it is dated earlier (20260905010000). "Today" there is
--   current_date — UTC again. A receipt now correctly dated 2026-09-18 posted
--   at 00:50 BST takes clock_timestamp(), which is 2026-09-17 23:50 UTC.
--
--   erp.post_movement_finance() then dates the journal and the subledger row
--   on m.occurred_at::date. That cast is performed in the session's timezone,
--   so the journal comes out 2026-09-17 under a document dated 2026-09-18.
--   The document would have been right and the ledger still wrong, which is
--   worse than both being wrong, because the two no longer agree.
--
-- So four stamping paths move together, and one read:
--
--   1. erp.create_document()        the default itself
--   2. erp.open_document()          which overrides the default with UTC
--   3. erp.raise_stock_adjustment() its default, its "not tomorrow" refusal,
--                                   and the backdating test that decides
--                                   whether finance.post is required
--   4. erp.post_stock_adjustment()  and erp.post_document_stock(): which day
--                                   counts as today when stamping occurred_at
--   5. erp.post_movement_finance()  reading a movement's day back
--
-- (3) matters more than it looks. raise_stock_adjustment() refuses a date after
-- today and asks for finance.post before a date before today. Left at UTC while
-- the document date became local, an adjustment dated today would have been
-- refused as a forecast for the hour after local midnight.
--
-- (5) is answered by the document where there is one. An adjustment's journal
-- follows its adjustment; only a bare movement — write_off_stock(), post_count()
-- — falls back to reading the movement's own instant in local time.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- What is deliberately left alone
--
-- current_date appears about a thousand times in this repository. All but the
-- five paths above are reads: how old is this, is this rule in force, which
-- bucket does this fall in. A report that says "as at today" against the
-- server's day is a different question from a document stamped with a day it
-- was not raised on, and folding them together would be a much larger change
-- with no finding behind it.
--
-- Proof: erp_test.local_date_suite(), which raises documents under two
-- organisations whose timezones are fourteen hours apart in opposite
-- directions, so that whatever the hour of the run, at least one of them is on
-- a different day from UTC — and the suite refuses to pass if neither is, so it
-- cannot go green by proving nothing.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Whose day it is
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.local_timezone(p_site_id uuid default null)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.current_tenant_id();
  v_tz     text;
begin
  if v_tenant is null then
    return 'UTC';
  end if;

  if p_site_id is not null then
    select nullif(btrim(s.timezone), '') into v_tz
      from erp.site s
     where s.tenant_id = v_tenant and s.id = p_site_id;
  end if;

  if v_tz is null then
    select nullif(btrim(t.default_timezone), '') into v_tz
      from erp.tenant t where t.id = v_tenant;
  end if;

  if v_tz is null then
    return 'UTC';
  end if;

  -- A name the server does not know would raise from inside a document being
  -- written, which is a bad place to discover a typo in a setting. The setting
  -- is answered here and reported by erp.assert_timezones_are_known().
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    return 'UTC';
  end if;

  return v_tz;
end;
$$;

comment on function erp.local_timezone(uuid) is
  'The timezone a document raised at this site is dated in: the site''s, then '
  'the organisation''s default, then UTC. The one place that chain is written.';

create or replace function erp.local_today(p_site_id uuid default null)
returns date
language sql
stable
security invoker
set search_path = ''
as $$
  select (now() at time zone erp.local_timezone(p_site_id))::date
$$;

comment on function erp.local_today(uuid) is
  'Today where the work is happening, not where the database is. Every place a '
  'document or a movement is stamped with the day it was raised reads this.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The document spine
-- ═════════════════════════════════════════════════════════════════════════════

-- Both bodies are patched, not restated. erp.create_document() has been
-- rewritten in place since the file that created it — 20260904980000 renamed
-- every refusal to CLOVEERP_, 20260906081000 gave it provisional numbers under
-- a gapless rule, 20260906142000 again — so restating 20260829190000's text
-- would have quietly put the retired refusal prefix back and taken gapless
-- numbering away. The rule the rest of this repository follows: read the
-- deployed body, name what you expect of it, and change that.

do $create_document$
declare
  v_def text;
  v_n   text := E'    coalesce(p_document_date, current_date),';
  v_r   text := E'    -- The day where the document is being raised, not the day where the\n'
             || E'    -- database is standing. current_date here dated a receipt keyed at ten\n'
             || E'    -- to one in the morning BST to the day before, and the GRNI accrual\n'
             || E'    -- with it.\n'
             || E'    coalesce(p_document_date, erp.local_today(p_site_id)),';
  v_hits integer;
begin
  v_def := pg_get_functiondef(
    'erp.create_document(text,uuid,uuid,uuid,date,character,text,jsonb)'::regprocedure);

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: erp.create_document() defaults its '
      'date from current_date % time(s), not once', v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(
    'erp.create_document(text,uuid,uuid,uuid,date,character,text,jsonb)'::regprocedure);
  if position('erp.local_today(p_site_id)' in v_def) = 0
     or position('erp.provisional_document_number()' in v_def) = 0 then
    raise exception
      'CLOVEERP_CREATE_DOCUMENT_UNRECOGNISED: the rewrite did not take, or it '
      'dropped the gapless numbering 20260906081000 added'
      using hint = 'The function was replaced by something else between the read and the write.';
  end if;
end
$create_document$;

-- The door every screen raises through. It did not leave the date to
-- create_document() at all: it passed current_date itself, so the default above
-- could never be reached from a screen, and fixing the default alone would have
-- fixed nothing anybody can see.
do $open_document$
declare
  v_def text;
  v_n   text := E'  v_id := erp.create_document(p_type_code, v_entity, p_site_id, p_party_id,\n'
             || E'                              current_date, p_currency, p_their_ref);';
  v_r   text := E'  -- The date is left to create_document(), which reads the day at the site.\n'
             || E'  v_id := erp.create_document(p_type_code, v_entity, p_site_id, p_party_id,\n'
             || E'                              null, p_currency, p_their_ref);';
  v_hits integer;
begin
  v_def := pg_get_functiondef(
    'erp.open_document(text,uuid,uuid,uuid,text,date,character)'::regprocedure);

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_OPEN_DOCUMENT_UNRECOGNISED: erp.open_document() hands '
      'create_document() current_date % time(s), not once', v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_n, v_r);

  v_def := pg_get_functiondef(
    'erp.open_document(text,uuid,uuid,uuid,text,date,character)'::regprocedure);
  if position('current_date' in v_def) > 0 then
    raise exception 'CLOVEERP_OPEN_DOCUMENT_UNRECOGNISED: the rewrite did not take'
      using hint = 'The function was replaced by something else between the read and the write.';
  end if;
end
$open_document$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. When the movement happened
--
-- Three bodies are patched rather than restated. Each of them has been rewritten
-- in place by an earlier migration — erp.post_document_stock() by 20260905010000
-- and erp.post_movement_finance() by 20260906143000 — so the text on disk in the
-- migration that created them is not the text that is deployed. Restating from
-- the older file would silently undo the later work. Every patch names what it
-- expects and refuses if it is not there.
-- ═════════════════════════════════════════════════════════════════════════════

do $stock_bridge$
declare
  v_def text;
  v_n   text := E'case when coalesce(d.posting_date, d.document_date) >= current_date';
  v_r   text := E'case when coalesce(d.posting_date, d.document_date) >= erp.local_today(d.site_id)';
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure);

  v_hits := (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n);
  if v_hits <> 1 then
    raise exception
      'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: erp.post_document_stock() decides '
      'today against current_date % time(s), not once', v_hits
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  execute replace(v_def, v_n, v_r);

  if position(v_r in pg_get_functiondef('erp.post_document_stock(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_STOCK_BRIDGE_UNRECOGNISED: the rewrite did not take'
      using hint = 'The function was replaced by something else between the read and the write.';
  end if;
end
$stock_bridge$;

do $adjust$
declare
  v_def  text;
  v_hits integer;
  -- raise_stock_adjustment: the default, the refusal and the backdating test.
  v_a1 text := E'  v_on     date := coalesce(p_adjusted_on, current_date);';
  v_b1 text := E'  v_on     date := coalesce(p_adjusted_on, erp.local_today(p_site_id));';
  v_a2 text := E'  if v_on > current_date then';
  v_b2 text := E'  if v_on > erp.local_today(p_site_id) then';
  v_a3 text := E'  if v_on < current_date then';
  v_b3 text := E'  if v_on < erp.local_today(p_site_id) then';
begin
  v_def := pg_get_functiondef(
    'erp.raise_stock_adjustment(uuid,text,jsonb,date,text,text)'::regprocedure);

  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1),
    (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2),
    (length(v_def) - length(replace(v_def, v_a3, ''))) / length(v_a3)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_ADJUSTMENT_RAISE_UNRECOGNISED: erp.raise_stock_adjustment() '
        'does not read current_date exactly once in each of its three places'
        using hint = 'Read the deployed body and re-anchor this patch on it.';
    end if;
  end loop;

  execute replace(replace(replace(v_def, v_a1, v_b1), v_a2, v_b2), v_a3, v_b3);

  v_def := pg_get_functiondef(
    'erp.raise_stock_adjustment(uuid,text,jsonb,date,text,text)'::regprocedure);
  if position('current_date' in v_def) > 0 then
    raise exception
      'CLOVEERP_ADJUSTMENT_RAISE_UNRECOGNISED: erp.raise_stock_adjustment() still '
      'reads current_date after the patch'
      using hint = 'A fourth reading of current_date arrived since this was written.';
  end if;
end
$adjust$;

do $adjust_post$
declare
  v_def  text;
  v_hits integer;
  v_a1 text := E'  if v_on > current_date then';
  v_b1 text := E'  if v_on > erp.local_today(d.site_id) then';
  v_a2 text := E'  if v_on < current_date then';
  v_b2 text := E'  if v_on < erp.local_today(d.site_id) then';
  v_a3 text := E'  v_when := case when v_on >= current_date';
  v_b3 text := E'  v_when := case when v_on >= erp.local_today(d.site_id)';
begin
  v_def := pg_get_functiondef('erp.post_stock_adjustment(uuid)'::regprocedure);

  foreach v_hits in array array[
    (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1),
    (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2),
    (length(v_def) - length(replace(v_def, v_a3, ''))) / length(v_a3)]
  loop
    if v_hits <> 1 then
      raise exception
        'CLOVEERP_ADJUSTMENT_POST_UNRECOGNISED: erp.post_stock_adjustment() does '
        'not read current_date exactly once in each of its three places'
        using hint = 'Read the deployed body and re-anchor this patch on it.';
    end if;
  end loop;

  execute replace(replace(replace(v_def, v_a1, v_b1), v_a2, v_b2), v_a3, v_b3);

  v_def := pg_get_functiondef('erp.post_stock_adjustment(uuid)'::regprocedure);
  if position('current_date' in v_def) > 0 then
    raise exception
      'CLOVEERP_ADJUSTMENT_POST_UNRECOGNISED: erp.post_stock_adjustment() still '
      'reads current_date after the patch'
      using hint = 'A fourth reading of current_date arrived since this was written.';
  end if;
end
$adjust_post$;

-- The journal a bare movement raises. A movement made by a document takes the
-- document's date — an adjustment posted a fortnight late belongs to the day the
-- count was taken, and the document is where that day is agreed. A movement with
-- no document — erp.write_off_stock(), erp.post_count() — takes its own instant,
-- read in the site's timezone rather than the session's.
do $movement_finance$
declare
  v_def  text;
  v_n1 text := E'  v_in      boolean;\n  v_event_type text;\nbegin';
  v_r1 text := E'  v_in      boolean;\n  v_event_type text;\n  v_on      date;\nbegin';
  v_n2 text := E'  v_event_type := case when m.movement_type = ''ownership_transfer'' then ''stock.ownership_transferred'' else ''stock.adjusted'' end;';
  v_r2 text := E'  v_event_type := case when m.movement_type = ''ownership_transfer'' then ''stock.ownership_transferred'' else ''stock.adjusted'' end;\n'
            || E'\n'
            || E'  -- The day the ledger follows. A movement a document made takes the\n'
            || E'  -- document''s day, so a backdated adjustment posts where it says it\n'
            || E'  -- happened; a bare movement takes its own instant read where the stock\n'
            || E'  -- is standing, because ::date on its own is read in the session''s\n'
            || E'  -- timezone, which is UTC, which is not the warehouse''s day.\n'
            || E'  select coalesce(dd.posting_date, dd.document_date) into v_on\n'
            || E'    from erp.document dd\n'
            || E'   where dd.tenant_id = v_tenant and dd.id = m.document_id;\n'
            || E'  v_on := coalesce(v_on,\n'
            || E'                   (m.occurred_at at time zone erp.local_timezone(m.site_id))::date,\n'
            || E'                   erp.local_today(m.site_id));';
  v_n3 text := E'coalesce(m.occurred_at::date, current_date)';
  v_r3 text := E'v_on';
  v_hits integer;
begin
  v_def := pg_get_functiondef('erp.post_movement_finance(bigint)'::regprocedure);

  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1
     or (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception
      'CLOVEERP_MOVEMENT_POSTING_UNRECOGNISED: erp.post_movement_finance() is not '
      'the body this migration patches'
      using hint = 'Read the deployed body and re-anchor this patch on it.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_n3, ''))) / length(v_n3);
  if v_hits <> 4 then
    raise exception
      'CLOVEERP_MOVEMENT_POSTING_UNRECOGNISED: erp.post_movement_finance() dates '
      'itself from the movement % time(s), not the four this patch knows about', v_hits
      using hint = 'A fifth date was added since this was written; decide what it should follow.';
  end if;

  execute replace(replace(replace(v_def, v_n1, v_r1), v_n2, v_r2), v_n3, v_r3);

  v_def := pg_get_functiondef('erp.post_movement_finance(bigint)'::regprocedure);
  if position('current_date' in v_def) > 0 or position('v_on      date;' in v_def) = 0 then
    raise exception
      'CLOVEERP_MOVEMENT_POSTING_UNRECOGNISED: the rewrite did not take'
      using hint = 'The function was replaced by something else between the read and the write.';
  end if;
end
$movement_finance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A setting the server cannot read is a setting nobody set
--
-- erp.local_timezone() answers UTC for a name PostgreSQL does not know, because
-- raising out of the middle of a document being written is a bad way to find out
-- that somebody typed "GMT+1" into a site. Falling back quietly would hide it,
-- so the build says it instead.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.assert_timezones_are_known()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_bad text;
  v_n   integer;
begin
  select count(*), string_agg(x.what || ' = ' || quote_literal(x.tz), ', ' order by x.what)
    into v_n, v_bad
    from (
      select 'site ' || s.code as what, btrim(s.timezone) as tz
        from erp.site s
       where coalesce(btrim(s.timezone), '') <> ''
         and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = btrim(s.timezone))
      union all
      select 'organisation ' || t.code, btrim(t.default_timezone)
        from erp.tenant t
       where coalesce(btrim(t.default_timezone), '') <> ''
         and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = btrim(t.default_timezone))
      union all
      select 'calendar ' || c.code, btrim(c.timezone)
        from erp.calendar c
       where coalesce(btrim(c.timezone), '') <> ''
         and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = btrim(c.timezone))
    ) x;

  if v_n > 0 then
    raise exception
      'CLOVEERP_TIMEZONE_NOT_KNOWN: % setting(s) name a timezone this server does '
      'not have: %. Documents raised there are dated in UTC.', v_n, v_bad
      using hint = 'Set the timezone to an IANA name — Europe/London, not GMT+1 — '
                   'on the site, the organisation or the calendar named above.';
  end if;

  return format('%s timezone setting(s) are names the server knows',
                (select count(*) from erp.site where coalesce(btrim(timezone), '') <> '')
                + (select count(*) from erp.tenant where coalesce(btrim(default_timezone), '') <> '')
                + (select count(*) from erp.calendar where coalesce(btrim(timezone), '') <> ''));
end;
$$;

comment on function erp.assert_timezones_are_known() is
  'Every site, organisation and calendar names a timezone PostgreSQL has. One '
  'it does not have is silently UTC, and silently UTC is how a document gets '
  'yesterday''s date.';

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('timezones_are_known', 'Every timezone setting is a name the server has', 'assertion', 'platform', 'erp',
   'assert_timezones_are_known', '', null, '',
   'A site, organisation or calendar whose timezone is a name PostgreSQL does not have is treated as UTC, and a document raised there quietly takes the wrong day. Nothing else would report it: the setting looks set.',
   true, 98)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Proof
--
-- The clock cannot be moved in a test, so the fixture moves the organisation
-- instead. Etc/GMT-14 is UTC+14 and Etc/GMT+12 is UTC-12 — twenty-six hours
-- apart, so whatever hour the build runs at, the two are never on the same day
-- as each other and at least one of them is never on the same day as UTC. The
-- suite asserts both of those before it asserts anything else, because a
-- timezone test that runs at noon and proves nothing is worse than no test.
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.local_date_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tenant  uuid; v_admin uuid; v_token text;
  v_entity  uuid; v_site uuid;
  v_ahead   constant text := 'Etc/GMT-14';   -- UTC+14
  v_behind  constant text := 'Etc/GMT+12';   -- UTC-12
  v_on_ahead  date; v_on_behind date; v_on_site date; v_on_door date;
  v_doc     uuid;
begin
  begin
  v_step := 'provisioning the organisation';
  select t.tenant_id, t.admin_user_id, t.admin_token
    into v_tenant, v_admin, v_token
    from erp.provision_tenant('zz-local-date', 'Local date suite',
                              'admin@zz-local-date.test', 'Local Date Admin',
                              p_timezone => v_ahead) t;
  update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
  insert into auth.users (id, email)
  values ('00000000-0000-4000-8000-0000000000f1', 'admin@zz-local-date.test');
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-0000000000f1')::text, true);
  perform erp.claim_invitation(v_token);

  v_step := 'installing finance and procurement';
  perform erp.configure_finance();
  perform erp.configure_procurement(100000000);

  select e.id into v_entity from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
  -- A site of its own. Finance and procurement install no site, so reading
  -- "the organisation's first site" found none, the site cases raised
  -- documents with no site at all, and they fell back to the organisation's
  -- day — which the first run of this suite in CI caught, because a site case
  -- is asserted against the site's day and not merely against "some local day".
  v_site := erp.create_site('ZZ-LOCAL', 'Local date depot', 'warehouse', v_entity, null, v_ahead);
  if v_site is null then
    raise exception 'CLOVEERP_SUITE_FIXTURE: local_date_suite has no site to raise documents for'
      using hint = 'erp.create_site() returned nothing; the site cases would prove nothing.';
  end if;

  -- ── 1. Fourteen hours ahead ──────────────────────────────────────────────
  v_step := 'raising a document fourteen hours ahead of UTC';
  v_cases := v_cases + 1;
  update erp.tenant set default_timezone = v_ahead where id = v_tenant;
  update erp.site set timezone = v_ahead where tenant_id = v_tenant;
  v_doc := erp.create_document('requisition', v_entity);
  select d.document_date into v_on_ahead from erp.document d where d.id = v_doc;

  case_name := 'a document raised in an organisation fourteen hours ahead of UTC takes that day';
  passed := v_on_ahead = (now() at time zone v_ahead)::date;
  detail := format('document dated %s, %s says %s, the database says %s',
                   v_on_ahead, v_ahead, (now() at time zone v_ahead)::date, current_date);
  return next;

  -- ── 2. Twelve hours behind ───────────────────────────────────────────────
  v_step := 'raising a document twelve hours behind UTC';
  v_cases := v_cases + 1;
  update erp.tenant set default_timezone = v_behind where id = v_tenant;
  update erp.site set timezone = v_behind where tenant_id = v_tenant;
  v_doc := erp.create_document('requisition', v_entity);
  select d.document_date into v_on_behind from erp.document d where d.id = v_doc;

  case_name := 'a document raised in an organisation twelve hours behind UTC takes that day';
  passed := v_on_behind = (now() at time zone v_behind)::date;
  detail := format('document dated %s, %s says %s, the database says %s',
                   v_on_behind, v_behind, (now() at time zone v_behind)::date, current_date);
  return next;

  -- ── 3. The suite cannot pass by proving nothing ──────────────────────────
  v_step := 'checking the fixture can tell the two apart';
  v_cases := v_cases + 1;
  case_name := 'the two organisations are on different days, and at least one of them is not on the database''s day';
  passed := v_on_ahead is distinct from v_on_behind
        and (v_on_ahead is distinct from current_date or v_on_behind is distinct from current_date);
  detail := format('ahead %s, behind %s, database %s — %s',
                   v_on_ahead, v_on_behind, current_date,
                   case when v_on_ahead is distinct from current_date
                        then 'the organisation ahead differs from the database'
                        else 'the organisation behind differs from the database' end);
  return next;

  -- ── 4. The site, not the organisation ────────────────────────────────────
  v_step := 'raising a document for a site in another timezone';
  v_cases := v_cases + 1;
  update erp.tenant set default_timezone = v_behind where id = v_tenant;
  update erp.site set timezone = v_ahead where tenant_id = v_tenant and id = v_site;
  v_doc := erp.create_document('requisition', v_entity, v_site);
  select d.document_date into v_on_site from erp.document d where d.id = v_doc;

  case_name := 'a document raised for a site takes the site''s day, not the organisation''s default';
  passed := v_on_site = (now() at time zone v_ahead)::date
        and v_on_site is distinct from (now() at time zone v_behind)::date;
  detail := format('site %s says %s, the organisation default %s says %s, the document says %s',
                   v_ahead, (now() at time zone v_ahead)::date,
                   v_behind, (now() at time zone v_behind)::date, v_on_site);
  return next;

  -- ── 5. The door every screen raises through ──────────────────────────────
  -- erp.open_document() used to pass current_date itself, so create_document()'s
  -- default could never be reached from a screen. This is the case that would
  -- have stayed red if only the default had been fixed.
  v_step := 'raising through erp.open_document';
  v_cases := v_cases + 1;
  v_doc := erp.open_document('requisition', null, v_entity, v_site);
  select d.document_date into v_on_door from erp.document d where d.id = v_doc;

  case_name := 'raising through the door every screen uses takes the site''s day, not the database''s';
  passed := v_on_door = (now() at time zone v_ahead)::date;
  detail := format('document dated %s, the site''s day is %s, the database''s day is %s',
                   v_on_door, (now() at time zone v_ahead)::date, current_date);
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);

  -- ── 6. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant where code = 'zz-local-date')
        and not exists (select 1 from auth.users
                         where id = '00000000-0000-4000-8000-0000000000f1');
  detail := coalesce(v_state, 'zz-local-date rolled back with its documents');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: local_date_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.local_date_suite() from public, anon;

comment on function erp_test.local_date_suite() is
  'A document is dated where it is raised. Proved against two organisations '
  'twenty-six hours apart, so the fixture is never on one day at both ends; '
  'falsified by refusing to pass unless the two differ from each other and at '
  'least one of them differs from the database''s own day. Covers the default, '
  'the site overriding the organisation, and erp.open_document(), which used to '
  'pass current_date itself and so hid the default from every screen.';

create or replace function erp_test.assert_local_date_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _local_date on commit drop as
    select * from erp_test.local_date_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _local_date;
  drop table _local_date;
  if v_fail > 0 then
    raise exception E'CLOVEERP_LOCAL_DATE_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: local_date_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a document is dated where it is raised: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_local_date_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_local_date_suite();
select erp_test.assert_stock_adjustment_suite();

select erp.assert_timezones_are_known();
select erp.assert_diagnostics_registered();
select erp.assert_write_only_columns();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_isolation();
