set lock_timeout = '30s';

-- =============================================================================
-- 20261007092000  A business partner's contact can be kept
-- -----------------------------------------------------------------------------
-- Found walking the demonstration on live, 4 October (J-107). A business
-- partner's people live in erp.party_contact, and three things read them: a
-- purchase order's email goes to the supplier's purchasing contact, else the
-- default one (erp.supplier_email_address); a quote goes to the customer's
-- default contact (erp.quote_recipients); and an erasure request names a
-- contact as its subject. Nothing on the desk writes one. A contact arrives
-- only through the party file under Imports, a demonstration's seed, or the
-- one commercial contact Set the quote's contact writes, so a buyer whose
-- supplier changed their orders address had no way to say so.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   A. A contact may end on the day it began. erp.party_contact's range check
--      was valid_to > valid_from, so a contact added in error could not be
--      ended until the next day and went on receiving orders until then. It
--      is now valid_to >= valid_from, as erp.user_role and
--      erp.approval_delegation already are: an empty range applies to no day,
--      and every reader already asks valid_to > current_date.
--   B. Four refusals: a contact that says neither who nor how to reach them
--      (or an address or number that cannot be one, or a kind not in the
--      list), one that is not this partner's, one that has ended, and one
--      whose personal details were erased on request.
--   C. erp.save_party_contact and its door public.erp_save_party_contact:
--      adds a contact, or changes one, with a kind (general, purchase orders,
--      invoices and payments, deliveries, other), a name, an email address, a
--      phone number and whether it is the partner's default. A partner's first
--      current contact becomes its default. One default to a partner, as Set
--      the quote's contact already keeps it.
--   D. erp.end_party_contact and its door public.erp_end_party_contact: the
--      contact stops being reached from today. It is never deleted: an
--      erasure request may still name it, and erasing overwrites the row's
--      personal details in place (erp.execute_erasure), so the row has to be
--      there to overwrite.
--   E. public.erp_party_contacts, which lists a partner's contacts, current
--      and ended, for its record on Common data.
--   F. Their write allowances, their place in the screen's help, and the
--      words the record says.
--   G. erp_test.party_contact_suite, which also proves a contact kept here is
--      what a purchase order's email goes to, and that an erasure still
--      overwrites it and then holds.
--
-- ── PERSONAL DATA ────────────────────────────────────────────────────────────
--
-- No column is added. name, email, phone, role_title and notes on
-- erp.party_contact are on the register already (erp_ref.personal_data_field,
-- subject kind contact), so an erasure overwrites them wherever these doors
-- wrote them, and erp.assert_personal_data_register_sound() runs at the end.
-- A contact whose details were erased is not written to again: that would put
-- a person's details back under the record their erasure certificate names.
--
-- ── THE PERMISSION ───────────────────────────────────────────────────────────
--
-- master_data.write, as for the rest of the party file (erp_create_party,
-- erp_set_party_address). The list authorises master_data.read.
--
-- On production: the range check on erp.party_contact is replaced by one that
-- every existing row already meets (a quiet table: no document, stock or
-- ledger path writes it). Three functions, three doors and their
-- registrations are added. No row of any organisation is changed.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. A contact may end on the day it began
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.party_contact drop constraint if exists party_contact_range;
alter table erp.party_contact
  add constraint party_contact_range check (valid_to is null or valid_to >= valid_from);

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The refusals
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_CONTACT_INVALID',
  'Recording a contact with neither a name nor an email address, an email address a message cannot reach, a phone number without its digits, or a kind not in the list.',
  'Orders and quotes are sent to a partner''s contacts, so a contact has to say who they are and how they are reached.',
  'Give a name or an email address, type the email address as name@example.com and the phone number with its digits, and choose the kind from the list.');

select erp.register_refusal('CLOVEERP_CONTACT_NOT_FOUND',
  'Changing or ending a contact that is not one of this business partner''s in this organisation.',
  'Only a contact kept on the partner''s record can be changed or ended there.',
  'Choose the contact from the partner''s record on Common data.');

select erp.register_refusal('CLOVEERP_CONTACT_ENDED',
  'Changing or ending a contact that has ended already.',
  'An ended contact is sent nothing and is kept only as a record of who was reached before.',
  'Add the person as a new contact if they are to be reached again.');

select erp.register_refusal('CLOVEERP_CONTACT_ERASED',
  'Changing a contact whose personal details were erased on request.',
  'The erasure overwrote that person''s details for good; writing new ones into the same record would undo what it promised.',
  'Add a new contact if the person has agreed to be reached again.');

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Adding or changing a contact
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.save_party_contact(
  p_party_id   uuid,
  p_contact_id uuid default null,
  p_kind       text default null,
  p_name       text default null,
  p_email      text default null,
  p_phone      text default null,
  p_is_default boolean default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant  uuid := erp.require_tenant_id();
  p         erp.party%rowtype;
  c         erp.party_contact%rowtype;
  v_kind    text := nullif(lower(btrim(coalesce(p_kind, ''))), '');
  v_name    text := nullif(btrim(coalesce(p_name, '')), '');
  v_email   text := nullif(btrim(coalesce(p_email, '')), '');
  v_phone   text := nullif(btrim(coalesce(p_phone, '')), '');
  v_digits  integer;
  v_default boolean;
  v_id      uuid;
begin
  -- A business partner's contact, added or changed (20261007092000). A change
  -- sets the contact to what is given: an empty name, email address or phone
  -- number clears it. An empty kind, or no answer on the default, keeps what
  -- the contact had.
  perform erp.authorise('master_data.write', null, null, null, 'party', p_party_id);

  select * into p from erp.party x where x.tenant_id = v_tenant and x.id = p_party_id;
  if not found then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;
  if p.merged_into_id is not null then
    raise exception 'CLOVEERP_PARTNER_MERGED: % was merged into another business partner', p.code
      using errcode = '23514', hint = 'Record it on the partner it was merged into.';
  end if;

  -- One writer at a time for this partner's contacts: the default is theirs.
  perform pg_advisory_xact_lock(hashtextextended(
    'party_contact:' || v_tenant::text || ':' || p_party_id::text, 0));

  if p_contact_id is not null then
    select * into c from erp.party_contact x
     where x.tenant_id = v_tenant and x.id = p_contact_id and x.party_id = p_party_id
       for update;
    if not found then
      raise exception 'CLOVEERP_CONTACT_NOT_FOUND: % is not a contact of %', p_contact_id, p.code
        using errcode = '23503', hint = 'Choose the contact from the partner''s record on Common data.';
    end if;
    if c.valid_to is not null and c.valid_to <= current_date then
      raise exception 'CLOVEERP_CONTACT_ENDED: the contact % stopped being reached on %', coalesce(c.name, c.email, ''), c.valid_to
        using errcode = '23514', hint = 'Add the person as a new contact if they are to be reached again.';
    end if;
    if exists (select 1 from erp.erasure_request r
                where r.tenant_id = v_tenant and r.subject_kind = 'contact'
                  and r.subject_id = c.id and r.status = 'executed') then
      raise exception 'CLOVEERP_CONTACT_ERASED: this contact''s personal details were erased on request'
        using errcode = '23514', hint = 'Add a new contact if the person has agreed to be reached again.';
    end if;
  end if;

  v_kind := coalesce(v_kind, c.contact_kind, 'commercial');
  if v_kind is distinct from c.contact_kind
     and v_kind not in ('commercial', 'purchasing', 'accounts', 'delivery', 'other') then
    raise exception 'CLOVEERP_CONTACT_INVALID: % is not a kind of contact', v_kind
      using errcode = '23514', hint = 'Choose the kind from the list.';
  end if;
  if v_name is null and v_email is null then
    raise exception 'CLOVEERP_CONTACT_INVALID: a contact needs a name or an email address'
      using errcode = '23514', hint = 'Give the person''s name, their email address, or both.';
  end if;
  if length(coalesce(v_name, '')) > 200 then
    raise exception 'CLOVEERP_CONTACT_INVALID: a name of % characters is longer than a name', length(v_name)
      using errcode = '23514', hint = 'Give the person''s name as it is written to them.';
  end if;
  if v_email is not null and (not erp.email_address_usable(v_email) or length(v_email) > 254) then
    raise exception 'CLOVEERP_CONTACT_INVALID: % is not an email address a message can reach', v_email
      using errcode = '23514', hint = 'Type the email address as name@example.com.';
  end if;
  if v_phone is not null then
    v_digits := length(regexp_replace(v_phone, '[^0-9]', '', 'g'));
    if v_digits < 5 or v_digits > 20 or length(v_phone) > 40 then
      raise exception 'CLOVEERP_CONTACT_INVALID: % is not a phone number', v_phone
        using errcode = '23514', hint = 'Type the phone number with its digits, such as 01904 123456 or +44 1904 123456.';
    end if;
  end if;

  -- A partner's first current contact is its default.
  v_default := coalesce(p_is_default, c.is_default,
                        not exists (select 1 from erp.party_contact x
                                     where x.tenant_id = v_tenant and x.party_id = p_party_id and x.is_default
                                       and x.valid_from <= current_date
                                       and (x.valid_to is null or x.valid_to > current_date)));

  if p_contact_id is null then
    insert into erp.party_contact (tenant_id, party_id, contact_kind, name, email, phone, is_default, valid_from)
    values (v_tenant, p_party_id, v_kind, v_name, v_email, v_phone, v_default, current_date)
    returning id into v_id;
  else
    v_id := c.id;
    update erp.party_contact x
       set contact_kind = v_kind, name = v_name, email = v_email, phone = v_phone,
           is_default = v_default, updated_at = now()
     where x.tenant_id = v_tenant and x.id = c.id;
  end if;

  -- One default to a partner.
  if v_default then
    update erp.party_contact x
       set is_default = false, updated_at = now()
     where x.tenant_id = v_tenant and x.party_id = p_party_id and x.id <> v_id and x.is_default;
  end if;

  return jsonb_build_object('contact_id', v_id, 'party_id', p_party_id, 'code', p.code,
                            'kind', v_kind, 'name', v_name, 'email', v_email, 'phone', v_phone,
                            'is_default', v_default, 'added', p_contact_id is null);
end;
$$;

revoke all on function erp.save_party_contact(uuid, uuid, text, text, text, text, boolean) from public, anon;

comment on function erp.save_party_contact(uuid, uuid, text, text, text, text, boolean) is
  'Adds a contact to a business partner, or changes one, with its kind, name, email address, phone number and whether '
  'it is the default (20261007092000). One default to a partner; a partner''s first current contact is its default. '
  'Refuses an ended contact and one whose details were erased. Authorises master_data.write.';

create or replace function public.erp_save_party_contact(
  p_party_id   uuid,
  p_contact_id uuid default null,
  p_kind       text default null,
  p_name       text default null,
  p_email      text default null,
  p_phone      text default null,
  p_is_default boolean default null)
returns jsonb
language sql
set search_path = ''
as $$
  select erp.save_party_contact(p_party_id, p_contact_id, p_kind, p_name, p_email, p_phone, p_is_default)
$$;

revoke all on function public.erp_save_party_contact(uuid, uuid, text, text, text, text, boolean) from public, anon;
grant execute on function public.erp_save_party_contact(uuid, uuid, text, text, text, text, boolean) to authenticated, service_role;

comment on function public.erp_save_party_contact(uuid, uuid, text, text, text, text, boolean) is
  'Adds or changes a business partner''s contact (20261007092000). Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Ending a contact
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.end_party_contact(p_contact_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  c        erp.party_contact%rowtype;
  v_to     date;
begin
  -- A contact stops being reached from today (20261007092000). The row stays,
  -- so an erasure request can still name it and overwrite it.
  perform erp.authorise('master_data.write', null, null, null, 'party_contact', p_contact_id);

  select * into c from erp.party_contact x
   where x.tenant_id = v_tenant and x.id = p_contact_id
     for update;
  if not found then
    raise exception 'CLOVEERP_CONTACT_NOT_FOUND: % is not a contact in this organisation', p_contact_id
      using errcode = '23503', hint = 'Choose the contact from the partner''s record on Common data.';
  end if;
  if c.valid_to is not null and c.valid_to <= current_date then
    raise exception 'CLOVEERP_CONTACT_ENDED: the contact % stopped being reached on %', coalesce(c.name, c.email, ''), c.valid_to
      using errcode = '23514', hint = 'Add the person as a new contact if they are to be reached again.';
  end if;

  v_to := greatest(current_date, c.valid_from);
  update erp.party_contact x
     set valid_to = v_to, is_default = false, updated_at = now()
   where x.tenant_id = v_tenant and x.id = c.id;

  return jsonb_build_object('contact_id', c.id, 'party_id', c.party_id, 'valid_to', v_to,
                            'was_default', c.is_default);
end;
$$;

revoke all on function erp.end_party_contact(uuid) from public, anon;

comment on function erp.end_party_contact(uuid) is
  'Ends a business partner''s contact from today, keeping the row for the record and for an erasure '
  '(20261007092000). Authorises master_data.write.';

create or replace function public.erp_end_party_contact(p_contact_id uuid)
returns jsonb
language sql
set search_path = ''
as $$ select erp.end_party_contact(p_contact_id) $$;

revoke all on function public.erp_end_party_contact(uuid) from public, anon;
grant execute on function public.erp_end_party_contact(uuid) to authenticated, service_role;

comment on function public.erp_end_party_contact(uuid) is
  'Ends a business partner''s contact from today (20261007092000). Authorises master_data.write.';

-- ─────────────────────────────────────────────────────────────────────────────
-- E. Reading them
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.erp_party_contacts(p_party_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_out    jsonb;
begin
  -- A business partner's contacts, current first, for its record on Common
  -- data (20261007092000).
  perform erp.authorise('master_data.read', null, null, null, 'party', p_party_id);

  if not exists (select 1 from erp.party x where x.tenant_id = v_tenant and x.id = p_party_id) then
    raise exception 'CLOVEERP_UNKNOWN_PARTY: % is not a business partner of this organisation', p_party_id
      using errcode = '23503', hint = 'Choose a business partner from the list.';
  end if;

  select coalesce(jsonb_agg(q.x order by q.ended, q.is_default desc, q.name nulls last, q.created_at), '[]'::jsonb)
    into v_out
    from (
      select (c.valid_to is not null and c.valid_to <= current_date) as ended,
             c.is_default, lower(c.name) as name, c.created_at,
             jsonb_build_object(
               'contact_id', c.id, 'party_id', c.party_id,
               'kind', c.contact_kind, 'name', c.name, 'email', c.email, 'phone', c.phone,
               'role_title', c.role_title, 'is_default', c.is_default,
               'valid_from', c.valid_from, 'valid_to', c.valid_to,
               'state', case when c.valid_to is not null and c.valid_to <= current_date then 'ended'
                             when c.valid_from > current_date then 'starts_later'
                             else 'current' end,
               'erased', exists (select 1 from erp.erasure_request r
                                  where r.tenant_id = c.tenant_id and r.subject_kind = 'contact'
                                    and r.subject_id = c.id and r.status = 'executed')) as x
        from erp.party_contact c
       where c.tenant_id = v_tenant and c.party_id = p_party_id) q;
  return v_out;
end;
$$;

revoke all on function public.erp_party_contacts(uuid) from public, anon;
grant execute on function public.erp_party_contacts(uuid) to authenticated, service_role;

comment on function public.erp_party_contacts(uuid) is
  'A business partner''s contacts, current and ended, with whether each is the default and whether its details were '
  'erased (20261007092000). Authorises master_data.read.';

-- ─────────────────────────────────────────────────────────────────────────────
-- F. Their registrations and their words
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_save_party_contact', 'erp.save_party_contact',
   'Adds or changes a business partner''s contact, keeping one default to a partner; authorises master_data.write.'),
  ('erp_end_party_contact', 'erp.end_party_contact',
   'Ends a business partner''s contact from today without deleting it; authorises master_data.write.'),
  ('erp_party_contacts', 'erp.authorise',
   'Reads only, but authorising writes an access-decision row via erp.log_access_decision(), so this is correctly VOLATILE and belongs on the register.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/master-data',
                                 array['erp_save_party_contact', 'erp_end_party_contact']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A business partner''s contacts on its record on Common data '
       '(20261007092000).'
  from (values
    ('Contacts'),
    ('Add a contact'),
    ('Change the contact'),
    ('End the contact'),
    ('Somebody at this partner, and how they are reached. A purchase order''s email goes to the purchase orders contact first, then the default one; a quote goes to the default one.'),
    ('The contact stops being sent anything from today. They stay on the record, ended.'),
    ('What this contact is reached for.'),
    ('Give a name, an email address, or both.'),
    ('Where emails to this contact go.'),
    ('With its digits, and the country code if it is abroad.'),
    ('The one emails to this partner go to when nothing more particular is asked for.'),
    ('General'),
    ('Purchase orders'),
    ('Invoices and payments'),
    ('Deliveries'),
    ('Phone'),
    ('No contact yet. A purchase order or quote emailed to this partner has nobody to go to.'),
    ('Details erased on request')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- G. The proof
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.party_contact_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_cases  integer := 0;
  v_tag    text := substr(md5(gen_random_uuid()::text), 1, 6);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  a3       uuid := gen_random_uuid();
  s_buy    uuid := gen_random_uuid();
  rb       record;
  rb2      record;
  res      jsonb;
  v_step   text := 'provisioning';
  v_state  text;
  v_supp uuid; v_cust uuid; v_gone uuid;
  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_req uuid;
  v_out  jsonb; v_out2 jsonb; v_list jsonb; v_addr jsonb;
  v_n    integer; v_n2 integer;
  v_err  text; v_err2 text; v_err3 text; v_err4 text; v_err5 text; v_err6 text;
begin
  begin
    -- ── The fixture ─────────────────────────────────────────────────────────
    v_step := 'an organisation with two administrators, a buyer, a supplier, a customer and a merged partner';
    perform set_config('request.jwt.claims', '', true);
    select * into rb from erp.provision_tenant(
      'zzpct-' || v_tag, 'Party Contact Suite',
      'admin@zzpct-' || v_tag || '.test', 'Contact Admin');
    update erp.environment set is_live = false where tenant_id = rb.tenant_id and is_self;
    insert into auth.users (id, email)
    values (a1, 'admin@zzpct-' || v_tag || '.test'),
           (a2, 'second@zzpct-' || v_tag || '.test'),
           (s_buy, 'buyer@zzpct-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(rb.admin_token);
    perform erp.ensure_demo_configuration(rb.tenant_id, rb.admin_user_id);
    res := public.erp_invite_principal('buyer@zzpct-' || v_tag || '.test', 'Bea Buyer');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'purchasing', null, null, 'buys');
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    res := public.erp_invite_principal('second@zzpct-' || v_tag || '.test', 'Sam Second');
    perform erp.grant_role((res ->> 'app_user_id')::uuid, 'administrator', null, null, 'erases with the first');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(res ->> 'token');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    v_supp := erp_test.cash_payment_supplier('ZPCTSUP');
    v_cust := (public.erp_create_party('ZPCTCUST', 'Contact Customer', 'customer') ->> 'party_id')::uuid;
    v_gone := (public.erp_create_party('ZPCTGONE', 'Merged Away', 'customer') ->> 'party_id')::uuid;
    update erp.party set merged_into_id = v_cust, status = 'inactive' where id = v_gone;

    -- ── 1. Its registers ────────────────────────────────────────────────────
    v_step := 'reading the registers';
    v_cases := v_cases + 1;
    case_name := 'the three doors are allowed and gated, the two that write are in the screen''s help, the four refusals and the words are registered, and a contact may end the day it began';
    passed := v_state is null
          and (select count(*) from erp_meta.public_write_allowance w
                where (w.function_name, w.gate) in (('erp_save_party_contact', 'erp.save_party_contact'),
                                                    ('erp_end_party_contact', 'erp.end_party_contact'),
                                                    ('erp_party_contacts', 'erp.authorise'))) = 3
          and exists (select 1 from erp_ref.help_topic h
                       where h.screen_path = '/master-data'
                         and h.actions @> array['erp_save_party_contact', 'erp_end_party_contact'])
          and (select count(*) from erp_ref.refusal f
                where f.code in ('CLOVEERP_CONTACT_INVALID', 'CLOVEERP_CONTACT_NOT_FOUND',
                                 'CLOVEERP_CONTACT_ENDED', 'CLOVEERP_CONTACT_ERASED')
                  and coalesce(f.next_action, '') <> '') = 4
          and (select count(*) from erp_ref.resource x
                where x.locale = 'en'
                  and x.key in (erp_ref.ui_key('Contacts'), erp_ref.ui_key('Add a contact'),
                                erp_ref.ui_key('End the contact'))) = 3
          and exists (select 1 from pg_constraint k
                       where k.conrelid = 'erp.party_contact'::regclass and k.conname = 'party_contact_range'
                         and pg_get_constraintdef(k.oid) like '%>=%')
          and (select count(*) from erp_ref.personal_data_field f
                where f.schema_name = 'erp' and f.table_name = 'party_contact'
                  and f.column_name in ('name', 'email', 'phone')) = 3;
    detail := coalesce(v_state, 'registers read');
    return next;

    -- ── 2. The first contact is the default, and orders go to it ────────────
    v_step := 'a supplier''s first contact added';
    begin perform public.erp_save_party_contact(v_supp, null, 'sales ledger', 'Kim Accounts', 'kim@supplier.test'); v_err := 'saved';
    exception when others then v_err := sqlerrm; end;
    v_out := public.erp_save_party_contact(v_supp, null, null, ' Kim Accounts ', ' kim@supplier.test ', '01904 123456');
    v_c1 := (v_out ->> 'contact_id')::uuid;
    v_addr := erp.supplier_email_address(v_supp);
    v_list := public.erp_party_contacts(v_supp);
    v_cases := v_cases + 1;
    case_name := 'a kind not in the list is refused; a partner''s first contact is general and its default, trimmed, the list reads it, and the supplier''s orders go to it';
    passed := v_state is null
          and v_err like 'CLOVEERP_CONTACT_INVALID%'
          and (v_out ->> 'is_default')::boolean
          and v_out ->> 'kind' = 'commercial'
          and v_addr ->> 'address' = 'kim@supplier.test'
          and jsonb_array_length(v_list) = 1
          and v_list -> 0 ->> 'name' = 'Kim Accounts'
          and v_list -> 0 ->> 'phone' = '01904 123456'
          and v_list -> 0 ->> 'state' = 'current'
          and (v_list -> 0 ->> 'erased')::boolean = false;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_out::text, v_addr::text, v_list::text));
    return next;

    -- ── 3. A purchase orders contact is where orders go ─────────────────────
    v_step := 'a purchase orders contact added, then made the default';
    v_out := public.erp_save_party_contact(v_supp, null, 'purchasing', 'Orders desk', 'orders@supplier.test', null, false);
    v_c2 := (v_out ->> 'contact_id')::uuid;
    v_addr := erp.supplier_email_address(v_supp);
    v_out2 := public.erp_save_party_contact(v_supp, v_c2, 'purchasing', 'Orders desk', 'orders@supplier.test', null, true);
    v_cases := v_cases + 1;
    case_name := 'a purchase orders contact is where the supplier''s orders go, and making it the default leaves the partner one default';
    passed := v_state is null
          and (v_out ->> 'is_default')::boolean = false
          and v_addr ->> 'address' = 'orders@supplier.test'
          and (v_out2 ->> 'is_default')::boolean
          and (select count(*) from erp.party_contact x where x.party_id = v_supp and x.is_default) = 1
          and (select x.is_default from erp.party_contact x where x.id = v_c1) = false;
    detail := coalesce(v_state, concat_ws(' / ', v_out::text, v_addr::text, v_out2::text));
    return next;

    -- ── 4. A change sets the contact to what is given ───────────────────────
    v_step := 'the first contact changed: a new address and no phone';
    v_out := public.erp_save_party_contact(v_supp, v_c1, null, 'Kim Accounts', 'kim.accounts@supplier.test', '');
    v_cases := v_cases + 1;
    case_name := 'a change sets the contact to what is given, clears what is left empty, and keeps the kind and the default when they are not answered';
    passed := v_state is null
          and (v_out ->> 'contact_id')::uuid = v_c1
          and exists (select 1 from erp.party_contact x
                       where x.id = v_c1 and x.email = 'kim.accounts@supplier.test' and x.phone is null
                         and x.contact_kind = 'commercial' and not x.is_default)
          and (select count(*) from erp.party_contact x where x.party_id = v_supp) = 2;
    detail := coalesce(v_state, v_out::text);
    return next;

    -- ── 5. What is not a contact is refused, and nothing is written ─────────
    v_step := 'contacts that are not one';
    select count(*) into v_n from erp.party_contact x where x.tenant_id = rb.tenant_id;
    begin perform public.erp_save_party_contact(v_cust, null, 'commercial', '', '', '01904 123456'); v_err := 'saved';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_cust, null, 'commercial', 'Lee', 'not an address'); v_err2 := 'saved';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_cust, null, 'commercial', 'Lee', null, 'call me'); v_err3 := 'saved';
    exception when others then v_err3 := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_cust, v_c1, 'commercial', 'Lee'); v_err4 := 'saved';
    exception when others then v_err4 := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_gone, null, 'commercial', 'Lee'); v_err5 := 'saved';
    exception when others then v_err5 := sqlerrm; end;
    select count(*) into v_n2 from erp.party_contact x where x.tenant_id = rb.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'no name and no address, an address that is not one, a phone number without digits, another partner''s contact and a merged partner are each refused, and nothing is written';
    passed := v_state is null
          and v_err like 'CLOVEERP_CONTACT_INVALID%'
          and v_err2 like 'CLOVEERP_CONTACT_INVALID%'
          and v_err3 like 'CLOVEERP_CONTACT_INVALID%'
          and v_err4 like 'CLOVEERP_CONTACT_NOT_FOUND%'
          and v_err5 like 'CLOVEERP_PARTNER_MERGED%'
          and v_n = v_n2;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3, v_err4, v_err5, v_n || '→' || v_n2));
    return next;

    -- ── 6. Ended the day it began, kept, and sent nothing ───────────────────
    v_step := 'the purchase orders contact ended the day it was added';
    v_out := public.erp_end_party_contact(v_c2);
    v_addr := erp.supplier_email_address(v_supp);
    v_list := public.erp_party_contacts(v_supp);
    v_err := null; v_err2 := null;
    begin perform public.erp_end_party_contact(v_c2); v_err := 'ended twice';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_supp, v_c2, null, 'Orders desk', 'orders@supplier.test'); v_err2 := 'changed';
    exception when others then v_err2 := sqlerrm; end;
    v_cases := v_cases + 1;
    case_name := 'a contact ended the day it began is kept on the record, ended, is sent no order, and is neither ended again nor changed';
    passed := v_state is null
          and (v_out ->> 'valid_to')::date = current_date
          and exists (select 1 from erp.party_contact x
                       where x.id = v_c2 and x.valid_to = current_date and not x.is_default)
          and v_addr ->> 'address' = 'kim.accounts@supplier.test'
          and jsonb_array_length(v_list) = 2
          and v_list -> 1 ->> 'contact_id' = v_c2::text
          and v_list -> 1 ->> 'state' = 'ended'
          and v_err like 'CLOVEERP_CONTACT_ENDED%'
          and v_err2 like 'CLOVEERP_CONTACT_ENDED%';
    detail := coalesce(v_state, concat_ws(' / ', v_out::text, v_addr::text, v_list::text, v_err, v_err2));
    return next;

    -- ── 7. An erasure overwrites a contact kept here, and holds ─────────────
    v_step := 'a customer contact added, then erased by two administrators';
    v_out := public.erp_save_party_contact(v_cust, null, 'accounts', 'Pat Payable', 'pat@customer.test', '+44 1904 765432', true);
    v_c3 := (v_out ->> 'contact_id')::uuid;
    v_req := erp.request_erasure('contact', v_c3, 'asked to be forgotten');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.execute_erasure(v_req);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_list := public.erp_party_contacts(v_cust);
    v_err := null;
    begin perform public.erp_save_party_contact(v_cust, v_c3, null, 'Pat Payable', 'pat@customer.test'); v_err := 'written back';
    exception when others then v_err := sqlerrm; end;
    v_out2 := public.erp_end_party_contact(v_c3);
    v_cases := v_cases + 1;
    case_name := 'an erasure overwrites a contact kept here; its details cannot be written back, and it can still be ended';
    passed := v_state is null
          and exists (select 1 from erp.party_contact x
                       where x.id = v_c3 and x.email is null and x.phone is null
                         and x.name is distinct from 'Pat Payable')
          and (v_list -> 0 ->> 'erased')::boolean
          and v_err like 'CLOVEERP_CONTACT_ERASED%'
          and (v_out2 ->> 'valid_to')::date = current_date
          and (select x.email from erp.party_contact x where x.id = v_c3) is null;
    detail := coalesce(v_state, concat_ws(' / ', v_list::text, v_err, v_out2::text));
    return next;

    -- ── 8. A buyer reads the contacts and keeps none ────────────────────────
    v_step := 'the buyer reads, adds, changes and ends';
    select count(*) into v_n from erp.party_contact x where x.tenant_id = rb.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', s_buy)::text, true);
    v_list := public.erp_party_contacts(v_supp);
    v_err := null; v_err2 := null; v_err3 := null;
    begin perform public.erp_save_party_contact(v_supp, null, 'purchasing', 'Buyer''s friend', 'friend@supplier.test'); v_err := 'added';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_supp, v_c1, null, 'Kim', 'kim@elsewhere.test'); v_err2 := 'changed';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_end_party_contact(v_c1); v_err3 := 'ended';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n2 from erp.party_contact x where x.tenant_id = rb.tenant_id;
    v_cases := v_cases + 1;
    case_name := 'somebody who reads common data sees a partner''s contacts but neither adds, changes nor ends one';
    passed := v_state is null
          and jsonb_array_length(v_list) = 2
          and v_err like 'CLOVEERP_PERMISSION_DENIED%'
          and v_err2 like 'CLOVEERP_PERMISSION_DENIED%'
          and v_err3 like 'CLOVEERP_PERMISSION_DENIED%'
          and v_n = v_n2
          and (select x.email from erp.party_contact x where x.id = v_c1) = 'kim.accounts@supplier.test';
    detail := coalesce(v_state, concat_ws(' / ', jsonb_array_length(v_list)::text, v_err, v_err2, v_err3));
    return next;

    -- ── 9. Another organisation sees none of it ─────────────────────────────
    v_step := 'a second organisation';
    perform set_config('request.jwt.claims', '', true);
    select * into rb2 from erp.provision_tenant(
      'zzpcx-' || v_tag, 'Party Contact Other',
      'admin@zzpcx-' || v_tag || '.test', 'Other Admin');
    update erp.environment set is_live = false where tenant_id = rb2.tenant_id and is_self;
    insert into auth.users (id, email) values (a3, 'admin@zzpcx-' || v_tag || '.test');
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(rb2.admin_token);
    v_err := null; v_err2 := null; v_err3 := null;
    begin perform public.erp_party_contacts(v_supp); v_err := 'read';
    exception when others then v_err := sqlerrm; end;
    begin perform public.erp_save_party_contact(v_supp, null, 'commercial', 'Intruder', 'in@other.test'); v_err2 := 'added';
    exception when others then v_err2 := sqlerrm; end;
    begin perform public.erp_end_party_contact(v_c1); v_err3 := 'ended';
    exception when others then v_err3 := sqlerrm; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_cases := v_cases + 1;
    case_name := 'another organisation can neither read, add to nor end this partner''s contacts';
    passed := v_state is null
          and v_err like 'CLOVEERP_UNKNOWN_PARTY%'
          and v_err2 like 'CLOVEERP_UNKNOWN_PARTY%'
          and v_err3 like 'CLOVEERP_CONTACT_NOT_FOUND%'
          and (select x.valid_to from erp.party_contact x where x.id = v_c1) is null;
    detail := coalesce(v_state, concat_ws(' / ', v_err, v_err2, v_err3));
    return next;

    perform set_config('request.jwt.claims', '', true);
    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_state := format('at "%s": %s', v_step, left(sqlerrm, 240));
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  if v_state is not null or v_cases <> c_expected then
    raise exception 'CLOVEERP_PARTY_CONTACT_SUITE_SHRANK: % case(s), expected %; the fixture stopped %',
      v_cases, c_expected, coalesce(v_state, 'nowhere, so a case was added or lost')
      using detail = coalesce(v_state, 'A case was added or lost. Update the count deliberately.');
  end if;
end;
$$;

revoke all on function erp_test.party_contact_suite() from public, anon;

comment on function erp_test.party_contact_suite() is
  'A business partner''s contact can be kept (20261007092000): the first is the default and orders go to it, a '
  'purchase orders contact is where orders go, a change sets what is given, what is not a contact is refused, one '
  'ended the day it began is kept and sent nothing, an erasure overwrites one and holds, a reader only reads, and '
  'another organisation sees none of it.';

create or replace function erp_test.assert_party_contact_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)), count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.party_contact_suite() s;
  if v_failed > 0 then
    raise exception 'CLOVEERP_PARTY_CONTACT_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total, E'\n  ' || v_detail
      using hint = 'A business partner''s contact was added, changed, ended or read where it should not be, or an erasure did not hold. Read the case that failed.';
  end if;
  if v_total <> 9 then
    raise exception 'CLOVEERP_PARTY_CONTACT_SUITE_SHRANK: % case(s), expected 9', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
  return format('party contact: %s/%s cases passed', v_total, v_total);
end;
$$;

revoke all on function erp_test.assert_party_contact_suite() from public, anon;

comment on function erp_test.assert_party_contact_suite() is
  'A business partner''s contacts can be added, changed and ended on its record on Common data, on master_data.write, '
  'and an erasure still overwrites them (20261007092000).';

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
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_personal_data_register_sound();
