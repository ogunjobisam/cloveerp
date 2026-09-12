-- The register pin, moved by the row I added to it.
--
-- 20260912222000 registered the document module's capability, because the
-- coverage report refuses a module with nothing claiming to deliver it. That
-- was right and it went green. erp_test.part5_register_suite() then failed,
-- because it pins the register's shape:
--
--   the register reads 96 built, 0 partial, 1 absent, and the summary agrees
--     — 97 built, 0 partial, 1 absent
--
-- The pin is the point of that case: the register is a claim about what the
-- product delivers, and a row appearing or vanishing unnoticed is exactly what
-- it is there to catch. It caught me. So the pin moves by one, deliberately,
-- rather than the case being loosened to stop counting.
--
-- The lesson, written down because I have now made this mistake twice in a
-- day: a fix that adds a row to a register, or changes a column a generator
-- reads, is not finished when its own assertion passes. Something else counts
-- that thing. Grep for the count before writing the row.

do $pin$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.part5_register_suite()'::regprocedure);

  v_new := replace(v_def,
$old$  return query select 'the register reads 96 built, 0 partial, 1 absent, and the summary agrees',
    v_built = 96 and v_partial = 0 and v_absent = 1
    and (select sum(s.built) from erp.part5_summary() s) = 96
    and (select sum(s.total) from erp.part5_summary() s) = 97,$old$,
$new$  -- 97 since 20260912222000 registered the document module's capability.
  return query select 'the register reads 97 built, 0 partial, 1 absent, and the summary agrees',
    v_built = 97 and v_partial = 0 and v_absent = 1
    and (select sum(s.built) from erp.part5_summary() s) = 97
    and (select sum(s.total) from erp.part5_summary() s) = 98,$new$);

  if v_new = v_def then
    raise exception 'CLOVEERP_PART5_PIN_UNRECOGNISED: erp_test.part5_register_suite() does not pin 96 built and 97 total, so this migration is patching a body that has already moved on';
  end if;

  execute v_new;
end
$pin$;

select erp_test.assert_part5_register_suite();
