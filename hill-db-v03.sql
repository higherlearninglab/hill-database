-- HiLL database: CERIC-T v0.3 update (applied on top of the Phase 2 build).
-- Run once as a database administrator who is a member of hill_owner.
-- Question wording is not in this file; it is loaded from a private file.
--
-- What this adds (protocol and decision rules v0.3, decided by Gene on 2026-11-10):
--   * questions are kept per protocol version, so every coding stays tied to the wording it used
--   * the 42 v0.3 questions (C1-C7, E1-E10, R1-R8, I1-I9, Co1-Co8)
--   * the CER summary question (S1) and its reason; the Evidence tier; publication status
--   * the half rule and the v0.3 triggers; verdict rule 1 (S1 answered PN or N)
--   * S1 and the Evidence tier as reconcilable items
-- v0.2 questions and rules stay in place for any coding recorded under v0.2.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

-- ======================================================================
-- 1. Questions per protocol version
-- ======================================================================
ALTER TABLE tracker.answers DROP CONSTRAINT answers_question_code_fkey;
ALTER TABLE tracker.questions DROP CONSTRAINT questions_pkey;
ALTER TABLE tracker.questions ADD PRIMARY KEY (protocol_version, code);
ALTER TABLE tracker.answers ADD COLUMN protocol_version text;
UPDATE tracker.answers a SET protocol_version = c.protocol_version FROM tracker.codings c WHERE c.coding_id = a.coding_id;
ALTER TABLE tracker.answers ALTER COLUMN protocol_version SET NOT NULL;
ALTER TABLE tracker.answers ADD CONSTRAINT answers_question_fkey
  FOREIGN KEY (protocol_version, question_code) REFERENCES tracker.questions (protocol_version, code);
COMMENT ON COLUMN tracker.answers.protocol_version IS 'Always the protocol version of the coding; set by trigger.';

-- An answer always carries its coding's protocol version, whatever the writer sends.
CREATE FUNCTION tracker.set_answer_version() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  NEW.protocol_version := (SELECT protocol_version FROM tracker.codings WHERE coding_id = NEW.coding_id);
  RETURN NEW;
END $$;
CREATE TRIGGER a_set_answer_version BEFORE INSERT OR UPDATE ON tracker.answers
  FOR EACH ROW EXECUTE FUNCTION tracker.set_answer_version();

INSERT INTO tracker.protocol_versions (version, instrument, released_on, notes) VALUES
  ('CERIC-T v0.3', 'CERIC-T', '2026-11-10', 'Draft; not yet piloted. evidence-tracker/ceric-t-protocol-v0.3-draft.md');

INSERT INTO tracker.questions (code, element, position, wording, ni_reading, na_allowed, book_section, protocol_version) VALUES
  ('C1', 'Claim', 1, 'C1', 'unfavorable', false, '3.1', 'CERIC-T v0.3'),
  ('C2', 'Claim', 2, 'C2', 'unfavorable', true,  '3.4', 'CERIC-T v0.3'),
  ('C3', 'Claim', 3, 'C3', 'unfavorable', false, '3.3; 10.2.3', 'CERIC-T v0.3'),
  ('C4', 'Claim', 4, 'C4', 'unfavorable', false, '3.2; 5.1.4', 'CERIC-T v0.3'),
  ('C5', 'Claim', 5, 'C5', 'unfavorable', false, '4.3; 10.2.2', 'CERIC-T v0.3'),
  ('C6', 'Claim', 6, 'C6', 'unfavorable', false, '10.2.1', 'CERIC-T v0.3'),
  ('C7', 'Claim', 7, 'C7', 'unfavorable', false, '3.4', 'CERIC-T v0.3'),
  ('E1', 'Evidence', 1, 'E1', 'unfavorable', false, '4.3; 10.2.2', 'CERIC-T v0.3'),
  ('E2', 'Evidence', 2, 'E2', 'unfavorable', false, '4.3; 10.2.2', 'CERIC-T v0.3'),
  ('E3', 'Evidence', 3, 'E3', 'unfavorable', false, '4.1', 'CERIC-T v0.3'),
  ('E4', 'Evidence', 4, 'E4', 'unfavorable', false, '4.1; 10.3.3', 'CERIC-T v0.3'),
  ('E5', 'Evidence', 5, 'E5', 'unfavorable', false, NULL, 'CERIC-T v0.3'),
  ('E6', 'Evidence', 6, 'E6', 'unfavorable', false, '10.2; 10.2.2', 'CERIC-T v0.3'),
  ('E7', 'Evidence', 7, 'E7', 'neutral',     false, '10.2.2', 'CERIC-T v0.3'),
  ('E8', 'Evidence', 8, 'E8', 'unfavorable', false, '5.4.3; 5.2.3.2', 'CERIC-T v0.3'),
  ('E9', 'Evidence', 9, 'E9', 'unfavorable', true,  NULL, 'CERIC-T v0.3'),
  ('E10','Evidence', 10,'E10','unfavorable', true,  NULL, 'CERIC-T v0.3'),
  ('R1', 'Reasoning', 1, 'R1', 'unfavorable', false, '5.4.3', 'CERIC-T v0.3'),
  ('R2', 'Reasoning', 2, 'R2', 'unfavorable', false, '5.4.3; 10.2.3', 'CERIC-T v0.3'),
  ('R3', 'Reasoning', 3, 'R3', 'unfavorable', false, '5.4.3', 'CERIC-T v0.3'),
  ('R4', 'Reasoning', 4, 'R4', 'unfavorable', false, '5.4.3', 'CERIC-T v0.3'),
  ('R5', 'Reasoning', 5, 'R5', 'unfavorable', false, '5.4.3', 'CERIC-T v0.3'),
  ('R6', 'Reasoning', 6, 'R6', 'neutral',     true,  '5.4.3; 5.1.4', 'CERIC-T v0.3'),
  ('R7', 'Reasoning', 7, 'R7', 'unfavorable', false, '5.2.3.2; 10.2.3', 'CERIC-T v0.3'),
  ('R8', 'Reasoning', 8, 'R8', 'unfavorable', false, '5.1.2', 'CERIC-T v0.3'),
  ('I1', 'Implications', 1, 'I1', 'unfavorable', false, '6.1; 6.3.1', 'CERIC-T v0.3'),
  ('I2', 'Implications', 2, 'I2', 'unfavorable', false, '6.1.1', 'CERIC-T v0.3'),
  ('I3', 'Implications', 3, 'I3', 'unfavorable', false, '6.2.4; 10.2.4', 'CERIC-T v0.3'),
  ('I4', 'Implications', 4, 'I4', 'unfavorable', false, '10.2.4', 'CERIC-T v0.3'),
  ('I5', 'Implications', 5, 'I5', 'unfavorable', false, '6.2.4', 'CERIC-T v0.3'),
  ('I6', 'Implications', 6, 'I6', 'neutral',     true,  '10.2.4', 'CERIC-T v0.3'),
  ('I7', 'Implications', 7, 'I7', 'unfavorable', false, '10.2.4; 10.3.2', 'CERIC-T v0.3'),
  ('I8', 'Implications', 8, 'I8', 'neutral',     true,  '10.2.4', 'CERIC-T v0.3'),
  ('I9', 'Implications', 9, 'I9', 'unfavorable', false, '6.2.4', 'CERIC-T v0.3'),
  ('Co1','Context', 1, 'Co1', 'unfavorable', false, '7.1; 7.3', 'CERIC-T v0.3'),
  ('Co2','Context', 2, 'Co2', 'unfavorable', true,  '7.2.4; 10.2.5', 'CERIC-T v0.3'),
  ('Co3','Context', 3, 'Co3', 'neutral',     true,  '10.2.5', 'CERIC-T v0.3'),
  ('Co4','Context', 4, 'Co4', 'neutral',     false, '10.2.5', 'CERIC-T v0.3'),
  ('Co5','Context', 5, 'Co5', 'unfavorable', false, '10.2.5', 'CERIC-T v0.3'),
  ('Co6','Context', 6, 'Co6', 'unfavorable', false, '10.2.5', 'CERIC-T v0.3'),
  ('Co7','Context', 7, 'Co7', 'neutral',     true,  NULL, 'CERIC-T v0.3'),
  ('Co8','Context', 8, 'Co8', 'unfavorable', false, '7.1', 'CERIC-T v0.3');

UPDATE admin.settings SET value = 'CERIC-T v0.3', updated_at = now() WHERE key = 'protocol_version';
INSERT INTO admin.settings (key, value, note) VALUES
  ('cer_summary_wording CERIC-T v0.3', 'S1', 'Wording of the CER summary question; loaded from the private wording file');

-- ======================================================================
-- 2. New human-only fields: CER summary, Evidence tier; publication status
-- ======================================================================
CREATE TYPE tracker.evidence_tier AS ENUM
  ('Strong', 'Moderate', 'Promising', 'Demonstrates a Rationale', 'No Rationale Demonstrated');

ALTER TABLE tracker.codings
  ADD COLUMN cer_summary tracker.answer_code CHECK (cer_summary IN ('Y','PY','PN','N')),
  ADD COLUMN cer_summary_reason text,
  ADD COLUMN evidence_tier tracker.evidence_tier;
COMMENT ON COLUMN tracker.codings.cer_summary IS 'S1: given the Evidence and Reasoning evaluations, is the main Claim supported as stated? PN or N makes the verdict Not supported.';
COMMENT ON COLUMN tracker.codings.evidence_tier IS 'E11: adapted from the ESSA tiers. Reported beside the verdict; never an input to it.';
GRANT INSERT (cer_summary, cer_summary_reason, evidence_tier),
      UPDATE (cer_summary, cer_summary_reason, evidence_tier) ON tracker.codings TO hill_coder;

ALTER TABLE tracker.reconciled_claims
  ADD COLUMN cer_summary tracker.answer_code,
  ADD COLUMN evidence_tier tracker.evidence_tier;

ALTER TABLE tracker.studies
  ADD COLUMN publication_status text CHECK (publication_status IN ('peer-reviewed','preprint or working paper','predatory venue')),
  ADD COLUMN publication_basis text,
  ADD COLUMN publication_confirmed_by int REFERENCES admin.people,
  ADD CONSTRAINT predatory_needs_basis CHECK (publication_status IS DISTINCT FROM 'predatory venue' OR publication_basis IS NOT NULL);
COMMENT ON COLUMN tracker.studies.publication_status IS 'Reported beside the verdict. An agent may pre-fill; a coder or the lead confirms.';
GRANT INSERT (publication_status, publication_basis), UPDATE (publication_status, publication_basis) ON tracker.studies TO hill_agent;
GRANT UPDATE (publication_status, publication_basis, publication_confirmed_by) ON tracker.studies TO hill_coder;

-- ======================================================================
-- 3. Rules
-- ======================================================================
CREATE OR REPLACE FUNCTION tracker._unf_codes(p_coding int, p_element tracker.element,
                                              OUT unf text[], OUT answered int, OUT total int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce(array_agg(q.code) FILTER (WHERE a.answer IS NOT NULL AND tracker.is_unf(a.answer, q.ni_reading)), '{}'),
         count(a.answer)::int,
         count(*)::int
  FROM tracker.codings cd
  JOIN tracker.questions q ON q.protocol_version = cd.protocol_version
  LEFT JOIN tracker.answers a ON a.question_code = q.code AND a.coding_id = cd.coding_id
  WHERE cd.coding_id = p_coding AND q.element = p_element AND tracker.assert_visible(p_coding)
$$;

-- Proposed element evaluations. NULL until every question of the element is answered.
CREATE OR REPLACE FUNCTION tracker.proposed_evaluation(p_coding int, p_element tracker.element) RETURNS tracker.evaluation
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  u text[]; n_ans int; n_tot int; k int; c record; u2 text[]; causal boolean;
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO u, n_ans, n_tot FROM tracker._unf_codes(p_coding, p_element);
  IF n_ans < n_tot THEN RETURN NULL; END IF;
  SELECT * INTO c FROM tracker.codings WHERE coding_id = p_coding;
  k := cardinality(u);
  causal := tracker.evaluated_claim_type(p_coding) = 'Cause-effect';

  IF c.protocol_version = 'CERIC-T v0.2' THEN
    -- protocol v0.2 algorithms, unchanged
    IF p_element = 'Claim' THEN
      IF 'C4' = ANY(u) OR k >= 3 OR ('C3' = ANY(u) AND c.mark_c3_opposite_direction) THEN RETURN 'Not supported'; END IF;
    ELSIF p_element = 'Evidence' THEN
      IF 'E1' = ANY(u) OR 'E6' = ANY(u) OR 'E8' = ANY(u) OR k >= 3 THEN RETURN 'Not supported'; END IF;
    ELSIF p_element = 'Reasoning' THEN
      IF ('R3' = ANY(u) AND causal) OR 'R6' = ANY(u) OR ('R7' = ANY(u) AND c.mark_r7_fallacy_carries_claim) OR k >= 3 THEN
        RETURN 'Not supported'; END IF;
    ELSIF p_element = 'Implications' THEN
      u2 := array_remove(u, 'I1');
      IF ('I6' = ANY(u) AND (u && ARRAY['I3','I4','I5'])) OR ('I7' = ANY(u) AND c.mark_i7_no_limitations)
         OR cardinality(u2) >= 3 THEN RETURN 'Not supported'; END IF;
      IF cardinality(u2) >= 1 OR 'I1' = ANY(u) THEN RETURN 'Some concerns'; END IF;
      RETURN 'Supported';
    ELSIF p_element = 'Context' THEN
      IF 'X1' = ANY(u) OR 'X3' = ANY(u) OR k >= 3 THEN RETURN 'Not supported'; END IF;
    END IF;
    IF k >= 1 THEN RETURN 'Some concerns'; END IF;
    RETURN 'Supported';
  END IF;

  -- protocol v0.3: the half rule (4 of 7, 5 of 10, 4 of 8, 4 of I2-I9, 4 of 8) plus named triggers
  IF p_element = 'Claim' THEN
    IF 'C4' = ANY(u) OR k >= 4 OR ('C3' = ANY(u) AND c.mark_c3_opposite_direction) THEN RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Evidence' THEN
    -- E7 reads NI as neutral, so it is unfavorable only when answered N or PN.
    IF u && ARRAY['E1','E2','E7','E9'] OR (causal AND u && ARRAY['E6','E10']) OR k >= 5 THEN RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Reasoning' THEN
    IF ('R3' = ANY(u) AND causal) OR 'R6' = ANY(u) OR ('R7' = ANY(u) AND c.mark_r7_fallacy_carries_claim) OR k >= 4 THEN
      RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Implications' THEN
    u2 := array_remove(u, 'I1');           -- counts run over I2-I9
    IF ('I6' = ANY(u) AND (u && ARRAY['I3','I4','I5','I9'])) OR ('I7' = ANY(u) AND c.mark_i7_no_limitations)
       OR cardinality(u2) >= 4 THEN RETURN 'Not supported'; END IF;
    IF cardinality(u2) >= 1 OR 'I1' = ANY(u) THEN RETURN 'Some concerns'; END IF;
    RETURN 'Supported';
  ELSIF p_element = 'Context' THEN
    IF u && ARRAY['Co1','Co3'] OR k >= 4 THEN RETURN 'Not supported'; END IF;
  END IF;
  IF k >= 1 THEN RETURN 'Some concerns'; END IF;
  RETURN 'Supported';
END $$;

-- Decision rules v0.3: the CER summary answer comes first.
CREATE FUNCTION tracker.derive_verdict(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                       i tracker.evaluation, x tracker.evaluation) RETURNS tracker.verdict
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN s1 IS NULL OR c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN s1 IN ('PN','N') THEN 'Not supported'                                   -- rule 1
    WHEN e = 'Not supported' OR r = 'Not supported' THEN 'Not supported'         -- rule 2
    WHEN c = 'Not supported' OR i = 'Not supported' THEN 'Overstated'            -- rule 3
    WHEN x = 'Not supported' THEN 'Partially supported'                          -- rule 4 (flag context)
    WHEN 'Some concerns' IN (c, e, r, i, x) THEN 'Partially supported'           -- rule 5
    ELSE 'Supported'                                                             -- rule 6
  END::tracker.verdict
$$;

CREATE FUNCTION tracker.derive_severity(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                        i tracker.evaluation, x tracker.evaluation) RETURNS tracker.severity
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN s1 IS NULL OR c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN s1 IN ('PN','N') OR 'Not supported' IN (c, e, r) THEN 'Major concerns'
    WHEN c = 'Supported' AND e = 'Supported' AND r = 'Supported' AND i = 'Supported' AND x = 'Supported' THEN 'No concerns'
    ELSE 'Minor concerns'
  END::tracker.severity
$$;

CREATE FUNCTION tracker.derive_context_flag(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                            i tracker.evaluation, x tracker.evaluation) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT tracker.derive_verdict(s1, c, e, r, i, x) = 'Partially supported' AND x = 'Not supported'
$$;

-- Proposed Overstated type. v0.3 adds C7 (Misleading reporting) and I9 (Inappropriate extrapolation).
CREATE OR REPLACE FUNCTION tracker.derive_type(p_coding int, v tracker.verdict, c tracker.evaluation, i tracker.evaluation)
RETURNS tracker.overstated_type
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE uc text[]; ui text[];
BEGIN
  IF v IS DISTINCT FROM 'Overstated' THEN RETURN NULL; END IF;
  SELECT unf INTO uc FROM tracker._unf_codes(p_coding, 'Claim');
  SELECT unf INTO ui FROM tracker._unf_codes(p_coding, 'Implications');
  IF c = 'Not supported' THEN
    IF uc && ARRAY['C4','C5'] THEN RETURN 'Misleading interpretation'; END IF;
    IF uc && ARRAY['C3','C6','C7'] THEN RETURN 'Misleading reporting'; END IF;
    RETURN NULL;
  END IF;
  IF i = 'Not supported' AND ui && ARRAY['I3','I4','I5','I6','I9'] THEN RETURN 'Inappropriate extrapolation'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION tracker.coding_result(p_coding int,
  OUT proposed_verdict tracker.verdict, OUT proposed_severity tracker.severity,
  OUT context_flag boolean, OUT proposed_type tracker.overstated_type,
  OUT needs_supportable_claim boolean, OUT attention text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation;
  cd record; s record; uc text[]; n_ans int; n_q int; msg text := ''; v3 boolean; has_reason boolean;
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO cd FROM tracker.codings WHERE coding_id = p_coding;
  v3 := cd.protocol_version <> 'CERIC-T v0.2';
  SELECT effective INTO c FROM tracker.coding_summary(p_coding) WHERE element = 'Claim';
  SELECT effective INTO e FROM tracker.coding_summary(p_coding) WHERE element = 'Evidence';
  SELECT effective INTO r FROM tracker.coding_summary(p_coding) WHERE element = 'Reasoning';
  SELECT effective INTO i FROM tracker.coding_summary(p_coding) WHERE element = 'Implications';
  SELECT effective INTO x FROM tracker.coding_summary(p_coding) WHERE element = 'Context';
  IF v3 THEN
    proposed_verdict  := tracker.derive_verdict(cd.cer_summary, c, e, r, i, x);
    proposed_severity := tracker.derive_severity(cd.cer_summary, c, e, r, i, x);
    context_flag      := tracker.derive_context_flag(cd.cer_summary, c, e, r, i, x);
  ELSE
    proposed_verdict  := tracker.derive_verdict(c, e, r, i, x);
    proposed_severity := tracker.derive_severity(c, e, r, i, x);
    context_flag      := tracker.derive_context_flag(c, e, r, i, x);
  END IF;
  proposed_type     := tracker.derive_type(p_coding, coalesce(cd.final_verdict, proposed_verdict), c, i);
  SELECT unf INTO uc FROM tracker._unf_codes(p_coding, 'Claim');
  needs_supportable_claim := uc && ARRAY['C4','C5'];

  SELECT count(*) INTO n_ans FROM tracker.answers WHERE coding_id = p_coding;
  SELECT count(*) INTO n_q FROM tracker.questions WHERE protocol_version = cd.protocol_version;
  IF n_ans < n_q THEN msg := msg || format('%s of %s questions answered; ', n_ans, n_q); END IF;
  FOR s IN SELECT * FROM tracker.coding_summary(p_coding) LOOP
    IF s.final IS NULL THEN msg := msg || s.element || ' evaluation missing; '; END IF;
    IF NOT s.has_rationale THEN msg := msg || s.element || ' rationale missing; '; END IF;
    IF s.needs_override_note THEN msg := msg || s.element || ' differs from Proposed without a note; '; END IF;
  END LOOP;
  IF needs_supportable_claim AND cd.supportable_claim IS NULL THEN msg := msg || 'supportable claim missing; '; END IF;
  IF v3 THEN
    has_reason := coalesce(length(trim(cd.cer_summary_reason)), 0) > 0;
    IF cd.cer_summary IS NULL THEN
      msg := msg || 'CER summary not answered; ';
    ELSE
      IF cd.cer_summary IN ('PN','N') AND NOT has_reason THEN
        msg := msg || 'CER summary answered Probably no or No without a reason; ';
      END IF;
      IF cd.cer_summary IN ('Y','PY') AND 'Not supported' IN (e, r) THEN
        msg := msg || 'CER summary cannot be Yes or Probably yes when Evidence or Reasoning is Not supported; ';
      END IF;
      IF cd.cer_summary IN ('Y','PY') AND needs_supportable_claim AND NOT has_reason THEN
        msg := msg || 'CER summary is Yes or Probably yes although a supportable claim was written: add a note; ';
      END IF;
    END IF;
    IF cd.evidence_tier IS NULL THEN msg := msg || 'Evidence tier not chosen; '; END IF;
  END IF;
  IF coalesce(cd.final_verdict, proposed_verdict) = 'Overstated' AND cd.overstated_type IS NULL THEN
    msg := msg || 'Overstated type missing; ';
  END IF;
  IF cd.overstated_type IS NOT NULL AND cd.overstated_type IS DISTINCT FROM proposed_type
     AND coalesce(length(trim(cd.type_reason)), 0) = 0 THEN
    msg := msg || 'Overstated type differs from Proposed (or none proposed) without a reason; ';
  END IF;
  IF (cd.final_verdict IS NOT NULL AND cd.final_verdict IS DISTINCT FROM proposed_verdict
      OR cd.final_severity IS NOT NULL AND cd.final_severity IS DISTINCT FROM proposed_severity)
     AND coalesce(length(trim(cd.override_note)), 0) = 0 THEN
    msg := msg || 'verdict or severity override without a note; ';
  END IF;
  attention := nullif(msg, '');
END $$;

-- "Not applicable" only where the coding's protocol version allows it.
CREATE OR REPLACE FUNCTION tracker.guard_coding_child() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE cid int := CASE WHEN TG_OP = 'DELETE' THEN OLD.coding_id ELSE NEW.coding_id END;
        st text; pv text;
BEGIN
  SELECT status, protocol_version INTO st, pv FROM tracker.codings WHERE coding_id = cid;
  IF st = 'submitted' THEN
    RAISE EXCEPTION 'Coding % is submitted and locked; changes go through reconciliation', cid
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP <> 'DELETE' AND TG_OP = 'UPDATE' AND NEW.coding_id <> OLD.coding_id THEN
    RAISE EXCEPTION 'An answer cannot be moved to another coding';
  END IF;
  IF TG_TABLE_NAME = 'answers' AND TG_OP <> 'DELETE' THEN
    IF to_jsonb(NEW) ->> 'answer' = 'NA'
       AND NOT (SELECT na_allowed FROM tracker.questions
                WHERE protocol_version = pv AND code = to_jsonb(NEW) ->> 'question_code') THEN
      RAISE EXCEPTION 'NA is not allowed on %', to_jsonb(NEW) ->> 'question_code' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

-- ======================================================================
-- 4. Reconciliation of the CER summary and the Evidence tier
-- ======================================================================
CREATE TABLE tracker.reconciliation_items (
  claim_id    text NOT NULL REFERENCES tracker.claims,
  item        text NOT NULL CHECK (item IN ('CER summary','Evidence tier')),
  coding_a    int NOT NULL REFERENCES tracker.codings,
  coding_b    int NOT NULL REFERENCES tracker.codings,
  value_a     text NOT NULL,
  value_b     text NOT NULL,
  proposed_value text,
  proposed_by int REFERENCES admin.people,
  signoff_a   boolean NOT NULL DEFAULT false,
  signoff_b   boolean NOT NULL DEFAULT false,
  agreed_value text,
  reason      text,
  resolution  text CHECK (resolution IN ('agreed','decided')),
  decided_by  int REFERENCES admin.people,
  resolved_at timestamptz,
  PRIMARY KEY (claim_id, item),
  CHECK (resolution IS NULL OR (agreed_value IS NOT NULL AND reason IS NOT NULL))
);
COMMENT ON TABLE tracker.reconciliation_items IS 'Disagreements between two coders on the CER summary (favorable versus unfavorable) or the Evidence tier. Settled like an element.';
CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON tracker.reconciliation_items
  FOR EACH ROW EXECUTE FUNCTION admin.log_change();
REVOKE ALL ON tracker.reconciliation_items FROM PUBLIC;
GRANT SELECT ON tracker.reconciliation_items TO hill_lead, hill_coder, hill_tiebreak, hill_agent;

CREATE FUNCTION tracker.valid_item_value(p_item text, p_value text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_item
    WHEN 'CER summary' THEN p_value IN ('Y','PY','PN','N')
    WHEN 'Evidence tier' THEN p_value = ANY (enum_range(NULL::tracker.evidence_tier)::text[])
    ELSE false END
$$;

CREATE OR REPLACE FUNCTION tracker.open_reconciliation(p_claim text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE a record; b record; n int := 0; el tracker.element; ea tracker.evaluation; eb tracker.evaluation;
BEGIN
  IF admin.my_login_role() NOT IN ('lead','coder','agent','admin') THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF admin.my_login_role() = 'coder' AND NOT tracker.is_coder_of(p_claim, admin.me()) THEN
    RAISE EXCEPTION 'Only coders of this claim can open its reconciliation';
  END IF;
  SELECT * INTO a FROM tracker.codings WHERE claim_id = p_claim AND status = 'submitted' ORDER BY coder_id LIMIT 1;
  SELECT * INTO b FROM tracker.codings WHERE claim_id = p_claim AND status = 'submitted' ORDER BY coder_id OFFSET 1 LIMIT 1;
  IF b.coding_id IS NULL OR (SELECT count(*) FROM tracker.codings WHERE claim_id = p_claim) <> 2 THEN
    RAISE EXCEPTION 'Both codings of % must be submitted first', p_claim;
  END IF;
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    SELECT final_evaluation INTO ea FROM tracker.element_evaluations WHERE coding_id = a.coding_id AND element = el;
    SELECT final_evaluation INTO eb FROM tracker.element_evaluations WHERE coding_id = b.coding_id AND element = el;
    IF ea IS DISTINCT FROM eb THEN
      INSERT INTO tracker.reconciliations (claim_id, element, coding_a, coding_b, evaluation_a, evaluation_b)
      VALUES (p_claim, el, a.coding_id, b.coding_id, ea, eb) ON CONFLICT DO NOTHING;
      n := n + 1;
    END IF;
  END LOOP;
  -- CER summary: a disagreement only when one coder is favorable (Y, PY) and the other is not (PN, N).
  IF a.cer_summary IS NOT NULL AND b.cer_summary IS NOT NULL
     AND (a.cer_summary IN ('Y','PY')) <> (b.cer_summary IN ('Y','PY')) THEN
    INSERT INTO tracker.reconciliation_items (claim_id, item, coding_a, coding_b, value_a, value_b)
    VALUES (p_claim, 'CER summary', a.coding_id, b.coding_id, a.cer_summary::text, b.cer_summary::text) ON CONFLICT DO NOTHING;
    n := n + 1;
  END IF;
  IF a.evidence_tier IS NOT NULL AND b.evidence_tier IS NOT NULL AND a.evidence_tier <> b.evidence_tier THEN
    INSERT INTO tracker.reconciliation_items (claim_id, item, coding_a, coding_b, value_a, value_b)
    VALUES (p_claim, 'Evidence tier', a.coding_id, b.coding_id, a.evidence_tier::text, b.evidence_tier::text) ON CONFLICT DO NOTHING;
    n := n + 1;
  END IF;
  RETURN n;
END $$;

CREATE FUNCTION tracker.agree_item(p_claim text, p_item text, p_value text, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rc record; side text; m int := admin.me();
BEGIN
  IF admin.my_login_role() <> 'coder' THEN RAISE EXCEPTION 'Coder sign-ins only' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT * INTO rc FROM tracker.reconciliation_items WHERE claim_id = p_claim AND item = p_item FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No open reconciliation for % %', p_claim, p_item; END IF;
  IF rc.resolution IS NOT NULL THEN RAISE EXCEPTION 'Already resolved'; END IF;
  IF m = (SELECT coder_id FROM tracker.codings WHERE coding_id = rc.coding_a) THEN side := 'a';
  ELSIF m = (SELECT coder_id FROM tracker.codings WHERE coding_id = rc.coding_b) THEN side := 'b';
  ELSE RAISE EXCEPTION 'Only the two coders of % can agree a reconciliation', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT tracker.valid_item_value(p_item, p_value) THEN RAISE EXCEPTION '% is not a valid value for %', p_value, p_item; END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF rc.proposed_value IS DISTINCT FROM p_value THEN
    UPDATE tracker.reconciliation_items
       SET proposed_value = p_value, reason = p_reason, proposed_by = m, signoff_a = (side = 'a'), signoff_b = (side = 'b')
     WHERE claim_id = p_claim AND item = p_item;
    RETURN 'proposed; waiting for the other coder';
  END IF;
  UPDATE tracker.reconciliation_items
     SET signoff_a = signoff_a OR side = 'a', signoff_b = signoff_b OR side = 'b'
   WHERE claim_id = p_claim AND item = p_item;
  UPDATE tracker.reconciliation_items
     SET agreed_value = proposed_value, resolution = 'agreed', resolved_at = now()
   WHERE claim_id = p_claim AND item = p_item AND signoff_a AND signoff_b;
  RETURN CASE WHEN FOUND THEN 'agreed' ELSE 'signed off; waiting for the other coder' END;
END $$;

CREATE FUNCTION tracker.decide_item(p_claim text, p_item text, p_value text, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE m int := admin.me(); rl text := admin.my_login_role();
BEGIN
  IF rl NOT IN ('lead','tiebreak') THEN RAISE EXCEPTION 'Only the lead or an assigned tie-breaker decides' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF tracker.is_coder_of(p_claim, m) THEN
    RAISE EXCEPTION 'You coded % and cannot decide its reconciliation; assign a tie-breaker', p_claim
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF rl = 'tiebreak' AND NOT EXISTS (SELECT 1 FROM tracker.tiebreak_assignments WHERE claim_id = p_claim AND person_id = m) THEN
    RAISE EXCEPTION 'You are not assigned as tie-breaker for %', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT tracker.valid_item_value(p_item, p_value) THEN RAISE EXCEPTION '% is not a valid value for %', p_value, p_item; END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  UPDATE tracker.reconciliation_items
     SET agreed_value = p_value, reason = p_reason, resolution = 'decided', decided_by = m, resolved_at = now()
   WHERE claim_id = p_claim AND item = p_item AND resolution IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'No open reconciliation for % %', p_claim, p_item; END IF;
END $$;

-- Final result of a claim. Under v0.3 the agreed CER summary decides rule 1, and the agreed tier is recorded.
CREATE OR REPLACE FUNCTION tracker.finalize_claim(p_claim text, p_type tracker.overstated_type DEFAULT NULL,
                                                  p_supportable text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS tracker.verdict
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE
  rl text := admin.my_login_role(); n_sub int; n_all int; el tracker.element; ev tracker.evaluation;
  ev_all tracker.evaluation[] := '{}'; v tracker.verdict; sv tracker.severity; t tracker.overstated_type; sc text;
  pv text; v3 boolean; s1 tracker.answer_code; tier tracker.evidence_tier; cf boolean; txt text;
BEGIN
  IF rl NOT IN ('lead','coder') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF rl = 'coder' AND NOT tracker.is_coder_of(p_claim, admin.me()) THEN RAISE EXCEPTION 'Not a coder of %', p_claim; END IF;
  SELECT count(*) FILTER (WHERE status = 'submitted'), count(*) INTO n_sub, n_all FROM tracker.codings WHERE claim_id = p_claim;
  IF n_sub = 0 OR n_sub <> n_all THEN RAISE EXCEPTION 'All codings of % must be submitted', p_claim; END IF;
  IF n_sub = 1 AND EXISTS (SELECT 1 FROM tracker.double_samples WHERE claim_id = p_claim AND selected) THEN
    RAISE EXCEPTION '% was drawn for double-coding; it needs a second coding', p_claim;
  END IF;
  pv := (SELECT protocol_version FROM tracker.codings WHERE claim_id = p_claim LIMIT 1);
  v3 := pv <> 'CERIC-T v0.2';
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    SELECT CASE WHEN count(DISTINCT ee.final_evaluation) = 1 THEN min(ee.final_evaluation)
                ELSE (SELECT agreed_evaluation FROM tracker.reconciliations r WHERE r.claim_id = p_claim AND r.element = el) END
      INTO ev
      FROM tracker.codings c JOIN tracker.element_evaluations ee ON ee.coding_id = c.coding_id AND ee.element = el
     WHERE c.claim_id = p_claim;
    IF ev IS NULL THEN RAISE EXCEPTION '% on % is not reconciled yet', el, p_claim; END IF;
    ev_all := ev_all || ev;
  END LOOP;
  IF v3 THEN
    -- CER summary: the coders' answers when both are favorable or both unfavorable (the less certain one is kept),
    -- otherwise the reconciled answer.
    IF (SELECT count(DISTINCT (cer_summary IN ('Y','PY'))) FROM tracker.codings WHERE claim_id = p_claim) = 1 THEN
      SELECT CASE WHEN bool_and(cer_summary IN ('Y','PY'))
                  THEN CASE WHEN bool_or(cer_summary = 'PY') THEN 'PY' ELSE 'Y' END
                  ELSE CASE WHEN bool_or(cer_summary = 'PN') THEN 'PN' ELSE 'N' END END::tracker.answer_code
        INTO s1 FROM tracker.codings WHERE claim_id = p_claim;
    ELSE
      SELECT agreed_value INTO txt FROM tracker.reconciliation_items WHERE claim_id = p_claim AND item = 'CER summary';
      s1 := txt::tracker.answer_code;
    END IF;
    IF s1 IS NULL THEN RAISE EXCEPTION 'CER summary on % is not reconciled yet', p_claim; END IF;
    IF (SELECT count(DISTINCT evidence_tier) FROM tracker.codings WHERE claim_id = p_claim) = 1 THEN
      SELECT min(evidence_tier) INTO tier FROM tracker.codings WHERE claim_id = p_claim;
    ELSE
      SELECT agreed_value INTO txt FROM tracker.reconciliation_items WHERE claim_id = p_claim AND item = 'Evidence tier';
      tier := txt::tracker.evidence_tier;
    END IF;
    IF tier IS NULL THEN RAISE EXCEPTION 'Evidence tier on % is not reconciled yet', p_claim; END IF;
    v  := tracker.derive_verdict(s1, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    sv := tracker.derive_severity(s1, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    cf := tracker.derive_context_flag(s1, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
  ELSE
    v  := tracker.derive_verdict(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    sv := tracker.derive_severity(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    cf := tracker.derive_context_flag(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
  END IF;
  t := p_type;
  IF v = 'Overstated' AND t IS NULL THEN
    SELECT CASE WHEN count(DISTINCT overstated_type) = 1 AND count(overstated_type) = count(*) THEN min(overstated_type) END
      INTO t FROM tracker.codings WHERE claim_id = p_claim;
    IF t IS NULL THEN RAISE EXCEPTION 'Overstated: the coders chose different types; give the agreed type'; END IF;
  END IF;
  IF v <> 'Overstated' THEN t := NULL; END IF;
  sc := p_supportable;
  IF sc IS NULL THEN
    SELECT CASE WHEN count(DISTINCT supportable_claim) = 1 THEN min(supportable_claim) END INTO sc
      FROM tracker.codings WHERE claim_id = p_claim AND supportable_claim IS NOT NULL;
  END IF;
  INSERT INTO tracker.reconciled_claims (claim_id, claim_eval, evidence_eval, reasoning_eval, implications_eval, context_eval,
                                         verdict, severity, context_flag, overstated_type, supportable_claim, note,
                                         protocol_version, finalized_by, cer_summary, evidence_tier)
  VALUES (p_claim, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5], v, sv, cf,
          t, sc, p_note, pv, admin.me(), s1, tier);
  RETURN v;
END $$;

-- Agreement between two independent coders on the two new items (percent agreement only).
CREATE FUNCTION tracker.reliability_items(p_protocol text)
RETURNS TABLE (item text, n_claims int, percent_agreement numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  WITH pairs AS (
    SELECT claim_id,
           count(DISTINCT (cer_summary IN ('Y','PY'))) = 1 AS s1_same,
           count(DISTINCT evidence_tier) = 1 AS tier_same
    FROM tracker.codings
    WHERE status = 'submitted' AND protocol_version = p_protocol
    GROUP BY claim_id HAVING count(*) = 2
  )
  SELECT 'CER summary', count(*)::int, round(100.0 * avg(s1_same::int), 1) FROM pairs
  UNION ALL
  SELECT 'Evidence tier', count(*)::int, round(100.0 * avg(tier_same::int), 1) FROM pairs
$$;

-- ======================================================================
-- 5. Views
-- ======================================================================
CREATE OR REPLACE VIEW tracker.question_splits WITH (security_invoker = true) AS
WITH r AS (
  SELECT c.claim_id, c.protocol_version, a.question_code,
         CASE WHEN a.answer IN ('Y','PY') THEN 'favorable'
              WHEN tracker.is_unf(a.answer, q.ni_reading) THEN 'unfavorable' ELSE 'neutral' END AS reading
  FROM tracker.codings c
  JOIN tracker.answers a ON a.coding_id = c.coding_id
  JOIN tracker.questions q ON q.code = a.question_code AND q.protocol_version = c.protocol_version
  WHERE c.status = 'submitted'
)
SELECT protocol_version, question_code, count(*) AS claims_split, count(*) >= 3 AS flag_for_rewording
FROM (SELECT claim_id, protocol_version, question_code FROM r
      GROUP BY 1, 2, 3 HAVING count(*) = 2 AND count(DISTINCT reading) = 2) s
GROUP BY 1, 2;

CREATE OR REPLACE VIEW tracker.public_census AS
SELECT s.study_id, s.citation, s.doi, s.year, s.strand, s.status, s.wwc_rating, s.wwc_source,
       CASE WHEN s.publication_confirmed_by IS NOT NULL THEN s.publication_status END AS publication_status
FROM tracker.studies s JOIN tracker.released_studies USING (study_id)
WHERE s.status <> 'holding';

CREATE OR REPLACE VIEW tracker.public_verdicts AS
SELECT rc.claim_id, cl.study_id, cl.main_claim, rc.verdict, rc.severity, rc.context_flag, rc.overstated_type,
       rc.supportable_claim, rc.claim_eval, rc.evidence_eval, rc.reasoning_eval, rc.implications_eval, rc.context_eval,
       rc.protocol_version, rc.cer_summary, rc.evidence_tier
FROM tracker.reconciled_claims rc
JOIN tracker.claims cl USING (claim_id)
JOIN tracker.released_studies USING (study_id)
WHERE admin.setting('verdicts_public') = 'on';

-- ======================================================================
-- 6. Permissions on the new functions
-- ======================================================================
REVOKE ALL ON FUNCTION tracker.set_answer_version(), tracker.valid_item_value(text, text),
  tracker.derive_verdict(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_severity(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_context_flag(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.agree_item(text, text, text, text), tracker.decide_item(text, text, text, text), tracker.reliability_items(text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.valid_item_value(text, text),
  tracker.derive_verdict(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_severity(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_context_flag(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation)
  TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.agree_item(text, text, text, text) TO hill_coder;
GRANT EXECUTE ON FUNCTION tracker.decide_item(text, text, text, text) TO hill_lead, hill_tiebreak;
GRANT EXECUTE ON FUNCTION tracker.reliability_items(text) TO hill_lead, hill_agent;

COMMIT;
