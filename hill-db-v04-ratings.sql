-- CERIC-T v0.4, part 1 of the build: the two ratings.
-- Adds types and pure functions only. It changes no table, no v0.3 function and no stored record.
-- Decision rules v0.4 (Gene, 2026-11-11): each Claim has a Claim rating and an Implications rating,
-- stored separately. "Overstated" is a value of the Implications rating only.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE TYPE tracker.claim_rating AS ENUM
  ('Supported','Supported with concerns','Not supported','Cannot be evaluated');
CREATE TYPE tracker.implications_rating AS ENUM
  ('Supported','Some concerns','Overstated','Not rated');
COMMENT ON TYPE tracker.claim_rating IS 'v0.4. Overstated is deliberately absent: it applies only to the Implications.';

-- Claim rating. Implications are not an input. e_ni and r_ni say that the element is Not supported
-- only through No information answers (no question in it was answered No or Probably no).
CREATE FUNCTION tracker.derive_claim_rating(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation,
                                            r tracker.evaluation, x tracker.evaluation, e_ni boolean, r_ni boolean)
RETURNS tracker.claim_rating LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN s1 IS NULL OR c IS NULL OR e IS NULL OR r IS NULL OR x IS NULL THEN NULL
    WHEN (e = 'Not supported' AND NOT coalesce(e_ni, false))
      OR (r = 'Not supported' AND NOT coalesce(r_ni, false)) THEN 'Not supported'      -- rule 1
    WHEN e = 'Not supported' OR r = 'Not supported' THEN 'Cannot be evaluated'         -- rule 2
    WHEN c = 'Not supported' OR s1 IN ('PN','N') THEN 'Not supported'                  -- rule 3
    WHEN x = 'Not supported' OR 'Some concerns' IN (c, e, r, x) THEN 'Supported with concerns'  -- rule 4
    ELSE 'Supported'                                                                   -- rule 5
  END::tracker.claim_rating
$$;

-- Implications rating: the Implications element under its public names, or Not rated when the Claim fails.
CREATE FUNCTION tracker.derive_implications_rating(cr tracker.claim_rating, i tracker.evaluation)
RETURNS tracker.implications_rating LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN cr IS NULL OR i IS NULL THEN NULL
    WHEN cr IN ('Not supported','Cannot be evaluated') THEN 'Not rated'
    WHEN i = 'Not supported' THEN 'Overstated'
    WHEN i = 'Some concerns' THEN 'Some concerns'
    ELSE 'Supported'
  END::tracker.implications_rating
$$;

-- The S1 consistency check, widened to the Claim element.
CREATE FUNCTION tracker.s1_consistent_v04(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT NOT (s1 IN ('Y','PY') AND 'Not supported' IN (c, e, r))
$$;

-- Where the Claim's argument falls short. Implications are not listed: they have their own line.
CREATE FUNCTION tracker.falls_short_v04(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                        x tracker.evaluation, e_ni boolean, r_ni boolean) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(concat_ws(', ',
    CASE WHEN c <> 'Supported' THEN 'Claim (' || c || ')' END,
    CASE WHEN e = 'Not supported' AND coalesce(e_ni, false) THEN 'Evidence (not enough reported)'
         WHEN e <> 'Supported' THEN 'Evidence (' || e || ')' END,
    CASE WHEN r = 'Not supported' AND coalesce(r_ni, false) THEN 'Reasoning (not enough reported)'
         WHEN r <> 'Supported' THEN 'Reasoning (' || r || ')' END,
    CASE WHEN s1 = 'PN' THEN 'CER summary (Probably no)' WHEN s1 = 'N' THEN 'CER summary (No)' END,
    CASE WHEN x <> 'Supported' THEN 'Context (' || x || ')' END), '')
$$;

GRANT USAGE ON TYPE tracker.claim_rating, tracker.implications_rating TO hill_lead, hill_coder, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.derive_claim_rating(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean),
  tracker.derive_implications_rating(tracker.claim_rating, tracker.evaluation),
  tracker.s1_consistent_v04(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.falls_short_v04(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean)
  TO hill_lead, hill_coder, hill_agent;
COMMIT;
