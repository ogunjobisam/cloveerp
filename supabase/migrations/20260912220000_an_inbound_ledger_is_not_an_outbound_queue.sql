-- erp.api_request is the wrong side of the gateway.
--
-- erp.assert_gateway_integrity() refuses a table other than erp.command that
-- "holds dispatchable outbound intent", and named erp.api_request. The shape
-- fooled it: a row with a method, a path, a checksum and a status code looks
-- like something waiting to be sent.
--
-- It is the opposite. erp.api_request is the idempotency ledger for requests
-- the product RECEIVES: an external caller presents a key, the row records
-- what was asked and what was answered, and a repeat of the same key returns
-- the stored response instead of doing the work twice. Nothing dispatches
-- from it and nothing ever will; there is no destination on the row.
--
-- erp_meta.gateway_exemption exists for exactly this — a table that trips the
-- shape test and should not, said out loud with a reason rather than by
-- loosening the test for everything.

insert into erp_meta.gateway_exemption (schema_name, table_name, rationale) values
  ('erp', 'api_request',
   'Inbound, not outbound. This is the idempotency ledger for API requests the product receives: method, path and request checksum identify the call, status_code and response record what was answered, and a repeat of the same idempotency key is served from the row rather than executed again. It carries no destination, no attempt count and no dispatch state, and nothing reads it looking for work to send.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

select erp.assert_gateway_integrity();
