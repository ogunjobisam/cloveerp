-- Twenty findings, two causes, both in the document work.
--
-- 1. Thirteen refusals were registered with a plain insert into
--    erp_ref.refusal. erp.register_refusal() exists because a row in that
--    table is only half of a refusal: the other half is three keys in the
--    resource layer, which is what the client resolves and what an
--    organisation overrides to put its own wording in front of its own
--    people. Inserted directly, the register had the words and no screen
--    could reach them.
--
-- 2. Seven of them were reported "raised nowhere" while being raised on
--    every unready invoice. erp.issue_sales_invoice() takes the first
--    finding from erp.validate_sales_invoice_issue() and raises it by
--    value:
--
--      raise exception '%: % is missing on this invoice',
--        v_first ->> 'refusal', v_first ->> 'field'
--
--    which is neat and unreadable. erp.refusal_report() reads the source of
--    every routine looking for the token each raise names, because the
--    register's promise is that a code can be found in the code. A token
--    assembled at run time keeps that promise to the user and breaks it to
--    everyone who has to maintain the thing.
--
--    So the raise is spelled out, one branch per refusal, with the same
--    message and the same errcode. Longer, and greppable — which is the
--    whole point of a register.

-- ── 1. The half that was missing ────────────────────────────────────────────

select erp.register_refusal(f.code, f.refused, f.why, f.next_action)
  from erp_ref.refusal f
 where not exists (select 1 from erp_ref.resource r
                    where r.locale = 'en'
                      and r.key = erp_ref.refusal_key(f.code, 'next_action'));

-- ── 2. A raise the register can read ────────────────────────────────────────

do $issue$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.issue_sales_invoice(uuid,uuid,uuid)'::regprocedure);

  v_new := replace(v_def,
$old$    raise exception '%: % is missing on this invoice',
      v_first ->> 'refusal', v_first ->> 'field'
      using errcode = '23514';$old$,
$new$    -- Raised by literal so erp.refusal_report() can see it. Every branch
    -- says what the by-value raise said; the else is the safety net for a
    -- finding erp.validate_sales_invoice_issue() learns to return later.
    case v_first ->> 'refusal'
      when 'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING' then
        raise exception 'CLOVEERP_ISSUER_COMPANY_NUMBER_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING' then
        raise exception 'CLOVEERP_ISSUER_REGISTERED_OFFICE_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_ISSUER_VAT_NUMBER_MISSING' then
        raise exception 'CLOVEERP_ISSUER_VAT_NUMBER_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_INVOICE_TAX_POINT_MISSING' then
        raise exception 'CLOVEERP_INVOICE_TAX_POINT_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_INVOICE_NO_LINES' then
        raise exception 'CLOVEERP_INVOICE_NO_LINES: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_INVOICE_LINE_TAX_MISSING' then
        raise exception 'CLOVEERP_INVOICE_LINE_TAX_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      when 'CLOVEERP_CUSTOMER_ADDRESS_MISSING' then
        raise exception 'CLOVEERP_CUSTOMER_ADDRESS_MISSING: % is missing on this invoice', v_first ->> 'field' using errcode = '23514';
      else
        raise exception '%: % is missing on this invoice',
          v_first ->> 'refusal', v_first ->> 'field' using errcode = '23514';
    end case;$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_ISSUE_RAISE_UNRECOGNISED: erp.issue_sales_invoice() does not raise the readiness refusal by value, so this migration is patching a body that has already moved on';
  end if;

  execute v_new;
end
$issue$;

select erp.assert_refusals_name_next_action();
