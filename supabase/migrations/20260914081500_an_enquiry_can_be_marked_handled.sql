-- =============================================================================
-- An enquiry can be marked handled
--
-- On 14 September the console's Today page showed "2 Enquiries not emailed to
-- you". Both were test enquiries from 4 September that Resend refused with a
-- 422 "Invalid `from` field", before the sender setting was right; every
-- enquiry since had been sent. Nothing could clear the card except erasing the
-- enquiry, which destroys it, so a failure that had been read and dealt with
-- would sit on Today for ever and teach the owner to ignore the card.
--
-- An enquiry now records that somebody handled it: when, who, and a note of
-- what was done. status and failure_reason stay as the record of what the mail
-- did; handling is a separate fact about people. Today counts only enquiries
-- nobody has handled.
--
-- The sender setting itself is checked before any message is posted, in
-- worker/src/core/resend.ts, so a malformed address fails with a reason that
-- names its shape rather than a provider's validation error.
-- =============================================================================

alter table erp_meta.enquiry add column if not exists handled_at   timestamptz;
alter table erp_meta.enquiry add column if not exists handled_by   text;
alter table erp_meta.enquiry add column if not exists handled_note text;

alter table erp_meta.enquiry drop constraint if exists enquiry_handled_says_how;
alter table erp_meta.enquiry add constraint enquiry_handled_says_how check (
  handled_at is null
  or (coalesce(btrim(handled_by), '') <> '' and coalesce(btrim(handled_note), '') <> ''));

alter table erp_meta.enquiry drop constraint if exists enquiry_handled_note_length;
alter table erp_meta.enquiry add constraint enquiry_handled_note_length check (
  handled_note is null or length(handled_note) <= 500);

comment on column erp_meta.enquiry.handled_at is
  'When a member of platform staff recorded that the enquiry was dealt with. '
  'Separate from status, which says what the mail did.';

-- ── Recording it ─────────────────────────────────────────────────────────────

create or replace function erp.mark_enquiry_handled(p_id uuid, p_by text, p_note text)
returns void
language plpgsql
set search_path to ''
as $$
begin
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'CLOVEERP_ENQUIRY_NOTE_REQUIRED: say what was done about this enquiry'
      using errcode = '22023';
  end if;

  update erp_meta.enquiry
     set handled_at = now(), handled_by = btrim(p_by), handled_note = left(btrim(p_note), 500)
   where id = p_id;

  if not found then
    raise exception 'CLOVEERP_ENQUIRY_NOT_FOUND: no enquiry %', p_id
      using errcode = '23503';
  end if;
end;
$$;

revoke all on function erp.mark_enquiry_handled(uuid, text, text) from public, anon, authenticated;

create or replace function public.erp_platform_mark_enquiry_handled(p_id uuid, p_note text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare v erp_meta.platform_staff;
begin
  v := erp_meta.require_platform('operator');
  perform erp.mark_enquiry_handled(p_id, v.email, p_note);
  perform erp_meta.platform_log(v, 'platform.enquiry_handled', null, null, p_note,
                                jsonb_build_object('enquiry_id', p_id));
  return jsonb_build_object('enquiry_id', p_id, 'handled', true);
end;
$$;

revoke all on function public.erp_platform_mark_enquiry_handled(uuid, text) from public, anon;
grant execute on function public.erp_platform_mark_enquiry_handled(uuid, text) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_mark_enquiry_handled', 'erp_meta.require_platform',
   'Records that an enquiry was dealt with and how. Operator or owner, and written to the platform log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_mark_enquiry_handled',
   'erp_meta.enquiry is platform_internal, denied to every signed-in role by row security. Gated by erp_meta.require_platform(''operator'') on its first line.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_ENQUIRY_NOTE_REQUIRED',
  'Marking an enquiry handled without saying what was done.',
  'Handled takes the enquiry off Today for good, so the next person needs to know whether somebody replied, booked a demo or decided it was not a lead.',
  'Write a short note, such as "Replied by email on Monday" or "Our own test".');

-- ── Reading it ───────────────────────────────────────────────────────────────

drop function if exists erp.enquiry_report(integer);

create function erp.enquiry_report(p_limit integer default 200)
returns table (
  id uuid, submitted_at timestamptz, full_name text, email text,
  organisation text, message text, source_page text,
  status text, notified_at timestamptz, failure_reason text,
  handled_at timestamptz, handled_by text, handled_note text)
language sql
stable
set search_path to ''
as $$
  select e.id, e.submitted_at, e.full_name, e.email, e.organisation, e.message,
         e.source_page, e.status, e.notified_at, e.failure_reason,
         e.handled_at, e.handled_by, e.handled_note
    from erp_meta.enquiry e
   order by e.submitted_at desc
   limit greatest(coalesce(p_limit, 200), 1)
$$;

revoke all on function erp.enquiry_report(integer) from public, anon, authenticated;

create or replace function public.erp_platform_enquiries(p_limit integer default 200)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'submitted_at', r.submitted_at,
             'full_name', r.full_name, 'email', r.email,
             'organisation', r.organisation, 'message', r.message,
             'source_page', r.source_page, 'status', r.status,
             'notified_at', r.notified_at, 'failure_reason', r.failure_reason,
             'handled_at', r.handled_at, 'handled_by', r.handled_by, 'handled_note', r.handled_note)
           order by r.submitted_at desc)
      from erp.enquiry_report(p_limit) r), '[]'::jsonb);
end;
$$;

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.enquiry_handled_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id  uuid;
  v_ok  boolean;
  v_msg text;
  op    uuid := gen_random_uuid();
  sp    uuid := gen_random_uuid();
  res   jsonb;
  c_msg constant text := 'We run three sites and need stock, purchasing and the ledger in one place.';
begin
  insert into auth.users (id, email) values (op, 'zzoperator@zzenqh.test'), (sp, 'zzsupport@zzenqh.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('zzoperator@zzenqh.test', op, 'Enquiry Operator', 'operator'),
         ('zzsupport@zzenqh.test', sp, 'Enquiry Support', 'support');

  v_id := erp.record_enquiry('Dana Okafor', 'dana@handled.example.test', c_msg, 'Okafor Foods', '/contact', 'zzhash-handled');
  perform erp.fail_enquiry_notice(v_id, 'permanent failure for owner@example.test: resend responded 422');

  perform set_config('request.jwt.claims', json_build_object('sub', sp)::text, true);
  begin
    perform public.erp_platform_mark_enquiry_handled(v_id, 'Replied by email');
    v_ok := false; v_msg := 'support marked an enquiry handled';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 70);
  end;
  return query select 'support can read enquiries but not mark one handled'::text, v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', op)::text, true);
  begin
    perform public.erp_platform_mark_enquiry_handled(v_id, '   ');
    v_ok := false; v_msg := 'an enquiry was marked handled with no note';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ENQUIRY_NOTE_REQUIRED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'handled says what was done'::text, v_ok, v_msg;

  res := public.erp_platform_mark_enquiry_handled(v_id, 'Our own test before the sender was set');
  return query select 'an operator marks a failed enquiry handled, and the failure is still on record'::text,
    (res ->> 'handled')::boolean
    and exists (select 1 from erp_meta.enquiry e
                 where e.id = v_id and e.handled_at is not null and e.handled_by = 'zzoperator@zzenqh.test'
                   and e.handled_note = 'Our own test before the sender was set'
                   and e.status = 'notification_failed' and e.failure_reason like 'permanent failure%'),
    'handled_at, handled_by and handled_note set; status and failure_reason untouched';

  res := public.erp_platform_enquiries(200);
  return query select 'the console reads who handled it and how'::text,
    exists (select 1 from jsonb_array_elements(res) x
             where x ->> 'id' = v_id::text and x ->> 'handled_note' = 'Our own test before the sender was set'
               and x ->> 'handled_by' = 'zzoperator@zzenqh.test' and x ->> 'handled_at' is not null),
    'erp_platform_enquiries carries handled_at, handled_by and handled_note';

  return query select 'the platform log records it'::text,
    exists (select 1 from erp_meta.platform_audit a
             where a.action = 'platform.enquiry_handled' and a.actor_email = 'zzoperator@zzenqh.test'),
    'platform.enquiry_handled';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.enquiry where ip_hash = 'zzhash-handled' or email like '%@handled.example.test';
  delete from erp_meta.platform_staff where email like '%@zzenqh.test';
  delete from auth.users where id in (op, sp);
  return query select 'the suite leaves nothing behind'::text,
    not exists (select 1 from erp_meta.enquiry e where e.ip_hash = 'zzhash-handled')
    and not exists (select 1 from erp_meta.platform_staff s where s.email like '%@zzenqh.test'),
    'enquiry and staff gone';
end;
$$;

revoke all on function erp_test.enquiry_handled_suite() from public, anon;

create or replace function erp_test.assert_enquiry_handled_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _enq_handled on commit drop as
    select * from erp_test.enquiry_handled_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail from _enq_handled;
  if v_all <> 6 then
    raise exception 'CLOVEERP_SUITE_SHRANK: enquiry_handled_suite ran % cases, expected 6', v_all;
  end if;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ENQUIRY_HANDLED_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001';
  end if;
  return format('enquiries handled: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_enquiry_handled_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_enquiries_answerable();
-- erp_test.enquiry_suite is left to the build: its clean-up deletes every
-- erased enquiry, which on the live database would be real ones.
select erp_test.assert_enquiry_handled_suite();
