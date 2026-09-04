-- ─────────────────────────────────────────────────────────────────────────────
-- A silence budget, a visit that announces itself, and two suites that were
-- measuring the wrong thing.
--
-- The last of the minors from the production-readiness pass, each small and
-- each the same shape as the large ones: something the product could say and
-- did not.
--
-- 1. A job has no silence budget unless somebody types one in.
--    erp.job.max_silence_seconds is nullable with no default, and
--    erp.upsert_job() passes whatever it is given straight through, so every
--    job the base pack installs arrives with a null budget. erp.silent_jobs()
--    reads that budget to decide whether a job has gone quiet; with none, a job
--    that stopped running a fortnight ago is reported only if it has never
--    succeeded at all. The handler knows how often it is meant to run — that is
--    what default_timeout_seconds already is — so it can carry a default
--    silence budget the same way, and erp.upsert_job() falls back to it exactly
--    as it already falls back for the timeout.
--
-- 2. Entering a customer organisation is recorded and not announced.
--    20260904880000 made the session visible on the organisation's own screen,
--    which is the difference between a record and no record. It is not the
--    difference between a record and being told. §9.2 now has routes, so the
--    entry raises an event and the organisation's administrators hear about it
--    while it is happening rather than when they next look.
--
-- 3. Two suite cases measured something other than their own names.
--    erp_test.chart_alternative_suite's case 'erp.determine_account() has
--    something to answer from' counted rows in erp.account_determination and
--    never called the function — which is how erp.determine_account() spent its
--    whole life raising `relation "erp.entity_legislation" does not exist` with
--    a green test beside it. And erp_test.determination_coverage_suite's last
--    case, named 'and the suite removes both organisations it built', measures
--    `select count(*) from erp.determination_coverage_report() = 0` — the whole
--    database, not its own cleanup. On a fresh build that is trivially true
--    because nothing is left; on any database with real organisations in it,
--    the case fails for something that has nothing to do with the suite. It has
--    already done so once, on live.
--
-- 4. And one that was withdrawn rather than fixed. The pass logged "erasure has
--    no data-subject path" as a minor, because erp_erasure_subjects() needs
--    administration.users. Reading erp.request_erasure() shows that is the
--    design, stated in its own words:
--
--      ERPWARE_ERASURE_SELF: a principal does not erase themself;
--                            ask another administrator
--
--    Two-person control at both ends — one person asks, another executes — is
--    the same discipline the change sets and the erasure execution already
--    hold, and weakening it to add self-service would be inventing policy on an
--    organisation's behalf. The finding was wrong; nothing here changes it.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. A handler carries the silence its schedule implies ────────────────────

alter table erp_ref.job_handler
  add column if not exists default_max_silence_seconds integer;

comment on column erp_ref.job_handler.default_max_silence_seconds is
  'How long this handler may go without a successful run before erp.silent_jobs() '
  'says so. A job installed without one has no budget at all, which is how a job '
  'that stopped a fortnight ago goes unreported.';

-- Measured against the schedules the base pack ships, then rounded up: a budget
-- is a promise about the worst acceptable silence, not a restatement of the
-- interval, so each is comfortably more than one missed run.
update erp_ref.job_handler set default_max_silence_seconds = v.secs
  from (values
    ('administration.approval_ageing',        7200),
    ('administration.sequence_gaps',         172800),
    ('commercial.expire_contracts',          172800),
    ('commercial.expire_quotes',             172800),
    ('commercial.generate_invoice_schedules', 172800),
    ('commercial.measure_active_users',      172800),
    ('commercial.propose_renewals',          172800),
    ('commercial.raise_contract_key_dates',  172800),
    ('commercial.report_entitlement_breaches', 86400),
    ('finance.grni_ageing',                  172800),
    ('finance.stock_to_ledger',               86400),
    ('finance.suspense_balance',              86400),
    ('integration.backlog',                    7200),
    ('integration.backlog_alert',              7200),
    ('inventory.expiry_horizon',              86400),
    ('inventory.reservation_ageing',          86400),
    ('notifications.dispatch',                 3600),
    ('notifications.route_events',             3600),
    ('platform.reclaim_expired_commands',      3600),
    ('platform.reclaim_timed_out_runs',        3600),
    ('platform.report_silent_jobs',           86400),
    ('reporting.distribute_subscriptions',    86400),
    ('reporting.produce_extracts',            86400)
  ) as v(code, secs)
 where erp_ref.job_handler.code = v.code;

-- A handler with no budget is a job that can go quiet unnoticed, so the
-- register refuses to hold one.
do $$
declare v_missing text;
begin
  select string_agg(code, ', ' order by code) into v_missing
    from erp_ref.job_handler where is_current and default_max_silence_seconds is null;
  if v_missing is not null then
    raise exception
      'ERPWARE_HANDLER_WITHOUT_SILENCE_BUDGET: % ', v_missing
      using errcode = '23502',
      hint = 'Give the handler a default_max_silence_seconds in this migration; '
             'a job installed without one is never reported as silent.';
  end if;
end $$;

CREATE OR REPLACE FUNCTION erp.upsert_job(p_code text, p_name text, p_handler_code text, p_schedule_kind text, p_interval_seconds integer DEFAULT NULL::integer, p_at_time time without time zone DEFAULT NULL::time without time zone, p_days_of_week text DEFAULT NULL::text, p_day_of_month integer DEFAULT NULL::integer, p_timezone text DEFAULT 'UTC'::text, p_parameters jsonb DEFAULT '{}'::jsonb, p_timeout_seconds integer DEFAULT NULL::integer, p_max_silence_seconds integer DEFAULT NULL::integer, p_is_enabled boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_tenant uuid := erp.require_tenant_id();
  h        erp_ref.job_handler%rowtype;
  v_days   smallint[];
  v_id     uuid;
begin
  select * into h from erp_ref.job_handler where code = p_handler_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_JOB_HANDLER: % is not a handler this product implements',
      p_handler_code using errcode = '23503',
      hint = 'erp_ref.job_handler lists them. A job naming a handler nothing implements '
             'is the failure erp.assert_scheduler_integrity() exists to refuse.';
  end if;

  if jsonb_typeof(coalesce(p_parameters, '{}'::jsonb)) <> 'object' then
    raise exception 'ERPWARE_JOB_PARAMETERS: parameters must be an object'
      using errcode = '22023';
  end if;

  -- Comma-separated rather than an array, because that is what every other door
  -- taking a list does and what a form field can produce.
  v_days := case
    when p_days_of_week is null or btrim(p_days_of_week) = '' then null
    else (select array_agg(btrim(s)::smallint)
            from unnest(string_to_array(p_days_of_week, ',')) s
           where btrim(s) <> '')
  end;

  insert into erp.job (
    tenant_id, code, name, handler_code, parameters, schedule_kind,
    interval_seconds, at_time, days_of_week, day_of_month, timezone,
    timeout_seconds, max_silence_seconds, is_enabled)
  values (
    v_tenant, lower(btrim(p_code)), p_name, p_handler_code,
    coalesce(p_parameters, '{}'::jsonb),
    p_schedule_kind::erp.job_schedule_kind,
    p_interval_seconds, p_at_time, v_days, p_day_of_month::smallint,
    coalesce(nullif(btrim(p_timezone), ''), 'UTC'),
    coalesce(p_timeout_seconds, h.default_timeout_seconds),
    -- The same fallback the timeout has always had. Without it every job the
    -- base pack installs arrives with a null budget, and a job that stopped
    -- running is reported only if it had never succeeded at all.
    coalesce(p_max_silence_seconds, h.default_max_silence_seconds),
    coalesce(p_is_enabled, true))
  on conflict (tenant_id, code) do update set
    name = excluded.name, handler_code = excluded.handler_code,
    parameters = excluded.parameters, schedule_kind = excluded.schedule_kind,
    interval_seconds = excluded.interval_seconds, at_time = excluded.at_time,
    days_of_week = excluded.days_of_week, day_of_month = excluded.day_of_month,
    timezone = excluded.timezone, timeout_seconds = excluded.timeout_seconds,
    max_silence_seconds = excluded.max_silence_seconds,
    is_enabled = excluded.is_enabled, updated_at = now()
  returning id into v_id;

  -- next_run_at is not set here: erp.maintain_job_schedule() computes it from
  -- the schedule on write, and duplicating that arithmetic is how the two
  -- disagree later.
  return jsonb_build_object('job_id', v_id, 'code', lower(btrim(p_code)));
end;
$function$;

-- ── 2. A visit that announces itself ─────────────────────────────────────────

insert into erp_ref.event_type
  (code, version, aggregate_type, module_code, name_key, description,
   payload_schema, is_current)
values
  ('support.access_granted', 1, 'support_access', 'administration',
   'event.support.access_granted',
   'Platform staff entered this organisation under a time-bounded support '
   'window. The window itself is on erp.support_access; this is the moment it '
   'opened, so the organisation is told rather than left to look.',
   '{"type": "object"}'::jsonb, true)
on conflict (code, version) do update set
  aggregate_type = excluded.aggregate_type, module_code = excluded.module_code,
  name_key = excluded.name_key, description = excluded.description,
  payload_schema = excluded.payload_schema, is_current = excluded.is_current;

insert into erp_ref.resource (key, locale, value, module_code, description)
values
  ('notify.support_access_granted.subject', 'en',
   'Clove ERP support has been given access', 'administration',
   'Subject line when platform staff enter a customer organisation.'),
  ('notify.support_access_granted.body', 'en',
   'A member of Clove ERP support has been given a time-bounded window in your '
   'organisation. Settings → Operations → continuity shows who, why and until '
   'when.', 'administration',
   'Body when platform staff enter a customer organisation.'),
  ('event.support.access_granted', 'en', 'Support access granted', 'administration',
   'The event raised when platform staff enter a customer organisation.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code,
  description = excluded.description;

insert into erp_ref.pack_item
  (pack_code, object_kind, object_key, payload, operation, requires_capability,
   is_decision, decision_prompt, provenance, seq)
values
  ('base', 'notification_template', 'support_access_granted',
   jsonb_build_object(
     'code', 'support_access_granted',
     'channel_kind', 'email',
     'subject_key', 'notify.support_access_granted.subject',
     'body_key', 'notify.support_access_granted.body'),
   'upsert', null, false, null,
   'Starter Content Packs §9.2 and §17.1. Being able to look up a support '
   'session is not the same as being told about one.', 6214),

  ('base', 'notification_route', 'support_access_granted',
   jsonb_build_object(
     'code', 'support_access_granted',
     'name', 'Clove ERP support has entered this organisation',
     'event_pattern', 'support.access_granted', 'severity', 'high',
     'audience_kind', 'role', 'role_code', 'administrator',
     'channel_kind', 'email', 'template_code', 'support_access_granted',
     'is_mandatory', true),
   'upsert', null, false, null,
   'Starter Content Packs §9.2 and §17.1. Mandatory: whether somebody outside '
   'the organisation is inside it is not a matter of notification taste.', 6215)
on conflict (pack_code, object_kind, object_key) do update set
  payload = excluded.payload, operation = excluded.operation,
  provenance = excluded.provenance, seq = excluded.seq;

CREATE OR REPLACE FUNCTION public.erp_platform_enter_tenant(p_tenant_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v        erp_meta.platform_staff;
  v_t      erp.tenant;
  v_user   uuid;
  v_owner  uuid;
  v_role   uuid;
  v_access jsonb;
begin
  v := erp_meta.require_platform('support');

  -- The same reason erp.grant_support_access has always required. It used to be
  -- merely non-empty here, which meant the door that actually grants access
  -- held a lower bar than the door that records it — and, once this function
  -- records the access, a one-word reason would have failed deep inside the
  -- insert instead of being refused by name.
  if length(btrim(coalesce(p_reason, ''))) < 20 then
    raise exception
      'ERPWARE_REASON_REQUIRED: entering a customer organisation needs a reason, '
      'not a word'
      using errcode = '22023',
      hint = '§17.1: say what you are looking at and for whom — the customer '
             'reads this on their own support-access screen. At least twenty '
             'characters.';
  end if;

  select * into v_t from erp.tenant where id = p_tenant_id;
  if v_t.id is null then
    raise exception 'ERPWARE_UNKNOWN_TENANT' using errcode = '23503';
  end if;

  perform set_config('erp.job_tenant_id', p_tenant_id::text, true);

  select u.id into v_user from erp.app_user u
   where u.tenant_id = p_tenant_id and u.auth_user_id = v.auth_user_id;

  if v_user is null then
    -- No row bound to this account. Before making one, look for the email:
    -- erp.app_user is unique on (tenant_id, email), and the row most likely to
    -- be holding this staff member's address is the administrator the console
    -- invited when it created the organisation — very often typed in by the
    -- same person now trying to enter. Inserting over it raised 23505 on a
    -- unique index, which is the product refusing to work rather than the
    -- product telling somebody their name is taken.
    select u.id, u.auth_user_id into v_user, v_owner
      from erp.app_user u
     where u.tenant_id = p_tenant_id
       and lower(u.email) = lower(v.email)
     limit 1;

    if v_user is not null and v_owner is not null then
      -- Held by a different account. Adopting it would hand one person's
      -- identity inside a customer's organisation to another, which is a much
      -- worse thing than a refusal, so it is refused by name.
      raise exception
        'ERPWARE_EMAIL_TAKEN: a different account already holds % in this organisation', v.email
        using errcode = '22023';
    end if;

    if v_user is not null then
      update erp.app_user
         set auth_user_id = v.auth_user_id,
             status       = 'active'
       where id = v_user;
    else
      insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name,
                                email, user_locale)
      values (p_tenant_id, v.auth_user_id, 'person', 'active',
              v.display_name || ' (Clove ERP ' || v.staff_role || ')',
              v.email, 'en')
      returning id into v_user;
    end if;
  else
    update erp.app_user set status = 'active' where id = v_user;
  end if;

  select r.id into v_role from erp.role r
   where r.tenant_id = p_tenant_id and r.code = 'administrator' and r.status = 'active';

  if v_role is not null and not exists (
    select 1 from erp.user_role ur
     where ur.tenant_id = p_tenant_id and ur.app_user_id = v_user and ur.role_id = v_role)
  then
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    values (p_tenant_id, v_user, v_role,
            'Platform ' || v.staff_role || ' support access: ' || p_reason);
  end if;

  insert into erp_meta.principal_preference (auth_user_id, active_tenant_id)
  values (v.auth_user_id, p_tenant_id)
  on conflict (auth_user_id)
    do update set active_tenant_id = excluded.active_tenant_id, chosen_at = now();

  -- §17.1. The grant above gives administration rights inside somebody else's
  -- organisation; this is the row that says so on that organisation's own
  -- screen, while it is happening. The role granted is an administrator, so the
  -- window is a write window — recording it as read-only would put every change
  -- made during the session outside its access, which is the finding
  -- erp.assert_support_discipline() raises.
  v_access := erp.grant_support_access(p_tenant_id, p_reason, 4, true, null, null, v_user);

  -- And the organisation is told, rather than left to notice. The record made
  -- the session visible to somebody who went looking; §9.2's route is what
  -- reaches the administrators who did not.
  perform erp.append_event(
    'support.access_granted', 'support_access',
    (v_access ->> 'access_id')::uuid,
    jsonb_build_object('staff_email', v.email, 'staff_role', v.staff_role,
                       'reason', p_reason,
                       'expires_at', v_access ->> 'expires_at'));

  perform erp_meta.platform_log(v, 'platform.tenant_entered', p_tenant_id,
                                v_t.code, p_reason,
                                jsonb_build_object('access_id', v_access ->> 'access_id',
                                                   'expires_at', v_access ->> 'expires_at'));

  return jsonb_build_object('tenant_id', p_tenant_id, 'code', v_t.code,
                            'principal_id', v_user,
                            'access_id', v_access ->> 'access_id',
                            'expires_at', v_access ->> 'expires_at');
end;
$function$;

-- ── 4. The decision that had no row ──────────────────────────────────────────

insert into erp_ref.product_decision
  (code, seq, title, decision, rationale, cost, supersedes, spec_reference)
values
  ('D39', 39,
   'Sign-in rate limiting, session lifetime and password strength are platform settings, not schema',
   'Clove ERP does not implement its own rate limiting, session expiry or '
   'password policy. Authentication is Supabase Auth, and those three controls '
   'are project settings on it: sign-in and sign-up rate limits, the JWT and '
   'refresh-token lifetimes, and the minimum password length and required '
   'character classes, with leaked-password protection on. The product''s own '
   'controls — erp.authorise(), row security, the support-access window, the '
   'append-only logs — sit behind authentication and assume it has already '
   'happened.',
   'A control that exists in the product can be asserted on every build. These '
   'three cannot, so they were invisible: the production-readiness pass could '
   'find no schema surface for them and no record that anybody had decided '
   'anything. A decision nobody wrote down is indistinguishable from an '
   'oversight, and this is the register that tells them apart.',
   'The settings live in a console this repository does not build, so they '
   'cannot be version-controlled here and a change to them leaves no trace in '
   'the migration history. They must be checked by hand at each go-live.',
   null, 'v1.5 Part 23')
on conflict (code) do update set
  seq = excluded.seq, title = excluded.title, decision = excluded.decision,
  rationale = excluded.rationale, cost = excluded.cost,
  spec_reference = excluded.spec_reference;

select erp.assert_scheduler_integrity();
select erp.assert_notification_routes_resolvable();
select erp.assert_public_api_safe();

-- ── 3. Two suite cases that measured something other than their own names ───

CREATE OR REPLACE FUNCTION erp_test.chart_alternative_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();
  v_t uuid; res jsonb; v_cs uuid; n integer; v_ok boolean; v_msg text;
begin
  insert into auth.users (id, email) values (a1, 'chart@zzchart.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.onboard_tenant('Chart', 'zzchart');
  v_t := erp.require_tenant_id();

  -- The choice, made before there is a chart. Direct rather than through a
  -- change set because the organisation is inside its bootstrap window, which
  -- is the only moment this choice can be made.
  perform erp.set_capability('statutory_chart_8_1', true, 'chose §8.1''s chart');

  return query select 'the choice is a capability like every other choice',
    erp.capability_on(v_t, 'statutory_chart_8_1', current_date),
    'not a flag on erp.tenant and not a migration argument — it appears on the '
    'features screen beside the rest';

  -- ── The chart first, then the modules ───────────────────────────────────
  --
  -- Order matters and the product enforces it. erp.promote_change_set()
  -- refuses a change set that introduces a posting rule naming an account the
  -- company does not have — C1's determination-coverage gate — so installing a
  -- module before the chart it posts to is refused rather than discovered at a
  -- month end. That refusal is what found this ordering.

  res := erp.apply_content_pack('chart_8_1');
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);

  return query select 'the pack brings the whole chart',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,
    format('%s accounts, including the four §8.1 names that nothing created — '
           'freight variance, equity, operating expenses and suspense',
      (select count(*) from erp.account a where a.tenant_id = v_t));

  return query select 'the chart it ships conforms to §8.1''s own ranges',
    (select count(*) from erp.chart_of_accounts_divergence_report(v_t)) = 0,
    format('%s divergences from the report that measures §8.1 conformance',
      (select count(*) from erp.chart_of_accounts_divergence_report(v_t)));

  perform erp.configure_finance();
  perform erp.configure_procurement();
  perform erp.configure_inventory();
  perform erp.configure_production();
  perform erp.configure_sales();
  perform erp.configure_procurement_controls();

  return query select 'the installers create no chart of their own',
    (select count(*) from erp.account a where a.tenant_id = v_t) = 20,
    format('still %s accounts after six installers, because the pack owns the '
           'chart and they defer to it',
      (select count(*) from erp.account a where a.tenant_id = v_t));

  return query select 'and their posting rules reach the chart that is actually there',
    (select count(*) from erp.dead_configuration_report()) = 0,
    'erp.chart_account_code() gives the installer the code for the chart in '
    'force while it builds the rule; posting still resolves a literal, '
    'unchanged';

  return query select 'so a purchase invoice clears GRNI at §8.1''s code',
    exists (
      select 1 from erp.posting_rule pr, lateral jsonb_array_elements(pr.posting_lines) l
       where pr.tenant_id = v_t and pr.code = 'purchase_invoice'
         and pr.status = 'active'
         and l ->> 'side' = 'debit' and l ->> 'account' = '3200'),
    'the same rule on the default chart debits 2100';

  -- ── The flags §9.1's job reads ──────────────────────────────────────────

  return query select 'GRNI, tax control and suspense block a close',
    (select count(*) from erp.account a
      where a.tenant_id = v_t and a.close_blocking) = 3
    and (select count(*) from erp.account a
          where a.tenant_id = v_t and a.reconciliation_required) = 4,
    format('%s close-blocking, %s needing reconciliation',
      (select count(*) from erp.account a where a.tenant_id = v_t and a.close_blocking),
      (select count(*) from erp.account a where a.tenant_id = v_t and a.reconciliation_required));

  return query select 'and §9.1''s suspense job now has a suspense account to report on',
    exists (select 1 from erp.account a
             where a.tenant_id = v_t and a.code = '9000' and a.close_blocking),
    '§13 clause 7 asks to close a period with suspense empty, and until this '
    'no chart the product shipped had one';

  -- ── The determination matrix ────────────────────────────────────────────

  select count(*) into n from erp.account_determination ad where ad.tenant_id = v_t;
  return query select 'erp.determine_account() has something to answer from',
    n = 20,
    format('%s determinations, one per purpose, where a configured '
           'organisation had none at all', n);

  -- And it is asked. Counting the rules is not the same as calling the
  -- function the case above is named after, and the difference mattered:
  -- erp.determine_account() read a table that does not exist and raised on
  -- every call that reached it, for as long as it had existed, with this
  -- suite green beside it the whole time.
  declare
    v_ans jsonb;
    v_ok  boolean;
    v_msg text;
  begin
    begin
      v_ans := erp.determine_account(
        'goods_receipt', null, null, null,
        (select e.id from erp.entity e where e.tenant_id = v_t limit 1),
        null, null, current_date, false);
      v_ok  := v_ans ? 'matched';
      v_msg := format('matched=%s, why=%s', v_ans ->> 'matched',
                      coalesce(v_ans ->> 'why', '-'));
    exception when others then
      v_ok := false; v_msg := left(sqlerrm, 90);
    end;
    return query select 'and answering is asking it, not counting its rules',
      v_ok, v_msg;
  end;

  -- ── Falsification: the guard on switching it back off ───────────────────

  return query select 'switching the chart off is guarded once anything has posted',
    exists (select 1 from erp_ref.capability_guard g
             where g.capability_code = 'statutory_chart_8_1'
               and g.table_name = 'journal_line'),
    'the postings would be left pointing at accounts the chart no longer '
    'explains, and the rules at accounts nobody can find';

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  delete from auth.users where id = a1;

  return query select 'and the suite removes the organisation it built',
    not exists (select 1 from erp.account a where a.tenant_id = v_t),
    'the chart cascades with the tenant, as every tenant-scoped table does';
end $function$

;

CREATE OR REPLACE FUNCTION erp_test.determination_coverage_suite()
 RETURNS TABLE(case_name text, passed boolean, detail text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  a1 uuid := gen_random_uuid();
  b1 uuid := gen_random_uuid();
  v jsonb; v_t uuid; v_e uuid; v_tb uuid;
  v_dt uuid; v_rule text; v_pr uuid; v_acc uuid; v_want text;
  n integer; v_ok boolean; v_msg text; v_cs uuid;
begin
  insert into auth.users (id, email) values
    (a1, 'c1@zzc1.test'), (b1, 'c1b@zzc1.test');

  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  v := erp.onboard_tenant('C1 coverage', 'zzc1');
  v_t := (v ->> 'tenant_id')::uuid;
  v_e := (v ->> 'entity_id')::uuid;
  perform erp.configure_finance();
  perform erp.configure_procurement();
  perform erp.configure_sales(20);

  -- ── The baseline ────────────────────────────────────────────────────────

  return query select
    'a fully configured organisation has nothing to report',
    (select count(*) from erp.determination_coverage_report(v_t)) = 0,
    'if this is not zero every case below is measuring the wrong thing';

  return query select 'and it has finance-bearing document types to judge',
    (select count(*) from erp.document_type dt
       join erp_ref.document_type bt on bt.code = dt.base_type_code
      where dt.tenant_id = v_t and dt.status = 'active' and bt.affects_finance) > 0,
    'a report over an organisation with no postable documents is green for '
    'the same reason an empty database is';

  -- ── The posting path ────────────────────────────────────────────────────

  select dt.id, dt.posting_rule_code into v_dt, v_rule
    from erp.document_type dt
    join erp_ref.document_type bt on bt.code = dt.base_type_code
   where dt.tenant_id = v_t and dt.status = 'active' and bt.affects_finance
     and dt.posting_rule_code is not null
   limit 1;

  update erp.document_type set posting_rule_code = null where id = v_dt;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%names no posting rule';
  return query select 'a document type that reaches the ledger and names no rule',
    n = 1, format('%s finding(s) — posting it raises ERPWARE_NO_POSTING_RULE', n);

  update erp.document_type set posting_rule_code = 'NO-SUCH-RULE' where id = v_dt;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%no version in force';
  return query select 'a document type naming a rule with no version in force',
    n = 1,
    format('%s finding(s) — a document outside every version''s range must not '
           'be guessed at', n);
  update erp.document_type set posting_rule_code = v_rule where id = v_dt;

  -- §5's own sentence, on the mechanism that posts. Accounts resolve by code
  -- AND company, so retiring one breaks every rule that names it, on the
  -- companies that no longer have it, and nowhere else.
  select l.value ->> 'account' into v_want
    from erp.posting_rule pr,
         lateral jsonb_array_elements(pr.posting_lines) l
   where pr.tenant_id = v_t and pr.status = 'active'
     and (l.value ->> 'account') is not null
   limit 1;
  update erp.account set status = 'inactive'
   where tenant_id = v_t and code = v_want;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%account a company does not have';
  return query select
    'an account retired out from under a rule that names it',
    n > 0,
    format('%s document type(s) would refuse on this company with '
           'ERPWARE_UNKNOWN_ACCOUNT and work everywhere else', n);
  update erp.account set status = 'active'
   where tenant_id = v_t and code = v_want;

  select id into v_pr from erp.posting_rule
   where tenant_id = v_t and status = 'active' limit 1;
  update erp.posting_rule set ledger_id = null where id = v_pr;
  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%names no ledger';
  return query select 'a rule in force with no ledger to post into',
    n = 1, format('%s finding(s)', n);
  update erp.posting_rule
     set ledger_id = (select l.id from erp.ledger l
                       where l.tenant_id = v_t and l.code = 'GL')
   where id = v_pr;

  return query select 'and with all four put back, the posting path is clear',
    (select count(*) from erp.determination_coverage_report(v_t)
      where mechanism = 'posting path') = 0,
    'a report that cannot go back to green is a report nobody will act on';

  -- ── The determination surface ───────────────────────────────────────────

  insert into erp.account (tenant_id, entity_id, code, name, account_type, status)
  values (v_t, v_e, '9999', 'Retired account', 'expense', 'inactive')
  returning id into v_acc;
  insert into erp.account_determination (
    tenant_id, transaction_type, account_id, valid_from, status)
  values (v_t, 'zz_probe', v_acc, current_date, 'active');

  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%account that is not active';
  return query select 'a determination rule pointing at a retired account',
    n = 1,
    format('%s finding(s) — the rule resolves and the account behind it cannot '
           'receive a posting', n);

  insert into erp.posting_class (tenant_id, kind, code, name, valid_from, status)
  values (v_t, 'item', 'FG', 'Finished goods', current_date, 'active'),
         (v_t, 'item', 'RM', 'Raw materials',  current_date, 'active');
  update erp.account_determination
     set item_class_id = (select pc.id from erp.posting_class pc
                           where pc.tenant_id = v_t and pc.kind = 'item'
                             and pc.code = 'FG')
   where tenant_id = v_t and transaction_type = 'zz_probe';

  select count(*) into n from erp.determination_coverage_report(v_t)
   where finding like '%no determination rule';
  return query select
    'a posting class and company combination with no rule to cover it',
    n = 1,
    format('%s finding(s) — §5 refuses a default-to-suspense, so this is a '
           'refusal at posting time', n);

  return query select 'the report names which mechanism each finding is on',
    (select count(distinct mechanism) from erp.determination_coverage_report(v_t)) = 1
      and (select distinct mechanism from erp.determination_coverage_report(v_t))
          = 'determination',
    'erp.account_determination is not on the path that raises journals, and a '
    'report that blurred the two would overstate what it proves';

  -- ── The assertion over the report ───────────────────────────────────────

  begin
    perform erp.assert_determination_coverage(v_t);
    v_ok := false; v_msg := 'the assertion returned with two findings outstanding';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DETERMINATION_NOT_COVERED%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select 'the assertion raises rather than returning a count',
    v_ok, v_msg;

  -- ── The gate on the promotion path ──────────────────────────────────────
  --
  -- Two gaps are outstanding at this point, deliberately. That is what makes
  -- these two cases worth anything: the first proves the gate does not punish
  -- a promotion for a gap it did not cause, and the second proves it stops one
  -- that does.

  v_cs := erp.create_change_set('zzc1-t', 'Terminology', 'Touches nothing financial.');
  perform erp.add_change_set_item(v_cs, 'terminology', 'nav.sales|en',
    jsonb_build_object('key', 'nav.sales', 'locale', 'en', 'value', 'Selling'));
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := true; v_msg := 'promoted, with two gaps outstanding and untouched';
  exception when others then
    v_ok := false; v_msg := 'REFUSED: ' || left(sqlerrm, 70);
  end;
  return query select
    'a promotion that changes nothing financial is not held up by an old gap',
    v_ok, v_msg;

  -- A posting class with no determination rule to cover it is a real way to
  -- break determination by promotion, and an easy one to do by accident.
  v_cs := erp.create_change_set('zzc1-p', 'A class nothing covers',
    'One posting class, no rule for it.');
  perform erp.add_change_set_item(v_cs, 'posting_class', 'item|ZZNEW',
    jsonb_build_object('kind', 'item', 'code', 'ZZNEW', 'name', 'Uncovered class'));
  perform erp.submit_change_set(v_cs);
  perform erp.approve_change_set(v_cs);
  begin
    perform erp.promote_change_set(v_cs);
    v_ok := false; v_msg := 'promoted a change set that broke determination';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_PROMOTION_BREAKS_DETERMINATION%';
    v_msg := left(sqlerrm, 80);
  end;
  return query select
    'and one that introduces a new way for a posting to fail is refused',
    v_ok, v_msg;

  return query select 'the refused promotion rolled back whole',
    not exists (select 1 from erp.posting_class pc
                 where pc.tenant_id = v_t and pc.code = 'ZZNEW'),
    'a promotion that fails half-applied is worse than one that never ran';

  -- ── Scope ───────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', json_build_object('sub', b1)::text, true);
  v := erp.onboard_tenant('C1 neighbour', 'zzc1b');
  v_tb := (v ->> 'tenant_id')::uuid;
  perform erp.configure_finance();

  return query select 'one organisation''s gaps are not reported against another',
    (select count(*) from erp.determination_coverage_report(v_tb)) = 0,
    'the whole point of a per-organisation scope is that a promotion here is '
    'not held up by a gap over there';

  return query select 'and the unscoped report sees both',
    (select count(*) from erp.determination_coverage_report()) >=
    (select count(*) from erp.determination_coverage_report(v_t)),
    'CI runs it unscoped, over whatever is in the database at the time';

  -- ── Clean up ────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_t);
  delete from erp.tenant where id = v_t;
  perform erp.end_tenant_purge();
  perform erp.begin_tenant_purge(v_tb);
  delete from erp.tenant where id = v_tb;
  perform erp.end_tenant_purge();
  delete from auth.users where id in (a1, b1);

  -- What this case is named for is its own cleanup, and what it used to
  -- measure was the whole database: count(*) from a report with no tenant
  -- filter. On a fresh build that is trivially zero because nothing is left,
  -- so it passed for the wrong reason; on a database with real organisations
  -- in it, it failed for somebody else's configuration gap. It has already
  -- done both. It now asks the question in its name.
  return query select 'and the suite removes both organisations it built',
    not exists (select 1 from erp.tenant t where t.id in (v_t, v_tb))
      and not exists (select 1 from erp.determination_coverage_report() r
                       where r.tenant_code in ('zzdet-a', 'zzdet-b')),
    'its own two organisations, and its own two organisations only — the '
    'report reads every tenant, which is what made this vacuous in CI and '
    'red against anybody else''s data';
end $function$

;

-- The chart-alternative suite gained the case that asks erp.determine_account()
-- something, so its expected count moves with it. The count is the guard
-- against a suite quietly losing a case, which is exactly how the case above
-- was able to stand for so long saying one thing and measuring another.
CREATE OR REPLACE FUNCTION erp_test.assert_chart_alternative_suite()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_pass integer; v_total integer; v_detail text;
  -- One on the choice, two on the pack, three on the installers deferring to
  -- it, two on the flags, one counting the determinations and one asking
  -- erp.determine_account() for one, one on the guard, cleanup.
  c_expected constant integer := 12;
begin
  create temporary table if not exists zz_chart_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from zz_chart_result;
  insert into zz_chart_result select * from erp_test.chart_alternative_suite();

  select count(*) filter (where passed), count(*),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not passed)
    into v_pass, v_total, v_detail from zz_chart_result;

  if v_total <> c_expected then
    raise exception 'ERPWARE_SUITE_SHRANK: %/% cases ran, % expected',
      v_pass, v_total, c_expected using errcode = 'P0001';
  end if;
  if v_pass < v_total then
    raise exception E'ERPWARE_CHART_ALTERNATIVE_SUITE_FAILED: %/%\n%',
      v_pass, v_total, v_detail using errcode = 'P0001';
  end if;

  return format('chart alternative: %s/%s', v_pass, v_total);
end $function$;

select erp.assert_scheduler_integrity();
select erp.assert_notification_routes_resolvable();
select erp.assert_audit_attributed();
select erp.assert_public_api_safe();

-- ── The strings the two new events render through ────────────────────────────
--
-- erp.assert_resource_coverage() found these the moment they were registered,
-- which is the register doing its job: an event type whose name_key resolves to
-- nothing shows a person the key instead of a sentence.

insert into erp_ref.resource (key, locale, value, module_code, description)
values
  ('event.job.failed', 'en', 'Scheduled job failed', 'administration',
   'The event raised when a job exhausts its attempts.'),
  ('event.integration.backlog_exceeded', 'en',
   'Integration backlog above its threshold', 'administration',
   'The event raised when the queue crosses the threshold its job was given.')
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code,
  description = excluded.description;

-- ── And D39 is bound to a check, like every other decision ───────────────────
--
-- erp.assert_product_decisions_enforced() refuses a decision that nothing
-- enforces, and it refused this one as soon as it was written — correctly, and
-- awkwardly, because D39's whole content is that these three controls are NOT
-- in the schema. A decision not to build something is still checkable: what it
-- forbids is a second, half-built implementation drifting in beside the real
-- one, and that is what this looks for.

create or replace function erp.authentication_boundary_report()
returns table (finding text, reference text, detail text)
language sql
stable
set search_path to ''
as $$
  -- A routine in the product's own schemas that looks like it is implementing
  -- rate limiting, session lifetime or password policy. D39 says those live in
  -- Supabase Auth; something here doing them too means two answers to the same
  -- question, and the one nobody configured wins silently.
  select 'the product appears to implement an authentication control',
         n.nspname || '.' || p.proname,
         'D39 places sign-in rate limiting, session lifetime and password '
         'strength in Supabase Auth. A routine here doing the same is a second '
         'answer to a question that already has one.'
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('erp', 'public', 'erp_meta')
     and (p.proname ~ 'rate_limit|throttle_sign|password_policy|password_strength'
          or p.proname ~ 'session_lifetime|session_expiry')

  union all

  -- Or a table holding the same policy.
  select 'the product appears to store an authentication policy',
         c.relnamespace::regnamespace::text || '.' || c.relname,
         'D39 places these settings on the authentication provider; a table '
         'here holding them is a copy that will drift.'
    from pg_catalog.pg_class c
   where c.relkind = 'r'
     and c.relnamespace::regnamespace::text in ('erp', 'erp_meta', 'erp_ref')
     and c.relname ~ 'rate_limit|password_policy|session_policy'
$$;

revoke all on function erp.authentication_boundary_report() from public, anon;

create or replace function erp.assert_authentication_boundary()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_count int; v_detail text;
begin
  select count(*), string_agg(format('  %s — %s (%s)', r.finding, r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.authentication_boundary_report() r;

  if v_count > 0 then
    raise exception E'ERPWARE_AUTHENTICATION_BOUNDARY: % finding(s)\n%', v_count, v_detail
      using errcode = '23514',
      hint = 'D39: these three controls belong to Supabase Auth. Either remove '
             'the second implementation, or supersede D39 with a decision that '
             'says the product owns them.';
  end if;

  return 'authentication boundary: rate limiting, session lifetime and password '
         'strength are the provider''s, and nothing here shadows them';
end;
$$;

revoke all on function erp.assert_authentication_boundary() from public, anon;

insert into erp_ref.product_decision_check (decision_code, schema_name, routine_name, note)
values
  ('D39', 'erp', 'assert_authentication_boundary',
   'A decision not to build something is checkable by what it forbids: a '
   'second implementation of rate limiting, session lifetime or password '
   'policy drifting in beside the provider''s. The settings themselves live in '
   'a console this repository does not build, which D39 states as its cost.')
on conflict (decision_code, schema_name, routine_name) do update set
  note = excluded.note;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('authentication_boundary', 'Authentication controls are the provider''s',
   'assertion', 'platform', 'erp', 'assert_authentication_boundary', '',
   'authentication_boundary_report', '',
   'D39 puts rate limiting, session lifetime and password strength on Supabase '
   'Auth. This refuses a second implementation growing beside it.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

select erp.assert_authentication_boundary();
select erp.assert_product_decisions_enforced();
select erp.assert_resource_coverage('en');
select erp.assert_diagnostics_registered();
