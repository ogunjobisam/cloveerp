-- ─────────────────────────────────────────────────────────────────────────────
-- A report cannot outlive the KPI it names.
--
-- Found in Phase 2 of the production-readiness pass, doing the most ordinary
-- thing a new organisation does: apply the base pack.
--
--   select erp.promote_change_set(...);
--   ERROR: ERPWARE_UNKNOWN_KPI: report supplier_performance names supplier_reject_rate
--
-- The base pack ships the report `supplier_performance` with no capability
-- gate, and the KPI `supplier_reject_rate` gated on quality_inspection. A
-- default organisation has quality_inspection off, so the KPI is held back and
-- the report is not; erp.upsert_report then refuses a report naming a KPI that
-- does not exist, and the whole promotion fails.
--
-- What that costs is the entire pack. The change set stops at 'approved' and
-- nothing lands — no roles, no segregation-of-duties rules, no approval bands,
-- no reason codes. The organisation is left with the single administrator
-- provisioning gave it and no role library at all, which is where the
-- production-readiness pass found it.
--
-- CI did not catch this because the acceptance suite enables the capabilities
-- before applying the pack. The default path — the one every real onboarding
-- takes — was the untested one.
--
-- erp.plan_content_pack already holds back a report whose governed view has not
-- arrived, and says so through an advisory. This is the same rule for the same
-- reason, applied to the other thing a report depends on.
--
-- Scanned every pack for the shape rather than fixing the one instance: base is
-- the only pack with a report/KPI capability mismatch, and supplier_performance
-- is the only one where the report is looser than the KPI. count_accuracy is
-- the harmless direction — the report is gated more tightly than its KPIs.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION erp.plan_content_pack(p_pack_code text)
 RETURNS TABLE(object_kind text, object_key text, operation erp.change_operation, payload jsonb, effect text, is_decision boolean, seq integer)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with item as (
    select pi.*,
           case when pi.is_decision and d.answer is not null
                then pi.payload || d.answer
                else pi.payload end as effective_payload
      from erp_ref.pack_item pi
      left join erp.pack_decision d
        on d.tenant_id = erp.require_tenant_id()
       and d.pack_code = pi.pack_code
       and d.object_kind = pi.object_kind
       and d.object_key = pi.object_key
     where pi.pack_code = p_pack_code
       and (pi.requires_capability is null
            or erp.capability_enabled(pi.requires_capability))
       -- A report reads a governed view, and the view comes with a module
       -- installer, not with the pack. Until that module is installed the
       -- report is held back — the same additive rule as a capability that
       -- is off — and erp.pack_conflicts() says which module brings it.
       and (pi.object_kind <> 'report'
            or pi.payload -> 'version' ->> 'view' is null
            or exists (
              select 1 from erp.governed_view gv
               where gv.tenant_id = erp.require_tenant_id()
                 and gv.code = pi.payload -> 'version' ->> 'view'))
       -- And the same rule for the KPIs a report names. erp.upsert_report
       -- refuses a report naming a KPI that does not exist, and the base pack
       -- ships supplier_performance — ungated — naming supplier_reject_rate,
       -- which is gated on quality_inspection. On a default organisation the
       -- KPI is held back and the report is not, so promoting the base pack
       -- died with ERPWARE_UNKNOWN_KPI and installed nothing: no roles, no
       -- segregation-of-duties rules, no approval bands. A report whose KPI is
       -- not coming is held back the same way its missing view holds it back.
       and (pi.object_kind <> 'report'
            or pi.payload ->> 'kpi_codes' is null
            or not exists (
              select 1 from unnest(string_to_array(pi.payload ->> 'kpi_codes', ',')) kc
               where trim(kc) <> ''
                 and not exists (select 1 from erp.kpi k
                                  where k.tenant_id = erp.require_tenant_id()
                                    and k.code = trim(kc))
                 and not exists (select 1 from erp_ref.pack_item ki
                                  where ki.pack_code = pi.pack_code
                                    and ki.object_kind = 'kpi'
                                    and ki.object_key = trim(kc)
                                    and (ki.requires_capability is null
                                         or erp.capability_enabled(ki.requires_capability)))))
  ),
  -- What a pack it already applied gave this organisation. Needed because
  -- three of the eleven pack-installable kinds — uom, location, account — are
  -- deliberately absent from erp.configuration_manifest(): they are master
  -- data, and putting them in the manifest would put them in every rollback
  -- snapshot, which would make undoing a configuration change undo a
  -- warehouse's bins.
  already as (
    select csi.object_kind, csi.object_key, csi.payload
      from erp.change_set_item csi
      join erp.tenant_pack tp
        on tp.tenant_id = csi.tenant_id and tp.change_set_id = csi.change_set_id
     where csi.tenant_id = erp.require_tenant_id()
       and tp.status = 'applied'
  )
  select i.object_kind, i.object_key, i.operation, i.effective_payload,
         case when m.object_key is null then 'creates' else 'updates' end,
         i.is_decision, i.seq
    from item i
    left join erp.configuration_manifest() m
      on m.object_kind = i.object_kind and m.object_key = i.object_key
   -- §11.7: "the change set contains only what is missing". Containment, not
   -- equality: a pack payload is a subset of what the manifest emits, so
   -- comparing hashes would mark everything missing for ever.
   -- coalesced, not bare: m.content is NULL when the organisation holds
   -- nothing of that kind, NULL @> anything is NULL, and `not NULL` is NULL —
   -- so the first version of this line silently planned nothing at all for a
   -- brand new organisation, which is the one case that matters most.
   where not (coalesce(m.content, '{}'::jsonb) @> i.effective_payload)
     and not exists (
       select 1 from already a
        where a.object_kind = i.object_kind and a.object_key = i.object_key
          and a.payload = i.effective_payload)
   order by i.seq, i.object_kind, i.object_key
$function$

;

CREATE OR REPLACE FUNCTION erp.pack_conflicts(p_pack_code text)
 RETURNS TABLE(severity text, conflict text, reference text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if not exists (select 1 from erp_ref.content_pack where code = p_pack_code) then
    raise exception 'ERPWARE_UNKNOWN_PACK: %', p_pack_code using errcode = '23503';
  end if;

  return query
  -- §11.3, first named conflict: "account ranges colliding with a legislation
  -- pack". §8.1 says that where a bound legislation pack defines a statutory
  -- structure, it wins — so a pack account whose code already exists with a
  -- different name is the collision, and the existing row is the winner.
  select 'blocking',
         format('account %s already exists as %L and the pack would call it %L',
                pi.payload ->> 'code', a.name, pi.payload ->> 'name'),
         p_pack_code || ' / ' || pi.object_key
    from erp_ref.pack_item pi
    join erp.account a
      on a.tenant_id = v_tenant and a.code = (pi.payload ->> 'code')
     and a.status = 'active'
   where pi.pack_code = p_pack_code and pi.object_kind = 'account'
     and a.name is distinct from (pi.payload ->> 'name')

  union all

  -- Second: duplicate codes. Two items in one pack claiming the same object
  -- differ only in which lands last, which is not a decision anybody made.
  --
  -- Stated as identical payloads under different keys, not as a shared code.
  -- The first version grouped by object_kind and payload->>'code', and the
  -- base pack refused to apply because of it: reason codes are unique per
  -- CATEGORY, so ORDERED_IN_ERROR exists under both return-to-supplier and
  -- customer return, and WRONG_QUANTITY, CUSTOMER_REQUEST and
  -- SYSTEM_CORRECTION likewise. Four false positives out of four findings. The
  -- object_key already carries the full identity — category|code here,
  -- kind|code for a posting class — and the primary key makes it unique, so
  -- the only duplicate left to find is the same row written twice under two
  -- names.
  select 'blocking',
         format('%s items in this pack write an identical %s payload under '
                'different keys, so all but one are dead',
                count(*), pi.object_kind),
         p_pack_code || ' / ' || string_agg(pi.object_key, ', ' order by pi.object_key)
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
   group by pi.object_kind, pi.payload
  having count(*) > 1

  union all

  -- And the authoring error that would silently break §11.7: an object_key
  -- that does not agree with the code in its own payload. The key is what
  -- erp.plan_content_pack() matches against the manifest, so a key naming one
  -- thing and a payload writing another makes the item permanently missing —
  -- it lands, and the next application plans it again for ever.
  select 'blocking',
         format('%s %s writes code %L, which its own key does not name',
                pi.object_kind, pi.object_key, pi.payload ->> 'code'),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.payload ? 'code'
     and position(upper(pi.payload ->> 'code') in upper(pi.object_key)) = 0

  union all

  -- Third: unmet capability dependencies. An item gated on a capability that
  -- is off is skipped rather than blocked — that is §2 working as intended —
  -- but a PACK gated on a capability that is off has nothing to say at all.
  select 'blocking',
         format('this pack needs the %s capability, which is off for this organisation',
                cp.requires_capability),
         p_pack_code
    from erp_ref.content_pack cp
   where cp.code = p_pack_code
     and cp.requires_capability is not null
     and not erp.capability_enabled(cp.requires_capability)

  union all

  -- And advisory: items this organisation will not receive because their own
  -- capability is off. Not a conflict — a consequence — but somebody reading
  -- a diff of forty items when the pack has ninety deserves to know why.
  select 'advisory',
         format('%s item(s) are held back because the %s capability is off',
                count(*), pi.requires_capability),
         p_pack_code
    from erp_ref.pack_item pi
   where pi.pack_code = p_pack_code
     and pi.requires_capability is not null
     and not erp.capability_enabled(pi.requires_capability)
   group by pi.requires_capability

  union all

  -- And the reports this organisation will not receive yet because the view
  -- each reads comes with a module it has not installed. Named per view, with
  -- the module that brings it, so the reader knows what to install rather
  -- than what to wait for. Reports already held back by a capability are not
  -- counted twice.
  select 'advisory',
         format('report(s) %s are held back because the %s view they read '
                'comes with the %s module, which is not installed',
                string_agg(pi.object_key, ', ' order by pi.object_key),
                mgv.code, mgv.install_code),
         p_pack_code
    from erp_ref.pack_item pi
    join erp_ref.module_governed_view mgv
      on mgv.code = pi.payload -> 'version' ->> 'view'
   where pi.pack_code = p_pack_code
     and pi.object_kind = 'report'
     and (pi.requires_capability is null
          or erp.capability_enabled(pi.requires_capability))
     and not exists (
       select 1 from erp.governed_view gv
        where gv.tenant_id = v_tenant and gv.code = mgv.code)
   group by mgv.code, mgv.install_code

  union all

  -- And the reports held back because a KPI they name is not coming. Named per
  -- KPI with the capability that would bring it, for the same reason as the
  -- view advisory above: so the reader knows what to switch on.
  select 'advisory',
         format('report(s) %s are held back because the %s KPI they name '
                'comes with the %s capability, which is off',
                string_agg(distinct pi.object_key, ', '),
                ki.object_key, ki.requires_capability),
         p_pack_code
    from erp_ref.pack_item pi
    cross join lateral unnest(string_to_array(pi.payload ->> 'kpi_codes', ',')) kc
    join erp_ref.pack_item ki
      on ki.pack_code = pi.pack_code and ki.object_kind = 'kpi'
     and ki.object_key = trim(kc)
   where pi.pack_code = p_pack_code
     and pi.object_kind = 'report'
     and (pi.requires_capability is null or erp.capability_enabled(pi.requires_capability))
     and ki.requires_capability is not null
     and not erp.capability_enabled(ki.requires_capability)
     and not exists (select 1 from erp.kpi k
                      where k.tenant_id = v_tenant and k.code = ki.object_key)
   group by ki.object_key, ki.requires_capability;
end;
$function$

;
