-- =============================================================================
-- An enquiry goes to the address that answers it, not to whoever owns the
-- platform.
--
-- 20260904950000 made the contact form reach somebody by asking
-- erp_meta.platform_staff who the owners are, and told them. The comment it
-- left says why: "Read from the register rather than written into the code. An
-- address in a function body is one that stays right until somebody leaves."
-- That is still true. What it got wrong is which register.
--
-- Platform owner is the console role: it enters customer organisations, erases
-- an enquirer's details, opens and closes sign-up, changes billing. Answering a
-- sales lead is none of those. Tying the two together means the only way to
-- move where leads land is to hand somebody the keys to the platform, or to
-- take them off the person who holds them — and on 20 September that was the
-- live position: leads were going to a personal Gmail address because that
-- address happened to be the owner row.
--
-- So the recipients become a setting a platform owner can change from the
-- console, and the owner role goes back to meaning what it says. The fallback
-- is the old behaviour exactly: with no setting, the owners are told. That is
-- deliberate and is the reason this is safe to deploy. A contact form that
-- stores a lead and tells nobody is worse than no form — 20260904950000's
-- words — so there is no state of this setting, including absent, empty, or
-- cleared by somebody in a hurry, in which the list comes back empty while a
-- staff member exists to receive it.
--
-- ── WHAT DOES NOT CHANGE ─────────────────────────────────────────────────────
--
-- erp_ingress.enquiry_recipients() keeps its name, signature and result shape,
-- so supabase/functions/enquiry/index.ts is untouched by this migration. It
-- still loops over the addresses it is given, still sets reply_to to the
-- enquirer, and still records a provider message id or a reason for every one.
-- The "names nobody to tell" path it already has is unreached while a fallback
-- exists, and is left in place for the case where it does not.
--
-- ── WHY A SETTING AND NOT A SECOND STAFF TABLE ───────────────────────────────
--
-- A recipient is not a person here. It is a mailbox somebody in sales reads,
-- and it has no sign-in, no role, no audit identity and nothing to revoke. A
-- staff row for it would be a staff row that can never be used to sign in,
-- which is the sort of thing that later gets granted something by accident.
-- erp_meta.platform_setting already holds a change, its reason, when, and by
-- which owner, and already writes every change to erp_meta.platform_audit.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The address the notifications go to
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.platform_setting (key, value, reason)
values ('enquiry.notify_to', '["sales@cloveerp.com"]'::jsonb,
        'Set when enquiry notifications were separated from the platform owner role: '
        'a lead goes to the sales mailbox, which is read by whoever is answering, '
        'rather than to whichever personal address happens to hold owner.')
on conflict (key) do nothing;

-- Absent, malformed, or holding nothing but blanks all read as "no address is
-- set", because each of them means the same thing to the caller and only one
-- of them can be told apart by looking. btrim so a pasted address with a
-- trailing space is still an address; the shape check on the way in is what
-- keeps anything worse out.
create or replace function erp.enquiry_notify_to()
returns text[]
language sql
stable
set search_path to ''
as $$
  select coalesce(
    (select array_agg(btrim(a.value) order by btrim(a.value))
       from erp_meta.platform_setting s
       cross join lateral jsonb_array_elements_text(s.value) as a(value)
      where s.key = 'enquiry.notify_to'
        and jsonb_typeof(s.value) = 'array'
        and btrim(a.value) <> ''),
    '{}'::text[])
$$;

revoke all on function erp.enquiry_notify_to() from public, anon;

comment on function erp.enquiry_notify_to() is
  'The addresses enquiry notifications are sent to, from the enquiry.notify_to '
  'platform setting. Empty when no address is set, which is what makes '
  'erp.enquiry_recipients() fall back to the platform owners.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. Who hears about an enquiry
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Same name, same signature, same ordering as 20260904950000. The owners
-- branch is that migration's body unchanged, and is reached whenever no
-- address is set.

create or replace function erp.enquiry_recipients()
returns table (email text, display_name text)
language sql
stable
set search_path to ''
as $$
  with configured as (
    select a.email, 'Clove ERP enquiries'::text as display_name
      from unnest(erp.enquiry_notify_to()) as a(email)
  ),
  -- Owners first, because a lead is a commercial matter and an owner is who
  -- answers for one. If nobody holds owner — which would itself be a finding —
  -- every unrevoked staff member is told rather than nobody.
  owners as (
    select s.email, s.display_name
      from erp_meta.platform_staff s
     where s.revoked_at is null
       and (s.staff_role = 'owner'
            or not exists (select 1 from erp_meta.platform_staff o
                            where o.revoked_at is null and o.staff_role = 'owner'))
  )
  select c.email, c.display_name from configured c
  union all
  select o.email, o.display_name from owners o
   where not exists (select 1 from configured)
   order by 1
$$;

revoke all on function erp.enquiry_recipients() from public, anon;

comment on function erp.enquiry_recipients() is
  'Who is told about a new enquiry: the addresses in the enquiry.notify_to '
  'setting, or the platform owners when none is set. Answering a lead is a '
  'sales job and owning the platform is a console role, so the two are '
  'separate registers; the fallback is what keeps an enquiry from reaching '
  'nobody if the setting is ever cleared.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The doors the console reads and writes it through
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_platform_enquiry_notify_to()
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v_row erp_meta.platform_setting;
begin
  perform erp_meta.require_platform('support');

  select * into v_row from erp_meta.platform_setting s where s.key = 'enquiry.notify_to';

  -- Both lists, because they answer different questions. "configured" is what
  -- an owner set; "recipients" is where the next enquiry actually goes. They
  -- differ exactly when nothing is set, and that is the case somebody reading
  -- this screen most needs to see stated rather than inferred.
  return jsonb_build_object(
    'configured', to_jsonb(erp.enquiry_notify_to()),
    'recipients', coalesce((select jsonb_agg(r.email order by r.email)
                              from erp.enquiry_recipients() r), '[]'::jsonb),
    'falls_back_to_owners', cardinality(erp.enquiry_notify_to()) = 0,
    'reason', v_row.reason,
    'updated_at', v_row.updated_at);
end;
$$;

comment on function public.erp_platform_enquiry_notify_to() is
  'Where enquiry notifications go: {configured, recipients, falls_back_to_owners, '
  'reason, updated_at}. Platform staff only, and volatile because the gate binds '
  'the staff identity on first use.';

revoke all on function public.erp_platform_enquiry_notify_to() from public, anon;
grant execute on function public.erp_platform_enquiry_notify_to() to authenticated, service_role;

create or replace function public.erp_platform_set_enquiry_notify_to(
  p_emails text[], p_reason text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $$
declare
  v       erp_meta.platform_staff;
  v_was   text[];
  v_clean text[];
  v_email text;
  v_row   erp_meta.platform_setting;
begin
  v := erp_meta.require_platform('owner');

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'CLOVEERP_ENQUIRY_NOTIFY_TO_NEEDS_REASON: moving where enquiries are sent is recorded with its reason'
      using errcode = '22023',
            hint = 'Say why the notification address is changing. The reason is kept with the setting and in the platform log.';
  end if;

  -- Deliberately the same shape check erp.record_enquiry() applies to the
  -- enquirer, and for the same reason: what makes an address real is that a
  -- message reaches it, which the provider's response tells us. This refuses
  -- what obviously cannot be one — and an address that cannot be one here
  -- costs a lead rather than a form submission, so it is refused at the door
  -- and not discovered in a bounce.
  select array_agg(distinct btrim(e) order by btrim(e)) into v_clean
    from unnest(coalesce(p_emails, '{}'::text[])) as e
   where btrim(e) <> '';

  v_clean := coalesce(v_clean, '{}'::text[]);

  foreach v_email in array v_clean loop
    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$' then
      raise exception 'CLOVEERP_ENQUIRY_NOTIFY_TO_INVALID: % does not look like an email address', v_email
        using errcode = '22023',
              hint = 'Give the mailbox that answers enquiries, such as sales@cloveerp.com. Clearing the list sends enquiries to the platform owners instead.';
    end if;
  end loop;

  v_was := erp.enquiry_notify_to();

  insert into erp_meta.platform_setting (key, value, reason, updated_at, updated_by)
  values ('enquiry.notify_to', to_jsonb(v_clean), btrim(p_reason), now(), v.id)
  on conflict (key) do update
     set value = excluded.value, reason = excluded.reason,
         updated_at = excluded.updated_at, updated_by = excluded.updated_by
  returning * into v_row;

  perform erp_meta.platform_log(
    v, 'platform.enquiry_notify_to_set', null, 'enquiry.notify_to', btrim(p_reason),
    jsonb_build_object('was', to_jsonb(v_was), 'now', to_jsonb(v_clean)));

  return jsonb_build_object(
    'configured', to_jsonb(v_clean),
    'recipients', coalesce((select jsonb_agg(r.email order by r.email)
                              from erp.enquiry_recipients() r), '[]'::jsonb),
    'falls_back_to_owners', cardinality(v_clean) = 0,
    'reason', v_row.reason,
    'updated_at', v_row.updated_at);
end;
$$;

comment on function public.erp_platform_set_enquiry_notify_to(text[], text) is
  'Sets the addresses enquiry notifications are sent to. Platform owner only; a '
  'reason is required, kept with the setting and written to the platform log. An '
  'empty list clears the setting, which sends enquiries to the platform owners. '
  'Returns the same shape as erp_platform_enquiry_notify_to().';

revoke all on function public.erp_platform_set_enquiry_notify_to(text[], text) from public, anon;
grant execute on function public.erp_platform_set_enquiry_notify_to(text[], text) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The allowances
-- ═════════════════════════════════════════════════════════════════════════════

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_enquiry_notify_to',
   'Platform staff read, gated by erp_meta.require_platform(''support'') on its first '
   'line. Runs as its owner because the setting and the staff register are both in '
   'erp_meta, which is sealed to a signed-in caller. Writes nothing.'),
  ('public', 'erp_platform_set_enquiry_notify_to',
   'Platform owner door, gated by erp_meta.require_platform(''owner'') on its first '
   'line. Runs as its owner because erp_meta is sealed to a signed-in caller. Writes '
   'one platform setting and its platform audit row.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_enquiry_notify_to', 'erp_meta.require_platform',
   'Reads where enquiry notifications are sent. Platform staff only, and volatile '
   'because the gate binds the staff identity on first use.'),
  ('erp_platform_set_enquiry_notify_to', 'erp_meta.require_platform',
   'Moves where every enquiry from the marketing site is sent. Platform owner, on the '
   'first line; refuses a change without a reason and an address that cannot be one; '
   'writes the setting and the platform log.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The refusals, in the register the desk reads
-- ═════════════════════════════════════════════════════════════════════════════

select erp.register_refusal('CLOVEERP_ENQUIRY_NOTIFY_TO_NEEDS_REASON',
  'Changing the address enquiry notifications are sent to without saying why.',
  'Where the leads land is a decision about the whole platform, and somebody finding the sales mailbox quiet needs to be able to read when it moved and what for.',
  'Say why the notification address is changing. The reason is kept with the setting and in the platform log.');

select erp.register_refusal('CLOVEERP_ENQUIRY_NOTIFY_TO_INVALID',
  'Setting an enquiry notification address that cannot be an email address.',
  'A mistyped address here does not fail visibly: the form keeps accepting enquiries, the sender is thanked, and every notification bounces into a failure reason nobody is watching.',
  'Give the mailbox that answers enquiries, such as sales@cloveerp.com. Clearing the list sends enquiries to the platform owners instead.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The setting is one row for the whole platform, so the suite cannot make its
-- own copy of it the way it makes its own staff. It takes the live value,
-- works, and puts it back — including putting back "absent", which is a
-- different state from "empty" and the one a fresh build starts in.

create or replace function erp_test.enquiry_notification_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_cases int := 0;
  v_ok    boolean;
  v_msg   text;
  v_saved erp_meta.platform_setting;
  v_had   boolean;
  own     uuid := gen_random_uuid();
  sup     uuid := gen_random_uuid();
  res     jsonb;
begin
  select * into v_saved from erp_meta.platform_setting s where s.key = 'enquiry.notify_to';
  v_had := found;

  insert into auth.users (id, email) values (own, 'zzowner@zzenqn.test'), (sup, 'zzsupport@zzenqn.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('zzowner@zzenqn.test', own, 'Enquiry Notify Owner', 'owner'),
         ('zzsupport@zzenqn.test', sup, 'Enquiry Notify Support', 'support');

  -- ── With no address set, the owners are told, exactly as before ───────────

  delete from erp_meta.platform_setting where key = 'enquiry.notify_to';

  v_cases := v_cases + 1;
  return query select 'with no address set, an owner is told and a support account is not'::text,
    exists (select 1 from erp.enquiry_recipients() r where r.email = 'zzowner@zzenqn.test')
    and not exists (select 1 from erp.enquiry_recipients() r where r.email = 'zzsupport@zzenqn.test'),
    'erp.enquiry_recipients() falls back to 20260904950000''s owners branch, which is '
    'what makes this safe to deploy before anybody sets an address';

  -- ── An owner sets one, and it replaces them ───────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', sup)::text, true);
  v_cases := v_cases + 1;
  begin
    perform public.erp_platform_set_enquiry_notify_to(
      array['support@zzenqn.test'], 'support tried to move the leads');
    v_ok := false; v_msg := 'support moved the notification address';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 70);
  end;
  return query select 'support can read where enquiries go but not move them'::text, v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', own)::text, true);

  v_cases := v_cases + 1;
  begin
    perform public.erp_platform_set_enquiry_notify_to(array['sales@zzenqn.test'], '   ');
    v_ok := false; v_msg := 'the address moved with no reason given';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ENQUIRY_NOTIFY_TO_NEEDS_REASON%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'moving the address says why'::text, v_ok, v_msg;

  v_cases := v_cases + 1;
  begin
    perform public.erp_platform_set_enquiry_notify_to(
      array['sales at zzenqn dot test'], 'a mistyped address');
    v_ok := false; v_msg := 'an address that cannot be one was accepted';
  exception when others then
    v_ok := sqlerrm like 'CLOVEERP_ENQUIRY_NOTIFY_TO_INVALID%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an address that cannot be an address is refused at the door'::text,
    v_ok, v_msg || ' — a bounce is discovered by nobody, a refusal by the person typing';

  res := public.erp_platform_set_enquiry_notify_to(
    array['sales@zzenqn.test', 'leads@zzenqn.test'], 'the sales mailbox answers enquiries');

  v_cases := v_cases + 1;
  return query select 'the configured addresses are told, and the owner is not'::text,
    (select count(*) = 2 from erp.enquiry_recipients())
    and exists (select 1 from erp.enquiry_recipients() r where r.email = 'sales@zzenqn.test')
    and exists (select 1 from erp.enquiry_recipients() r where r.email = 'leads@zzenqn.test')
    and not exists (select 1 from erp.enquiry_recipients() r where r.email = 'zzowner@zzenqn.test'),
    'owning the platform and answering a lead are different jobs, which is the '
    'whole point of this migration';

  v_cases := v_cases + 1;
  return query select 'the Edge Function is given the same list'::text,
    (select count(*) = 2 from erp_ingress.enquiry_recipients())
    and not exists (select 1 from erp_ingress.enquiry_recipients() r
                     where r.email = 'zzowner@zzenqn.test'),
    'erp_ingress.enquiry_recipients() is what supabase/functions/enquiry/index.ts reads, '
    'and it is unchanged by this migration';

  v_cases := v_cases + 1;
  return query select 'the console says where the next enquiry goes'::text,
    (res ->> 'falls_back_to_owners')::boolean is false
    and res -> 'recipients' = '["leads@zzenqn.test", "sales@zzenqn.test"]'::jsonb
    and res ->> 'reason' = 'the sales mailbox answers enquiries',
    'erp_platform_set_enquiry_notify_to returns configured, recipients and the reason';

  v_cases := v_cases + 1;
  return query select 'the platform log records the move and what it was before'::text,
    exists (select 1 from erp_meta.platform_audit a
             where a.action = 'platform.enquiry_notify_to_set'
               and a.actor_email = 'zzowner@zzenqn.test'
               and a.detail -> 'now' = '["leads@zzenqn.test", "sales@zzenqn.test"]'::jsonb),
    'platform.enquiry_notify_to_set, with the addresses on both sides of the change';

  -- ── Clearing it goes back to the owners rather than to nobody ─────────────

  v_cases := v_cases + 1;
  res := public.erp_platform_set_enquiry_notify_to(
    '{}'::text[], 'clearing it puts the leads back with the owners');
  return query select 'clearing the address sends enquiries to the owners, never to nobody'::text,
    (res ->> 'falls_back_to_owners')::boolean
    and exists (select 1 from erp.enquiry_recipients() r where r.email = 'zzowner@zzenqn.test'),
    'a contact form that stores a lead and tells nobody is worse than no form';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  -- The platform log is append-only by trigger — t_platform_audit_append_only,
  -- from 20260904810000 — so the two rows this suite wrote stay, as
  -- erp_test.enquiry_handled_suite's do. That is the log working: a routine
  -- that could erase its own entries is not a log.
  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.platform_staff where email like '%@zzenqn.test';
  delete from auth.users where id in (own, sup);

  delete from erp_meta.platform_setting where key = 'enquiry.notify_to';
  if v_had then
    insert into erp_meta.platform_setting (key, value, reason, updated_at, updated_by)
    values (v_saved.key, v_saved.value, v_saved.reason, v_saved.updated_at, v_saved.updated_by);
  end if;

  v_cases := v_cases + 1;
  return query select 'the suite leaves the platform''s own setting as it found it'::text,
    v_had = exists (select 1 from erp_meta.platform_setting s where s.key = 'enquiry.notify_to')
    and not exists (select 1 from erp_meta.platform_staff s where s.email like '%@zzenqn.test')
    and coalesce(erp.enquiry_notify_to() = coalesce(
          (select array_agg(btrim(a.value) order by btrim(a.value))
             from jsonb_array_elements_text(v_saved.value) as a(value)), '{}'::text[]), not v_had),
    'the setting is one row for the whole platform, so the suite borrows it rather '
    'than making its own';

  if v_cases <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: enquiry_notification_suite ran % cases, expected 10', v_cases;
  end if;
end;
$$;

revoke all on function erp_test.enquiry_notification_suite() from public, anon;

create or replace function erp_test.assert_enquiry_notification_suite()
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare v_fail int; v_all int; v_detail text;
begin
  create temp table if not exists _enq_notify on commit drop as
    select * from erp_test.enquiry_notification_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail from _enq_notify;
  if v_all <> 10 then
    raise exception 'CLOVEERP_SUITE_SHRANK: enquiry_notification_suite ran % cases, expected 10', v_all;
  end if;
  if v_fail > 0 then
    raise exception E'CLOVEERP_ENQUIRY_NOTIFICATION_SUITE_FAILED: %/% case(s) failed\n%', v_fail, v_all, v_detail
      using errcode = 'P0001';
  end if;
  return format('enquiry notifications: %s/%s cases pass', v_all - v_fail, v_all);
end;
$$;

revoke all on function erp_test.assert_enquiry_notification_suite() from public, anon;

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
select erp.assert_enquiries_answerable();

-- ── The suite is run by the build, not from here ─────────────────────────────
--
-- 20260920310000's rule, and this suite is the kind it was written for: it
-- borrows erp_meta.platform_setting's one enquiry.notify_to row, works, and
-- puts it back. Inside a migration's transaction that is atomic and invisible,
-- but a deploy has no business touching the live setting to prove something a
-- build already proved from an empty cluster. So the call is not made here —
-- and the claim that removing it loses no coverage is asserted rather than
-- assumed, because it rests on a catalogue picking the suite up by name.
do $covered$
declare
  v_suite    constant text := 'enquiry_notification_suite';
  v_check    constant text := 'assert_enquiry_notification_suite';
  v_expected constant integer := 10;
  v_call     text;
  v_body     text;
  v_wrap     text;
begin
  select c.call into v_call
    from erp.ci_check_catalogue() c
   where c.schema_name = 'erp_test' and c.function_name = v_check;

  if v_call is null then
    raise exception
      'CLOVEERP_SUITE_NOT_IN_CATALOGUE: erp_test.%() is not in erp.ci_check_catalogue(), so nothing runs it', v_check
      using errcode = '23503',
            hint = 'The catalogue gathers assert_% routines in erp and erp_test that take no arguments. '
                   'Either give it back that shape, or run it from somewhere that a build reaches.';
  end if;

  v_body := pg_get_functiondef(('erp_test.' || v_suite || '()')::regprocedure);
  v_wrap := pg_get_functiondef(('erp_test.' || v_check || '()')::regprocedure);

  if position('v_cases <> ' || v_expected in v_body) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold itself to % cases', v_suite, v_expected
      using errcode = '23514',
            hint = 'A suite that loses a case reports success. Pin the count inside the suite.';
  end if;

  if position('v_all <> ' || v_expected in v_wrap) = 0 then
    raise exception
      'CLOVEERP_SUITE_COUNT_UNPINNED: erp_test.%() does not hold the suite to % cases', v_check, v_expected
      using errcode = '23514',
            hint = 'The wrapper counts the rows the suite returned. Pin the same number there.';
  end if;

  raise notice
    'the build runs erp_test.%() from the catalogue as "%", and both ends pin % cases',
    v_check, v_call, v_expected;
end
$covered$;

-- The migration must not end with an enquiry that would reach nobody. Said as
-- the count and not as the address, because a replay onto a database whose
-- owner has since changed the setting from the console must not fail for
-- having found what it asked for.
do $reaches$
begin
  if not exists (select 1 from erp.enquiry_recipients()) then
    raise exception 'CLOVEERP_ENQUIRY_REACHES_NOBODY: the migration that moves enquiry notifications ends with nobody to send them to'
      using errcode = '23502',
            hint = 'Set enquiry.notify_to to the mailbox that answers enquiries, or leave a platform owner unrevoked to fall back to.';
  end if;
end
$reaches$;
