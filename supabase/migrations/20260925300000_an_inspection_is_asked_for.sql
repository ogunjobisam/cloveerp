set lock_timeout = '30s';

-- =============================================================================
-- 20260925300000  An inspection is asked for, and a batch nobody sampled is released
-- -----------------------------------------------------------------------------
-- PR8, M6a: the first half of node M6 of docs/spec/simplification-review.md
-- (inspection door, production trigger points, sampled batch release). This
-- half is the door and the release; M6b is the trigger points on the floor.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
--   * Nobody could ask for an inspection. erp.raise_inspection() had one
--     caller, the goods receipt, and no door: a batch somebody doubted, stock
--     returned from a customer, a lot pulled for a periodic test, could not be
--     inspected from any screen. The Quality screen said inspections appear
--     "once an event is reported", and nothing an event does raises one.
--   * A promoted inspection plan could not name the product it inspects: the
--     promotion wrote the class, the site and the trigger point and dropped
--     the item. And the trigger point was free text, so a plan typed with a
--     trigger nothing reads was accepted and never fired.
--   * erp.release_batch() demanded a typed basis and a signature on every
--     batch, before anything else, including one no plan had ever sampled:
--     stock quarantined on receipt because its item says so, with no plan to
--     inspect it against. The clean path paid the regulated path's price.
--
-- ── WHAT CHANGES ─────────────────────────────────────────────────────────────
--
--   * erp_raise_inspection: inspect a batch, or a product at a site, against
--     a plan named or the one that applies. It authorises quality.inspect,
--     refuses where no plan applies or one is already open, and moves no
--     stock: an inspection pending already stands between the batch and its
--     release. erp_inspection_plans lists the plans that apply, for the form.
--   * A plan's trigger point is one of receipt, in process, pre-release and
--     manual, and a promoted plan names its product.
--   * A batch is released without a basis or a signature where no plan
--     sampled it, and the release says so; where one did, both are still
--     demanded, first, as they always were.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_NO_INSPECTION_PLAN',
  'Asking for an inspection of a product no inspection plan covers.',
  'An inspection is made against a plan: what to check, how many to sample. With none, there is nothing to record the result against.',
  'Promote an inspection plan for the product, its class or everything on the Configuration screen, then ask again.');
select erp.register_refusal('CLOVEERP_INSPECTION_PLAN_DOES_NOT_APPLY',
  'Asking for an inspection against a plan for another product, class or site, or one withdrawn.',
  'The plan says what to check on the product it names; checked against something else its characteristics mean nothing.',
  'Choose one of the plans offered for the batch, or leave the plan empty and the one that applies is used.');
select erp.register_refusal('CLOVEERP_INSPECTION_ALREADY_OPEN',
  'Asking for a second inspection of a batch that has one nobody has decided.',
  'Two open inspections of one batch are two answers to one question; the release would have to choose between them.',
  'Record the results of the open inspection and decide it, then ask again if another is needed.');
select erp.register_refusal('CLOVEERP_INSPECTION_NEEDS_A_SUBJECT',
  'Asking for an inspection of nothing: no batch, no product, or a batch of another product than the one named.',
  'An inspection is of something, and its plan is chosen by what that is.',
  'Choose the batch, or the product, to inspect.');
select erp.register_refusal('CLOVEERP_RELEASE_NEEDS_BASIS_AND_SIGNATURE',
  'Releasing a batch an inspection plan sampled without saying what the release rests on, or signing it.',
  'A release of a batch that was inspected is a signed statement that the inspection supports it, not a status change.',
  'Give the basis for the release, such as the inspection or certificate relied on, and sign it with your full name.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. A plan's trigger point is one the product reads, and a promoted plan
-- names its product
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.inspection_plan drop constraint if exists inspection_plan_trigger_known;
alter table erp.inspection_plan add constraint inspection_plan_trigger_known
  check (trigger_point in ('receipt', 'in_process', 'pre_release', 'manual')) not valid;

do $validate$
declare
  v_bad text;
begin
  select string_agg(distinct format('%s (%s)', t.code, ip.trigger_point), ', ') into v_bad
    from erp.inspection_plan ip join erp.tenant t on t.id = ip.tenant_id
   where ip.trigger_point not in ('receipt', 'in_process', 'pre_release', 'manual');
  if v_bad is null then
    alter table erp.inspection_plan validate constraint inspection_plan_trigger_known;
  else
    -- Held, not fixed: a plan typed with a trigger nothing reads never fired,
    -- and which one it meant is its organisation's to say.
    raise notice 'inspection plans with a trigger point nothing reads, left for their organisation: %', v_bad;
  end if;
end
$validate$;

do $promote$
declare
  v_sig constant text := 'erp.apply_change_set_item(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        insert into erp.inspection_plan (
          tenant_id, code, name, item_class, site_id, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name', p ->> 'item_class',$o$,
    $n$        -- A plan may name its product, by code (20260925300000); one that
        -- names a product the organisation does not have is refused, not
        -- promoted as a plan for everything.
        if nullif(p ->> 'item', '') is not null
           and not exists (select 1 from erp.item it where it.tenant_id = v_tenant and it.code = p ->> 'item') then
          raise exception 'CLOVEERP_UNKNOWN_ITEM: inspection plan % names product %, which this organisation does not have',
            p ->> 'code', p ->> 'item'
            using errcode = '23503', hint = 'Name a product code the organisation holds, or leave the product empty.';
        end if;
        insert into erp.inspection_plan as ip_t (
          tenant_id, code, name, item_id, item_class, site_id, trigger_point, sampling_rule,
          characteristics, status)
        values (v_tenant, p ->> 'code', p ->> 'name',
                (select it.id from erp.item it where it.tenant_id = v_tenant and it.code = nullif(p ->> 'item', '')),
                p ->> 'item_class',$n$,
    $o$          set name = excluded.name, item_class = excluded.item_class,
              site_id = excluded.site_id,$o$,
    $n$          -- A plan updated without naming its product keeps the one it had
          -- (found on review: it became a plan for everything).
          set name = excluded.name,
              item_id = case when p ? 'item' then excluded.item_id else ip_t.item_id end,
              item_class = excluded.item_class,
              site_id = excluded.site_id,$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$promote$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. Which plan applies
-- ─────────────────────────────────────────────────────────────────────────────

-- The plan for a product at a site: tied to the site before one that is not,
-- to the product before its class, and to its class before everything. A
-- trigger point narrows it; null takes any, a manual one first among equals.
create or replace function erp.inspection_plan_for(p_item_id uuid, p_site_id uuid, p_trigger text default null)
returns uuid
language sql
stable
set search_path = ''
as $$
  select p.id
    from erp.inspection_plan p
    left join erp.item i on i.tenant_id = p.tenant_id and i.id = p_item_id
   where p.tenant_id = erp.current_tenant_id() and p.status = 'active'
     and (p_trigger is null or p.trigger_point = p_trigger)
     and (p.site_id is null or p.site_id = p_site_id)
     and (p.item_id = p_item_id or (p.item_id is null and p.item_class = i.item_class)
          or (p.item_id is null and p.item_class is null))
   -- The most specific plan first, whatever its trigger; manual only breaks a
   -- tie (found on review: a spot check for everything outranked the
   -- product's own plan).
   order by (p.site_id is not null) desc, (p.item_id is not null) desc, (p.item_class is not null) desc,
            (p.trigger_point = 'manual') desc, p.code
   limit 1
$$;

revoke all on function erp.inspection_plan_for(uuid, uuid, text) from public, anon;

comment on function erp.inspection_plan_for(uuid, uuid, text) is
  'The inspection plan for a product at a site: tied to the site first, then to the product, '
  'its class, and everything; at the trigger point given, or at any, manual first among equals (20260925300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The door
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.request_inspection(
  p_site_id uuid, p_batch_id uuid default null, p_item_id uuid default null,
  p_quantity numeric default null, p_plan_id uuid default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity uuid;
  v_item   uuid := p_item_id;
  v_qty    numeric := p_quantity;
  pl       erp.inspection_plan%rowtype;
  v_class  text;
  v_id     uuid;
begin
  select s.entity_id into v_entity from erp.site s where s.tenant_id = v_tenant and s.id = p_site_id;
  if v_entity is null then
    raise exception 'CLOVEERP_UNKNOWN_SITE: %', p_site_id using errcode = '23503';
  end if;

  perform erp.authorise('quality.inspect', v_entity, p_site_id, null, 'batch', p_batch_id);

  if p_batch_id is not null then
    select b.item_id into v_item from erp.batch b where b.tenant_id = v_tenant and b.id = p_batch_id;
    if v_item is null or (p_item_id is not null and p_item_id <> v_item) then
      raise exception 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: the batch is not of the product named, or is not this organisation''s'
        using errcode = '23514', hint = 'Choose the batch, or the product, to inspect.';
    end if;
  end if;
  if v_item is null then
    raise exception 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: nothing was named to inspect'
      using errcode = '22023', hint = 'Choose the batch, or the product, to inspect.';
  end if;

  -- A batch is inspected where it is held (found on review: an inspection at a
  -- site holding none of it gated nothing), and a batch-controlled product is
  -- inspected by the batch, since nothing else stands between it and release.
  if p_batch_id is not null then
    if not exists (select 1 from erp.stock_balance sb
                    where sb.tenant_id = v_tenant and sb.batch_id = p_batch_id
                      and sb.site_id = p_site_id and sb.quantity > 0) then
      raise exception 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: none of the batch is held at this site'
        using errcode = '23514', hint = 'Choose the site that holds the batch.';
    end if;
    -- What is there to inspect, where nobody said.
    if v_qty is null then
      select coalesce(sum(sb.quantity), 0) into v_qty
        from erp.stock_balance sb
       where sb.tenant_id = v_tenant and sb.batch_id = p_batch_id and sb.site_id = p_site_id and sb.quantity > 0;
    end if;
    -- A rejected batch is dealt with as rejected, not inspected again until
    -- something accepts it (found on review: an empty inspection accepted
    -- overturned a reject).
    if (select ins.disposition from erp.inspection ins
         where ins.tenant_id = v_tenant and ins.batch_id = p_batch_id
           and ins.status <> 'cancelled' and ins.disposition <> 'pending'
         order by coalesce(ins.disposition_at, ins.completed_at, ins.created_at) desc, ins.created_at desc, ins.id
         limit 1) in ('reject', 'destroy') then
      raise exception 'CLOVEERP_BATCH_REJECTED: the batch was last dispositioned rejected, and is dealt with as rejected, not inspected again'
        using errcode = '23514',
              hint = 'Quarantine it until it is dealt with as rejected. A batch reworked is received or made again as a batch of its own.';
    end if;
  elsif exists (select 1 from erp.item i where i.tenant_id = v_tenant and i.id = v_item and i.is_batch_controlled) then
    raise exception 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: a batch-controlled product is inspected by the batch'
      using errcode = '22023', hint = 'Choose the batch to inspect.';
  end if;
  if coalesce(v_qty, 0) <= 0 then
    raise exception 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: there is nothing of it here to inspect'
      using errcode = '22023', hint = 'Give the quantity to inspect, or choose a batch held at this site.';
  end if;

  if p_plan_id is not null then
    select i.item_class into v_class from erp.item i where i.tenant_id = v_tenant and i.id = v_item;
    select * into pl from erp.inspection_plan p
     where p.tenant_id = v_tenant and p.id = p_plan_id and p.status = 'active'
       and (p.site_id is null or p.site_id = p_site_id)
       and (p.item_id = v_item or (p.item_id is null and p.item_class = v_class)
            or (p.item_id is null and p.item_class is null));
    if not found then
      raise exception 'CLOVEERP_INSPECTION_PLAN_DOES_NOT_APPLY: that plan does not cover this product at this site'
        using errcode = '23514',
              hint = 'Choose one of the plans offered for the batch, or leave the plan empty and the one that applies is used.';
    end if;
  else
    select * into pl from erp.inspection_plan p
     where p.id = erp.inspection_plan_for(v_item, p_site_id, null);
    if not found then
      raise exception 'CLOVEERP_NO_INSPECTION_PLAN: no inspection plan covers % at this site',
        (select i.code from erp.item i where i.id = v_item)
        using errcode = '23514',
              hint = 'Promote an inspection plan for the product, its class or everything on the Configuration screen, then ask again.';
    end if;
  end if;

  if exists (
       select 1 from erp.inspection ins
        where ins.tenant_id = v_tenant and ins.site_id = p_site_id
          and ins.status <> 'cancelled' and ins.disposition = 'pending'
          and (ins.batch_id = p_batch_id
               or (p_batch_id is null and ins.batch_id is null and ins.item_id = v_item))) then
    raise exception 'CLOVEERP_INSPECTION_ALREADY_OPEN: this has an inspection here nobody has decided'
      using errcode = '23514',
            hint = 'Record the results of the open inspection and decide it, then ask again if another is needed.';
  end if;

  insert into erp.inspection (
    tenant_id, entity_id, site_id, inspection_plan_id, item_id, batch_id,
    document_id, quantity_inspected, sample_size, status, started_at)
  values (v_tenant, v_entity, p_site_id, pl.id, v_item, p_batch_id, null, v_qty,
          -- A whole number of units, rounded up: a sample of a lot under one
          -- unit is the lot, not nothing (found on review).
          greatest(ceil(erp.sample_size(pl.sampling_rule, v_qty)), 1)::integer, 'planned', now())
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function erp.request_inspection(uuid, uuid, uuid, numeric, uuid) from public, anon;

comment on function erp.request_inspection(uuid, uuid, uuid, numeric, uuid) is
  'Opens an inspection of a batch, or of a product at a site, against the plan named or the one '
  'that applies; authorises quality.inspect. Moves no stock (20260925300000).';

create or replace function public.erp_raise_inspection(
  p_site_id uuid, p_batch_id uuid default null, p_item_id uuid default null,
  p_quantity numeric default null, p_plan_id uuid default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.request_inspection(p_site_id, p_batch_id, p_item_id, p_quantity, p_plan_id) $$;

comment on function public.erp_raise_inspection(uuid, uuid, uuid, numeric, uuid) is
  'Inspect a batch, or a product at a site, against a plan: erp.request_inspection (20260925300000).';

create or replace function public.erp_inspection_plans(
  p_batch_id uuid default null, p_item_id uuid default null, p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with subject as (
    select coalesce((select b.item_id from erp.batch b
                      where b.tenant_id = erp.current_tenant_id() and b.id = p_batch_id), p_item_id) as item_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'inspection_plan_id', p.id, 'code', p.code, 'name', p.name,
           'trigger_point', p.trigger_point,
           'applies_to', coalesce((select i.code from erp.item i where i.id = p.item_id), p.item_class, 'everything'))
         order by (p.site_id is not null) desc, (p.item_id is not null) desc, (p.item_class is not null) desc,
                  (p.trigger_point = 'manual') desc, p.code), '[]'::jsonb)
    from erp.inspection_plan p, subject s
    left join erp.item i on i.tenant_id = erp.current_tenant_id() and i.id = s.item_id
   where p.tenant_id = erp.current_tenant_id() and p.status = 'active'
     and (p_site_id is null or p.site_id is null or p.site_id = p_site_id)
     and (s.item_id is null
          or p.item_id = s.item_id or (p.item_id is null and p.item_class = i.item_class)
          or (p.item_id is null and p.item_class is null))
$$;

comment on function public.erp_inspection_plans(uuid, uuid, uuid) is
  'The inspection plans that cover a batch or product at a site, manual ones first (20260925300000).';

do $$
declare f text;
begin
  foreach f in array array[
    'erp_raise_inspection(uuid, uuid, uuid, numeric, uuid)',
    'erp_inspection_plans(uuid, uuid, uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_raise_inspection', 'erp.request_inspection',
   'Opens an inspection of a batch or a product against an inspection plan, moving no stock; authorises quality.inspect.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/quality', array['erp_raise_inspection']);

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. A batch nobody sampled is released without a signed statement
--
-- Sampled means an inspection of the batch against a plan that nobody
-- cancelled, or a release naming an inspection. The demand for a basis and a signature stays exactly
-- where it was, first, for those; for the rest the release records that no
-- plan sampled the batch, and the signature if one was given.
-- ─────────────────────────────────────────────────────────────────────────────

do $release$
declare
  v_sig constant text := 'erp.release_batch(uuid,uuid,text,text,uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$p_basis text, p_signature text, p_inspection_id uuid DEFAULT NULL::uuid)$o$,
    $n$p_basis text DEFAULT NULL::text, p_signature text DEFAULT NULL::text, p_inspection_id uuid DEFAULT NULL::uuid)$n$,
    $o$  v_disp   erp.disposition;
begin$o$,
    $n$  v_disp   erp.disposition;
  v_sampled boolean;
begin$n$,
    $o$  if coalesce(p_signature, '') = '' or coalesce(p_basis, '') = '' then
    raise exception
      'CLOVEERP_RELEASE_NEEDS_BASIS_AND_SIGNATURE: a qualified release is a '
      'signed statement, not a status change'
      using errcode = '23514';
  end if;$o$,
    $n$  -- Sampled: an inspection of the batch against a plan, that nobody
  -- cancelled (20260925300000). Only then is the release a signed statement.
  -- Any plan's inspection counts, whatever sample it stored, and so does a
  -- release that names one (found on review: a lot under half a unit stored a
  -- sample of nought and was released unsigned).
  v_sampled := p_inspection_id is not null or exists (
    select 1 from erp.inspection ins
     where ins.tenant_id = v_tenant and ins.batch_id = p_batch_id
       and ins.status <> 'cancelled' and ins.inspection_plan_id is not null);

  if v_sampled and (coalesce(btrim(p_signature), '') = '' or coalesce(btrim(p_basis), '') = '') then
    raise exception
      'CLOVEERP_RELEASE_NEEDS_BASIS_AND_SIGNATURE: batch % was sampled by an inspection plan, and its '
      'release is a signed statement, not a status change', b.batch_number
      using errcode = '23514',
            hint = 'Give the basis for the release, such as the inspection or certificate relied on, and sign it with your full name.';
  end if;$n$,
    $o$          'quality.release_batch', jsonb_build_object('statement', p_basis),
          p_inspection_id, p_signature)$o$,
    $n$          'quality.release_batch',
          jsonb_build_object('statement', coalesce(nullif(btrim(p_basis), ''), 'No inspection plan sampled this batch'),
                             'sampled', v_sampled),
          p_inspection_id, nullif(btrim(p_signature), ''))$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$release$;

create or replace function public.erp_release_batch(p_batch_id uuid, p_site_id uuid, p_basis text default null,
                                                    p_signature text default null, p_inspection_id uuid default null)
returns uuid
language sql
set search_path = ''
as $$ select erp.release_batch(p_batch_id, p_site_id, p_basis, p_signature, p_inspection_id) $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. What the Quality screen says
-- ─────────────────────────────────────────────────────────────────────────────

update erp_meta.flow_budget
   set rationale = 'Today''s cost. An inspection is asked for from the actions (20260925300000), not a stage: the '
                || 'ordinary one is raised by what happened to the stock.'
 where flow_code = 'quality';

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). An inspection asked for, and a release that asks for a signature only where a plan sampled the batch (20260925300000).'
  from (values
    ('Raise an inspection'),
    ('Inspect a batch where it is held, against its inspection plan. The batch waits for the result before it is released.'),
    ('Inspection plan'),
    ('Leave empty and the plan that covers the product is used.'),
    ('Quantity to inspect'),
    ('Leave empty to inspect what the batch holds here.'),
    ('Needed where an inspection plan sampled the batch. What you relied on to decide.'),
    ('Needed where an inspection plan sampled the batch. Typed in full; it is kept against the release.'),
    ('Inspections appear here once a receipt needs inspecting, or when one is asked for from the actions.')
  ) v(text)
on conflict (key, locale) do update set value = excluded.value;

delete from erp_ref.resource
 where key in (erp_ref.ui_key('Inspections appear here once an event is reported or a receipt needs inspecting.'),
               erp_ref.ui_key('What you relied on to decide.'),
               erp_ref.ui_key('Typed in full. It is kept against the release.'));

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.quality_suite
--
-- The suite the spec names for M6, which did not exist. M6b adds the floor's
-- cases to it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.quality_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex   text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1 uuid := gen_random_uuid(); a2 uuid := gen_random_uuid();
  a3 uuid := gen_random_uuid(); a4 uuid := gen_random_uuid();
  r       record;
  res     jsonb;
  v_tok2 text; v_tok3 text; v_tok4 text;
  v_second uuid; v_inspector uuid; v_planner uuid;
  csf uuid; csp uuid; csi uuid; csq uuid; v_cs uuid;
  v_uom uuid; v_site uuid; v_recv uuid; v_quar uuid; v_sup uuid;
  v_chill uuid; v_amb uuid; v_b1 uuid; v_b2 uuid; v_ba uuid; v_grn uuid;
  v_goods_in uuid; v_insp uuid; v_mine uuid; v_rel uuid;
  v_kg uuid; v_loose uuid; v_fine uuid; v_b3 uuid; v_b4 uuid; v_two uuid; v_insp3 uuid; v_insp4 uuid;
  v_err text; v_err2 text;
begin
  begin
    select * into r from erp.provision_tenant(
      'zz-qs-' || v_hex, 'Quality suite', 'a@zz-qs-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-qs-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok2 := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('inspector@zz-qs-' || v_hex || '.test', 'Inspector');
    v_inspector := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    perform erp.grant_role(v_inspector, 'quality', null, null, 'inspects');
    res := public.erp_invite_principal('planner@zz-qs-' || v_hex || '.test', 'Planner');
    v_planner := (res ->> 'app_user_id')::uuid; v_tok4 := res ->> 'token';
    perform erp.grant_role(v_planner, 'planning', null, null, 'does not inspect');
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    csq := erp.configure_quality('4 hours', '24 hours');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok2);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform erp.approve_change_set(csq); perform erp.promote_change_set(csq);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    perform erp.claim_invitation(v_tok4);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    select ip.id into v_goods_in from erp.inspection_plan ip
     where ip.tenant_id = r.tenant_id and ip.code = 'goods_in';

    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Receiving', 'receiving', 'active') returning id into v_recv;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'QUAR', 'Quarantine', 'quarantine', 'active') returning id into v_quar;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    -- One item quarantined on receipt, one not.
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, quarantine_on_receipt, status)
    values (r.tenant_id, 'CHILL', 'Chilled thing', v_uom, true, true, 'active') returning id into v_chill;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, quarantine_on_receipt, status)
    values (r.tenant_id, 'AMB', 'Ambient thing', v_uom, true, false, 'active') returning id into v_amb;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_chill, 'B-001', 'quarantine', current_date, current_date + 60) returning id into v_b1;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_chill, 'B-002', 'quarantine', current_date, current_date + 60) returning id into v_b2;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_amb, 'A-001', 'released', current_date, current_date + 60) returning id into v_ba;

    -- B-001 into quarantine, sampled by the receipt; A-001 onto the shelf.
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_chill, 100, 1000, 'chilled');
    update erp.document_line set batch_id = v_b1, location_id = v_quar where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    select ins.id into v_insp from erp.inspection ins where ins.batch_id = v_b1 limit 1;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_amb, 100, 1000, 'ambient');
    update erp.document_line set batch_id = v_ba, location_id = v_recv where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');

    -- 1. Somebody who does not inspect is refused; an inspector is not.
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    begin perform public.erp_raise_inspection(v_site, v_ba); v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 120); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    begin v_mine := public.erp_raise_inspection(v_site, v_ba, null, null, v_goods_in); v_err2 := 'raised';
    exception when others then v_err2 := left(sqlerrm, 120); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'an inspection is asked for by somebody who inspects, and nobody else',
      v_err like 'CLOVEERP_PERMISSION_DENIED:%' and v_err2 = 'raised' and v_mine is not null,
      format('%s | %s', v_err, v_err2);

    -- 2. Against a plan named, sampled by its rule, and nothing moved.
    return query select 'a batch is inspected against the plan named, sampled by its rule, with its stock where it was',
      (select ins.inspection_plan_id = v_goods_in and ins.sample_size = 11 and ins.quantity_inspected = 100
              and ins.status = 'planned' and ins.disposition = 'pending' and ins.batch_id = v_ba
         from erp.inspection ins where ins.id = v_mine)
      and (select sum(sb.quantity) from erp.stock_balance sb
            where sb.batch_id = v_ba and sb.stock_status = 'available') = 100
      and jsonb_array_length(public.erp_inspection_plans(v_ba, null, v_site)) >= 1,
      (select format('sample %s of %s', ins.sample_size, ins.quantity_inspected) from erp.inspection ins where ins.id = v_mine);

    -- 3. Not twice, and not where no plan covers it.
    begin perform public.erp_raise_inspection(v_site, v_b1); v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 120); end;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status)
    values (r.tenant_id, 'LOOSE', 'Not batch-controlled', v_uom, 'active') returning id into v_loose;
    update erp.inspection_plan set status = 'inactive' where id = v_goods_in;
    begin perform public.erp_raise_inspection(v_site, null, v_loose, 5); v_err2 := 'raised';
    exception when others then v_err2 := left(sqlerrm, 120); end;
    return query select 'a batch with an inspection open is not given a second, and a product no plan covers is refused',
      v_err like 'CLOVEERP_INSPECTION_ALREADY_OPEN:%' and v_err2 like 'CLOVEERP_NO_INSPECTION_PLAN:%',
      format('%s | %s', v_err, v_err2);

    -- 4. A batch of one product named as another; a batch-controlled product
    -- without its batch; and a batch where it is not held.
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'TWO', 'Second', 'warehouse', 'active') returning id into v_two;
    begin perform public.erp_raise_inspection(v_site, v_ba, v_chill); v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 120); end;
    begin perform public.erp_raise_inspection(v_site, null, v_amb, 5); v_err2 := 'raised';
    exception when others then v_err2 := left(sqlerrm, 120); end;
    return query select 'a batch named with another product, a batch-controlled product without its batch, and a batch where it is not held are refused',
      v_err like 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT:%' and v_err2 like 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT:%'
      and (select count(*) from erp.inspection ins where ins.site_id = v_two) = 0,
      format('%s | %s', v_err, v_err2);
    begin perform public.erp_raise_inspection(v_two, v_b1, null, 5); v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'a batch is not inspected at a site that holds none of it',
      v_err like 'CLOVEERP_INSPECTION_NEEDS_A_SUBJECT: none of the batch is held at this site%', v_err;

    -- 5. Quarantined, and no plan sampled it: released without a signed
    -- statement, and the release says why.
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_chill, 40, 1000, 'chilled, no plan');
    update erp.document_line set batch_id = v_b2, location_id = v_quar where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    update erp.inspection_plan set status = 'active' where id = v_goods_in;
    v_rel := public.erp_release_batch(v_b2, v_site);
    return query select 'a batch no plan sampled is released without a basis or a signature, and the release says so',
      not exists (select 1 from erp.inspection ins where ins.batch_id = v_b2)
      and (select rr.basis ->> 'sampled' = 'false' and rr.signature is null
                  and rr.basis ->> 'statement' = 'No inspection plan sampled this batch'
             from erp.release_record rr where rr.id = v_rel)
      and (select sum(sb.quantity) from erp.stock_balance sb
            where sb.batch_id = v_b2 and sb.stock_status = 'available') = 40,
      (select rr.basis::text from erp.release_record rr where rr.id = v_rel);

    -- 6. Sampled: still a signed statement, first.
    perform erp.record_inspection_result(v_insp, 'temperature', 3);
    perform erp.record_inspection_result(v_insp, 'packaging', null, 'intact');
    perform erp.disposition_inspection(v_insp, 'accept', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin perform public.erp_release_batch(v_b1, v_site, null, null, v_insp); v_err := 'released';
    exception when others then v_err := left(sqlerrm, 120); end;
    v_rel := public.erp_release_batch(v_b1, v_site, 'Goods-in inspection accepted', 'Second Admin', v_insp);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a batch a plan sampled is still refused without a basis and a signature, and released with them',
      v_err like 'CLOVEERP_RELEASE_NEEDS_BASIS_AND_SIGNATURE:%'
      and (select rr.basis ->> 'sampled' = 'true' and rr.signature = 'Second Admin'
             from erp.release_record rr where rr.id = v_rel),
      v_err;

    -- 6b. A rejected batch is not inspected again to overturn it.
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_chill, 'B-003', 'quarantine', current_date, current_date + 60) returning id into v_b3;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_chill, 20, 1000, 'chilled, warm');
    update erp.document_line set batch_id = v_b3, location_id = v_quar where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    select ins.id into v_insp3 from erp.inspection ins where ins.batch_id = v_b3 limit 1;
    perform erp.record_inspection_result(v_insp3, 'temperature', 9);
    perform erp.record_inspection_result(v_insp3, 'packaging', null, 'intact');
    perform erp.disposition_inspection(v_insp3, 'reject', 'Arrived warm');
    begin perform public.erp_raise_inspection(v_site, v_b3); v_err := 'raised';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'a rejected batch is not inspected again, so no empty inspection can overturn the reject',
      v_err like 'CLOVEERP_BATCH_REJECTED:%', v_err;

    -- 6c. A lot too small for a whole sample was still sampled.
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'KG', 'Kilogram', 'mass', 3, true, 'active') returning id into v_kg;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, quarantine_on_receipt, status)
    values (r.tenant_id, 'FINE', 'Fine powder', v_kg, true, true, 'active') returning id into v_fine;
    insert into erp.batch (tenant_id, item_id, batch_number, status, manufactured_on, expires_on)
    values (r.tenant_id, v_fine, 'P-001', 'quarantine', current_date, current_date + 60) returning id into v_b4;
    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, v_fine, 0.4, 1000, 'a pinch');
    update erp.document_line set batch_id = v_b4, location_id = v_quar where document_id = v_grn;
    perform erp.transition_document(v_grn, 'post');
    select ins.id into v_insp4 from erp.inspection ins where ins.batch_id = v_b4 limit 1;
    perform erp.record_inspection_result(v_insp4, 'temperature', 3);
    perform erp.record_inspection_result(v_insp4, 'packaging', null, 'intact');
    perform erp.disposition_inspection(v_insp4, 'accept', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    begin perform public.erp_release_batch(v_b4, v_site, null, null, v_insp4); v_err := 'released';
    exception when others then v_err := left(sqlerrm, 120); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a lot under a unit, inspected against a plan, is still released only on a signed statement',
      v_err like 'CLOVEERP_RELEASE_NEEDS_BASIS_AND_SIGNATURE:%', v_err;

    -- 7. A trigger point nothing reads is refused.
    begin
      insert into erp.inspection_plan (tenant_id, code, name, trigger_point, sampling_rule, characteristics, status)
      values (r.tenant_id, 'weekly', 'Weekly', 'weekly', '{"scheme":"fixed","size":1}'::jsonb, '[]'::jsonb, 'active');
      v_err := 'written';
    exception when others then v_err := left(sqlerrm, 120); end;
    return query select 'a plan with a trigger point nothing reads is refused',
      v_err like '%inspection_plan_trigger_known%', v_err;

    -- 8. A promoted plan names its product, and one naming a product the
    -- organisation lacks is refused.
    v_cs := erp.create_change_set('qs-plan-' || v_hex, 'A plan for chilled goods', 'The suite promotes a plan.');
    perform erp.add_change_set_item(v_cs, 'inspection_plan', 'chilled_in',
      jsonb_build_object('code', 'chilled_in', 'name', 'Chilled goods in', 'item', 'CHILL',
                         'trigger_point', 'receipt',
                         'sampling_rule', jsonb_build_object('scheme', 'fixed', 'size', 3),
                         'characteristics', '[]'::jsonb), 'upsert', null, 'suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    v_cs := erp.create_change_set('qs-bad-' || v_hex, 'A plan for nothing', 'The suite promotes a plan for a product nobody has.');
    perform erp.add_change_set_item(v_cs, 'inspection_plan', 'ghost_in',
      jsonb_build_object('code', 'ghost_in', 'name', 'Ghost goods in', 'item', 'GHOST', 'trigger_point', 'receipt'),
      'upsert', null, 'suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
      perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
      v_err := 'promoted';
    exception when others then v_err := left(sqlerrm, 120); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    -- Promoted again without naming its product, it keeps it.
    v_cs := erp.create_change_set('qs-again-' || v_hex, 'A larger sample', 'The suite promotes the plan again.');
    perform erp.add_change_set_item(v_cs, 'inspection_plan', 'chilled_in',
      jsonb_build_object('code', 'chilled_in', 'name', 'Chilled goods in', 'trigger_point', 'receipt',
                         'sampling_rule', jsonb_build_object('scheme', 'fixed', 'size', 5),
                         'characteristics', '[]'::jsonb), 'upsert', null, 'suite');
    perform erp.submit_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.approve_change_set(v_cs); perform erp.promote_change_set(v_cs);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a promoted inspection plan names its product, keeps it when promoted again without it, and one naming a product the organisation lacks is refused',
      (select ip.item_id = v_chill and ip.sampling_rule ->> 'size' = '5'
         from erp.inspection_plan ip where ip.tenant_id = r.tenant_id and ip.code = 'chilled_in')
      and erp.inspection_plan_for(v_chill, v_site, 'receipt')
          = (select ip.id from erp.inspection_plan ip where ip.tenant_id = r.tenant_id and ip.code = 'chilled_in')
      and v_err like '%CLOVEERP_UNKNOWN_ITEM:%',
      v_err;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-qs-' || v_hex);
  detail := 'the organisation, its batches, inspections and releases rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.quality_suite() from public, anon;

create or replace function erp_test.assert_quality_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.quality_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_QUALITY_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'An inspection nobody can ask for, a plan that cannot name its product, or a release that asks a clean batch for a signature, is the case that failed. Read it.';
  end if;
  if v_total <> 12 then
    raise exception 'CLOVEERP_QUALITY_SUITE_SHRANK: % case(s), expected 12', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_quality_suite() from public, anon;

comment on function erp_test.assert_quality_suite() is
  'An inspection is asked for by somebody who inspects, against a plan that covers the product; a '
  'promoted plan names its product; and a batch is released on a signed statement only where a plan '
  'sampled it (20260925300000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
