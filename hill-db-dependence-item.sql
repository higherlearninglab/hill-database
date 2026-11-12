-- HiLL database: Dependence item (transfer of responsibility), reported beside the rating.
-- Applied on top of hill-db-tiebreak-guard.sql. Run once as a database administrator who is a member of hill_owner.
-- No question wording in this file.
-- An agent pre-fills each field with a quoted passage; a coder or the lead confirms.
-- A person who still has coding to submit on the study cannot see the row.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE TABLE tracker.study_dependence (
  study_id          text PRIMARY KEY REFERENCES tracker.studies,
  tool_design       text NOT NULL CHECK (tool_design IN ('fades','fixed or on demand','not reported','not applicable')),
  tool_design_quote text,
  tool_design_page  text,
  transfer_evidence text NOT NULL CHECK (transfer_evidence IN ('measured: transferred','measured: not transferred','not measured','not applicable')),
  transfer_quote    text,
  transfer_page     text,
  teacher_role      text NOT NULL CHECK (teacher_role IN ('yes','no','not reported','not applicable')),
  teacher_quote     text,
  teacher_page      text,
  note              text,
  prefilled_by      int REFERENCES admin.people DEFAULT admin.me(),
  prefilled_at      timestamptz NOT NULL DEFAULT now(),
  confirmed_by      int REFERENCES admin.people,
  confirmed_at      timestamptz,
  CHECK (tool_design NOT IN ('fades','fixed or on demand') OR tool_design_quote IS NOT NULL),
  CHECK (transfer_evidence NOT LIKE 'measured:%' OR transfer_quote IS NOT NULL),
  CHECK (teacher_role NOT IN ('yes','no') OR teacher_quote IS NOT NULL),
  CHECK ((confirmed_by IS NULL) = (confirmed_at IS NULL))
);
COMMENT ON TABLE tracker.study_dependence IS 'Dependence item: does the AI tool transfer responsibility to the student. Reported beside the rating; never an input to it.';

CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON tracker.study_dependence
  FOR EACH ROW EXECUTE FUNCTION admin.log_change();

-- Who may see a row: agents always; a person only when they have no coding left to submit on the study.
CREATE FUNCTION tracker.dependence_visible(p_study text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
  SELECT admin.my_login_role() = 'agent'
      OR (admin.my_login_role() IN ('lead','coder','tiebreak')
          AND NOT EXISTS (
            SELECT 1 FROM tracker.assignments a JOIN tracker.claims c USING (claim_id)
            WHERE c.study_id = p_study AND a.coder_id = admin.me()
              AND NOT EXISTS (SELECT 1 FROM tracker.codings k
                              WHERE k.claim_id = a.claim_id AND k.coder_id = a.coder_id AND k.status = 'submitted')))
$$;
REVOKE ALL ON FUNCTION tracker.dependence_visible(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.dependence_visible(text) TO hill_lead, hill_coder, hill_tiebreak, hill_agent;

ALTER TABLE tracker.study_dependence ENABLE ROW LEVEL SECURITY;
CREATE POLICY see  ON tracker.study_dependence FOR SELECT USING (tracker.dependence_visible(study_id));
CREATE POLICY add  ON tracker.study_dependence FOR INSERT WITH CHECK (admin.my_login_role() = 'agent');
CREATE POLICY edit ON tracker.study_dependence FOR UPDATE
  USING (tracker.dependence_visible(study_id)) WITH CHECK (tracker.dependence_visible(study_id));

REVOKE ALL ON tracker.study_dependence FROM PUBLIC, hill_lead, hill_coder, hill_tiebreak, hill_agent, hill_publisher;
GRANT SELECT ON tracker.study_dependence TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT INSERT (study_id, tool_design, tool_design_quote, tool_design_page, transfer_evidence, transfer_quote, transfer_page,
              teacher_role, teacher_quote, teacher_page, note) ON tracker.study_dependence TO hill_agent;
GRANT UPDATE (tool_design, tool_design_quote, tool_design_page, transfer_evidence, transfer_quote, transfer_page,
              teacher_role, teacher_quote, teacher_page, note) ON tracker.study_dependence TO hill_agent, hill_coder, hill_lead;

-- A change to any value clears the confirmation; an agent cannot change a confirmed row.
CREATE FUNCTION tracker.guard_dependence() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.tool_design, NEW.tool_design_quote, NEW.tool_design_page, NEW.transfer_evidence, NEW.transfer_quote, NEW.transfer_page,
      NEW.teacher_role, NEW.teacher_quote, NEW.teacher_page)
     IS DISTINCT FROM
     (OLD.tool_design, OLD.tool_design_quote, OLD.tool_design_page, OLD.transfer_evidence, OLD.transfer_quote, OLD.transfer_page,
      OLD.teacher_role, OLD.teacher_quote, OLD.teacher_page) THEN
    IF OLD.confirmed_by IS NOT NULL AND admin.my_login_role() = 'agent' THEN
      RAISE EXCEPTION 'A person has confirmed this Dependence record; an agent cannot change it.';
    END IF;
    IF NEW.confirmed_by IS NOT DISTINCT FROM OLD.confirmed_by THEN
      NEW.confirmed_by := NULL; NEW.confirmed_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_dependence BEFORE UPDATE ON tracker.study_dependence
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_dependence();

-- Confirmation is by a person, never an agent.
CREATE FUNCTION tracker.confirm_dependence(p_study text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('coder','lead') THEN
    RAISE EXCEPTION 'Only a coder or the lead can confirm a Dependence record.';
  END IF;
  IF NOT tracker.dependence_visible(p_study) THEN
    RAISE EXCEPTION 'Submit your coding of this study before confirming its Dependence record.';
  END IF;
  UPDATE tracker.study_dependence SET confirmed_by = admin.me(), confirmed_at = now() WHERE study_id = p_study;
  IF NOT FOUND THEN RAISE EXCEPTION 'No Dependence record for study %.', p_study; END IF;
END $$;
REVOKE ALL ON FUNCTION tracker.confirm_dependence(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.confirm_dependence(text) TO hill_coder, hill_lead;

-- Public: confirmed records of released studies only.
CREATE VIEW tracker.public_dependence AS
SELECT d.study_id, d.tool_design, d.tool_design_quote, d.tool_design_page,
       d.transfer_evidence, d.transfer_quote, d.transfer_page,
       d.teacher_role, d.teacher_quote, d.teacher_page
FROM tracker.study_dependence d JOIN tracker.released_studies USING (study_id)
WHERE d.confirmed_by IS NOT NULL;
REVOKE ALL ON tracker.public_dependence FROM PUBLIC;
GRANT SELECT ON tracker.public_dependence TO hill_lead, hill_publisher;

COMMIT;
