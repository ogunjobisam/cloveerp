-- Addendum B, step one: put the mechanism where the rest of the codebase keeps it.
--
-- All nine of Addendum B's configuration surfaces are written by a
-- public.erp_upsert_* door with the logic inline. That is inverted from
-- everywhere else here, where the mechanism lives in erp.* and the public
-- function is a thin gate — erp.create_party beneath
-- public.erp_create_party_with_roles, and so on.
--
-- It matters because erp.apply_change_set_item has nothing to call. The
-- promoter handles 22 object kinds today and not one of these nine is among
-- them, so Addendum B's own promise — "every new surface is a configuration
-- object: effective-dated, versioned, change-set promotable" — is unmet, and
-- the onboarding interview in §7 cannot propose a diff for any surface it
-- exists to configure.
--
-- It is also a live governance hole on its own, which is the more urgent half.
-- Measured on a live organisation before this migration:
--
--   rule_set            : refused BY THE GUARD
--   department          : ACCEPTED — no guard
--   classification_axis : ACCEPTED — no guard
--
-- So on a live organisation today, account determination — which decides the
-- ledger account a posting hits — and approval bands — which decide who must
-- approve what — are directly editable, while a rule set is not. That is
-- precisely the quiet live change B6 exists to prevent.
--
-- This migration only moves code. It adds no behaviour, changes no signature,
-- and every door keeps its own permission. The promoter branches, the live
-- guard registration and the assertion that stops surface ten repeating the
-- omission follow in the next migration, which needs these to exist first.
--
-- ONE JUDGEMENT IS ENCODED, and it is the reason this is a split rather than a
-- rename: `perform erp.authorise(...)` stays in the public door and does not
-- move into erp.*. Promotion authorises once, at the change set. A principal
-- holding administration.promote but not finance.configure must still be able
-- to promote a determination rule somebody else authored — that is the
-- separation of duties B6 is for, and it is why none of the 22 existing
-- promoter branches authorises per item.
--
-- Generated mechanically from the existing bodies rather than retyped: nine
-- functions, ~470 lines, several of which decide accounting behaviour.

-- ── erp_upsert_department ───────────────────────────────────

create or replace function erp.upsert_department(
  p_code                 text,
  p_name                 text,
  p_manager_user_id      uuid default null,
  p_parent_department_id uuid default null,
  p_default_cost_centre  text default null,
  p_entity_id            uuid default null,
  p_valid_from           date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin

  insert into erp.department (
    tenant_id, code, name, manager_user_id, parent_department_id,
    default_cost_centre, entity_id, valid_from)
  values (
    v_tenant, upper(p_code), p_name, p_manager_user_id, p_parent_department_id,
    p_default_cost_centre, p_entity_id, coalesce(p_valid_from, current_date))
  on conflict (tenant_id, code) do update
    set name = excluded.name,
        manager_user_id = excluded.manager_user_id,
        parent_department_id = excluded.parent_department_id,
        default_cost_centre = excluded.default_cost_centre,
        entity_id = excluded.entity_id
  returning id into v_id;

  return jsonb_build_object('department_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_upsert_department(
  p_code                 text,
  p_name                 text,
  p_manager_user_id      uuid default null,
  p_parent_department_id uuid default null,
  p_default_cost_centre  text default null,
  p_entity_id            uuid default null,
  p_valid_from           date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.upsert_department(p_code, p_name, p_manager_user_id, p_parent_department_id, p_default_cost_centre, p_entity_id, p_valid_from);
end;
$$;


-- ── erp_upsert_approval_band ───────────────────────────────────

create or replace function erp.upsert_approval_band(
  p_department_id     uuid,
  p_object_type       text,
  p_seq               integer,
  p_upper_bound_minor bigint default null,
  p_lower_bound_minor bigint default 0,
  p_approver_user_id  uuid default null,
  p_approver_role_code text default null,
  p_use_line_manager  boolean default false,
  p_currency          text default 'GBP',
  p_is_parallel       boolean default false,
  p_rerun_lower_bands boolean default true,
  p_escalate_after_hours integer default null,
  p_vacancy           text default 'hold_and_raise',
  p_tolerance_pct     numeric default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_resolution jsonb := '[]'::jsonb;
  v_id uuid;
begin

  if p_approver_user_id is not null then
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','user','user_id', p_approver_user_id));
  end if;
  if p_approver_role_code is not null then
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','role_in_department','role_code', p_approver_role_code));
    v_resolution := v_resolution || jsonb_build_array(
      jsonb_build_object('kind','role','role_code', p_approver_role_code,'scope','entity'));
  end if;
  if p_use_line_manager then
    v_resolution := v_resolution || jsonb_build_array(jsonb_build_object('kind','line_manager'));
  end if;

  if jsonb_array_length(v_resolution) = 0 then
    raise exception 'ERPWARE_BAND_UNRESOLVABLE: a band must name at least one way to find an approver'
      using errcode = '23514';
  end if;

  insert into erp.approval_band (
    tenant_id, department_id, object_type, seq, lower_bound_minor, upper_bound_minor,
    currency, resolution, is_parallel, rerun_lower_bands,
    escalate_after, vacancy, tolerance_pct)
  values (
    v_tenant, p_department_id, p_object_type, p_seq,
    coalesce(p_lower_bound_minor, 0), p_upper_bound_minor,
    upper(coalesce(p_currency,'GBP'))::char(3), v_resolution, p_is_parallel, p_rerun_lower_bands,
    case when p_escalate_after_hours is null then null
         else make_interval(hours => p_escalate_after_hours) end,
    p_vacancy::erp.vacancy_behaviour, p_tolerance_pct)
  on conflict (tenant_id, department_id, object_type, seq, valid_from) do update
    set lower_bound_minor = excluded.lower_bound_minor,
        upper_bound_minor = excluded.upper_bound_minor,
        currency = excluded.currency,
        resolution = excluded.resolution,
        is_parallel = excluded.is_parallel,
        rerun_lower_bands = excluded.rerun_lower_bands,
        escalate_after = excluded.escalate_after,
        vacancy = excluded.vacancy,
        tolerance_pct = excluded.tolerance_pct,
        version = erp.approval_band.version + 1
  returning id into v_id;

  return jsonb_build_object('band_id', v_id);
end;
$$;

create or replace function public.erp_upsert_approval_band(
  p_department_id     uuid,
  p_object_type       text,
  p_seq               integer,
  p_upper_bound_minor bigint default null,
  p_lower_bound_minor bigint default 0,
  p_approver_user_id  uuid default null,
  p_approver_role_code text default null,
  p_use_line_manager  boolean default false,
  p_currency          text default 'GBP',
  p_is_parallel       boolean default false,
  p_rerun_lower_bands boolean default true,
  p_escalate_after_hours integer default null,
  p_vacancy           text default 'hold_and_raise',
  p_tolerance_pct     numeric default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.upsert_approval_band(p_department_id, p_object_type, p_seq, p_upper_bound_minor, p_lower_bound_minor, p_approver_user_id, p_approver_role_code, p_use_line_manager, p_currency, p_is_parallel, p_rerun_lower_bands, p_escalate_after_hours, p_vacancy, p_tolerance_pct);
end;
$$;


-- ── erp_assign_named_approver ───────────────────────────────────

create or replace function erp.assign_named_approver(
  p_subject_kind      text,
  p_subject_id        uuid,
  p_object_type       text,
  p_approver_user_id  uuid,
  p_mode              text default 'prepends',
  p_lower_bound_minor bigint default null,
  p_upper_bound_minor bigint default null,
  p_reason            text default null,
  p_valid_from        date default null,
  p_valid_to          date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin

  if p_subject_kind = 'principal' and p_subject_id = p_approver_user_id then
    raise exception 'ERPWARE_SELF_APPROVAL: a principal may not be assigned as their own approver'
      using errcode = '23514';
  end if;

  insert into erp.approver_assignment (
    tenant_id, subject_kind, subject_id, object_type, approver_user_id, mode,
    lower_bound_minor, upper_bound_minor, reason, valid_from, valid_to)
  values (
    v_tenant, p_subject_kind::erp.approver_subject_kind, p_subject_id, p_object_type,
    p_approver_user_id, p_mode::erp.approver_assignment_mode,
    p_lower_bound_minor, p_upper_bound_minor, p_reason,
    coalesce(p_valid_from, current_date), p_valid_to)
  returning id into v_id;

  return jsonb_build_object('assignment_id', v_id);
end;
$$;

create or replace function public.erp_assign_named_approver(
  p_subject_kind      text,
  p_subject_id        uuid,
  p_object_type       text,
  p_approver_user_id  uuid,
  p_mode              text default 'prepends',
  p_lower_bound_minor bigint default null,
  p_upper_bound_minor bigint default null,
  p_reason            text default null,
  p_valid_from        date default null,
  p_valid_to          date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.assign_named_approver(p_subject_kind, p_subject_id, p_object_type, p_approver_user_id, p_mode, p_lower_bound_minor, p_upper_bound_minor, p_reason, p_valid_from, p_valid_to);
end;
$$;


-- ── erp_upsert_posting_class ───────────────────────────────────

create or replace function erp.upsert_posting_class(
  p_kind        text,
  p_code        text,
  p_name        text,
  p_description text default null,
  p_valid_from  date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id uuid;
begin

  select pc.id into v_id from erp.posting_class pc
   where pc.tenant_id = v_tenant and pc.kind::text = p_kind and pc.code = upper(p_code);

  if v_id is null then
    insert into erp.posting_class (tenant_id, kind, code, name, description, valid_from)
    values (v_tenant, p_kind::erp.posting_class_kind, upper(p_code), p_name, p_description,
            coalesce(p_valid_from, current_date))
    returning id into v_id;
  else
    update erp.posting_class
       set name = p_name, description = coalesce(p_description, description),
           status = 'active', updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('posting_class_id', v_id, 'code', upper(p_code), 'kind', p_kind);
end;
$$;

create or replace function public.erp_upsert_posting_class(
  p_kind        text,
  p_code        text,
  p_name        text,
  p_description text default null,
  p_valid_from  date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('finance.configure');
  return erp.upsert_posting_class(p_kind, p_code, p_name, p_description, p_valid_from);
end;
$$;


-- ── erp_upsert_account_determination ───────────────────────────────────

create or replace function erp.upsert_account_determination(
  p_transaction_type      text,
  p_account_id            uuid,
  p_item_class_id         uuid default null,
  p_party_class_id        uuid default null,
  p_site_id               uuid default null,
  p_entity_id             uuid default null,
  p_ledger_id             uuid default null,
  p_reason_code           text default null,
  p_legislation_pack_code text default null,
  p_dimensions            jsonb default null,
  p_note                  text default null,
  p_valid_from            date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_from date := coalesce(p_valid_from, current_date);
  v_id uuid;
begin

  if not exists (select 1 from erp.account a
                  where a.tenant_id = v_tenant and a.id = p_account_id and a.is_postable) then
    raise exception 'ERPWARE_ACCOUNT_NOT_POSTABLE: that account cannot take a posting'
      using errcode = '23514';
  end if;

  select ad.id into v_id from erp.account_determination ad
   where ad.tenant_id = v_tenant
     and ad.transaction_type = p_transaction_type
     and ad.status = 'active'
     and ad.item_class_id is not distinct from p_item_class_id
     and ad.party_class_id is not distinct from p_party_class_id
     and ad.site_id is not distinct from p_site_id
     and ad.entity_id is not distinct from p_entity_id
     and ad.ledger_id is not distinct from p_ledger_id
     and ad.reason_code is not distinct from p_reason_code
     and ad.legislation_pack_code is not distinct from p_legislation_pack_code
     and ad.valid_from = v_from;

  if v_id is null then
    insert into erp.account_determination (
      tenant_id, transaction_type, item_class_id, party_class_id, site_id, entity_id,
      ledger_id, legislation_pack_code, reason_code, account_id, dimensions, note, valid_from)
    values (v_tenant, p_transaction_type, p_item_class_id, p_party_class_id, p_site_id,
            p_entity_id, p_ledger_id, p_legislation_pack_code, p_reason_code, p_account_id,
            coalesce(p_dimensions, '{}'::jsonb), p_note, v_from)
    returning id into v_id;
  else
    update erp.account_determination
       set account_id = p_account_id,
           dimensions = coalesce(p_dimensions, dimensions),
           note = coalesce(p_note, note),
           version = version + 1,
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('rule_id', v_id, 'transaction_type', p_transaction_type);
end;
$$;

create or replace function public.erp_upsert_account_determination(
  p_transaction_type      text,
  p_account_id            uuid,
  p_item_class_id         uuid default null,
  p_party_class_id        uuid default null,
  p_site_id               uuid default null,
  p_entity_id             uuid default null,
  p_ledger_id             uuid default null,
  p_reason_code           text default null,
  p_legislation_pack_code text default null,
  p_dimensions            jsonb default null,
  p_note                  text default null,
  p_valid_from            date default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('finance.configure');
  return erp.upsert_account_determination(p_transaction_type, p_account_id, p_item_class_id, p_party_class_id, p_site_id, p_entity_id, p_ledger_id, p_reason_code, p_legislation_pack_code, p_dimensions, p_note, p_valid_from);
end;
$$;


-- ── erp_upsert_classification_axis ───────────────────────────────────

create or replace function erp.upsert_classification_axis(
  p_code         text,
  p_name         text,
  p_is_mandatory boolean default false,
  p_item_classes text default null,
  p_seq          integer default 100,
  p_name_key     text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_classes text[];
begin

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select a.id into v_id from erp.classification_axis a
   where a.tenant_id = v_tenant and a.code = upper(p_code);

  if v_id is null then
    insert into erp.classification_axis (
      tenant_id, code, name, name_key, item_classes, is_mandatory, seq)
    values (v_tenant, upper(p_code), p_name, p_name_key, v_classes,
            coalesce(p_is_mandatory, false), coalesce(p_seq, 100))
    returning id into v_id;
  else
    update erp.classification_axis
       set name = p_name, name_key = coalesce(p_name_key, name_key),
           item_classes = v_classes,
           is_mandatory = coalesce(p_is_mandatory, is_mandatory),
           seq = coalesce(p_seq, seq), updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('axis_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_upsert_classification_axis(
  p_code         text,
  p_name         text,
  p_is_mandatory boolean default false,
  p_item_classes text default null,
  p_seq          integer default 100,
  p_name_key     text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('master_data.write');
  return erp.upsert_classification_axis(p_code, p_name, p_is_mandatory, p_item_classes, p_seq, p_name_key);
end;
$$;


-- ── erp_upsert_classification_value ───────────────────────────────────

create or replace function erp.upsert_classification_value(
  p_axis_id      uuid,
  p_code         text,
  p_name         text,
  p_abbreviation text,
  p_parent_value_id uuid default null,
  p_name_key     text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
  v_used   boolean;
begin

  select v.id into v_id from erp.classification_value v
   where v.tenant_id = v_tenant and v.axis_id = p_axis_id and v.code = upper(p_code);

  if v_id is null then
    insert into erp.classification_value (
      tenant_id, axis_id, code, name, name_key, abbreviation, parent_value_id)
    values (v_tenant, p_axis_id, upper(p_code), p_name, p_name_key,
            upper(p_abbreviation), p_parent_value_id)
    returning id into v_id;
  else
    -- An abbreviation that has already produced a code cannot move: the codes
    -- it produced would stop meaning what they say.
    select exists (select 1 from erp.item_classification ic
                    where ic.tenant_id = v_tenant and ic.value_id = v_id)
      into v_used;

    if v_used and upper(p_abbreviation) is distinct from
         (select abbreviation from erp.classification_value where id = v_id) then
      raise exception
        'ERPWARE_ABBREVIATION_IN_USE: items already carry codes built from this abbreviation'
        using errcode = '23514';
    end if;

    update erp.classification_value
       set name = p_name, name_key = coalesce(p_name_key, name_key),
           abbreviation = upper(p_abbreviation),
           parent_value_id = p_parent_value_id, updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('value_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_upsert_classification_value(
  p_axis_id      uuid,
  p_code         text,
  p_name         text,
  p_abbreviation text,
  p_parent_value_id uuid default null,
  p_name_key     text default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('master_data.write');
  return erp.upsert_classification_value(p_axis_id, p_code, p_name, p_abbreviation, p_parent_value_id, p_name_key);
end;
$$;


-- ── erp_upsert_code_template ───────────────────────────────────

create or replace function erp.upsert_code_template(
  p_code         text,
  p_name         text,
  p_segments     jsonb,
  p_item_classes text default null,
  p_casing       text default 'upper',
  p_entity_id    uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_classes text[];
  v_latest  erp.code_template%rowtype;
  v_used    boolean := false;
  v_id      uuid;
  v_version integer := 1;
begin

  if jsonb_typeof(coalesce(p_segments, 'null'::jsonb)) <> 'array'
     or jsonb_array_length(p_segments) = 0 then
    raise exception 'ERPWARE_TEMPLATE_EMPTY: a template needs at least one segment'
      using errcode = '23514';
  end if;

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select * into v_latest from erp.code_template t
   where t.tenant_id = v_tenant and t.code = upper(p_code)
   order by t.version desc limit 1;

  if v_latest.id is not null then
    select exists (select 1 from erp.item_code_assignment a
                    where a.tenant_id = v_tenant and a.template_id = v_latest.id)
      into v_used;
  end if;

  if v_latest.id is null then
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, 1)
    returning id into v_id;
  elsif v_used then
    update erp.code_template set valid_to = current_date, status = 'retired',
                                 updated_at = now()
     where id = v_latest.id;
    v_version := v_latest.version + 1;
    insert into erp.code_template (
      tenant_id, code, name, segments, item_classes, casing, entity_id, version,
      next_value)
    values (v_tenant, upper(p_code), p_name, p_segments, v_classes,
            coalesce(p_casing, 'upper'), p_entity_id, v_version, v_latest.next_value)
    returning id into v_id;
  else
    update erp.code_template
       set name = p_name, segments = p_segments, item_classes = v_classes,
           casing = coalesce(p_casing, casing), entity_id = p_entity_id,
           updated_at = now()
     where id = v_latest.id
    returning id, version into v_id, v_version;
  end if;

  return jsonb_build_object('template_id', v_id, 'code', upper(p_code),
                            'version', v_version);
end;
$$;

create or replace function public.erp_upsert_code_template(
  p_code         text,
  p_name         text,
  p_segments     jsonb,
  p_item_classes text default null,
  p_casing       text default 'upper',
  p_entity_id    uuid default null
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('master_data.write');
  return erp.upsert_code_template(p_code, p_name, p_segments, p_item_classes, p_casing, p_entity_id);
end;
$$;


-- ── erp_upsert_release_area ───────────────────────────────────

create or replace function erp.upsert_release_area(
  p_site_id            uuid,
  p_code               text,
  p_name               text,
  p_location_id        uuid default null,
  p_replenishment_mode text default 'pull',
  p_channel_code       text default null,
  p_order_type_code    text default null,
  p_item_classes       text default null,
  p_min_quantity       numeric default null,
  p_max_quantity       numeric default null,
  p_ageing_hours       integer default 72,
  p_gate_printing      boolean default true)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  v_id      uuid;
  v_classes text[];
begin

  v_classes := case
    when p_item_classes is null or btrim(p_item_classes) = '' then null
    else (select array_agg(btrim(s)) from unnest(string_to_array(p_item_classes, ',')) s
           where btrim(s) <> '')
  end;

  select a.id into v_id from erp.release_area a
   where a.tenant_id = v_tenant and a.site_id = p_site_id and a.code = upper(p_code);

  if v_id is null then
    insert into erp.release_area (
      tenant_id, site_id, code, name, location_id, replenishment_mode,
      channel_code, order_type_code, item_classes, min_quantity, max_quantity,
      ageing_hours, gate_printing)
    values (v_tenant, p_site_id, upper(p_code), p_name, p_location_id,
            coalesce(p_replenishment_mode, 'pull'), p_channel_code, p_order_type_code,
            v_classes, p_min_quantity, p_max_quantity, coalesce(p_ageing_hours, 72),
            coalesce(p_gate_printing, true))
    returning id into v_id;
  else
    update erp.release_area
       set name = p_name, location_id = p_location_id,
           replenishment_mode = coalesce(p_replenishment_mode, replenishment_mode),
           channel_code = p_channel_code, order_type_code = p_order_type_code,
           item_classes = v_classes, min_quantity = p_min_quantity,
           max_quantity = p_max_quantity,
           ageing_hours = coalesce(p_ageing_hours, ageing_hours),
           gate_printing = coalesce(p_gate_printing, gate_printing),
           updated_at = now()
     where tenant_id = v_tenant and id = v_id;
  end if;

  return jsonb_build_object('release_area_id', v_id, 'code', upper(p_code));
end;
$$;

create or replace function public.erp_upsert_release_area(
  p_site_id            uuid,
  p_code               text,
  p_name               text,
  p_location_id        uuid default null,
  p_replenishment_mode text default 'pull',
  p_channel_code       text default null,
  p_order_type_code    text default null,
  p_item_classes       text default null,
  p_min_quantity       numeric default null,
  p_max_quantity       numeric default null,
  p_ageing_hours       integer default 72,
  p_gate_printing      boolean default true
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('logistics.plan');
  return erp.upsert_release_area(p_site_id, p_code, p_name, p_location_id, p_replenishment_mode, p_channel_code, p_order_type_code, p_item_classes, p_min_quantity, p_max_quantity, p_ageing_hours, p_gate_printing);
end;
$$;

-- ── Prove it ─────────────────────────────────────────────────────────────────
--
-- The doors keep their signatures, their permissions and their register rows,
-- so the public API surface is unchanged and these must still pass.

select erp.assert_public_api_safe();
select erp.assert_isolation();
