-- =============================================================================
-- Light users are counted apart from full users
--
-- The price list the owner approved on 14 September sells a plan with a number
-- of full users included (Starter 5, Standard 15, Enterprise 40), extra full
-- users at £45, £49 and £45 a month, and light users at £9, £9 and £6. The
-- public pricing page says who a light user is: somebody who only approves,
-- looks at reports or uses the scanner. 20260914077000 put full_user and
-- light_user items on the price book. Nothing in the product could tell one
-- person from the other, so an organisation could be sold light users and
-- never be billed as sold.
--
-- This migration builds the measurement. It changes no refusal.
--
--   1. Every permission says what seat it needs. erp_ref.permission.seat is
--      'light' for a permission that only reads or reports (read, audit_read,
--      reporting.export, document.reprint), decides an approval
--      (master_data.approve, procurement.approve, sales.discount_approve,
--      finance.approve_payment) or records a count (inventory.count). Every
--      permission that creates, changes, posts, configures or administers is
--      'full'. A permission nobody has classified is counted as full, and
--      erp.assert_every_permission_has_a_seat() fails the build for it, so the
--      next permission cannot arrive without saying.
--   2. erp.person_seat(app_user_id) is 'full', 'light' or 'none'. It is 'none'
--      for somebody who is not an active person, or whose current grants reach
--      no permission (valid_from and valid_to are read as erp.has_permission
--      reads them, and a retired role reaches nothing). It is 'light' when
--      every permission their current roles reach is light, and 'full'
--      otherwise. A grant made for a platform support visit ('Platform %
--      support access:%', as erp_platform_enter_tenant writes it) is not
--      counted, and neither is a service principal. It is one set-based query,
--      erp.person_seats(), which the meter uses for a whole organisation at
--      once rather than a call per person.
--   3. The meter. 'users' now counts full users only, and 'light_users' is
--      metered beside it. Full only, because what a plan includes is full
--      users: a Standard customer with fifteen full users and forty people
--      who approve has used the fifteen it bought, not fifty-five. A plan
--      includes no light users and caps none (its limit is stated as null); a
--      contract that sells them sets the number. create_contract_from_quote
--      turned a quote's lines into contract entitlements only where the price
--      item named an entitlement, and a light_user item names none, so light
--      users sold on a quote reached no contract at all. A light_user line now
--      provisions a light_users limit of its quantity, and a contract already
--      in force that sold light users is given the row it should have had.
--      Full-user lines are left as they are, so a contract's users limit is
--      still the plan's unless a users band was sold.
--
--      Nothing is refused by this. erp.require_entitlement() is the only
--      routine that refuses on the users entitlement, and no invitation, grant
--      or principal writer calls it; the suites do. A quote's own limit on
--      users (CLOVEERP_QUOTE_USERS_BEYOND_PLAN) reads the plan register
--      directly and is untouched. What moves is what the meter says: the
--      customer's own agreement page, the breach sweep and the console now
--      count full users where they counted every active person.
--   4. The console. public.erp_platform_seats(p_tenant_id) gives an
--      organisation's full and light users, each with its limit and whether
--      the contract or the plan set it, for platform support and above. It
--      reads the same meter the invoice would, inside the organisation it
--      names (erp_meta.act_in_tenant), because the plan lookup behind a limit
--      falls back to the caller's own organisation while it is planned.
--   5. erp_test.light_users_suite proves an approver, a reporter and a counter
--      are light; a poster, a configurer and anybody holding one full role
--      among light ones are full; nobody with no role, a grant not yet begun,
--      an invitation not yet accepted, a support visit or a service principal
--      is counted; an unclassified permission counts as full and is refused;
--      the meter and the console agree with the people; and light users sold
--      on a quote become the contract's limit.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. The seat each permission needs
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_ref.permission add column if not exists seat text;
alter table erp_ref.permission drop constraint if exists permission_seat_known;
alter table erp_ref.permission add constraint permission_seat_known
  check (seat is null or seat in ('light', 'full'));

comment on column erp_ref.permission.seat is
  'The seat a person needs to hold this permission, as the price list sells '
  'them. light: it only reads or reports, decides an approval, or records a '
  'count. full: it creates, changes, posts, configures or administers. Null is '
  'unclassified, is counted as full by erp.person_seats(), and fails '
  'erp.assert_every_permission_has_a_seat().';

do $seats$
declare
  v_unknown text;
begin
  create temp table _permission_seat (code text primary key, seat text not null) on commit drop;
  insert into _permission_seat (code, seat) values
    ('master_data.read',          'light'),
    ('master_data.write',         'full'),
    ('master_data.approve',       'light'),
    ('master_data.import',        'full'),
    ('inventory.read',            'light'),
    ('inventory.move',            'full'),
    ('inventory.adjust',          'full'),
    ('inventory.count',           'light'),
    ('inventory.write_off',       'full'),
    ('procurement.read',          'light'),
    ('procurement.requisition',   'full'),
    ('procurement.order',         'full'),
    ('procurement.approve',       'light'),
    ('procurement.receive',       'full'),
    ('procurement.match',         'full'),
    ('planning.read',             'light'),
    ('planning.forecast',         'full'),
    ('planning.run',              'full'),
    ('planning.firm',             'full'),
    ('production.read',           'light'),
    ('production.order',          'full'),
    ('production.execute',        'full'),
    ('production.release',        'full'),
    ('sales.read',                'light'),
    ('sales.order',               'full'),
    ('sales.price',               'full'),
    ('sales.discount_approve',    'light'),
    ('sales.credit_release',      'full'),
    ('sales.despatch',            'full'),
    ('sales.invoice',             'full'),
    ('finance.read',              'light'),
    ('finance.post',              'full'),
    ('finance.approve_payment',   'light'),
    ('finance.close_period',      'full'),
    ('finance.reopen_period',     'full'),
    ('finance.configure',         'full'),
    ('quality.read',              'light'),
    ('quality.inspect',           'full'),
    ('quality.disposition',       'full'),
    ('quality.release_batch',     'full'),
    ('quality.recall',            'full'),
    ('logistics.read',            'light'),
    ('logistics.plan',            'full'),
    ('logistics.despatch',        'full'),
    ('reporting.read',            'light'),
    ('reporting.define',          'full'),
    ('reporting.export',          'light'),
    ('administration.read',       'light'),
    ('administration.users',      'full'),
    ('administration.roles',      'full'),
    ('administration.configure',  'full'),
    ('administration.promote',    'full'),
    ('administration.integrate',  'full'),
    ('administration.jobs',       'full'),
    ('administration.audit_read', 'light'),
    ('document.template_manage',  'full'),
    ('document.issue',            'full'),
    ('document.reprint',          'light');

  select string_agg(s.code, ', ' order by s.code) into v_unknown
    from _permission_seat s
   where not exists (select 1 from erp_ref.permission p where p.code = s.code);
  if v_unknown is not null then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: the catalogue holds no permission %', v_unknown
      using hint = 'The classification names a code the catalogue does not hold; correct the list.';
  end if;

  update erp_ref.permission p
     set seat = s.seat
    from _permission_seat s
   where s.code = p.code
     and p.seat is distinct from s.seat;
end
$seats$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The check that every permission says
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.permission_seat_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a permission does not say whether it needs a light or a full seat',
         p.code,
         'erp.person_seats() counts it as full until erp_ref.permission.seat is set in the migration that adds it'
    from erp_ref.permission p
   where p.seat is null
   order by 2
$$;

comment on function erp.permission_seat_report() is
  'Permissions with no seat. Each is counted as a full seat until it is classified.';

create or replace function erp.assert_every_permission_has_a_seat()
returns text
language plpgsql
set search_path = ''
as $$
declare v_count integer; v_detail text;
begin
  select count(*), string_agg(format('  %s — %s', reference, detail), E'\n')
    into v_count, v_detail from erp.permission_seat_report();
  if v_count > 0 then
    raise exception 'CLOVEERP_PERMISSION_WITHOUT_SEAT: % permission(s) do not say whether they need a light or a full seat', v_count
      using errcode = 'P0001', detail = v_detail,
            hint = 'Set erp_ref.permission.seat in the migration that adds the permission: light if it only reads or reports, decides an approval or records a count; full otherwise.';
  end if;
  return format('permissions: %s light, %s full, none unclassified',
    (select count(*) from erp_ref.permission p where p.seat = 'light'),
    (select count(*) from erp_ref.permission p where p.seat = 'full'));
end;
$$;

revoke all on function erp.permission_seat_report() from public, anon, authenticated;
revoke all on function erp.assert_every_permission_has_a_seat() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('permission_seats', 'Every permission says whether it needs a light or a full seat',
   'assertion', 'platform', 'erp', 'assert_every_permission_has_a_seat', '',
   'permission_seat_report', '',
   'Light and full users are billed at different prices, and a person''s seat is read from the permissions their roles reach. A permission that says neither would be counted as full without anybody deciding it.',
   true, 79)
on conflict (code) do update set
  title = excluded.title, function_name = excluded.function_name,
  detail_function = excluded.detail_function, blurb = excluded.blurb, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A person's seat
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.person_seats(p_tenant_id uuid, p_app_user_id uuid default null)
returns table(app_user_id uuid, seat text)
language sql
stable
set search_path = ''
as $$
  -- Only people who hold a seat are returned; everybody else is 'none'. The
  -- grant is read as erp.has_permission() reads it (in force today, on an
  -- active role), and a grant made for a platform support visit is left out.
  select u.id,
         case when bool_and(coalesce(p.seat, 'full') = 'light') then 'light' else 'full' end
    from erp.app_user u
    join erp.user_role ur
      on ur.tenant_id = u.tenant_id and ur.app_user_id = u.id
     and ur.valid_from <= current_date
     and (ur.valid_to is null or ur.valid_to >= current_date)
     and coalesce(ur.grant_reason, '') not like 'Platform % support access:%'
    join erp.role r
      on r.tenant_id = ur.tenant_id and r.id = ur.role_id and r.status = 'active'
    join erp.role_permission rp
      on rp.tenant_id = ur.tenant_id and rp.role_id = r.id
    join erp_ref.permission p
      on p.code = rp.permission_code
   where u.tenant_id = p_tenant_id
     and (p_app_user_id is null or u.id = p_app_user_id)
     and u.kind = 'person'
     and u.status = 'active'
   group by u.id
$$;

comment on function erp.person_seats(uuid, uuid) is
  'The seat each active person in one organisation holds: full where any '
  'permission their current roles reach needs a full seat (or says nothing), '
  'light where every one is light. People with no seat are not returned. '
  'Service principals and platform support grants are never counted. One '
  'query for the organisation, so a meter need not ask person by person.';

create or replace function erp.person_seat(p_app_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select s.seat
       from erp.app_user u
       cross join lateral erp.person_seats(u.tenant_id, u.id) s
      where u.id = p_app_user_id),
    'none')
$$;

comment on function erp.person_seat(uuid) is
  'full, light or none for one principal, as the price list sells seats: none '
  'for somebody who is not an active person or whose current grants reach no '
  'permission, light when every permission they reach is light, full otherwise.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The meter
-- ═════════════════════════════════════════════════════════════════════════════

update erp_meta.entitlement_kind
   set title = 'Full users',
       counts_what = 'erp.app_user rows of kind person with status active whose current roles reach a full permission (erp.person_seat() is full)',
       note = 'What a plan includes, and what an extra full user adds to. Until 20260914095000 this counted every active person; light users are counted apart now. erp.require_entitlement() refuses on it where it is called, and no invitation or grant calls it.'
 where code = 'users';

insert into erp_meta.entitlement_kind
  (code, title, unit, counts_what, enforcement_schema, enforcement_routine, note) values
('light_users', 'Light users', 'users',
 'erp.app_user rows of kind person with status active whose current roles reach only light permissions: reading and reporting, deciding approvals, counting stock (erp.person_seat() is light)',
 'erp', 'require_entitlement',
 'Sold per person beside the plan, which includes none. Measured so an organisation is billed as sold; nothing refuses on it.')
on conflict (code) do update set
  title = excluded.title, unit = excluded.unit, counts_what = excluded.counts_what,
  enforcement_schema = excluded.enforcement_schema,
  enforcement_routine = excluded.enforcement_routine, note = excluded.note;

-- A plan states a limit for every entitlement, and a null limit is stated.
insert into erp_meta.plan_entitlement (plan_code, entitlement_code, limit_value, note)
select p.code, 'light_users', null,
       'A plan includes no light users and caps none; the contract that sells them sets the number.'
  from erp_meta.plan p
on conflict (plan_code, entitlement_code) do nothing;

do $usage$
declare
  v_sig    constant text := 'erp.entitlement_usage(text,uuid)';
  v_def    text := pg_get_functiondef('erp.entitlement_usage(text,uuid)'::regprocedure);
  v_needle constant text := $n$    when 'users' then
      select count(*) into v_used from erp.app_user u
       where u.tenant_id = v_tenant and u.kind = 'person'
         and u.status = 'active';$n$;
  v_new    constant text := $n$    when 'users' then
      -- Full users (20260914095000): what a plan includes.
      select count(*) into v_used from erp.person_seats(v_tenant) s
       where s.seat = 'full';
    when 'light_users' then
      select count(*) into v_used from erp.person_seats(v_tenant) s
       where s.seat = 'light';$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not count users the way 20260904190000 wrote it', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$usage$;

-- Light users sold on a quote become the contract's light users limit.
do $contract$
declare
  v_sig    constant text := 'erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)';
  v_def    text := pg_get_functiondef('erp.create_contract_from_quote(uuid,text,text,text,date,integer,text,integer,text,text,jsonb,jsonb,date,integer)'::regprocedure);
  v_needle constant text := $n$    elsif l ->> 'kind' = 'capability_addon' then$n$;
  v_new    constant text := $n$    elsif l ->> 'kind' = 'light_user' then
      -- A light user item names no entitlement: its quantity is the number of
      -- light users sold, and that is the limit (20260914095000).
      insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
      values (v_id, 'light_users', (l ->> 'quantity')::numeric, p_commencement);
    elsif l ->> 'kind' = 'capability_addon' then$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not turn a capability line into a contract row exactly once', v_sig
      using hint = 'Read the live body and write the needle against it.';
  end if;
  execute replace(v_def, v_needle, v_new);
end
$contract$;

-- And a contract already in force that sold light users is given the row.
insert into erp_meta.contract_entitlement (contract_id, entitlement_code, limit_value, effective_from)
select c.id, 'light_users', sum(l.quantity), c.commencement
  from erp_meta.contract c
  join erp.document_line l
    on l.tenant_id = c.platform_tenant_id and l.document_id = c.quote_document_id and not l.is_cancelled
  join erp.price_item pi
    on pi.tenant_id = l.tenant_id and pi.item_id = l.item_id
   and pi.kind = 'light_user' and pi.entitlement_code is null
 where c.status in ('active', 'terminating')
   and not exists (select 1 from erp_meta.contract_entitlement ce
                    where ce.contract_id = c.id and ce.entitlement_code = 'light_users')
 group by c.id, c.commencement;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The console
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function public.erp_platform_seats(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_out jsonb;
begin
  perform erp_meta.require_platform('support');
  if not exists (select 1 from erp.tenant t where t.id = p_tenant_id) then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: % is not an organisation on this deployment', p_tenant_id
      using errcode = '23503',
            hint = 'It may have been purged. Read the organisation list again.';
  end if;

  -- Inside the organisation: a limit reads its plan through
  -- erp.tenant_plan_code(), whose fallback to the caller's own organisation is
  -- evaluated while the query is planned.
  perform erp_meta.act_in_tenant(p_tenant_id);

  select jsonb_build_object('tenant_id', p_tenant_id) || jsonb_object_agg(k.seat, jsonb_build_object(
           'used', coalesce(erp.entitlement_usage(k.code, p_tenant_id), 0),
           'limit', erp.entitlement_limit(k.code, p_tenant_id),
           'limit_from', case
             when exists (select 1
                            from erp_meta.contract_entitlement ce
                            join erp_meta.contract c on c.id = ce.contract_id
                           where c.tenant_id = p_tenant_id and c.status in ('active', 'terminating')
                             and ce.entitlement_code = k.code
                             and ce.effective_from <= current_date
                             and (ce.effective_to is null or ce.effective_to > current_date)) then 'contract'
             when erp.tenant_plan_code(p_tenant_id) is not null then 'plan'
           end))
    into v_out
    from (values ('users', 'full'), ('light_users', 'light')) as k(code, seat);

  perform erp_meta.stop_acting_in_tenant();
  return v_out;
end;
$$;

comment on function public.erp_platform_seats(uuid) is
  'One organisation''s full and light users, as the meter counts them, each '
  'with its limit and whether the contract or the plan set it. Platform '
  'support and above.';

revoke all on function public.erp_platform_seats(uuid) from public, anon;
grant execute on function public.erp_platform_seats(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_platform_seats', 'erp_meta.require_platform',
   'Platform staff read. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_seats',
   'Counts one organisation''s people by seat and reads its contract and plan limits from erp_meta. Gated by erp_meta.require_platform(''support'') on its first line; returns counts, and names nobody.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.light_users_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  v_tag     text := substr(md5(gen_random_uuid()::text), 1, 6);
  ra record; rb record; rp record;
  -- Sign-ins. The platform owner is also the administrator of organisation B,
  -- which is the case the console gets wrong when it forgets to act inside the
  -- organisation it names.
  s_admin   uuid := gen_random_uuid();
  s_owner   uuid := gen_random_uuid();
  s_padmin  uuid := gen_random_uuid();
  s_appr    uuid := gen_random_uuid(); s_rep    uuid := gen_random_uuid(); s_count uuid := gen_random_uuid();
  s_post    uuid := gen_random_uuid(); s_conf   uuid := gen_random_uuid(); s_mixed uuid := gen_random_uuid();
  s_none    uuid := gen_random_uuid(); s_ended  uuid := gen_random_uuid(); s_future uuid := gen_random_uuid();
  s_support uuid := gen_random_uuid();
  u_admin uuid; u_appr uuid; u_rep uuid; u_count uuid; u_post uuid; u_conf uuid; u_mixed uuid;
  u_none uuid; u_ended uuid; u_future uuid; u_invited uuid; u_support uuid; u_service uuid;
  t_appr text; t_rep text; t_count text; t_post text; t_conf text; t_mixed text;
  t_none text; t_ended text; t_future text;
  v_a uuid; v_b uuid; v_p uuid;
  v_prior   erp_meta.platform_organisation;
  v_q uuid; v_contract uuid;
  v_step    text := 'provisioning';
  v_msg     text;
  v_seats   jsonb;
  v_seated  text;
  v_probe_seat text; v_probe_refused boolean; v_probe_msg text;
  v_full integer; v_light integer; v_disagree text;
  v_use_full numeric; v_use_light numeric; v_b_full numeric; v_b_light numeric;
  res jsonb; res_limits jsonb; v_after uuid;
  v_refused boolean; v_refused_msg text;
  v_light_row numeric; v_plan_users numeric;
begin
  select po.* into v_prior from erp_meta.platform_organisation po;

  begin
    v_step := 'three organisations are provisioned and their administrators join';
    perform set_config('request.jwt.claims', '', true);
    select * into ra from erp.provision_tenant('zzlua-' || v_tag, 'Light Users Customer',
                                               'admin@zzlua-' || v_tag || '.test', 'Customer Admin');
    v_a := ra.tenant_id;
    select * into rb from erp.provision_tenant('zzlub-' || v_tag, 'Light Users Owner''s Company',
                                               'owner@zzlub-' || v_tag || '.test', 'Platform Owner');
    v_b := rb.tenant_id;
    select * into rp from erp.provision_tenant('zzlup-' || v_tag, 'Light Users Platform',
                                               'admin@zzlup-' || v_tag || '.test', 'Platform Admin');
    v_p := rp.tenant_id;
    perform set_config('erp.job_tenant_id', '', true);
    insert into auth.users (id, email) values
      (s_admin,  'admin@zzlua-' || v_tag || '.test'),
      (s_owner,  'owner@zzlub-' || v_tag || '.test'),
      (s_padmin, 'admin@zzlup-' || v_tag || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
    values ('owner@zzlub-' || v_tag || '.test', s_owner, 'Platform Owner', 'owner');
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    u_admin := erp.claim_invitation(ra.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', s_owner)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', s_padmin)::text, true);
    perform erp.claim_invitation(rp.admin_token);

    v_step := 'five narrow roles, and a support visit, while the organisation is opened for them';
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_a);
    insert into erp.role (tenant_id, code, name, status) values
      (v_a, 'zz_approver',   'Suite approver',   'active'),
      (v_a, 'zz_reporter',   'Suite reporter',   'active'),
      (v_a, 'zz_counter',    'Suite counter',    'active'),
      (v_a, 'zz_poster',     'Suite poster',     'active'),
      (v_a, 'zz_configurer', 'Suite configurer', 'active');
    insert into erp.role_permission (tenant_id, role_id, permission_code)
    select v_a, ro.id, x.perm
      from (values ('zz_approver', 'procurement.read'), ('zz_approver', 'procurement.approve'),
                   ('zz_approver', 'finance.approve_payment'), ('zz_approver', 'sales.discount_approve'),
                   ('zz_approver', 'master_data.approve'),
                   ('zz_reporter', 'reporting.read'), ('zz_reporter', 'reporting.export'),
                   ('zz_reporter', 'finance.read'), ('zz_reporter', 'administration.audit_read'),
                   ('zz_counter', 'inventory.read'), ('zz_counter', 'inventory.count'),
                   ('zz_poster', 'finance.read'), ('zz_poster', 'finance.post'),
                   ('zz_configurer', 'administration.read'), ('zz_configurer', 'administration.configure')) as x(role_code, perm)
      join erp.role ro on ro.tenant_id = v_a and ro.code = x.role_code;
    -- As erp_platform_enter_tenant writes a visit: an active person holding
    -- the administrator role under a support-access reason.
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_a, s_support, 'person', 'active', 'Suite Support (Clove ERP support)',
            'support@zzlua-' || v_tag || '.test', 'en')
    returning id into u_support;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select v_a, u_support, r.id, 'Platform support support access: the light users suite'
      from erp.role r where r.tenant_id = v_a and r.code = 'administrator';
    perform erp_test.close_bootstrap_window(v_a);

    v_step := 'the people are invited and given their roles';
    select x.app_user_id, x.token into u_appr, t_appr from erp.invite_principal('approver@zzlua-' || v_tag || '.test', 'Avery Approver') x;
    select x.app_user_id, x.token into u_rep, t_rep from erp.invite_principal('reporter@zzlua-' || v_tag || '.test', 'Robin Reporter') x;
    select x.app_user_id, x.token into u_count, t_count from erp.invite_principal('counter@zzlua-' || v_tag || '.test', 'Casey Counter') x;
    select x.app_user_id, x.token into u_post, t_post from erp.invite_principal('poster@zzlua-' || v_tag || '.test', 'Pat Poster') x;
    select x.app_user_id, x.token into u_conf, t_conf from erp.invite_principal('configurer@zzlua-' || v_tag || '.test', 'Charlie Configurer') x;
    select x.app_user_id, x.token into u_mixed, t_mixed from erp.invite_principal('mixed@zzlua-' || v_tag || '.test', 'Morgan Reports And Posts') x;
    select x.app_user_id, x.token into u_none, t_none from erp.invite_principal('none@zzlua-' || v_tag || '.test', 'Noel No Role') x;
    select x.app_user_id, x.token into u_ended, t_ended from erp.invite_principal('ended@zzlua-' || v_tag || '.test', 'Eden Ended') x;
    select x.app_user_id, x.token into u_future, t_future from erp.invite_principal('future@zzlua-' || v_tag || '.test', 'Frankie Future') x;
    select x.app_user_id into u_invited from erp.invite_principal('invited@zzlua-' || v_tag || '.test', 'Ivy Invited') x;
    u_service := erp.create_service_principal('Suite integration');

    perform erp.grant_role(u_appr,    'zz_approver',   null, null, 'approves');
    perform erp.grant_role(u_rep,     'zz_reporter',   null, null, 'reads and exports reports');
    perform erp.grant_role(u_count,   'zz_counter',    null, null, 'counts stock');
    perform erp.grant_role(u_post,    'zz_poster',     null, null, 'posts journals');
    perform erp.grant_role(u_conf,    'zz_configurer', null, null, 'configures');
    perform erp.grant_role(u_mixed,   'zz_reporter',   null, null, 'reads reports');
    perform erp.grant_role(u_mixed,   'zz_poster',     null, null, 'and posts');
    perform erp.grant_role(u_ended,   'zz_reporter',   null, null, 'reads reports');
    perform erp.grant_role(u_ended,   'zz_poster',     null, null, 'posted until yesterday', current_date - 30, current_date - 1);
    perform erp.grant_role(u_future,  'zz_poster',     null, null, 'posts from tomorrow', current_date + 1);
    perform erp.grant_role(u_invited, 'zz_approver',   null, null, 'has not accepted yet');
    perform erp.grant_role(u_service, 'zz_poster',     null, null, 'posts from the integration');

    v_step := 'the people accept their invitations';
    perform set_config('request.jwt.claims', json_build_object('sub', s_appr)::text, true);   perform erp.claim_invitation(t_appr);
    perform set_config('request.jwt.claims', json_build_object('sub', s_rep)::text, true);    perform erp.claim_invitation(t_rep);
    perform set_config('request.jwt.claims', json_build_object('sub', s_count)::text, true);  perform erp.claim_invitation(t_count);
    perform set_config('request.jwt.claims', json_build_object('sub', s_post)::text, true);   perform erp.claim_invitation(t_post);
    perform set_config('request.jwt.claims', json_build_object('sub', s_conf)::text, true);   perform erp.claim_invitation(t_conf);
    perform set_config('request.jwt.claims', json_build_object('sub', s_mixed)::text, true);  perform erp.claim_invitation(t_mixed);
    perform set_config('request.jwt.claims', json_build_object('sub', s_none)::text, true);   perform erp.claim_invitation(t_none);
    perform set_config('request.jwt.claims', json_build_object('sub', s_ended)::text, true);  perform erp.claim_invitation(t_ended);
    perform set_config('request.jwt.claims', json_build_object('sub', s_future)::text, true); perform erp.claim_invitation(t_future);
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);

    v_step := 'reading each person''s seat';
    v_seats := jsonb_build_object(
      'administrator', erp.person_seat(u_admin),
      'approver', erp.person_seat(u_appr),
      'reporter', erp.person_seat(u_rep),
      'counter', erp.person_seat(u_count),
      'poster', erp.person_seat(u_post),
      'configurer', erp.person_seat(u_conf),
      'reports and posts', erp.person_seat(u_mixed),
      'no role', erp.person_seat(u_none),
      'posting ended yesterday', erp.person_seat(u_ended),
      'posts from tomorrow', erp.person_seat(u_future),
      'not yet accepted', erp.person_seat(u_invited),
      'support visit', erp.person_seat(u_support),
      'integration', erp.person_seat(u_service));
    select string_agg(s.seat, ', ') into v_seated
      from erp.person_seats(v_a) s
     where s.app_user_id in (u_support, u_service, u_none, u_future, u_invited);

    v_step := 'a permission nobody has classified';
    begin
      update erp_ref.permission set seat = null where code = 'reporting.export';
      v_probe_seat := erp.person_seat(u_rep);
      begin
        perform erp.assert_every_permission_has_a_seat();
        v_probe_refused := false;
        v_probe_msg := 'the assertion passed over an unclassified permission';
      exception when others then
        v_probe_refused := sqlerrm like 'CLOVEERP_PERMISSION_WITHOUT_SEAT%';
        v_probe_msg := left(sqlerrm, 100);
      end;
      raise exception 'zz_light_users_probe_undone';
    exception when others then
      if sqlerrm <> 'zz_light_users_probe_undone' then
        v_probe_msg := concat_ws('; ', v_probe_msg, left(sqlerrm, 100));
      end if;
    end;

    v_step := 'counting the organisations';
    select count(*) filter (where s.seat = 'full'), count(*) filter (where s.seat = 'light')
      into v_full, v_light
      from erp.person_seats(v_a) s;
    select string_agg(format('%s: %s alone, %s with the organisation', u.display_name,
                             erp.person_seat(u.id), coalesce(s.seat, 'none')), '; ')
      into v_disagree
      from erp.app_user u
      left join erp.person_seats(v_a) s on s.app_user_id = u.id
     where u.tenant_id = v_a
       and erp.person_seat(u.id) is distinct from coalesce(s.seat, 'none');
    v_use_full  := erp.entitlement_usage('users', v_a);
    v_use_light := erp.entitlement_usage('light_users', v_a);
    v_b_full    := erp.entitlement_usage('users', v_b);
    v_b_light   := erp.entitlement_usage('light_users', v_b);

    v_step := 'the platform owner, who belongs to another organisation, reads the console';
    perform set_config('request.jwt.claims', json_build_object('sub', s_owner)::text, true);
    res := public.erp_platform_seats(v_a);
    v_after := erp.current_tenant_id();
    perform set_config('request.jwt.claims', json_build_object('sub', s_admin)::text, true);
    begin
      perform public.erp_platform_seats(v_a);
      v_refused := false;
      v_refused_msg := 'a customer''s administrator read the console';
    exception when others then
      v_refused := sqlerrm like '%NOT_PLATFORM_STAFF%';
      v_refused_msg := left(sqlerrm, 100);
    end;

    v_step := 'the platform sells the customer six light users';
    perform set_config('request.jwt.claims', json_build_object('sub', s_owner)::text, true);
    perform erp.designate_platform_organisation('zzlup-' || v_tag, 'the light users suite');
    perform set_config('request.jwt.claims', json_build_object('sub', s_padmin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_p);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_p);
    v_q := erp.open_commercial_quote('LIGHT', 'Light Users Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30,
                                     'zzlua-' || v_tag);
    perform erp.add_quote_line(v_q, 'PLAN-STANDARD');
    perform erp.add_quote_line(v_q, 'USER-STANDARD', 2);
    perform erp.add_quote_line(v_q, 'LIGHT-STANDARD', 6);
    perform erp.submit_quote(v_q);
    perform erp.issue_quote(v_q);
    perform erp.quote_transition(v_q, 'accept', 'order form returned signed');

    v_step := 'the owner makes and signs the contract';
    perform set_config('request.jwt.claims', json_build_object('sub', s_owner)::text, true);
    v_contract := erp.create_contract_from_quote(v_q, 'zzlua-' || v_tag, 'Light Users Customer Ltd', 'Clove ERP Ltd',
                                                 current_date, 12, 'automatic', 90, 'England and Wales', 'annual');
    perform erp.sign_contract(v_contract, 'A. Customer, director', 'Platform Owner, director',
                              'agreement to the order form');
    select ce.limit_value into v_light_row
      from erp_meta.contract_entitlement ce
     where ce.contract_id = v_contract and ce.entitlement_code = 'light_users';
    select pe.limit_value into v_plan_users
      from erp_meta.plan_entitlement pe
     where pe.plan_code = 'standard' and pe.entitlement_code = 'users';
    res_limits := public.erp_platform_seats(v_a);
    perform set_config('request.jwt.claims', '', true);
  exception when others then
    v_msg := format('%s: %s', v_step, left(sqlerrm, 200));
  end;

  -- ── The verdicts ─────────────────────────────────────────────────────────

  return query select 'every permission says whether it needs a light or a full seat',
    v_msg is null and not exists (select 1 from erp.permission_seat_report()),
    coalesce(v_msg, (select string_agg(f.reference, ', ') from erp.permission_seat_report() f), 'none unclassified');

  return query select 'a person who only approves is light',
    coalesce(v_msg is null and v_seats ->> 'approver' = 'light', false),
    coalesce(v_msg, v_seats::text);

  return query select 'a person who only reads and exports reports is light',
    coalesce(v_msg is null and v_seats ->> 'reporter' = 'light', false),
    coalesce(v_msg, v_seats::text);

  return query select 'a person who only counts stock is light',
    coalesce(v_msg is null and v_seats ->> 'counter' = 'light', false),
    coalesce(v_msg, v_seats::text);

  return query select 'a person who can post or configure is full, and so is one who holds a full role among light ones',
    coalesce(v_msg is null
             and v_seats ->> 'poster' = 'full' and v_seats ->> 'configurer' = 'full'
             and v_seats ->> 'reports and posts' = 'full' and v_seats ->> 'administrator' = 'full', false),
    coalesce(v_msg, v_seats::text);

  return query select 'a grant that has ended reaches nothing, and one not yet begun reaches nothing yet',
    coalesce(v_msg is null and v_seats ->> 'posting ended yesterday' = 'light'
             and v_seats ->> 'posts from tomorrow' = 'none', false),
    coalesce(v_msg, v_seats::text);

  return query select 'somebody with no role, or who has not accepted their invitation, holds no seat',
    coalesce(v_msg is null and v_seats ->> 'no role' = 'none' and v_seats ->> 'not yet accepted' = 'none', false),
    coalesce(v_msg, v_seats::text);

  return query select 'a support visit and a service principal are never counted',
    coalesce(v_msg is null and v_seats ->> 'support visit' = 'none' and v_seats ->> 'integration' = 'none'
             and v_seated is null, false),
    coalesce(v_msg, format('%s; seated among them: %s', v_seats::text, coalesce(v_seated, 'nobody')));

  return query select 'a permission nobody has classified counts as full, and the assertion refuses it',
    coalesce(v_msg is null and v_probe_seat = 'full' and v_probe_refused
             and (select p.seat from erp_ref.permission p where p.code = 'reporting.export') = 'light', false),
    coalesce(v_msg, format('the reporter became %s; %s', coalesce(v_probe_seat, 'nothing'), coalesce(v_probe_msg, 'no answer')));

  return query select 'the meter counts full and light users from the same seats, one organisation at a time',
    coalesce(v_msg is null
             and v_full = 4 and v_light = 4 and v_disagree is null
             and v_use_full = v_full and v_use_light = v_light
             and v_b_full = 1 and v_b_light = 0, false),
    coalesce(v_msg, format('seats %s full, %s light; meter %s full, %s light; the other organisation %s and %s; disagreeing: %s',
                           v_full, v_light, v_use_full, v_use_light, v_b_full, v_b_light, coalesce(v_disagree, 'nobody')));

  return query select 'the console reads the meter, for an owner who belongs to another organisation',
    coalesce(v_msg is null
             and (res -> 'full' ->> 'used')::numeric = v_use_full
             and (res -> 'light' ->> 'used')::numeric = v_use_light
             and res -> 'full' ->> 'limit' is null and res -> 'light' ->> 'limit_from' is null
             and v_after = v_b, false),
    coalesce(v_msg, format('%s; the owner is in %s afterwards', coalesce(res::text, 'no answer'), coalesce(v_after::text, 'no organisation')));

  return query select 'a customer''s administrator cannot read the console',
    coalesce(v_msg is null and v_refused, false),
    coalesce(v_msg, v_refused_msg, 'no answer');

  return query select 'light users sold on a quote become the contract''s limit, and the console shows where each limit comes from',
    coalesce(v_msg is null
             and v_light_row = 6
             and (res_limits -> 'light' ->> 'limit')::numeric = 6
             and res_limits -> 'light' ->> 'limit_from' = 'contract'
             and res_limits -> 'full' ->> 'limit_from' = 'plan'
             and (res_limits -> 'full' ->> 'limit')::numeric is not distinct from v_plan_users, false),
    coalesce(v_msg, format('contract row %s; %s', coalesce(v_light_row::text, 'none'), coalesce(res_limits::text, 'no answer')));

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.contract where tenant_id = v_a;
  delete from erp_meta.subscription where tenant_id = v_a;
  delete from erp_meta.platform_organisation where tenant_id = v_p;
  if exists (select 1 from erp.tenant tn where tn.id = v_p) then
    perform erp.begin_tenant_purge(v_p);
    delete from erp.tenant where id = v_p;
    perform erp.end_tenant_purge();
  end if;
  if exists (select 1 from erp.tenant tn where tn.id = v_a) then
    perform erp.begin_tenant_purge(v_a);
    delete from erp.tenant where id = v_a;
    perform erp.end_tenant_purge();
  end if;
  if exists (select 1 from erp.tenant tn where tn.id = v_b) then
    perform erp.begin_tenant_purge(v_b);
    delete from erp.tenant where id = v_b;
    perform erp.end_tenant_purge();
  end if;
  delete from erp_meta.platform_staff where email = 'owner@zzlub-' || v_tag || '.test';
  delete from auth.users where id in (s_admin, s_owner, s_padmin);
  if v_prior.tenant_id is not null
     and not exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id) then
    delete from erp_meta.platform_organisation;
    insert into erp_meta.platform_organisation (tenant_id, tenant_code, designated_at, designated_by, reason)
    values (v_prior.tenant_id, v_prior.tenant_code, v_prior.designated_at, v_prior.designated_by, v_prior.reason);
  end if;

  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant tn where tn.id in (v_a, v_b, v_p))
    and not exists (select 1 from erp.tenant tn where tn.code like 'zzlu_-' || v_tag)
    and not exists (select 1 from erp_meta.contract c where c.tenant_code = 'zzlua-' || v_tag)
    and not exists (select 1 from erp_meta.platform_staff ps where ps.email = 'owner@zzlub-' || v_tag || '.test')
    and (select p.seat from erp_ref.permission p where p.code = 'reporting.export') = 'light'
    and (v_prior.tenant_id is null
         or exists (select 1 from erp_meta.platform_organisation po where po.tenant_id = v_prior.tenant_id)),
    'organisations, contract and staff gone, the classification as it was, and any designation that was there before is back';
end;
$$;

comment on function erp_test.light_users_suite() is
  'Who holds a light seat, a full seat or none; that the meter and the console '
  'count the same people; and that light users sold on a quote become the '
  'contract''s limit. Provisions its own zzlu organisations and removes them.';

create or replace function erp_test.assert_light_users_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 14;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from erp_test.light_users_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_LIGHT_USERS_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost.',
            hint = 'Update the expected count deliberately.';
  end if;
  if v_passed <> v_total then
    raise exception E'CLOVEERP_LIGHT_USERS_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail
      using hint = 'Read the failing cases above; each names what it found.';
  end if;
  return format('light users: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.light_users_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_light_users_suite() from public, anon, authenticated;

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
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_entitlements_enforceable();
select erp.assert_console_acts_in_the_organisation_it_names();
select erp.assert_every_permission_has_a_seat();
select erp_test.assert_light_users_suite();
