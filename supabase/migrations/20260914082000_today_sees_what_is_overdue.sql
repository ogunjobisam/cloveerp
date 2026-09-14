-- =============================================================================
-- Today sees what is overdue, who is inside, and who signs in
--
-- PR 121 built the console's Today page and an organisation's own page from
-- the doors that already existed, and named what those doors could not tell it:
--
--   * an invoice past its due date anywhere on the deployment. erp_platform_revenue
--     gives sums, and erp_platform_invoices reads one contract at a time;
--   * an organisation waiting to be purged after a deletion request, as against
--     one merely suspended. erp_platform_tenants never returned deleted_at;
--   * who in an organisation last signed in, and when;
--   * which support windows are open anywhere, as against one's own.
--
-- Four reads, each for platform staff and each as narrow as its screen:
--
--   erp_platform_tenants          gains deleted_at.
--   erp_platform_open_invoices    every issued, unpaid contract invoice, with
--                                 how many days it is overdue.
--   erp_platform_support_windows  every support window still open.
--   erp_platform_people           one organisation's people, their roles and
--                                 when each last signed in. Operator and up:
--                                 it names people, which support staff reach
--                                 only when let in.
-- =============================================================================

-- ── The deletion request ─────────────────────────────────────────────────────

do $tenants$
declare
  v_sig    constant text := 'public.erp_platform_tenants()';
  v_def    text := pg_get_functiondef('public.erp_platform_tenants()'::regprocedure);
  v_needle constant text := $n$'suspended_at', t.suspended_at,$n$;
  v_new    constant text := $n$'suspended_at', t.suspended_at,
             'deleted_at', t.deleted_at,$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not name suspended_at exactly once', v_sig;
  end if;
  execute replace(v_def, v_needle, v_new);
end
$tenants$;

-- ── Invoices waiting for payment, everywhere ─────────────────────────────────

create or replace function public.erp_platform_open_invoices()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'invoice_id', i.id, 'reference', i.reference,
             'contract_id', c.id, 'tenant_code', i.tenant_code,
             'customer_legal_name', c.customer_legal_name,
             'period_start', i.period_start, 'period_end', i.period_end,
             'due_on', i.due_on, 'issued_at', i.issued_at,
             'currency', i.currency, 'total_minor', i.total_minor,
             'overdue', i.due_on < current_date,
             'days_overdue', greatest(current_date - i.due_on, 0))
           order by i.due_on, i.reference)
      from erp_meta.contract_invoice i
      join erp_meta.contract c on c.id = i.contract_id
     where i.status = 'issued'), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_open_invoices() is
  'Every contract invoice issued and not yet paid, across the deployment, with '
  'whether and by how many days it is past its due date. Platform staff.';

-- ── Support windows still open, everywhere ───────────────────────────────────

create or replace function public.erp_platform_support_windows()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('support');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'access_id', a.id, 'tenant_id', a.tenant_id,
             'tenant_code', t.code, 'tenant_name', t.name,
             'staff_email', a.staff_email, 'staff_role', a.staff_role,
             'reason', a.reason, 'is_write_access', a.is_write_access,
             'granted_at', a.granted_at, 'expires_at', a.expires_at)
           order by a.expires_at)
      from erp.support_access a
      join erp.tenant t on t.id = a.tenant_id
     where a.expires_at > now()), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_support_windows() is
  'Every support window still open on the deployment: which organisation, who, '
  'why, and until when. Platform staff.';

-- ── One organisation's people ────────────────────────────────────────────────

create or replace function public.erp_platform_people(p_tenant_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  perform erp_meta.require_platform('operator');
  if not exists (select 1 from erp.tenant t where t.id = p_tenant_id) then
    raise exception 'CLOVEERP_UNKNOWN_TENANT: % is not an organisation on this deployment', p_tenant_id
      using errcode = '23503',
            hint = 'It may have been purged. Read the organisation list again.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'principal_id', u.id, 'display_name', u.display_name, 'email', u.email,
             'kind', u.kind::text, 'status', u.status::text,
             'roles', coalesce((select jsonb_agg(r.code order by r.code)
                                  from erp.user_role ur
                                  join erp.role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                                 where ur.tenant_id = u.tenant_id and ur.app_user_id = u.id
                                   and (ur.valid_to is null or ur.valid_to >= current_date)), '[]'::jsonb),
             -- Read through to_jsonb so the column is optional: the platform's
             -- auth schema carries last_sign_in_at, a bare Postgres does not.
             'last_sign_in_at', (select to_jsonb(au) ->> 'last_sign_in_at'
                                   from auth.users au where au.id = u.auth_user_id))
           order by u.status::text, u.display_name)
      from erp.app_user u
     where u.tenant_id = p_tenant_id), '[]'::jsonb);
end;
$$;

comment on function public.erp_platform_people(uuid) is
  'An organisation''s people for its console page: name, address, kind, status, '
  'roles and when each last signed in. Operator and up, because it names people.';

-- ── Registration ─────────────────────────────────────────────────────────────

revoke all on function public.erp_platform_open_invoices() from public, anon;
revoke all on function public.erp_platform_support_windows() from public, anon;
revoke all on function public.erp_platform_people(uuid) from public, anon;
grant execute on function public.erp_platform_open_invoices() to authenticated, service_role;
grant execute on function public.erp_platform_support_windows() to authenticated, service_role;
grant execute on function public.erp_platform_people(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
select v.fn, 'erp_meta.require_platform',
       'Platform staff read. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.'
  from (values ('erp_platform_open_invoices'), ('erp_platform_support_windows'), ('erp_platform_people')) as v(fn)
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_platform_open_invoices',
   'Reads erp_meta.contract_invoice and erp_meta.contract, platform_internal, across every organisation. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_support_windows',
   'Reads erp.support_access and erp.tenant across every organisation. Gated by erp_meta.require_platform(''support'') on its first line.'),
  ('public', 'erp_platform_people',
   'Reads one organisation''s erp.app_user, roles and auth.users sign-in times. Gated by erp_meta.require_platform(''operator'') on its first line.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

-- ── The suite ────────────────────────────────────────────────────────────────

create or replace function erp_test.console_reads_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  rc record;
  ow uuid := gen_random_uuid(); sp uuid := gen_random_uuid(); ca uuid := gen_random_uuid();
  v_customer uuid; v_ccode text := 'zzcrc-' || substr(md5(random()::text), 1, 6);
  v_contract uuid; v_inv uuid; v_access jsonb;
  res jsonb; v_ok boolean; v_msg text;
begin
  select * into rc from erp.provision_tenant(v_ccode, 'Reads Customer', 'admin@zzcrc.test', 'Customer Admin');
  v_customer := rc.tenant_id;
  insert into auth.users (id, email) values (ow, 'owner@zzcr.test'), (sp, 'support@zzcr.test'), (ca, 'admin@zzcrc.test');
  insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role)
  values ('owner@zzcr.test', ow, 'Reads Owner', 'owner'), ('support@zzcr.test', sp, 'Reads Support', 'support');
  perform set_config('request.jwt.claims', json_build_object('sub', ca)::text, true);
  perform erp.claim_invitation(rc.admin_token);

  -- A contract with one invoice past its date and one not yet due.
  insert into erp_meta.contract
    (tenant_id, tenant_code, platform_tenant_id, quote_document_id, quote_number, quote_version,
     customer_legal_name, platform_legal_name, plan_code, term_kind, currency, annual_value_minor,
     commencement, initial_term_months, current_term_start, current_term_end, governing_law, created_by)
  values (v_customer, v_ccode, v_customer, gen_random_uuid(), 'CQ-TEST', 1,
          'Reads Customer Ltd', 'Clove ERP Ltd', 'starter', 'annual', 'GBP', 474000,
          current_date - 40, 12, current_date - 40, current_date + 325, 'England and Wales', 'owner@zzcr.test')
  returning id into v_contract;
  insert into erp_meta.contract_invoice
    (contract_id, tenant_id, tenant_code, seq, reference, period_start, period_end, due_on, currency,
     subscription_minor, total_minor, status, issued_at)
  values (v_contract, v_customer, v_ccode, 1, 'INV-ZZCR-1-' || v_ccode, current_date - 40, current_date - 10,
          current_date - 10, 'GBP', 39500, 39500, 'issued', now() - interval '40 days'),
         (v_contract, v_customer, v_ccode, 2, 'INV-ZZCR-2-' || v_ccode, current_date - 10, current_date + 20,
          current_date + 5, 'GBP', 39500, 39500, 'issued', now());
  select i.id into v_inv from erp_meta.contract_invoice i where i.contract_id = v_contract and i.seq = 1;

  perform set_config('request.jwt.claims', json_build_object('sub', sp)::text, true);
  res := public.erp_platform_open_invoices();
  return query select 'support sees every unpaid invoice, and which are past their date',
    (select (x ->> 'overdue')::boolean and (x ->> 'days_overdue')::integer = 10
       from jsonb_array_elements(res) x where x ->> 'invoice_id' = v_inv::text)
    and (select not (x ->> 'overdue')::boolean
           from jsonb_array_elements(res) x where x ->> 'reference' = 'INV-ZZCR-2-' || v_ccode),
    'one ten days overdue, one due in five';

  res := public.erp_platform_tenants();
  return query select 'the organisation list says whether deletion was requested',
    exists (select 1 from jsonb_array_elements(res) x where x ->> 'code' = v_ccode and x ? 'deleted_at'),
    'deleted_at present';

  begin
    perform public.erp_platform_people(v_customer);
    v_ok := false; v_msg := 'support read an organisation''s people';
  exception when others then
    v_ok := true; v_msg := left(sqlerrm, 70);
  end;
  return query select 'support cannot list an organisation''s people; they are named there', v_ok, v_msg;

  perform set_config('request.jwt.claims', json_build_object('sub', ow)::text, true);
  res := public.erp_platform_people(v_customer);
  return query select 'an owner lists an organisation''s people with their roles and last sign-in',
    exists (select 1 from jsonb_array_elements(res) x
             where x ->> 'email' = 'admin@zzcrc.test' and x -> 'roles' ? 'administrator'
               and x ? 'last_sign_in_at'),
    res::text;

  v_access := erp.grant_support_access(v_customer, 'Suite: reading support windows across the deployment', 1, false, null, null, null);
  res := public.erp_platform_support_windows();
  return query select 'every open support window is listed, with who and until when',
    exists (select 1 from jsonb_array_elements(res) x
             where x ->> 'tenant_code' = v_ccode and x ->> 'staff_email' = 'owner@zzcr.test'
               and (x ->> 'expires_at')::timestamptz > now()),
    coalesce(v_access::text, 'no access');

  -- ── Clean up ─────────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  delete from erp_meta.contract where id = v_contract;
  perform erp.begin_tenant_purge(v_customer);
  delete from erp.tenant where id = v_customer;
  perform erp.end_tenant_purge();
  delete from erp_meta.platform_staff where email like '%@zzcr.test';
  delete from auth.users where id in (ow, sp, ca);
  return query select 'the suite leaves nothing behind',
    not exists (select 1 from erp.tenant t where t.id = v_customer)
    and not exists (select 1 from erp_meta.contract c where c.id = v_contract),
    'organisation, contract and staff gone';
end;
$$;

create or replace function erp_test.assert_console_reads_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare v_total integer; v_passed integer; v_detail text;
begin
  create temp table if not exists _console_reads_result on commit drop as
    select * from erp_test.console_reads_suite();
  select count(*), count(*) filter (where passed),
         string_agg(format('  %s — %s', case_name, detail), E'\n') filter (where not passed)
    into v_total, v_passed, v_detail
    from _console_reads_result;
  if v_passed < v_total then
    raise exception E'CLOVEERP_CONSOLE_READS_SUITE_FAILED: %/%\n%', v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  return format('console reads: %s/%s', v_passed, v_total);
end;
$$;

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
select erp.assert_console_acts_in_the_organisation_it_names();
select erp_test.assert_console_reads_suite();
