-- I added a branch for a change-set item kind that already had one.
--
-- 20260912250000 taught erp.apply_change_set_item() to handle 'document_type'
-- items, on the finding that no such branch existed. It did exist.
-- 20260904150000 added it, calling erp.upsert_document_type() with a payload
-- shaped 'base_type' / 'numbering_rule' / 'state_machine' / 'posting_rule'.
-- I checked one earlier definition of the promoter, found nothing, and did not
-- check the later one that replaced it.
--
-- My branch sorted ahead of the real one in the same case expression, so it
-- shadowed it, and every existing producer of a document_type item hit a
-- contract it was not written for:
--
--   null value in column "base_type_code" of relation "document_type"
--   violates not-null constraint ... (requisition, null, Requisition, ...)
--
-- which is erp.configure_procurement() — a routine that has been promoting
-- document types correctly since September the 4th — being handed my stricter
-- payload contract. It broke the demonstration seed, so main died before the
-- check catalogue and is redder now than before that migration landed.
--
-- Worse, and more useful: 20260904150000 had already done the whole of what
-- 20260912250000 set out to do. It rewrote erp.configure_procurement_controls()
-- to emit the numbering rule and the document type as change-set items, with
-- create_permission procurement.match, for exactly the reason I gave. The two
-- whole-function rewrites on 9 and 10 September reverted it to direct inserts
-- and took the create_permission with it. That is the same regression
-- 20260912224000 patched half of, from the other end.
--
-- So: my branch goes, and the item payload becomes the one the promoter has
-- always understood. Nothing new is invented here; this restores what was
-- already right and had been rewritten away twice.

-- ── 1. Give the kind back to the branch that owns it ────────────────────────

do $undo$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);

  v_new := replace(v_def,
$old$    when 'document_type' then
      declare
        v_dt_rule   uuid;
        v_dt_entity uuid;
      begin
        if i.operation = 'remove' then
          update erp.document_type dt
             set status = 'inactive', updated_at = now()
           where dt.tenant_id = v_tenant and dt.code = (p ->> 'code');
        else
          select nr.id, nr.entity_id into v_dt_rule, v_dt_entity
            from erp.numbering_rule nr
           where nr.tenant_id = v_tenant
             and nr.code = coalesce(p ->> 'numbering_rule', p ->> 'code');

          if v_dt_rule is null then
            raise exception
              'CLOVEERP_PROMOTION_UNKNOWN_NUMBERING_RULE: document type % names numbering rule %, which this environment does not have',
              p ->> 'code', coalesce(p ->> 'numbering_rule', p ->> 'code')
              using errcode = '23503',
                    hint = 'A document type is applied after the rule that numbers it. Put the numbering_rule item before the document_type item in the change set.';
          end if;

          insert into erp.document_type (
            tenant_id, code, base_type_code, name, entity_id,
            state_machine_code, numbering_rule_id, posting_rule_code,
            create_permission, status)
          values (v_tenant, p ->> 'code', p ->> 'base_type_code', p ->> 'name',
                  v_dt_entity, p ->> 'state_machine_code', v_dt_rule,
                  p ->> 'posting_rule_code', p ->> 'create_permission', 'active')
          on conflict (tenant_id, code) do update
            set base_type_code = excluded.base_type_code,
                name = excluded.name,
                entity_id = excluded.entity_id,
                state_machine_code = excluded.state_machine_code,
                numbering_rule_id = excluded.numbering_rule_id,
                posting_rule_code = excluded.posting_rule_code,
                create_permission = excluded.create_permission,
                status = 'active',
                updated_at = now();
        end if;
      end;

    when 'numbering_rule' then$old$,
$new$    when 'numbering_rule' then$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the duplicate document_type branch 20260912250000 added is not in erp.apply_change_set_item()';
  end if;

  execute v_new;

  -- And the branch that was always there is reachable again.
  if position(E'perform erp.upsert_document_type(' in
              pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the original document_type branch is not there to fall back to';
  end if;
end
$undo$;

-- ── 2. The item, in the shape the promoter has always read ──────────────────

do $ctrl$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp.configure_procurement_controls(text,numeric,numeric,bigint)'::regprocedure);

  v_new := replace(v_def,
$old$      jsonb_build_object('kind','document_type','key','purchase_invoice','payload',
        jsonb_build_object(
          'code','purchase_invoice', 'base_type_code','invoice_reference',
          'name','Purchase invoice', 'state_machine_code','purchase_invoice',
          'numbering_rule','purchase_invoice', 'posting_rule_code','purchase_invoice',
          -- Base invoice_reference carries sales.invoice, which is right for
          -- sales_invoice and wrong here: every transition on this lifecycle
          -- wants procurement.match, so raising one must too.
          'create_permission','procurement.match'))));$old$,
$new$      -- The payload erp.upsert_document_type() reads, which is the one
      -- 20260904150000 wrote here before two rewrites replaced it with a
      -- direct insert. Base invoice_reference carries sales.invoice, which is
      -- right for sales_invoice and wrong here: every transition on this
      -- lifecycle wants procurement.match, so raising one must too.
      jsonb_build_object('kind','document_type','key','purchase_invoice','payload',
        jsonb_build_object('code','purchase_invoice',
          'base_type','invoice_reference','name','Purchase invoice',
          'numbering_rule','purchase_invoice','state_machine','purchase_invoice',
          'posting_rule','purchase_invoice',
          'create_permission','procurement.match'))));$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PROCUREMENT_CONTROLS_UNRECOGNISED: the document_type item 20260912250000 added is not the one this migration corrects';
  end if;

  execute v_new;
end
$ctrl$;

select erp.apply_execute_grants();
