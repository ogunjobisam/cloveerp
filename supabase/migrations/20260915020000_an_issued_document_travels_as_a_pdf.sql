-- =============================================================================
-- An issued document travels as a PDF
--
-- Since 20260914097300 an issued order form or contract invoice is emailed to
-- the customer the moment it is issued, but only as an email: a customer who
-- wanted to file the invoice, forward it to their accounts payable, or sign the
-- order form and send it back had nothing to file, forward or sign. The owner
-- approved on 15 September that both go as PDF documents too.
--
-- The PDF is drawn where the email is written, by the dispatch drain, from the
-- same payload (src/lib/pdf/commercial-document.ts). It is attached to the
-- email, and a copy is kept in the private document-output bucket under
-- commercial/<order-form|contract-invoice>/<email id>.pdf. What this file adds
-- is the database's half:
--
--   1. The letterhead. The payload carries the platform's legal name,
--      registered address and company number from erp_meta.platform_billing_details
--      when they are set, and the file name the document is attached under
--      (Order-form-<quote number>-v<version>.pdf, Invoice-<reference>.pdf),
--      decided here so the attachment and a download are named alike.
--   2. The stored copy. erp.complete_commercial_email() takes the copy's path,
--      size and SHA-256 when the drain kept one, and records them on the queue
--      row only when the archive holds an object at exactly the path that row
--      would be stored under; otherwise it records why there is no copy. A
--      PDF that could not be drawn, stored or attached is a reason on the row,
--      never a reason not to send the email.
--   3. The downloads. A customer's administrator reads the stored copies of
--      their own organisation's order forms and invoices through
--      erp_my_commercial_document(), and platform staff at support or above
--      read any of them through erp_platform_commercial_document(). Each door
--      returns where the copy is; the server function beside the screens
--      turns that into a signed link that lasts five minutes, as the issued
--      sales invoice does (20260911123400). Your agreement lists what can be
--      downloaded, and the console's send history says which sends kept one.
--
-- Proof: erp_test.commercial_document_suite() (8 cases), inside a block it
-- rolls back.
-- =============================================================================

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Where a stored copy is recorded
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp_meta.commercial_email add column if not exists document_path text;
alter table erp_meta.commercial_email add column if not exists document_bytes integer;
alter table erp_meta.commercial_email add column if not exists document_sha256 text;
alter table erp_meta.commercial_email add column if not exists document_problem text;

alter table erp_meta.commercial_email drop constraint if exists commercial_email_document_whole;
alter table erp_meta.commercial_email add constraint commercial_email_document_whole check (
  (document_path is null and document_bytes is null and document_sha256 is null)
  or (document_path ~ '^commercial/(order-form|contract-invoice)/[0-9a-f-]{36}\.pdf$'
      and document_bytes > 0
      and document_sha256 ~ '^[0-9a-f]{64}$'));

comment on column erp_meta.commercial_email.document_path is
  'Where the PDF sent with this email is kept in the document-output bucket, when '
  'the drain kept one. document_problem says why there is none.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The letterhead and the file name
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.platform_letterhead()
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- What the top of an order form or invoice says about who sent it, as the
  -- owner set it. Nothing that is not set is invented.
  select jsonb_strip_nulls(jsonb_build_object(
           'legal_name', d.legal_name,
           'registered_address', d.registered_address,
           'company_number', d.company_number))
    from erp_meta.platform_billing_details d
$$;

revoke all on function erp.platform_letterhead() from public, anon, authenticated;

comment on function erp.platform_letterhead() is
  'The platform''s legal name, registered address and company number, as far as '
  'an owner has set them, or null while nothing is set.';

create or replace function erp.commercial_document_filename(p_kind text, p_document_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case p_kind
    when 'order_form' then (
      select 'Order-form-' || regexp_replace(d.document_number, '[^A-Za-z0-9-]+', '-', 'g')
             || '-v' || cq.version || '.pdf'
        from erp.commercial_quote cq
        join erp.document d on d.tenant_id = cq.tenant_id and d.id = cq.document_id
       where cq.document_id = p_document_id)
    when 'contract_invoice' then (
      select 'Invoice-' || regexp_replace(i.reference, '[^A-Za-z0-9-]+', '-', 'g') || '.pdf'
        from erp_meta.contract_invoice i
       where i.id = p_document_id)
  end
$$;

revoke all on function erp.commercial_document_filename(text, uuid) from public, anon, authenticated;

comment on function erp.commercial_document_filename(text, uuid) is
  'The name an order form or invoice PDF is attached and downloaded under: '
  'Order-form-<quote number>-v<version>.pdf or Invoice-<reference>.pdf.';

-- The payload carries both.
do $payload$
declare
  v_sig   constant text := 'erp.commercial_email_payload(uuid)';
  v_def   text := pg_get_functiondef('erp.commercial_email_payload(uuid)'::regprocedure);
  v_pairs text[][] := array[
    array[$n$      'issued_at', q.order_form_issued_at,
      'issuer_email', e.requested_by));$n$,
          $n$      'issued_at', q.order_form_issued_at,
      'issued_on', (q.order_form_issued_at at time zone 'UTC')::date,
      -- The letterhead and the file name of the PDF (20260915020000).
      'letterhead', erp.platform_letterhead(),
      'filename', erp.commercial_document_filename('order_form', q.document_id),
      'issuer_email', e.requested_by));$n$],
    array[$n$    'plan_code', v_contract.plan_code,
    'issuer_email', e.requested_by));$n$,
          $n$    'plan_code', v_contract.plan_code,
    -- The letterhead and the file name of the PDF (20260915020000).
    'letterhead', erp.platform_letterhead(),
    'filename', erp.commercial_document_filename('contract_invoice', v_invoice.id),
    'issuer_email', e.requested_by));$n$]];
  i integer;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    if (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]) <> 1 then
      raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry "%" exactly once', v_sig, left(v_pairs[i][1], 80)
        using hint = 'A later migration changed what the commercial email payload carries. Read pg_get_functiondef() of it and patch that body.';
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  execute v_def;
  if position('erp.platform_letterhead()' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needles with pg_get_functiondef() of the function.';
  end if;
end
$payload$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The settle records the stored copy
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A new argument list is a new function, so the old one goes first. What it
-- did is kept statement for statement, proven against the live body before it
-- is dropped: the trusted-session refusal, the provider's id, the settle.

do $settle$
declare
  v_def text := pg_get_functiondef('erp.complete_commercial_email(uuid,text)'::regprocedure);
begin
  if position('erp.session_is_trusted()' in v_def) = 0
     or position('CLOVEERP_EMAIL_NOT_SENT' in v_def) = 0
     or position($s$set status = 'sent', provider_message_id = btrim(p_provider_message_id), sent_at = now(),$s$ in v_def) = 0
     or position('CLOVEERP_COMMERCIAL_EMAIL_NOT_SENDING' in v_def) = 0
     or position('document_path' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.complete_commercial_email(uuid, text) is not the 20260914097300 body this migration re-creates'
      using hint = 'Read the live body with pg_get_functiondef and re-create the settle from it under a new migration version.';
  end if;
end
$settle$;

drop function erp.complete_commercial_email(uuid, text);

create function erp.complete_commercial_email(
  p_id uuid,
  p_provider_message_id text,
  p_document_path text default null,
  p_document_bytes integer default null,
  p_document_sha256 text default null,
  p_document_problem text default null)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_kind    text;
  v_path    text := nullif(btrim(coalesce(p_document_path, '')), '');
  v_sha     text := lower(nullif(btrim(coalesce(p_document_sha256, '')), ''));
  v_problem text := nullif(btrim(coalesce(p_document_problem, '')), '');
begin
  if not erp.session_is_trusted() then
    raise exception 'CLOVEERP_UNTRUSTED_CONTEXT_ASSERTION: role % may not settle commercial email', current_user
      using errcode = '42501', hint = 'The dispatch drain settles these over its own connection; nobody signed in does.';
  end if;
  if coalesce(btrim(p_provider_message_id), '') = '' then
    raise exception 'CLOVEERP_EMAIL_NOT_SENT: an email is sent when the provider names it'
      using errcode = '22023', hint = 'Settle it as failed, or wait for the provider''s id.';
  end if;

  -- A stored copy is recorded only where this row's copy belongs, whole, and
  -- only when the archive holds it (20260915020000). Anything else is a reason
  -- there is no copy, and the email is still sent.
  select e.kind into v_kind from erp_meta.commercial_email e where e.id = p_id;
  if v_path is not null then
    if v_path <> format('commercial/%s/%s.pdf', replace(coalesce(v_kind, ''), '_', '-'), p_id)
       or coalesce(p_document_bytes, 0) <= 0
       or coalesce(v_sha, '') !~ '^[0-9a-f]{64}$' then
      v_problem := concat_ws('; ', v_problem, 'the stored copy was described wrongly, so it is not recorded');
      v_path := null;
    elsif not exists (select 1 from storage.objects o
                       where o.bucket_id = 'document-output' and o.name = v_path) then
      v_problem := concat_ws('; ', v_problem, 'the stored copy is not in the archive');
      v_path := null;
    end if;
  end if;

  update erp_meta.commercial_email
     set status = 'sent', provider_message_id = btrim(p_provider_message_id), sent_at = now(),
         claimed_by = null, lease_expires_at = null, failure_reason = null,
         document_path = v_path,
         document_bytes = case when v_path is not null then p_document_bytes end,
         document_sha256 = case when v_path is not null then v_sha end,
         document_problem = left(v_problem, 500)
   where id = p_id and status = 'sending';
  if not found then
    raise exception 'CLOVEERP_COMMERCIAL_EMAIL_NOT_SENDING: % is not being sent', p_id
      using errcode = '23514', hint = 'Its lease ran out and it went back to the queue; the next pass sends it.';
  end if;
end;
$$;

revoke all on function erp.complete_commercial_email(uuid, text, text, integer, text, text) from public, anon, authenticated;

comment on function erp.complete_commercial_email(uuid, text, text, integer, text, text) is
  'Settles a commercial email as sent with the provider''s id. When the drain kept '
  'a copy of the PDF it sent, records its path, size and SHA-256, but only if the '
  'archive holds an object at the path this row''s copy belongs under; otherwise, '
  'and when no PDF could be made or kept, records why. Trusted sessions only.';

-- The console's send history says which sends kept a copy.
do $sends$
declare
  v_sig    constant text := 'erp.commercial_email_sends(uuid,uuid)';
  v_def    text := pg_get_functiondef('erp.commercial_email_sends(uuid,uuid)'::regprocedure);
  v_needle constant text := $n$'requested_by', e.requested_by, 'created_at', e.created_at)$n$;
  v_new    constant text := $n$'requested_by', e.requested_by, 'created_at', e.created_at,
           'has_document', e.document_path is not null, 'document_bytes', e.document_bytes,
           'document_problem', e.document_problem)$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not end each send with who asked and when exactly once', v_sig
      using hint = 'A later migration changed the send history. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('''has_document''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$sends$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. What an organisation can download
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.organisation_commercial_documents(p_tenant_id uuid)
returns table (email_id uuid, kind text, document_id uuid, filename text, document_bytes integer,
               sent_at timestamptz)
language sql
stable
set search_path = ''
as $$
  -- The latest stored copy of each order form and invoice the organisation was
  -- sent: invoices of its own contracts, and order forms of quotes made for it
  -- or that its contracts were made from.
  select distinct on (x.kind, x.document_id)
         x.id, x.kind, x.document_id, erp.commercial_document_filename(x.kind, x.document_id),
         x.document_bytes, x.sent_at
    from (select e.id, e.kind, coalesce(e.quote_document_id, e.contract_invoice_id) as document_id,
                 e.document_bytes, e.sent_at
            from erp_meta.commercial_email e
           where e.status = 'sent'
             and e.document_path is not null
             and ((e.kind = 'contract_invoice'
                   and exists (select 1 from erp_meta.contract_invoice i
                                where i.id = e.contract_invoice_id and i.tenant_id = p_tenant_id))
                  or (e.kind = 'order_form'
                      and (e.tenant_id = p_tenant_id
                           or exists (select 1 from erp_meta.contract c
                                       where c.quote_document_id = e.quote_document_id
                                         and c.tenant_id = p_tenant_id))))) x
   order by x.kind, x.document_id, x.sent_at desc
$$;

revoke all on function erp.organisation_commercial_documents(uuid) from public, anon, authenticated;

comment on function erp.organisation_commercial_documents(uuid) is
  'The latest stored PDF of every order form and contract invoice an organisation '
  'was sent, with the name it downloads under.';

create or replace function public.erp_my_commercial_document(p_kind text, p_document_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  r        record;
begin
  perform erp.authorise('administration.read');
  select e.document_path, e.document_bytes, e.document_sha256, d.filename, d.sent_at
    into r
    from erp.organisation_commercial_documents(v_tenant) d
    join erp_meta.commercial_email e on e.id = d.email_id
   where d.kind = p_kind and d.document_id = p_document_id;
  if not found then
    raise exception 'CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND: this organisation has no stored copy of that document'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('storage_path', r.document_path, 'filename', r.filename,
                            'bytes', r.document_bytes, 'sha256', r.document_sha256, 'sent_at', r.sent_at);
end;
$$;

create or replace function public.erp_platform_commercial_document(p_email_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare r record;
begin
  perform erp_meta.require_platform('support');
  select e.document_path, e.document_bytes, e.document_sha256, e.sent_at,
         erp.commercial_document_filename(e.kind, coalesce(e.quote_document_id, e.contract_invoice_id)) as filename
    into r
    from erp_meta.commercial_email e
   where e.id = p_email_id and e.document_path is not null;
  if not found then
    raise exception 'CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND: that send kept no copy of its document'
      using errcode = 'P0002';
  end if;
  return jsonb_build_object('storage_path', r.document_path, 'filename', r.filename,
                            'bytes', r.document_bytes, 'sha256', r.document_sha256, 'sent_at', r.sent_at);
end;
$$;

-- Your agreement lists them.
do $agreement$
declare
  v_sig    constant text := 'erp.my_agreement()';
  v_def    text := pg_get_functiondef('erp.my_agreement()'::regprocedure);
  v_needle constant text := $n$    'payment_details', erp.platform_payment_details(),$n$;
  v_new    constant text := $n$    'payment_details', erp.platform_payment_details(),
    -- The PDFs this organisation was sent and can download (20260915020000).
    'commercial_documents', coalesce((select jsonb_agg(jsonb_build_object(
                                         'kind', cd.kind, 'document_id', cd.document_id, 'filename', cd.filename,
                                         'bytes', cd.document_bytes, 'sent_at', cd.sent_at)
                                       order by cd.sent_at desc)
                                       from erp.organisation_commercial_documents(v_tenant) cd), '[]'::jsonb),$n$;
begin
  if (length(v_def) - length(replace(v_def, v_needle, ''))) / length(v_needle) <> 1 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % does not carry its payment details exactly once, so it is not the 20260914097300 body', v_sig
      using hint = 'A later migration changed what the customer reads of its agreement. Read pg_get_functiondef() of it and patch that body.';
  end if;
  execute replace(v_def, v_needle, v_new);
  if position('erp.organisation_commercial_documents(v_tenant)' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % did not take the replacement', v_sig
      using hint = 'The replacement did not land. Compare the needle with pg_get_functiondef() of the function.';
  end if;
end
$agreement$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Registration
-- ═════════════════════════════════════════════════════════════════════════════

revoke all on function public.erp_my_commercial_document(text, uuid) from public, anon;
revoke all on function public.erp_platform_commercial_document(uuid) from public, anon;
grant execute on function public.erp_my_commercial_document(text, uuid) to authenticated, service_role;
grant execute on function public.erp_platform_commercial_document(uuid) to authenticated, service_role;

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_my_commercial_document', 'erp.authorise',
   'An organisation''s administrator reads where its own stored order form or invoice PDF is, to be handed a short signed link. Volatile because erp.authorise() records the decision.'),
  ('erp_platform_commercial_document', 'erp_meta.require_platform',
   'Platform staff read where a sent order form or invoice PDF is kept. The gate binds the staff identity on first sight, which is the write; the door must therefore be volatile.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale) values
  ('public', 'erp_my_commercial_document',
   'Reads erp_meta.commercial_email, erp_meta.contract_invoice and erp_meta.contract, platform_internal, for the caller''s own organisation only. Gated by erp.authorise(''administration.read'').'),
  ('public', 'erp_platform_commercial_document',
   'Reads erp_meta.commercial_email, platform_internal, across organisations. Gated by erp_meta.require_platform(''support'') on its first line.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

select erp.register_refusal('CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND',
  'Downloading an order form or invoice PDF that was not kept, or that belongs to another organisation.',
  'A copy is kept when the email that carried it was sent, and each organisation reads only its own.',
  'Ask Clove ERP to send the document again. A new send keeps a new copy.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Organisations, people and staff of its own, provisioned inside a block that
-- is rolled back at the end: the queue rows, the archive objects it writes and
-- the payment details it sets go with it. It runs on the live database when
-- this migration is deployed.

create or replace function erp_test.commercial_document_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  v_pcode    text;
  v_ccode    text;
  v_ocode    text;
  a_admin    uuid := gen_random_uuid();
  a_owner    uuid := gen_random_uuid();
  a_support  uuid := gen_random_uuid();
  a_customer uuid := gen_random_uuid();
  a_other    uuid := gen_random_uuid();
  v_step     text := 'starting';
  v_state    text;
  rp         record;
  rc         record;
  ro         record;
  c          record;
  v_platform uuid;
  v_customer uuid;
  v_q        uuid;
  v_number   text;
  v_contract uuid;
  v_inv1     uuid;
  v_inv2     uuid;
  v_reference text;
  v_form_id  uuid;
  v_inv1_id  uuid;
  v_inv2_id  uuid;
  v_form     jsonb;
  v_invoice  jsonb;
  v_sha      text := repeat('ab', 32);
  v_ok       boolean;
  v_msg      text;
  res        jsonb;

  ok_letter  boolean; msg_letter  text;
  ok_name    boolean; msg_name    text;
  ok_stored  boolean; msg_stored  text;
  ok_missing boolean; msg_missing text;
  ok_mine    boolean; msg_mine    text;
  ok_theirs  boolean; msg_theirs  text;
  ok_staff   boolean; msg_staff   text;
begin
  begin
    v_pcode := 'zzcdp-' || v_tag;
    v_ccode := 'zzcdc-' || v_tag;
    v_ocode := 'zzcdo-' || v_tag;

    -- ── Organisations, people and staff ─────────────────────────────────────
    v_step := 'the organisations are provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into rp from erp.provision_tenant(v_pcode, 'Clove Platform Documents', 'admin@' || v_pcode || '.test', 'Platform Admin');
    v_platform := rp.tenant_id;
    select * into rc from erp.provision_tenant(v_ccode, 'Document Customer Ltd', 'admin@' || v_ccode || '.test', 'Customer Admin');
    v_customer := rc.tenant_id;
    select * into ro from erp.provision_tenant(v_ocode, 'Another Customer Ltd', 'admin@' || v_ocode || '.test', 'Other Admin');
    insert into auth.users (id, email) values
      (a_admin, 'admin@' || v_pcode || '.test'),
      (a_owner, 'owner@' || v_pcode || '.test'),
      (a_support, 'support@' || v_pcode || '.test'),
      (a_customer, 'admin@' || v_ccode || '.test'),
      (a_other, 'admin@' || v_ocode || '.test');
    insert into erp_meta.platform_staff (email, auth_user_id, display_name, staff_role) values
      ('owner@' || v_pcode || '.test', a_owner, 'Document Owner', 'owner'),
      ('support@' || v_pcode || '.test', a_support, 'Document Support', 'support');
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.claim_invitation(rp.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    perform erp.claim_invitation(rc.admin_token);
    perform set_config('request.jwt.claims', json_build_object('sub', a_other)::text, true);
    perform erp.claim_invitation(ro.admin_token);

    v_step := 'the platform organisation is designated, sells the list and says who it is';
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    perform erp.designate_platform_organisation(v_pcode, 'the commercial document suite');
    res := public.erp_platform_set_billing_details('Suite Supplier Ltd', E'1 Nowhere Lane\nTesttown TT1 1TT', '00000000',
                                                   'Suite Supplier Ltd', '00-00-00', '00000000', null);
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp_test.reopen_bootstrap_window(v_platform);
    perform erp.set_up_selling();
    perform erp_test.close_bootstrap_window(v_platform);

    -- ── An order form and two invoices, issued ──────────────────────────────
    v_step := 'a quote is issued, accepted and made a contract';
    v_q := erp.open_commercial_quote('ZZDOC', 'Document Customer Ltd', 'CLOVE-LIST', 'annual', 12, 'GBP', 30, v_ccode);
    res := public.erp_set_quote_contact(v_q, 'Dana Buyer', 'dana@' || v_ccode || '.test');
    perform erp.add_quote_line(v_q, 'PLAN-STANDARD', 1, 10);
    perform erp.submit_quote(v_q);
    perform erp.issue_quote(v_q);
    select d.document_number into v_number from erp.document d where d.id = v_q;
    perform erp.quote_transition(v_q, 'accept', 'order form returned signed');
    perform set_config('request.jwt.claims', json_build_object('sub', a_owner)::text, true);
    v_contract := erp.create_contract_from_quote(v_q, v_ccode, 'Document Customer Ltd', 'Clove ERP Ltd', current_date,
                                                 12, 'automatic', 90, 'England and Wales', 'monthly');
    perform erp.sign_contract(v_contract, 'A. Customer, director', 'Document Owner, director', 'agreement to the order form');
    perform erp.generate_invoice_schedule(v_contract);
    select i.id, i.reference into v_inv1, v_reference
      from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq limit 1;
    select i.id into v_inv2 from erp_meta.contract_invoice i where i.contract_id = v_contract order by i.seq offset 1 limit 1;
    perform erp.issue_contract_invoice(v_inv1);
    perform erp.issue_contract_invoice(v_inv2);

    -- ── The claim, from a bare connection ───────────────────────────────────
    v_step := 'the drain claims from a connection with no organisation and nobody signed in';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    for c in select * from erp.claim_commercial_email_batch(500, 'zz-commercial-document') loop
      if c.email_kind = 'order_form' and c.email_id in (select e.id from erp_meta.commercial_email e where e.quote_document_id = v_q) then
        v_form_id := c.email_id;
        v_form := c.payload;
      elsif c.email_id in (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv1) then
        v_inv1_id := c.email_id;
        v_invoice := c.payload;
      elsif c.email_id in (select e.id from erp_meta.commercial_email e where e.contract_invoice_id = v_inv2) then
        v_inv2_id := c.email_id;
      end if;
    end loop;
    perform set_config('erp.job_tenant_id', '', true);

    ok_letter := v_form -> 'letterhead' ->> 'legal_name' = 'Suite Supplier Ltd'
             and v_form -> 'letterhead' ->> 'company_number' = '00000000'
             and v_form -> 'letterhead' ->> 'registered_address' = E'1 Nowhere Lane\nTesttown TT1 1TT'
             and v_invoice -> 'letterhead' = v_form -> 'letterhead'
             and (v_form ->> 'issued_on')::date = current_date
             and not (v_form -> 'letterhead' ? 'bank_account_name')
             and erp_test.keys_naming_cost_or_margin(v_form) is null;
    msg_letter := format('order form letterhead %s', coalesce((v_form -> 'letterhead')::text, 'none'));

    ok_name := v_form ->> 'filename' = 'Order-form-' || v_number || '-v1.pdf'
           and v_invoice ->> 'filename' = 'Invoice-' || v_reference || '.pdf'
           and v_inv2_id is not null;
    msg_name := format('%s and %s', coalesce(v_form ->> 'filename', 'none'), coalesce(v_invoice ->> 'filename', 'none'));

    -- ── Settled with a stored copy, and without one ─────────────────────────
    v_step := 'the drain settles the order form and the first invoice with the copies it kept';
    insert into storage.objects (bucket_id, name, metadata, user_metadata) values
      ('document-output', 'commercial/order-form/' || v_form_id || '.pdf',
       jsonb_build_object('mimetype', 'application/pdf', 'size', 2048), jsonb_build_object('sha256', v_sha)),
      ('document-output', 'commercial/contract-invoice/' || v_inv1_id || '.pdf',
       jsonb_build_object('mimetype', 'application/pdf', 'size', 4096), jsonb_build_object('sha256', v_sha));
    perform erp.complete_commercial_email(v_form_id, 'zz-provider-form',
                                          'commercial/order-form/' || v_form_id || '.pdf', 2048, v_sha, null);
    perform erp.complete_commercial_email(v_inv1_id, 'zz-provider-inv1',
                                          'commercial/contract-invoice/' || v_inv1_id || '.pdf', 4096, upper(v_sha), null);
    ok_stored := (select e.status = 'sent' and e.document_path = 'commercial/order-form/' || v_form_id || '.pdf'
                     and e.document_bytes = 2048 and e.document_sha256 = v_sha and e.document_problem is null
                    from erp_meta.commercial_email e where e.id = v_form_id)
             and (select e.document_sha256 = v_sha and e.document_bytes = 4096
                    from erp_meta.commercial_email e where e.id = v_inv1_id);
    msg_stored := 'path, size and SHA-256 recorded on both rows';

    v_step := 'the second invoice is settled with a copy the archive does not hold';
    perform erp.complete_commercial_email(v_inv2_id, 'zz-provider-inv2',
                                          'commercial/contract-invoice/' || v_inv2_id || '.pdf', 4096, v_sha,
                                          'the attachment was sent');
    ok_missing := (select e.status = 'sent' and e.provider_message_id = 'zz-provider-inv2'
                      and e.document_path is null and e.document_bytes is null and e.document_sha256 is null
                      and e.document_problem = 'the attachment was sent; the stored copy is not in the archive'
                     from erp_meta.commercial_email e where e.id = v_inv2_id);
    msg_missing := coalesce((select e.status || ': ' || coalesce(e.document_problem, 'no problem')
                               from erp_meta.commercial_email e where e.id = v_inv2_id), 'no row');

    -- ── The customer's administrator downloads their own ────────────────────
    v_step := 'the customer''s administrator reads its stored copies';
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    res := public.erp_my_commercial_document('contract_invoice', v_inv1);
    ok_mine := res ->> 'storage_path' = 'commercial/contract-invoice/' || v_inv1_id || '.pdf'
           and res ->> 'filename' = 'Invoice-' || v_reference || '.pdf';
    res := public.erp_my_commercial_document('order_form', v_q);
    ok_mine := ok_mine and res ->> 'storage_path' = 'commercial/order-form/' || v_form_id || '.pdf';
    res := erp.my_agreement();
    ok_mine := ok_mine
           and jsonb_array_length(res -> 'commercial_documents') = 2
           and not exists (select 1 from jsonb_array_elements(res -> 'commercial_documents') x
                            where (x ->> 'document_id')::uuid = v_inv2);
    begin
      perform public.erp_my_commercial_document('contract_invoice', v_inv2);
      ok_mine := false; msg_mine := 'a send that kept no copy was downloadable';
    exception when others then
      ok_mine := ok_mine and sqlerrm like 'CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND%';
      msg_mine := 'the order form and the first invoice; the second kept no copy';
    end;

    v_step := 'another organisation''s administrator asks for them';
    perform set_config('request.jwt.claims', json_build_object('sub', a_other)::text, true);
    ok_theirs := true; msg_theirs := '';
    begin
      perform public.erp_my_commercial_document('contract_invoice', v_inv1);
      ok_theirs := false; msg_theirs := 'another organisation downloaded the invoice; ';
    exception when others then
      ok_theirs := sqlerrm like 'CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND%';
      msg_theirs := 'invoice: ' || left(sqlerrm, 60) || '; ';
    end;
    begin
      perform public.erp_my_commercial_document('order_form', v_q);
      ok_theirs := false; msg_theirs := msg_theirs || 'another organisation downloaded the order form';
    exception when others then
      ok_theirs := ok_theirs and sqlerrm like 'CLOVEERP_COMMERCIAL_DOCUMENT_NOT_FOUND%';
      msg_theirs := msg_theirs || 'order form: ' || left(sqlerrm, 60);
    end;
    ok_theirs := ok_theirs
             and jsonb_array_length(coalesce(erp.my_agreement() -> 'commercial_documents', '[]'::jsonb)) = 0;

    -- ── Platform staff ──────────────────────────────────────────────────────
    v_step := 'platform staff read a stored copy';
    perform set_config('request.jwt.claims', json_build_object('sub', a_support)::text, true);
    res := public.erp_platform_commercial_document(v_inv1_id);
    ok_staff := res ->> 'storage_path' = 'commercial/contract-invoice/' || v_inv1_id || '.pdf'
            and exists (select 1 from jsonb_array_elements(public.erp_platform_commercial_emails(null, v_contract) -> 'sends') x
                         where (x ->> 'id')::uuid = v_inv1_id and (x ->> 'has_document')::boolean
                           and (x ->> 'document_bytes')::integer = 4096);
    perform set_config('request.jwt.claims', json_build_object('sub', a_customer)::text, true);
    begin
      perform public.erp_platform_commercial_document(v_inv1_id);
      ok_staff := false; msg_staff := 'a customer read the platform''s copy';
    exception when others then
      ok_staff := ok_staff and sqlerrm like 'CLOVEERP_NOT_PLATFORM_STAFF%';
      msg_staff := 'support reads it; a customer is refused: ' || left(sqlerrm, 60);
    end;

    v_step := 'done';
    raise exception 'ZZ_COMMERCIAL_DOCUMENT_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_COMMERCIAL_DOCUMENT_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'the payload carries the letterhead the owner set, and nothing of the bank details beside it';
  passed := v_state is null and coalesce(ok_letter, false);
  detail := coalesce(v_state, msg_letter);
  return next;

  case_name := 'the payload names the PDF as the attachment and the download are named';
  passed := v_state is null and coalesce(ok_name, false);
  detail := coalesce(v_state, msg_name);
  return next;

  case_name := 'the settle records the stored copy''s path, size and SHA-256';
  passed := v_state is null and coalesce(ok_stored, false);
  detail := coalesce(v_state, msg_stored);
  return next;

  case_name := 'a copy the archive does not hold is not recorded, says why, and the email is still sent';
  passed := v_state is null and coalesce(ok_missing, false);
  detail := coalesce(v_state, msg_missing);
  return next;

  case_name := 'a customer''s administrator downloads their own organisation''s order form and invoice';
  passed := v_state is null and coalesce(ok_mine, false);
  detail := coalesce(v_state, msg_mine);
  return next;

  case_name := 'another organisation''s administrator is refused both, and sees none listed';
  passed := v_state is null and coalesce(ok_theirs, false);
  detail := coalesce(v_state, msg_theirs);
  return next;

  case_name := 'platform staff at support read a stored copy, and somebody who is not staff is refused';
  passed := v_state is null and coalesce(ok_staff, false);
  detail := coalesce(v_state, msg_staff);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in (v_pcode, v_ccode, v_ocode))
        and not exists (select 1 from auth.users au
                         where au.id in (a_admin, a_owner, a_support, a_customer, a_other))
        and not exists (select 1 from storage.objects o
                         where o.bucket_id = 'document-output'
                           and o.name in ('commercial/order-form/' || coalesce(v_form_id::text, '') || '.pdf',
                                          'commercial/contract-invoice/' || coalesce(v_inv1_id::text, '') || '.pdf'))
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisations, people, staff, emails, archive objects, payment details and every setting went with the block';
  return next;
end;
$$;

revoke all on function erp_test.commercial_document_suite() from public, anon, authenticated;

create or replace function erp_test.assert_commercial_document_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 8;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _commercial_document_result on commit drop as
    select * from erp_test.commercial_document_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _commercial_document_result s;
  drop table _commercial_document_result;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_COMMERCIAL_DOCUMENT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_COMMERCIAL_DOCUMENT_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('commercial documents: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_commercial_document_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
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
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_suite_verdicts_strict();
select erp.assert_document_archive_sound();
select erp_test.assert_commercial_email_suite();
select erp_test.assert_commercial_document_suite();
