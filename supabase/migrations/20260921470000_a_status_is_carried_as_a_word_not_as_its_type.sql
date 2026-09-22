set lock_timeout = '30s';

-- =============================================================================
-- 20260921470000  A variable called v_from is read as the word FROM
-- -----------------------------------------------------------------------------
-- erp.assert_no_missing_relations() refused erp.bootstrap_change_set() on the
-- build, with one finding:
--
--     erp.bootstrap_change_set reads erp.change_set_status, which does not exist
--
-- It is a false positive, and the mechanism is worth writing down because the
-- next person to meet it will spend the same half hour.
--
-- erp.missing_relation_report() looks for a schema-qualified name sitting where
-- a relation goes, which it finds with
--
--     (?:from|join|update|into|delete\s+from)\s+((?:erp|…)\.[a-z_][a-z0-9_]*)
--
-- and the start of that keyword is not anchored to a word boundary. The routine
-- declared
--
--     v_from   erp.change_set_status;
--
-- so the last four characters of the variable's own name matched `from`, the
-- spaces after it matched `\s+`, and the enum type that followed was read as a
-- table nobody had created. Any local whose name ends in from, join, update or
-- into, declared as a schema-qualified type, produces the same finding.
--
-- ── WHAT THIS FILE DOES ABOUT IT ─────────────────────────────────────────────
--
-- The variable is renamed. It is not a workaround dressed up: it was a poor
-- name — it held what the change set WAS before the work, and v_was says that
-- where v_from reads like the start of a query. It is text rather than the enum
-- as well, because the value it carries goes straight into json, where it is a
-- string whichever way it is declared.
--
-- The missing anchor is a real defect in erp.missing_relation_report() and it
-- is not repaired here: that check reads every plpgsql routine in six schemas,
-- and tightening its pattern is a change whose blast radius is the whole
-- product rather than one routine. It is raised separately.
--
-- Forward, not an edit. 20260921410000 applied cleanly and created a working
-- routine; what it left behind was one static finding, and a later CREATE OR
-- REPLACE is all that takes to settle it.
-- =============================================================================

create or replace function erp.bootstrap_change_set(p_change_set_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  cs       erp.change_set%rowtype;
  -- What the change set was before this call, as a word. Not v_from: the
  -- relation check reads the end of that name as the keyword FROM and then
  -- reads whatever type follows it as a table that does not exist.
  v_was    text;
begin
  perform erp.authorise('administration.promote', null, null, null,
                        'change_set', p_change_set_id);

  select * into cs
    from erp.change_set c
   where c.tenant_id = v_tenant and c.id = p_change_set_id;

  if not found then
    raise exception
      'CLOVEERP_CHANGE_SET_NOT_FOUND: no change set % in this organisation', p_change_set_id
      using errcode = '23503',
            hint = 'Check the change set is one of this organisation''s own; a change '
                   'set belonging to another organisation is not visible here.';
  end if;

  -- Before anything is submitted, approved or promoted. A refusal after a
  -- partial run would leave a change set half-way through a route that is not
  -- allowed here at all.
  if erp.tenant_is_live(v_tenant) then
    raise exception
      'CLOVEERP_BOOTSTRAP_ON_A_LIVE_ORGANISATION: % may not be approved and promoted in one call once this organisation is live', cs.code
      using errcode = '42501',
            hint = 'This shortcut exists for an organisation still being built, '
                   'where there is nobody else to approve. On a live one, submit '
                   'the change and ask somebody who may promote configuration to '
                   'approve it and put it in force.';
  end if;

  v_was := cs.status::text;

  if cs.status = 'draft' then
    perform erp.submit_change_set(p_change_set_id);
  end if;

  perform erp.approve_change_set(p_change_set_id);
  perform erp.promote_change_set(p_change_set_id);

  select * into cs
    from erp.change_set c
   where c.tenant_id = v_tenant and c.id = p_change_set_id;

  return jsonb_build_object(
    'change_set_id', p_change_set_id,
    'code', cs.code,
    'was', v_was,
    'status', cs.status,
    'items', (select count(*) from erp.change_set_item i
               where i.tenant_id = v_tenant and i.change_set_id = p_change_set_id));
end;
$$;

revoke all on function erp.bootstrap_change_set(uuid) from public, anon, authenticated;

comment on function erp.bootstrap_change_set(uuid) is
  'Submits, approves and promotes one change set, and only while the '
  'organisation is still being built. Refuses outright once it is live, where '
  'approving is somebody else''s to do. The route erp.install_module_config() '
  'already takes, written once so a reseed does not write it again.';

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the proof
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.assert_no_missing_relations() is run from here, because it is the check
-- this file answers and a repair that does not run the check it repairs is a
-- claim rather than a proof. The suite that exercises the route is not run
-- here: it provisions two people's worth of organisation and takes it live, so
-- the catalogue runs it.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_no_missing_relations();
select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
