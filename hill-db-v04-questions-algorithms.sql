-- CERIC-T v0.4, part 2 of the build: the question set and the element algorithms.
-- Adds the v0.4 protocol version and its 41 questions (wording is loaded from a private file),
-- three columns on tracker.questions, three on codings and element evaluations, and a v0.4 branch
-- in tracker.proposed_evaluation. The v0.2 and v0.3 branches are unchanged, and v0.3 stays the
-- current protocol: this file does not switch admin.settings.protocol_version.
\set ON_ERROR_STOP on
ALTER TYPE tracker.claim_type ADD VALUE IF NOT EXISTS 'Difference';
BEGIN;
SET LOCAL ROLE hill_owner;

ALTER TABLE tracker.questions
  ADD COLUMN ni_allowed boolean NOT NULL DEFAULT true,
  ADD COLUMN favorable_when text,
  ADD COLUMN shown_if text CHECK (shown_if IN ('qualitative data'));
COMMENT ON COLUMN tracker.questions.ni_allowed IS 'False where No information is not offered (v0.4: I8).';
COMMENT ON COLUMN tracker.questions.favorable_when IS 'Anchor for the Probably yes / Probably no line. Private wording, loaded separately.';
COMMENT ON COLUMN tracker.questions.shown_if IS 'Shown only when the coder''s screener says the Claim also rests on qualitative data; otherwise recorded as NA.';

ALTER TABLE tracker.codings
  ADD COLUMN has_qualitative_data boolean,
  ADD COLUMN supplement_seen boolean;
COMMENT ON COLUMN tracker.codings.has_qualitative_data IS 'v0.4 screener, answered by each coder: does the Evidence for this Claim also include qualitative data?';
COMMENT ON COLUMN tracker.codings.supplement_seen IS 'v0.4: whether the coder had the supplement before answering E3 and E4.';

ALTER TABLE tracker.element_evaluations
  ADD COLUMN own_evaluation tracker.evaluation,
  ADD COLUMN not_supported_route text CHECK (not_supported_route IN ('trigger','half rule','both'));
COMMENT ON COLUMN tracker.element_evaluations.own_evaluation IS 'v0.4: the evaluation the coder would give, recorded before the algorithm''s result is shown. Used to test the half rule.';
COMMENT ON COLUMN tracker.element_evaluations.not_supported_route IS 'v0.4: what made the algorithm propose Not supported.';

INSERT INTO tracker.protocol_versions (version, instrument, released_on, notes) VALUES
  ('CERIC-T v0.4', 'CERIC-T', '2026-11-11', 'Draft for calibration round two. evidence-tracker/ceric-t-protocol-v0.4-draft.md');

INSERT INTO tracker.questions (code, element, position, wording, ni_reading, na_allowed, ni_allowed, shown_if, book_section, protocol_version) VALUES
  ('C1', 'Claim', 1, 'C1', 'unfavorable', false, true, NULL, '3.1', 'CERIC-T v0.4'),
  ('C4', 'Claim', 2, 'C4', 'unfavorable', false, true, NULL, '3.2; 5.1.4', 'CERIC-T v0.4'),
  ('C5', 'Claim', 3, 'C5', 'unfavorable', false, true, NULL, '4.3; 10.2.2', 'CERIC-T v0.4'),
  ('C6', 'Claim', 4, 'C6', 'unfavorable', false, true, NULL, '10.2.1', 'CERIC-T v0.4'),
  ('C7', 'Claim', 5, 'C7', 'unfavorable', false, true, NULL, '3.4', 'CERIC-T v0.4'),
  ('E1', 'Evidence', 1, 'E1', 'unfavorable', false, true, NULL, '4.3; 10.2.2', 'CERIC-T v0.4'),
  ('E2', 'Evidence', 2, 'E2', 'unfavorable', false, true, NULL, '4.3; 10.2.2', 'CERIC-T v0.4'),
  ('E3', 'Evidence', 3, 'E3', 'unfavorable', false, true, NULL, '4.1', 'CERIC-T v0.4'),
  ('E4', 'Evidence', 4, 'E4', 'unfavorable', false, true, NULL, '4.1; 10.3.3', 'CERIC-T v0.4'),
  ('E5', 'Evidence', 5, 'E5', 'unfavorable', false, true, NULL, NULL, 'CERIC-T v0.4'),
  ('E6', 'Evidence', 6, 'E6', 'unfavorable', false, true, NULL, '10.2; 10.2.2', 'CERIC-T v0.4'),
  ('E7', 'Evidence', 7, 'E7', 'neutral',     false, true, NULL, '10.2.2', 'CERIC-T v0.4'),
  ('E8a','Evidence', 8, 'E8a','unfavorable', true,  true, NULL, '5.4.3; 5.2.3.2', 'CERIC-T v0.4'),
  ('E8b','Evidence', 9, 'E8b','unfavorable', true,  true, NULL, '5.4.3; 5.2.3.2', 'CERIC-T v0.4'),
  ('E8c','Evidence', 10,'E8c','unfavorable', true,  true, 'qualitative data', NULL, 'CERIC-T v0.4'),
  ('E9', 'Evidence', 11,'E9', 'unfavorable', true,  true, NULL, NULL, 'CERIC-T v0.4'),
  ('E10','Evidence', 12,'E10','unfavorable', true,  true, NULL, NULL, 'CERIC-T v0.4'),
  ('R1', 'Reasoning', 1, 'R1', 'unfavorable', true,  true, NULL, '5.4.3', 'CERIC-T v0.4'),
  ('R1b','Reasoning', 2, 'R1b','unfavorable', true,  true, 'qualitative data', NULL, 'CERIC-T v0.4'),
  ('R2', 'Reasoning', 3, 'R2', 'unfavorable', false, true, NULL, '5.4.3; 10.2.3', 'CERIC-T v0.4'),
  ('R3', 'Reasoning', 4, 'R3', 'unfavorable', false, true, NULL, '5.4.3', 'CERIC-T v0.4'),
  ('R4', 'Reasoning', 5, 'R4', 'unfavorable', false, true, NULL, '5.4.3', 'CERIC-T v0.4'),
  ('R6', 'Reasoning', 6, 'R6', 'neutral',     true,  true, NULL, '5.4.3; 5.1.4', 'CERIC-T v0.4'),
  ('R7', 'Reasoning', 7, 'R7', 'unfavorable', false, true, NULL, '5.2.3.2; 10.2.3', 'CERIC-T v0.4'),
  ('I1', 'Implications', 1, 'I1', 'unfavorable', false, true, NULL, '6.1; 6.3.1', 'CERIC-T v0.4'),
  ('I2', 'Implications', 2, 'I2', 'unfavorable', false, true, NULL, '6.1.1', 'CERIC-T v0.4'),
  ('I3', 'Implications', 3, 'I3', 'unfavorable', false, true, NULL, '6.2.4; 10.2.4', 'CERIC-T v0.4'),
  ('I4', 'Implications', 4, 'I4', 'unfavorable', false, true, NULL, '10.2.4', 'CERIC-T v0.4'),
  ('I5', 'Implications', 5, 'I5', 'unfavorable', false, true, NULL, '6.2.4', 'CERIC-T v0.4'),
  ('I6', 'Implications', 6, 'I6', 'neutral',     true,  true, NULL, '10.2.4', 'CERIC-T v0.4'),
  ('I7a','Implications', 7, 'I7a','unfavorable', false, true, NULL, '10.2.4; 10.3.2', 'CERIC-T v0.4'),
  ('I7b','Implications', 8, 'I7b','unfavorable', false, true, NULL, '10.2.4; 10.3.2', 'CERIC-T v0.4'),
  ('I8', 'Implications', 9, 'I8', 'neutral',     true,  false, NULL, '10.2.4', 'CERIC-T v0.4'),
  ('Co1','Context', 1, 'Co1', 'unfavorable', false, true, NULL, '7.1; 7.3', 'CERIC-T v0.4'),
  ('Co2','Context', 2, 'Co2', 'unfavorable', true,  true, NULL, '7.2.4; 10.2.5', 'CERIC-T v0.4'),
  ('Co3','Context', 3, 'Co3', 'neutral',     true,  true, NULL, '10.2.5', 'CERIC-T v0.4'),
  ('Co4','Context', 4, 'Co4', 'neutral',     false, true, NULL, '10.2.5', 'CERIC-T v0.4'),
  ('Co5','Context', 5, 'Co5', 'unfavorable', false, true, NULL, '10.2.5', 'CERIC-T v0.4'),
  ('Co6','Context', 6, 'Co6', 'unfavorable', false, true, NULL, '10.2.5', 'CERIC-T v0.4'),
  ('Co7','Context', 7, 'Co7', 'neutral',     true,  true, NULL, NULL, 'CERIC-T v0.4'),
  ('Co8','Context', 8, 'Co8', 'unfavorable', false, true, NULL, '7.1', 'CERIC-T v0.4');

INSERT INTO admin.settings (key, value, note) VALUES
  ('cer_summary_wording CERIC-T v0.4', 'S1', 'Wording of the CER summary question; loaded from the private wording file');

-- The v0.4 element rule as a pure function, so that it can be tested without any coding record.
--   u  = codes answered unfavorably (PN, N, or NI where NI reads unfavorable)
--   n  = codes answered with a plain No
--   ni = codes answered No information
-- Only a plain No on a trigger question makes an element Not supported alone; No information on E1 or E2
-- is the one exception. The half rule is provisional (Claim 3 of 5; Evidence 6 of 12; Reasoning 4 of 7;
-- Implications 4 of the 8 counted; Context 4 of 8).
CREATE FUNCTION tracker.v04_element_rule(p_element tracker.element, u text[], n text[], ni text[],
                                         causal boolean, mark_r7 boolean, mark_i7 boolean,
                                         OUT evaluation tracker.evaluation, OUT route text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE trig boolean := false; half boolean := false; k int := cardinality(u); u2 text[];
BEGIN
  IF p_element = 'Claim' THEN
    trig := 'C4' = ANY(u) AND u && ARRAY['C5','C6'];
    half := k >= 3;
  ELSIF p_element = 'Evidence' THEN
    trig := n && ARRAY['E1','E2','E7','E9'] OR ni && ARRAY['E1','E2'] OR (coalesce(causal, false) AND 'E6' = ANY(n));
    half := k >= 6;
  ELSIF p_element = 'Reasoning' THEN
    trig := 'R6' = ANY(n) OR ('R7' = ANY(n) AND coalesce(mark_r7, false));
    half := k >= 4;
  ELSIF p_element = 'Implications' THEN
    u2 := array_remove(u, 'I1');                       -- counts run over I2-I8
    trig := ('I6' = ANY(n) AND u && ARRAY['I3','I4','I5']) OR ('I7a' = ANY(n) AND coalesce(mark_i7, false));
    half := cardinality(u2) >= 4;
  ELSIF p_element = 'Context' THEN
    trig := n && ARRAY['Co1','Co3'];
    half := k >= 4;
  END IF;
  IF trig OR half THEN
    evaluation := 'Not supported';
    route := CASE WHEN trig AND half THEN 'both' WHEN trig THEN 'trigger' ELSE 'half rule' END;
  ELSIF k >= 1 THEN evaluation := 'Some concerns';
  ELSE evaluation := 'Supported';
  END IF;
END $$;

-- Codes of one element answered with a given answer.
CREATE FUNCTION tracker._codes_answered(p_coding int, p_element tracker.element, p_answer tracker.answer_code) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce(array_agg(a.question_code), '{}')
  FROM tracker.codings cd
  JOIN tracker.questions q ON q.protocol_version = cd.protocol_version AND q.element = p_element
  JOIN tracker.answers a ON a.question_code = q.code AND a.coding_id = cd.coding_id AND a.answer = p_answer
  WHERE cd.coding_id = p_coding AND tracker.assert_visible(p_coding)
$$;

-- v0.4 evaluates every element against the Claim as the authors state it, so the claim type is the Claim's own.
CREATE FUNCTION tracker._v04_rule(p_coding int, p_element tracker.element, OUT evaluation tracker.evaluation, OUT route text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE u text[]; n_ans int; n_tot int; c record; causal boolean;
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO u, n_ans, n_tot FROM tracker._unf_codes(p_coding, p_element);
  IF n_ans < n_tot THEN RETURN; END IF;
  SELECT cd.*, cl.claim_type INTO c FROM tracker.codings cd JOIN tracker.claims cl USING (claim_id) WHERE cd.coding_id = p_coding;
  causal := c.claim_type = 'Cause-effect';
  SELECT r.evaluation, r.route INTO evaluation, route
  FROM tracker.v04_element_rule(p_element, u, tracker._codes_answered(p_coding, p_element, 'N'),
                                tracker._codes_answered(p_coding, p_element, 'NI'),
                                causal, c.mark_r7_fallacy_carries_claim, c.mark_i7_no_limitations) r;
END $$;

CREATE FUNCTION tracker.proposed_route(p_coding int, p_element tracker.element) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT route FROM tracker._v04_rule(p_coding, p_element)
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

  IF c.protocol_version = 'CERIC-T v0.4' THEN
    RETURN (SELECT evaluation FROM tracker._v04_rule(p_coding, p_element));
  END IF;

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

REVOKE ALL ON FUNCTION tracker._codes_answered(int, tracker.element, tracker.answer_code), tracker._v04_rule(int, tracker.element) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.v04_element_rule(tracker.element, text[], text[], text[], boolean, boolean, boolean),
  tracker.proposed_route(int, tracker.element) TO hill_lead, hill_coder, hill_agent;
COMMIT;
