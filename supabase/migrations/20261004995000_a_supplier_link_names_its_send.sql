set lock_timeout = '30s';

-- =============================================================================
-- 20261004995000  A supplier link names its send
-- -----------------------------------------------------------------------------
-- erp.assert_personal_data_register_sound() reads a column that refers to a
-- table holding personal data as one that may carry it, and
-- erp.supplier_response_link.document_email_id (20261004990000) refers to
-- erp.document_email, whose addresses and names are registered there. The
-- column is the send's id and nothing more: it carries no address, no name
-- and no message, and the send it names is kept, and erased, as that table's
-- own rows say. Exempt, with why.
-- =============================================================================

insert into erp_ref.personal_data_exemption (schema_name, table_name, column_name, rationale) values
  ('erp', 'supplier_response_link', 'document_email_id',
   'The id of the purchase order send a supplier''s answer link was minted for, nothing more: no address, name '
   'or message is copied here. The send''s addresses are registered on erp.document_email itself and kept for '
   'the document''s legal life, as that table''s exemptions say (20261004995000).')
on conflict do nothing;

select erp.assert_personal_data_register_sound();
