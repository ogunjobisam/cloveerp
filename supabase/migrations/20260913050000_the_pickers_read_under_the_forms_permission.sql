-- The pickers read under the form's permission.
--
-- 20260913030000 turned sixty-odd typed codes into pickers and recorded, in its
-- own header, what it could not finish: five pickers read a door that
-- authorises a different permission from the form around them, so a person
-- who may use the form and does not hold the door's permission is shown a
-- dropdown that refuses to fill; and four fields still took an identifier by
-- hand because no door listed the thing. Both halves are finished here, with
-- the two mismatches found on the way.
--
-- 1. Any of, not one. erp_dimensions, erp_departments, erp_entities and
--    erp_cost_centres each now read under whichever permission the caller
--    holds: the door's own first, then the permissions of the forms that pick
--    from it. Every branch is still a literal erp.authorise('…'), so the
--    access log names the permission actually used, the code catalogue check
--    still sees every code, and a caller with none of them is refused under
--    the door's own. A helper taking an array would have hidden the codes from
--    erp.assert_authorise_codes_exist(); the chain keeps them in view.
--
--    erp_permissions_directory is not widened. It is the organisation's
--    people directory — principals with their addresses, roles and grants —
--    and administration.roles is the right gate for that. The two forms that
--    read it wanted two small things from it: the permission catalogue, which
--    is product content, and the service accounts a key may be issued to.
--    Each gets its own door, and the directory stays where it was.
--
-- 2. Eight doors that list what a form asks for:
--      erp_permission_catalogue   every permission code, for any signed-in person
--      erp_service_accounts       the organisation's machine accounts, under administration.integrate
--      erp_config_snapshots       the snapshots a promotion took, under administration.configure
--      erp_legislation_packs      the current legislation packs, product content
--      erp_count_programmes       the counting programmes, under inventory.read
--      erp_mass_changes           the mass changes, under master_data.read
--      erp_preview_mass_change    works a mass change out before it is applied
--      erp_reports                each report once, beside erp_report_versions
--    erp_preview_mass_change is the one write: erp.preview_mass_change() has
--    existed since 20260829230000 and moves a mass change from draft to
--    previewed, and applying refuses anything not previewed, yet no door
--    reached it — so nothing on the desk could ever apply a mass change. The
--    erp function authorises nothing of its own; the door does, under
--    master_data.write, the permission applying it asks for.
--
--    erp_reports exists because the subscribe and pack pickers read
--    erp_report_versions, which lists a row per version, and a report with
--    three versions was offered three times. erp_output_templates sits beside
--    erp_output_template_versions for the same reason.
--
-- 3. Two forms named a permission the database does not ask for, which is the
--    quietest defect a desk can have: the form is shown, the submission is
--    refused. Both are corrected in src, not here — the database was right.
--    erp_merge_master_record authorises master_data.approve (since
--    20260829230000; the register row says so) and the form said write;
--    erp_rollback_to_snapshot authorises administration.promote and the form
--    said configure. erp_qualify_supplier, the only other door on
--    master_data.approve, had the same mismatch on the procurement screen.
--
-- The words the new pickers say are seeded through erp_ref.ui_key() as every
-- seeding since 20260904710000, so a tenant can rename them.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Four doors read under whichever permission the caller holds
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_dimensions()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- Under whichever the caller holds: the door's own permission, then those of
  -- the forms that pick from it (/finance/dimensions, /finance/account-determination).
  if erp.has_permission('administration.read') then
    perform erp.authorise('administration.read');
  elsif erp.has_permission('finance.configure') then
    perform erp.authorise('finance.configure');
  elsif erp.has_permission('finance.read') then
    perform erp.authorise('finance.read');
  else
    perform erp.authorise('administration.read');
  end if;
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'dimension_id', d.id, 'code', d.code, 'name', d.name,
      'derivation', d.derivation, 'is_mandatory_default', d.is_mandatory_default,
      'status', d.status,
      'value_count', (select count(*) from erp.dimension_value dv
                       where dv.tenant_id = d.tenant_id and dv.dimension_id = d.id
                         and dv.status = 'active')) as x
      from erp.dimension d
     where d.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_departments()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- Under whichever the caller holds: the door's own permission, then those of
  -- the forms that pick from it (/administration/organisation, notifications,
  -- and the procurement screen's approval routing).
  if erp.has_permission('administration.read') then
    perform erp.authorise('administration.read');
  elsif erp.has_permission('administration.configure') then
    perform erp.authorise('administration.configure');
  elsif erp.has_permission('procurement.order') then
    perform erp.authorise('procurement.order');
  else
    perform erp.authorise('administration.read');
  end if;
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'department_id', d.id, 'code', d.code, 'name', d.name,
      'entity_id', d.entity_id, 'manager_user_id', d.manager_user_id,
      'manager', mu.display_name,
      'parent_department_id', d.parent_department_id,
      'parent_code', p.code,
      'default_cost_centre', d.default_cost_centre,
      'dimension_value_id', d.dimension_value_id,
      'valid_from', d.valid_from, 'valid_to', d.valid_to,
      'status', d.status,
      'member_count', (select count(*) from erp.principal_department pd
                        where pd.tenant_id = d.tenant_id
                          and pd.department_id = d.id
                          and pd.status = 'active'),
      'band_count', (select count(*) from erp.approval_band ab
                      where ab.tenant_id = d.tenant_id
                        and ab.department_id = d.id
                        and ab.status = 'active')) as x
      from erp.department d
      left join erp.department p on p.tenant_id = d.tenant_id and p.id = d.parent_department_id
      left join erp.app_user mu on mu.tenant_id = d.tenant_id and mu.id = d.manager_user_id
     where d.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

create or replace function public.erp_entities()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- Under whichever the caller holds: the door's own permission, then those of
  -- the forms that pick a company (consolidation, account determination,
  -- dimension rules, creating companies and sites, allocation policy).
  if erp.has_permission('finance.read') then
    perform erp.authorise('finance.read');
  elsif erp.has_permission('finance.configure') then
    perform erp.authorise('finance.configure');
  elsif erp.has_permission('finance.post') then
    perform erp.authorise('finance.post');
  elsif erp.has_permission('administration.configure') then
    perform erp.authorise('administration.configure');
  else
    perform erp.authorise('finance.read');
  end if;
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'entity_id', e.id, 'code', e.code, 'name', e.name,
      'base_currency', e.base_currency, 'country_code', e.country_code) as x
      from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_entities() is
  'The organisation''s active legal entities, under finance.read or the '
  'permission of the form picking one: finance.configure, finance.post or '
  'administration.configure.';

create or replace function public.erp_cost_centres()
returns jsonb
language plpgsql
set search_path to ''
as $$
declare v_out jsonb;
begin
  -- Under whichever the caller holds: the door's own permission, then those of
  -- the forms that pick a cost centre (/finance/cost-centres, and a
  -- department's default centre on /administration/organisation).
  if erp.has_permission('finance.read') then
    perform erp.authorise('finance.read');
  elsif erp.has_permission('finance.configure') then
    perform erp.authorise('finance.configure');
  elsif erp.has_permission('administration.configure') then
    perform erp.authorise('administration.configure');
  else
    perform erp.authorise('finance.read');
  end if;
  select coalesce(jsonb_agg(x order by x ->> 'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
             'cost_centre_id', dv.id,
             'code', dv.code,
             'name', dv.name,
             'parent', (select p.code from erp.dimension_value p
                         where p.tenant_id = dv.tenant_id and p.id = dv.parent_value_id),
             'valid_from', dv.valid_from,
             'valid_to', dv.valid_to,
             'status', dv.status,
             'posted_lines', (
               select count(*) from erp.journal_line l
                where l.tenant_id = dv.tenant_id
                  and l.dimensions ->> 'COST_CENTRE' = dv.code)) as x
      from erp.dimension_value dv
      join erp.dimension d on d.tenant_id = dv.tenant_id and d.id = dv.dimension_id
     where dv.tenant_id = erp.current_tenant_id()
       and d.code = 'COST_CENTRE'
  ) s;
  return v_out;
end $$;

comment on function public.erp_cost_centres is
  'The cost centres of this organisation, with how many posted lines each '
  'carries, under finance.read or the permission of the form picking one.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Eight doors that list what a form asks for
-- ═════════════════════════════════════════════════════════════════════════════

-- The permission catalogue is product content, readable by any signed-in
-- person: the codes are the vocabulary of every form that names one.
create or replace function public.erp_permission_catalogue()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'module_code', p.module_code, 'action', p.action,
           'name', erp.text(p.name_key),
           'is_mutating', p.is_mutating, 'data_class_aware', p.data_class_aware)
         order by p.code), '[]'::jsonb)
    from erp_ref.permission p;
$$;

comment on function public.erp_permission_catalogue is
  'Every permission code the product knows, with its module and its name in '
  'the caller''s language. Product content, so open to any signed-in person; '
  'the organisation''s people, roles and grants stay behind erp_permissions_directory.';

create or replace function public.erp_service_accounts()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  perform erp.authorise('administration.integrate');
  select coalesce(jsonb_agg(x order by x->>'display_name'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'app_user_id', u.id, 'display_name', u.display_name,
      'status', u.status, 'created_at', u.created_at) as x
      from erp.app_user u
     where u.tenant_id = erp.current_tenant_id()
       and u.kind = 'service'
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_service_accounts is
  'The organisation''s machine accounts — the principals an API key may be '
  'issued to — under administration.integrate. People are not listed here.';

create or replace function public.erp_config_snapshots()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- The screen is read under administration.configure; rolling back to a
  -- snapshot is done under administration.promote, and a promoter may lack
  -- the first.
  if erp.has_permission('administration.configure') then
    perform erp.authorise('administration.configure');
  elsif erp.has_permission('administration.promote') then
    perform erp.authorise('administration.promote');
  else
    perform erp.authorise('administration.configure');
  end if;
  select coalesce(jsonb_agg(x order by x->>'taken_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'snapshot_id', s.id, 'code', s.code, 'reason', s.reason,
      'taken_at', s.taken_at, 'taken', to_char(s.taken_at, 'YYYY-MM-DD HH24:MI'),
      'entry_count', s.entry_count, 'content_hash', s.content_hash,
      'change_code', pr.change_code, 'promotion_status', pr.status) as x
      from erp.config_snapshot s
      left join lateral (
        select c.code as change_code, p.status
          from erp.promotion p
          join erp.change_set c on c.tenant_id = p.tenant_id and c.id = p.change_set_id
         where p.tenant_id = s.tenant_id and p.snapshot_id = s.id
         order by p.started_at desc
         limit 1) pr on true
     where s.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_config_snapshots is
  'The configuration snapshots this organisation holds, newest first, each '
  'with the change whose promotion took it, so a rollback is chosen rather '
  'than typed.';

-- Product content, like the permission catalogue: which packs exist is not a
-- secret of any organisation, and the form that names one is gated on its own.
create or replace function public.erp_legislation_packs()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', l.code, 'version', l.version, 'jurisdiction', l.jurisdiction,
           'name', erp.text(l.name_key), 'description', l.description,
           'effective_from', l.effective_from, 'effective_to', l.effective_to,
           'requires_gapless', l.requires_gapless)
         order by l.jurisdiction, l.code), '[]'::jsonb)
    from erp_ref.legislation_pack l
   where l.is_current;
$$;

comment on function public.erp_legislation_packs is
  'The legislation packs currently shipped, by jurisdiction, for the forms '
  'that bind a company or a posting rule to one.';

create or replace function public.erp_count_programmes()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- The stock audit screen is read under inventory.read; raising tasks from a
  -- programme is done under inventory.count.
  if erp.has_permission('inventory.read') then
    perform erp.authorise('inventory.read');
  elsif erp.has_permission('inventory.count') then
    perform erp.authorise('inventory.count');
  else
    perform erp.authorise('inventory.read');
  end if;
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'programme_id', c.id, 'code', c.code, 'name', c.name, 'kind', c.kind,
      'site_id', c.site_id, 'site', st.code,
      'tolerance_absolute', c.tolerance_absolute, 'tolerance_pct', c.tolerance_pct,
      'approval_chain_code', c.approval_chain_code, 'status', c.status) as x
      from erp.count_programme c
      left join erp.site st on st.tenant_id = c.tenant_id and st.id = c.site_id
     where c.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_count_programmes is
  'The counting programmes of this organisation with their site, kind, '
  'tolerances and status. Raising tasks refuses a programme that is not '
  'active, so the status is shown beside the code.';

create or replace function public.erp_mass_changes()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_out jsonb;
begin
  -- The governance screen is read under master_data.read; a mass change is
  -- opened, previewed, applied and reversed under master_data.write.
  if erp.has_permission('master_data.read') then
    perform erp.authorise('master_data.read');
  elsif erp.has_permission('master_data.write') then
    perform erp.authorise('master_data.write');
  else
    perform erp.authorise('master_data.read');
  end if;
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'mass_change_id', m.id, 'code', m.code, 'object_type', m.object_type,
      'status', m.status, 'affected', m.affected, 'reason', m.reason,
      'opened_by', u.display_name, 'created_at', m.created_at,
      'applied_at', m.applied_at, 'reversed_at', m.reversed_at) as x
      from erp.mass_change m
      left join erp.app_user u on u.tenant_id = m.tenant_id and u.id = m.created_by
     where m.tenant_id = erp.current_tenant_id()
  ) s;
  return v_out;
end;
$$;

comment on function public.erp_mass_changes is
  'The mass changes of this organisation, newest first, with their status: '
  'draft, previewed, applied or reversed. Applying wants a previewed one and '
  'reversing an applied one, so the status is shown beside the code.';

create or replace function public.erp_preview_mass_change(p_mass_change_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_rows jsonb;
begin
  -- erp.preview_mass_change() authorises nothing of its own and moves a draft
  -- to previewed; the door asks for the permission applying it will ask for.
  perform erp.authorise('master_data.write', null, null, null, 'mass_change', p_mass_change_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'object_id', p.object_id, 'code', p.code,
           'before', p.before_value, 'after', p.after_value) order by p.code), '[]'::jsonb)
    into v_rows
    from erp.preview_mass_change(p_mass_change_id) p;
  return jsonb_build_object('mass_change_id', p_mass_change_id,
                            'affected', jsonb_array_length(v_rows),
                            'records', v_rows);
end;
$$;

comment on function public.erp_preview_mass_change is
  'Works out which records a mass change would touch and what each would '
  'become, and marks it previewed, which applying requires. Under '
  'master_data.write.';

-- Each report once, beside erp_report_versions which lists each version.
create or replace function public.erp_reports()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'code', r.code,
           'name', coalesce(r.name, r.name_key), 'module_code', r.module_code,
           'status', r.status,
           'governed_view', g.code,
           'versions', (select count(*) from erp.report_version v
                         where v.tenant_id = r.tenant_id and v.report_id = r.id),
           'version_in_force', (select max(v.version) from erp.report_version v
                                 where v.tenant_id = r.tenant_id and v.report_id = r.id
                                   and v.status = 'active'
                                   and v.effective_from <= current_date
                                   and (v.effective_to is null or v.effective_to > current_date)))
         order by r.code), '[]'::jsonb)
    from erp.report r
    left join erp.governed_view g on g.tenant_id = r.tenant_id and g.id = r.governed_view_id
   where r.tenant_id = erp.require_tenant_id();
$$;

comment on function public.erp_reports is
  'Each report of this organisation once, with how many versions it has and '
  'which is in force. erp_report_versions lists the versions themselves.';

-- ── Nobody in particular may call any of this ────────────────────────────────

revoke all on function public.erp_permission_catalogue() from public, anon;
revoke all on function public.erp_service_accounts() from public, anon;
revoke all on function public.erp_config_snapshots() from public, anon;
revoke all on function public.erp_legislation_packs() from public, anon;
revoke all on function public.erp_count_programmes() from public, anon;
revoke all on function public.erp_mass_changes() from public, anon;
revoke all on function public.erp_preview_mass_change(uuid) from public, anon;
revoke all on function public.erp_reports() from public, anon;

grant execute on function public.erp_permission_catalogue() to authenticated, service_role;
grant execute on function public.erp_service_accounts() to authenticated, service_role;
grant execute on function public.erp_config_snapshots() to authenticated, service_role;
grant execute on function public.erp_legislation_packs() to authenticated, service_role;
grant execute on function public.erp_count_programmes() to authenticated, service_role;
grant execute on function public.erp_mass_changes() to authenticated, service_role;
grant execute on function public.erp_preview_mass_change(uuid) to authenticated, service_role;
grant execute on function public.erp_reports() to authenticated, service_role;

-- ── The write register says what each volatile door writes under ────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_cost_centres', 'erp.authorise',
   'Lists cost centres under finance.read, or under the permission of the form picking one. Writes only the access-log row erp.authorise() raises.'),
  ('erp_service_accounts', 'erp.authorise',
   'Lists the organisation''s machine accounts under administration.integrate. Writes only the access-log row erp.authorise() raises.'),
  ('erp_config_snapshots', 'erp.authorise',
   'Lists configuration snapshots under administration.configure or administration.promote. Writes only the access-log row erp.authorise() raises.'),
  ('erp_count_programmes', 'erp.authorise',
   'Lists counting programmes under inventory.read or inventory.count. Writes only the access-log row erp.authorise() raises.'),
  ('erp_mass_changes', 'erp.authorise',
   'Lists mass changes under master_data.read or master_data.write. Writes only the access-log row erp.authorise() raises.'),
  ('erp_preview_mass_change', 'erp.authorise',
   'Previews a mass change under master_data.write, moving a draft to previewed; erp.preview_mass_change() authorises nothing of its own, so the door does.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── Each screen's help names the doors it now offers ─────────────────────────

select erp_meta.add_help_actions('/administration/configuration', array['erp_config_snapshots']);
select erp_meta.add_help_actions('/finance/account-determination', array['erp_legislation_packs']);
select erp_meta.add_help_actions('/inventory/audit', array['erp_count_programmes']);
select erp_meta.add_help_actions('/governance', array['erp_mass_changes', 'erp_preview_mass_change']);
select erp_meta.add_help_actions('/reporting/distribution', array['erp_reports']);
select erp_meta.add_help_actions('/operations/integrations', array['erp_service_accounts', 'erp_permission_catalogue']);
select erp_meta.add_help_actions('/administration/adoption', array['erp_permission_catalogue']);

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The words the new pickers say
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Screen string of a form field that now picks from what the database knows: a label, a hint, or a description.'
  from (values
    ('Mass change'),
    ('Only a previewed mass change can be applied.'),
    ('Only an applied mass change can be reversed.'),
    ('Preview a mass change'),
    ('Programme'),
    ('Report'),
    ('Snapshot'),
    ('Works out which records the selector matches and what each would become. A mass change is applied only after it has been previewed.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Generators, then the checks that read what changed
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
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_guidance_sound();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
