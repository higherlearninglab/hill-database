-- CERIC-T v0.4, part 3 of the build: submitting a coding.
-- A v0.4 coding carries two ratings, written at submission from the element evaluations and the CER summary.
-- v0.2 and v0.3 codings are untouched: every function below returns to the earlier behaviour for them.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

ALTER TABLE tracker.codings
  ADD COLUMN final_claim_rating tracker.claim_rating,
  ADD COLUMN final_implications_rating tracker.implications_rating,
  ADD CONSTRAINT v04_ratings_only_under_v04 CHECK (
    (final_claim_rating IS NULL AND final_implications_rating IS NULL) OR protocol_version = 'CERIC-T v0.4'),
  ADD CONSTRAINT v04_ratings_together CHECK ((final_claim_rating IS NULL) = (final_implications_rating IS NULL)),
  ADD CONSTRAINT v04_submitted_has_ratings CHECK (
    protocol_version <> 'CERIC-T v0.4' OR status <> 'submitted' OR final_claim_rating IS NOT NULL),
  ADD CONSTRAINT v04_no_single_rating CHECK (
    protocol_version <> 'CERIC-T v0.4' OR (final_rating IS NULL AND final_severity IS NULL)),
  ADD CONSTRAINT v04_supportable_claim CHECK (
    protocol_version <> 'CERIC-T v0.4' OR status <> 'submitted'
    OR (final_claim_rating = 'Not supported') = (supportable_claim IS NOT NULL));
COMMENT ON COLUMN tracker.codings.final_claim_rating IS 'v0.4: derived at submission. Overstated is not a possible value.';
COMMENT ON COLUMN tracker.codings.final_implications_rating IS 'v0.4: derived at submission. Not rated when the Claim rating is Not supported or Cannot be evaluated.';

-- Each coder records the type of the Claim as the authors state it. The element rules keep using the type on the
-- Claim record, so both coders answer under the same rules; the coders' own types are compared in the agreement report.
ALTER TABLE tracker.codings ADD COLUMN coder_claim_type tracker.claim_type;
COMMENT ON COLUMN tracker.codings.coder_claim_type IS 'v0.4: the type of the authors'' Claim as this coder reads it. Compared between coders; the rules use the type on the Claim record.';

-- A suspected reporting error that affects a rating: the coder codes the article as published and records a flag.
ALTER TABLE tracker.codings
  ADD COLUMN reporting_error_note text,
  ADD COLUMN reporting_error_open_data boolean,
  ADD CONSTRAINT reporting_error_complete CHECK ((reporting_error_note IS NULL) = (reporting_error_open_data IS NULL));
COMMENT ON COLUMN tracker.codings.reporting_error_note IS 'v0.4: a likely error in the published article that affects a rating. The article is still coded as published.';
COMMENT ON COLUMN tracker.codings.reporting_error_open_data IS 'v0.4: whether the authors'' data are openly available to check the suspected error.';

GRANT INSERT (has_qualitative_data, supplement_seen, reporting_error_note, reporting_error_open_data, coder_claim_type),
      UPDATE (has_qualitative_data, supplement_seen, reporting_error_note, reporting_error_open_data, coder_claim_type) ON tracker.codings TO hill_coder;

-- A coder cannot set the v0.4 ratings; submit_coding() writes them.
CREATE OR REPLACE FUNCTION tracker.no_rating_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF NEW.protocol_version <> 'CERIC-T v0.2' AND NEW.status = 'draft'
     AND (NEW.final_rating IS NOT NULL OR NEW.final_severity IS NOT NULL) THEN
    RAISE EXCEPTION 'Under % the rating and severity cannot be overridden; they follow from the evaluations and the CER summary', NEW.protocol_version
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status = 'draft' AND (NEW.final_claim_rating IS NOT NULL OR NEW.final_implications_rating IS NOT NULL) THEN
    RAISE EXCEPTION 'Under % the Claim rating and the Implications rating cannot be set; they follow from the evaluations and the CER summary', NEW.protocol_version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- Answers: NA only where allowed (as before), and now No information only where it is offered.
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
    IF to_jsonb(NEW) ->> 'answer' = 'NI'
       AND NOT (SELECT ni_allowed FROM tracker.questions
                WHERE protocol_version = pv AND code = to_jsonb(NEW) ->> 'question_code') THEN
      RAISE EXCEPTION 'No information is not offered on %', to_jsonb(NEW) ->> 'question_code' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

-- The result of a v0.4 coding, and everything that still stops it being submitted.
CREATE FUNCTION tracker.coding_result_v04(p_coding int,
  OUT claim_rating tracker.claim_rating, OUT implications_rating tracker.implications_rating,
  OUT falls_short text, OUT needs_supportable_claim boolean, OUT attention text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation;
  cd record; s record; n_ans int; n_q int; msg text := ''; has_reason boolean; e_ni boolean; r_ni boolean;
  a_e8a tracker.answer_code; a_e8b tracker.answer_code; a_e8c tracker.answer_code; a_r1 tracker.answer_code; a_r1b tracker.answer_code;
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

  -- Screener and the questions it controls
  SELECT answer INTO a_e8a FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'E8a';
  SELECT answer INTO a_e8b FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'E8b';
  SELECT answer INTO a_e8c FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'E8c';
  SELECT answer INTO a_r1  FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'R1';
  SELECT answer INTO a_r1b FROM tracker.answers WHERE coding_id = p_coding AND question_code = 'R1b';
  SELECT unf INTO unf_e FROM tracker._unf_codes(p_coding, 'Evidence');
  IF cd.has_qualitative_data IS NULL THEN
    msg := msg || 'qualitative-data screener not answered; ';
  ELSIF NOT cd.has_qualitative_data THEN
    IF a_e8c IS DISTINCT FROM 'NA' OR a_r1b IS DISTINCT FROM 'NA' THEN
      msg := msg || 'E8c and R1b must be Not applicable when the Claim does not rest on qualitative data; ';
    END IF;
  ELSE
    IF a_e8c = 'NA' THEN msg := msg || 'E8c cannot be Not applicable when the Claim also rests on qualitative data; '; END IF;
    -- Counted once: an unreported limit is answered at E8c, and R1b is then Not applicable.
    IF 'E8c' = ANY(unf_e) AND a_r1b IS DISTINCT FROM 'NA' THEN
      msg := msg || 'R1b must be Not applicable when E8c is unfavorable; ';
    ELSIF NOT ('E8c' = ANY(unf_e)) AND a_r1b = 'NA' THEN
      msg := msg || 'R1b can be Not applicable only when E8c is unfavorable; ';
    END IF;
  END IF;
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

CREATE OR REPLACE FUNCTION tracker.submit_coding(p_coding int) RETURNS tracker.rating
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE c record; r record; r4 record;
BEGIN
  SELECT * INTO c FROM tracker.codings WHERE coding_id = p_coding;
  IF NOT FOUND OR c.coder_id IS DISTINCT FROM admin.me() OR admin.my_login_role() <> 'coder' THEN
    RAISE EXCEPTION 'Only the coder can submit their own coding' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF c.status <> 'draft' THEN RAISE EXCEPTION 'Coding % is already submitted', p_coding; END IF;

  IF c.protocol_version = 'CERIC-T v0.4' THEN
    SELECT * INTO r4 FROM tracker.coding_result_v04(p_coding);
    IF r4.attention IS NOT NULL THEN
      RAISE EXCEPTION 'Cannot submit coding %: %', p_coding, r4.attention USING ERRCODE = 'check_violation';
    END IF;
    PERFORM set_config('hill.submitting', 'on', true);
    UPDATE tracker.element_evaluations ee
       SET not_supported_route = tracker.proposed_route(p_coding, ee.element)
     WHERE ee.coding_id = p_coding;
    UPDATE tracker.codings
       SET final_claim_rating = r4.claim_rating, final_implications_rating = r4.implications_rating,
           status = 'submitted', submitted_at = now()
     WHERE coding_id = p_coding;
    PERFORM set_config('hill.submitting', 'off', true);
    RETURN NULL;       -- a v0.4 coding has no single rating; read final_claim_rating and final_implications_rating
  END IF;

  SELECT * INTO r FROM tracker.coding_result(p_coding);
  IF r.attention IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot submit coding %: %', p_coding, r.attention USING ERRCODE = 'check_violation';
  END IF;
  PERFORM set_config('hill.submitting', 'on', true);
  UPDATE tracker.codings
     SET final_rating   = coalesce(final_rating, r.proposed_rating),
         final_severity = coalesce(final_severity, r.proposed_severity),
         status = 'submitted', submitted_at = now()
   WHERE coding_id = p_coding;
  PERFORM set_config('hill.submitting', 'off', true);
  RETURN (SELECT final_rating FROM tracker.codings WHERE coding_id = p_coding);
END $$;

-- The coder's own evaluation is recorded before the algorithm's result is shown, so it cannot be changed afterwards.
CREATE FUNCTION tracker.lock_own_evaluation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF OLD.own_evaluation IS NOT NULL AND NEW.own_evaluation IS DISTINCT FROM OLD.own_evaluation THEN
    RAISE EXCEPTION 'Your own evaluation of % is already recorded and cannot be changed', OLD.element USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER lock_own_evaluation BEFORE UPDATE ON tracker.element_evaluations
  FOR EACH ROW EXECUTE FUNCTION tracker.lock_own_evaluation();

GRANT EXECUTE ON FUNCTION tracker.coding_result_v04(int) TO hill_coder, hill_lead, hill_tiebreak;
COMMIT;
