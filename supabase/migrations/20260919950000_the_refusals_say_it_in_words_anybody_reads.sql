-- ─────────────────────────────────────────────────────────────────────────────
-- The refusals about the audit trail's source say it in words anybody reads.
--
-- 20260919930000 registered three refusals for erp.declare_source(), and three
-- of their nine fields named identifiers: two said erp_ref.audit_source and one
-- said erp.authorise(). erp_test.plain_words_suite() reads every row in
-- erp_ref.refusal through erp_test.sounds_internal(), which refuses a schema
-- -qualified name, a snake_case token, a specification section, a refusal code
-- — anything that tells the reader to go and look at the build rather than at
-- their own screen. It was right to refuse them.
--
-- Worth naming the shape, because it is the same one twice over in this branch.
-- The build proves the schema at two depths: the migration's own transaction,
-- and the catalogue afterwards. A migration can assert everything it knows to
-- assert and still be refused later by a check that reads the whole database —
-- here, by a suite that judges wording rather than structure, which no amount
-- of getting the structure right would have satisfied. The refusals were
-- written the way this file's comments are written, and comments are for
-- whoever maintains the product; a refusal is for whoever met it.
--
-- So the two are re-registered. erp.register_refusal() writes the register row
-- and mirrors the three keys into the resource layer in one call, so the
-- screens and the register cannot drift apart, and it upserts — nothing here
-- adds a row or a key. The third, on declaring the honest default, was already
-- plain and is left alone.
--
-- The hints on the raises themselves keep their identifiers. A hint is read in
-- a build log by somebody holding the source, and erp_test.sounds_internal()
-- does not read prosrc; the register and the dictionary the screens read are
-- what a person meets, and those are what this changes.
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal(
  'CLOVEERP_UNKNOWN_AUDIT_SOURCE',
  'Declaring the audit trail''s source to be a way into this product that does not exist.',
  'The source on the audit trail says which way into the product caused a change — a person on a screen, the queue worker that runs work nobody is waiting for, one of the small functions that send and receive email. It is a closed list, and the database refuses a word outside it, because a column filled from free text is a column where one mistyped word becomes an origin nobody can account for and nobody notices. That is how this column spent its first fortnight saying nothing at all: it was filled from a setting no part of the product ever set.',
  'Use one of the ways in the product already knows. If this really is a new way into the database, it has to be added to the list of known ones first, in a change to the product, alongside whatever declares it.');

select erp.register_refusal(
  'CLOVEERP_AUDIT_SOURCE_NOT_YOURS',
  'A session reached through the application declaring itself to be the worker, a background function, or another trusted way in.',
  'A request that arrives over the application''s own connection is the application, whatever it says about itself. If such a request could name itself the queue worker, the audit trail would record a person''s change as a machine''s — and the one record this product asks an auditor to trust would be the one record anybody could forge. The trusted ways in connect differently, and the database can tell.',
  'Nothing to do from the application: a request that arrives with somebody signed in is recorded as a person on a screen already, before anything it changes is written. If this is a background job, connect the way the queue worker connects and say so there.');

-- ── Proved, in the same transaction ──────────────────────────────────────────

select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();
select erp.assert_no_legacy_refusal_prefix();

-- The suite that refused them, run here rather than left to the catalogue: a
-- wording this migration did not fix is a wording this migration should not
-- land with.
select erp_test.assert_plain_words_suite();
