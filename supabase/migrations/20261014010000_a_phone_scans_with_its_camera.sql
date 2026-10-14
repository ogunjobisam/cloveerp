-- A phone scans with its camera.
--
-- Theme 4, phones and scanners (owner, 14 October 2026). The scanner screen
-- (/device, specification v1.2 Part 14) read barcodes only from a hardware
-- scanner that types into its field, so a phone without one could only type
-- an identifier, with a reason, recorded as keyed. It now reads with the
-- phone's camera: the browser's own BarcodeDetector where it has one, and
-- ZXing in WebAssembly, served from this site, where it has not (an iPhone).
-- A camera's read goes through exactly the checks a hardware scan does and is
-- recorded as scanned, which erp.device_action already allows; nothing in the
-- database changes but the words the screen says.

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). Scanning with a phone''s camera on the scanner screen (20261014010000).'
  from (values
    ('Hold the barcode inside the frame.'),
    ('No camera could be opened. Scan with the scanner, or type the identifier with a reason.'),
    ('Not taken'),
    ('Scan with the camera'),
    ('Stop the camera'),
    ('The camera is not allowed. Allow it for this site in the phone''s settings, or scan with the scanner.'),
    ('This phone cannot read barcodes with its camera. Scan with the scanner.')) v(text)
on conflict do nothing;

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
select erp.assert_no_public_execute();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
