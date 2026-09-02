-- ─────────────────────────────────────────────────────────────────────────────
-- Register the doors 20260902121003 changed, and prove the boundary.
--
-- 20260904584000_4240c356-… was written from the dashboard as 20260902121003
-- and is applied on the live project, so it is written once and cannot be
-- edited (§16.2, and supabase/ci/migrations_immutable.sh); it is renamed to
-- sort after the migrations that create the doors it alters, content
-- untouched. It did two things the boundary assertion has to know about, and
-- did not run the assertion:
--
--   1. Twelve read doors were made VOLATILE, because each writes an
--      authorisation audit row through erp.authorise() and a STABLE function
--      cannot. A VOLATILE public function is on the write allow-list with the
--      gate it reaches, or the assertion fails it.
--   2. Four platform-staff reads over erp_meta became SECURITY DEFINER with an
--      explicit erp_meta.require_platform('support') on their first line. A
--      DEFINER public function is registered with its rationale, or the
--      assertion fails it.
--
-- Nothing here changes a function. It registers what that migration did, and
-- then runs the assertion that migration should have run, so that a build
-- from empty reaches 20260904590000 — the first later migration that asserts
-- the boundary — with a governed surface. It sorts before that one on purpose.
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_adoption_signals', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.read.'),
  ('erp_commercial_summary', 'erp.commercial_summary', 'A read made VOLATILE by 20260902121003 because the authorisation inside erp.commercial_summary() is recorded; writes nothing else.'),
  ('erp_determination_coverage_report', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. finance.read.'),
  ('erp_domain_cutovers', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. finance.read.'),
  ('erp_erasure_requests', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.read.'),
  ('erp_erasure_subjects', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.users.'),
  ('erp_help_topics', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.read.'),
  ('erp_migration_domains', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. master_data.read.'),
  ('erp_opening_batches', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. master_data.read.'),
  ('erp_parallel_run_figures', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. finance.read.'),
  ('erp_personal_data_register', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.read.'),
  ('erp_proposals', 'erp.authorise', 'A read made VOLATILE by 20260902121003 because erp.authorise() records the authorisation; writes nothing else. administration.read.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_incidents', 'Console read of erp.incident_report() over erp_meta, which is platform-internal. Gated by erp_meta.require_platform(''support'') on its first line; made DEFINER by 20260902121003.'),
  ('public', 'erp_platform_disclosures', 'Console read of erp.disclosure_report() over erp_meta. Gated by erp_meta.require_platform(''support'') on its first line; made DEFINER by 20260902121003.'),
  ('public', 'erp_platform_maintenance_windows', 'Console read of erp.maintenance_report() over erp_meta. Gated by erp_meta.require_platform(''support'') on its first line; made DEFINER by 20260902121003.'),
  ('public', 'erp_platform_incident_organisations', 'Console read of the organisations named on an incident, from erp_meta. Gated by erp_meta.require_platform(''support'') on its first line; made DEFINER by 20260902121003.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- 3. Nine platform-staff writers over erp_meta became SECURITY DEFINER. Each
--    calls erp_meta.require_platform(...) before it writes; the door in
--    public that fronts it is on the write allow-list already.
insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'declare_incident', 'Writes erp_meta.incident on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'contain_incident', 'Writes erp_meta.incident on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'resolve_incident', 'Writes erp_meta.incident on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'post_incident_update', 'Writes erp_meta.incident_update on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'name_affected_organisations', 'Writes erp_meta.incident_tenant on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'flag_security_incident', 'Writes erp_meta.incident on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'record_disclosure', 'Writes erp_meta.disclosure on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'announce_maintenance', 'Writes erp_meta.maintenance_window on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.'),
  ('erp', 'cancel_maintenance', 'Writes erp_meta.maintenance_window on behalf of platform staff; gated by erp_meta.require_platform on its first line. Made DEFINER by 20260902121003.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.assert_isolation();
select erp.assert_public_api_safe();
