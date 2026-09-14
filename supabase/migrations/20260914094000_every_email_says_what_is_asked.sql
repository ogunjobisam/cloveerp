-- Every email says what is asked.
--
-- The owner was sent an approval email on 14 September and found it very
-- basic. It was: the subject "Approval requested", the sentence "A document is
-- waiting for your approval.", a blank line and https://cloveerp.com/governance.
-- Not which document, not for how much, not who asked or by when, and no button.
-- Every notification the product emails is built the same way, because
-- erp.notification holds a subject and a plain body and nothing else, and the
-- dispatch drain sends exactly those. The owner asked for every email to be
-- professional, detailed about the ask, and able to act.
--
-- This is the first of three steps. It gives every notification the product
-- emails today a shared, button-led layout that states the ask and the facts
-- it rests on. The second adds Approve and Reject buttons that act from the
-- email through single-use tokens; approval contexts already carry the task,
-- the request and the object those buttons will need.
--
-- What this file does, in order:
--
--   1. erp.notification gains context: what kind of ask an email is, the facts
--      it rests on, the words in the reader's language and the paths of the
--      screens where they act, frozen when the notification is written. body
--      stays what it was, word for word, and remains the plain fallback: a
--      notification without a context, or one the sender cannot render, goes
--      out as its subject and body exactly as before.
--
--   2. The words: every heading, sentence, label and button an email says, in
--      English and German, as resources an organisation can rename like any
--      other. Subjects are the exception: they are read from the product's own
--      strings, never an organisation's override, so the line a reader sees
--      beside mail from their bank carries product words and system identifiers
--      only (src/lib/invitation-email.ts says why).
--
--   3. erp.notification_email_context(event, person, mandatory), called by
--      erp.route_notifications() for every email it writes, from the product's
--      routes and from an organisation's own, for the kinds it knows:
--        approval.task_assigned / approval.task_escalated — the document's type,
--          number, business partner, value and currency, the step, when it was
--          requested and when the decision is due; links to the task on
--          /governance and to the document;
--        change_set.submitted — the change, its entries and when it was
--          submitted; a link to the change on Configuration;
--        job.failed — the job, what it runs, how many failures in a row, and
--          the error; mandatory for administrators;
--        support.access_granted — the role, the reason, the kind of access and
--          when it ends; mandatory.
--      People are frozen as ids, never as names: erp.claim_email_batch() reads
--      their names when the email leaves, so an erasure between the two is not
--      undone by a queue. A route that digests gets no context per message;
--      erp.dispatch_notifications() gives the digest one of its own
--      (erp.notification_digest_context), listing what it collects. An
--      incident notice gets one from erp.communicate_incidents(): severity,
--      services affected, when it was declared, the update as posted and when
--      the next is due.
--
--   4. erp.claim_email_batch() is dropped and re-created from its latest body
--      (20260906112000 as patched by 20260914072000) to return the context, the
--      organisation's name and the reader's name besides what it returned.
--      The kill switch and the demonstration refusal are the same statements,
--      in the same place, proven below before the old function goes.
--
--   5. erp_test.notification_email_context_suite(), run here. It builds an
--      organisation that trades, requests approval of a document worth
--      £4,200.00 from a named approver and routes it, then claims it. It
--      creates its own organisation inside a block it rolls back, so nothing it
--      queues is ever committed: no minute pass or drain can see a row it
--      writes, and it claims only its own organisation's rows.
--
-- What renders the email is src/lib/email/notification-email.ts, on the shared
-- layout src/lib/email/layout.ts that the invitation and enquiry emails now use
-- too. The dispatch worker renders when the claim returns a context and sends
-- the body when it does not or when rendering fails, and logs the failure.
--
-- Not changed: the in-app notification keeps its subject and body; nothing
-- here sends mail; click tracking is a Resend domain setting, not a per-message
-- one, so it is not switched here.
--
-- Proof: erp_test.notification_email_context_suite() (10), and the product
-- routes, email delivery and demonstration suites run again below because they
-- drive what changed.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. A notification carries what its email says
-- ═════════════════════════════════════════════════════════════════════════════

alter table erp.notification add column if not exists context jsonb;

alter table erp.notification drop constraint if exists notification_context_names_its_kind;
alter table erp.notification add constraint notification_context_names_its_kind
  check (context is null or (jsonb_typeof(context) = 'object' and jsonb_typeof(context -> 'kind') = 'string'));

comment on column erp.notification.context is
  'What the email for this notification says (20260914094000): its kind, the facts '
  'it rests on, the words in the reader''s language and the paths of the screens '
  'where they act, frozen when it was written. People appear as ids and are named '
  'when the email is claimed. Null for a notification the email layout does not '
  'describe; body is the plain fallback either way.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The words
-- ═════════════════════════════════════════════════════════════════════════════
--
-- {placeholders} are filled by the sender: {organisation} and {name} always;
-- the others by kind, from the context's fields, formatted for the reader.

insert into erp_ref.resource (key, locale, value, module_code, description)
select w.key, l.locale, case l.locale when 'en' then w.en else w.de end, 'administration', w.description
  from (values
    -- Every email
    ('email.common.greeting', 'Hello {name},', 'Hallo {name},',
     'Email: the greeting. {name} is the reader''s name.'),
    ('email.common.fallback',
     'If a button does not work, copy the address into your browser.',
     'Falls eine Schaltfläche nicht funktioniert, kopieren Sie die Adresse in Ihren Browser.',
     'Email: above the plain addresses repeated under the buttons.'),
    ('email.common.preferences', 'Choose which emails you receive',
     'Legen Sie fest, welche E-Mails Sie erhalten',
     'Email: the link to the notification preferences.'),
    ('email.common.mandatory',
     'Administrators receive this notice whatever their email settings, so it cannot be switched off.',
     'Administratoren erhalten diese Mitteilung unabhängig von ihren E-Mail-Einstellungen, daher lässt sie sich nicht abbestellen.',
     'Email: said instead of the preferences link when the notice is mandatory.'),
    ('email.common.footer', 'Sent by Clove ERP for {organisation}.',
     'Von Clove ERP für {organisation} gesendet.',
     'Email: the last line.'),

    -- An approval task
    ('email.approval.subject', 'Approval needed: {number} · {value}',
     'Genehmigung erforderlich: {number} · {value}',
     'Email subject: a document waits for the reader''s approval. Product words and identifiers only.'),
    ('email.approval.subject_plain', 'Approval needed', 'Genehmigung erforderlich',
     'Email subject: a request that is not a document waits for the reader''s approval.'),
    ('email.approval.subject_escalated', 'Approval escalated to you: {number} · {value}',
     'Genehmigung an Sie eskaliert: {number} · {value}',
     'Email subject: an overdue document approval came to the reader.'),
    ('email.approval.subject_escalated_plain', 'Approval escalated to you',
     'Genehmigung an Sie eskaliert',
     'Email subject: an overdue approval that is not a document came to the reader.'),
    ('email.approval.preheader', 'A request in {organisation} is waiting for your decision.',
     'Eine Anfrage in {organisation} wartet auf Ihre Entscheidung.',
     'Email: the preview line of an approval that is not a document.'),
    ('email.approval.preheader_document', '{document_type} {number} for {value} is waiting for your decision.',
     '{document_type} {number} über {value} wartet auf Ihre Entscheidung.',
     'Email: the preview line of a document approval.'),
    ('email.approval.heading', 'Your approval is needed', 'Ihre Genehmigung ist erforderlich',
     'Email: the heading of an approval task.'),
    ('email.approval.heading_escalated', 'An approval has been escalated to you',
     'Eine Genehmigung wurde an Sie eskaliert',
     'Email: the heading of an escalated approval task.'),
    ('email.approval.intro',
     'A request in {organisation} has reached the approval step “{step}”, which names you as its approver. Review the details below, then approve or reject it in Clove ERP.',
     'Eine Anfrage in {organisation} hat den Genehmigungsschritt „{step}“ erreicht, der Sie als Genehmiger nennt. Prüfen Sie die Angaben unten und genehmigen oder lehnen Sie die Anfrage in Clove ERP ab.',
     'Email: what an approval task asks, for a request that is not a document.'),
    ('email.approval.intro_document',
     '{document_type} {number} has reached the approval step “{step}”, which names you as its approver. Review the details below, then approve or reject it in Clove ERP.',
     '{document_type} {number} hat den Genehmigungsschritt „{step}“ erreicht, der Sie als Genehmiger nennt. Prüfen Sie die Angaben unten und genehmigen oder lehnen Sie den Beleg in Clove ERP ab.',
     'Email: what an approval task asks, for a document.'),
    ('email.approval.intro_escalated',
     'A request in {organisation} was not decided in time at the approval step “{step}”, so it has come to you. Review the details below, then approve or reject it in Clove ERP.',
     'Eine Anfrage in {organisation} wurde im Genehmigungsschritt „{step}“ nicht rechtzeitig entschieden und liegt nun bei Ihnen. Prüfen Sie die Angaben unten und genehmigen oder lehnen Sie die Anfrage in Clove ERP ab.',
     'Email: what an escalated approval task asks, for a request that is not a document.'),
    ('email.approval.intro_escalated_document',
     '{document_type} {number} was not decided in time at the approval step “{step}”, so it has come to you. Review the details below, then approve or reject it in Clove ERP.',
     '{document_type} {number} wurde im Genehmigungsschritt „{step}“ nicht rechtzeitig entschieden und liegt nun bei Ihnen. Prüfen Sie die Angaben unten und genehmigen oder lehnen Sie den Beleg in Clove ERP ab.',
     'Email: what an escalated approval task asks, for a document.'),
    ('email.approval.primary', 'Review and approve', 'Prüfen und genehmigen',
     'Email: the button that opens the approval task.'),
    ('email.approval.secondary', 'Open the document', 'Beleg öffnen',
     'Email: the button that opens the document being approved.'),
    ('email.approval.note',
     'Nothing is approved until you decide in Clove ERP, where everything the request rests on is in front of you.',
     'Genehmigt ist erst, wenn Sie in Clove ERP entscheiden. Dort sehen Sie alles, worauf die Anfrage beruht.',
     'Email: under the buttons of an approval task.'),
    ('email.approval.reason',
     'You are receiving this because an approval step in {organisation} names you as its approver.',
     'Sie erhalten diese E-Mail, weil ein Genehmigungsschritt in {organisation} Sie als Genehmiger nennt.',
     'Email: why the reader received an approval task.'),
    ('email.approval.reason_escalated',
     'You are receiving this because an overdue approval in {organisation} was escalated to you.',
     'Sie erhalten diese E-Mail, weil eine überfällige Genehmigung in {organisation} an Sie eskaliert wurde.',
     'Email: why the reader received an escalated approval task.'),
    ('email.approval.label.document_type', 'Document', 'Beleg', 'Email detail label.'),
    ('email.approval.label.number', 'Number', 'Nummer', 'Email detail label.'),
    ('email.approval.label.partner', 'Business partner', 'Geschäftspartner', 'Email detail label.'),
    ('email.approval.label.value', 'Value', 'Wert', 'Email detail label.'),
    ('email.approval.label.step', 'Approval step', 'Genehmigungsschritt', 'Email detail label.'),
    ('email.approval.label.requested_by', 'Requested by', 'Angefordert von', 'Email detail label.'),
    ('email.approval.label.requested_at', 'Requested', 'Angefordert am', 'Email detail label.'),
    ('email.approval.label.due_at', 'Decision due by', 'Entscheidung fällig bis', 'Email detail label.'),
    ('email.approval.label.delegated_from', 'Delegated to you by', 'An Sie delegiert von', 'Email detail label.'),
    ('email.approval.label.escalated_from', 'Escalated from', 'Eskaliert von', 'Email detail label.'),

    -- A configuration change waiting for a second approver
    ('email.change_set.subject', 'Approval needed: configuration change',
     'Genehmigung erforderlich: Konfigurationsänderung',
     'Email subject: a configuration change waits for the reader''s approval.'),
    ('email.change_set.preheader',
     'A configuration change in {organisation} is waiting for a second approver.',
     'Eine Konfigurationsänderung in {organisation} wartet auf eine zweite Genehmigung.',
     'Email: the preview line of a configuration change to approve.'),
    ('email.change_set.heading', 'A configuration change needs your approval',
     'Eine Konfigurationsänderung braucht Ihre Genehmigung',
     'Email: the heading of a configuration change to approve.'),
    ('email.change_set.intro',
     'A configuration change has been submitted in {organisation}. The organisation is live, so somebody other than the person who made the change must approve it before it is put in force. Review what it changes, then decide whether to approve it.',
     'In {organisation} wurde eine Konfigurationsänderung eingereicht. Die Organisation ist live, daher muss jemand anderes als die Person, die sie erstellt hat, sie genehmigen, bevor sie in Kraft tritt. Prüfen Sie, was sie ändert, und entscheiden Sie dann über die Genehmigung.',
     'Email: what a configuration change to approve asks.'),
    ('email.change_set.primary', 'Review the change', 'Änderung prüfen',
     'Email: the button that opens the change on Configuration.'),
    ('email.change_set.reason',
     'You are receiving this because you can approve configuration changes in {organisation}.',
     'Sie erhalten diese E-Mail, weil Sie Konfigurationsänderungen in {organisation} genehmigen können.',
     'Email: why the reader received a configuration change to approve.'),
    ('email.change_set.label.name', 'Change', 'Änderung', 'Email detail label.'),
    ('email.change_set.label.code', 'Reference', 'Referenz', 'Email detail label.'),
    ('email.change_set.label.item_count', 'Entries in the change', 'Einträge in der Änderung', 'Email detail label.'),
    ('email.change_set.label.submitted_by', 'Submitted by', 'Eingereicht von', 'Email detail label.'),
    ('email.change_set.label.submitted_at', 'Submitted', 'Eingereicht am', 'Email detail label.'),

    -- A scheduled job that failed
    ('email.job_failed.subject', 'Scheduled job failed: {job}', 'Geplanter Job fehlgeschlagen: {job}',
     'Email subject: a scheduled job used up its retries. {job} is the job''s code.'),
    ('email.job_failed.preheader', '{job} has failed {count} times in a row in {organisation}.',
     '{job} ist in {organisation} {count}-mal hintereinander fehlgeschlagen.',
     'Email: the preview line of a job that failed more than once.'),
    ('email.job_failed.preheader_once', '{job} has failed in {organisation}.',
     '{job} ist in {organisation} fehlgeschlagen.',
     'Email: the preview line of a job that failed once.'),
    ('email.job_failed.heading', 'A scheduled job has failed', 'Ein geplanter Job ist fehlgeschlagen',
     'Email: the heading of a failed job.'),
    ('email.job_failed.intro',
     'The job {job} failed {count} times in a row, so its retries are used up. Until the cause is put right, the work it does may not be happening. The last error it reported is below.',
     'Der Job {job} ist {count}-mal hintereinander fehlgeschlagen, seine Wiederholungen sind aufgebraucht. Bis die Ursache behoben ist, findet die Arbeit, die er erledigt, möglicherweise nicht statt. Der zuletzt gemeldete Fehler steht unten.',
     'Email: what a failed job means, after more than one failure.'),
    ('email.job_failed.intro_once',
     'The job {job} failed and its retries are used up. Until the cause is put right, the work it does may not be happening. The error it reported is below.',
     'Der Job {job} ist fehlgeschlagen, seine Wiederholungen sind aufgebraucht. Bis die Ursache behoben ist, findet die Arbeit, die er erledigt, möglicherweise nicht statt. Der gemeldete Fehler steht unten.',
     'Email: what a failed job means, after one failure.'),
    ('email.job_failed.primary', 'Open the job', 'Job öffnen',
     'Email: the button that opens the recurring tasks screen.'),
    ('email.job_failed.reason',
     'You are receiving this because you are an administrator of {organisation}.',
     'Sie erhalten diese E-Mail, weil Sie Administrator von {organisation} sind.',
     'Email: why the reader received a failed job.'),
    ('email.job_failed.label.job', 'Job', 'Job', 'Email detail label.'),
    ('email.job_failed.label.handler', 'What it runs', 'Was er ausführt', 'Email detail label.'),
    ('email.job_failed.label.failures', 'Failures in a row', 'Fehlschläge in Folge', 'Email detail label.'),
    ('email.job_failed.label.failed_at', 'Failed', 'Fehlgeschlagen am', 'Email detail label.'),
    ('email.job_failed.label.error', 'Error', 'Fehler', 'Email detail label.'),

    -- Support given access to the organisation
    ('email.support_access.subject', 'Support access granted to your organisation',
     'Support-Zugang zu Ihrer Organisation gewährt',
     'Email subject: Clove ERP support was given access to the organisation.'),
    ('email.support_access.preheader', 'Clove ERP support can act in {organisation} until {expires}.',
     'Der Clove-ERP-Support kann bis {expires} in {organisation} handeln.',
     'Email: the preview line of support access.'),
    ('email.support_access.heading', 'Clove ERP support has been given access',
     'Der Clove-ERP-Support hat Zugang erhalten',
     'Email: the heading of support access.'),
    ('email.support_access.intro',
     'A member of Clove ERP support has been given access to {organisation} until {expires}, for the reason below. Everything they do is recorded in the audit log. If you were not expecting this, review the session now.',
     'Ein Mitglied des Clove-ERP-Supports hat bis {expires} Zugang zu {organisation} erhalten, aus dem unten genannten Grund. Alles, was es tut, wird im Prüfprotokoll festgehalten. Wenn Sie das nicht erwartet haben, prüfen Sie die Sitzung jetzt.',
     'Email: what support access means.'),
    ('email.support_access.access_write', 'Can make changes, as an administrator',
     'Kann Änderungen vornehmen, als Administrator',
     'Email: the access a support session has, when it can write.'),
    ('email.support_access.access_read', 'Can look, but not change anything',
     'Kann einsehen, aber nichts ändern',
     'Email: the access a support session has, when it can only read.'),
    ('email.support_access.primary', 'Review the support session', 'Support-Sitzung prüfen',
     'Email: the button that opens the continuity screen.'),
    ('email.support_access.reason',
     'You are receiving this because you are an administrator of {organisation}.',
     'Sie erhalten diese E-Mail, weil Sie Administrator von {organisation} sind.',
     'Email: why the reader received support access.'),
    ('email.support_access.label.staff', 'Support staff member', 'Support-Mitarbeiter', 'Email detail label.'),
    ('email.support_access.label.role', 'Their role', 'Rolle', 'Email detail label.'),
    ('email.support_access.label.reason', 'Reason given', 'Angegebener Grund', 'Email detail label.'),
    ('email.support_access.label.access', 'Access', 'Zugang', 'Email detail label.'),
    ('email.support_access.label.granted_at', 'Granted', 'Gewährt am', 'Email detail label.'),
    ('email.support_access.label.expires_at', 'Access ends', 'Zugang endet', 'Email detail label.'),

    -- A service incident
    ('email.incident.subject', 'Service incident {code} · {severity}',
     'Störung {code} · {severity}',
     'Email subject: a service incident was declared.'),
    ('email.incident.subject_update', 'Service incident update {code} · {severity}',
     'Neuigkeiten zur Störung {code} · {severity}',
     'Email subject: an update on a service incident.'),
    ('email.incident.preheader', 'An incident that may affect {organisation} has been declared.',
     'Eine Störung, die {organisation} betreffen kann, wurde gemeldet.',
     'Email: the preview line of a declared incident.'),
    ('email.incident.preheader_update', 'The latest on an incident that may affect {organisation}.',
     'Der neueste Stand zu einer Störung, die {organisation} betreffen kann.',
     'Email: the preview line of an incident update.'),
    ('email.incident.heading', 'A service incident has been declared', 'Eine Störung wurde gemeldet',
     'Email: the heading of a declared incident.'),
    ('email.incident.heading_update', 'An update on a service incident', 'Neuigkeiten zu einer Störung',
     'Email: the heading of an incident update.'),
    ('email.incident.intro',
     'We have declared an incident that may affect {organisation}. What we know so far is below, and we will keep you informed until it is resolved.',
     'Wir haben eine Störung gemeldet, die {organisation} betreffen kann. Was wir bisher wissen, steht unten, und wir halten Sie auf dem Laufenden, bis sie behoben ist.',
     'Email: what a declared incident means.'),
    ('email.incident.intro_update',
     'Here is the latest on an incident that may affect {organisation}. We will keep you informed until it is resolved.',
     'Hier ist der neueste Stand zu einer Störung, die {organisation} betreffen kann. Wir halten Sie auf dem Laufenden, bis sie behoben ist.',
     'Email: what an incident update is.'),
    ('email.incident.primary', 'View the incident', 'Störung ansehen',
     'Email: the button that opens the continuity screen.'),
    ('email.incident.reason',
     'You are receiving this because you are told about service incidents that may affect {organisation}.',
     'Sie erhalten diese E-Mail, weil Sie über Störungen informiert werden, die {organisation} betreffen können.',
     'Email: why the reader received an incident notice.'),
    ('email.incident.mandatory',
     'Service notices are sent whatever your email settings, so they cannot be switched off.',
     'Störungsmeldungen werden unabhängig von Ihren E-Mail-Einstellungen gesendet und lassen sich nicht abbestellen.',
     'Email: why an incident notice cannot be switched off.'),
    ('email.incident.label.incident', 'Incident', 'Störung', 'Email detail label.'),
    ('email.incident.label.code', 'Reference', 'Referenz', 'Email detail label.'),
    ('email.incident.label.severity', 'Severity', 'Schweregrad', 'Email detail label.'),
    ('email.incident.label.components', 'Affected services', 'Betroffene Dienste', 'Email detail label.'),
    ('email.incident.label.declared_at', 'Declared', 'Gemeldet am', 'Email detail label.'),
    ('email.incident.label.next_update_at', 'Next update by', 'Nächste Meldung bis', 'Email detail label.'),

    -- A digest
    ('email.digest.subject', '{count} updates', '{count} Neuigkeiten',
     'Email subject: a digest of more than one notification.'),
    ('email.digest.subject_one', '1 update', '1 Neuigkeit',
     'Email subject: a digest of one notification.'),
    ('email.digest.preheader', '{count} notifications from {organisation}, collected into one email.',
     '{count} Benachrichtigungen aus {organisation}, in einer E-Mail gesammelt.',
     'Email: the preview line of a digest.'),
    ('email.digest.preheader_one', '1 notification from {organisation}.',
     '1 Benachrichtigung aus {organisation}.',
     'Email: the preview line of a digest of one.'),
    ('email.digest.heading', '{count} updates', '{count} Neuigkeiten', 'Email: the heading of a digest.'),
    ('email.digest.heading_one', '1 update', '1 Neuigkeit', 'Email: the heading of a digest of one.'),
    ('email.digest.intro',
     'These notifications were collected for you in {organisation} since your last summary.',
     'Diese Benachrichtigungen wurden seit Ihrer letzten Zusammenfassung in {organisation} für Sie gesammelt.',
     'Email: what a digest is.'),
    ('email.digest.primary', 'Open notifications', 'Benachrichtigungen öffnen',
     'Email: the button that opens the notifications screen.'),
    ('email.digest.reason',
     'You are receiving this summary because a notification rule in {organisation} collects these updates for you.',
     'Sie erhalten diese Zusammenfassung, weil eine Benachrichtigungsregel in {organisation} diese Neuigkeiten für Sie sammelt.',
     'Email: why the reader received a digest.'),
    ('email.digest.more', 'And {more} more in Clove ERP.', 'Und {more} weitere in Clove ERP.',
     'Email: under a digest that lists fewer than it collected.')
  ) as w(key, en, de, description)
  cross join (values ('en'), ('de')) as l(locale)
on conflict (key, locale) do update set
  value = excluded.value, module_code = excluded.module_code, description = excluded.description;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. How a context is made
-- ═════════════════════════════════════════════════════════════════════════════

-- The words of one part of an email, as the reader will read them.
create or replace function erp.email_words(p_part text, p_locale text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  -- The keys directly under email.<part>., each by its last segment, through
  -- erp.text() so an organisation's renaming holds.
  select coalesce(jsonb_object_agg(substr(r.key, length(v.prefix) + 1), erp.text(r.key, p_locale)), '{}'::jsonb)
    from (select 'email.' || p_part || '.' as prefix) v
    join erp_ref.resource r
      on r.locale = 'en'
     and left(r.key, length(v.prefix)) = v.prefix
     and strpos(substr(r.key, length(v.prefix) + 1), '.') = 0
$$;

revoke all on function erp.email_words(text, text) from public, anon, authenticated;

comment on function erp.email_words(text, text) is
  'The words of one part of an email (email.<part>.*), keyed by their last segment, '
  'resolved for the locale through erp.text() so an organisation''s renaming holds.';

-- A product string, never an organisation's override: what a subject is made of.
create or replace function erp.email_product_text(p_key text, p_locale text)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (select r.value
       from unnest(erp.locale_chain(coalesce(nullif(btrim(p_locale), ''), 'en'))) with ordinality as c(code, depth)
       join erp_ref.resource r on r.key = p_key and r.locale = c.code
      order by c.depth
      limit 1),
    p_key)
$$;

revoke all on function erp.email_product_text(text, text) from public, anon, authenticated;

comment on function erp.email_product_text(text, text) is
  'A product string for the locale''s fallback chain, ignoring organisation overrides. '
  'Email subjects are read through this, so a subject carries product words only.';

-- An instant as the sender reads it: UTC, to the second, with its zone.
create or replace function erp.email_instant(p_at timestamptz)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

revoke all on function erp.email_instant(timestamptz) from public, anon, authenticated;

comment on function erp.email_instant(timestamptz) is
  'An instant written for an email context: ISO 8601 in UTC, to the second.';

-- The reader's language and time zone, or the organisation's.
create or replace function erp.email_reader(p_tenant_id uuid, p_app_user_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
           'locale', coalesce(nullif(btrim(x.user_locale), ''), nullif(btrim(x.default_locale), ''), 'en'),
           'time_zone', coalesce(nullif(btrim(x.timezone), ''), nullif(btrim(x.default_timezone), ''), 'UTC'))
    from (select 1) one
    left join lateral (
      select u.user_locale, u.timezone, t.default_locale, t.default_timezone
        from erp.tenant t
        left join erp.app_user u on u.tenant_id = t.id and u.id = p_app_user_id
       where t.id = p_tenant_id) x on true
$$;

revoke all on function erp.email_reader(uuid, uuid) from public, anon, authenticated;

comment on function erp.email_reader(uuid, uuid) is
  'The language and time zone an email is written in: the person''s, then their '
  'organisation''s, then English and UTC.';

create or replace function erp.notification_email_context(
  p_event erp.event, p_app_user_id uuid, p_mandatory boolean default false)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := p_event.tenant_id;
  v_reader jsonb;
  v_locale text;
  v_common jsonb;
  v_links  jsonb := jsonb_build_object('preferences', '/notifications');
  w        jsonb;
  v_esc    boolean;
  v_doc    boolean;
  v_once   boolean;
  -- One record per kind, so no expression is ever planned against another
  -- kind's row shape.
  r        record;
  cs_row   record;
  sa_row   record;
begin
  if p_event.id is null or p_app_user_id is null
     or p_event.event_type not in ('approval.task_assigned', 'approval.task_escalated',
                                   'change_set.submitted', 'job.failed', 'support.access_granted') then
    return null;
  end if;

  v_reader := erp.email_reader(v_tenant, p_app_user_id);
  v_locale := v_reader ->> 'locale';
  v_common := erp.email_words('common', v_locale);

  -- ── An approval task ────────────────────────────────────────────────────────
  if p_event.event_type in ('approval.task_assigned', 'approval.task_escalated') then
    select t.id as task_id, t.approval_request_id, t.step_code, t.due_at, t.delegated_from,
           ft.assignee_user_id as escalated_from,
           coalesce(nullif(btrim(st.name), ''), t.step_code) as step,
           ar.object_type, ar.object_id, ar.requested_at,
           coalesce(ar.requested_by, ar.created_by) as requested_by,
           d.id as document_id, d.document_number,
           coalesce(nullif(btrim(dt.name), ''), dt.code) as document_type,
           pa.name as partner,
           case when d.id is not null then erp.document_value_minor(d.id) end as value_minor,
           d.currency,
           coalesce(cu.minor_units, 2) as minor_units
      into r
      from erp.approval_task t
      join erp.approval_request ar on ar.tenant_id = t.tenant_id and ar.id = t.approval_request_id
      left join erp.approval_step st on st.tenant_id = t.tenant_id and st.id = t.approval_step_id
      left join erp.approval_task ft on ft.tenant_id = t.tenant_id and ft.id = t.escalated_from
      left join erp.document d
        on ar.object_type = 'document' and d.tenant_id = ar.tenant_id and d.id = ar.object_id
      left join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
      left join erp.party pa on pa.tenant_id = d.tenant_id and pa.id = d.party_id
      left join erp_ref.currency cu on cu.code = d.currency
     where t.tenant_id = v_tenant and t.id = p_event.aggregate_id;
    if not found then
      return null;
    end if;

    v_esc := p_event.event_type = 'approval.task_escalated';
    v_doc := r.document_id is not null;
    w := erp.email_words('approval', v_locale);

    v_links := v_links || jsonb_build_object('primary', '/governance?task=' || r.task_id::text);
    if v_doc then
      v_links := v_links || jsonb_build_object('secondary', '/documents/' || r.document_id::text);
    end if;

    return jsonb_build_object(
      'version', 1,
      'kind', 'approval',
      'locale', v_locale,
      'time_zone', v_reader ->> 'time_zone',
      'mandatory', coalesce(p_mandatory, false),
      'words', v_common || jsonb_strip_nulls(jsonb_build_object(
        'subject', erp.email_product_text(
                     'email.approval.subject' || case when v_esc then '_escalated' else '' end
                                              || case when v_doc then '' else '_plain' end, v_locale),
        'preheader', w ->> case when v_doc then 'preheader_document' else 'preheader' end,
        'heading', w ->> case when v_esc then 'heading_escalated' else 'heading' end,
        'intro', w ->> ('intro' || case when v_esc then '_escalated' else '' end
                                || case when v_doc then '_document' else '' end),
        'primary', w ->> 'primary',
        'secondary', case when v_doc then w ->> 'secondary' end,
        'note', w ->> 'note',
        'reason', w ->> case when v_esc then 'reason_escalated' else 'reason' end)),
      'labels', erp.email_words('approval.label', v_locale),
      'links', v_links,
      'fields', jsonb_strip_nulls(jsonb_build_object(
        'task_id', r.task_id,
        'approval_request_id', r.approval_request_id,
        'object_type', r.object_type,
        'object_id', r.object_id,
        'step_code', r.step_code,
        'step', r.step,
        'escalated', v_esc,
        'document_id', r.document_id,
        'document_number', r.document_number,
        'document_type', r.document_type,
        'partner', r.partner,
        'value_minor', r.value_minor,
        'currency', r.currency,
        'minor_units', case when v_doc then r.minor_units end,
        'requested_at', erp.email_instant(r.requested_at),
        'due_at', erp.email_instant(r.due_at))),
      'people', jsonb_strip_nulls(jsonb_build_object(
        'requested_by', r.requested_by,
        'delegated_from', r.delegated_from,
        'escalated_from', r.escalated_from)));
  end if;

  -- ── A configuration change waiting for somebody else ────────────────────────
  if p_event.event_type = 'change_set.submitted' then
    select cs.id, cs.code, cs.name into cs_row
      from erp.change_set cs
     where cs.tenant_id = v_tenant and cs.id = p_event.aggregate_id;
    if not found then
      return null;
    end if;
    w := erp.email_words('change_set', v_locale);

    return jsonb_build_object(
      'version', 1,
      'kind', 'change_set',
      'locale', v_locale,
      'time_zone', v_reader ->> 'time_zone',
      'mandatory', coalesce(p_mandatory, false),
      'words', v_common || jsonb_strip_nulls(jsonb_build_object(
        'subject', erp.email_product_text('email.change_set.subject', v_locale),
        'preheader', w ->> 'preheader',
        'heading', w ->> 'heading',
        'intro', w ->> 'intro',
        'primary', w ->> 'primary',
        'reason', w ->> 'reason')),
      'labels', erp.email_words('change_set.label', v_locale),
      -- The configuration screen brings the change a link names into view.
      'links', v_links || jsonb_build_object(
        'primary', '/administration/configuration?change=' || cs_row.id::text),
      'fields', jsonb_strip_nulls(jsonb_build_object(
        'change_set_id', cs_row.id,
        'code', cs_row.code,
        'name', cs_row.name,
        'item_count', case when jsonb_typeof(p_event.payload -> 'item_count') = 'number'
                           then p_event.payload -> 'item_count' end,
        'submitted_at', erp.email_instant(p_event.occurred_at))),
      'people', jsonb_strip_nulls(jsonb_build_object('submitted_by', p_event.actor_id)));
  end if;

  -- ── A scheduled job that used up its retries ────────────────────────────────
  if p_event.event_type = 'job.failed' then
    w := erp.email_words('job_failed', v_locale);
    v_once := coalesce(p_event.payload ->> 'consecutive_failures', '') in ('', '1');

    return jsonb_build_object(
      'version', 1,
      'kind', 'job_failed',
      'locale', v_locale,
      'time_zone', v_reader ->> 'time_zone',
      'mandatory', coalesce(p_mandatory, false),
      'words', v_common || jsonb_strip_nulls(jsonb_build_object(
        'subject', erp.email_product_text('email.job_failed.subject', v_locale),
        'preheader', w ->> case when v_once then 'preheader_once' else 'preheader' end,
        'heading', w ->> 'heading',
        'intro', w ->> case when v_once then 'intro_once' else 'intro' end,
        'primary', w ->> 'primary',
        'reason', w ->> 'reason')),
      'labels', erp.email_words('job_failed.label', v_locale),
      'links', v_links || jsonb_build_object('primary', '/operations/jobs'),
      'fields', jsonb_strip_nulls(jsonb_build_object(
        'job_id', p_event.aggregate_id,
        'job_code', coalesce(nullif(p_event.payload ->> 'job_code', ''),
                             (select j.code from erp.job j where j.tenant_id = v_tenant and j.id = p_event.aggregate_id)),
        'job_name', (select j.name from erp.job j where j.tenant_id = v_tenant and j.id = p_event.aggregate_id),
        'handler', nullif(p_event.payload ->> 'handler', ''),
        'handler_name', (select erp.text(h.name_key, v_locale) from erp_ref.job_handler h
                          where h.code = p_event.payload ->> 'handler'),
        'consecutive_failures', case when jsonb_typeof(p_event.payload -> 'consecutive_failures') = 'number'
                                     then p_event.payload -> 'consecutive_failures' end,
        'error', left(nullif(p_event.payload ->> 'error', ''), 2000),
        'failed_at', erp.email_instant(p_event.occurred_at))));
  end if;

  -- ── Support given access ────────────────────────────────────────────────────
  -- The member of staff is named when the email leaves, from the access record.
  w := erp.email_words('support_access', v_locale);
  select sa.id, sa.staff_role, sa.reason, sa.is_write_access, sa.granted_at, sa.expires_at into sa_row
    from erp.support_access sa
   where sa.tenant_id = v_tenant and sa.id = p_event.aggregate_id;

  return jsonb_build_object(
    'version', 1,
    'kind', 'support_access',
    'locale', v_locale,
    'time_zone', v_reader ->> 'time_zone',
    'mandatory', coalesce(p_mandatory, false),
    'words', v_common || jsonb_strip_nulls(jsonb_build_object(
      'subject', erp.email_product_text('email.support_access.subject', v_locale),
      'preheader', w ->> 'preheader',
      'heading', w ->> 'heading',
      'intro', w ->> 'intro',
      'access', case when sa_row.id is null then null
                     when sa_row.is_write_access then w ->> 'access_write'
                     else w ->> 'access_read' end,
      'primary', w ->> 'primary',
      'reason', w ->> 'reason')),
    'labels', erp.email_words('support_access.label', v_locale),
    'links', v_links || jsonb_build_object('primary', '/operations/continuity'),
    'fields', jsonb_strip_nulls(jsonb_build_object(
      'access_id', p_event.aggregate_id,
      'staff_role', coalesce(sa_row.staff_role, nullif(p_event.payload ->> 'staff_role', '')),
      'reason', coalesce(sa_row.reason, nullif(p_event.payload ->> 'reason', '')),
      'write_access', sa_row.is_write_access,
      'granted_at', erp.email_instant(coalesce(sa_row.granted_at, p_event.occurred_at)),
      'expires_at', coalesce(erp.email_instant(sa_row.expires_at),
                             case when p_event.payload ->> 'expires_at' ~ '^\d{4}-\d{2}-\d{2}'
                                  then erp.email_instant((p_event.payload ->> 'expires_at')::timestamptz) end))));
end;
$$;

revoke all on function erp.notification_email_context(erp.event, uuid, boolean) from public, anon, authenticated;

comment on function erp.notification_email_context(erp.event, uuid, boolean) is
  'What the email for an event says to one person (20260914094000): the kind, the '
  'facts, the words in their language and the link paths, for approval tasks, '
  'configuration changes waiting for a second approver, failed jobs and support '
  'access. Null for any other event. People are ids; the claim names them.';

create or replace function erp.notification_digest_context(
  p_digest_key text, p_app_user_id uuid, p_count integer)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_reader jsonb := erp.email_reader(v_tenant, p_app_user_id);
  v_locale text := v_reader ->> 'locale';
  v_one    boolean := coalesce(p_count, 0) = 1;
  w        jsonb := erp.email_words('digest', v_locale);
  v_items  jsonb;
  v_listed integer;
begin
  -- The messages the digest collects, as their subjects and when each arrived;
  -- the first twenty, and a line saying how many more.
  select coalesce(jsonb_agg(jsonb_build_object('at', erp.email_instant(x.created_at),
                                               'subject', left(x.subject, 200))
                            order by x.created_at, x.id), '[]'::jsonb),
         count(*)
    into v_items, v_listed
    from (select n.id, n.created_at, n.subject
            from erp.notification n
           where n.tenant_id = v_tenant and n.status = 'pending'
             and n.digest_key = p_digest_key and n.app_user_id = p_app_user_id
           order by n.created_at, n.id
           limit 20) x;

  return jsonb_build_object(
    'version', 1,
    'kind', 'digest',
    'locale', v_locale,
    'time_zone', v_reader ->> 'time_zone',
    'mandatory', false,
    'words', erp.email_words('common', v_locale) || jsonb_strip_nulls(jsonb_build_object(
      'subject', erp.email_product_text('email.digest.' || case when v_one then 'subject_one' else 'subject' end, v_locale),
      'preheader', w ->> case when v_one then 'preheader_one' else 'preheader' end,
      'heading', w ->> case when v_one then 'heading_one' else 'heading' end,
      'intro', w ->> 'intro',
      'primary', w ->> 'primary',
      'note', case when coalesce(p_count, 0) > v_listed then w ->> 'more' end,
      'reason', w ->> 'reason')),
    'labels', '{}'::jsonb,
    'links', jsonb_build_object('primary', '/notifications', 'preferences', '/notifications'),
    'fields', jsonb_build_object(
      'count', coalesce(p_count, 0),
      'more', greatest(coalesce(p_count, 0) - v_listed, 0),
      'items', v_items));
end;
$$;

revoke all on function erp.notification_digest_context(text, uuid, integer) from public, anon, authenticated;

comment on function erp.notification_digest_context(text, uuid, integer) is
  'What a digest email says (20260914094000): how many messages it collects, the '
  'first twenty by subject and time, and the words in the reader''s language.';

-- The names a context refers to, read now.
create or replace function erp.notification_email_names(p_tenant_id uuid, p_context jsonb)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
           (select jsonb_object_agg(x.key, u.display_name)
              from jsonb_each_text(case when jsonb_typeof(p_context -> 'people') = 'object'
                                        then p_context -> 'people' else '{}'::jsonb end) x
              join erp.app_user u
                on u.tenant_id = p_tenant_id
               and u.id = case when x.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                               then x.value::uuid end),
           '{}'::jsonb)
      || coalesce(
           (select jsonb_build_object('staff', sa.staff_email)
              from erp.support_access sa
             where p_context ->> 'kind' = 'support_access'
               and sa.tenant_id = p_tenant_id
               and sa.id = case when (p_context -> 'fields' ->> 'access_id')
                                     ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                                then (p_context -> 'fields' ->> 'access_id')::uuid end),
           '{}'::jsonb)
$$;

revoke all on function erp.notification_email_names(uuid, jsonb) from public, anon, authenticated;

comment on function erp.notification_email_names(uuid, jsonb) is
  'The display names of the people an email context refers to by id, and for support '
  'access the member of staff, read at the moment the email is claimed, so a person '
  'erased after the notification was written is not named by it.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. Routing writes the context
-- ═════════════════════════════════════════════════════════════════════════════

do $router$
declare
  v_sig text := 'erp.route_notifications()';
  v_def text := pg_get_functiondef('erp.route_notifications()'::regprocedure);
  v_org_old text := $o$        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until, digest_key)
        values (v_tenant, rt.id, ev.id, rt.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold,
                case when rt.digest_minutes is not null then rt.code || ':' || v_user::text end);
$o$;
  v_org_new text := $r$        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until, digest_key, context)
        values (v_tenant, rt.id, ev.id, rt.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold,
                case when rt.digest_minutes is not null then rt.code || ':' || v_user::text end,
                -- What the email says (20260914094000). A route that digests
                -- gets none per message: the digest carries its own.
                case when v_chan = 'email' and rt.digest_minutes is null
                     then erp.notification_email_context(ev, v_user, rt.is_mandatory) end);
$r$;
  v_product_old text := $o$        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until)
        values (v_tenant, null, ev.id, pr.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold);
$o$;
  v_product_new text := $r$        insert into erp.notification
          (tenant_id, route_id, event_id, severity, app_user_id, channel_kind, subject, body,
           status, held_until, context)
        values (v_tenant, null, ev.id, pr.severity, v_user, v_chan, v_subj, v_body,
                case when v_hold is not null then 'held' else 'pending' end, v_hold,
                -- What the email says (20260914094000); the body stays the fallback.
                case when v_chan = 'email'
                     then erp.notification_email_context(ev, v_user, pr.is_mandatory) end);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_org_old, ''))) / length(v_org_old) <> 1
     or (length(v_def) - length(replace(v_def, v_product_old, ''))) / length(v_product_old) <> 1
     or position('notification_email_context' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260913121000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(replace(v_def, v_org_old, v_org_new), v_product_old, v_product_new);
  if (length(pg_get_functiondef(v_sig::regprocedure))
      - length(replace(pg_get_functiondef(v_sig::regprocedure), 'erp.notification_email_context(ev, v_user', '')))
     / length('erp.notification_email_context(ev, v_user') <> 2 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without both of its email contexts', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needles above.';
  end if;
end
$router$;

-- A digest says what it collects.
do $digest$
declare
  v_sig text := 'erp.dispatch_notifications()';
  v_def text := pg_get_functiondef('erp.dispatch_notifications()'::regprocedure);
  v_old text := $o$    insert into erp.notification
      (tenant_id, route_id, severity, app_user_id, channel_kind, subject, body, status, digest_of)
    values (v_tenant, d.route_id, d.severity, d.app_user_id, d.channel_kind,
            format('%s: %s update(s)', d.name, d.cnt), v_body, 'pending', d.cnt);
$o$;
  v_new text := $r$    insert into erp.notification
      (tenant_id, route_id, severity, app_user_id, channel_kind, subject, body, status, digest_of, context)
    values (v_tenant, d.route_id, d.severity, d.app_user_id, d.channel_kind,
            format('%s: %s update(s)', d.name, d.cnt), v_body, 'pending', d.cnt,
            -- What the digest email says (20260914094000): read before the
            -- messages it collects are marked digested just below.
            case when d.channel_kind = 'email'
                 then erp.notification_digest_context(d.digest_key, d.app_user_id, d.cnt::integer) end);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('notification_digest_context' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260906144000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
  if position('erp.notification_digest_context(d.digest_key' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its digest context', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;
end
$digest$;

-- An incident notice says what is known. Inline rather than in a helper: the
-- sweep reads platform-internal tables as its owner, and a helper of its own
-- would be an invoker routine that names them.
do $incidents$
declare
  v_sig text := 'erp.communicate_incidents()';
  v_def text := pg_get_functiondef('erp.communicate_incidents()'::regprocedure);
  v_old text := $o$      insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
      select v_tenant, v_sevn, u, 'email', v_subject, v_body, 'queued'
       where exists (select 1 from erp.app_user au where au.id = u and au.email is not null);
$o$;
  v_new text := $r$      insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status, context)
      select v_tenant, v_sevn, u, 'email', v_subject, v_body, 'queued',
             -- What the email says (20260914094000); the body is the update as posted.
             (select jsonb_build_object(
                       'version', 1,
                       'kind', 'incident',
                       'locale', rd.reader ->> 'locale',
                       'time_zone', rd.reader ->> 'time_zone',
                       'mandatory', true,
                       'words', erp.email_words('common', rd.reader ->> 'locale') || jsonb_strip_nulls(jsonb_build_object(
                         'subject', erp.email_product_text(
                                      case when r.is_update then 'email.incident.subject_update'
                                           else 'email.incident.subject' end, rd.reader ->> 'locale'),
                         'preheader', ww.words ->> case when r.is_update then 'preheader_update' else 'preheader' end,
                         'heading', ww.words ->> case when r.is_update then 'heading_update' else 'heading' end,
                         'intro', ww.words ->> case when r.is_update then 'intro_update' else 'intro' end,
                         'primary', ww.words ->> 'primary',
                         'reason', ww.words ->> 'reason',
                         'mandatory', ww.words ->> 'mandatory')),
                       'labels', erp.email_words('incident.label', rd.reader ->> 'locale'),
                       'links', jsonb_build_object('primary', '/operations/continuity',
                                                   'preferences', '/notifications'),
                       'fields', jsonb_strip_nulls(jsonb_build_object(
                         'incident_id', r.incident_id,
                         'update_id', r.update_id,
                         'code', r.code,
                         'severity', upper(r.severity_code),
                         'title', r.title,
                         'is_update', r.is_update,
                         'declared_at', erp.email_instant(i.declared_at),
                         'next_update_at', erp.email_instant(coalesce(up.next_update_at, i.next_update_due_at)),
                         'components', (select jsonb_agg(erp.text(pc.name_key, rd.reader ->> 'locale')
                                                         order by ic.component_code)
                                          from erp_meta.incident_component ic
                                          join erp_ref.platform_component pc on pc.code = ic.component_code
                                         where ic.incident_id = r.incident_id),
                         'body', left(v_body, 4000))))
                from erp_meta.incident i
                cross join lateral (select erp.email_reader(v_tenant, u) as reader) rd
                cross join lateral (select erp.email_words('incident', rd.reader ->> 'locale') as words) ww
                left join erp_meta.incident_update up on up.id = r.update_id
               where i.id = r.incident_id)
       where exists (select 1 from erp.app_user au where au.id = u and au.email is not null);
$r$;
begin
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1
     or position('''kind'', ''incident''' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % is not the 20260913120000 body this migration patches', v_sig
      using hint = 'Read the live body with pg_get_functiondef and write the patch against it under a new migration version.';
  end if;
  execute replace(v_def, v_old, v_new);
  if position('''kind'', ''incident''' in pg_get_functiondef(v_sig::regprocedure)) = 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: % was re-emitted without its email context', v_sig
      using hint = 'The replacement did not land; compare the patched body with the needle above.';
  end if;
end
$incidents$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The claim returns what an email needs
-- ═════════════════════════════════════════════════════════════════════════════
--
-- A new result shape is a new function, so the old one goes first. What it did
-- is kept statement for statement: the kill switch, then the demonstration
-- refusal (20260914072000), then the same claim and lease. Proven here against
-- the live body before it is dropped.

do $claim$
declare
  v_def text := pg_get_functiondef('erp.claim_email_batch(integer,text)'::regprocedure);
begin
  if position($k$  if erp.is_killed('integration', 'email') then
    return;
  end if;$k$ in v_def) = 0
     or position($d$  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;$d$ in v_def) = 0
     or position('lease_expires_at = now() + interval ''5 minutes''' in v_def) = 0
     or position('context' in v_def) > 0 then
    raise exception 'CLOVEERP_BODY_UNRECOGNISED: erp.claim_email_batch(integer, text) is not the 20260914072000 body this migration re-creates'
      using hint = 'Read the live body with pg_get_functiondef and re-create the claim from it under a new migration version.';
  end if;
end
$claim$;

drop function erp.claim_email_batch(integer, text);

create function erp.claim_email_batch(p_limit integer default 50, p_worker text default null)
returns table(id uuid, to_address text, subject text, body text, from_address text, reply_to text,
              severity text, context jsonb, organisation_name text, recipient_name text)
language plpgsql
set search_path = ''
as $$
declare v_tenant uuid := erp.require_tenant_id();
begin
  if erp.is_killed('integration', 'email') then
    return;
  end if;

  -- A demonstration sends nothing outside the product (20260914072000). Its
  -- notifications are written in-app; one queued before that, or moved here
  -- by a writer that forgot, is never handed to a sender.
  if erp.tenant_is_demonstration(v_tenant) then
    return;
  end if;

  -- The batch is marked 'sending' inside the claim, with who holds it and until
  -- when, so a worker that dies mid-flight leaves rows that are visibly stuck
  -- and reclaimable, rather than rows that look queued and get sent again.
  return query
  with claimed as (
    select n.id
      from erp.notification n
     where n.tenant_id = v_tenant
       and n.channel_kind = 'email'
       and n.status = 'queued'
     order by n.created_at
     limit greatest(p_limit, 1)
     for update skip locked
  ),
  marked as (
    update erp.notification n
       set status = 'sending',
           claimed_by = coalesce(p_worker, current_user),
           claimed_at = now(),
           lease_expires_at = now() + interval '5 minutes',
           send_attempts = n.send_attempts + 1
      from claimed c
     where n.id = c.id
     returning n.*
  )
  select m.id,
         u.email,
         m.subject,
         m.body,
         coalesce(m.sender, erp.sender_for('operational') ->> 'from_address'),
         erp.sender_for('operational') ->> 'reply_to',
         m.severity::text,
         -- The context as it was written, with the names of the people it
         -- refers to read now (20260914094000).
         case when m.context is not null
              then m.context || jsonb_build_object('names', erp.notification_email_names(m.tenant_id, m.context))
         end,
         t.name,
         u.display_name
    from marked m
    join erp.app_user u on u.id = m.app_user_id
    join erp.tenant t on t.id = m.tenant_id;
end;
$$;

revoke all on function erp.claim_email_batch(integer, text) from public, anon, authenticated;

comment on function erp.claim_email_batch(integer, text) is
  'Claims up to p_limit queued emails for the organisation in context, marking them '
  'sending under a five-minute lease held by p_worker. Nothing while the email kill '
  'switch is on, and nothing for a demonstration organisation. Returns each message '
  'with its context (names read now), the organisation''s name and the reader''s name, '
  'so the sender can lay it out; body is the plain fallback.';

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- One organisation that trades, provisioned and configured inside a block that
-- is rolled back at the end, so nothing it writes is ever committed: no minute
-- pass, drain or other session can see a row it queues, and every claim it
-- makes is scoped to its own organisation. The block's own state goes with it,
-- the settings it changes included, and the last case proves so.

create or replace function erp_test.notification_email_context_suite()
returns table (case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_job_before    text := coalesce(current_setting('erp.job_tenant_id', true), '');
  v_claims_before text := coalesce(current_setting('request.jwt.claims', true), '');
  v_tag      text := substr(md5(gen_random_uuid()::text), 1, 8);
  a_admin    uuid := gen_random_uuid();
  a_approver uuid := gen_random_uuid();
  v_step     text := 'starting';
  v_state    text;
  r          record;
  v_tenant   uuid;
  v_org_name text := 'Mail Context Suite & Co';
  u_admin    uuid;
  u_approver uuid;
  v_entity   uuid;
  v_site     uuid;
  v_party    uuid;
  v_item     uuid;
  v_ccy      char(3);
  v_doc      uuid;
  v_number   text;
  v_value    bigint;
  v_chain    uuid;
  v_ver      uuid;
  v_req      uuid;
  v_task     uuid;
  v_due      timestamptz;
  v_ev       uuid;
  v_note     uuid;
  v_ctx      jsonb;
  v_body     text;
  v_job_ev   uuid;
  v_job_ctx  jsonb;
  v_mandatory boolean;
  v_plain    uuid;
  v_n        integer;
  v_c_ctx    jsonb;
  v_c_org    text;
  v_c_name   text;
  v_p_ctx    jsonb;
  v_p_org    text;
  v_p_name   text;
  v_p_found  boolean;

  ok_route    boolean; msg_route    text;
  ok_links    boolean; msg_links    text;
  ok_words    boolean; msg_words    text;
  ok_nameless boolean; msg_nameless text;
  ok_body     boolean; msg_body     text;
  ok_job      boolean; msg_job      text;
  ok_claim    boolean; msg_claim    text;
  ok_plain    boolean; msg_plain    text;
  ok_demo     boolean; msg_demo     text;
begin
  begin
    -- ── An organisation that trades ─────────────────────────────────────────
    v_step := 'an organisation is provisioned';
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('erp.job_principal_id', '', true);
    perform set_config('request.jwt.claims', '', true);
    select * into r from erp.provision_tenant('zzmailctx-' || v_tag, v_org_name,
                                              'admin@zzmailctx-' || v_tag || '.test', 'Context Admin');
    v_tenant := r.tenant_id;
    update erp.environment set is_live = false where tenant_id = v_tenant and is_self;
    insert into auth.users (id, email)
    values (a_admin, 'admin@zzmailctx-' || v_tag || '.test'),
           (a_approver, 'approver@zzmailctx-' || v_tag || '.test');
    perform set_config('erp.job_tenant_id', '', true);
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    u_admin := erp.claim_invitation(r.admin_token);

    v_step := 'the organisation is configured to trade';
    perform erp.ensure_demo_configuration(v_tenant, u_admin);

    v_step := 'an approver who also administers';
    insert into erp.app_user (tenant_id, auth_user_id, kind, status, display_name, email, user_locale)
    values (v_tenant, a_approver, 'person', 'active', 'Context Approver',
            'approver@zzmailctx-' || v_tag || '.test', 'en')
    returning id into u_approver;
    insert into erp.user_role (tenant_id, app_user_id, role_id, grant_reason)
    select v_tenant, u_approver, ro.id, 'the suite needs an administrator other than whoever raises a failure'
      from erp.role ro
     where ro.tenant_id = v_tenant and ro.code = 'administrator' and ro.status = 'active';

    v_step := 'a document worth four thousand two hundred';
    select e.id, e.base_currency into v_entity, v_ccy
      from erp.entity e where e.tenant_id = v_tenant order by e.code limit 1;
    select s.id into v_site from erp.site s
     where s.tenant_id = v_tenant and s.site_type = 'warehouse' order by s.code limit 1;
    select pr.party_id into v_party from erp.party_role pr
     where pr.tenant_id = v_tenant and pr.role_kind = 'customer' order by pr.party_id limit 1;
    insert into erp.item (tenant_id, code, name, item_class, stock_uom_id, status)
    select v_tenant, 'ZZ-MAIL', 'Mail context item', 'FG', u.id, 'active'
      from erp.uom u where u.tenant_id = v_tenant and u.is_base limit 1
    returning id into v_item;
    v_doc := erp.create_document('sales_order', v_entity, v_site, v_party, current_date, v_ccy,
                                 'ZZ-MAIL-CTX', '{}'::jsonb);
    perform erp.add_document_line(v_doc, v_item, 10, 42000, 'ten at four hundred and twenty', current_date);
    select d.document_number into v_number from erp.document d where d.id = v_doc;
    v_value := erp.document_value_minor(v_doc);

    v_step := 'an approval chain for documents names the approver';
    insert into erp.approval_chain (tenant_id, code, name, object_type, priority)
    -- Ahead of whatever chains the installers made for documents.
    values (v_tenant, 'zz_mail_ctx', 'Mail context suite', 'document', -1000)
    returning id into v_chain;
    insert into erp.approval_chain_version (tenant_id, approval_chain_id, version, status)
    values (v_tenant, v_chain, 1, 'draft')
    returning id into v_ver;
    insert into erp.approval_step (tenant_id, approval_chain_version_id, seq, code, name, approver_kind,
                                   app_user_id, escalate_after, escalate_to_user_id)
    values (v_tenant, v_ver, 1, 'finance_review', 'Finance review', 'user', u_approver,
            interval '2 days', u_admin);
    perform erp.activate_approval_chain_version(v_ver, current_date);

    v_step := 'notification services start before anything is asked';
    perform erp.ensure_notification_services();

    -- ── 1-5. The approval the route writes ──────────────────────────────────
    v_step := 'the document''s approval is requested and routed';
    v_req := erp.request_approval('document', v_doc, jsonb_build_object('suite', 'mail context'), 1,
                                  v_entity, v_site);
    select t.id, t.due_at into v_task, v_due from erp.approval_task t
     where t.tenant_id = v_tenant and t.approval_request_id = v_req
       and t.status = 'pending' and t.assignee_user_id = u_approver;
    select e.id into v_ev from erp.event e
     where e.tenant_id = v_tenant and e.event_type = 'approval.task_assigned' and e.aggregate_id = v_task;
    perform erp.route_notifications();
    select n.id, n.context, n.body into v_note, v_ctx, v_body
      from erp.notification n
     where n.tenant_id = v_tenant and n.event_id = v_ev and n.app_user_id = u_approver
       and n.channel_kind = 'email' and n.route_id is null
     limit 1;

    ok_route := v_note is not null
            and v_ctx ->> 'kind' = 'approval'
            and v_ctx -> 'fields' ->> 'document_number' = v_number
            and v_value > 0
            and (v_ctx -> 'fields' ->> 'value_minor')::bigint = v_value
            and v_ctx -> 'fields' ->> 'currency' = v_ccy
            and (v_ctx -> 'fields' ->> 'minor_units')::integer = 2
            and v_ctx -> 'fields' ->> 'step' = 'Finance review'
            and v_due is not null
            and v_ctx -> 'fields' ->> 'due_at' = erp.email_instant(v_due)
            and v_ctx -> 'fields' ->> 'task_id' = v_task::text
            and v_ctx -> 'fields' ->> 'approval_request_id' = v_req::text
            and v_ctx -> 'fields' ->> 'document_id' = v_doc::text
            and v_ctx -> 'people' ->> 'requested_by' = u_admin::text
            and not coalesce((v_ctx ->> 'mandatory')::boolean, true);
    msg_route := format('document %s worth %s %s; fields %s', coalesce(v_number, 'unnumbered'), v_value,
                        v_ccy, left(coalesce((v_ctx -> 'fields')::text, 'no context'), 400));

    ok_links := v_ctx -> 'links' ->> 'primary' = '/governance?task=' || v_task::text
            and v_ctx -> 'links' ->> 'secondary' = '/documents/' || v_doc::text
            and v_ctx -> 'links' ->> 'preferences' = '/notifications';
    msg_links := coalesce((v_ctx -> 'links')::text, 'no links');

    ok_words := not exists (
                  select 1
                    from unnest(array['subject', 'preheader', 'heading', 'intro', 'primary', 'secondary',
                                      'note', 'reason', 'greeting', 'fallback', 'preferences',
                                      'footer', 'mandatory']) s(slot)
                   where coalesce(v_ctx -> 'words' ->> s.slot, 'email.') like 'email.%')
            and v_ctx -> 'words' ->> 'subject' = erp.email_product_text('email.approval.subject', 'en')
            and v_ctx -> 'words' ->> 'primary' = erp.text('email.approval.primary', 'en')
            and (select count(*) from jsonb_object_keys(v_ctx -> 'labels')) = 10
            and not exists (select 1 from jsonb_each_text(v_ctx -> 'labels') l where l.value like 'email.%');
    msg_words := left(coalesce((v_ctx -> 'words')::text, 'no words'), 400);

    ok_nameless := v_ctx is not null
               and position('Context Admin' in v_ctx::text) = 0
               and position('Context Approver' in v_ctx::text) = 0
               and position('@zzmailctx-' in v_ctx::text) = 0;
    msg_nameless := 'the requester is an id in people; no display name or address is frozen';

    ok_body := v_body = erp.text('notify.approval_requested.body', 'en') || E'\n\n'
                        || (select res.value from erp_ref.resource res
                             where res.key = 'app.base_url' and res.locale = 'en') || '/governance';
    msg_body := coalesce(v_body, 'no body');

    -- ── 6. A failed job, told to an administrator ───────────────────────────
    v_step := 'a scheduled job fails';
    v_job_ev := erp.append_event('job.failed', 'job', gen_random_uuid(),
      jsonb_build_object('job_code', 'zz_mail_job', 'handler', 'notifications.dispatch',
                         'consecutive_failures', 3, 'error', 'relation "zz_missing" does not exist'));
    perform erp.route_notifications();
    -- The product's route, or the base pack's of the same code where the
    -- installers promoted it; either way the context says what the route says
    -- about switching it off.
    select n.context, coalesce(rt.is_mandatory, true) into v_job_ctx, v_mandatory
      from erp.notification n
      left join erp.notification_route rt on rt.tenant_id = n.tenant_id and rt.id = n.route_id
     where n.tenant_id = v_tenant and n.event_id = v_job_ev and n.app_user_id = u_approver
       and n.channel_kind = 'email'
     limit 1;
    ok_job := v_job_ctx ->> 'kind' = 'job_failed'
          and (v_job_ctx ->> 'mandatory')::boolean is not distinct from v_mandatory
          and v_job_ctx -> 'fields' ->> 'job_code' = 'zz_mail_job'
          and v_job_ctx -> 'fields' ->> 'error' = 'relation "zz_missing" does not exist'
          and v_job_ctx -> 'fields' ->> 'consecutive_failures' = '3'
          and v_job_ctx -> 'links' ->> 'primary' = '/operations/jobs'
          and v_job_ctx -> 'words' ->> 'intro' = erp.text('email.job_failed.intro', 'en');
    msg_job := left(coalesce(v_job_ctx::text, 'no email context for the administrator'), 400);

    -- ── 7. The claim returns what the email needs ───────────────────────────
    v_step := 'dispatch queues and a sender claims';
    perform erp.dispatch_notifications();
    select c.context, c.organisation_name, c.recipient_name into v_c_ctx, v_c_org, v_c_name
      from erp.claim_email_batch(50, 'zz-mail-context') c
     where c.id = v_note;
    ok_claim := v_c_ctx ->> 'kind' = 'approval'
            and v_c_ctx -> 'names' ->> 'requested_by' = 'Context Admin'
            and v_c_ctx -> 'fields' ->> 'document_number' = v_number
            and v_c_org = v_org_name
            and v_c_name = 'Context Approver';
    msg_claim := format('organisation %s, reader %s, names %s', coalesce(v_c_org, 'none'),
                        coalesce(v_c_name, 'none'), coalesce((v_c_ctx -> 'names')::text, 'none'));

    -- ── 8. A notification with no context still claims ──────────────────────
    v_step := 'a notification with no context is queued and claimed';
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'info', u_approver, 'email', 'Mail context suite', 'A plain body and nothing else.', 'queued')
    returning id into v_plain;
    select true, c.context, c.organisation_name, c.recipient_name
      into v_p_found, v_p_ctx, v_p_org, v_p_name
      from erp.claim_email_batch(50, 'zz-mail-context') c
     where c.id = v_plain;
    ok_plain := coalesce(v_p_found, false) and v_p_ctx is null
            and v_p_org = v_org_name and v_p_name = 'Context Approver'
            and (select n.status from erp.notification n where n.id = v_plain) = 'sending';
    msg_plain := format('claimed %s; context %s; organisation %s; reader %s',
                        coalesce(v_p_found, false), coalesce(v_p_ctx::text, 'null'),
                        coalesce(v_p_org, 'none'), coalesce(v_p_name, 'none'));

    -- ── 9. The kill switch and a demonstration still stop the claim ─────────
    v_step := 'the email kill switch is set';
    perform set_config('request.jwt.claims', json_build_object('sub', a_admin)::text, true);
    perform erp.set_kill_switch('integration', 'email', 'the mail context suite proves the claim still stops');
    insert into erp.notification (tenant_id, severity, app_user_id, channel_kind, subject, body, status)
    values (v_tenant, 'info', u_approver, 'email', 'Mail context suite', 'Held by the kill switch.', 'queued')
    returning id into v_plain;
    select count(*) into v_n from erp.claim_email_batch(50, 'zz-mail-context');
    ok_demo := v_n = 0 and (select n.status from erp.notification n where n.id = v_plain) = 'queued';
    msg_demo := format('kill switch: %s claimed', v_n);
    perform erp.clear_kill_switch('integration', 'email');

    v_step := 'the organisation becomes a demonstration';
    update erp.tenant set code = 'demo-' || v_tag where id = v_tenant;
    select count(*) into v_n from erp.claim_email_batch(50, 'zz-mail-context');
    ok_demo := ok_demo and erp.tenant_is_demonstration(v_tenant) and v_n = 0
           and (select n.status from erp.notification n where n.id = v_plain) = 'queued';
    msg_demo := msg_demo || format('; demonstration: %s claimed, the row is still %s', v_n,
                                   (select n.status from erp.notification n where n.id = v_plain));

    v_step := 'done';
    raise exception 'ZZ_NOTIFICATION_EMAIL_CONTEXT_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'ZZ_NOTIFICATION_EMAIL_CONTEXT_SUITE_UNDO' then
      v_state := v_step || ': ' || left(sqlerrm, 300);
    end if;
  end;

  case_name := 'an approval task on a document is routed with a context: number, value, step, due date and its request';
  passed := v_state is null and coalesce(ok_route, false);
  detail := coalesce(v_state, msg_route);
  return next;

  case_name := 'the context links to the task on the approvals screen and to the document';
  passed := v_state is null and coalesce(ok_links, false);
  detail := coalesce(v_state, msg_links);
  return next;

  case_name := 'every word the email says is resolved, and the subject is the product''s own';
  passed := v_state is null and coalesce(ok_words, false);
  detail := coalesce(v_state, msg_words);
  return next;

  case_name := 'the context freezes no name and no address';
  passed := v_state is null and coalesce(ok_nameless, false);
  detail := coalesce(v_state, msg_nameless);
  return next;

  case_name := 'the body stays the plain fallback, word for word';
  passed := v_state is null and coalesce(ok_body, false);
  detail := coalesce(v_state, msg_body);
  return next;

  case_name := 'a failed job is emailed to an administrator with its error, saying whether it can be switched off';
  passed := v_state is null and coalesce(ok_job, false);
  detail := coalesce(v_state, msg_job);
  return next;

  case_name := 'the claim returns the context with names read now, the organisation''s name and the reader''s';
  passed := v_state is null and coalesce(ok_claim, false);
  detail := coalesce(v_state, msg_claim);
  return next;

  case_name := 'a notification with no context still claims, so the plain body can be sent';
  passed := v_state is null and coalesce(ok_plain, false);
  detail := coalesce(v_state, msg_plain);
  return next;

  case_name := 'the kill switch and a demonstration organisation still stop every claim';
  passed := v_state is null and coalesce(ok_demo, false);
  detail := coalesce(v_state, msg_demo);
  return next;

  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code in ('zzmailctx-' || v_tag, 'demo-' || v_tag))
        and not exists (select 1 from auth.users au where au.id in (a_admin, a_approver))
        and coalesce(current_setting('erp.job_tenant_id', true), '') = v_job_before
        and coalesce(current_setting('request.jwt.claims', true), '') = v_claims_before;
  detail := 'the organisation, its people, its notifications and every setting went with the block';
  return next;
end;
$$;

revoke all on function erp_test.notification_email_context_suite() from public, anon, authenticated;

create or replace function erp_test.assert_notification_email_context_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 10;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _notification_email_context on commit drop as
    select * from erp_test.notification_email_context_suite();
  select count(*), count(*) filter (where coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_passed, v_detail
    from _notification_email_context s;
  drop table _notification_email_context;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_NOTIFICATION_EMAIL_CONTEXT_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using hint = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_passed < v_total then
    raise exception E'CLOVEERP_NOTIFICATION_EMAIL_CONTEXT_SUITE_FAILED: %/% case(s) failed\n%',
      v_total - v_passed, v_total, v_detail
      using hint = 'Read each failed case''s detail above; the first names the step that raised.';
  end if;
  return format('notification email context: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_notification_email_context_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 7. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
select erp.assert_vocabulary_aligned();
select erp.assert_notification_routes_resolvable();
select erp.assert_personal_data_register_sound();

select erp_test.assert_notification_email_context_suite();
select erp_test.assert_notification_product_routes_suite();
select erp_test.assert_email_delivery_suite();
select erp_test.assert_demo_stays_quiet_suite();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_invoker_doors_executable();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_no_public_execute();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
