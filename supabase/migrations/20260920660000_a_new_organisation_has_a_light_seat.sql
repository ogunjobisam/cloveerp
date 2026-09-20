set lock_timeout = '30s';

-- =============================================================================
-- 20260920660000  A new organisation has a light seat
-- -----------------------------------------------------------------------------
-- The price list sells a light user at £9: somebody who only reads, reports,
-- decides an approval or counts stock. The seat register says the same thing in
-- its own words, and erp.person_seats() computes it — a person is light when
-- every permission their roles reach is light, and full the moment one of them
-- is not.
--
-- A walk through the roles a new organisation is actually given found that none
-- of them can produce that seat. Provisioning creates the administrator, and
-- the trigger on a new organisation seeds eleven roles for the eleven jobs —
-- Inventory, Warehouse staff, Purchasing, Sales, Finance, Production, Quality,
-- Despatch, Planning, Reporting, Master data. Every one of them reaches a
-- permission that needs a full seat, and two of them by a single code:
-- Reporting is full only because of defining a report, and Master data only
-- because of writing and importing. So the cheapest seat the product sells
-- could not be reached by anybody until an administrator built a role by hand,
-- or found Features and content and applied the base pack — which carries the
-- Auditor and the Scanner operator, the only two light roles in the product.
--
-- Nothing caught that, because nothing asserted it.
--
-- The fix is not to reclassify a permission. Moving stock and despatching a
-- consignment need a full seat and that is correct; bending a permission to
-- reach an answer would be selling a seat the product does not mean. The fix is
-- four roles that are light by the register's own definition:
--
--   Viewer            every permission whose action is read, and taking a
--                     report away with you. Coded observer, not viewer: the
--                     code 'viewer' is already how a demonstration and four
--                     of the product's own suites name a role they build by
--                     hand on their own tenant, each with no on-conflict
--                     handling of its own — none of them anticipated a role
--                     of that code already existing before they got to make
--                     one. Renaming this seat's code rather than four
--                     unrelated fixtures keeps the collision out of files
--                     this migration has no reason to touch; the name shown
--                     on screen is still Viewer.
--   Stock counter     counting stock and reading what is being counted.
--   Scanner operator  confirming on a registered scanner what somebody else
--                     planned. This is the base pack's own template, read from
--                     the pack rather than written out a second time, so the
--                     role a new organisation gets and the role the pack would
--                     install cannot drift apart. An organisation that later
--                     applies the base pack is not offered it twice.
--   Approver          deciding a master-data approval, and reading enough to
--                     decide it. Deliberately not the approvals that commit
--                     money: the owner's decision of 17 September made
--                     approving a purchase, a payment or a discount a full
--                     seat, and only approving master data stayed light.
--
-- Each is seeded the way the eleven are: only where the organisation does not
-- already have a role of that code, so seeding never rewrites one, and only on
-- a new organisation. No existing organisation gains a role here. The three
-- that are live keep the roles they have, and the Features and content screen
-- is where they take the pack's two light roles if they want them — offered,
-- not forced.
--
-- The seats are asserted rather than declared. erp.assert_provisioning_offers_a_light_seat()
-- reads each role's permissions against the seat register with the same rule
-- erp.person_seats() uses, and names any that would not be light. It runs on
-- every build by existing.
--
-- What this costs a live database: nothing. The trigger fires on a new
-- organisation only, and no row of an existing one is read or written.
--
-- The base pack plans one item fewer on a new organisation, because the Scanner
-- operator template is now a role it already holds. The acceptance suite counts
-- that on purpose and says so.
--
-- Proof: erp_test.a_light_seat_exists_suite(), six cases, pinned at both ends.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What each light role holds
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.light_role_permissions(p_code text)
returns text[]
language sql
stable
set search_path = ''
as $$
  select case p_code
    -- Read from the catalogue rather than listed out, so a module that ships
    -- later is in the Viewer's reach on the day it ships. If one of those reads
    -- ever needs a full seat, erp.assert_provisioning_offers_a_light_seat()
    -- fails the build rather than quietly selling a full user at a light price.
    when 'observer' then (
      select coalesce(array_agg(p.code order by p.code), '{}'::text[])
        from erp_ref.permission p
       where p.action = 'read' or p.code = 'reporting.export')
    when 'stock_counter' then
      array['inventory.count', 'inventory.read', 'master_data.read']
    -- One definition, not two.
    when 'scanner_operator' then (
      select coalesce(array_agg(e.value ->> 'permission'
                                order by e.value ->> 'permission'), '{}'::text[])
        from erp_ref.pack_item pi,
             lateral jsonb_array_elements(pi.payload -> 'permissions') e
       where pi.pack_code = 'base' and pi.object_kind = 'role'
         and pi.object_key = 'scanner_operator')
    when 'approver' then
      array['master_data.approve', 'master_data.read',
            'reporting.read', 'administration.read']
    else '{}'::text[]
  end
$$;

comment on function erp.light_role_permissions(text) is
  'What each of the four light roles a new organisation is given holds. The '
  'Viewer''s set is read from the permission catalogue so a later module is in '
  'it the day it ships, and the Scanner operator''s from the base pack''s own '
  'template so the seeded role and the pack''s cannot drift apart. Every one of '
  'them is light by the seat register''s definition, which '
  'erp.assert_provisioning_offers_a_light_seat() proves on every build.';

create or replace function erp.light_role_seat_report()
returns table(role_code text, permission_count integer, seat text)
language sql
stable
set search_path = ''
as $$
  with held as (
    select c.code, erp.light_role_permissions(c.code) as perms
      from (values ('observer'), ('stock_counter'),
                   ('scanner_operator'), ('approver')) c(code)
  )
  select h.code,
         coalesce(array_length(h.perms, 1), 0),
         case
           when coalesce(array_length(h.perms, 1), 0) = 0 then 'no permissions'
           when exists (select 1 from unnest(h.perms) x
                         where not exists (select 1 from erp_ref.permission p
                                            where p.code = x))
             then 'a permission the catalogue does not hold'
           -- The same rule erp.person_seats() uses: light only where every one
           -- of them is light, and a permission that says nothing counts full.
           when (select bool_and(coalesce(p.seat, 'full') = 'light')
                   from unnest(h.perms) x
                   join erp_ref.permission p on p.code = x)
             then 'light'
           else 'full'
         end
    from held h
   order by 1
$$;

comment on function erp.light_role_seat_report() is
  'The seat each of the four light roles would produce, read from the seat '
  'register with the rule erp.person_seats() uses. Anything other than light is '
  'a role that was meant to be sold at the light price and would be billed as a '
  'full user.';

create or replace function erp.assert_provisioning_offers_a_light_seat()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_bad   text;
  v_light integer;
begin
  select string_agg(format('%s (%s permission(s)) would be %s',
                           r.role_code, r.permission_count, r.seat), '; '
                    order by r.role_code)
    into v_bad
    from erp.light_role_seat_report() r
   where r.seat <> 'light';

  if v_bad is not null then
    raise exception 'CLOVEERP_NO_LIGHT_SEAT: a role a new organisation is given to sell at the light price would not be light — %', v_bad
      using errcode = '23514',
            hint = 'Put the permission back the way it was, or take it off the role. Do not move a permission between seats to reach an answer: what a seat costs is on the price list.';
  end if;

  select count(*) into v_light
    from erp.light_role_seat_report() r where r.seat = 'light';

  return format('a new organisation is given %s role(s) that produce a light seat', v_light);
end;
$$;

revoke all on function erp.light_role_permissions(text) from public, anon, authenticated;
revoke all on function erp.light_role_seat_report() from public, anon, authenticated;
revoke all on function erp.assert_provisioning_offers_a_light_seat() from public, anon, authenticated;

comment on function erp.assert_provisioning_offers_a_light_seat is
  'A new organisation always has at least one role that produces the light seat '
  'the price list sells, and every role meant to be light is light. The claim '
  'the published price list makes, which the product could not honour until '
  '20260920660000 and nothing checked.';

-- erp.assert_diagnostics_registered() refuses an assert_* function in schema
-- erp that is neither registered here nor exempt: fifteen checks were once
-- reachable only from a SQL client, and this is how the build now refuses to
-- let a sixteenth join them.
insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments,
   detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('provisioning_offers_a_light_seat', 'A new organisation can sell the seat the price list sells',
   'assertion', 'platform', 'erp', 'assert_provisioning_offers_a_light_seat', '',
   'light_role_seat_report', '',
   'The price list sells a light user at the lower price, and until this every '
   'role a new organisation was given reached a permission that needs a full '
   'seat. A role meant to be light that stops being light — because a '
   'permission it reaches was reclassified, or a permission was added to it — '
   'fails the build rather than quietly billing a full user at the light price.',
   true, 99)
on conflict (code) do update set
  title = excluded.title, kind = excluded.kind, scope = excluded.scope,
  schema_name = excluded.schema_name, function_name = excluded.function_name,
  arguments = excluded.arguments, detail_function = excluded.detail_function,
  detail_arguments = excluded.detail_arguments, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. And a new organisation is given them
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A second loop beside the eleven, by asserted replacement of the text the
-- database carries. The eleven are not touched: not their codes, not their
-- names, not what erp.standard_role_permissions() gives them.

do $seed$
declare
  v_def text := pg_get_functiondef('erp.ensure_standard_roles(uuid)'::regprocedure);
  v_n   constant text := $n$    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$n$;
  v_r   constant text := $r$    v_made := v_made + 1;
  end loop;

  -- The light seats (20260920660000). Every role above reaches a permission
  -- that needs a full seat, so until this nothing a new organisation was given
  -- could produce the seat the price list sells at the lower price. These four
  -- are light by the seat register's own definition — they read, they report,
  -- they decide a master-data approval, they record a count — and
  -- erp.assert_provisioning_offers_a_light_seat() proves it on every build.
  --
  -- Seeded the same way: a role already on file belongs to the organisation,
  -- however it was shaped, and seeding never rewrites one.
  foreach v_trio slice 1 in array array[
    array['observer', 'Viewer',
          'Reads what the organisation has, everywhere, and takes a report away. Changes nothing.'],
    array['stock_counter', 'Stock counter',
          'Counts stock and reads what is being counted. Accepting the variance is somebody else''s.'],
    array['scanner_operator', 'Scanner operator',
          'Confirms counts, put-aways, replenishments, picks and receipts that somebody else planned, on a registered scanner.'],
    array['approver', 'Approver',
          'Decides master-data approvals and reads enough to decide them. Approving what commits money is a full seat and is not here.']
  ] loop
    v_code := v_trio[1];
    v_name := v_trio[2];

    if exists (select 1 from erp.role r
                where r.tenant_id = p_tenant_id and r.code = v_code) then
      continue;
    end if;

    -- Scanner operator carries the base pack's own template mark, and only
    -- it: it is the pack's Scanner operator template, read from the pack
    -- rather than written out a second time, and from_template is how a
    -- content pack recognises a role it does not need to plan again
    -- (erp.plan_content_pack() tests containment on the whole role, and a
    -- null from_template here would never contain the pack item's
    -- 'base-1.0.0'). The other three are not any pack's and carry none.
    insert into erp.role (tenant_id, code, name, description, from_template, status)
    values (p_tenant_id, v_code, v_name, v_trio[3],
            case when v_code = 'scanner_operator' then 'base-1.0.0' else null end,
            'active')
    returning id into v_role;

    insert into erp.role_permission (tenant_id, role_id, permission_code, data_classes)
    select p_tenant_id, v_role, perm, '{}'
      from unnest(erp.light_role_permissions(v_code)) perm;

    v_made := v_made + 1;
  end loop;

  return v_made;
end;
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_SEEDING_UNRECOGNISED: seeding a new organisation''s roles does not end the way this migration patches'
      using hint = 'A later migration changed it. Read the definition the database carries and write the needle against that.';
  end if;

  -- The second loop needs a variable of its own, declared beside the ones the
  -- first loop uses.
  if (length(v_def) - length(replace(v_def, E'  v_pair  text[];', ''))) / length(E'  v_pair  text[];') <> 1 then
    raise exception 'CLOVEERP_SEEDING_UNRECOGNISED: seeding a new organisation''s roles does not declare its loop variable once where this migration expects'
      using hint = 'A later migration changed it. Read the definition the database carries and write the needle against that.';
  end if;
  v_def := replace(v_def, E'  v_pair  text[];', E'  v_pair  text[];\n  v_trio  text[];');
  if position('v_trio  text[];' in v_def) = 0 then
    raise exception 'CLOVEERP_SEEDING_UNRECOGNISED: seeding a new organisation''s roles does not declare its loop variable where this migration expects'
      using hint = 'Read the definition the database carries and write the needle against that.';
  end if;

  execute replace(v_def, v_n, v_r);

  if position('erp.light_role_permissions(v_code)'
              in pg_get_functiondef('erp.ensure_standard_roles(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_SEEDING_UNRECOGNISED: seeding a new organisation''s roles did not take the light roles'
      using hint = 'The replacement did not land. Compare the needle with the definition the database carries.';
  end if;
end
$seed$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The base pack plans one item fewer
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The Scanner operator template is now a role a new organisation already holds,
-- with the grants the template gives, so the pack adds nothing and does not
-- plan it. The count is hardcoded on purpose — it is what makes a pack that
-- grows by accident fail the build — so each deliberate move updates it and
-- says what moved it.

do $acceptance$
declare
  v_sig constant text := 'erp_test.starter_pack_acceptance_suite()';
  v_def text := pg_get_functiondef('erp_test.starter_pack_acceptance_suite()'::regprocedure);
  v_n   constant text := $n$    (res ->> 'items')::integer = 346
$n$;
  v_r   constant text := $r$    -- 345 since 20260920660000: a new organisation is seeded the Scanner
    -- operator role, with the grants the base pack's own template gives it, so
    -- the pack has nothing to add and no longer plans that item.
    (res ->> 'items')::integer = 345
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % does not count 346 planned items once', v_sig
      using hint = 'A later migration recounted the base pack. Read the suite and patch its count.';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('integer = 345' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_ACCEPTANCE_SUITE_UNRECOGNISED: % did not take its new count', v_sig
      using hint = 'The replacement did not land. Compare the needle with the suite''s definition.';
  end if;
end
$acceptance$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.a_light_seat_exists_suite()
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
  r         record;
  a1        uuid := gen_random_uuid();
  v_codes   text[];
  v_person  uuid; v_token text; v_sub uuid;
  v_subs    uuid[] := '{}';
  v_seats   text := '';
  v_all_light boolean := true;
  v_admin_perms integer; v_catalogue integer;
  v_eleven  integer;
  v_scanner text[]; v_pack_scanner text[];
  v_scanner_mark text; v_marks text;
  c         text;
begin
  begin
  v_step := 'provisioning a new organisation';
  perform set_config('request.jwt.claims', '', true);
  select * into r from erp.provision_tenant(
    'zzls-' || v_tag, 'Light Seat',
    'admin@zzls-' || v_tag || '.test', 'Light Seat Admin');
  insert into auth.users (id, email) values (a1, 'admin@zzls-' || v_tag || '.test');
  perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
  perform erp.claim_invitation(r.admin_token);

  -- ── 1. The four roles are there ──────────────────────────────────────────
  v_cases := v_cases + 1;
  select array(select ro.code from erp.role ro
                where ro.tenant_id = r.tenant_id
                  and ro.code in ('observer', 'stock_counter', 'scanner_operator', 'approver')
                order by ro.code) into v_codes;
  case_name := 'a newly provisioned organisation is given the four light roles';
  passed := v_codes = array['approver', 'observer', 'scanner_operator', 'stock_counter'];
  detail := format('it has %s', array_to_string(v_codes, ', '));
  return next;

  -- ── 2. Each produces a light seat, as the seat function computes it ──────
  v_step := 'somebody holds each of them';
  v_cases := v_cases + 1;
  foreach c in array array['observer', 'stock_counter', 'scanner_operator', 'approver'] loop
    v_sub := gen_random_uuid();
    v_subs := v_subs || v_sub;
    select p.app_user_id, p.token into v_person, v_token
      from erp.invite_principal(c || '@zzls-' || v_tag || '.test', 'Holder of ' || c) p;
    perform erp.grant_role(v_person, c, null, null, 'a light seat');
    insert into auth.users (id, email) values (v_sub, c || '@zzls-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', v_sub)::text, true);
    perform erp.claim_invitation(v_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_seats := v_seats || format('%s is %s; ', c, erp.person_seat(v_person));
    if erp.person_seat(v_person) <> 'light' then
      v_all_light := false;
    end if;
  end loop;
  case_name := 'somebody holding one of them is a light user, as the seat function computes it and not as a table says';
  passed := v_all_light
        and (select count(*) from erp.person_seats(r.tenant_id) s where s.seat = 'light') = 4
        and erp.entitlement_usage('light_users', r.tenant_id) = 4;
  detail := format('%sthe meter counts %s light user(s)',
                   v_seats, erp.entitlement_usage('light_users', r.tenant_id));
  return next;

  -- ── 3. And the report agrees with the seat function ──────────────────────
  v_cases := v_cases + 1;
  case_name := 'the report the build reads agrees with what the seat function computed for a real person';
  passed := not exists (select 1 from erp.light_role_seat_report() x where x.seat <> 'light')
        and (select count(*) from erp.light_role_seat_report()) = 4;
  detail := (select string_agg(format('%s: %s (%s)', x.role_code, x.seat, x.permission_count), '; ' order by x.role_code)
               from erp.light_role_seat_report() x);
  return next;

  -- ── 4. Nothing that was there before moved ───────────────────────────────
  v_step := 'the roles that were seeded before';
  v_cases := v_cases + 1;
  select count(*)::integer into v_eleven
    from erp.role ro
   where ro.tenant_id = r.tenant_id
     and ro.code in ('inventory', 'warehouse', 'purchasing', 'sales', 'finance',
                     'production', 'quality', 'despatch', 'planning', 'reporting',
                     'master_data');
  select count(*)::integer into v_admin_perms
    from erp.role_permission rp
    join erp.role ro on ro.id = rp.role_id and ro.tenant_id = rp.tenant_id
   where rp.tenant_id = r.tenant_id and ro.code = 'administrator';
  select count(*)::integer into v_catalogue from erp_ref.permission;
  select erp.light_role_permissions('scanner_operator') into v_scanner;
  select array(select e.value ->> 'permission'
                 from erp_ref.pack_item pi,
                      lateral jsonb_array_elements(pi.payload -> 'permissions') e
                where pi.pack_code = 'base' and pi.object_kind = 'role'
                  and pi.object_key = 'scanner_operator'
                order by 1) into v_pack_scanner;
  case_name := 'the eleven roles seeded before are still there, the administrator still holds every permission, and the scanner role is the pack''s own definition rather than a second one';
  passed := v_eleven = 11
        and v_admin_perms = v_catalogue
        and v_scanner = v_pack_scanner
        and array_length(v_scanner, 1) > 0;
  detail := format('%s of the eleven; the administrator holds %s of %s; the scanner role holds %s, which is what the pack''s template gives',
                   v_eleven, v_admin_perms, v_catalogue, array_to_string(v_scanner, ', '));
  return next;

  -- ── 5. Scanner operator carries the template mark; the other three do not ─
  --
  -- This is the check that would have caught the gap the first draft of this
  -- migration shipped with: a scanner_operator seeded with no from_template
  -- looks identical to the eleven module roles to every OTHER case above —
  -- same code, same permissions, same seat — right up until the organisation
  -- applies the base pack and gets a second, indistinguishable role instead
  -- of nothing. Named by role, not folded into case 4's boolean, so a
  -- regression here says exactly which role stopped carrying its mark.
  v_step := 'the scanner operator''s template mark, and the base pack offered again';
  v_cases := v_cases + 1;
  select ro.from_template into v_scanner_mark
    from erp.role ro where ro.tenant_id = r.tenant_id and ro.code = 'scanner_operator';
  select string_agg(format('%s: %s', ro.code, coalesce(ro.from_template, 'none')), ', ' order by ro.code)
    into v_marks
    from erp.role ro
   where ro.tenant_id = r.tenant_id
     and ro.code in ('observer', 'stock_counter', 'scanner_operator', 'approver');
  case_name := 'the scanner operator role carries the base pack''s template mark, the other three light roles carry none, and the base pack does not offer the scanner operator role a second time';
  passed := v_scanner_mark = 'base-1.0.0'
        and (select ro.from_template from erp.role ro
              where ro.tenant_id = r.tenant_id and ro.code = 'observer') is null
        and (select ro.from_template from erp.role ro
              where ro.tenant_id = r.tenant_id and ro.code = 'stock_counter') is null
        and (select ro.from_template from erp.role ro
              where ro.tenant_id = r.tenant_id and ro.code = 'approver') is null
        and not exists (select 1 from erp.plan_content_pack('base') p
                          where p.object_kind = 'role' and p.object_key = 'scanner_operator');
  detail := format('%s; the base pack''s plan for this organisation names no scanner_operator item',
                   v_marks);
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
        and not exists (select 1 from erp.tenant t where t.code = 'zzls-' || v_tag)
        and not exists (select 1 from auth.users u where u.id = a1);
  detail := coalesce(v_state, 'the organisation and everybody in it rolled back');
  return next;

  if v_cases <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_light_seat_exists_suite ran % case(s), expected %; the fixture stopped %',
      v_cases, c_expected,
      coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$suite$;

revoke all on function erp_test.a_light_seat_exists_suite() from public, anon;

comment on function erp_test.a_light_seat_exists_suite() is
  'A new organisation can sell the seat the price list sells at the lower '
  'price. It is given the four light roles; somebody holding any one of them is '
  'computed as a light user by the seat function and counted as one by the '
  'meter; the report the build reads agrees; nothing that was seeded before '
  'moved — the eleven job roles are still there and the administrator still '
  'holds every permission; and, by name, the scanner operator role carries the '
  'base pack''s template mark while the other three carry none, and the base '
  'pack does not plan the scanner operator role a second time. Rolls back '
  'everything it made.';

create or replace function erp_test.assert_a_light_seat_exists_suite()
returns text
language plpgsql
volatile
set search_path = ''
as $wrap$
declare
  c_expected constant integer := 6;
  v_all integer; v_fail integer; v_detail text;
begin
  create temp table if not exists _a_light_seat_exists on commit drop as
    select * from erp_test.a_light_seat_exists_suite();
  select count(*), count(*) filter (where not coalesce(passed, false)),
         string_agg(format('  %s — %s', case_name, detail), E'\n')
           filter (where not coalesce(passed, false))
    into v_all, v_fail, v_detail
    from _a_light_seat_exists;
  drop table _a_light_seat_exists;
  if v_fail > 0 then
    raise exception E'CLOVEERP_A_LIGHT_SEAT_EXISTS_SUITE_FAILED: %/% case(s) failed\n%',
      v_fail, v_all, v_detail
      using hint = 'Read the failed case. Either a new organisation lost the roles that reach the lower-priced seat, or one of them stopped being light.';
  end if;
  if v_all <> c_expected then
    raise exception 'CLOVEERP_SUITE_SHRANK: a_light_seat_exists_suite ran % case(s), expected %',
      v_all, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('a new organisation has a light seat: %s/%s cases passed', v_all, v_all);
end;
$wrap$;

revoke all on function erp_test.assert_a_light_seat_exists_suite() from public, anon;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_provisioning_offers_a_light_seat();
select erp_test.assert_a_light_seat_exists_suite();
select erp_test.assert_provisioning_suite();

select erp.assert_every_permission_has_a_seat();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_refusals_name_next_action();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_isolation();
