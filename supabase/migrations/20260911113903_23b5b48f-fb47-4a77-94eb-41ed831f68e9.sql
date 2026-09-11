create or replace function erp.document_sequence_identity_is_fixed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    -- Only when the whole organisation is being erased, which is the one
    -- occasion the register has nothing left to number.
    if coalesce(current_setting('erp.purge_tenant_id', true), '') = old.tenant_id::text then
      return old;
    end if;
    raise exception 'CLOVEERP_SEQUENCE_IMMUTABLE: a numbering register is never deleted'
      using errcode = '42501';
  end if;
  if new.tenant_id <> old.tenant_id or new.document_kind <> old.document_kind then
    raise exception 'CLOVEERP_SEQUENCE_IMMUTABLE: a numbering register cannot change organisation or document type'
      using errcode = '42501';
  end if;
  if new.prefix <> old.prefix and old.next_number > 1 then
    raise exception 'CLOVEERP_SEQUENCE_PREFIX_FIXED: numbers have already been issued under prefix %, so it cannot change', old.prefix
      using errcode = '42501';
  end if;
  if new.next_number < old.next_number then
    raise exception 'CLOVEERP_SEQUENCE_MONOTONIC: a document number is never reused'
      using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function erp.document_issue_is_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if coalesce(current_setting('erp.purge_tenant_id', true), '') = old.tenant_id::text then
      return old;
    end if;
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: an issued document is never deleted; it is voided and replaced'
      using errcode = '42501';
  end if;

  if new.tenant_id        <> old.tenant_id
  or new.document_kind    <> old.document_kind
  or new.source_document_id <> old.source_document_id
  or new.sequence_prefix  <> old.sequence_prefix
  or new.sequence_number  <> old.sequence_number
  or new.issued_number    <> old.issued_number
  or new.contract_snapshot::text <> old.contract_snapshot::text
  or coalesce(new.template_version_id, '00000000-0000-0000-0000-000000000000'::uuid)
     <> coalesce(old.template_version_id, '00000000-0000-0000-0000-000000000000'::uuid)
  or coalesce(new.replaces_issue_id, '00000000-0000-0000-0000-000000000000'::uuid)
     <> coalesce(old.replaces_issue_id, '00000000-0000-0000-0000-000000000000'::uuid) then
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: the identity of an issue cannot be altered after the number was taken'
      using errcode = '42501';
  end if;

  if old.status in ('issued', 'sent')
     and (coalesce(new.storage_path, '') <> coalesce(old.storage_path, '')
          or coalesce(new.content_checksum, '') <> coalesce(old.content_checksum, '')) then
    raise exception 'CLOVEERP_ISSUE_IMMUTABLE: the issued file and its checksum cannot change'
      using errcode = '42501';
  end if;

  if new.status <> old.status and not (
       (old.status = 'reserved' and new.status in ('issued', 'void'))
    or (old.status = 'issued'   and new.status in ('sent', 'void'))) then
    raise exception 'CLOVEERP_ISSUE_STATE: an issue cannot move from % to %', old.status, new.status
      using errcode = '42501';
  end if;

  return new;
end $$;

select erp.assert_document_issue_sound();
