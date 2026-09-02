-- =============================================================================
-- Part 19: the services beneath the reports
--
-- §19.2's versions, parameters and reproducible runs landed in 20260904230000,
-- and §19.3's budget defers a run to an extract "rather than failing". What
-- happened to a deferred run afterwards was nothing: erp.report_run recorded
-- deferred_to_extract, and no function ever produced the extract. A budget
-- that defers to something that never comes is a failure with better manners.
--
-- Four things, each the register-and-writer shape the rest of the product has:
--
--   §19.3 EXTRACTS. erp.produce_report_extracts() is a job handler that walks
--   the deferred runs and produces each one through the output subsystem: an
--   output request against the organisation's extract template, a render with
--   the rows as CSV, a checksum, and the parameters and as-at time in the
--   snapshot — so an extract is archived and reproducible exactly as a printed
--   invoice is (§15.1). The extract template is configuration, installed by
--   erp.configure_reporting() through a change set like every module.
--
--   §19.4 SUBSCRIPTIONS. By person or by role, on a cadence, delivered through
--   Part 15 so a scheduled report is archived and traceable like any other
--   output. The subscriber's permission is checked when they subscribe and
--   again when the report is produced: a report is not a way to keep seeing
--   what a screen would now refuse.
--
--   §19.4 PACKS. A pack is a defined artefact with a manifest: which reports,
--   which versions, which parameters, the as-at time of each figure and the
--   checksum of each extract. The manifest is the pack; the extracts are what
--   it points at.
--
--   §19.5 THE ANALYTICS CONTRACT. A governed view exposed to external tools is
--   a versioned contract, deprecated on notice and retired after it, read
--   through one door with a credential that is tenant-scoped, scoped to named
--   views, expiring and separately revocable. Bulk export is the same door
--   read incrementally. Natural-language querying is a client of this door,
--   recorded as a decision rather than implied.
-- =============================================================================

-- ── An extract is an output ──────────────────────────────────────────────────

alter table erp.output_template drop constraint if exists output_template_kind_check;
alter table erp.output_template
  add constraint output_template_kind_check check (kind in ('document', 'label', 'extract'));

-- The archive holds the bytes when they are small enough to hold, which an
-- extract's CSV is; the checksum is over exactly this text.
alter table erp.output_render add column if not exists content text;

comment on column erp.output_render.content is
  'The rendered artefact itself, where it is text the archive can hold: an '
  'extract''s CSV. The checksum is computed over it, so reproducing the render '
  'is comparing two strings.';

create table if not exists erp.report_extract (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references erp.tenant (id) on delete cascade,
  report_run_id      uuid not null references erp.report_run (id) on delete cascade,
  output_request_id  uuid,
  output_render_id   uuid,
  status             text not null default 'waiting',
  row_count          integer,
  failure_reason     text,
  produced_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint report_extract_status_known check (status in ('waiting', 'produced', 'failed')),
  constraint report_extract_failed_has_reason
    check (status <> 'failed' or coalesce(btrim(failure_reason), '') <> ''),
  constraint report_extract_produced_has_render
    check (status <> 'produced' or output_render_id is not null),
  constraint report_extract_one_per_run unique (tenant_id, report_run_id),
  constraint report_extract_tenant_id_key unique (tenant_id, id)
);

comment on table erp.report_extract is
  'Specification v1.2 §19.3: what became of a run the budget deferred. Waiting '
  'until the extract job produces it, produced with the render it points at, '
  'or failed with the reason. One per run.';

-- ── §19.4 subscriptions ──────────────────────────────────────────────────────

create table if not exists erp.report_subscription (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references erp.tenant (id) on delete cascade,
  report_id         uuid not null,
  subscriber_kind   text not null,
  app_user_id       uuid,
  role_id           uuid,
  parameters        jsonb not null default '{}'::jsonb,
  cadence           text not null,
  at_time           time not null default '06:00',
  timezone          text not null default 'UTC',
  destination_kind  text not null default 'email',
  next_due_at       timestamptz not null,
  last_run_at       timestamptz,
  status            text not null default 'active',
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  constraint report_subscription_kind_known check (subscriber_kind in ('person', 'role')),
  constraint report_subscription_subject
    check ((subscriber_kind = 'person' and app_user_id is not null and role_id is null)
        or (subscriber_kind = 'role' and role_id is not null and app_user_id is null)),
  constraint report_subscription_cadence_known check (cadence in ('daily', 'weekly', 'monthly')),
  constraint report_subscription_destination_known check (destination_kind in ('email', 'archive')),
  constraint report_subscription_status_known check (status in ('active', 'paused')),
  constraint report_subscription_tenant_id_key unique (tenant_id, id),
  constraint report_subscription_report_fk
    foreign key (tenant_id, report_id) references erp.report (tenant_id, id) on delete cascade,
  constraint report_subscription_user_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade,
  constraint report_subscription_role_fk
    foreign key (tenant_id, role_id) references erp.role (tenant_id, id) on delete cascade
);

comment on table erp.report_subscription is
  'Specification v1.2 §19.4: a subscription by person or role, on a cadence, '
  'delivered through Part 15. The subscriber''s permission is checked at '
  'subscription and again at every production.';

-- ── §19.4 packs ──────────────────────────────────────────────────────────────

create table if not exists erp.report_pack (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant (id) on delete cascade,
  code         text not null,
  name         text not null,
  description  text,
  status       text not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint report_pack_status_known check (status in ('active', 'inactive')),
  constraint report_pack_unique_code unique (tenant_id, code),
  constraint report_pack_tenant_id_key unique (tenant_id, id)
);

create table if not exists erp.report_pack_item (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references erp.tenant (id) on delete cascade,
  pack_id     uuid not null,
  report_id   uuid not null,
  parameters  jsonb not null default '{}'::jsonb,
  seq         integer not null default 10,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint report_pack_item_once unique (tenant_id, pack_id, report_id),
  constraint report_pack_item_tenant_id_key unique (tenant_id, id),
  constraint report_pack_item_pack_fk
    foreign key (tenant_id, pack_id) references erp.report_pack (tenant_id, id) on delete cascade,
  constraint report_pack_item_report_fk
    foreign key (tenant_id, report_id) references erp.report (tenant_id, id) on delete cascade
);

create table if not exists erp.report_pack_run (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant (id) on delete cascade,
  pack_id      uuid not null,
  as_at        timestamptz not null default now(),
  manifest     jsonb not null,
  run_by       uuid,
  produced_at  timestamptz not null default now(),
  constraint report_pack_run_tenant_id_key unique (tenant_id, id),
  constraint report_pack_run_pack_fk
    foreign key (tenant_id, pack_id) references erp.report_pack (tenant_id, id) on delete cascade
);

comment on table erp.report_pack_run is
  'Specification v1.2 §19.4: "a defined artefact with a manifest of what they '
  'contain and the as-at time of each figure". The manifest names each report, '
  'its version, its parameters, its run, its extract and the checksum of it.';

-- ── §19.5 the contract and its credentials ───────────────────────────────────

create table if not exists erp.analytics_contract (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references erp.tenant (id) on delete cascade,
  governed_view_id    uuid not null,
  version             integer not null,
  exposed_at          timestamptz not null default now(),
  deprecated_at       timestamptz,
  deprecation_notice  text,
  retire_after        date,
  retired_at          timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint analytics_contract_version_positive check (version >= 1),
  constraint analytics_contract_deprecated_on_notice
    check (deprecated_at is null
           or (coalesce(btrim(deprecation_notice), '') <> '' and retire_after is not null)),
  constraint analytics_contract_retired_after_notice
    check (retired_at is null or deprecated_at is not null),
  constraint analytics_contract_once unique (tenant_id, governed_view_id, version),
  constraint analytics_contract_tenant_id_key unique (tenant_id, id),
  constraint analytics_contract_view_fk
    foreign key (tenant_id, governed_view_id) references erp.governed_view (tenant_id, id) on delete cascade
);

comment on table erp.analytics_contract is
  'Specification v1.2 §19.5: a governed view exposed to external tools is a '
  'versioned contract, "deprecated on notice, because an external tool built '
  'against a view becomes a dependency the platform must not break silently". '
  'A deprecation states its notice and the date after which it may be retired.';

create table if not exists erp.analytics_credential (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references erp.tenant (id) on delete cascade,
  app_user_id    uuid not null,
  label          text not null,
  token_digest   text not null unique,
  view_codes     text[],
  expires_at     timestamptz not null,
  revoked_at     timestamptz,
  revoke_reason  text,
  last_used_at   timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  constraint analytics_credential_revoked_has_reason
    check (revoked_at is null or coalesce(btrim(revoke_reason), '') <> ''),
  constraint analytics_credential_tenant_id_key unique (tenant_id, id),
  constraint analytics_credential_principal_fk
    foreign key (tenant_id, app_user_id) references erp.app_user (tenant_id, id) on delete cascade
);

comment on table erp.analytics_credential is
  'Specification v1.2 §19.5: "credentials that are tenant-scoped, '
  'permission-scoped and separately revocable". The token is held as a digest '
  'and shown once; the credential names the views it may read, expires, and is '
  'revoked with a reason.';

-- ── Reading a report's rows, the one way ─────────────────────────────────────

create or replace function erp.report_rows(p_version_id uuid, p_parameters jsonb, p_limit integer default 50000)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_ver     erp.report_version%rowtype;
  v_view    erp.governed_view%rowtype;
  v_where   text := '';
  v_param   record;
  v_value   text;
  v_sql     text;
  v_rows    jsonb;
  v_has_tenant boolean;
begin
  select * into v_ver from erp.report_version rv
   where rv.tenant_id = v_tenant and rv.id = p_version_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT_VERSION: %', p_version_id using errcode = '23503';
  end if;
  select * into v_view from erp.governed_view g
   where g.tenant_id = v_tenant and g.id = v_ver.governed_view_id;

  -- §19.1: scoping is in the view, and a governed view over a product table
  -- carries the organisation's own rows. The filter is belt and braces where
  -- the source has the column; where it does not, the view is the boundary.
  select exists (select 1 from information_schema.columns c
                  where c.table_schema = v_view.source_schema
                    and c.table_name = v_view.source_name
                    and c.column_name = 'tenant_id')
    into v_has_tenant;
  if v_has_tenant then
    v_where := format(' where tenant_id = %L', v_tenant);
  end if;

  -- §19.2: typed parameters that filter a declared column, and nothing else.
  for v_param in
    select * from erp.report_parameter rp
     where rp.tenant_id = v_tenant and rp.report_version_id = p_version_id
       and rp.filters_column is not null
  loop
    v_value := coalesce(p_parameters ->> v_param.code, v_param.default_value);
    if v_value is not null then
      v_where := v_where || case when v_where = '' then ' where ' else ' and ' end
                 || format('%I = %L', v_param.filters_column, v_value);
    end if;
  end loop;

  v_sql := format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from (select %s from %I.%I%s%s limit %s) q',
                  (select string_agg(format('%I', c), ', ') from unnest(v_ver.columns) c),
                  v_view.source_schema, v_view.source_name, v_where,
                  case when coalesce(cardinality(v_ver.default_sort), 0) > 0
                       then ' order by ' || (select string_agg(format('%I', c), ', ')
                                               from unnest(v_ver.default_sort) c)
                       else '' end,
                  greatest(p_limit, 1));
  execute v_sql into v_rows;
  return v_rows;
end;
$$;

comment on function erp.report_rows is
  'Specification v1.2 §19.1 and §19.2: the rows of a report version, read from '
  'its governed view with its declared columns and only the parameters it '
  'declares. The one reader, so an extract, a subscription and a pack cannot '
  'each read differently.';

create or replace function erp.csv_of(p_rows jsonb, p_columns text[])
returns text
language sql
immutable
set search_path = ''
as $$
  select (select string_agg(
            case when c ~ '[",\n]' then '"' || replace(c, '"', '""') || '"' else c end, ',')
            from unnest(p_columns) c)
         || E'\n'
         || coalesce((
            select string_agg(line, E'\n')
              from (
                select (select string_agg(
                          case when v is null then ''
                               when v ~ '[",\n]' then '"' || replace(v, '"', '""') || '"'
                               else v end, ',' order by ord)
                        from unnest(p_columns) with ordinality as u(c, ord)
                        cross join lateral (select r ->> u.c as v) x) as line
                  from jsonb_array_elements(p_rows) r) lines), '')
$$;

-- ── §19.3 producing an extract through the output subsystem ─────────────────

create or replace function erp.produce_report_extract(p_run_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  v_run      erp.report_run%rowtype;
  v_report   erp.report%rowtype;
  v_ver      erp.report_version%rowtype;
  v_template erp.output_template%rowtype;
  v_tver     erp.output_template_version%rowtype;
  v_request  uuid;
  v_render   uuid;
  v_rows     jsonb;
  v_csv      text;
  v_checksum text;
  v_n        integer;
  v_extract  uuid;
begin
  select * into v_run from erp.report_run rr where rr.tenant_id = v_tenant and rr.id = p_run_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT_RUN: %', p_run_id using errcode = '23503';
  end if;
  select * into v_report from erp.report r where r.tenant_id = v_tenant and r.id = v_run.report_id;
  select * into v_ver from erp.report_version rv where rv.tenant_id = v_tenant and rv.id = v_run.report_version_id;

  insert into erp.report_extract (tenant_id, report_run_id, status)
  values (v_tenant, p_run_id, 'waiting')
  on conflict (tenant_id, report_run_id) do nothing;
  select e.id into v_extract from erp.report_extract e
   where e.tenant_id = v_tenant and e.report_run_id = p_run_id;

  -- The extract template is configuration: installed through a change set by
  -- erp.configure_reporting(), promoted like any module. Until it is in force
  -- the run waits and says why, rather than producing something outside the
  -- archive.
  select * into v_template from erp.output_template t
   where t.tenant_id = v_tenant and t.kind = 'extract' and t.status = 'active'
   order by t.code limit 1;
  if found then
    select * into v_tver from erp.output_template_version tv
     where tv.tenant_id = v_tenant and tv.output_template_id = v_template.id
       and tv.status = 'active' and tv.effective_from <= current_date
       and (tv.effective_to is null or tv.effective_to > current_date)
     order by tv.version desc limit 1;
  end if;
  if v_template.id is null or v_tver.id is null then
    update erp.report_extract set status = 'waiting',
           failure_reason = 'no extract template is in force; install Reporting services (erp.configure_reporting) and promote it',
           updated_at = now()
     where id = v_extract;
    return jsonb_build_object('extract_id', v_extract, 'status', 'waiting',
                              'reason', 'no extract template is in force');
  end if;

  begin
    v_rows := erp.report_rows(v_ver.id, coalesce(v_run.parameters, '{}'::jsonb));
    v_n := jsonb_array_length(v_rows);
    v_csv := erp.csv_of(v_rows, v_ver.columns);
    v_checksum := md5(v_csv);

    -- §15.1: an intent, then the artefact, then wherever it goes.
    insert into erp.output_request
      (tenant_id, output_template_id, template_version_id, object_type, object_id,
       destination_kind, locale, copies, triggering_event, requested_by)
    values (v_tenant, v_template.id, v_tver.id, 'report_run', p_run_id,
            'archive_only', 'en', 1, 'report.extract', v_run.run_by)
    returning id into v_request;

    insert into erp.output_render
      (tenant_id, output_request_id, template_version_id, version, format,
       checksum, byte_size, data_snapshot, document_reference, content)
    values (v_tenant, v_request, v_tver.id, v_tver.version, 'csv',
            v_checksum, octet_length(v_csv),
            jsonb_build_object('report', v_report.code, 'report_version', v_ver.version,
                               'parameters', coalesce(v_run.parameters, '{}'::jsonb),
                               'as_at', now(), 'row_count', v_n),
            'RUN-' || p_run_id::text, v_csv)
    returning id into v_render;

    update erp.report_extract
       set status = 'produced', output_request_id = v_request, output_render_id = v_render,
           row_count = v_n, failure_reason = null, produced_at = now(), updated_at = now()
     where id = v_extract;
  exception when others then
    update erp.report_extract
       set status = 'failed', failure_reason = left(sqlerrm, 500), updated_at = now()
     where id = v_extract;
    return jsonb_build_object('extract_id', v_extract, 'status', 'failed',
                              'reason', left(sqlerrm, 500));
  end;

  return jsonb_build_object('extract_id', v_extract, 'status', 'produced',
                            'render_id', v_render, 'row_count', v_n, 'checksum', v_checksum);
end;
$$;

comment on function erp.produce_report_extract is
  'Specification v1.2 §19.3 through §15.1: produces one deferred run as an '
  'extract — an output request against the extract template, a render holding '
  'the CSV with its checksum and the parameters and as-at time in its '
  'snapshot. Waits with a reason when no extract template is in force.';

create or replace function erp.produce_report_extracts()
returns table(run_id uuid, report_code text, status text, detail text)
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); r record; res jsonb;
begin
  for r in
    select rr.id, rp.code
      from erp.report_run rr
      join erp.report rp on rp.tenant_id = rr.tenant_id and rp.id = rr.report_id
     where rr.tenant_id = v_tenant
       and rr.outcome = 'deferred_to_extract'
       and not exists (select 1 from erp.report_extract e
                        where e.tenant_id = v_tenant and e.report_run_id = rr.id
                          and e.status = 'produced')
     order by rr.run_at
     limit 100
  loop
    res := erp.produce_report_extract(r.id);
    run_id := r.id; report_code := r.code;
    status := res ->> 'status'; detail := coalesce(res ->> 'reason', res ->> 'checksum');
    return next;
  end loop;
end;
$$;

comment on function erp.produce_report_extracts is
  'Specification v1.2 §19.3: the scheduled half of "the request becomes a '
  'scheduled extract rather than failing". Walks the deferred runs not yet '
  'produced and produces each through the output subsystem.';

-- ── §19.4 subscriptions ──────────────────────────────────────────────────────

create or replace function erp.next_subscription_due(p_cadence text, p_at_time time, p_timezone text, p_after timestamptz default now())
returns timestamptz
language plpgsql
immutable
set search_path = ''
as $$
declare v_local timestamp; v_candidate timestamp;
begin
  v_local := p_after at time zone p_timezone;
  v_candidate := date_trunc('day', v_local) + p_at_time;
  if v_candidate <= v_local then
    v_candidate := v_candidate + case p_cadence
      when 'daily' then interval '1 day'
      when 'weekly' then interval '7 days'
      else interval '1 month' end;
  end if;
  return v_candidate at time zone p_timezone;
end;
$$;

create or replace function erp.subscribe_to_report(
  p_report_code text,
  p_subscriber_kind text,
  p_app_user_id uuid default null,
  p_role_code text default null,
  p_parameters jsonb default '{}'::jsonb,
  p_cadence text default 'daily',
  p_at_time time default '06:00',
  p_timezone text default 'UTC',
  p_destination_kind text default 'email')
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_report erp.report%rowtype;
  v_ver    erp.report_version%rowtype;
  v_user   uuid := coalesce(p_app_user_id, erp.current_principal_id());
  v_role   uuid;
  v_id     uuid;
begin
  select * into v_report from erp.report r where r.tenant_id = v_tenant and r.code = p_report_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT: %', p_report_code using errcode = '23503';
  end if;
  select * into v_ver from erp.report_version rv
   where rv.tenant_id = v_tenant and rv.report_id = v_report.id and rv.status = 'active'
     and rv.effective_from <= current_date
     and (rv.effective_to is null or rv.effective_to > current_date)
   order by rv.version desc limit 1;
  if not found then
    raise exception 'ERPWARE_REPORT_NOT_IN_FORCE: % has no version in force', p_report_code
      using errcode = '23503';
  end if;

  -- §19.1: a subscription is not a way to keep receiving what a screen would
  -- refuse. Subscribing somebody else, or a role, is defining distribution.
  perform erp.authorise(v_ver.required_permission, null, null, null, 'report', v_report.id);
  if p_subscriber_kind = 'role' or v_user is distinct from erp.current_principal_id() then
    perform erp.authorise('reporting.define', null, null, null, 'report', v_report.id);
  end if;

  if p_subscriber_kind = 'role' then
    select ro.id into v_role from erp.role ro
     where ro.tenant_id = v_tenant and ro.code = p_role_code and ro.status = 'active';
    if v_role is null then
      raise exception 'ERPWARE_UNKNOWN_ROLE: %', p_role_code using errcode = '23503';
    end if;
    v_user := null;
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_timezone) then
    raise exception 'ERPWARE_UNKNOWN_TIMEZONE: %', p_timezone using errcode = '22023';
  end if;

  insert into erp.report_subscription
    (tenant_id, report_id, subscriber_kind, app_user_id, role_id, parameters,
     cadence, at_time, timezone, destination_kind, next_due_at)
  values (v_tenant, v_report.id, p_subscriber_kind, v_user, v_role,
          coalesce(p_parameters, '{}'::jsonb), p_cadence, p_at_time, p_timezone,
          p_destination_kind,
          erp.next_subscription_due(p_cadence, p_at_time, p_timezone))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.set_report_subscription_status(p_subscription_id uuid, p_status text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); s erp.report_subscription%rowtype;
begin
  select * into s from erp.report_subscription rs
   where rs.tenant_id = v_tenant and rs.id = p_subscription_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_SUBSCRIPTION: %', p_subscription_id using errcode = '23503';
  end if;
  if s.subscriber_kind = 'role' or s.app_user_id is distinct from erp.current_principal_id() then
    perform erp.authorise('reporting.define', null, null, null, 'report', s.report_id);
  end if;
  if p_status = 'cancelled' then
    delete from erp.report_subscription where id = s.id;
  else
    update erp.report_subscription set status = p_status, updated_at = now() where id = s.id;
  end if;
end;
$$;

create or replace function erp.distribute_report_subscriptions()
returns table(subscription_id uuid, report_code text, outcome text, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  s        record;
  v_ver    erp.report_version%rowtype;
  v_run    uuid;
  res      jsonb;
  v_render uuid;
  v_recip  record;
  v_sent   integer;
  v_refused text;
begin
  for s in
    select rs.*, rp.code as rcode
      from erp.report_subscription rs
      join erp.report rp on rp.tenant_id = rs.tenant_id and rp.id = rs.report_id
     where rs.tenant_id = v_tenant and rs.status = 'active' and rs.next_due_at <= now()
     order by rs.next_due_at
     limit 100
  loop
    subscription_id := s.id; report_code := s.rcode;

    select * into v_ver from erp.report_version rv
     where rv.tenant_id = v_tenant and rv.report_id = s.report_id and rv.status = 'active'
       and rv.effective_from <= current_date
       and (rv.effective_to is null or rv.effective_to > current_date)
     order by rv.version desc limit 1;
    if not found then
      outcome := 'skipped'; detail := 'no version in force';
      update erp.report_subscription set next_due_at = erp.next_subscription_due(s.cadence, s.at_time, s.timezone), updated_at = now() where id = s.id;
      return next; continue;
    end if;

    -- The run is recorded as the subscriber's, deferred straight to an extract:
    -- a scheduled report is by definition not interactive.
    insert into erp.report_run
      (tenant_id, report_id, report_version_id, version, parameters, run_by,
       outcome, extract_reason)
    values (v_tenant, s.report_id, v_ver.id, v_ver.version, s.parameters, s.app_user_id,
            'deferred_to_extract', 'scheduled distribution')
    returning id into v_run;
    res := erp.produce_report_extract(v_run);
    if res ->> 'status' <> 'produced' then
      outcome := 'not produced'; detail := res ->> 'reason';
      update erp.report_subscription set last_run_at = now(),
             next_due_at = erp.next_subscription_due(s.cadence, s.at_time, s.timezone), updated_at = now()
       where id = s.id;
      return next; continue;
    end if;
    v_render := (res ->> 'render_id')::uuid;

    -- §19.4 through §15: delivered, archived and traceable. Each recipient must
    -- still hold the permission the version requires, today.
    v_sent := 0; v_refused := null;
    if s.destination_kind = 'email' then
      for v_recip in
        select distinct u.id, u.email
          from erp.app_user u
         where u.tenant_id = v_tenant and u.status = 'active' and u.email is not null
           and ((s.subscriber_kind = 'person' and u.id = s.app_user_id)
                or (s.subscriber_kind = 'role' and exists (
                      select 1 from erp.user_role ur
                       where ur.tenant_id = v_tenant and ur.app_user_id = u.id and ur.role_id = s.role_id
                         and ur.valid_from <= current_date
                         and (ur.valid_to is null or ur.valid_to >= current_date))))
           and exists (select 1 from erp.effective_permission ep
                        where ep.tenant_id = v_tenant and ep.app_user_id = u.id
                          and ep.permission_code = v_ver.required_permission
                          and ep.valid_from <= current_date
                          and (ep.valid_to is null or ep.valid_to >= current_date))
      loop
        begin
          perform erp.attempt_delivery(v_render, v_recip.email, 'email');
          v_sent := v_sent + 1;
        exception when others then
          v_refused := coalesce(v_refused || '; ', '') || left(sqlerrm, 120);
        end;
      end loop;
    end if;

    update erp.report_subscription set last_run_at = now(),
           next_due_at = erp.next_subscription_due(s.cadence, s.at_time, s.timezone), updated_at = now()
     where id = s.id;
    outcome := 'produced';
    detail := format('%s recipient(s)%s', v_sent, coalesce('; refused: ' || v_refused, ''));
    return next;
  end loop;
end;
$$;

comment on function erp.distribute_report_subscriptions is
  'Specification v1.2 §19.4: produces each due subscription as an extract and '
  'queues a delivery through Part 15 to every recipient who still holds the '
  'permission the version requires. A suppressed address is refused by the '
  'delivery path and the refusal is in the result.';

-- ── §19.4 packs ──────────────────────────────────────────────────────────────

create or replace function erp.upsert_report_pack(p_code text, p_name text, p_description text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_id uuid;
begin
  perform erp.authorise('reporting.define', null, null, null, 'report_pack', null);
  insert into erp.report_pack (tenant_id, code, name, description)
  values (v_tenant, p_code, p_name, p_description)
  on conflict (tenant_id, code) do update set
    name = excluded.name, description = excluded.description, status = 'active', updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.add_report_pack_item(p_pack_code text, p_report_code text, p_parameters jsonb default '{}'::jsonb, p_seq integer default 10)
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_pack uuid; v_report uuid; v_id uuid;
begin
  select id into v_pack from erp.report_pack where tenant_id = v_tenant and code = p_pack_code;
  if v_pack is null then
    raise exception 'ERPWARE_UNKNOWN_REPORT_PACK: %', p_pack_code using errcode = '23503';
  end if;
  perform erp.authorise('reporting.define', null, null, null, 'report_pack', v_pack);
  select id into v_report from erp.report where tenant_id = v_tenant and code = p_report_code;
  if v_report is null then
    raise exception 'ERPWARE_UNKNOWN_REPORT: %', p_report_code using errcode = '23503';
  end if;
  insert into erp.report_pack_item (tenant_id, pack_id, report_id, parameters, seq)
  values (v_tenant, v_pack, v_report, coalesce(p_parameters, '{}'::jsonb), p_seq)
  on conflict (tenant_id, pack_id, report_id) do update set
    parameters = excluded.parameters, seq = excluded.seq, updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function erp.remove_report_pack_item(p_pack_code text, p_report_code text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_pack uuid;
begin
  select id into v_pack from erp.report_pack where tenant_id = v_tenant and code = p_pack_code;
  if v_pack is null then
    raise exception 'ERPWARE_UNKNOWN_REPORT_PACK: %', p_pack_code using errcode = '23503';
  end if;
  perform erp.authorise('reporting.define', null, null, null, 'report_pack', v_pack);
  delete from erp.report_pack_item i
   where i.tenant_id = v_tenant and i.pack_id = v_pack
     and i.report_id = (select r.id from erp.report r where r.tenant_id = v_tenant and r.code = p_report_code);
end;
$$;

create or replace function erp.assemble_report_pack(p_pack_code text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_pack   erp.report_pack%rowtype;
  it       record;
  res      jsonb; ext jsonb;
  v_items  jsonb := '[]'::jsonb;
  v_run    uuid;
  v_id     uuid;
  v_as_at  timestamptz := now();
begin
  select * into v_pack from erp.report_pack p where p.tenant_id = v_tenant and p.code = p_pack_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT_PACK: %', p_pack_code using errcode = '23503';
  end if;
  perform erp.authorise('reporting.export', null, null, null, 'report_pack', v_pack.id);
  if not exists (select 1 from erp.report_pack_item i where i.tenant_id = v_tenant and i.pack_id = v_pack.id) then
    raise exception 'ERPWARE_REPORT_PACK_EMPTY: % contains no reports', p_pack_code
      using errcode = '23514';
  end if;

  for it in
    select i.parameters, i.seq, r.code as report_code
      from erp.report_pack_item i
      join erp.report r on r.tenant_id = i.tenant_id and r.id = i.report_id
     where i.tenant_id = v_tenant and i.pack_id = v_pack.id
     order by i.seq, r.code
  loop
    -- Each figure is a run of its own, authorised as the assembler, and its
    -- extract is what the manifest points at. Every run in a pack is an
    -- extract by definition: a pack is read, not scrolled.
    res := erp.run_report(it.report_code, it.parameters, null, null);
    v_run := (res ->> 'run_id')::uuid;
    ext := erp.produce_report_extract(v_run);
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'seq', it.seq, 'report', it.report_code, 'version', (res ->> 'version')::integer,
      'parameters', it.parameters, 'run_id', v_run, 'as_at', now(),
      'extract_status', ext ->> 'status', 'render_id', ext ->> 'render_id',
      'row_count', ext ->> 'row_count', 'checksum', ext ->> 'checksum',
      'reason', ext ->> 'reason'));
  end loop;

  insert into erp.report_pack_run (tenant_id, pack_id, as_at, manifest, run_by)
  values (v_tenant, v_pack.id, v_as_at,
          jsonb_build_object('pack', v_pack.code, 'name', v_pack.name, 'as_at', v_as_at,
                             'assembled_by', erp.current_principal_id(), 'items', v_items),
          erp.current_principal_id())
  returning id into v_id;
  return jsonb_build_object('pack_run_id', v_id, 'as_at', v_as_at, 'items', v_items);
end;
$$;

comment on function erp.assemble_report_pack is
  'Specification v1.2 §19.4: assembles a pack. One run per item, authorised as '
  'the assembler, each produced as an extract, and a manifest naming every '
  'report, version, parameter set, run, extract and checksum with the as-at '
  'time of each figure.';

-- ── §19.5 the contract ───────────────────────────────────────────────────────

create or replace function erp.expose_governed_view(p_view_code text)
returns integer
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_view erp.governed_view%rowtype; v_version integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'governed_view', null);
  select * into v_view from erp.governed_view g where g.tenant_id = v_tenant and g.code = p_view_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_GOVERNED_VIEW: %', p_view_code using errcode = '23503';
  end if;
  if exists (select 1 from erp.analytics_contract c
              where c.tenant_id = v_tenant and c.governed_view_id = v_view.id and c.retired_at is null) then
    select max(c.version) into v_version from erp.analytics_contract c
     where c.tenant_id = v_tenant and c.governed_view_id = v_view.id;
    return v_version;
  end if;
  select coalesce(max(c.version), 0) + 1 into v_version from erp.analytics_contract c
   where c.tenant_id = v_tenant and c.governed_view_id = v_view.id;
  insert into erp.analytics_contract (tenant_id, governed_view_id, version)
  values (v_tenant, v_view.id, v_version);
  update erp.governed_view set is_analytics_exposed = true, updated_at = now() where id = v_view.id;
  return v_version;
end;
$$;

create or replace function erp.revise_analytics_contract(p_view_code text, p_deprecation_notice text, p_retire_after date)
returns integer
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_view erp.governed_view%rowtype; v_version integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'governed_view', null);
  select * into v_view from erp.governed_view g where g.tenant_id = v_tenant and g.code = p_view_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_GOVERNED_VIEW: %', p_view_code using errcode = '23503';
  end if;
  if coalesce(btrim(p_deprecation_notice), '') = '' or p_retire_after is null or p_retire_after <= current_date then
    raise exception
      'ERPWARE_DEPRECATION_WITHOUT_NOTICE: a contract is deprecated on notice, with a retirement date in the future'
      using errcode = '23514';
  end if;
  update erp.analytics_contract c
     set deprecated_at = now(), deprecation_notice = btrim(p_deprecation_notice),
         retire_after = p_retire_after, updated_at = now()
   where c.tenant_id = v_tenant and c.governed_view_id = v_view.id
     and c.retired_at is null and c.deprecated_at is null;
  select coalesce(max(c.version), 0) + 1 into v_version from erp.analytics_contract c
   where c.tenant_id = v_tenant and c.governed_view_id = v_view.id;
  insert into erp.analytics_contract (tenant_id, governed_view_id, version)
  values (v_tenant, v_view.id, v_version);
  update erp.governed_view set is_analytics_exposed = true, updated_at = now() where id = v_view.id;
  return v_version;
end;
$$;

create or replace function erp.retire_analytics_contract(p_view_code text, p_version integer)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); c erp.analytics_contract%rowtype;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'governed_view', null);
  select ac.* into c from erp.analytics_contract ac
    join erp.governed_view g on g.tenant_id = ac.tenant_id and g.id = ac.governed_view_id
   where ac.tenant_id = v_tenant and g.code = p_view_code and ac.version = p_version;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_CONTRACT: % version %', p_view_code, p_version using errcode = '23503';
  end if;
  if c.deprecated_at is null or c.retire_after > current_date then
    raise exception
      'ERPWARE_RETIRED_BEFORE_NOTICE: version % of % may be retired after %, not before',
      p_version, p_view_code, coalesce(c.retire_after::text, 'a deprecation with notice')
      using errcode = '23514';
  end if;
  update erp.analytics_contract set retired_at = now(), updated_at = now() where id = c.id;
  if not exists (select 1 from erp.analytics_contract ac
                  where ac.tenant_id = v_tenant and ac.governed_view_id = c.governed_view_id and ac.retired_at is null) then
    update erp.governed_view set is_analytics_exposed = false, updated_at = now() where id = c.governed_view_id;
  end if;
end;
$$;

create or replace function erp.issue_analytics_credential(p_label text, p_view_codes text[] default null, p_expires_at timestamptz default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_principal uuid;
  v_token text;
  v_id uuid;
  v_code text;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'analytics_credential', null);
  if coalesce(btrim(p_label), '') = '' then
    raise exception 'ERPWARE_CREDENTIAL_NEEDS_A_LABEL: a credential is named for the tool that holds it'
      using errcode = '23514';
  end if;
  -- Permission-scoped: a credential may only name views that are exposed.
  if p_view_codes is not null then
    foreach v_code in array p_view_codes loop
      if not exists (select 1 from erp.governed_view g
                      where g.tenant_id = v_tenant and g.code = v_code and g.is_analytics_exposed) then
        raise exception 'ERPWARE_VIEW_NOT_EXPOSED: % is not on the analytics contract', v_code
          using errcode = '23503', hint = 'Expose the view first; a credential cannot widen the contract.';
      end if;
    end loop;
  end if;
  v_principal := erp.create_service_principal('Analytics: ' || btrim(p_label));
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into erp.analytics_credential
    (tenant_id, app_user_id, label, token_digest, view_codes, expires_at)
  values (v_tenant, v_principal, btrim(p_label),
          encode(extensions.digest(v_token, 'sha256'), 'hex'),
          p_view_codes, coalesce(p_expires_at, now() + interval '365 days'))
  returning id into v_id;
  -- The token is shown once. What the table holds cannot be turned back into it.
  return jsonb_build_object('credential_id', v_id, 'token', v_token,
                            'expires_at', coalesce(p_expires_at, now() + interval '365 days'));
end;
$$;

create or replace function erp.revoke_analytics_credential(p_credential_id uuid, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id(); v_n integer;
begin
  perform erp.authorise('administration.integrate', null, null, null, 'analytics_credential', p_credential_id);
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'ERPWARE_REVOCATION_HAS_NO_REASON' using errcode = '23514';
  end if;
  update erp.analytics_credential
     set revoked_at = coalesce(revoked_at, now()), revoke_reason = btrim(p_reason), updated_at = now()
   where tenant_id = v_tenant and id = p_credential_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'ERPWARE_UNKNOWN_CREDENTIAL: %', p_credential_id using errcode = '23503';
  end if;
end;
$$;

create or replace function erp.analytics_read(p_token text, p_view_code text, p_since timestamptz default null, p_limit integer default 1000)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cred   erp.analytics_credential%rowtype;
  v_view   erp.governed_view%rowtype;
  v_ctr    erp.analytics_contract%rowtype;
  v_ts     text;
  v_sql    text;
  v_rows   jsonb;
  v_next   timestamptz;
begin
  select * into v_cred from erp.analytics_credential c
   where c.token_digest = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found or v_cred.revoked_at is not null or v_cred.expires_at <= now() then
    raise exception 'ERPWARE_ANALYTICS_CREDENTIAL_REFUSED: the credential is unknown, revoked or expired'
      using errcode = '42501';
  end if;
  if not exists (select 1 from erp.app_user u where u.id = v_cred.app_user_id and u.status = 'active') then
    raise exception 'ERPWARE_ANALYTICS_CREDENTIAL_REFUSED: the credential''s principal is not active'
      using errcode = '42501';
  end if;
  if v_cred.view_codes is not null and not (p_view_code = any (v_cred.view_codes)) then
    raise exception 'ERPWARE_ANALYTICS_OUT_OF_SCOPE: this credential does not read %', p_view_code
      using errcode = '42501';
  end if;

  select * into v_view from erp.governed_view g
   where g.tenant_id = v_cred.tenant_id and g.code = p_view_code;
  if not found or not v_view.is_analytics_exposed then
    raise exception 'ERPWARE_VIEW_NOT_EXPOSED: % is not on the analytics contract', p_view_code
      using errcode = '42501';
  end if;
  select * into v_ctr from erp.analytics_contract c
   where c.tenant_id = v_cred.tenant_id and c.governed_view_id = v_view.id and c.retired_at is null
   order by c.version desc limit 1;

  -- §19.5's incremental extract: the source's own change column, where it has
  -- one. A view with none is read whole, and says so.
  select c.column_name into v_ts
    from information_schema.columns c
   where c.table_schema = v_view.source_schema and c.table_name = v_view.source_name
     and c.column_name in ('updated_at', 'recorded_at', 'occurred_at', 'created_at')
   order by array_position(array['updated_at', 'recorded_at', 'occurred_at', 'created_at'], c.column_name::text)
   limit 1;

  v_sql := format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb), max(q.%s) from (select * from %I.%I where tenant_id = %L%s order by %s limit %s) q',
                  coalesce(quote_ident(v_ts), 'null::timestamptz'),
                  v_view.source_schema, v_view.source_name, v_cred.tenant_id,
                  case when v_ts is not null and p_since is not null
                       then format(' and %I > %L', v_ts, p_since) else '' end,
                  coalesce(quote_ident(v_ts), '1'),
                  least(greatest(coalesce(p_limit, 1000), 1), 10000));
  execute v_sql into v_rows, v_next;

  update erp.analytics_credential set last_used_at = now() where id = v_cred.id;

  return jsonb_build_object(
    'view', p_view_code, 'contract_version', v_ctr.version,
    'deprecated', v_ctr.deprecated_at is not null,
    'deprecation_notice', v_ctr.deprecation_notice, 'retire_after', v_ctr.retire_after,
    'incremental_on', v_ts, 'next_since', v_next,
    'row_count', jsonb_array_length(v_rows), 'rows', v_rows);
end;
$$;

comment on function erp.analytics_read is
  'Specification v1.2 §19.5: the read-only analytics contract. A credential '
  'names the organisation and the views it may read; the view must be exposed '
  'on an unretired contract; the response carries the contract version and any '
  'deprecation notice, and reads incrementally on the source''s own change '
  'column. Security definer because the credential, not a session, is the '
  'identity; every read is scoped to the credential''s organisation.';

-- ── The installer: reporting services as a change set ────────────────────────

create or replace function erp.configure_reporting()
returns uuid
language plpgsql
set search_path = ''
as $$
declare v_cs uuid;
begin
  v_cs := erp.install_module_config(
    'reporting-services', 'Reporting services',
    'The extract template a deferred run is produced through, and the two jobs that produce extracts and distribute subscriptions.',
    jsonb_build_array(
      jsonb_build_object('kind', 'output_template', 'key', 'report_extract', 'payload',
        jsonb_build_object(
          'code', 'report_extract', 'name_key', 'output.template.report_extract',
          'kind', 'extract', 'page', 'A4', 'blocks', '[]'::jsonb,
          'version', jsonb_build_object(
            'rendering_engine', 'text', 'page', '{}'::jsonb, 'blocks', '[]'::jsonb,
            'required_permission', 'reporting.export'))),
      jsonb_build_object('kind', 'job', 'key', 'produce_report_extracts', 'payload',
        jsonb_build_object(
          'code', 'produce_report_extracts', 'name', 'Produce report extracts',
          'handler_code', 'reporting.produce_extracts', 'schedule_kind', 'interval',
          'interval_seconds', 900, 'timeout_seconds', 600, 'is_enabled', true)),
      jsonb_build_object('kind', 'job', 'key', 'distribute_report_subscriptions', 'payload',
        jsonb_build_object(
          'code', 'distribute_report_subscriptions', 'name', 'Distribute report subscriptions',
          'handler_code', 'reporting.distribute_subscriptions', 'schedule_kind', 'interval',
          'interval_seconds', 900, 'timeout_seconds', 600, 'is_enabled', true))));
  return v_cs;
end;
$$;

comment on function erp.configure_reporting is
  'Specification v1.2 §19.3 and §19.4: installs reporting services through a '
  'change set — the extract template and the two scheduled jobs. Enabled on '
  'install, unlike a pack''s jobs, because installing this module is asking '
  'for exactly this work.';

insert into erp_ref.job_handler
  (code, name_key, description, module_code, parameter_schema,
   default_timeout_seconds, forbids_overlap, is_current, sql_function)
values
  ('reporting.produce_extracts', 'job_handler.produce_extracts.name',
   'Produces every run the interactive budget deferred as an extract through the output subsystem: rows as CSV, checksum, parameters and as-at time in the archive. §19.3.',
   'reporting', '{"type": "object", "additionalProperties": false}'::jsonb, 600, true, true,
   'produce_report_extracts'),
  ('reporting.distribute_subscriptions', 'job_handler.distribute_subscriptions.name',
   'Produces each due subscription as an extract and queues its delivery through Part 15 to every recipient who still holds the permission. §19.4.',
   'reporting', '{"type": "object", "additionalProperties": false}'::jsonb, 600, true, true,
   'distribute_report_subscriptions')
on conflict (code) do update set
  description = excluded.description, sql_function = excluded.sql_function,
  is_current = excluded.is_current, module_code = excluded.module_code;

-- ── What the screens read ────────────────────────────────────────────────────

create or replace function erp.reporting_services_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  -- §19.3: a run deferred to an extract that nothing will produce.
  select 'a deferred run has waited more than a day and nothing is scheduled to produce it',
         rr.id::text,
         format('%s deferred %s; %s', rp.code, rr.run_at,
                coalesce((select e.failure_reason from erp.report_extract e
                           where e.tenant_id = rr.tenant_id and e.report_run_id = rr.id),
                         'no extract job is enabled'))
    from erp.report_run rr
    join erp.report rp on rp.tenant_id = rr.tenant_id and rp.id = rr.report_id
   where rr.outcome = 'deferred_to_extract'
     and rr.run_at < now() - interval '1 day'
     and not exists (select 1 from erp.report_extract e
                      where e.tenant_id = rr.tenant_id and e.report_run_id = rr.id and e.status = 'produced')
     and (not exists (select 1 from erp.job j
                       where j.tenant_id = rr.tenant_id and j.handler_code = 'reporting.produce_extracts' and j.is_enabled)
          or exists (select 1 from erp.report_extract e
                      where e.tenant_id = rr.tenant_id and e.report_run_id = rr.id and e.status <> 'produced'))
  union all
  -- §19.5: exposed with no contract, or a contract on a view no longer exposed.
  select 'a governed view is exposed with no contract version in force', g.code, g.name
    from erp.governed_view g
   where g.is_analytics_exposed
     and not exists (select 1 from erp.analytics_contract c
                      where c.tenant_id = g.tenant_id and c.governed_view_id = g.id and c.retired_at is null)
  union all
  select 'a credential names a view that is not on the contract', c.label, v
    from erp.analytics_credential c
    cross join lateral unnest(c.view_codes) v
   where c.revoked_at is null
     and not exists (select 1 from erp.governed_view g
                      where g.tenant_id = c.tenant_id and g.code = v and g.is_analytics_exposed)
  union all
  -- §19.4: a subscription whose subscriber no longer holds the permission.
  select 'a subscription''s subscriber no longer holds the permission the report requires',
         s.id::text, rp.code
    from erp.report_subscription s
    join erp.report rp on rp.tenant_id = s.tenant_id and rp.id = s.report_id
    join erp.report_version rv on rv.tenant_id = s.tenant_id and rv.report_id = rp.id and rv.status = 'active'
   where s.subscriber_kind = 'person' and s.status = 'active'
     and not exists (select 1 from erp.effective_permission ep
                      where ep.tenant_id = s.tenant_id and ep.app_user_id = s.app_user_id
                        and ep.permission_code = rv.required_permission
                        and ep.valid_from <= current_date
                        and (ep.valid_to is null or ep.valid_to >= current_date))
  union all
  -- A contract past its retirement date, still serving: a notice nobody acted on.
  select 'a deprecated contract is past its retirement date and still in force',
         g.code || ' v' || c.version::text, format('retire after %s', c.retire_after)
    from erp.analytics_contract c
    join erp.governed_view g on g.tenant_id = c.tenant_id and g.id = c.governed_view_id
   where c.deprecated_at is not null and c.retired_at is null and c.retire_after < current_date - 30
  order by 1, 2
$$;

create or replace function erp.assert_reporting_services()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text; v_handlers integer;
begin
  select count(*), string_agg(format('  %s — %s: %s', finding, reference, detail), E'\n')
    into v_count, v_detail
    from erp.reporting_services_report();
  if v_count > 0 then
    raise exception 'ERPWARE_REPORTING_SERVICES: % finding(s)', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = '§19.3 defers rather than fails, §19.4 delivers to those still permitted, §19.5 deprecates on notice.';
  end if;
  select count(*) into v_handlers from erp_ref.job_handler h
   where h.code in ('reporting.produce_extracts', 'reporting.distribute_subscriptions')
     and h.sql_function is not null;
  if v_handlers < 2 then
    raise exception 'ERPWARE_REPORTING_SERVICES: the extract and distribution handlers are not both registered'
      using errcode = 'P0001';
  end if;
  return 'reporting services: extracts produced, subscriptions permitted, contracts on notice';
end;
$$;

-- ── The doors ────────────────────────────────────────────────────────────────

create or replace function public.erp_configure_reporting()
returns uuid language sql set search_path = '' as $$ select erp.configure_reporting(); $$;

create or replace function public.erp_subscribe_to_report(
  p_report_code text, p_subscriber_kind text default 'person', p_app_user_id uuid default null,
  p_role_code text default null, p_parameters jsonb default '{}'::jsonb, p_cadence text default 'daily',
  p_at_time time default '06:00', p_timezone text default 'UTC', p_destination_kind text default 'email')
returns uuid language sql set search_path = '' as $$
  select erp.subscribe_to_report(p_report_code, p_subscriber_kind, p_app_user_id, p_role_code,
                                 p_parameters, p_cadence, p_at_time, p_timezone, p_destination_kind);
$$;

create or replace function public.erp_set_report_subscription_status(p_subscription_id uuid, p_status text)
returns void language sql set search_path = '' as $$
  select erp.set_report_subscription_status(p_subscription_id, p_status);
$$;

create or replace function public.erp_report_subscriptions()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'report_code', rp.code, 'report_name', rp.name,
           'subscriber_kind', s.subscriber_kind,
           'subscriber', coalesce(u.display_name, ro.name),
           'parameters', s.parameters, 'cadence', s.cadence, 'at_time', s.at_time,
           'timezone', s.timezone, 'destination_kind', s.destination_kind,
           'next_due_at', s.next_due_at, 'last_run_at', s.last_run_at, 'status', s.status)
         order by s.next_due_at), '[]'::jsonb)
    from erp.report_subscription s
    join erp.report rp on rp.tenant_id = s.tenant_id and rp.id = s.report_id
    left join erp.app_user u on u.tenant_id = s.tenant_id and u.id = s.app_user_id
    left join erp.role ro on ro.tenant_id = s.tenant_id and ro.id = s.role_id
   where s.tenant_id = erp.require_tenant_id();
$$;

create or replace function public.erp_upsert_report_pack(p_code text, p_name text, p_description text default null)
returns uuid language sql set search_path = '' as $$ select erp.upsert_report_pack(p_code, p_name, p_description); $$;

create or replace function public.erp_add_report_pack_item(p_pack_code text, p_report_code text, p_parameters jsonb default '{}'::jsonb, p_seq integer default 10)
returns uuid language sql set search_path = '' as $$ select erp.add_report_pack_item(p_pack_code, p_report_code, p_parameters, p_seq); $$;

create or replace function public.erp_remove_report_pack_item(p_pack_code text, p_report_code text)
returns void language sql set search_path = '' as $$ select erp.remove_report_pack_item(p_pack_code, p_report_code); $$;

create or replace function public.erp_assemble_report_pack(p_pack_code text)
returns jsonb language sql set search_path = '' as $$ select erp.assemble_report_pack(p_pack_code); $$;

create or replace function public.erp_report_packs()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', p.code, 'name', p.name, 'description', p.description, 'status', p.status,
           'items', coalesce((select jsonb_agg(jsonb_build_object('report_code', r.code, 'report_name', r.name,
                                                                  'parameters', i.parameters, 'seq', i.seq)
                                               order by i.seq, r.code)
                                from erp.report_pack_item i
                                join erp.report r on r.tenant_id = i.tenant_id and r.id = i.report_id
                               where i.tenant_id = p.tenant_id and i.pack_id = p.id), '[]'::jsonb),
           'runs', coalesce((select jsonb_agg(jsonb_build_object('id', pr.id, 'as_at', pr.as_at,
                                                                 'run_by', u.display_name, 'manifest', pr.manifest)
                                              order by pr.as_at desc)
                               from (select * from erp.report_pack_run x
                                      where x.tenant_id = p.tenant_id and x.pack_id = p.id
                                      order by x.as_at desc limit 10) pr
                               left join erp.app_user u on u.tenant_id = pr.tenant_id and u.id = pr.run_by), '[]'::jsonb))
         order by p.code), '[]'::jsonb)
    from erp.report_pack p
   where p.tenant_id = erp.require_tenant_id();
$$;

create or replace function public.erp_report_extracts()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'run_id', rr.id, 'report_code', rp.code, 'report_name', rp.name, 'version', rr.version,
           'parameters', rr.parameters, 'run_at', rr.run_at, 'run_by', u.display_name,
           'extract_reason', rr.extract_reason,
           'status', coalesce(e.status, 'waiting'), 'row_count', e.row_count,
           'failure_reason', coalesce(e.failure_reason,
             case when e.id is null then 'not yet produced; the extract job runs every fifteen minutes when reporting services are installed' end),
           'produced_at', e.produced_at, 'render_id', e.output_render_id,
           'checksum', o.checksum, 'byte_size', o.byte_size,
           'job_enabled', exists (select 1 from erp.job j where j.tenant_id = rr.tenant_id
                                   and j.handler_code = 'reporting.produce_extracts' and j.is_enabled))
         order by rr.run_at desc), '[]'::jsonb)
    from (select * from erp.report_run x where x.tenant_id = erp.require_tenant_id()
           and x.outcome = 'deferred_to_extract' order by x.run_at desc limit 200) rr
    join erp.report rp on rp.tenant_id = rr.tenant_id and rp.id = rr.report_id
    left join erp.app_user u on u.tenant_id = rr.tenant_id and u.id = rr.run_by
    left join erp.report_extract e on e.tenant_id = rr.tenant_id and e.report_run_id = rr.id
    left join erp.output_render o on o.tenant_id = rr.tenant_id and o.id = e.output_render_id;
$$;

create or replace function public.erp_report_extract_content(p_run_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare v_tenant uuid := erp.require_tenant_id(); v_ver erp.report_version%rowtype; r record;
begin
  select rv.* into v_ver from erp.report_run rr
    join erp.report_version rv on rv.tenant_id = rr.tenant_id and rv.id = rr.report_version_id
   where rr.tenant_id = v_tenant and rr.id = p_run_id;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_REPORT_RUN: %', p_run_id using errcode = '23503';
  end if;
  perform erp.authorise('reporting.export', null, null, null, 'report', v_ver.report_id);
  select o.content, o.checksum, o.byte_size, o.data_snapshot, o.rendered_at into r
    from erp.report_extract e
    join erp.output_render o on o.tenant_id = e.tenant_id and o.id = e.output_render_id
   where e.tenant_id = v_tenant and e.report_run_id = p_run_id and e.status = 'produced';
  if not found then
    return jsonb_build_object('produced', false);
  end if;
  return jsonb_build_object('produced', true, 'content', r.content, 'checksum', r.checksum,
                            'byte_size', r.byte_size, 'snapshot', r.data_snapshot, 'rendered_at', r.rendered_at);
end;
$$;

create or replace function public.erp_expose_governed_view(p_view_code text)
returns integer language sql set search_path = '' as $$ select erp.expose_governed_view(p_view_code); $$;

create or replace function public.erp_revise_analytics_contract(p_view_code text, p_deprecation_notice text, p_retire_after date)
returns integer language sql set search_path = '' as $$ select erp.revise_analytics_contract(p_view_code, p_deprecation_notice, p_retire_after); $$;

create or replace function public.erp_retire_analytics_contract(p_view_code text, p_version integer)
returns void language sql set search_path = '' as $$ select erp.retire_analytics_contract(p_view_code, p_version); $$;

create or replace function public.erp_issue_analytics_credential(p_label text, p_view_codes text[] default null, p_expires_at timestamptz default null)
returns jsonb language sql set search_path = '' as $$ select erp.issue_analytics_credential(p_label, p_view_codes, p_expires_at); $$;

create or replace function public.erp_revoke_analytics_credential(p_credential_id uuid, p_reason text)
returns void language sql set search_path = '' as $$ select erp.revoke_analytics_credential(p_credential_id, p_reason); $$;

create or replace function public.erp_analytics_read(p_token text, p_view_code text, p_since timestamptz default null, p_limit integer default 1000)
returns jsonb language sql set search_path = '' as $$ select erp.analytics_read(p_token, p_view_code, p_since, p_limit); $$;

create or replace function public.erp_analytics_contract()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'views', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', g.code, 'name', g.name, 'module_code', g.module_code,
               'source', g.source_schema || '.' || g.source_name,
               'required_permission', g.required_permission,
               'is_exposed', g.is_analytics_exposed,
               'contracts', coalesce((select jsonb_agg(jsonb_build_object(
                                        'version', c.version, 'exposed_at', c.exposed_at,
                                        'deprecated_at', c.deprecated_at, 'deprecation_notice', c.deprecation_notice,
                                        'retire_after', c.retire_after, 'retired_at', c.retired_at)
                                      order by c.version desc)
                                 from erp.analytics_contract c
                                where c.tenant_id = g.tenant_id and c.governed_view_id = g.id), '[]'::jsonb))
             order by g.is_analytics_exposed desc, g.code)
        from erp.governed_view g where g.tenant_id = erp.require_tenant_id()), '[]'::jsonb),
    'credentials', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'label', c.label, 'view_codes', c.view_codes,
               'expires_at', c.expires_at, 'revoked_at', c.revoked_at, 'revoke_reason', c.revoke_reason,
               'last_used_at', c.last_used_at, 'created_at', c.created_at)
             order by c.created_at desc)
        from erp.analytics_credential c where c.tenant_id = erp.require_tenant_id()), '[]'::jsonb),
    'services_installed', exists (
      select 1 from erp.output_template t
       where t.tenant_id = erp.require_tenant_id() and t.kind = 'extract' and t.status = 'active'),
    'findings', coalesce((
      select jsonb_agg(jsonb_build_object('finding', f.finding, 'reference', f.reference, 'detail', f.detail))
        from erp.reporting_services_report() f), '[]'::jsonb));
$$;

revoke all on function
  public.erp_configure_reporting(),
  public.erp_subscribe_to_report(text, text, uuid, text, jsonb, text, time, text, text),
  public.erp_set_report_subscription_status(uuid, text),
  public.erp_report_subscriptions(),
  public.erp_upsert_report_pack(text, text, text),
  public.erp_add_report_pack_item(text, text, jsonb, integer),
  public.erp_remove_report_pack_item(text, text),
  public.erp_assemble_report_pack(text),
  public.erp_report_packs(),
  public.erp_report_extracts(),
  public.erp_report_extract_content(uuid),
  public.erp_expose_governed_view(text),
  public.erp_revise_analytics_contract(text, text, date),
  public.erp_retire_analytics_contract(text, integer),
  public.erp_issue_analytics_credential(text, text[], timestamptz),
  public.erp_revoke_analytics_credential(uuid, text),
  public.erp_analytics_read(text, text, timestamptz, integer),
  public.erp_analytics_contract()
  from public, anon;

grant execute on function
  public.erp_configure_reporting(),
  public.erp_subscribe_to_report(text, text, uuid, text, jsonb, text, time, text, text),
  public.erp_set_report_subscription_status(uuid, text),
  public.erp_report_subscriptions(),
  public.erp_upsert_report_pack(text, text, text),
  public.erp_add_report_pack_item(text, text, jsonb, integer),
  public.erp_remove_report_pack_item(text, text),
  public.erp_assemble_report_pack(text),
  public.erp_report_packs(),
  public.erp_report_extracts(),
  public.erp_report_extract_content(uuid),
  public.erp_expose_governed_view(text),
  public.erp_revise_analytics_contract(text, text, date),
  public.erp_retire_analytics_contract(text, integer),
  public.erp_issue_analytics_credential(text, text[], timestamptz),
  public.erp_revoke_analytics_credential(uuid, text),
  public.erp_analytics_read(text, text, timestamptz, integer),
  public.erp_analytics_contract()
  to authenticated, service_role;

-- ── Registration ─────────────────────────────────────────────────────────────

insert into erp_meta.table_policy (schema_name, table_name, table_class, note) values
  ('erp','report_extract','tenant_scoped',
   'Part 19 §19.3. What became of a deferred run: waiting, produced with its render, or failed with the reason.'),
  ('erp','report_subscription','tenant_scoped',
   'Part 19 §19.4. A subscription by person or role; its next due time moves, so it is not append-only.'),
  ('erp','report_pack','tenant_scoped', 'Part 19 §19.4. A defined pack.'),
  ('erp','report_pack_item','tenant_scoped', 'Part 19 §19.4. The reports in a pack, with their parameters.'),
  ('erp','report_pack_run','tenant_scoped_append_only',
   'Part 19 §19.4. The manifest of an assembled pack: what it contained and the as-at time of each figure. An artefact, so append-only.'),
  ('erp','analytics_contract','tenant_scoped',
   'Part 19 §19.5. A governed view exposed as a versioned contract, deprecated on notice.'),
  ('erp','analytics_credential','tenant_scoped',
   'Part 19 §19.5. A credential held as a digest, scoped to views, expiring and revocable.')
on conflict (schema_name, table_name) do nothing;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_configure_reporting', 'erp.configure_reporting',
   'Installs reporting services through a change set, gated by administration.configure inside erp.install_module_config like every module installer.'),
  ('erp_subscribe_to_report', 'erp.subscribe_to_report',
   'Subscribes a person or a role to a report. Gated by the version''s own required permission, and by reporting.define for anybody other than oneself.'),
  ('erp_set_report_subscription_status', 'erp.set_report_subscription_status',
   'Pauses, resumes or cancels a subscription; one''s own freely, anybody else''s under reporting.define.'),
  ('erp_upsert_report_pack', 'erp.upsert_report_pack', 'Defines a pack. reporting.define.'),
  ('erp_add_report_pack_item', 'erp.add_report_pack_item', 'Adds a report to a pack. reporting.define.'),
  ('erp_remove_report_pack_item', 'erp.remove_report_pack_item', 'Removes a report from a pack. reporting.define.'),
  ('erp_assemble_report_pack', 'erp.assemble_report_pack',
   'Assembles a pack: one authorised run per item, each produced as an extract, and a manifest. reporting.export.'),
  ('erp_expose_governed_view', 'erp.expose_governed_view', 'Puts a governed view on the analytics contract. administration.integrate.'),
  ('erp_revise_analytics_contract', 'erp.revise_analytics_contract',
   'Deprecates the contract in force on notice and opens the next version. administration.integrate.'),
  ('erp_retire_analytics_contract', 'erp.retire_analytics_contract',
   'Retires a deprecated contract after its notice has run. administration.integrate.'),
  ('erp_issue_analytics_credential', 'erp.issue_analytics_credential',
   'Issues a tenant-scoped, view-scoped, expiring credential and shows its token once. administration.integrate, and administration.users through the service principal it creates.'),
  ('erp_revoke_analytics_credential', 'erp.revoke_analytics_credential', 'Revokes a credential with a reason. administration.integrate.'),
  ('erp_analytics_read', 'erp.analytics_read',
   'The read-only contract. The credential is the gate: it names the organisation, the views, and expires; the function refuses an unknown, revoked or expired one and a view not on the contract.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('erp', 'analytics_read',
   'The identity is the credential, not a session: an external tool presents a token, and the function resolves it to one organisation and the views that organisation exposed. Every read is filtered to the credential''s tenant_id, the view must be exposed on an unretired contract, the credential must be live, and nothing is written but last_used_at.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('reporting_services', 'Reporting services sound', 'assertion', 'platform',
   'erp', 'assert_reporting_services', '', 'reporting_services_report', '',
   'Part 19''s services: a deferred run is produced rather than forgotten, a subscription reaches only those still permitted, an exposed view has a contract in force and a credential names only exposed views, and a deprecated contract does not outlive its notice unnoticed.',
   true, 68)
on conflict (code) do update set
  title = excluded.title, blurb = excluded.blurb, function_name = excluded.function_name,
  detail_function = excluded.detail_function, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
('output.template.report_extract', 'en', 'Report extract',
 'The output template a deferred report run is produced through: the rows as CSV, archived with a checksum.'),
('job_handler.produce_extracts.name', 'en', 'Produce report extracts',
 'The scheduled job that produces the runs the interactive budget deferred.'),
('job_handler.distribute_subscriptions.name', 'en', 'Distribute report subscriptions',
 'The scheduled job that produces due subscriptions and queues their delivery.'),
('nav.reporting_distribution', 'en', 'Subscriptions, packs and extracts',
 'Navigation label for the reporting services screen: extracts of deferred runs, subscriptions by person or role, assembled packs with manifests, and the analytics contract.')
on conflict (key, locale) do update set value = excluded.value, description = excluded.description;

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(t.text), 'en', t.text,
       'Screen wording, keyed by its own source text so a tenant can rename it.'
  from (values
    ('Subscriptions, packs and extracts'),
    ('Reporting services are not installed. Installing them is a configuration change, approved and promoted like a module: the extract template a deferred run is produced through, and the two jobs that produce extracts and distribute subscriptions.'),
    ('Install reporting services'),
    ('Installed: deferred runs are produced as extracts and subscriptions are distributed by the scheduled jobs.'),
    ('Extracts'),
    ('Every run the interactive budget deferred, and what became of it. A produced extract is archived with its checksum, parameters and as-at time, so the figure can be reproduced.'),
    ('No run has been deferred. A run that exceeds its version''s row cap or time budget lands here instead of failing.'),
    ('Subscriptions'),
    ('By person or by role, on a cadence, delivered through the output subsystem. Each production checks that the recipient still holds the permission the report requires.'),
    ('Nobody is subscribed to a report.'),
    ('Packs'),
    ('A pack is a defined artefact with a manifest: which reports, which versions, which parameters, and the as-at time and checksum of each figure.'),
    ('No pack is defined.'),
    ('Analytics contract'),
    ('Governed views exposed to external tools as versioned contracts, deprecated on notice; credentials scoped to the organisation and to named views, expiring and revocable. Bulk export reads the same door incrementally.'),
    ('No governed view is registered yet; installing a module registers its views.'),
    ('No credential has been issued.'),
    ('Download'),
    ('Show'),
    ('Waiting'),
    ('Produced'),
    ('Failed'),
    ('Exposed'),
    ('Not exposed'),
    ('Deprecated'),
    ('Retired'),
    ('Revoked'),
    ('Expired'),
    ('Live'),
    ('Token'),
    ('Issue a credential'),
    ('Pause'),
    ('Resume'),
    ('This token is shown once. Give it to the tool that will hold it; it cannot be recovered, only revoked.')
  ) t(text)
on conflict (key, locale) do nothing;

insert into erp_ref.help_topic (screen_path, nav_key, module_code, summary, steps, next_action, actions) values
  ('/reporting/distribution', 'nav.reporting_distribution', 'reporting',
   'The services beneath the reports: a run the budget deferred is produced as an archived extract, a subscription by person or role is delivered on a cadence to those still permitted, a pack is assembled with a manifest, and a governed view is exposed to external tools as a versioned contract read with a scoped credential.',
   '["Install reporting services once; it is promoted like a module.","A deferred run appears under Extracts and is produced by the scheduled job.","Subscribe yourself, or under reporting.define a role, to a report on a cadence.","Define a pack and assemble it; the manifest is the artefact.","Expose a governed view, issue a credential naming it, and read it through erp_analytics_read."]',
   'Install reporting services, then subscribe to a report.',
   '{erp_configure_reporting,erp_subscribe_to_report,erp_assemble_report_pack,erp_issue_analytics_credential}')
on conflict (screen_path) do update set
  nav_key = excluded.nav_key, module_code = excluded.module_code, summary = excluded.summary,
  steps = excluded.steps, next_action = excluded.next_action, actions = excluded.actions;

-- ── The decisions ────────────────────────────────────────────────────────────

insert into erp_meta.policy_decision
  (code, title, spec_reference, decision, rationale, status, evidence)
values
  ('nl_querying_reads_the_contract',
   'Natural-language querying is a client of the analytics contract',
   'v1.2 §19.5',
   'The product does not parse language. Natural-language querying, where an organisation wants it, is a model outside the database that turns a question into a read of exposed governed views through erp_analytics_read(), under a credential scoped to those views. It inherits every scope rule because it can reach nothing else.',
   '§19.5 says NL querying "operates over the same governed views and is read-only, so it inherits every scope rule rather than needing its own". The way to make that true by construction is to give it no other door: the contract is the only read an external process has, and a credential cannot widen it. A language model inside the transaction path would be exactly the thing §10 refuses.',
   'accepted',
   'erp.analytics_read() is the one door; erp.issue_analytics_credential() refuses a view not on the contract; erp_test.reporting_services_suite() reads through it and is refused outside its scope.'),
  ('packs_and_subscriptions_are_operating_data',
   'Subscriptions and packs are operating data, not promoted configuration',
   'v1.2 §19.4',
   'erp.report_subscription, erp.report_pack and erp.report_pack_item are tenant-scoped and audited but are not on erp_meta.promotable_surface. They do not travel between an organisation''s environments through a change set.',
   'A subscription names a person and a next due time; promoting it into a sandbox would subscribe real people to a sandbox''s figures. A pack names reports that do promote (§19.2), so the pack definition is a small list an administrator recreates against promoted reports, and a pack run is an artefact of one environment by definition. What must promote — the report and its version — does.',
   'accepted',
   'erp_meta.promotable_surface holds erp.report, erp.report_version and erp.report_parameter and not the three tables above; erp.assert_configuration_promotable() passes.')
on conflict (code) do update set
  title = excluded.title, decision = excluded.decision, rationale = excluded.rationale,
  status = excluded.status, evidence = excluded.evidence;

-- ── The suite ─────────────────────────────────────────────────────────────────

create or replace function erp_test.reporting_services_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  r record;
  ad uuid := gen_random_uuid();
  v_tenant uuid; v_code text := 'zzrs-' || substr(md5(random()::text), 1, 6);
  v_view uuid; v_report uuid; v_ver uuid;
  v_ok boolean; v_msg text; res jsonb; v_run uuid; v_sub uuid; v_cred jsonb; v_n integer;
  v_token text;
begin
  select * into r from erp.provision_tenant(v_code, 'Reporting Services', 'admin@zzrs.test', 'Services Admin');
  v_tenant := r.tenant_id;
  insert into auth.users (id, email) values (ad, 'admin@zzrs.test');
  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  perform erp.claim_invitation(r.admin_token);

  perform erp_test.reopen_bootstrap_window(v_tenant);
  insert into erp.governed_view
    (tenant_id, code, name, description, source_schema, source_name,
     required_permission, data_classes, lineage_columns)
  values (v_tenant, 'movements', 'Stock movements', 'The ledger.', 'erp', 'stock_movement',
          'reporting.read', '{}', '{id}')
  returning id into v_view;
  insert into erp.report (tenant_id, code, name, description, governed_view_id, kpi_codes, audience_role_codes, status)
  values (v_tenant, 'movement_log', 'Movement log', 'Every movement.', v_view, '{}', '{}', 'active')
  returning id into v_report;
  insert into erp.report_version
    (tenant_id, report_id, version, governed_view_id, columns, group_by, default_sort,
     output_formats, required_permission, time_budget_ms, row_cap, status, effective_from)
  values (v_tenant, v_report, 1, v_view, '{movement_type,quantity,occurred_at}', '{}',
          '{occurred_at}', '{csv}', 'reporting.read', 5000, 100, 'active', current_date - 1)
  returning id into v_ver;
  perform erp_test.close_bootstrap_window(v_tenant);

  -- ── §19.3 a deferred run waits, then is produced ──────────────────────────

  res := erp.run_report('movement_log', '{}'::jsonb, 5000, 100);
  v_run := (res ->> 'run_id')::uuid;
  return query select 'a run beyond the row cap is deferred, not failed',
    res ->> 'outcome' = 'deferred_to_extract', res ->> 'extract_reason';

  res := erp.produce_report_extract(v_run);
  return query select 'without reporting services installed the extract waits and says why',
    res ->> 'status' = 'waiting' and res ->> 'reason' like 'no extract template%', res ->> 'reason';

  -- Installing is a change set; before go-live it is promoted on the spot,
  -- afterwards it waits for a second person, as every module does.
  perform erp_test.reopen_bootstrap_window(v_tenant);
  perform erp.configure_reporting();
  perform erp_test.close_bootstrap_window(v_tenant);
  return query select 'installing reporting services is a change set carrying the template and two jobs',
    exists (select 1 from erp.output_template t where t.tenant_id = v_tenant and t.code = 'report_extract' and t.kind = 'extract')
    and (select count(*) from erp.job j where j.tenant_id = v_tenant
          and j.handler_code in ('reporting.produce_extracts', 'reporting.distribute_subscriptions')) = 2,
    'promoted during the bootstrap window';

  select count(*) into v_n from erp.produce_report_extracts();
  res := public.erp_report_extract_content(v_run);
  return query select 'the extract job produces the run through the output subsystem',
    v_n = 1 and (res ->> 'produced')::boolean
    and res ->> 'content' = E'movement_type,quantity,occurred_at\n'
    and res ->> 'checksum' = md5(res ->> 'content')
    and exists (select 1 from erp.output_request q where q.tenant_id = v_tenant and q.object_id = v_run
                 and q.object_type = 'report_run' and q.destination_kind = 'archive_only'),
    format('%s bytes, checksum %s', res ->> 'byte_size', res ->> 'checksum');

  return query select 'and the snapshot carries the parameters and as-at time for reproduction',
    (res -> 'snapshot' ->> 'report') = 'movement_log'
    and (res -> 'snapshot' ->> 'as_at') is not null
    and (res -> 'snapshot' ->> 'row_count')::integer = 0,
    res -> 'snapshot' ->> 'as_at';

  return query select 'producing again does not produce twice',
    (select count(*) from erp.produce_report_extracts()) = 0
    and (select count(*) from erp.report_extract e where e.tenant_id = v_tenant) = 1,
    'one extract per run';

  -- ── §19.4 subscriptions ───────────────────────────────────────────────────

  v_sub := erp.subscribe_to_report('movement_log', 'person', null, null, '{}'::jsonb, 'daily', '06:00', 'Europe/London', 'email');
  return query select 'a person subscribes to a report they may read, and a next due time is set',
    (select s.next_due_at > now() from erp.report_subscription s where s.id = v_sub),
    (select s.next_due_at::text from erp.report_subscription s where s.id = v_sub);

  begin
    perform erp.subscribe_to_report('movement_log', 'role', null, 'nonexistent-role');
    v_ok := false; v_msg := 'a role that does not exist was subscribed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_UNKNOWN_ROLE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a role that does not exist cannot be subscribed', v_ok, v_msg;

  update erp.report_subscription set next_due_at = now() - interval '1 minute' where id = v_sub;
  select count(*) into v_n from erp.distribute_report_subscriptions() d where d.outcome = 'produced';
  return query select 'a due subscription is produced as an extract and queued for delivery',
    v_n = 1
    and exists (select 1 from erp.output_delivery d
                 where d.tenant_id = v_tenant and d.destination = 'admin@zzrs.test'
                   and d.destination_kind = 'email' and d.status = 'queued'),
    'queued to the subscriber through Part 15';

  return query select 'and its next due time moved on',
    (select s.next_due_at > now() and s.last_run_at is not null from erp.report_subscription s where s.id = v_sub),
    'the cadence continues';

  insert into erp.email_suppression (tenant_id, address, reason, is_permanent)
  values (v_tenant, 'admin@zzrs.test', 'complaint', true);
  update erp.report_subscription set next_due_at = now() - interval '1 minute' where id = v_sub;
  select d.detail into v_msg from erp.distribute_report_subscriptions() d;
  return query select 'a suppressed address is refused by the delivery path, and the refusal is in the result',
    v_msg like '%ERPWARE_ADDRESS_SUPPRESSED%' and v_msg like '0 recipient(s)%', v_msg;
  delete from erp.email_suppression where tenant_id = v_tenant;

  perform erp.set_report_subscription_status(v_sub, 'paused');
  return query select 'a subscription can be paused',
    (select s.status from erp.report_subscription s where s.id = v_sub) = 'paused', 'paused';

  -- ── §19.4 packs ───────────────────────────────────────────────────────────

  perform erp.upsert_report_pack('weekly', 'Weekly operating pack', 'What moved.');
  begin
    perform erp.assemble_report_pack('weekly');
    v_ok := false; v_msg := 'an empty pack was assembled';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_REPORT_PACK_EMPTY%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an empty pack cannot be assembled', v_ok, v_msg;

  perform erp.add_report_pack_item('weekly', 'movement_log', '{}'::jsonb, 10);
  res := erp.assemble_report_pack('weekly');
  return query select 'assembling a pack produces a manifest with each figure''s as-at time and checksum',
    jsonb_array_length(res -> 'items') = 1
    and res -> 'items' -> 0 ->> 'extract_status' = 'produced'
    and res -> 'items' -> 0 ->> 'checksum' is not null
    and res -> 'items' -> 0 ->> 'as_at' is not null
    and exists (select 1 from erp.report_pack_run pr where pr.tenant_id = v_tenant and pr.id = (res ->> 'pack_run_id')::uuid),
    res -> 'items' -> 0 ->> 'checksum';

  -- ── §19.5 the contract ────────────────────────────────────────────────────

  begin
    perform erp.issue_analytics_credential('BI tool', array['movements']);
    v_ok := false; v_msg := 'a credential named a view that is not exposed';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_VIEW_NOT_EXPOSED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a credential cannot name a view that is not on the contract', v_ok, v_msg;

  v_n := erp.expose_governed_view('movements');
  v_cred := erp.issue_analytics_credential('BI tool', array['movements']);
  v_token := v_cred ->> 'token';
  return query select 'exposing a view opens contract version 1, and a credential is issued once',
    v_n = 1 and length(v_token) = 64
    and (select c.token_digest <> v_token from erp.analytics_credential c where c.id = (v_cred ->> 'credential_id')::uuid),
    'the table holds a digest, not the token';

  perform set_config('request.jwt.claims', '', true);
  res := erp.analytics_read(v_token, 'movements');
  return query select 'the contract is read with the credential alone, scoped to the organisation',
    (res ->> 'contract_version')::integer = 1 and (res ->> 'row_count')::integer = 0
    and res ->> 'incremental_on' = 'recorded_at',
    res ->> 'incremental_on';

  begin
    perform erp.analytics_read(v_token, 'other_view');
    v_ok := false; v_msg := 'a view outside the credential''s scope was read';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ANALYTICS_OUT_OF_SCOPE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a view outside the credential''s scope is refused', v_ok, v_msg;

  begin
    perform erp.analytics_read('not-a-token', 'movements');
    v_ok := false; v_msg := 'an unknown token was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ANALYTICS_CREDENTIAL_REFUSED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'an unknown token is refused', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  begin
    perform erp.revise_analytics_contract('movements', 'column renamed', current_date);
    v_ok := false; v_msg := 'a deprecation without future notice was accepted';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_DEPRECATION_WITHOUT_NOTICE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a contract is deprecated on notice, with a retirement date in the future', v_ok, v_msg;

  v_n := erp.revise_analytics_contract('movements', 'quantity becomes numeric(18,6)', current_date + 30);
  perform set_config('request.jwt.claims', '', true);
  res := erp.analytics_read(v_token, 'movements');
  return query select 'revising opens version 2 and the read reports it',
    v_n = 2 and (res ->> 'contract_version')::integer = 2,
    format('version %s', res ->> 'contract_version');

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  begin
    perform erp.retire_analytics_contract('movements', 1);
    v_ok := false; v_msg := 'a contract was retired before its notice ran';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_RETIRED_BEFORE_NOTICE%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a deprecated contract cannot be retired before its notice has run', v_ok, v_msg;

  perform erp.revoke_analytics_credential((v_cred ->> 'credential_id')::uuid, 'tool decommissioned');
  perform set_config('request.jwt.claims', '', true);
  begin
    perform erp.analytics_read(v_token, 'movements');
    v_ok := false; v_msg := 'a revoked credential still read';
  exception when others then
    v_ok := sqlerrm like 'ERPWARE_ANALYTICS_CREDENTIAL_REFUSED%'; v_msg := left(sqlerrm, 70);
  end;
  return query select 'a revoked credential is refused', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ad)::text, true);
  return query select 'the assertion passes over all of it',
    erp.assert_reporting_services() is not null, 'no finding';

  -- ── Clean up ──────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  perform erp.begin_tenant_purge(v_tenant);
  delete from erp.tenant where id = v_tenant;
  perform erp.end_tenant_purge();
  delete from auth.users where id = ad;
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_tenant), 'organisation gone';
end;
$$;

create or replace function erp_test.assert_reporting_services_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _reporting_services_result on commit drop as
    select * from erp_test.reporting_services_suite();

  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _reporting_services_result;

  if v_passed < v_total then
    raise exception E'ERPWARE_REPORTING_SERVICES_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('reporting services: %s/%s', v_passed, v_total);
end;
$$;

select erp_test.assert_reporting_services_suite();

-- ── The generators, then the assertions ──────────────────────────────────────

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_public_api_safe();
select erp.assert_configuration_promotable();
select erp.assert_no_dead_configuration();
select erp.assert_diagnostics_registered();
select erp.assert_job_handlers_resolvable();
select erp.assert_output_integrity();
select erp.assert_reporting_services();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_guidance_sound();
