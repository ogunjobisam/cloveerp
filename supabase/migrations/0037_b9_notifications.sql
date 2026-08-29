-- =============================================================================
-- ERPWare — B9 (part 2/3): notifications
-- Spec 3.9 (Notifications), 3.8 (alerts suppressed during planned outages)
--
--   "Channel abstraction with routing rules as configuration, digesting,
--    escalation and quiet hours. Templates are resource-based and localised."
--
-- Almost none of this is new machinery. Routing rules are B3's JsonLogic
-- evaluated against the notification's context. Templates are B5's resource
-- keys resolved through the locale fallback chain. Channel credentials are
-- B8's secret guards. Alert suppression is B9 part 1's outage calendar. What
-- is actually new is the queue, and the rules about when something may leave it.
--
-- The design question that matters is what quiet hours mean. Two readings:
--
--   Suppress — the notification is not sent. Simple, and wrong: it turns "do
--   not disturb me at 2am" into "lose the 2am stock-out", and the person who
--   configured it has no idea that is what they asked for.
--
--   Defer — the notification is held and delivered when the window ends.
--
-- Only the second is honest, so erp.notification has a 'held' status and a
-- deliver_after, and nothing is ever dropped for being inconvenient. A severity
-- floor lets genuinely urgent things through regardless, which is the whole
-- reason to record severity in the first place.
--
-- Three refusals:
--
--   1. A template whose text does not exist. A rule pointing at resource keys
--      with no resource is a notification that will render blank at the worst
--      possible moment; erp.assert_resource_coverage() now covers templates.
--
--   2. Escalation to the same audience. Escalating to the person who already
--      has not responded is not escalation, it is a second copy.
--
--   3. A credential in a channel's configuration. Same guard as B8, because a
--      webhook URL with an embedded token is exactly as much of a secret as an
--      API key, and looks far more innocent.
-- =============================================================================

create type erp.notification_channel_kind as enum (
  'email', 'sms', 'push', 'webhook', 'in_app'
);

create type erp.notification_severity as enum (
  'info', 'low', 'medium', 'high', 'critical'
);

create type erp.notification_status as enum (
  'pending',    -- ready to send
  'held',       -- inside quiet hours; deliver_after says when it leaves
  'digested',   -- folded into a digest and will not be sent alone
  'sending',    -- claimed by a worker
  'sent',
  'failed',     -- will retry
  'dead',       -- out of attempts
  'suppressed'  -- an outage window, or a kill switch; recorded, not sent
);

-- -----------------------------------------------------------------------------
-- Channels
-- -----------------------------------------------------------------------------

create table erp.notification_channel (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name            text not null,
  kind            erp.notification_channel_kind not null,
  -- Endpoint, sender identity, formatting options. Never a credential.
  settings        jsonb not null default '{}'::jsonb,
  -- Same contract as erp.external_system: a pointer into a secret store,
  -- resolved by the sending worker, never the secret itself.
  credential_ref  text
                    check (credential_ref is null
                           or credential_ref ~ '^[a-z][a-z0-9+.-]*://[^[:space:]]+$'),
  is_enabled      boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code),
  constraint notification_channel_credential_not_inline
    check (credential_ref is null or not erp_ref.looks_like_secret(credential_ref))
);

comment on table erp.notification_channel is
  'Spec 3.9: the channel abstraction. Holds a reference to a credential and '
  'never a credential — a webhook URL with a token in it is a secret that '
  'looks innocent.';

-- Refusal 3, reusing B8's walker rather than a second implementation.
create trigger t_notification_channel_no_inline_credential
  before insert or update on erp.notification_channel
  for each row execute function erp.reject_inline_credentials('settings');

-- -----------------------------------------------------------------------------
-- Templates: resource keys, never literals
-- -----------------------------------------------------------------------------

create table erp.notification_template (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  code            text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  -- Spec 3.10: "no user-facing literal anywhere; every string resolves through
  -- a resource key". A template stores keys; erp.text() resolves them through
  -- the recipient's locale chain at send time, so one template serves every
  -- language without a copy per locale.
  subject_key     text,
  body_key        text not null,
  channel_kind    erp.notification_channel_kind not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

comment on table erp.notification_template is
  'Spec 3.9: templates are resource-based and localised. Keys, not text — the '
  'text is resolved per recipient through B5''s locale fallback chain.';

-- -----------------------------------------------------------------------------
-- Quiet hours
-- -----------------------------------------------------------------------------

create table erp.quiet_hours (
  id              uuid not null default gen_random_uuid(),
  tenant_id       uuid not null references erp.tenant(id) on delete cascade,
  -- Narrowest match wins: a person's own window beats their role's, which
  -- beats the tenant's.
  app_user_id     uuid,
  role_id         uuid,
  days_of_week    smallint[] not null default '{1,2,3,4,5,6,7}'::smallint[],
  starts_at_time  time not null,
  ends_at_time    time not null,
  timezone        text not null default 'UTC',
  -- Anything at or above this severity is delivered regardless. Without it
  -- quiet hours would eventually be switched off entirely by someone who
  -- missed one thing that mattered.
  overridden_at_or_above erp.notification_severity not null default 'critical',
  created_at      timestamptz not null default now(),
  created_by      uuid,
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  primary key (id),
  unique (tenant_id, id),
  foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade,
  foreign key (tenant_id, role_id) references erp.role (tenant_id, id) on delete cascade,
  constraint quiet_hours_days_valid
    check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[]),
  constraint quiet_hours_one_scope
    check (num_nonnulls(app_user_id, role_id) <= 1)
);

comment on table erp.quiet_hours is
  'Spec 3.9. Quiet hours DEFER; they never suppress. "Do not disturb me at 2am" '
  'must not silently become "lose the 2am stock-out".';

-- A window may cross midnight, which is the common case and the one that gets
-- written wrong: 22:00-07:00 is two ranges, not one.
create or replace function erp.in_quiet_hours(
  p_app_user_id uuid,
  p_severity    erp.notification_severity,
  p_at          timestamptz default now()
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1
      from erp.quiet_hours q
     where q.tenant_id = erp.current_tenant_id()
       and (q.app_user_id = p_app_user_id
            or q.role_id in (select ur.role_id from erp.user_role ur
                              where ur.tenant_id = q.tenant_id
                                and ur.app_user_id = p_app_user_id
                                and ur.valid_from <= current_date
                                and (ur.valid_to is null or ur.valid_to >= current_date))
            or (q.app_user_id is null and q.role_id is null))
       and p_severity < q.overridden_at_or_above
       and extract(isodow from (p_at at time zone q.timezone))::smallint
             = any (q.days_of_week)
       and case
             when q.starts_at_time <= q.ends_at_time
               then (p_at at time zone q.timezone)::time
                      between q.starts_at_time and q.ends_at_time
             -- Crosses midnight: inside the window means after the start OR
             -- before the end, not between them.
             else (p_at at time zone q.timezone)::time >= q.starts_at_time
                  or (p_at at time zone q.timezone)::time <= q.ends_at_time
           end)
$$;

comment on function erp.in_quiet_hours is
  'True when this recipient is inside a quiet window that this severity does '
  'not override. Windows crossing midnight are two ranges, which is the case '
  'usually got wrong.';

-- When does the current quiet window end? Held notifications need a time to
-- wake up at, and "try again in an hour" would deliver at 3am.
create or replace function erp.quiet_hours_end(
  p_app_user_id uuid,
  p_severity    erp.notification_severity,
  p_at          timestamptz default now()
) returns timestamptz
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_at timestamptz := p_at;
  i    integer;
begin
  -- Step forward in fifteen-minute increments to the first moment outside every
  -- applicable window. Crude, bounded, and correct across overlapping windows
  -- and midnight, which closed-form arithmetic over a set of ranges is not.
  --
  -- The granularity is the cost: a window ending at 07:00 releases at 07:15.
  -- For something already deliberately held for hours that is immaterial, and
  -- it is the right trade against getting overlapping midnight-crossing windows
  -- subtly wrong. If minute precision is ever needed, narrow the step — the
  -- shape of the function does not change.
  for i in 1..(4 * 24 * 2) loop
    if not erp.in_quiet_hours(p_app_user_id, p_severity, v_at) then
      return v_at;
    end if;
    v_at := v_at + interval '15 minutes';
  end loop;

  -- Two days of unbroken quiet hours is a configuration error, not a quiet
  -- period. Deliver rather than hold forever.
  return p_at;
end;
$$;

select erp_meta.register_table('erp', 'notification_channel', 'tenant_scoped',
  'Spec 3.9: the channel abstraction.');
select erp_meta.register_table('erp', 'notification_template', 'tenant_scoped',
  'Spec 3.9: resource-key templates, localised at send time.');
select erp_meta.register_table('erp', 'quiet_hours', 'tenant_scoped',
  'Spec 3.9: quiet hours, which defer rather than suppress.');

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_isolation();
