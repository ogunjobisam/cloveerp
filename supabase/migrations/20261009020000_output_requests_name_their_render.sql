set lock_timeout = '30s';

-- =============================================================================
-- 20261009020000  Output requests name their render
-- -----------------------------------------------------------------------------
-- Found designing the folded rail, 4 October (design "rail", change 8). On
-- Output and printing, "Route a render to a printer" and "Reprint" each ask
-- for a render id, typed, and the hint under the box says to copy it from the
-- render listed in Recent output on this page. There is no Recent output on
-- that page, and no screen shows a render id at all: erp_output_requests, the
-- list the page draws, answers with each request's latest render (its time,
-- format, checksum, document) but not the render's own id. So neither form
-- could be filled in by anybody who had not read the database.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. public.erp_output_requests also answers render_id: the id of the latest
--      render it already describes, from the same row its rendered_at,
--      format, checksum and copy flag come from. A request not rendered yet
--      names none. It stays sql, stable and invoker, and reads what it read.
--   B. erp_test.output_channels_suite gains a case: each rendered request
--      names its latest render, and the row it names is the one the request's
--      other render fields describe.
--
-- The screen's half is in src/routes/operations/output.tsx: both forms pick
-- the render from erp_output_requests by its document, template and time,
-- under the label they had, and the hint naming a panel that does not exist
-- is deleted. No screen string is added.
--
-- ── WHAT THIS DOES NOT CHANGE ────────────────────────────────────────────────
--
-- erp_route_print and erp_reprint_output, their permissions and refusals are
-- as they were; a render id typed or picked is checked by them the same way.
--
-- On production: one read door and one test function are replaced. No table
-- is altered and no row of any organisation is touched.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. The list names the render it describes
-- ─────────────────────────────────────────────────────────────────────────────

do $requests$
declare
  v_sig  constant text := 'public.erp_output_requests()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    select jsonb_build_object(
             'id', q.id, 'template_code', t.code, 'version', r.version,
$o$;
  v_new  constant text := $n$    -- render_id is the render this row describes, so a form can pick it
    -- (20261009020000); a request not rendered yet names none.
    select jsonb_build_object(
             'id', q.id, 'render_id', r.id, 'template_code', t.code, 'version', r.version,
$n$;
begin
  if strpos(v_src, '20261009020000') > 0 then
    raise notice '% already names its render; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '0f2ad844d8e8dbf8f7c37fced1ec5b24' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009020000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$requests$;

revoke all on function public.erp_output_requests() from public, anon;

comment on function public.erp_output_requests() is
  'The organisation''s output requests, newest first and at most 500, each with its latest render and that '
  'render''s latest delivery. render_id names that render, for the forms that route or reprint one '
  '(20261009020000); a request not rendered yet names none. Reads under row security as the caller, and '
  'authorises nothing.';

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The proof
-- ─────────────────────────────────────────────────────────────────────────────

do $suite$
declare
  v_sig  constant text := 'erp_test.output_channels_suite()';
  v_src  text := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_sig::regprocedure);
  v_def  text := pg_catalog.pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$    and (select o.is_copy and o.content = v_zpl203 from erp.output_render o where o.id = (res ->> 'render_id')::uuid),
    'copy, same bytes, new row';
$o$;
  v_new  constant text := $n$    and (select o.is_copy and o.content = v_zpl203 from erp.output_render o where o.id = (res ->> 'render_id')::uuid),
    'copy, same bytes, new row';

  -- Route a render to a printer and Reprint pick the render from the list
  -- the page draws, so each rendered request names its latest render, and
  -- it is the row the request's other render fields describe
  -- (20261009020000). A reprint is a render of the same request, so the
  -- request reprinted above has two at one moment; either is its latest.
  return query select 'each rendered request names its latest render, which the print forms pick from',
    (select count(*) >= 2
            and count(*) filter (where x ->> 'rendered_at' is not null) = count(x ->> 'render_id')
            and bool_and(x ->> 'rendered_at' is not null or x ->> 'render_id' is null)
            and bool_and(x ->> 'render_id' is null or exists (
                  select 1 from erp.output_render o
                   where o.tenant_id = v_tenant and o.id = (x ->> 'render_id')::uuid
                     and o.output_request_id = q.id
                     and o.is_copy = (x ->> 'is_copy')::boolean
                     and o.checksum = x ->> 'checksum'
                     and o.rendered_at = (select max(o2.rendered_at) from erp.output_render o2
                                           where o2.tenant_id = v_tenant and o2.output_request_id = q.id)))
       from jsonb_array_elements(public.erp_output_requests()) x
       join erp.output_request q on q.tenant_id = v_tenant and q.id = (x ->> 'id')::uuid),
    'render_id is the latest render of its request';
$n$;
begin
  if strpos(v_src, '20261009020000') > 0 then
    raise notice '% already asks for the render; left as it is', v_sig;
    return;
  end if;
  if md5(v_src) <> '6a396c333c7196034adf6b6d35ecd0cc' then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % is not the body 20261009020000 expects (md5 %)', v_sig, md5(v_src);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor found other than once', v_sig;
  end if;
  execute replace(v_def, v_old, v_new);
end
$suite$;

revoke all on function erp_test.output_channels_suite() from public, anon;

comment on function erp_test.output_channels_suite() is
  'Output channels (§15.3 to §15.6): notifications routed to an audience within each person''s preferences, '
  'quiet hours, digests and escalation; a label rendered at the printer''s resolution, archived and queued; '
  'print routes, reprints and queue health; the sender''s identity. Each rendered request names its latest '
  'render, which the print forms pick from (20261009020000).';

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
