-- HiLL database: remove the qualitative-data lead-in question and the two questions it opened (E8c and R1b).
-- Applied on top of hill-db-supplemental-ratings.sql. Run once as a database administrator who is a member of hill_owner.
-- No question wording in this file.
--
-- Decided by Gene, 2026-11-13: Claim Check covers causal studies only, and a causal study does not rest its main
-- Claim on qualitative data. CERIC-T v0.4 therefore has 39 signalling questions, not 41:
-- Claim 5, Evidence 11, Reasoning 6, Implications 9, Context 8.
--
-- 1. Stops without changing anything if any coding has been started under v0.4, or any answer to E8c or R1b exists.
-- 2. Removes questions E8c and R1b from the v0.4 question set.
-- 3. The submit check no longer asks for the lead-in answer and no longer has rules for E8c and R1b.
-- 4. Coders can no longer write the lead-in answer. The column stays, empty, so that nothing recorded is lost.
-- 5. The Reasoning half rule becomes 3 unfavorable answers of its 6 counted questions (was 4 of 7). Gene, 2026-11-13.
--    The other elements are unchanged: Claim 3 of 5; Evidence 6 of 11; Implications 4 of the 8 counted; Context 4 of 8.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM tracker.codings WHERE protocol_version = 'CERIC-T v0.4') THEN
    RAISE EXCEPTION 'A coding has been started under CERIC-T v0.4; nothing was changed. The question set of a version in use is not changed.';
  END IF;
  IF EXISTS (SELECT 1 FROM tracker.answers WHERE question_code IN ('E8c','R1b')) THEN
    RAISE EXCEPTION 'Answers to E8c or R1b exist; nothing was changed.';
  END IF;
END $$;

DELETE FROM tracker.questions WHERE protocol_version = 'CERIC-T v0.4' AND code IN ('E8c','R1b');

DO $$
BEGIN
  IF (SELECT count(*) FROM tracker.questions WHERE protocol_version = 'CERIC-T v0.4') <> 39 THEN
    RAISE EXCEPTION 'Expected 39 questions under CERIC-T v0.4 after the removal; nothing was changed.';
  END IF;
END $$;

REVOKE INSERT (has_qualitative_data), UPDATE (has_qualitative_data) ON tracker.codings FROM hill_coder;
COMMENT ON COLUMN tracker.codings.has_qualitative_data IS 'No longer used (removed 2026-11-13). Was the v0.4 lead-in question on qualitative data.';
COMMENT ON COLUMN tracker.questions.shown_if IS 'No longer used (2026-11-13). Marked the two questions shown only for qualitative data.';

CREATE OR REPLACE FUNCTION tracker.coding_result_v04(p_coding int,
  OUT claim_rating tracker.claim_rating, OUT implications_rating tracker.implications_rating,
  OUT falls_short text, OUT needs_supportable_claim boolean, OUT attention text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation;
  cd record; s record; n_ans int; n_q int; msg text := ''; has_reason boolean; e_ni boolean; r_ni boolean;
  a_e8a tracker.answer_code; a_e8b tracker.answer_code; a_r1 tracker.answer_code;
  unf_e text[];
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO cd FROM tracker.codings WHERE coding_id = p_coding;
  IF cd.protocol_version <> 'CERIC-T v0.4' THEN
    RAISE EXCEPTION 'Coding % was recorded under %, not CERIC-T v0.4', p_coding, cd.protocol_version;
  END IF;
  SELECT effective INTO c FROM tracker.coding_summary(p_coding) WHERE element = 'Claim';
  SELECT effective INTO e FROM tracker.coding_summary(p_coding) WHERE element = 'Evidence';
  SELECT effective INTO r FROM tracker.coding_summary(p_coding) WHERE element = 'Reasoning';
  SELECT effective INTO i FROM tracker.coding_summary(p_coding) WHERE element = 'Implications';
  SELECT effective INTO x FROM tracker.coding_summary(p_coding) WHERE element = 'Context';
  e_ni := tracker._ni_only(cd.claim_id, p_coding, 'Evidence');
  r_ni := tracker._ni_only(cd.claim_id, p_coding, 'Reasoning');
  claim_rating := tracker.derive_claim_rating(cd.cer_summary, c, e, r, x, e_ni, r_ni);
  implications_rating := tracker.derive_implications_rating(claim_rating, i);
  falls_short := tracker.falls_short_v04(cd.cer_summary, c, e, r, x, e_ni, r_ni);
  needs_supportable_claim := claim_rating = 'Not supported';

  SELECT count(*) INTO n_ans FROM tracker.answers WHERE coding_id = p_coding;
  SELECT count(*) INTO n_q FROM tracker.questions WHERE protocol_version = cd.protocol_version;
  IF n_ans < n_q THEN msg := msg || format('%s of %s questions answered; ', n_ans, n_q); END IF;

  SELECT answer INTO a_e8a FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'E8a';
  SELECT answer INTO a_e8b FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'E8b';
  SELECT answer INTO a_r1  FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'R1';
  SELECT unf INTO unf_e FROM tracker._unf_codes(p_coding, 'Evidence');
  -- Counted once: unreported uncertainties are answered at E8a and E8b, and R1 is then Not applicable.
  IF unf_e @> ARRAY['E8a','E8b'] AND a_r1 IS DISTINCT FROM 'NA' THEN
    msg := msg || 'R1 must be Not applicable when E8a and E8b are both unfavorable; ';
  ELSIF NOT (unf_e @> ARRAY['E8a','E8b']) AND a_r1 = 'NA' THEN
    msg := msg || 'R1 can be Not applicable only when E8a and E8b are both unfavorable; ';
  END IF;
  IF cd.supplement_seen IS NULL THEN msg := msg || 'supplement seen or not seen is not recorded; '; END IF;
  IF cd.coder_claim_type IS NULL THEN msg := msg || 'the type of the authors'' Claim is not recorded; '; END IF;

  FOR s IN SELECT cs.*, ee.own_evaluation FROM tracker.coding_summary(p_coding) cs
           LEFT JOIN tracker.element_evaluations ee ON ee.coding_id = p_coding AND ee.element = cs.element LOOP
    IF s.final IS NULL THEN msg := msg || s.element || ' evaluation missing; '; END IF;
    IF s.own_evaluation IS NULL THEN msg := msg || s.element || ': your own evaluation is missing; '; END IF;
    IF NOT s.has_rationale THEN msg := msg || s.element || ' rationale missing; '; END IF;
    IF s.needs_override_note THEN msg := msg || s.element || ' differs from Proposed without a note; '; END IF;
  END LOOP;

  has_reason := coalesce(length(trim(cd.cer_summary_reason)), 0) > 0;
  IF cd.cer_summary IS NULL THEN
    msg := msg || 'CER summary not answered; ';
  ELSE
    IF cd.cer_summary IN ('PN','N') AND NOT has_reason THEN
      msg := msg || 'CER summary answered Probably no or No without a reason; ';
    END IF;
    IF NOT tracker.s1_consistent_v04(cd.cer_summary, c, e, r) THEN
      msg := msg || 'CER summary cannot be Yes or Probably yes when Claim, Evidence or Reasoning is Not supported; ';
    END IF;
  END IF;
  IF cd.evidence_tier IS NULL THEN msg := msg || 'Evidence tier not chosen; '; END IF;
  IF cd.overstated_type IS NOT NULL THEN msg := msg || 'Overstated types are not used under this protocol version: clear the type; '; END IF;

  -- The supportable claim is written at the end, and only when the Claim rating is Not supported.
  IF claim_rating = 'Not supported' AND (cd.supportable_claim IS NULL OR cd.supportable_claim_type IS NULL) THEN
    msg := msg || 'the Claim rating is Not supported: add the supportable claim and its type; ';
  ELSIF claim_rating IS DISTINCT FROM 'Not supported' AND cd.supportable_claim IS NOT NULL THEN
    msg := msg || 'a supportable claim is recorded only when the Claim rating is Not supported: clear it; ';
  END IF;
  attention := nullif(msg, '');
END $$;

-- 5. Reasoning half rule: 3 of 6
CREATE OR REPLACE FUNCTION tracker.v04_element_rule(p_element tracker.element, u text[], n text[], ni text[],
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
    half := k >= 3;                                        -- 3 of 6 (Gene, 2026-11-13)
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

COMMIT;
