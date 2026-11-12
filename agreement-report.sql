-- Agreement report for double-coded Claims. Run as gene_lead. Read-only: it saves nothing.
-- It covers only Claims that BOTH coders have submitted, on their independent codings (before reconciliation).
-- The lead sign-in cannot see another coder's coding of a Claim while Gene's own coding of it is still a draft,
-- so running this early cannot break blind coding.
\set ON_ERROR_STOP on
\pset pager off
SET client_min_messages = warning;
\set pv 'CERIC-T v0.3'
\echo
\echo == 1. Progress ==
SELECT (SELECT count(DISTINCT claim_id) FROM tracker.assignments) AS claims_assigned,
       (SELECT count(*) FROM (SELECT claim_id FROM tracker.codings WHERE status = 'submitted' AND protocol_version = :'pv'
                              GROUP BY claim_id HAVING count(*) = 2) x) AS claims_submitted_by_both;
\echo
\echo == 2. Agreement by element (percent agreement, kappa with approximate 95% interval, Gwet AC2, override rate) ==
\echo With few Claims the kappa interval is wide; read kappa as a point estimate. The target is 0.70 per element.
SELECT element, n_claims, round(100 * percent_agreement, 1) AS pct_agree, round(kappa, 2) AS kappa,
       round(greatest(kappa_ci_low, -1), 2) AS ci_low, round(least(kappa_ci_high, 1), 2) AS ci_high, round(gwet_ac2, 2) AS ac2, round(override_rate, 2) AS override_rate
  FROM tracker.reliability(:'pv') ORDER BY element;
\echo
\echo == 3. CER summary (favorable versus unfavorable) and Evidence tier ==
SELECT item, n_claims, round(percent_agreement, 1) AS pct_agree FROM tracker.reliability_items(:'pv');
\echo
\echo == 4. Rating from each independent coding, per Claim ==
WITH p AS (
  SELECT c.claim_id, min(c.final_rating::text) FILTER (WHERE c.coder_id = 1) AS gene, min(c.final_rating::text) FILTER (WHERE c.coder_id = 2) AS adam
    FROM tracker.codings c WHERE c.status = 'submitted' AND c.protocol_version = :'pv' GROUP BY c.claim_id HAVING count(*) = 2)
SELECT claim_id, gene, adam, CASE WHEN gene = adam THEN 'same' ELSE 'DIFFERENT' END AS agreement FROM p ORDER BY claim_id;
WITH p AS (
  SELECT c.claim_id, count(DISTINCT c.final_rating) = 1 AS same
    FROM tracker.codings c WHERE c.status = 'submitted' AND c.protocol_version = :'pv' GROUP BY c.claim_id HAVING count(*) = 2)
SELECT count(*) AS claims, count(*) FILTER (WHERE same) AS same_rating, round(100.0 * count(*) FILTER (WHERE same) / nullif(count(*), 0), 1) AS pct_agree FROM p;
\echo
\echo == 5. Element evaluations where the coders differ (these go to reconciliation) ==
WITH e AS (
  SELECT c.claim_id, ev.element, min(ev.final_evaluation::text) FILTER (WHERE c.coder_id = 1) AS gene, min(ev.final_evaluation::text) FILTER (WHERE c.coder_id = 2) AS adam
    FROM tracker.codings c JOIN tracker.element_evaluations ev USING (coding_id)
   WHERE c.status = 'submitted' AND c.protocol_version = :'pv' GROUP BY c.claim_id, ev.element HAVING count(*) = 2)
SELECT claim_id, element, gene, adam FROM e WHERE gene <> adam ORDER BY claim_id, element;
\echo
\echo == 6. Questions that split the coders (3 or more Claims: consider rewording) ==
SELECT question_code, claims_split, CASE WHEN flag_for_rewording THEN 'REWORD?' ELSE '' END AS flag
  FROM tracker.question_splits WHERE protocol_version = :'pv' ORDER BY claims_split DESC, question_code;
\echo
\echo == 7. Rule checks from calibration ==
\echo Evidence or Reasoning Not supported only through No information (the Cannot be evaluated boundary):
SELECT c.claim_id, c.coder_id, c.final_rating::text AS rating, tracker.coding_falls_short(c.coding_id) AS falls_short
  FROM tracker.codings c WHERE c.status = 'submitted' AND c.protocol_version = :'pv'
   AND c.claim_id IN (SELECT claim_id FROM tracker.codings WHERE status = 'submitted' GROUP BY claim_id HAVING count(*) = 2)
   AND (c.final_rating = 'Cannot be evaluated' OR tracker.coding_falls_short(c.coding_id) LIKE '%not enough reported%') ORDER BY 1, 2;
\echo Claim Not supported while the CER summary is Yes or Probably yes (rated Overstated by rule 3):
SELECT c.claim_id, c.coder_id, c.cer_summary::text AS s1, c.final_rating::text AS rating
  FROM tracker.codings c JOIN tracker.element_evaluations ev ON ev.coding_id = c.coding_id AND ev.element = 'Claim'
 WHERE c.status = 'submitted' AND c.protocol_version = :'pv' AND ev.final_evaluation = 'Not supported' AND c.cer_summary IN ('Y','PY')
   AND c.claim_id IN (SELECT claim_id FROM tracker.codings WHERE status = 'submitted' GROUP BY claim_id HAVING count(*) = 2) ORDER BY 1, 2;
\echo Elements decided by the half rule alone would need the answers; see section 6 for where the coders split.
