-- Every form asks for what its door asks for.
--
-- The desk declares a door and a permission in one breath — fn: "erp_x" and
-- permission: "a.b" on the same action, dialog, button or inquiry — and nothing
-- compared the two. The database is the enforcement and the permission prop is
-- convenience, so when they disagree the convenience lies: a form shown to
-- people the database refuses, whose refusal arrives only on submit, or hidden
-- from people the database would serve, who never learn the door exists. On 13
-- September three such forms were found by hand: merge under master_data.write
-- against a door on approve, qualify supplier under procurement.order against
-- master_data.approve, rollback under administration.configure against
-- promote. A static walk over every declaration then found fourteen more, and
-- in every one of the seventeen the database was right.
--
-- No suite can see this class. erp.assert_authorise_codes_exist() proves the
-- database's gates name real codes; erp.assert_app_permissions_exist() proves
-- the desk's do; neither asks whether the two name the same code for the same
-- door. A suite that asserts a role cannot press a button agrees with a form
-- that nobody holding the right permission can reach.
--
-- So, in the family of erp.assert_app_doors_exist() and
-- erp.assert_app_permissions_exist(): the build harvests every (door,
-- permission) pair the desk declares (supabase/ci/app_gates.sh) and hands the
-- list to erp.assert_app_gates_match(), which follows each door into the erp.*
-- functions it reaches — the reach rule erp.public_api_report() already uses,
-- names matched on comment-stripped, string-blanked text so prose cannot make
-- an edge — and reads every literal erp.authorise('…') on the way. Then:
--
--   * the code the desk names is among them            → the pair holds;
--   * none is, but the chain authorises from data — a
--     transition's required permission, a document type's
--     create permission, a report version's — the text
--     cannot judge it                                   → counted, not failed;
--   * none is, and the chain authorises nothing, and
--     nothing in it writes                              → a read scoped by row
--                                                         security; it holds;
--   * none is, the chain authorises nothing, and it
--     writes                                            → refused: a permission
--                                                         prop is the only guard,
--                                                         which CLAUDE.md forbids;
--   * literal codes exist and none is the desk's        → refused, naming both.
--
-- The walk found four writers of the last-but-one kind, and each is put right
-- here rather than excused:
--
--   * public.erp_assign_named_approver() lost its gate. 20260901120000
--     authorised administration.configure on the door — on the door and not
--     in erp.*, because the promoter calls erp.assign_named_approver() for
--     every approver item and authorises once, at the change set, so a
--     principal holding only administration.promote must still promote.
--     20260906145000 dropped and recreated both functions to take a currency
--     and did not carry the gate across, while the register row went on
--     saying "under administration.configure". The three desk buttons were
--     the only guard. The gate is back, on the door.
--   * erp.submit_change_request() and erp.apply_change_request() gate on
--     state — draft, approved — and on nothing else, while the desk gates both
--     buttons on master_data.write and the register says write for one and
--     approve for the other. Both now authorise master_data.write, which is
--     what opening a change request already asks for, and the register says
--     so of both.
--   * erp_decide_approval gates on the task being assigned to the caller and
--     asks for no permission code, so the button must not either — the rule
--     20260906148000 applied to the governance screen and the procurement
--     screen had not followed. Fixed in src with this file.
--
-- Two of the fourteen were not a wrong code but a wrong door: the logistics
-- module's "Confirm a delivery" and "Record a failed delivery" called
-- erp_confirm_delivery and erp_fail_delivery, which belong to the output
-- gateway — a webhook's delivery, not a customer's — with a delivery document
-- picked in front of them. Both actions and the flow stage that carried them
-- are gone from src; a delivery document is confirmed or failed on its own
-- page through its lifecycle, and the two doors are registered below for the
-- caller they were written for.
--
-- And one door found dead on the way: public.erp_create_classified_item()
-- calls erp.current_app_user_id(), which no migration defines, so it has failed
-- on first use since 20260830132420. It now calls erp.current_principal_id().
--
-- The three desk declarations that read their permission from data
-- (permission={type.create_permission}) cannot be harvested; the script lists
-- them and the database checks nothing it was not handed.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The judge: what a door authorises, read from its text and its reach
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.app_gate_report(p_pairs text[])
returns table(door text, permission_code text, verdict text, detail text)
language sql
stable
set search_path = ''
as $$
  with recursive
  pair as (
    select split_part(x, '|', 1) as door, split_part(x, '|', 2) as permission_code
      from unnest(p_pairs) as x
  ),
  -- Every routine a door can reach. Names are matched on comment-stripped,
  -- string-blanked text, so a routine mentioned in a message is not an edge;
  -- codes are read from comment-stripped text, because the code is a string.
  node as (
    select p.oid, n.nspname as ns, p.proname,
           erp.prosrc_code(p.prosrc) as code,
           regexp_replace(erp.prosrc_code(p.prosrc), '''(?:[^'']|'''')*''', '''''', 'g') as names
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('erp', 'erp_ref', 'erp_meta', 'erp_ai')
        or (n.nspname = 'public' and p.proname like 'erp\_%')
  ),
  mention as (
    select f.oid as caller, m[1] as ns, m[2] as name
      from node f, regexp_matches(f.names, '(erp[a-z_]*)\.([a-z][a-z0-9_]*)\(', 'g') m
  ),
  edge as (
    select distinct m.caller, c.oid as callee
      from mention m
      join node c on c.ns = m.ns and c.proname = m.name
     where m.caller <> c.oid and c.ns <> 'public'
  ),
  door_node as (
    select n.* from node n
     where n.ns = 'public' and n.proname in (select p.door from pair p)
  ),
  reach as (
    select d.oid as door_oid, d.oid as reached, 0 as depth from door_node d
    union
    select r.door_oid, e.callee, r.depth + 1
      from reach r join edge e on e.caller = r.reached
     where r.depth < 6
  ),
  literal as (
    select r.door_oid, m[1] as permission_code
      from reach r join node f on f.oid = r.reached,
           regexp_matches(f.code, 'erp\.authorise\(\s*''([a-z_]+\.[a-z_]+)''', 'g') m
  ),
  dynamic as (
    select distinct r.door_oid
      from reach r join node f on f.oid = r.reached
     where f.code ~ 'erp\.authorise\(\s*[^''\s)]'
  ),
  platform as (
    select distinct r.door_oid
      from reach r join node f on f.oid = r.reached
     where f.code ~ 'erp_meta\.require_platform\('
  ),
  -- A door that writes within two calls of itself. Text, not proof: it is
  -- here to tell a read scoped by row security from a writer whose only
  -- guard would otherwise be a prop on a screen.
  writer as (
    select distinct r.door_oid
      from reach r join node f on f.oid = r.reached
     where r.depth <= 2
       and f.code ~* '\m(insert\s+into|update\s+erp(_meta|_ai|_ref)?\.|delete\s+from)'
  )
  select p.door, p.permission_code,
         case
           when d.oid is null then 'missing_door'
           when exists (select 1 from platform pl where pl.door_oid = d.oid) then 'platform'
           when exists (select 1 from literal l
                         where l.door_oid = d.oid and l.permission_code = p.permission_code) then 'match'
           when exists (select 1 from dynamic dy where dy.door_oid = d.oid) then 'data'
           when exists (select 1 from literal l where l.door_oid = d.oid) then 'mismatch'
           when exists (select 1 from writer w where w.door_oid = d.oid) then 'ungated_write'
           else 'ungated_read'
         end as verdict,
         case
           when d.oid is null then 'no such door in schema public'
           when exists (select 1 from platform pl where pl.door_oid = d.oid)
             then 'a console door, gated by erp_meta.require_platform(); a tenant permission does not apply'
           else coalesce(
             'the door authorises ' || (select string_agg(distinct l.permission_code, ', ' order by l.permission_code)
                                          from literal l where l.door_oid = d.oid),
             'the door authorises nothing the text can name')
         end as detail
    from pair p
    left join door_node d on d.proname = p.door
   order by p.door, p.permission_code
$$;
revoke all on function erp.app_gate_report(text[]) from public, anon, authenticated;

comment on function erp.app_gate_report(text[]) is
  'For each ''door|permission'' pair the desk declares: match, data (the door '
  'authorises from a column), ungated_read, ungated_write, mismatch, platform '
  'or missing_door, with the codes the door''s reach authorises. Text over '
  'prosrc, like erp.authorise_code_report(): it sees literal calls and names '
  'the computed ones as data.';

create or replace function erp.assert_app_gates_match(p_pairs text[])
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_n        integer := coalesce(cardinality(p_pairs), 0);
  v_doors    integer;
  v_match    integer;
  v_data     integer;
  v_reads    integer;
  v_findings text;
  v_bad      integer;
begin
  if v_n = 0 then
    raise exception 'CLOVEERP_APP_NAMES_NO_GATES: the list of door and permission pairs is empty'
      using errcode = '22023',
            hint = 'supabase/ci/app_gates.sh extracts every (door, permission) pair from src; an empty list means the extraction found nothing, which is not a pass.';
  end if;

  select count(*) filter (where r.verdict = 'match'),
         count(*) filter (where r.verdict = 'data'),
         count(*) filter (where r.verdict = 'ungated_read'),
         count(*) filter (where r.verdict in ('mismatch', 'ungated_write', 'platform', 'missing_door')),
         string_agg(format('  %s under %s — %s: %s', r.door, r.permission_code, r.verdict, r.detail), E'\n' order by r.door, r.permission_code)
           filter (where r.verdict in ('mismatch', 'ungated_write', 'platform', 'missing_door')),
         count(distinct r.door)
    into v_match, v_data, v_reads, v_bad, v_findings, v_doors
    from erp.app_gate_report(p_pairs) r;

  if v_bad > 0 then
    raise exception E'CLOVEERP_APP_GATE_MISMATCH: % form(s) name a permission their door does not ask for:\n%',
      v_bad, v_findings
      using errcode = 'P0001',
            hint = 'The database is the enforcement. Set the form''s permission to the code the door authorises; for a writer that authorises nothing, give the door a gate in a migration rather than leave the prop as the only guard.';
  end if;

  return format('form gates: %s pair(s) on %s door(s); %s authorise the code named, %s authorise from data, %s are reads that authorise nothing',
                v_n, v_doors, v_match, v_data, v_reads);
end;
$$;
revoke all on function erp.assert_app_gates_match(text[]) from public, anon, authenticated;

comment on function erp.assert_app_gates_match(text[]) is
  'Refuses any (door, permission) pair the desk declares where the door, '
  'directly or through the erp.* functions it reaches, authorises literal '
  'codes and none is the one named, or authorises nothing yet writes. The '
  'build extracts the pairs from src and calls this; the desk-side half of '
  'what erp.assert_authorise_codes_exist() proves of the database''s gates.';

insert into erp_meta.check_run_exemption (schema_name, function_name, driven_by, rationale) values
  ('erp', 'assert_app_gates_match', null,
   'Takes the door and permission pairs supabase/ci/app_gates.sh extracts from the application source; only the build can know what the application declares, and it calls this with that list.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;
insert into erp_meta.diagnostic_exemption (schema_name, function_name, rationale) values
  ('erp', 'assert_app_gates_match',
   'Takes the list of door and permission pairs the application source declares. A console button has no such list; the build extracts it and calls this.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The gate a named approver lost, back on the door
-- ═════════════════════════════════════════════════════════════════════════════

-- Same eleven parameters and return type as 20260906145000, so this replaces
-- the door rather than overloading it and keeps its grants. erp.assign_named_approver()
-- itself is untouched: the promoter calls it for every approver item in a
-- change set and authorises once, at the change set (20260901120000).
create or replace function public.erp_assign_named_approver(
  p_subject_kind text, p_subject_id uuid, p_object_type text, p_approver_user_id uuid,
  p_mode text default 'prepends',
  p_lower_bound_minor bigint default null, p_upper_bound_minor bigint default null,
  p_reason text default null, p_valid_from date default null, p_valid_to date default null,
  p_currency text default 'GBP')
returns jsonb
language plpgsql
volatile
security invoker
set search_path = ''
as $$
begin
  -- 20260901120000 gated this door; 20260906145000 recreated it for the
  -- currency and left the gate out. Naming who approves is configuring the
  -- organisation, and the register has said so throughout.
  perform erp.authorise('administration.configure');
  return erp.assign_named_approver(p_subject_kind, p_subject_id, p_object_type, p_approver_user_id,
                                   p_mode, p_lower_bound_minor, p_upper_bound_minor, p_reason,
                                   p_valid_from, p_valid_to, p_currency);
end;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A change request is submitted and applied under master_data.write
-- ═════════════════════════════════════════════════════════════════════════════

do $gates$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.submit_change_request(uuid)'::regprocedure);
  v_new := replace(v_def,
$old$  if cr.status <> 'draft' then$old$,
$new$  -- Opening the request asked for master_data.write; submitting it asks again,
  -- so that a screen's permission prop is never the only guard on the act.
  perform erp.authorise('master_data.write', null, null, null, 'change_request', p_request_id);

  if cr.status <> 'draft' then$new$);
  if v_new = v_def then
    raise exception 'CLOVEERP_GATE_UNRECOGNISED: erp.submit_change_request() no longer tests for a draft where this migration expected';
  end if;
  execute v_new;

  v_def := pg_get_functiondef('erp.apply_change_request(uuid)'::regprocedure);
  v_new := replace(v_def,
$old$  if erp.change_request_effective_status(p_request_id) <> 'approved' then$old$,
$new$  -- Applying is the writer's act the approval released; master_data.write,
  -- as the desk has always said. Approval itself is a task decision.
  perform erp.authorise('master_data.write', null, null, null, 'change_request', p_request_id);

  if erp.change_request_effective_status(p_request_id) <> 'approved' then$new$);
  if v_new = v_def then
    raise exception 'CLOVEERP_GATE_UNRECOGNISED: erp.apply_change_request() no longer tests the effective status where this migration expected';
  end if;
  execute v_new;
end
$gates$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_submit_change_request', 'erp.submit_change_request',
   'Submits a drafted master-data change for approval under master_data.write; it proposes, it does not apply.'),
  ('erp_apply_change_request', 'erp.apply_change_request',
   'Applies an approved master-data change under master_data.write, and refuses a request that has not cleared approval.'),
  ('erp_assign_named_approver', 'erp.assign_named_approver',
   'Names an approver for a principal, department or role under administration.configure, with bounds in a stated currency so a value in another is converted rather than compared as a bare number.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. A door that called a function nobody wrote
-- ═════════════════════════════════════════════════════════════════════════════

do $dead$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.erp_create_classified_item'::regproc);
  v_new := replace(v_def, 'erp.current_app_user_id()', 'erp.current_principal_id()');
  if v_new = v_def then
    raise exception 'CLOVEERP_DOOR_UNRECOGNISED: public.erp_create_classified_item() no longer calls erp.current_app_user_id(), which this migration set out to replace';
  end if;
  execute v_new;
end
$dead$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4b. Two gateway doors no screen names any more
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_confirm_delivery', 'integration', null,
   'The output gateway confirms a delivery it made, under administration.integrate. It was offered on the logistics screen against a customer delivery document, which it never was; the screen now leaves it to the gateway.'),
  ('erp_fail_delivery', 'integration', null,
   'The output gateway fails a delivery it made, with the reason, under administration.integrate. Offered on the logistics screen by mistake until this migration; it belongs to the gateway.')
on conflict (function_name) do update set
  caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

-- The logistics help topic stops offering them too.
update erp_ref.help_topic h
   set actions = array_remove(array_remove(h.actions, 'erp_confirm_delivery'), 'erp_fail_delivery')
 where h.screen_path = '/logistics';

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.app_gate_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_ok  boolean;
  v_msg text;
begin
  -- 1
  v_msg := erp.assert_app_gates_match(array['erp_qualify_supplier|master_data.approve']);
  case_name := 'a form naming the code its door authorises is accepted';
  passed := v_msg like 'form gates: 1 pair(s) on 1 door(s); 1 authorise the code named%';
  detail := v_msg;
  return next;

  -- 2
  case_name := 'a form naming a code its door does not authorise is refused, and both codes are named';
  begin
    perform erp.assert_app_gates_match(array['erp_qualify_supplier|procurement.order']);
    v_ok := false; v_msg := 'a mismatched pair was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_GATE_MISMATCH%'
        and sqlerrm like '%erp_qualify_supplier under procurement.order%'
        and sqlerrm like '%master_data.approve%';
    v_msg := left(sqlerrm, 160);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 3
  case_name := 'a door that authorises from data is counted, not failed';
  v_msg := erp.assert_app_gates_match(array['erp_transition_document|procurement.approve']);
  passed := v_msg like '%1 authorise from data%';
  detail := v_msg;
  return next;

  -- 4
  case_name := 'a read that authorises nothing is scoped by row security and holds';
  v_msg := erp.assert_app_gates_match(array['erp_reason_codes|administration.read']);
  passed := v_msg like '%1 are reads that authorise nothing%';
  detail := v_msg;
  return next;

  -- 5. A writer that authorises nothing, with a permission on the desk: the
  -- prop would be the only guard. Built, judged and undone in one block.
  case_name := 'a writer that authorises nothing is refused when a form gates it';
  v_msg := null;
  begin
    execute $fn$
      create function public.erp_zz_ungated_writer()
      returns void language plpgsql set search_path = '' as $body$
      begin
        insert into erp.reason_code (tenant_id) values (null);
      end $body$
    $fn$;
    begin
      perform erp.assert_app_gates_match(array['erp_zz_ungated_writer|administration.configure']);
      v_msg := 'an ungated writer was accepted';
    exception when others then v_msg := sqlerrm;
    end;
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then v_msg := coalesce(v_msg, sqlerrm); end if;
  end;
  passed := v_msg like 'CLOVEERP_APP_GATE_MISMATCH%' and v_msg like '%erp_zz_ungated_writer under administration.configure — ungated_write%';
  detail := left(v_msg, 160);
  return next;

  -- 6
  case_name := 'a door that does not exist is refused';
  begin
    perform erp.assert_app_gates_match(array['erp_zz_no_such_door|administration.read']);
    v_ok := false; v_msg := 'a missing door was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_GATE_MISMATCH%' and sqlerrm like '%missing_door%';
    v_msg := left(sqlerrm, 160);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 7
  case_name := 'an extraction that found nothing is not a pass';
  begin
    perform erp.assert_app_gates_match(array[]::text[]);
    v_ok := false; v_msg := 'an empty list was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_APP_NAMES_NO_GATES%'; v_msg := left(sqlerrm, 90);
  end;
  passed := v_ok; detail := v_msg;
  return next;

  -- 8. The four writers this migration gated hold under the desk's codes, and
  -- the falsification above left nothing behind.
  v_msg := erp.assert_app_gates_match(array[
    'erp_assign_named_approver|administration.configure',
    'erp_submit_change_request|master_data.write',
    'erp_apply_change_request|master_data.write']);
  case_name := 'the writers this migration gated authorise what the desk names, and the falsification was undone';
  passed := v_msg like 'form gates: 3 pair(s) on 3 door(s); 3 authorise the code named%'
        and not exists (select 1 from pg_catalog.pg_proc where proname = 'erp_zz_ungated_writer');
  detail := v_msg;
  return next;
end;
$$;
revoke all on function erp_test.app_gate_suite() from public, anon, authenticated;

create or replace function erp_test.assert_app_gate_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _app_gate on commit drop as
    select * from erp_test.app_gate_suite();
  select count(*), count(*) filter (where coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_total, v_passed, v_detail
    from _app_gate;
  drop table _app_gate;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_APP_GATE_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_APP_GATE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail;
  end if;
  return format('form gates: %s/%s cases passed', v_passed, v_total);
end;
$$;
revoke all on function erp_test.assert_app_gate_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5b. The words the logistics flow now says
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Flow note of the logistics module, reworded when the confirm-delivery stage and its two actions left the screen.'
  from (values
    ('Plan the shipment, choose the carrier, book it, then record the proof of delivery. A delivery is confirmed or failed on its own document page.')
  ) as v(text)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_app_gate_suite();

select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
