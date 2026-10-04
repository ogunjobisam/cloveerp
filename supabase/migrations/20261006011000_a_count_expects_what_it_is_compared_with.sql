set lock_timeout = '30s';

-- =============================================================================
-- 20261006011000  A count expects what it is compared with
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-85). The Counting
-- worklist's Expected column read the figure frozen when the count was
-- raised. The count is not compared with that: erp.record_count() compares
-- it with that figure plus whatever moved through the place while it was
-- locked (movement_during, kept by erp.note_count_lock_movement()), less what
-- was committed and so not on the shelf. A counter who found exactly what the
-- screen expected could be told they were out, and one who found something
-- else could be told nothing was wrong.
--
-- On live, the demonstration also held 29 counts raised on 14 September and
-- never counted, each still holding its place's count lock, their expected
-- figures far from what is on hand now (PK-010 expected 2,397 with 609 on
-- hand). Nobody is going to count those; they only sit at the top of the
-- worklist and gather movement.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_count_tasks(): 'expected' is what the count is compared
--      with, expected_quantity + movement_during - committed_quantity, as
--      erp.record_count() reads it; the figure when the count was raised is
--      kept beside it as 'expected_at_raise'. So expected less variance is
--      what was counted, on every row. No new words: the worklist already
--      calls the column Expected.
--   B. erp_test.count_worklist_suite(): every row carries the new key, and a
--      new case receives five more of a product into a place while it is
--      being counted, reads 105 expected and 100 as raised, and records 105
--      as no variance. Fifteen cases, from fourteen.
--   C. DEMONSTRATIONS ONLY (organisations whose code is like 'demo-%'; not
--      clove-foods, not clove-erp, nobody's own data): every count raised
--      before 15 September and still open is cancelled through
--      erp.cancel_count_task(), the door the Counting worklist's Cancel
--      uses, so the lock is released, the task's lifecycle moves to
--      cancelled with its reason in the history, and a sheet whose last
--      count it was closes. Nothing is deleted. It acts as the
--      demonstration's administrator, as erp.catch_up_demonstrations()
--      does, because cancelling is authorised to somebody. The migration
--      says how many it cancelled. Not re-raised: the counting programme
--      raises what is due.
--
-- On production: the demonstration's open counts from 14 September move to
-- cancelled and release their locks; every other organisation's rows are
-- untouched, and every worklist's Expected now reads the compared figure.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The worklist expects what the count is compared with
-- ─────────────────────────────────────────────────────────────────────────────

do $tasks$
declare
  v_sig  constant text := 'public.erp_count_tasks(integer)';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$      'location', l.code, 'expected', c.expected_quantity, 'counted', c.counted_quantity,$o$;
  v_new  constant text := $n$      'location', l.code,
      -- What the count is compared with (20261006011000): the figure when it
      -- was raised, plus what moved through the place while it was locked,
      -- less what was committed and so not on the shelf, as
      -- erp.record_count() reads it. The figure as raised is kept beside it.
      'expected', c.expected_quantity + c.movement_during - c.committed_quantity,
      'expected_at_raise', c.expected_quantity,
      'counted', c.counted_quantity,$n$;
begin
  if strpos(v_src, '20261006011000') > 0 then
    raise notice '% already expects what the count is compared with; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '46e3ad17165b298c62cd1fa1adf59a96' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$tasks$;

comment on function public.erp_count_tasks(integer) is
  'Every count task of the organisation, open work first: where it stands, its sheet and line, the adjustment its post '
  'wrote, why an approved one waits, and whether the reader counted it. Expected is what the count is compared with '
  '(raised figure plus movement during the lock, less committed), the raised figure beside it (20261006011000). '
  'Authorises nothing; scoped to the organisation.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof: the count worklist suite reads the compared figure
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig   constant text := 'erp_test.count_worklist_suite()';
  v_src   text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def   text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old1  constant text := $o$    'counted_by_me', 'document_id', 'document_number', 'expected', 'item', 'item_name',$o$;
  v_new1  constant text := $n$    'counted_by_me', 'document_id', 'document_number', 'expected', 'expected_at_raise',
    'item', 'item_name',$n$;
  v_old2  constant text := $o$    'within_tolerance'];   -- stock_status since 20260928100000: 25 keys$o$;
  v_new2  constant text := $n$    'within_tolerance'];   -- stock_status since 20260928100000, expected_at_raise
                           -- since 20261006011000: 26 keys$n$;
  v_old3  constant text := $o$
    raise exception 'CLOVEERP_SUITE_UNDO';
$o$;
  v_new3  constant text := $n$
    -- 14. What a count expects is what it is compared with (20261006011000):
    --     the figure when it was raised, plus what moved through the place
    --     while it was being counted. E was raised at 100; five more are
    --     received into its place before anybody counts it. The worklist
    --     reads 105 expected and 100 as raised, a count of 105 is no
    --     variance, and on every row expected is what record_count compares.
    v_fixture := 'receiving five more of E while it is being counted';
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    perform erp.add_document_line(v_grn, i_e, 5, 100, 'E');
    perform erp.transition_document(v_grn, 'post');
    select x into x_e from jsonb_array_elements(public.erp_count_tasks(500)) x where x ->> 'task_id' = t_e::text;
    v_fixture := 'counting E as it stands';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := public.erp_record_count(t_e, 105)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select string_agg(x ->> 'item', ', ' order by x ->> 'item') into v_bad
      from jsonb_array_elements(public.erp_count_tasks(500)) x
      join erp.count_task t on t.id = (x ->> 'task_id')::uuid
     where (x ->> 'expected')::numeric is distinct from t.expected_quantity + t.movement_during - t.committed_quantity
        or (x ->> 'expected_at_raise')::numeric is distinct from t.expected_quantity
        or (t.counted_quantity is not null
            and (x ->> 'expected')::numeric is distinct from t.counted_quantity - t.variance);
    return query select 'a count expects what it is compared with: five received into its place while it is counted read 105 expected and 100 as raised, and a count of 105 is no variance',
      coalesce((x_e ->> 'expected')::numeric = 105 and (x_e ->> 'expected_at_raise')::numeric = 100
      and v_status = 'posted'
      and (select t.variance from erp.count_task t where t.id = t_e) = 0
      and v_bad is null, false),
      format('E expected %s, as raised %s; recorded %s with variance %s; wrong for %s',
             coalesce(x_e ->> 'expected', 'none'), coalesce(x_e ->> 'expected_at_raise', 'none'),
             coalesce(v_status, 'nothing'),
             coalesce((select t.variance::text from erp.count_task t where t.id = t_e), 'none'),
             coalesce(v_bad, 'no row'));

    raise exception 'CLOVEERP_SUITE_UNDO';
$n$;
begin
  if strpos(v_src, '20261006011000') > 0 then
    raise notice '% already reads the compared figure; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '053d085273536a9383c334fe3074a8cc' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     or (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     or (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
end
$suite$;

do $assert$
declare
  v_sig  constant text := 'erp_test.assert_count_worklist_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$  -- 14 since 20260928500000: a count whose post was refused is put back.
  if v_total <> 14 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_SHRANK: % case(s), expected 14; the fixture stopped %', v_total,$o$;
  v_new  constant text := $n$  -- 14 since 20260928500000: a count whose post was refused is put back.
  -- 15 since 20261006011000: a count expects what it is compared with.
  if v_total <> 15 then
    raise exception 'CLOVEERP_COUNT_WORKLIST_SUITE_SHRANK: % case(s), expected 15; the fixture stopped %', v_total,$n$;
begin
  if strpos(v_src, '20261006011000') > 0 then
    raise notice '% already expects fifteen cases; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> 'bf54956cb8ebda9740274a7f12ab9ca2' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261006011000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$assert$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. The demonstration's counts from 14 September, cancelled through the door
--    that cancels a count, as its administrator
-- ─────────────────────────────────────────────────────────────────────────────

do $repair$
declare
  c_before constant timestamptz := timestamptz '2026-09-15 00:00:00+00';
  c_reason constant text :=
    'Raised on 14 September and never counted. The stock has moved since, so the count is withdrawn and its place released.';
  r          record;
  k          record;
  v_admin    uuid;
  v_pref     uuid;
  v_pref_at  timestamptz;
  v_had_pref boolean;
  v_n        integer;
  v_left     integer;
begin
  for r in select tn.id, tn.code from erp.tenant tn
            where tn.deleted_at is null and tn.code like 'demo-%' order by tn.code loop
    perform erp_meta.act_in_tenant(r.id);
    continue when not exists (select 1 from erp.count_task c
                               where c.tenant_id = r.id and c.status = 'open'
                                 and c.created_at < c_before);

    -- Cancelling is authorised to somebody: the demonstration's longest-
    -- standing administrator who may count everywhere, as
    -- erp.catch_up_demonstrations() picks the person it acts as.
    v_admin := null;
    select u.auth_user_id into v_admin
      from erp.app_user u
     where u.tenant_id = r.id
       and u.kind = 'person'::erp.principal_kind
       and u.status = 'active'::erp.principal_status
       and u.auth_user_id is not null
       and erp.has_permission('inventory.count', null, null, null, u.id)
     order by u.created_at, u.id
     limit 1;
    if v_admin is null then
      raise warning 'stale counts: nobody in % may cancel a count, so its counts are left as they are', r.code;
      continue;
    end if;

    perform set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    perform set_config('erp.job_tenant_id', r.id::text, true);
    -- The administrator resolves to the organisation they last chose; it is
    -- made the demonstration for this transaction and put back after.
    select p.active_tenant_id, p.chosen_at into v_pref, v_pref_at
      from erp_meta.principal_preference p
     where p.auth_user_id = v_admin;
    v_had_pref := found;
    insert into erp_meta.principal_preference (auth_user_id, active_tenant_id, chosen_at)
    values (v_admin, r.id, now())
    on conflict (auth_user_id) do update
      set active_tenant_id = excluded.active_tenant_id, chosen_at = excluded.chosen_at;

    v_n := 0;
    if erp.current_tenant_id() is distinct from r.id or erp.current_principal_id() is null then
      raise warning 'stale counts: % does not resolve to its administrator, so its counts are left as they are', r.code;
    else
      for k in select c.id from erp.count_task c
                where c.tenant_id = r.id and c.status = 'open' and c.created_at < c_before
                order by c.created_at, c.id loop
        begin
          perform erp.cancel_count_task(k.id, c_reason);
          v_n := v_n + 1;
        exception when others then
          raise warning 'stale counts: count % of % is left open: %', k.id, r.code, sqlerrm;
        end;
      end loop;
      -- The checks the writes left waiting, fired while still in the
      -- organisation they read, so the generators below can alter the tables.
      set constraints all immediate;
    end if;

    if v_had_pref then
      update erp_meta.principal_preference
         set active_tenant_id = v_pref, chosen_at = v_pref_at
       where auth_user_id = v_admin;
    else
      delete from erp_meta.principal_preference where auth_user_id = v_admin;
    end if;
    perform set_config('request.jwt.claims', '', true);

    select count(*) into v_left from erp.count_task c
     where c.tenant_id = r.id and c.status = 'open' and c.created_at < c_before;
    raise warning 'stale counts: % count(s) of % cancelled and their places released; % left open', v_n, r.code, v_left;
  end loop;
  perform erp_meta.stop_acting_in_tenant();
end
$repair$;

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
