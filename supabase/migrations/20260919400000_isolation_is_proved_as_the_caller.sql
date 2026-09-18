-- =============================================================================
-- Isolation is proved as the caller
--
-- erp_test.door_isolation_suite() has been the product's proof that one
-- organisation cannot see another through the surface since 20260906090000.
-- It set request.jwt.claims three times and never changed role. The build runs
-- as a trusted owner, and a trusted owner bypasses row-level security, so every
-- case it reported was the doors' own `where tenant_id = erp.require_tenant_id()`
-- filters refusing. The policies were never in force while it ran. A door whose
-- filter was dropped in a rewrite, or a policy keyed on the wrong column, would
-- have left the suite green.
--
-- 0005_b1_isolation_test_suite.sql already knew this and said so in a comment:
-- "the whole point is to become the `authenticated` role for real rather than
-- to simulate what that role would see". The door suite never did it.
--
-- Two things follow, and both are built here.
--
-- 1. Every impersonation now becomes `authenticated` for real. It does so in a
--    helper rather than in the suite's own frame, because the suite has to be
--    the owner between cases — it reads both organisations to set the fixtures
--    up, and `authenticated` is not granted USAGE on erp_test at all. A
--    function carrying a SET clause is entered at a new GUC nesting level and
--    every setting it changes, `role` included, is restored when it returns:
--    so a helper that switches role switches it back whether it returns or
--    raises, and the switch is in force for every statement it makes in
--    between. That is the mechanic these helpers rely on, and it is why the
--    role switch cannot be lifted out into a routine the helper calls.
--
-- 2. Reading a row by its primary key is the case a tenant-keyed test cannot
--    fail. `where tenant_id = <the other's>` returns nothing whether the policy
--    works or not; `where id = <the other's row>` returns nothing only if it
--    does. The repository had exactly one such case, on erp.entity, written
--    twice (0005 and 0034). The Definition of Done names orders, invoices,
--    stock, ledger and customers, so each of those is read here by its primary
--    key, as the other organisation, under the policies — and read again as its
--    own organisation, which must find it. A case that only proves absence
--    passes just as well when the fixture wrote nothing.
--
-- And the read doors that take an identifier were never walked at all:
-- erp_test.walk_read_doors() selected `p.pronargs = p.pronargdefaults`, which
-- is every door callable with no arguments and no other. A door that takes a
-- document id was therefore never handed another organisation's document id by
-- anything in the build. erp_test.walk_read_doors_by_id() walks those doors,
-- hands each of them the second organisation's order, invoice, customer,
-- journal and site, and refuses if any of them answers with anything of the
-- second's. The identifier handed in is not counted against the door: the
-- caller already had it, and echoing it back discloses nothing. The same walk
-- is then made as the second organisation, where it must find plenty — without
-- that, an empty walk would pass the case before it.
--
-- The count moves from 5 cases to 14, deliberately, and the wrapper is restated
-- to match. erp_test.assert_isolation_suite()'s floor of 30 is untouched: that
-- is the other suite, and this migration does not change it.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Becoming the caller
-- ═════════════════════════════════════════════════════════════════════════════

-- Walk every zero-argument read door as one organisation's sign-in, in the
-- authenticated role, and report which of the other organisation's identifiers
-- appeared. The refusals are reported too: a door that answers the owner and
-- refuses a real caller is not a leak, but it is worth reading when the count
-- of walked doors moves.
drop function if exists erp_test.walk_read_doors(uuid[]);

create or replace function erp_test.walk_read_doors(p_other uuid[], p_auth uuid)
returns table(doors_walked integer, doors_refused integer, leaks text, refusals text)
language plpgsql
volatile
set search_path = ''
as $walk$
declare
  v_owner text := current_user;
  d       record;
  v_text  text;
  v_found uuid[];
  v_leaks text := null;
  v_refus text := null;
  v_state text;
begin
  doors_walked := 0; doors_refused := 0;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  for d in
    select p.proname
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'erp\_%'
       and p.provolatile <> 'v'
       and p.pronargs = p.pronargdefaults
       and p.prokind = 'f'
     order by p.proname
  loop
    begin
      execute format('select coalesce(string_agg(t::text, E''\n''), '''') from public.%I() t', d.proname) into v_text;
      doors_walked := doors_walked + 1;
      select array_agg(distinct m[1]::uuid) into v_found
        from regexp_matches(v_text, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') m
       where m[1]::uuid = any (p_other);
      if v_found is not null then
        v_leaks := coalesce(v_leaks || '; ', '') || format('%s exposed %s identifier(s)', d.proname, array_length(v_found, 1));
      end if;
    exception when others then
      -- A refusal is not a leak: platform doors refuse a tenant administrator,
      -- and some doors refuse without a context they need.
      doors_refused := doors_refused + 1;
      get stacked diagnostics v_state = returned_sqlstate;
      if length(coalesce(v_refus, '')) < 900 then
        v_refus := coalesce(v_refus || ', ', '') || format('%s[%s]', d.proname, v_state);
      end if;
    end;
  end loop;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  leaks := v_leaks;
  refusals := v_refus;
  return next;
end;
$walk$;

revoke all on function erp_test.walk_read_doors(uuid[], uuid) from public, anon, authenticated;

comment on function erp_test.walk_read_doors(uuid[], uuid) is
  'Suite helper: walks every zero-argument public read door as the given '
  'sign-in, in the authenticated role so the policies are in force, and reports '
  'which of the other organisation''s identifiers appeared. Returns to the '
  'calling role before it returns.';

-- The doors the walk above cannot reach: the ones that take an identifier.
-- Each is handed each probe — the other organisation's own rows — and must
-- answer with nothing of that organisation's beyond the identifier it was
-- given, which the caller already had.
create or replace function erp_test.walk_read_doors_by_id(
  p_other uuid[], p_probes uuid[], p_auth uuid)
returns table(doors_walked integer, calls_made integer, calls_refused integer,
              calls_exposing integer, leaks text)
language plpgsql
volatile
set search_path = ''
as $walkid$
declare
  v_owner text := current_user;
  d       record;
  v_probe uuid;
  v_text  text;
  v_found uuid[];
  v_leaks text := null;
begin
  doors_walked := 0; calls_made := 0; calls_refused := 0; calls_exposing := 0;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  for d in
    select p.proname
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname like 'erp\_%'
       and p.provolatile <> 'v'
       and p.prokind = 'f'
       and p.pronargs - p.pronargdefaults = 1
       and p.proargtypes[0] = 'pg_catalog.uuid'::regtype
     order by p.proname
  loop
    doors_walked := doors_walked + 1;
    foreach v_probe in array p_probes
    loop
      calls_made := calls_made + 1;
      begin
        execute format('select coalesce(string_agg(t::text, E''\n''), '''') from public.%I(%L::uuid) t',
                       d.proname, v_probe) into v_text;
        select array_agg(distinct m[1]::uuid) into v_found
          from regexp_matches(v_text, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') m
         where m[1]::uuid = any (p_other) and m[1]::uuid <> v_probe;
        if v_found is not null then
          calls_exposing := calls_exposing + 1;
          if length(coalesce(v_leaks, '')) < 900 then
            v_leaks := coalesce(v_leaks || '; ', '')
                    || format('%s given %s exposed %s identifier(s)',
                              d.proname, left(v_probe::text, 8), array_length(v_found, 1));
          end if;
        end if;
      exception when others then
        calls_refused := calls_refused + 1;
      end;
    end loop;
  end loop;

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  leaks := v_leaks;
  return next;
end;
$walkid$;

revoke all on function erp_test.walk_read_doors_by_id(uuid[], uuid[], uuid) from public, anon, authenticated;

comment on function erp_test.walk_read_doors_by_id(uuid[], uuid[], uuid) is
  'Suite helper: walks every public read door whose one required argument is an '
  'identifier, as the given sign-in in the authenticated role, handing each '
  'door each probe identifier, and reports which of them answered with '
  'something of the other organisation''s. The probe itself is not counted: the '
  'caller already had it.';

-- One row of one table, by its primary key, as the given sign-in. Returns the
-- number of rows the policies let that caller see, or -1 where the read was
-- refused outright — a refusal is not a leak either.
create or replace function erp_test.rows_visible_as(p_auth uuid, p_relation text, p_where text)
returns bigint
language plpgsql
volatile
set search_path = ''
as $visible$
declare
  v_owner text := current_user;
  v_n     bigint;
begin
  if p_relation not in ('erp.document', 'erp.document_line', 'erp.stock_movement',
                        'erp.stock_balance', 'erp.journal', 'erp.journal_line', 'erp.party') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a relation erp_test.door_isolation_suite reads by key', p_relation
      using hint = 'Read erp.document, erp.document_line, erp.stock_movement, erp.stock_balance, erp.journal, erp.journal_line or erp.party.';
  end if;
  if p_where !~ '^id = ' then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a primary-key predicate', left(p_where, 60)
      using hint = 'Pass a predicate of the form "id = <literal>", so the read is by primary key and nothing else.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute format('select count(*) from %s where %s', p_relation::regclass, p_where) into v_n;
  exception when others then
    v_n := -1;
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  return v_n;
end;
$visible$;

revoke all on function erp_test.rows_visible_as(uuid, text, text) from public, anon, authenticated;

comment on function erp_test.rows_visible_as(uuid, text, text) is
  'Suite helper: counts the rows of one table matching a primary-key predicate '
  'as the given sign-in, in the authenticated role so the policies are in '
  'force. -1 where the read was refused. Returns to the calling role before it '
  'returns.';

-- One read door, one identifier, as the given sign-in.
create or replace function erp_test.read_door_as(p_auth uuid, p_door text, p_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $reader$
declare
  v_owner text := current_user;
  v_out   jsonb;
  v_state text;
  v_msg   text;
begin
  if p_door not in ('erp_document', 'erp_document_lines') then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a read door erp_test.door_isolation_suite calls', p_door
      using hint = 'Call erp_document or erp_document_lines.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute format('select to_jsonb(public.%I($1))', p_door) into v_out using p_id;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_out := jsonb_build_object('refused', v_state, 'message', left(v_msg, 200));
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  return v_out;
end;
$reader$;

revoke all on function erp_test.read_door_as(uuid, text, uuid) from public, anon, authenticated;

comment on function erp_test.read_door_as(uuid, text, uuid) is
  'Suite helper: calls one read door with one identifier as the given sign-in, '
  'in the authenticated role, and returns its answer as jsonb or its refusal.';

-- One write door, as the given sign-in. Null where the door accepted the call,
-- which is what the write cases are looking for.
create or replace function erp_test.door_call_as(p_auth uuid, p_sql text)
returns text
language plpgsql
volatile
set search_path = ''
as $caller$
declare
  v_owner text := current_user;
  v_state text;
  v_msg   text;
  v_err   text := null;
begin
  if p_sql !~ '^select public\.erp_[a-z_]+\(' then
    raise exception 'CLOVEERP_SUITE_HELPER_MISUSED: % is not a call to a public door', left(p_sql, 60)
      using hint = 'Pass a statement of the form "select public.erp_<door>(...)", so the helper cannot be used to reach anything else.';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_err := format('%s %s', v_state, left(v_msg, 120));
  end;
  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);
  return v_err;
end;
$caller$;

revoke all on function erp_test.door_call_as(uuid, text) from public, anon, authenticated;

comment on function erp_test.door_call_as(uuid, text) is
  'Suite helper: makes one public door call as the given sign-in, in the '
  'authenticated role, and returns null where the door accepted it or the '
  'refusal where it did not.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The suite, run as the caller
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.door_isolation_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 14;
  v_owner   text := current_user;
  v_cases   integer := 0;
  v_step    text := 'starting';
  v_stop    text := null;
  a_auth    uuid := '00000000-0000-4000-8000-0000000000e2';
  b_auth    uuid := '00000000-0000-4000-8000-0000000000e3';
  fa jsonb; fb jsonb;
  v_ta uuid; v_tb uuid;
  v_ids_a uuid[]; v_ids_b uuid[]; v_probes uuid[];
  w record; w_a record; w_b record;
  v_doc_b uuid; v_line_b uuid; v_grn_b uuid; v_grn_line uuid; v_inv_b uuid;
  v_item_b uuid; v_site_b uuid; v_party_b uuid;
  v_move_b bigint; v_bal_b bigint;
  v_journal_b uuid; v_jline_b uuid;
  v_refused integer := 0; v_tried integer := 0; v_out text := null;
  v_msg text; v_err text;
  n_a bigint; n_b bigint; n_a2 bigint; n_b2 bigint;
  j_a jsonb; j_b jsonb; l_a jsonb; l_b jsonb;
begin
  begin
  v_step := 'building the two organisations through their own doors';
  fa := erp_test.nordwind_fixture('nordwind-a', a_auth, 'admin@nordwind-a.test');
  fb := erp_test.nordwind_fixture('nordwind-b', b_auth, 'admin@nordwind-b.test');
  v_ta := (fa ->> 'tenant_id')::uuid; v_tb := (fb ->> 'tenant_id')::uuid;
  v_item_b := (fb ->> 'hw')::uuid;
  v_site_b := (fb ->> 'wh')::uuid;
  v_party_b := (fb ->> 'cust_gb')::uuid;

  -- B does a day's work, as itself, so its doors have something to show and
  -- the isolation cases below have an order, an invoice, stock, a ledger entry
  -- and a customer to ask for. The role switch is inline here because the
  -- statements between it and the switch back are the work; it is unwound in
  -- any case when this function returns.
  v_step := 'the second organisation''s day of work';
  perform set_config('request.jwt.claims',
                     json_build_object('sub', b_auth, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  v_doc_b  := (public.erp_create_document('purchase_order', (fb ->> 'sup')::uuid, v_site_b,
                 'B-PO-1', null, (fb ->> 'gb')::uuid, null, null) ->> 'document_id')::uuid;
  v_line_b := (public.erp_add_document_line(v_doc_b, v_item_b, 5, 1000, 'B''s bolts') ->> 'line_id')::uuid;

  v_grn_b  := (public.erp_create_document('goods_receipt', (fb ->> 'sup')::uuid, v_site_b,
                 'B-GRN-1', null, (fb ->> 'gb')::uuid, null, null) ->> 'document_id')::uuid;
  v_grn_line := (public.erp_add_document_line(v_grn_b, v_item_b, 7, 1000, 'B''s receipt') ->> 'line_id')::uuid;
  perform public.erp_set_line_stock_identity(v_grn_line, null, (fb ->> 'bulk_a')::uuid, null);
  perform public.erp_transition_document(v_grn_b, 'post', 'door isolation fixture');

  v_inv_b  := (public.erp_create_document('sales_invoice', v_party_b, v_site_b,
                 'B-INV-1', null, (fb ->> 'gb')::uuid, null, null) ->> 'document_id')::uuid;
  perform public.erp_add_document_line(v_inv_b, v_item_b, 2, 5000, 'B''s invoice line');

  execute format('set local role %I', v_owner);
  perform set_config('request.jwt.claims', '', true);

  -- Read back, as the owner, what the second organisation now owns.
  v_step := 'reading the second organisation''s rows as the owner';
  select m.id into v_move_b from erp.stock_movement m
   where m.tenant_id = v_tb order by m.id limit 1;
  select b.id into v_bal_b from erp.stock_balance b
   where b.tenant_id = v_tb order by b.id limit 1;
  select j.id into v_journal_b from erp.journal j
   where j.tenant_id = v_tb order by j.id limit 1;
  select l.id into v_jline_b from erp.journal_line l
   where l.tenant_id = v_tb order by l.id limit 1;

  v_ids_a := erp_test.organisation_identifiers(v_ta);
  v_ids_b := erp_test.organisation_identifiers(v_tb);
  v_probes := array[v_doc_b, v_inv_b, v_party_b, v_journal_b, v_site_b];

  -- 1. As A, under the policies, every zero-argument read door shows nothing of B.
  v_step := 'walking every zero-argument read door as the first organisation';
  v_cases := v_cases + 1;
  select * into w from erp_test.walk_read_doors(v_ids_b, a_auth);
  case_name := 'as the first organisation, in the authenticated role, every zero-argument read door returns no identifier of the second';
  passed := coalesce(w.leaks is null and w.doors_walked >= 90, false);
  detail := format('%s door(s) walked, %s refused, leaks: %s; refusals: %s',
                   w.doors_walked, w.doors_refused, coalesce(w.leaks, 'none'),
                   left(coalesce(w.refusals, 'none'), 700));
  return next;

  -- 2. As B, the same.
  v_step := 'walking every zero-argument read door as the second organisation';
  v_cases := v_cases + 1;
  select * into w from erp_test.walk_read_doors(v_ids_a, b_auth);
  case_name := 'as the second organisation, in the authenticated role, every zero-argument read door returns no identifier of the first';
  passed := coalesce(w.leaks is null and w.doors_walked >= 90, false);
  detail := format('%s door(s) walked, %s refused, leaks: %s; refusals: %s',
                   w.doors_walked, w.doors_refused, coalesce(w.leaks, 'none'),
                   left(coalesce(w.refusals, 'none'), 700));
  return next;

  -- 3. As A, the write doors refuse B's things.
  v_step := 'presenting the second organisation''s things to the first''s write doors';
  v_cases := v_cases + 1;
  for v_msg in
    select unnest(array[
      format('select public.erp_transition_document(%L::uuid, ''submit'', ''isolation'')', v_doc_b),
      format('select public.erp_add_document_line(%L::uuid, %L::uuid, 1, 1, ''isolation'')', v_doc_b, v_item_b),
      format('select public.erp_set_line_stock_identity(%L::uuid, null, null, null)', v_line_b),
      format('select public.erp_stamp_document_approval(%L::uuid)', v_doc_b),
      format('select public.erp_create_document(''goods_receipt'', %L::uuid, %L::uuid, null, null, %L::uuid, null, null)', fb ->> 'sup', v_site_b, fb ->> 'gb'),
      format('select public.erp_create_batch(%L::uuid, ''X-1'', null, null, null)', v_item_b),
      format('select public.erp_set_standard_cost(%L::uuid, %L::uuid, 1, null)', v_item_b, v_site_b),
      format('select public.erp_create_location(%L::uuid, ''X'', ''X'', ''bulk'')', v_site_b),
      format('select public.erp_reserve_for_line(%L::uuid, null)', v_line_b),
      format('select public.erp_raise_intercompany_order(%L::uuid, %L::uuid)', v_doc_b, v_site_b)])
  loop
    v_tried := v_tried + 1;
    v_err := erp_test.door_call_as(a_auth, v_msg);
    if v_err is null then
      v_out := coalesce(v_out || '; ', '') || left(v_msg, 60);
    else
      v_refused := v_refused + 1;
    end if;
  end loop;
  case_name := 'as the first organisation, in the authenticated role, every write door presented with the second''s document, line, item or site refuses';
  passed := coalesce(v_refused = v_tried and v_tried = 10
        and not exists (select 1 from erp.document_line dl where dl.document_id = v_doc_b and dl.description = 'isolation')
        and not exists (select 1 from erp.batch b where b.item_id = v_item_b and b.batch_number = 'X-1'), false);
  detail := format('%s of %s refused%s', v_refused, v_tried, case when v_out is null then '' else '; accepted: ' || v_out end);
  return next;

  -- 4. The fixture really wrote what the cases below look for. Without this,
  --    every "nothing came back" case below passes on an empty organisation.
  v_step := 'confirming the second organisation has the rows the cases ask for';
  v_cases := v_cases + 1;
  case_name := 'the second organisation really has an order, an invoice, stock, a ledger entry and a customer';
  passed := coalesce(v_doc_b is not null and v_inv_b is not null and v_line_b is not null
        and v_move_b is not null and v_bal_b is not null
        and v_journal_b is not null and v_jline_b is not null and v_party_b is not null, false);
  detail := format('order %s, invoice %s, line %s, movement %s, balance %s, journal %s, journal line %s, customer %s',
                   coalesce(left(v_doc_b::text, 8), 'none'), coalesce(left(v_inv_b::text, 8), 'none'),
                   coalesce(left(v_line_b::text, 8), 'none'), coalesce(v_move_b::text, 'none'),
                   coalesce(v_bal_b::text, 'none'), coalesce(left(v_journal_b::text, 8), 'none'),
                   coalesce(left(v_jline_b::text, 8), 'none'), coalesce(left(v_party_b::text, 8), 'none'));
  return next;

  -- 5. The order, by its primary key.
  v_step := 'reading the second organisation''s order by its primary key';
  v_cases := v_cases + 1;
  n_a := erp_test.rows_visible_as(a_auth, 'erp.document', format('id = %L::uuid', v_doc_b));
  n_b := erp_test.rows_visible_as(b_auth, 'erp.document', format('id = %L::uuid', v_doc_b));
  n_a2 := erp_test.rows_visible_as(a_auth, 'erp.document_line', format('id = %L::uuid', v_line_b));
  n_b2 := erp_test.rows_visible_as(b_auth, 'erp.document_line', format('id = %L::uuid', v_line_b));
  case_name := 'the second organisation''s order and its line are not there when the first asks for them by primary key, and are when the second does';
  passed := coalesce(n_a = 0 and n_b = 1 and n_a2 = 0 and n_b2 = 1, false);
  detail := format('order: %s row(s) to the first, %s to the second; line: %s and %s', n_a, n_b, n_a2, n_b2);
  return next;

  -- 6. The invoice, by its primary key.
  v_step := 'reading the second organisation''s invoice by its primary key';
  v_cases := v_cases + 1;
  n_a := erp_test.rows_visible_as(a_auth, 'erp.document', format('id = %L::uuid', v_inv_b));
  n_b := erp_test.rows_visible_as(b_auth, 'erp.document', format('id = %L::uuid', v_inv_b));
  case_name := 'the second organisation''s invoice is not there when the first asks for it by primary key, and is when the second does';
  passed := coalesce(n_a = 0 and n_b = 1, false);
  detail := format('%s row(s) to the first, %s to the second', n_a, n_b);
  return next;

  -- 7. The stock, by primary key: the movement and the balance it left.
  v_step := 'reading the second organisation''s stock by primary key';
  v_cases := v_cases + 1;
  n_a := erp_test.rows_visible_as(a_auth, 'erp.stock_movement', format('id = %s', v_move_b));
  n_b := erp_test.rows_visible_as(b_auth, 'erp.stock_movement', format('id = %s', v_move_b));
  n_a2 := erp_test.rows_visible_as(a_auth, 'erp.stock_balance', format('id = %s', v_bal_b));
  n_b2 := erp_test.rows_visible_as(b_auth, 'erp.stock_balance', format('id = %s', v_bal_b));
  case_name := 'the second organisation''s stock movement and the balance it left are not there when the first asks for them by primary key, and are when the second does';
  passed := coalesce(n_a = 0 and n_b = 1 and n_a2 = 0 and n_b2 = 1, false);
  detail := format('movement: %s row(s) to the first, %s to the second; balance: %s and %s', n_a, n_b, n_a2, n_b2);
  return next;

  -- 8. The ledger, by primary key: the journal and one of its lines.
  v_step := 'reading the second organisation''s ledger by primary key';
  v_cases := v_cases + 1;
  n_a := erp_test.rows_visible_as(a_auth, 'erp.journal', format('id = %L::uuid', v_journal_b));
  n_b := erp_test.rows_visible_as(b_auth, 'erp.journal', format('id = %L::uuid', v_journal_b));
  n_a2 := erp_test.rows_visible_as(a_auth, 'erp.journal_line', format('id = %L::uuid', v_jline_b));
  n_b2 := erp_test.rows_visible_as(b_auth, 'erp.journal_line', format('id = %L::uuid', v_jline_b));
  case_name := 'the second organisation''s journal and its line are not there when the first asks for them by primary key, and are when the second does';
  passed := coalesce(n_a = 0 and n_b = 1 and n_a2 = 0 and n_b2 = 1, false);
  detail := format('journal: %s row(s) to the first, %s to the second; line: %s and %s', n_a, n_b, n_a2, n_b2);
  return next;

  -- 9. The customer, by its primary key.
  v_step := 'reading the second organisation''s customer by its primary key';
  v_cases := v_cases + 1;
  n_a := erp_test.rows_visible_as(a_auth, 'erp.party', format('id = %L::uuid', v_party_b));
  n_b := erp_test.rows_visible_as(b_auth, 'erp.party', format('id = %L::uuid', v_party_b));
  case_name := 'the second organisation''s customer is not there when the first asks for it by primary key, and is when the second does';
  passed := coalesce(n_a = 0 and n_b = 1, false);
  detail := format('%s row(s) to the first, %s to the second', n_a, n_b);
  return next;

  -- 10. The door that takes a document id, handed the other's document id.
  v_step := 'handing erp_document the second organisation''s order';
  v_cases := v_cases + 1;
  j_a := erp_test.read_door_as(a_auth, 'erp_document', v_doc_b);
  j_b := erp_test.read_door_as(b_auth, 'erp_document', v_doc_b);
  l_a := erp_test.read_door_as(a_auth, 'erp_document_lines', v_doc_b);
  l_b := erp_test.read_door_as(b_auth, 'erp_document_lines', v_doc_b);
  case_name := 'erp_document and erp_document_lines handed the second organisation''s order refuse the first or answer with nothing, and answer the second with the order';
  passed := coalesce(
              (j_a ->> 'refused' is not null
               or (coalesce(j_a -> 'document', 'null'::jsonb) = 'null'::jsonb
                   and jsonb_array_length(coalesce(j_a -> 'lines', '[]'::jsonb)) = 0))
              and (l_a ->> 'refused' is not null
                   or jsonb_typeof(l_a) <> 'array'
                   or jsonb_array_length(l_a) = 0)
              and j_b ->> 'refused' is null
              and (j_b -> 'document' ->> 'document_id') = v_doc_b::text
              and jsonb_array_length(coalesce(j_b -> 'lines', '[]'::jsonb)) = 1
              and jsonb_typeof(l_b) = 'array'
              and jsonb_array_length(l_b) = 1, false);
  detail := format('to the first: %s / %s; to the second: %s line(s) and %s line(s)',
                   left(j_a::text, 120), left(l_a::text, 80),
                   jsonb_array_length(coalesce(j_b -> 'lines', '[]'::jsonb)),
                   case when jsonb_typeof(l_b) = 'array' then jsonb_array_length(l_b) else -1 end);
  return next;

  -- 11. Every read door that takes an identifier, handed the other's.
  v_step := 'walking every read door that takes an identifier as the first organisation';
  v_cases := v_cases + 1;
  select * into w_a from erp_test.walk_read_doors_by_id(v_ids_b, v_probes, a_auth);
  case_name := 'as the first organisation, every read door that takes an identifier, handed the second''s order, invoice, customer, journal and site, returns nothing of the second';
  passed := coalesce(w_a.leaks is null and w_a.doors_walked >= 20, false);
  detail := format('%s door(s), %s call(s), %s refused, leaks: %s',
                   w_a.doors_walked, w_a.calls_made, w_a.calls_refused,
                   left(coalesce(w_a.leaks, 'none'), 700));
  return next;

  -- 12. The same walk as the owner of those identifiers, which must find them.
  v_step := 'walking the same doors as the second organisation';
  v_cases := v_cases + 1;
  select * into w_b from erp_test.walk_read_doors_by_id(v_ids_b, v_probes, b_auth);
  case_name := 'and the same walk as the second organisation does return them, so the case before it is not passing on a walk that reaches nothing';
  passed := coalesce(w_b.calls_exposing > 0, false);
  detail := format('%s of %s call(s) returned the second organisation''s identifiers to the second organisation',
                   w_b.calls_exposing, w_b.calls_made);
  return next;

  -- 13. Both organisations reconcile, side by side.
  v_step := 'reconciling both organisations';
  v_cases := v_cases + 1;
  perform set_config('request.jwt.claims', ''::text, true);
  v_out := erp.assert_whole_database_reconciles();
  case_name := 'with two organisations built through the doors, the whole database reconciles';
  passed := coalesce(v_out like 'whole database: % organisation(s), % check(s), all reconcile', false);
  detail := v_out;
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_stop := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  -- 14. Undone.
  perform set_config('request.jwt.claims', '', true);
  v_cases := v_cases + 1;
  case_name := 'the fixtures were undone';
  passed := coalesce(v_stop is null
        and not exists (select 1 from erp.tenant where code in ('nordwind-a', 'nordwind-b'))
        and not exists (select 1 from auth.users where id in (a_auth, b_auth)), false);
  detail := coalesce(v_stop, 'both organisations rolled back');
  return next;

  -- The count guard says what stopped the fixture. Without it the wrapper never
  -- sees a row, so the message this suite caught into v_stop — and the step that
  -- produced it — never reaches the build log, and every break costs a run.
  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_isolation_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_stop, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_stop, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.door_isolation_suite() from public, anon, authenticated;

create or replace function erp_test.assert_door_isolation_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 14;
  v_fail   integer;
  v_all    integer;
  v_detail text;
begin
  create temp table if not exists _door_isolation on commit drop as
    select * from erp_test.door_isolation_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _door_isolation;
  drop table _door_isolation;
  if v_fail > 0 then
    raise exception E'CLOVEERP_DOOR_ISOLATION_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail;
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: door_isolation_suite ran % case(s), expected %', v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('door isolation: %s/%s cases passed, every one as the caller', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_door_isolation_suite() from public, anon, authenticated;

-- The decision's note says what the suite now proves, because the note is what
-- a reader of the register sees.
insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note) values
  ('D23', 'erp_test', 'assert_door_isolation_suite',
   'Two organisations built through the doors. Every case runs in the authenticated role, so the policies are in force and not merely the doors'' own tenant filters: every zero-argument read door and every read door that takes an identifier is walked as each organisation and shows nothing of the other, the other''s order, invoice, stock movement and balance, journal and journal line and customer are each read by primary key and are not there, the same reads as their owner find them, and every write door presented with the other''s things refuses.')
on conflict (decision_code, schema_name, routine_name) do update set note = excluded.note;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The generators, then the checks a live database can answer
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();

-- The suite this migration rewrote, proved here rather than left to the
-- catalogue: it builds and rolls back its own two organisations, so it is a
-- suite a live database can answer.
select erp_test.assert_door_isolation_suite();
