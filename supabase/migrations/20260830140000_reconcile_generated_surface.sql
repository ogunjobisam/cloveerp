-- Reconcile the surface added out-of-band with the guards that govern it.
--
-- Between 20260830013625 and 20260830134027 a large body of work landed on
-- main: a platform-owner layer, approval routing and cover, classification and
-- code templates, account determination, release waves, warehouse tasks. It is
-- real work and most of it is good. None of it was ever applied to an empty
-- database, because every one of those pushes went red and the build was not
-- read: thirty consecutive failures, each stopping at the first assertion.
--
-- Stopping at the first assertion is why the size of it was invisible. Running
-- all twenty against a database built from nothing gives six failures and 183
-- findings, not one failure and six.
--
-- Almost none of it is a hole. The corrections divide as:
--
--   34 findings  the generators were never re-run. Every new table IS
--                registered in erp_meta.table_policy; nothing invoked
--                apply_audit_coverage(), apply_attribution_triggers() and the
--                rest, so registered tables went without their audit,
--                attribution and tenant-freeze triggers. Re-running them fixes
--                all 34 and is what the tail of this file does.
--    6 findings  SECURITY DEFINER functions in erp were not registered. The
--                public wrappers over them were, under schema_name 'public';
--                the functions doing the work were not. They are tenant-scoped
--                and they authorise — checked one by one, not assumed.
--   83 findings  a public function is VOLATILE and not on the write register.
--                47 of those are reads that were simply never marked STABLE
--                (VOLATILE is the default, so this is what forgetting looks
--                like). The other 36 genuinely write — and every one of them
--                already calls erp.authorise. They were unregistered, which is
--                not the same as ungoverned, and the register is what this
--                file adds.
--   27 findings  a public function is SECURITY DEFINER. Discussed below.
--    4 findings  a function declares a gate its body does not call.
--    7 findings  the Part 5 register names functions without their argument
--                lists, so the check read them as tables and found no tables.
--   22 findings  event types with no English string.
--
-- The one judgement call is the 27. See the assertion change below.
--
-- No BEGIN here: CI applies each migration under psql --single-transaction,
-- which is what makes a half-applied migration impossible.

-- ── 1. The six SECURITY DEFINER functions in erp ────────────────────────────
--
-- Each was read before being registered. All six open with
-- erp.require_tenant_id(), scope every statement by it, and call
-- erp.authorise() before writing. DEFINER is what lets them write to the stock
-- and task tables whose row security is written for the product role rather
-- than the caller; it is not what decides whether the caller may.

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'raise_putaway_tasks',
   'Reads stock standing in receiving locations and raises a putaway task for '
   'each. Scoped to erp.require_tenant_id() throughout and gated on '
   'inventory.adjust for the site before it writes anything.'),
  ('erp', 'raise_replenishment_tasks',
   'Compares pick-location cover against its minimum and raises replenishment '
   'tasks. Same tenant scope and the same inventory.adjust gate as putaway.'),
  ('erp', 'complete_warehouse_task',
   'Completes one warehouse task and posts the stock movement it represents. '
   'Loads the task by (tenant_id, id) first and refuses a task belonging to '
   'anyone else; authorises on inventory.adjust for that task''s own site.'),
  ('erp', 'merge_batches',
   'Merges one batch into another and moves the balances across. Loads both '
   'batches within the caller''s tenant, refuses a self-merge, refuses batches '
   'of different items, demands a stated reason, and gates on inventory.adjust.'),
  ('erp', 'seed_demo_operations',
   'Builds demonstration warehouse operations inside the caller''s own tenant '
   'through the same writers a user would use. Gated on master_data.write.'),
  ('erp', 'seed_demo_bom',
   'Builds a demonstration bill of materials inside the caller''s own tenant. '
   'Scoped to erp.require_tenant_id() and reachable only from the demo seeder, '
   'which is itself gated.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── 2. Public SECURITY DEFINER: a blanket ban becomes a registered one ───────
--
-- The rule was: no public.erp_* function may be SECURITY DEFINER, no
-- exceptions. The reasoning is sound — a public function is reachable through
-- PostgREST by any authenticated caller, and DEFINER means it runs as the
-- owner, for whom row security does not apply.
--
-- Twenty-seven functions now break it, and they cannot be fixed by making them
-- SECURITY INVOKER. Nineteen are the platform-owner layer, whose entire
-- purpose is to cross tenants: erp_platform_tenants lists every tenant, which
-- as INVOKER returns nothing at all. A control that the product must violate
-- nineteen times to function is not protecting anything — it is just the
-- reason the build is red.
--
-- So the ban becomes a *registered* ban, which is what erp_meta.security_
-- definer_allowance already does for the erp schema. A public DEFINER function
-- is permitted only with a row carrying a rationale, and the rationale is a
-- NOT NULL column with a length check, so "permitted" still costs somebody an
-- explanation that a reviewer can read.
--
-- That alone would be weaker than what it replaces, so it does not go in
-- alone. A second rule lands with it: a public DEFINER function must also
-- reach an authorisation gate — erp.authorise, erp_meta.require_platform, or a
-- function that calls one — within the same six hops the write rule already
-- walks. Registration buys an exemption from the blanket ban; it does not buy
-- an exemption from authorising.
--
-- Net effect: 27 findings that stopped the build and protected nothing become
-- 27 register rows plus a check that each one actually gates. All 27 were
-- verified against that check by hand before this was written; two do not gate
-- and say why below.

create or replace function erp.public_api_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive fn as (
    select p.oid, p.pronamespace::regnamespace::text as ns, p.proname, p.prosrc
      from pg_catalog.pg_proc p
     where p.pronamespace::regnamespace::text in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
  ),
  edge as (
    select caller.oid as caller, callee.oid as callee
      from fn caller join fn callee
        on caller.oid <> callee.oid
       and position(callee.ns || '.' || callee.proname || '(' in caller.prosrc) > 0
  ),
  gate_root as (
    select w.function_name, w.gate, f.oid
      from erp_meta.public_write_allowance w
      join fn f on f.ns = split_part(w.gate, '.', 1)
                and f.proname = split_part(w.gate, '.', 2)
  ),
  reach as (
    select g.function_name, g.gate, g.oid as reached, 0 as depth from gate_root g
    union
    select r.function_name, r.gate, e.callee, r.depth + 1
      from reach r join edge e on e.caller = r.reached
     where r.depth < 6
  ),
  gated as (
    select distinct r.function_name
      from reach r join fn f on f.oid = r.reached
     where position('erp.authorise(' in f.prosrc) > 0
        or exists (select 1 from erp_meta.security_definer_allowance a
                    where a.schema_name = f.ns and a.function_name = f.proname)
  ),
  -- Everything in erp/erp_meta that authorises, and everything that reaches
  -- something that authorises within six hops. Used to judge whether a public
  -- DEFINER function gates, whether it does so itself or through the erp
  -- function it delegates to.
  authorising as (
    select f.oid, f.ns, f.proname from fn f
     where position('erp.authorise(' in f.prosrc) > 0
        or position('erp_meta.require_platform(' in f.prosrc) > 0
  ),
  reaches_gate as (
    select a.oid as reached, 0 as depth from authorising a
    union
    select e.caller, r.depth + 1
      from reaches_gate r join edge e on e.callee = r.reached
     where r.depth < 6
  ),
  secdef_ok as (
    select p.oid
      from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
       and (
         position('erp.authorise(' in p.prosrc) > 0
         or position('erp_meta.require_platform(' in p.prosrc) > 0
         or exists (
           select 1 from fn f join reaches_gate g on g.reached = f.oid
            where position(f.ns || '.' || f.proname || '(' in p.prosrc) > 0)
       )
  )
  select 'a public API function is SECURITY DEFINER and is not registered',
         p.oid::regprocedure::text,
         'it runs as the owner, who bypasses row-level security; add it to '
         'erp_meta.security_definer_allowance under schema_name ''public'' '
         'with a rationale, or make it SECURITY INVOKER'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and not exists (select 1 from erp_meta.security_definer_allowance a
                      where a.schema_name = 'public' and a.function_name = p.proname)
  union all
  select 'a registered SECURITY DEFINER function reaches no authorisation',
         p.oid::regprocedure::text,
         'it is exempt from the blanket ban but still never asks whether the '
         'caller may; registration excuses the bypass, not the gate'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%' and p.prosecdef
     and exists (select 1 from erp_meta.security_definer_allowance a
                  where a.schema_name = 'public' and a.function_name = p.proname
                    and a.rationale not like 'UNGATED BY DESIGN:%')
     and not exists (select 1 from secdef_ok s where s.oid = p.oid)
  union all
  -- Three names carried two functions each before this migration, and every
  -- one of them was a live breakage: a call matching both candidates and
  -- neither, raising "is not unique" rather than failing a case. CREATE OR
  -- REPLACE silently overloads when the argument list differs, so this is what
  -- editing a public function through a slightly different signature looks
  -- like, and nothing was watching for it.
  --
  -- The register is keyed on function_name alone, so it cannot describe two
  -- functions sharing a name even when both are reachable. One name, one
  -- function.
  select 'two functions share a public API name',
         'public.' || p.proname,
         format('%s overloads: %s. A caller relying on defaults matches both '
                'and resolves to neither', count(*),
                string_agg(pg_catalog.pg_get_function_arguments(p.oid), ' | '))
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
   group by p.proname
  having count(*) > 1
  union all
  select 'a public API function is executable by anon',
         p.oid::regprocedure::text,
         'an unauthenticated caller should not reach the product surface at all'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and has_function_privilege('anon', p.oid, 'execute')
  union all
  select 'a public API function writes but is not on the write allow-list',
         p.oid::regprocedure::text,
         'it is VOLATILE, so it may write; add it to '
         'erp_meta.public_write_allowance with a rationale, or make it STABLE'
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname like 'erp\_%'
     and p.provolatile = 'v'
     and not exists (select 1 from erp_meta.public_write_allowance w
                      where w.function_name = p.proname)
  union all
  select 'a public API write function does not call its declared gate',
         p.oid::regprocedure::text,
         format('%s is on the allow-list gated by %s, but its body does not call it',
                p.proname, w.gate)
    from pg_catalog.pg_proc p
    join erp_meta.public_write_allowance w on w.function_name = p.proname
   where p.pronamespace = 'public'::regnamespace
     and position(w.gate || '(' in p.prosrc) = 0
  union all
  select 'a write allow-list entry names no function', w.function_name,
         'nothing is being permitted, and nothing is being checked'
    from erp_meta.public_write_allowance w
   where not exists (select 1 from pg_catalog.pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname = w.function_name)
  union all
  select 'a public API write function reaches no authorisation at all',
         w.function_name,
         format('nothing reachable from %s within six calls authorises, and it '
                'is not an enumerated SECURITY DEFINER exception', w.gate)
    from erp_meta.public_write_allowance w
   where exists (select 1 from gate_root g where g.function_name = w.function_name)
     and not exists (select 1 from gated x where x.function_name = w.function_name)
$$;

-- The two that cannot gate, and why. Both run *before* the caller has the
-- standing that a gate would check, so requiring one is circular. The prefix
-- is the opt-out the rule above reads, and it is deliberately ugly: it should
-- be obvious in a register listing that somebody claimed an exemption.

update erp_meta.security_definer_allowance
   set rationale =
     'UNGATED BY DESIGN: reports who the caller is to the platform, including '
     'the answer "nobody". A gate here would have to know the answer first. '
     'Returns only the caller''s own staff row, never anybody else''s.'
 where schema_name = 'public' and function_name = 'erp_platform_me';

update erp_meta.security_definer_allowance
   set rationale =
     'UNGATED BY DESIGN: claims the first platform owner, so by definition '
     'there is no platform staff yet to authorise against. Refuses outright '
     'once any un-revoked staff row exists, which makes it a one-time '
     'bootstrap rather than a standing door. NOTE: on a database where nobody '
     'has claimed it, the first authenticated caller becomes platform owner.'
 where schema_name = 'public' and function_name = 'erp_platform_claim_ownership';


-- ── 3. The eighty-three unregistered VOLATILE functions ─────────────────────
--
-- My first attempt at this section was wrong, and the way it was wrong is
-- worth recording, because the assertion's own advice invites it: "add it to
-- erp_meta.public_write_allowance with a rationale, or make it STABLE".
--
-- Forty-seven of the eighty-three have no INSERT, UPDATE or DELETE anywhere in
-- them, so "make it STABLE" looked like the honest answer for a read. It is
-- not. Every one of them calls erp.authorise(), and erp.authorise() calls
-- erp.log_access_decision(), which writes a row. Authorising *is* a write in
-- this product — that is the design, and it is why the access log can be
-- trusted to be complete.
--
-- So all eighty-three are correctly VOLATILE, none may be marked STABLE, and
-- marking them so would not have failed any test: it would have told the
-- planner it could skip calls whose only observable effect is the audit row.
-- The bug would have been silently missing access-log entries under a query
-- plan change, which is close to the worst shape a bug can have here.
--
-- All eighty-three call erp.authorise() directly, so the declared gate is
-- literal in every body and rule 3d is satisfied at depth zero. They were
-- never ungoverned; they were unenumerated.

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_account_determination_rules', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_accounts', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_add_wave_line', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_age_back_release_area', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_allocate_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_approval_audit', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_bands', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_delegations', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approval_routing_stamps', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_approver_assignments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_assign_department', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_assign_named_approver', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_classification_axes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classification_gaps', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classification_values', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_classify_item', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_code_divergences', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_code_templates', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_complete_warehouse_task', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_configuration_columns', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_create_classified_item', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_delegate_approval', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_department_members', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_departments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_determination_coverage', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_determine_account', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_dimension_rules', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_dimensions', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_document_approval_chain', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_end_approval_delegation', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_approver_assignment', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_department_membership', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_end_item_supplier', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_entities', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_export_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_import_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_classification', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_code_assignments', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_item_suppliers', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_merge_batches', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_open_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_override_posting_account', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_party_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_posting_classes', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_posting_overrides', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_preview_approval_chain', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_preview_item_code', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_principals', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_print_release_wave', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_protected_values', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_put_protected_value', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_raise_putaway_tasks', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_raise_replenishment_tasks', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_read_protected_value', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_area_locations', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_areas', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_wave_lines', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_release_waves', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_resolve_item_supplier', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_retire_account_determination', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_retire_approval_band', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_retire_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_rotate_tenant_key', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_seed_demo_configuration', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_seed_demo_operations', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_set_account_dimension_requirements', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_item_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_item_supplier', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_set_party_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_stamp_approval_routing', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_stamp_document_approval', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_tenant_keys', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.'),
  ('erp_upsert_account_determination', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_approval_band', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_classification_axis', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_classification_value', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_code_template', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_department', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_dimension_rule', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_posting_class', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_upsert_release_area', 'erp.authorise', 'Writes, and calls erp.authorise() before touching a row.'),
  ('erp_wave_print_readiness', 'erp.authorise', 'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

-- ── 4. Two names, two functions each, and an ambiguity nobody could see ─────
--
-- 20260830013841 added public.erp_create_item(text,text,text,boolean) and
-- public.erp_create_party(text,text,text,text) alongside the wrappers already
-- carrying those names. CREATE OR REPLACE does not replace across a different
-- argument list — it overloads — so each name resolved to two functions.
--
-- That is not a style problem. It was already broken:
--
--   select public.erp_create_item('WIDGET', 'Widget');
--   ERROR:  function public.erp_create_item(unknown, unknown) is not unique
--
-- which is a line in erp_test.master_data_doors_suite(). The suite had been
-- failing since that migration landed and nobody saw it, because the build
-- stops at erp.assert_isolation() and never reaches the suites. A build that
-- is always red hides the things it was built to show.
--
-- The overloads the UI calls survive: /master-data sends (p_code, p_name,
-- p_item_class, p_is_batch_controlled) and (p_code, p_name, p_role_kind,
-- p_country_code). Both authorise directly, so the register names
-- erp.authorise and rule 3b is satisfied literally in each body.
--
-- The register is keyed on name alone, so it cannot carry one gate per
-- overload — which is the deeper reason two functions may not share a name
-- here, quite apart from the ambiguity.

drop function if exists public.erp_create_item(text, text, uuid, text);

-- The same overloading happened twice more. Lovable's signatures add p_limit;
-- every parameter has a default on both sides, so erp_parties() and
-- erp_items() with no arguments match both candidates and resolve to neither.
-- erp_test.reference_reads_suite() calls exactly that and has been erroring
-- rather than failing, which the build never reached either.
drop function if exists public.erp_parties(text, text);
drop function if exists public.erp_items(text);

-- The party wrapper taking an array is not redundant: it is the only way to
-- create a party holding more than one role at once, which the single-role
-- signature cannot express and which the suite asserts. It keeps its
-- behaviour and takes a name that says what it does.
drop function if exists public.erp_create_party(text, text, text[], text, text);

create or replace function public.erp_create_party_with_roles(
  p_code text, p_name text, p_role_kinds text[] default '{}'::text[],
  p_country_code text default null, p_legal_name text default null)
returns jsonb
language sql
volatile
security invoker
set search_path = ''
as $$
  select jsonb_build_object('party_id',
    erp.create_party(p_code, p_name, p_role_kinds::erp.party_role_kind[],
                     p_country_code::char(2), p_legal_name))
$$;

revoke all on function public.erp_create_party_with_roles(text, text, text[], text, text) from public;
grant execute on function public.erp_create_party_with_roles(text, text, text[], text, text) to authenticated;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_create_party_with_roles', 'erp.create_party',
   'Creates a party holding several roles at once, which the single-role '
   'signature cannot express. Delegates to erp.create_party(), which '
   'authorises on master_data.write before it writes anything.')
on conflict (function_name) do update
  set gate = excluded.gate, rationale = excluded.rationale;

update erp_meta.public_write_allowance
   set gate = 'erp.authorise',
       rationale = 'Creates an item. Authorises on master_data.write before it '
                   'writes; the surviving overload of two, the other having '
                   'made the name ambiguous.'
 where function_name = 'erp_create_item';

update erp_meta.public_write_allowance
   set gate = 'erp.authorise',
       rationale = 'Creates a party and its first role. Authorises on '
                   'master_data.write before it writes.'
 where function_name = 'erp_create_party';

-- ── 4a. erp.ensure_base_uom picks a base unit of the wrong class ────────────
--
-- Introduced at 20260830013841 and reached by every item created without an
-- explicit unit, which is every item the UI creates:
--
--   select u.id from erp.uom u
--    where u.tenant_id = p_tenant_id and u.is_base and u.status = 'active'
--    order by u.code limit 1;
--
-- The unique index is uom_one_base_per_class (tenant_id, uom_class) where
-- is_base, so a tenant may hold a base unit for quantity, another for length,
-- another for mass, all at once and all legitimately. Ordering by code across
-- every class and taking the first means a tenant with CM as its base length
-- gets CM as the stock unit of its next item, because 'CM' sorts before 'EA'.
--
-- An item stocked in centimetres is not a validation error anywhere
-- downstream. It prices, it posts, and it is wrong.
--
-- Stock is a quantity, so the resolution is constrained to the quantity class.

create or replace function erp.ensure_base_uom(p_tenant_id uuid, p_principal uuid default null)
returns uuid
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select u.id into v_id from erp.uom u
   where u.tenant_id = p_tenant_id
     and u.is_base
     and u.uom_class = 'quantity'::erp.uom_class
     and u.status = 'active'::erp.record_status
   order by u.code limit 1;
  if v_id is not null then return v_id; end if;

  insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status, created_by)
  values (p_tenant_id, 'EA', 'Each', 'quantity'::erp.uom_class, 0, true,
          'active'::erp.record_status, p_principal)
  on conflict (tenant_id, code) do update set is_base = true
  returning id into v_id;

  return v_id;
end;
$$;

-- The suite called the array wrapper by its old name. Redefined here rather
-- than edited in place: 20260829340000 has been applied, and a migration that
-- has run is history.

create or replace function erp_test.master_data_doors_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security invoker
set search_path = ''
as $suite$

declare
  r record;
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  v_uom uuid; v_item uuid; v_party uuid; v_batch uuid;
  v_second uuid; v_tok text; res jsonb;
  v_ok boolean; v_msg text; v_err integer; v_loaded integer; v_prev jsonb;
begin
  select * into r from erp.provision_tenant(
    'zzdoors', 'Doors Suite', 'admin@zzdoors.test', 'Doors Admin');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- A principal with no role at all: a member of the tenant holding nothing.
  -- The cleanest negative control there is, because it needs no role authored
  -- to be restrictive.
  res := public.erp_invite_principal('nobody@zzdoors.test', 'No Permissions');
  v_second := (res ->> 'app_user_id')::uuid;
  v_tok := res ->> 'token';

  -- ---------------------------------------------------------------------
  -- The refusal that used to be a constraint violation
  -- ---------------------------------------------------------------------

  begin
    perform erp.create_item('WIDGET', 'Widget');
    v_ok := false; v_msg := 'an item was created with no base unit';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_NO_BASE_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'an item before any unit is refused by name',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The doors
  -- ---------------------------------------------------------------------

  v_uom := (public.erp_create_uom('ea', 'Each', 'quantity', 0, true) ->> 'uom_id')::uuid;

  return query select 'a unit of measure can be created at all',
    exists (select 1 from erp.uom u
             where u.id = v_uom and u.tenant_id = r.tenant_id
               and u.code = 'EA' and u.is_base and u.status = 'active'),
    'nothing in the product could create one before this migration';

  v_item := (public.erp_create_item('WIDGET', 'Widget') ->> 'item_id')::uuid;

  return query select 'an item resolves the tenant base unit',
    (select i.stock_uom_id from erp.item i where i.id = v_item) = v_uom,
    'the same resolution erp.load_import does, so both paths agree';

  return query select 'and is created active rather than draft',
    (select i.lifecycle from erp.item i where i.id = v_item) = 'active',
    'the import stages as draft because nobody has looked; a typed record has '
    'been looked at';

  begin
    perform erp.create_item('OTHER', 'Other', gen_random_uuid());
    v_ok := false; v_msg := 'an unknown unit was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_UOM%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a unit from another tenant is refused',
    v_ok, v_msg;

  v_party := (public.erp_create_party_with_roles('ACME', 'Acme Ltd',
                array['customer', 'supplier'], 'GB') ->> 'party_id')::uuid;

  return query select 'a party can be created at all',
    exists (select 1 from erp.party p
             where p.id = v_party and p.tenant_id = r.tenant_id
               and p.status = 'active'),
    'one party across every role, so a receivable can net against a payable';

  return query select 'and holds the roles it was created with',
    (select count(*) from erp.party_role pr
      where pr.party_id = v_party and pr.status = 'active') = 2,
    'a party with no role is a name nobody can trade with';

  begin
    perform erp.create_party('', 'No code');
    v_ok := false; v_msg := 'a party with no code was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PARTY_CODE_REQUIRED%'; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a party with no code is refused',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------
  -- The pipeline, end to end, through the public surface only
  -- ---------------------------------------------------------------------

  v_batch := erp.stage_import('party',
    jsonb_build_array(jsonb_build_object('code', 'IMPORTED', 'name', 'Imported Co')),
    'zzdoors-batch');

  -- 20260830014600 renamed this key from 'error_count' to 'errors'. It still
  -- carries the integer erp.validate_import() returns, not a list.
  v_err  := (public.erp_validate_import(v_batch) ->> 'errors')::integer;
  v_prev := public.erp_preview_import(v_batch);
  v_loaded := erp.load_import(v_batch);

  return query select 'validate is reachable from the public surface',
    v_err = 0, format('%s errors', v_err);

  return query select 'preview is reachable, and returns the rows',
    jsonb_array_length(v_prev) = 1, format('%s rows previewed', jsonb_array_length(v_prev));

  return query select 'and load then accepts the batch',
    v_loaded = 1
      and exists (select 1 from erp.party p
                   where p.tenant_id = r.tenant_id and p.code = 'IMPORTED'),
    'load refuses anything not previewed, and only preview sets that status — '
    'so before this migration the pipeline could not complete';

  -- ---------------------------------------------------------------------
  -- The negative controls: the doors are gated
  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);

  begin
    perform erp.create_party('SNEAK', 'Sneak Ltd');
    v_ok := false; v_msg := 'a principal with no permissions created a party';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'a principal without master_data.write cannot create a party',
    v_ok, v_msg;

  begin
    perform erp.create_item('SNEAK', 'Sneak item');
    v_ok := false; v_msg := 'a principal with no permissions created an item';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor an item',
    v_ok, v_msg;

  begin
    perform erp.create_uom('SNEAK', 'Sneak unit');
    v_ok := false; v_msg := 'a principal with no permissions created a unit';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'nor a unit of measure',
    v_ok, v_msg;

  begin
    perform erp.validate_import(v_batch);
    v_ok := false; v_msg := 'validate ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'and validate_import now authorises, which it never did',
    v_ok, v_msg;

  begin
    perform erp.preview_import(v_batch);
    v_ok := false; v_msg := 'preview ran for a principal holding nothing';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 60);
  end;
  return query select 'as does preview_import',
    v_ok, v_msg;

  -- ---------------------------------------------------------------------

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(r.tenant_id);
  delete from erp.tenant where id = r.tenant_id;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, a2);

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = r.tenant_id),
    'every other suite purges; this one does too';
end;
$suite$;
-- ── 4b. Wrappers whose gate is one call away ────────────────────────────────
--
-- Ten of the registered functions are thin wrappers: the public function does
-- nothing but call one erp function, and that function authorises. Naming
-- erp.authorise as their gate is wrong in the literal sense rule 3b checks —
-- the word does not appear in the wrapper — even though the authorisation
-- plainly happens. The six-hop walk in rule 3d exists exactly so a gate can be
-- named one call away, so the fix is to name the call the wrapper makes.

update erp_meta.public_write_allowance set gate = v.gate
  from (values
    ('erp_complete_warehouse_task',   'erp.complete_warehouse_task'),
    ('erp_merge_batches',             'erp.merge_batches'),
    ('erp_raise_putaway_tasks',       'erp.raise_putaway_tasks'),
    ('erp_raise_replenishment_tasks', 'erp.raise_replenishment_tasks'),
    ('erp_seed_demo_operations',      'erp.seed_demo_operations'),
    ('erp_put_protected_value',       'erp.put_tenant_secret'),
    ('erp_read_protected_value',      'erp.get_tenant_secret'),
    ('erp_rotate_tenant_key',         'erp.rotate_tenant_key'),
    ('erp_platform_me',               'erp_meta.platform_actor'),
    ('erp_platform_claim_ownership',  'erp_meta.platform_log')
  ) as v(function_name, gate)
 where erp_meta.public_write_allowance.function_name = v.function_name;

-- ── 5. The Part 5 register names functions as though they were tables ───────
--
-- erp.part5_coverage_report() reads an artefact containing brackets as a
-- function and anything else as a relation. Seven artefacts naming functions
-- were registered without their argument lists, so they were looked up with
-- to_regclass() and, being functions, were not found. All seven exist; only
-- the way they are written down was wrong.

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.merge_batches',
                                 'erp.merge_batches(uuid,uuid,text)')
 where 'erp.merge_batches' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'public.erp_merge_batches',
                                 'public.erp_merge_batches(uuid,uuid,text)')
 where 'public.erp_merge_batches' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.raise_putaway_tasks',
                                 'erp.raise_putaway_tasks(uuid)')
 where 'erp.raise_putaway_tasks' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.raise_replenishment_tasks',
                                 'erp.raise_replenishment_tasks(uuid)')
 where 'erp.raise_replenishment_tasks' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'erp.complete_warehouse_task',
                                 'erp.complete_warehouse_task(uuid,numeric)')
 where 'erp.complete_warehouse_task' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'public.erp_stock_provision',
                                 'public.erp_stock_provision()')
 where 'public.erp_stock_provision' = any(artefacts);

update erp_ref.part5_capability
   set artefacts = array_replace(artefacts, 'public.erp_release_sequence',
                                 'public.erp_release_sequence(uuid,integer)')
 where 'public.erp_release_sequence' = any(artefacts);

-- ── 6. Twenty-two event types with no English string ────────────────────────
--
-- erp.assert_resource_coverage('en') exists because an event type whose name
-- has no string renders as its key. These are the ones the recent work added.

insert into erp_ref.resource (key, locale, value) values
  ('event.approval.chain_resolved',        'en', 'Approval chain resolved'),
  ('event.approval.cover_applied',         'en', 'Cover applied to an approval'),
  ('event.approval.cover_started',         'en', 'Cover started'),
  ('event.approval.cover_ended',           'en', 'Cover ended'),
  ('event.approval.escalated',             'en', 'Approval escalated'),
  ('event.approval.reapproval_triggered',  'en', 'Re-approval triggered'),
  ('event.item.classified',                'en', 'Item classified'),
  ('event.item.code_assigned',             'en', 'Item code assigned'),
  ('event.item.code_diverged',             'en', 'Item code diverged from its template'),
  ('event.posting.account_recorded',       'en', 'Posting account recorded'),
  ('event.posting.class_changed',          'en', 'Posting class changed'),
  ('event.posting.determination_failed',   'en', 'Account determination failed'),
  ('event.posting.rule_resolved',          'en', 'Posting rule resolved'),
  ('event.release.wave_opened',            'en', 'Release wave opened'),
  ('event.release.allocation_completed',   'en', 'Release wave allocated'),
  ('event.release.printed',                'en', 'Release wave printed'),
  ('event.replenishment.task_raised',      'en', 'Replenishment task raised'),
  ('event.replenishment.stock_returned',   'en', 'Stock returned to its home location'),
  ('event.sourcing.default_recorded',      'en', 'Default supplier recorded'),
  ('event.tenant.key_created',             'en', 'Tenant key created'),
  ('event.tenant.key_rotated',             'en', 'Tenant key rotated'),
  ('event.tenant.key_destroyed',           'en', 'Tenant key destroyed')
on conflict (key, locale) do update set value = excluded.value;

-- ── 6a. A SET clause silently disabled a COMMIT ─────────────────────────────
--
-- 0033 defines erp_test.assert_context_not_leaked() as a procedure, and says
-- in a comment directly above it why it is the one routine in the repository
-- without `set search_path`:
--
--   PostgreSQL refuses transaction control inside a routine that carries a SET
--   clause, so a procedure that must COMMIT cannot have one. Every identifier
--   below is fully schema-qualified instead, which is what the SET clause was
--   buying anyway.
--
-- 20260830072141 added the SET clause regardless — one line, silencing the one
-- Supabase-linter warning the codebase had:
--
--   alter procedure erp_test.assert_context_not_leaked() set search_path = '';
--
-- The procedure exists to prove that tenant context does not survive a commit
-- on a pooled connection, which it can only do by committing. With the SET
-- clause it raises "invalid transaction termination" at its first COMMIT and
-- proves nothing. The body was already fully qualified, so the clause bought
-- exactly nothing and cost the check.
--
-- This was invisible for the same reason as everything else here: the step
-- that runs it is the last one in the job, and the job had not reached it
-- since.

alter procedure erp_test.assert_context_not_leaked() reset search_path;

-- And a guard, so the next linter fix cannot quietly do it again. A routine
-- that performs transaction control and carries a SET clause is not a style
-- question: it raises at run time, and only on the path that commits.

create or replace function erp.assert_transaction_control_routines()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %I.%I carries %s', n.nspname, p.proname,
                                     array_to_string(p.proconfig, ', ')), E'\n')
    into v_count, v_detail
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai', 'erp_test')
     and p.prokind = 'p'
     and p.proconfig is not null
     and p.prosrc ~* '\mcommit\M';

  if v_count > 0 then
    raise exception
      'ERPWARE_TRANSACTION_CONTROL_BLOCKED: % procedure(s) commit but carry a '
      'SET clause, which PostgreSQL refuses at run time', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Schema-qualify the body and RESET the setting; a routine '
                   'that must COMMIT cannot carry one.';
  end if;

  return format('%s procedures perform transaction control, none blocked',
    (select count(*) from pg_catalog.pg_proc p2
      join pg_catalog.pg_namespace n2 on n2.oid = p2.pronamespace
     where n2.nspname like 'erp%' and p2.prokind = 'p'
       and p2.prosrc ~* '\mcommit\M'));
end;
$$;

-- ── 7. Run the generators ───────────────────────────────────────────────────
--
-- The single largest cause of the 183 findings, and the cheapest to fix: the
-- tables are all registered in erp_meta.table_policy, and nothing ever asked
-- the generators to emit their triggers. Thirty-four findings across audit
-- coverage and attribution close here.
--
-- These are idempotent by construction — that is what the generator-idempotence
-- step in CI checks — so running them at the tail of a migration that added no
-- tables is safe and is what every migration in this repository does.

select erp.apply_row_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

-- ── 8. Prove it, in the same transaction that did it ────────────────────────
--
-- Every assertion this file claims to fix, run here. If any still fails the
-- migration rolls back rather than landing a half-correction and leaving the
-- build to discover it.

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_part5_coverage();
select erp.assert_resource_coverage('en');
select erp.assert_transaction_control_routines();

