set lock_timeout = '30s';

-- =============================================================================
-- 20260920620000  A seeded role a customer edited is theirs
-- -----------------------------------------------------------------------------
-- The base pack ships role templates, and a role it made carries the mark of
-- the template it came from. On 14 September that mark was taught to protect a
-- role the pack did NOT make: the administrator provisioning creates, or a role
-- the organisation built for itself, is added to and never replaced.
--
-- It protects nothing in the other direction. A role the pack DID make is
-- replaced wholesale every time the pack is applied again — its grant set
-- deleted and rewritten, and its name overwritten with the template's. So an
-- organisation that took the pack's Buyer, renamed it to "Purchasing officer"
-- and took a permission off it got both changes silently undone the next time
-- anybody pressed the button on Features and content. Nothing warned them,
-- nothing recorded it, and the preview said "updates" as though the product
-- were bringing them something.
--
-- That is the same defect the module upgrade planner had once, wearing the
-- other face. That one decided a rule was already held by its code and dropped
-- a revised one from the plan. This one decides a role is the template's
-- because the template made it, and drops the organisation's work.
--
-- The mark alone cannot tell the difference, because it records WHICH template
-- and never WHAT the template gave. So this records what it gave:
--
--   erp.role.template_digest — a digest of the grant set as the template wrote
--   it, stamped when a pack promotion lands the role.
--
-- Untouched means the digest of the grants as they stand still equals the one
-- recorded, and a later version of the template may land. Different means
-- somebody has made the role their own: the pack leaves it alone and says so in
-- the plan rather than omitting it, because a plan that quietly skips a role is
-- the same defect in a quieter hat.
--
-- The name is deliberately outside the digest. Renaming is allowed and is not a
-- modification, so a rename must never make a role look edited. It does not:
-- the digest covers the permission codes and the data classes they are narrowed
-- to, and nothing else. And the planner now offers a template against the name
-- the organisation gave, so applying a newer template keeps that name instead
-- of resetting it.
--
-- Roles seeded before today. Their digest is null, and null is read as changed
-- by hand. What the template gave them cannot be recovered — the record did not
-- exist — and the two ways of being wrong are not equal. Treating an untouched
-- role as modified costs one line in a plan saying it was left alone. Treating
-- a modified role as untouched destroys work the customer did, and cannot be
-- undone except from a snapshot nobody knew to take. So no row is rewritten
-- here: the three live organisations keep every role exactly as it stands, and
-- each pack-made role among them is protected until somebody applies a pack and
-- it is stamped as it lands.
--
-- Nothing else changes. A change set that is not a pack's — a promotion from
-- another environment, a rollback — still describes the whole role and still
-- replaces it wholesale, because that is what those are for. The role arm of
-- the promoter is not touched at all.
--
-- What this costs a live database: one nullable column on erp.role, which is
-- one row per role per organisation and no rewrite of any of them. The stamping
-- runs inside the promotion window the promoter already opens, over the roles
-- of one change set, and only for a change set that installs a pack.
--
-- Proof: erp_test.seeded_role_is_theirs_suite(), six cases, pinned at both ends.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What the template gave
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.role add column if not exists template_digest text;

comment on column erp.role.template_digest is
  'A digest of this role''s permission grants as the starter template last '
  'wrote them, stamped when a pack promotion lands the role. The grants as they '
  'stand still matching it means nobody has changed the role, and a later '
  'version of the template may land on it. Not matching means the organisation '
  'has made the role its own and a pack leaves it alone. Null where a template '
  'wrote the role before this was recorded, which is read the same way as '
  'changed: what the template gave cannot be recovered, and assuming it was '
  'untouched would destroy the organisation''s work. The role''s name is '
  'deliberately outside the digest, because renaming is allowed and is not a '
  'change.';

create or replace function erp.role_grant_digest(p_role_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  -- Ordered, so the digest is a property of the grant set and not of the order
  -- the rows happen to sit in. The data classes are in it because a grant
  -- narrowed to one class is a different grant.
  select md5(coalesce(
           string_agg(rp.permission_code || ' ' ||
                      array_to_string(rp.data_classes, ','),
                      E'\n' order by rp.permission_code,
                                     array_to_string(rp.data_classes, ',')),
           ''))
    from erp.role_permission rp
   where rp.role_id = p_role_id
$$;

comment on function erp.role_grant_digest(uuid) is
  'A digest of one role''s permission grants, each with the data classes it is '
  'narrowed to, in a fixed order. Compared with the digest recorded when a '
  'starter template last wrote the role, to tell a role nobody has touched from '
  'one the organisation has made its own.';

create or replace function erp.role_is_changed_by_hand(p_role_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A role with no template mark was never a template's, and the rule of 14
  -- September already protects it; this is only about roles a template made. A
  -- null recorded digest is one written before the record existed, and is read
  -- as changed on purpose.
  select exists (
    select 1 from erp.role r
     where r.id = p_role_id
       and r.from_template is not null
       and r.template_digest is distinct from erp.role_grant_digest(r.id))
$$;

comment on function erp.role_is_changed_by_hand(uuid) is
  'True where a role a starter template made no longer holds the grants that '
  'template gave it, so the organisation has made it its own and a pack must '
  'leave it alone. True as well where nothing was ever recorded for it, because '
  'what it was given cannot be recovered and the safe reading is the one that '
  'keeps the organisation''s work. Renaming a role never makes this true.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The planner offers against the name the organisation gave, and names what
--    it is leaving alone
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Two needles into the body the database carries, each asserted to occur
-- exactly once. The first carries the select list and the joins, so the role
-- the organisation holds is in scope for the second.

do $planner$
declare
  v_sig constant text := 'erp.plan_content_pack(text)';
  v_def text := pg_get_functiondef('erp.plan_content_pack(text)'::regprocedure);
  v_n1  constant text := $n$  select i.object_kind, i.object_key, i.operation, i.effective_payload,
         case when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
$n$;
  v_r1  constant text := $r$  select i.object_kind, i.object_key, i.operation,
         -- A template role is offered against the name this organisation gave
         -- it (20260920620000). Renaming is allowed and is not a modification,
         -- so landing a newer template must not reset the label.
         case when i.object_kind = 'role' and held.name is not null
              then i.effective_payload || jsonb_build_object('name', held.name)
              else i.effective_payload end,
         -- And a template role the organisation has changed is named in the
         -- plan as one this pack will not touch. Said rather than omitted: a
         -- plan that silently drops a role is the defect this replaced.
         case when i.object_kind = 'role' and erp.role_is_changed_by_hand(held.id)
              then 'left alone, because this organisation has changed it'
              when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
    left join erp.role held
      on i.object_kind = 'role'
     and held.tenant_id = erp.require_tenant_id()
     and held.code = i.object_key
     and held.status = 'active'
$r$;
  v_n2  constant text := $n$   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)$n$;
  v_r2  constant text := $r$   where not (coalesce(m.content, '{}'::jsonb) @>
              case when i.object_kind = 'role' and held.name is not null
                   then i.effective_payload || jsonb_build_object('name', held.name)
                   else i.effective_payload end)$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner does not build its result the way this migration patches'
      using hint = 'A later migration changed the planner. Read the definition the database carries and write the needle against that.';
  end if;
  v_def := replace(v_def, v_n1, v_r1);

  if (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner does not test containment the way this migration patches'
      using hint = 'A later migration changed the planner. Read the definition the database carries and write the needle against that.';
  end if;
  v_def := replace(v_def, v_n2, v_r2);

  execute v_def;

  if position('left alone, because this organisation has changed it'
              in pg_get_functiondef('erp.plan_content_pack(text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PLANNER_UNRECOGNISED: the pack planner did not take the rule about a role somebody has changed'
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$planner$;

comment on function erp.plan_content_pack is
  'What applying this pack would add to this organisation, and nothing it '
  'already holds — by containment against the configuration manifest, and by '
  'the pack history for the master-data kinds the manifest deliberately omits. '
  'Capability-gated items are left out when their capability is off; a '
  'decision that has been answered carries the answer. A role is offered '
  'against the name the organisation gave it, so renaming one never makes it '
  'look missing; and a role the organisation has changed since a template '
  'wrote it is listed as left alone rather than dropped from the plan.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. And what the plan says is what lands
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The plan is the preview and the change set is built from it, so the one place
-- that reads the plan has to honour what it says. Anything else would show a
-- reader "left alone" and then take the role anyway.

do $applier$
declare
  v_def text := pg_get_functiondef('erp.apply_content_pack(text,text)'::regprocedure);
  v_n   constant text := $n$  for r in select * from erp.plan_content_pack(p_pack_code) loop
    perform erp.add_change_set_item(v_cs, r.object_kind, r.object_key,
                                    r.payload, r.operation, null,
                                    format('%s %s', p_pack_code, cp.version));
    n := n + 1;
  end loop;
$n$;
  v_r   constant text := $r$  for r in select * from erp.plan_content_pack(p_pack_code) loop
    -- A role this organisation has changed since a template wrote it is in the
    -- plan so that somebody can see it was considered, and is not in the change
    -- set because it is theirs now (20260920620000).
    continue when r.effect like 'left alone,%';
    perform erp.add_change_set_item(v_cs, r.object_kind, r.object_key,
                                    r.payload, r.operation, null,
                                    format('%s %s', p_pack_code, cp.version));
    n := n + 1;
  end loop;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PACK_APPLIER_UNRECOGNISED: applying a pack does not build its change set the way this migration patches'
      using hint = 'A later migration changed it. Read the definition the database carries and write the needle against that.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('continue when r.effect like ''left alone,%'';'
              in pg_get_functiondef('erp.apply_content_pack(text,text)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PACK_APPLIER_UNRECOGNISED: applying a pack did not take the rule about a role somebody has changed'
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$applier$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What the template gave is recorded as it lands
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Stamped where the pack is recorded as applied: inside the promotion window
-- the promoter already opened, after every item of the change set has been
-- applied, so the grants read here are exactly the ones the template wrote.
-- Only for a change set that installs a pack — a promotion from another
-- environment or a rollback is not a template speaking, and must not be
-- mistaken for one.

do $stamp$
declare
  v_def text := pg_get_functiondef('erp.promote_change_set(uuid,text[],boolean)'::regprocedure);
  v_n   constant text := $n$  update erp.tenant_pack
     set status = 'applied', applied_at = now(), updated_at = now()
   where tenant_id = v_tenant and change_set_id = p_change_set_id
     and status = 'planned';
$n$;
  v_r   constant text := $r$  update erp.tenant_pack
     set status = 'applied', applied_at = now(), updated_at = now()
   where tenant_id = v_tenant and change_set_id = p_change_set_id
     and status = 'planned';

  -- What the template gave, recorded as it lands (20260920620000). A later
  -- version of the pack compares this with the grants as they stand: equal
  -- means nobody has touched the role and the new version may land on it;
  -- different means the organisation has made the role its own and the pack
  -- leaves it alone. The name is outside the digest on purpose, so renaming a
  -- role never makes it look edited.
  if exists (select 1 from erp.tenant_pack tp
              where tp.tenant_id = v_tenant
                and tp.change_set_id = p_change_set_id) then
    -- The table alias is deliberately not "r": erp.promote_change_set()
    -- already declares a plpgsql variable of that name for its own item
    -- loop, and giving a SQL alias the same name resolves a qualified column
    -- against the outer plpgsql variable instead of this query's table.
    update erp.role ro
       set template_digest = erp.role_grant_digest(ro.id), updated_at = now()
      from erp.change_set_item i
     where i.tenant_id = v_tenant
       and i.change_set_id = p_change_set_id
       and i.object_kind = 'role'
       and i.object_key = ro.code
       and ro.tenant_id = v_tenant
       and ro.from_template is not null;
  end if;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter does not record an applied pack the way this migration patches'
      using hint = 'A later migration changed the promoter. Read the definition the database carries and write the needle against that.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('set template_digest = erp.role_grant_digest(ro.id)'
              in pg_get_functiondef('erp.promote_change_set(uuid,text[],boolean)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter did not take the recording of what a template gave'
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$stamp$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A pack of its own rather than the base pack, because the base pack plans
-- hundreds of items and this is about two roles. Every edit the organisation
-- makes here goes through a change set, which is the route a live organisation
-- has: its environment is live from the moment it is provisioned.

create or replace function erp_test.seeded_role_is_theirs_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $suite$
declare
  c_expected constant integer := 6;
  v_cases   integer := 0;
  v_step    text := 'before the fixture started';
  v_state   text;
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pack    text;
  r         record;
  res       jsonb;
  a1        uuid := gen_random_uuid();   -- the author
  a2        uuid := gen_random_uuid();   -- the approver: B6 refuses self-approval
  v_second  uuid; v_tok text;
  v_cs      uuid;
  v_seeded  uuid; v_legacy uuid;
  v_first_digest text; v_after_digest text;
  v_named   text; v_perms text[];
  v_effect_seeded text; v_effect_legacy text;
  v_legacy_changed boolean; v_legacy_perms text[];
  v_changed_effect text; v_changed_perms text[];
begin
  begin
  -- ── The organisation, and a pack of one role ─────────────────────────────
  v_step := 'provisioning the organisation';
  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'zzrt-' || v_tag, 'Role Templates',
    'admin@zzrt-' || v_tag || '.test', 'Template Admin');

  insert into auth.users (id, email) values
    (a1, 'admin@zzrt-' || v_tag || '.test'),
    (a2, 'second@zzrt-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);
  select p.app_user_id, p.token into v_second, v_tok
    from erp.invite_principal('second@zzrt-' || v_tag || '.test', 'Second Admin') p;
  perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.claim_invitation(v_tok);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  v_step := 'a starter pack carrying one role template';
  v_pack := 'zzpack_' || v_tag;
  insert into erp_ref.content_pack
    (code, name, description, kind, version, provenance, seq)
  values (v_pack, 'Suite template pack',
          'One role template, so that a suite can watch a template meet a role.',
          'base', '1.0.0',
          'A fixture of erp_test.seeded_role_is_theirs_suite(). Not shipped: it '
          'is created and rolled back inside the suite.', 900);
  insert into erp_ref.pack_item
    (pack_code, object_kind, object_key, payload, provenance, seq)
  values (v_pack, 'role', 'zz_seeded',
          jsonb_build_object('code', 'zz_seeded', 'name', 'Seeded role',
            'from_template', v_pack || '-1.0.0',
            'permissions', jsonb_build_array(
              jsonb_build_object('permission', 'inventory.read'),
              jsonb_build_object('permission', 'reporting.read'))),
          'A fixture of the seeded-role suite.', 10);

  -- ── 1. A pack promotion records what the template gave ───────────────────
  v_step := 'applying the pack for the first time';
  v_cases := v_cases + 1;
  res := erp.apply_content_pack(v_pack);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select ro.id, ro.template_digest into v_seeded, v_first_digest
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_seeded';
  case_name := 'a pack promotion records what the template gave the role it made';
  passed := v_seeded is not null
        and v_first_digest is not null
        and v_first_digest = erp.role_grant_digest(v_seeded)
        and not erp.role_is_changed_by_hand(v_seeded);
  detail := format('the role was made and its record is %s, which is what its grants digest to; changed by hand: %s',
                   coalesce(left(v_first_digest, 12), 'nothing'),
                   erp.role_is_changed_by_hand(v_seeded));
  return next;

  -- ── 2. A role with no record of what it was given ────────────────────────
  --
  -- The shape every role a template wrote before today is in. Made here the
  -- way one would have been: a change set that is not a pack's, carrying a
  -- template mark, so nothing stamps it.
  v_step := 'a template role nothing recorded';
  v_cases := v_cases + 1;
  v_cs := erp.create_change_set('zzlegacy-' || v_tag, 'A role from before the record',
                                'A role carrying a template mark that nothing stamped.');
  perform erp.add_change_set_item(v_cs, 'role', 'zz_legacy',
    jsonb_build_object('code', 'zz_legacy', 'name', 'Legacy role',
      'from_template', v_pack || '-1.0.0',
      'permissions', jsonb_build_array(
        jsonb_build_object('permission', 'inventory.read'),
        jsonb_build_object('permission', 'reporting.read'))),
    'upsert', null, 'the suite');
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select ro.id into v_legacy
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'zz_legacy';
  v_legacy_changed := erp.role_is_changed_by_hand(v_legacy);
  case_name := 'a role a template marked and nothing recorded is read as one the organisation has changed, because what it was given cannot be recovered';
  passed := v_legacy is not null
        and (select ro.template_digest from erp.role ro where ro.id = v_legacy) is null
        and v_legacy_changed;
  detail := format('nothing was recorded for it and it reads as changed: %s', v_legacy_changed);
  return next;

  -- ── 3. Renaming leaves it untouched, and a newer template keeps the name ──
  v_step := 'renaming the seeded role and revising the template';
  v_cases := v_cases + 1;
  v_cs := erp.create_change_set('zzrename-' || v_tag, 'The organisation renames its role',
                                'The same grants under a name the organisation chose.');
  perform erp.add_change_set_item(v_cs, 'role', 'zz_seeded',
    jsonb_build_object('code', 'zz_seeded', 'name', 'Our own name',
      'from_template', v_pack || '-1.0.0',
      'permissions', jsonb_build_array(
        jsonb_build_object('permission', 'inventory.read'),
        jsonb_build_object('permission', 'reporting.read'))),
    'upsert', null, 'the suite');
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- The template gains a permission, and the pack is offered again.
  update erp_ref.pack_item pi
     set payload = jsonb_build_object('code', 'zz_seeded', 'name', 'Seeded role',
           'from_template', v_pack || '-1.0.0',
           'permissions', jsonb_build_array(
             jsonb_build_object('permission', 'inventory.read'),
             jsonb_build_object('permission', 'reporting.read'),
             jsonb_build_object('permission', 'master_data.read')))
   where pi.pack_code = v_pack and pi.object_kind = 'role' and pi.object_key = 'zz_seeded';
  insert into erp_ref.pack_item
    (pack_code, object_kind, object_key, payload, provenance, seq)
  values (v_pack, 'role', 'zz_legacy',
          jsonb_build_object('code', 'zz_legacy', 'name', 'Legacy role',
            'from_template', v_pack || '-1.0.0',
            'permissions', jsonb_build_array(
              jsonb_build_object('permission', 'inventory.read'),
              jsonb_build_object('permission', 'reporting.read'),
              jsonb_build_object('permission', 'master_data.read'))),
          'A fixture of the seeded-role suite.', 20);

  select p.effect into v_effect_seeded from erp.plan_content_pack(v_pack) p
   where p.object_key = 'zz_seeded';
  select p.effect into v_effect_legacy from erp.plan_content_pack(v_pack) p
   where p.object_key = 'zz_legacy';

  res := erp.apply_content_pack(v_pack);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select ro.name, ro.template_digest into v_named, v_after_digest
    from erp.role ro where ro.id = v_seeded;
  select array(select rp.permission_code from erp.role_permission rp
                where rp.role_id = v_seeded order by 1) into v_perms;
  case_name := 'renaming a seeded role leaves it recognisable as untouched, so a newer template lands on it and keeps the name the organisation gave';
  passed := v_effect_seeded = 'updates'
        and v_named = 'Our own name'
        and v_perms = array['inventory.read', 'master_data.read', 'reporting.read']
        and v_after_digest = erp.role_grant_digest(v_seeded)
        and not erp.role_is_changed_by_hand(v_seeded);
  detail := format('the plan said "%s"; the role is called "%s" and holds %s; its record moved with it',
                   v_effect_seeded, v_named, array_to_string(v_perms, ', '));
  return next;

  -- ── 4. And the one nothing recorded was left alone ───────────────────────
  v_step := 'what happened to the role nothing recorded';
  v_cases := v_cases + 1;
  select array(select rp.permission_code from erp.role_permission rp
                where rp.role_id = v_legacy order by 1) into v_legacy_perms;
  case_name := 'the role nothing recorded is named in the plan as left alone, and the pack did not touch it';
  passed := v_effect_legacy = 'left alone, because this organisation has changed it'
        and v_legacy_perms = array['inventory.read', 'reporting.read'];
  detail := format('the plan said "%s"; it still holds %s rather than the three the template offered',
                   v_effect_legacy, array_to_string(v_legacy_perms, ', '));
  return next;

  -- ── 5. A role the organisation changed is left alone ─────────────────────
  v_step := 'the organisation takes a permission off its seeded role';
  v_cases := v_cases + 1;
  v_cs := erp.create_change_set('zzedit-' || v_tag, 'The organisation narrows its role',
                                'One permission taken off a role a template made.');
  perform erp.add_change_set_item(v_cs, 'role', 'zz_seeded',
    jsonb_build_object('code', 'zz_seeded', 'name', 'Our own name',
      'from_template', v_pack || '-1.0.0',
      'permissions', jsonb_build_array(
        jsonb_build_object('permission', 'inventory.read'),
        jsonb_build_object('permission', 'master_data.read'))),
    'upsert', null, 'the suite');
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  -- A role the pack has not installed yet, so that the pack still has something
  -- to do. Both the roles it made are left alone now, and a change set with
  -- nothing in it is refused before it can be promoted — which would prove
  -- nothing about what the pack does to a role it is not allowed to touch.
  insert into erp_ref.pack_item
    (pack_code, object_kind, object_key, payload, provenance, seq)
  values (v_pack, 'role', 'zz_fresh',
          jsonb_build_object('code', 'zz_fresh', 'name', 'Fresh role',
            'from_template', v_pack || '-1.0.0',
            'permissions', jsonb_build_array(
              jsonb_build_object('permission', 'reporting.read'))),
          'A fixture of the seeded-role suite.', 30);

  select p.effect into v_changed_effect from erp.plan_content_pack(v_pack) p
   where p.object_key = 'zz_seeded';
  res := erp.apply_content_pack(v_pack);
  v_cs := (res ->> 'change_set_id')::uuid;
  perform erp.submit_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
  perform erp.approve_change_set(v_cs);
  perform erp.promote_change_set(v_cs);
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

  select array(select rp.permission_code from erp.role_permission rp
                where rp.role_id = v_seeded order by 1) into v_changed_perms;
  case_name := 'a seeded role the organisation changed is offered as left alone and the pack does not give back what was taken off it';
  passed := erp.role_is_changed_by_hand(v_seeded)
        and v_changed_effect = 'left alone, because this organisation has changed it'
        and v_changed_perms = array['inventory.read', 'master_data.read'];
  detail := format('the plan said "%s"; after applying the pack the role still holds %s',
                   v_changed_effect, array_to_string(v_changed_perms, ', '));
  return next;

  perform set_config('request.jwt.claims', '', true);
  raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('erp.job_tenant_id', '', true);

  -- ── 6. Undone ────────────────────────────────────────────────────────────
  v_cases := v_cases + 1;
  case_name := 'the fixture was undone';
  passed := v_state is null
        and not exists (select 1 from erp.tenant t where t.code = 'zzrt-' || v_tag)
        and not exists (select 1 from erp_ref.content_pack c where c.code = 'zzpack_' || v_tag)
        and not exists (select 1 from auth.users u where u.id in (a1, a2));
  detail := coalesce(v_state,
                     'the organisation, its roles and the fixture pack all rolled back');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: seeded_role_is_theirs_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.seeded_role_is_theirs_suite() from public, anon;

comment on function erp_test.seeded_role_is_theirs_suite() is
  'What a starter template may and may not do to a role it once made. A pack '
  'promotion records the grants it gave; a role nothing recorded is read as one '
  'the organisation has changed; renaming a role leaves it untouched so a newer '
  'template lands on it and keeps the new name; and a role whose grants the '
  'organisation changed is named in the plan as left alone and is not given '
  'back what was taken off it. Rolls back everything it made.';

create or replace function erp_test.assert_seeded_role_is_theirs_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _seeded_role_is_theirs on commit drop as
    select * from erp_test.seeded_role_is_theirs_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _seeded_role_is_theirs;
  drop table _seeded_role_is_theirs;
  if v_fail > 0 then
    raise exception E'CLOVEERP_SEEDED_ROLE_IS_THEIRS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either a starter template took back work an organisation did, or it stopped reaching a role nobody had touched.';
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: seeded_role_is_theirs_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a seeded role a customer edited is theirs: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_seeded_role_is_theirs_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════
--
-- erp.apply_execute_grants() is not optional: the pack planner is reached by an
-- invoker door and now reaches two new routines, and a routine a door reaches
-- that was never granted fails at runtime on a live database while a build from
-- an empty cluster says nothing at all.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp_test.assert_seeded_role_is_theirs_suite();

select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_governed_views_are_safe();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
