-- ─────────────────────────────────────────────────────────────────────────────
-- The audit trail says what did it.
--
-- Found by the production-readiness pass, Phase 8, by reading one organisation's
-- audit stream as its auditor. Of 4,785 entries, 208 carry no actor at all:
--
--   api | insert on role_permission x165
--   api | update on numbering_rule  x40
--   api | insert on app_user        x12
--   api | insert on user_role       x12
--   api | insert on environment      x6
--   … and eight smaller groups
--
-- These are honest in one sense — no person made them. They are provisioning
-- creating the administrator, the base pack granting permissions, the promoter
-- installing numbering rules; none of those has a signed-in principal, and
-- erp.current_principal_id() correctly returns null. What is not honest is the
-- rest of the row: actor_kind and actor_label are null, so the screen shows a
-- blank where an actor goes, and `source` says 'api', which none of them were.
--
-- An auditor reading that sees 208 changes to permissions and numbering that
-- nobody made, through an interface nobody used. The record is not wrong about
-- the change; it is wrong about the change's origin, which for an audit trail is
-- the whole point.
--
-- The mechanism is knowable without instrumenting every caller. PL/pgSQL keeps a
-- call stack and GET DIAGNOSTICS PG_CONTEXT hands it over, so the trigger can
-- name the outermost erp function on the stack — erp.provision_tenant,
-- erp.apply_content_pack, erp.promote_change_set — and say that. It is read only
-- when there is no actor, which is the rare case, so an ordinary write pays
-- nothing for it: the 152,506 stock movements in this test organisation all have
-- an actor and never reach the branch.
--
-- Then the class is closed rather than the instances relabelled:
-- erp.assert_audit_attributed() refuses an audit row that has neither a
-- principal nor a mechanism. An unattributed change may exist — provisioning
-- genuinely has no person behind it — but it must say what it was.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.audit_row_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_before   jsonb;
  v_after    jsonb;
  v_row      jsonb;
  v_tenant   uuid;
  v_changed  text[];
  v_action   erp.audit_action;
  v_actor    uuid := erp.current_principal_id();
  v_kind     erp.principal_kind;
  v_label    text;
  v_source   text;
  v_stack    text;
begin
  if tg_op = 'INSERT' then
    v_action := 'insert';
    v_after  := to_jsonb(new);
    v_row    := v_after;
  elsif tg_op = 'UPDATE' then
    v_action := 'update';
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
    v_row    := v_after;
  else
    v_action := 'delete';
    v_before := to_jsonb(old);
    v_row    := v_before;
  end if;

  v_tenant := (v_row ->> 'tenant_id')::uuid;

  -- A tenant purge removes the tenant's audit stream along with everything
  -- else; writing new audit rows during it would resurrect the tenant.
  if nullif(current_setting('erp.purge_tenant_id', true), '')::uuid = v_tenant then
    return coalesce(new, old);
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(key order by key), '{}')
      into v_changed
      from jsonb_each(v_after) e(key, value)
     where v_before -> e.key is distinct from e.value
       -- Attribution columns change on every update by definition; listing
       -- them as "what changed" would bury the field that actually did.
       and e.key not in ('updated_at', 'updated_by');

    -- An update that touched nothing but its own attribution is not a
    -- business change and does not earn a line in the stream.
    if cardinality(v_changed) = 0 then
      return new;
    end if;
  end if;

  v_source := coalesce(nullif(current_setting('erp.source', true), ''), 'api');

  if v_actor is not null then
    select u.kind, u.display_name into v_kind, v_label
      from erp.app_user u where u.id = v_actor;
  else
    -- No principal. Something still did this, and the call stack knows what:
    -- the outermost erp function on it is the mechanism — provisioning, a
    -- content pack, the promoter, a job. Read only here, so an ordinary write
    -- by a signed-in person never pays for it.
    get diagnostics v_stack = pg_context;
    select m[1] into v_label
      from regexp_matches(v_stack, 'PL/pgSQL function (erp[_a-z]*\.[a-z_]+)\(', 'g')
             with ordinality as f(m, ord)
     order by f.ord desc
     limit 1;

    v_kind  := 'service';
    v_label := coalesce('system: ' || v_label, 'system');
    -- And the source says the mechanism too, rather than claiming an API call
    -- nobody made. An explicitly set erp.source still wins: a caller that has
    -- said what it is knows better than this does.
    if nullif(current_setting('erp.source', true), '') is null then
      v_source := 'system';
    end if;
  end if;

  insert into erp.audit_entry (
    tenant_id, actor_id, actor_kind, actor_label, action,
    object_schema, object_type, object_id, object_key,
    entity_id, site_id, before_state, after_state, changed_fields,
    correlation_id, source)
  values (
    v_tenant,
    v_actor,
    v_kind,
    v_label,
    v_action,
    tg_table_schema,
    tg_table_name,
    (v_row ->> 'id')::uuid,
    v_row ->> 'code',
    (v_row ->> 'entity_id')::uuid,
    (v_row ->> 'site_id')::uuid,
    v_before,
    v_after,
    v_changed,
    erp.current_correlation_id(),
    v_source);

  return coalesce(new, old);
exception
  when invalid_text_representation then
    -- A table whose id or entity_id is not a uuid still gets audited; it just
    -- lands with those columns null rather than failing the business write.
    insert into erp.audit_entry (
      tenant_id, actor_id, actor_kind, actor_label, action,
      object_schema, object_type, object_key,
      before_state, after_state, changed_fields, correlation_id, source)
    values (
      v_tenant, v_actor, v_kind, v_label, v_action, tg_table_schema, tg_table_name,
      v_row ->> 'code', v_before, v_after, v_changed,
      erp.current_correlation_id(), v_source);
    return coalesce(new, old);
end;
$function$;

comment on function erp.audit_row_change() is
  'Writes the audit stream. A change with no signed-in principal names the '
  'mechanism that made it, read from the PL/pgSQL call stack, rather than '
  'leaving the actor blank and calling itself an API call. 208 entries in a '
  'single test organisation did the latter.';

-- ── The class, closed ────────────────────────────────────────────────────────
--
-- erp.audit_entry is append-only, so entries written before this migration
-- cannot be given the mechanism they never recorded — and inventing one for a
-- historical change is exactly the fault being repaired. The assertion is
-- therefore dated: it judges what has happened since attribution started being
-- recorded, and says so rather than quietly ignoring the rest.

create table if not exists erp_meta.audit_attribution_epoch (
  only_row    boolean primary key default true check (only_row),
  started_at  timestamptz not null default now()
);

insert into erp_meta.audit_attribution_epoch (only_row) values (true)
on conflict (only_row) do nothing;

comment on table erp_meta.audit_attribution_epoch is
  'When erp.audit_row_change() began naming the mechanism behind a change with '
  'no signed-in principal. erp.assert_audit_attributed() judges entries from '
  'this instant on; earlier ones are append-only and cannot be corrected.';

select erp_meta.register_table('erp_meta', 'audit_attribution_epoch',
  'platform_internal',
  'One row, recording when audit attribution began. Not tenant data.');

select erp.apply_platform_internal_security();

create or replace function erp.audit_attribution_report()
returns table (tenant_code text, object_type text, action text, entries bigint)
language sql
stable
set search_path to ''
as $$
  -- An audit row with neither a principal nor a mechanism. Provisioning has no
  -- person behind it and never will; what it must not do is decline to say so.
  select t.code, a.object_type, a.action::text, count(*)
    from erp.audit_entry a
    join erp.tenant t on t.id = a.tenant_id
   where a.actor_id is null
     and (a.actor_label is null or a.actor_label = '')
     and a.occurred_at >= (select e.started_at from erp_meta.audit_attribution_epoch e)
   group by t.code, a.object_type, a.action
   order by count(*) desc, t.code, a.object_type
$$;

revoke all on function erp.audit_attribution_report() from public, anon;

create or replace function erp.assert_audit_attributed()
returns text
language plpgsql
stable
set search_path to ''
as $$
declare v_rows bigint; v_groups int; v_detail text;
begin
  select coalesce(sum(r.entries), 0), count(*),
         string_agg(format('  %s: %s on %s x%s', r.tenant_code, r.action,
                           r.object_type, r.entries), E'\n')
    into v_rows, v_groups, v_detail
    from erp.audit_attribution_report() r;

  if v_groups > 0 then
    raise exception E'ERPWARE_AUDIT_UNATTRIBUTED: % entr(ies) in % group(s) name neither a principal nor a mechanism\n%',
      v_rows, v_groups, v_detail
      using errcode = '23502',
      hint = 'erp.audit_row_change() reads the call stack when there is no '
             'principal. A row that still says nothing was written round the '
             'trigger, or by a path that suppresses it.';
  end if;

  return format('audit attribution: every one of %s entries since %s names a principal or a mechanism',
                (select count(*) from erp.audit_entry a
                  where a.occurred_at >= (select e.started_at from erp_meta.audit_attribution_epoch e)),
                (select e.started_at::date from erp_meta.audit_attribution_epoch e));
end;
$$;

revoke all on function erp.assert_audit_attributed() from public, anon;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('audit_attributed', 'Every audit entry says who or what', 'assertion',
   'platform', 'erp', 'assert_audit_attributed', '',
   'audit_attribution_report', '',
   'A change with no signed-in principal must still name the mechanism that '
   'made it. 208 entries in one organisation named neither.', true,
   (select coalesce(max(seq), 0) + 1 from erp_meta.diagnostic_check))
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci;

select erp.assert_audit_attributed();
select erp.assert_diagnostics_registered();
