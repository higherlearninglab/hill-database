-- Agreement report for Claims double-coded under CERIC-T v0.4. Run as gene_lead. Read-only: it saves nothing.
-- It covers only Claims that BOTH coders have submitted, on their independent codings (before reconciliation).
-- The lead sign-in cannot see another coder's coding of a Claim while her own coding of it is still a draft,
-- so running this early cannot break blind coding.
-- Section labels V1 to V8 follow "Statistics required for version 1.0" in the CERIC-T v0.4 protocol.
-- V1 (bootstrap interval) and the V3 test statistic are computed by agreement_stats_v04.py from agreement_pairs_v04.sql.
\set ON_ERROR_STOP on
\pset pager off
SET client_min_messages = warning;
\set pv 'CERIC-T v0.4'
CREATE TEMP VIEW _both AS
  SELECT claim_id FROM tracker.codings WHERE status = 'submitted' AND protocol_version = :'pv' GROUP BY claim_id HAVING count(*) = 2;
CREATE TEMP VIEW _cod AS
  SELECT c.*, row_number() OVER (PARTITION BY c.claim_id ORDER BY c.coder_id) AS slot, p.name AS coder
  FROM tracker.codings c JOIN _both USING (claim_id) JOIN admin.people p ON p.person_id = c.coder_id;
CREATE TEMP VIEW _ev AS
  SELECT k.claim_id, k.slot, k.coder, k.coding_id, e.element, e.final_evaluation AS ev, e.own_evaluation AS own, e.not_supported_route AS route,
         array_position(enum_range(NULL::tracker.evaluation), e.final_evaluation) - 1 AS lvl
  FROM _cod k JOIN tracker.element_evaluations e USING (coding_id);
-- Is an element of a coding unfavorable only through No information answers? (As the database's own rule 2 reads it.)
CREATE TEMP VIEW _ni AS
  SELECT k.coding_id, q.element,
         coalesce(bool_and(a.answer NOT IN ('N','PN')), false) AND coalesce(bool_or(a.answer = 'NI' AND q.ni_reading = 'unfavorable'), false) AS ni_only
  FROM _cod k JOIN tracker.answers a USING (coding_id)
  JOIN tracker.questions q ON q.protocol_version = k.protocol_version AND q.code = a.question_code GROUP BY 1, 2;
\echo
\echo == 1. Progress ==
SELECT (SELECT count(*) FROM _both) AS claims_submitted_by_both,
       (SELECT count(DISTINCT cl.study_id) FROM _both b JOIN tracker.claims cl USING (claim_id)) AS studies,
       (SELECT max(n) FROM (SELECT count(*) n FROM _both b JOIN tracker.claims cl USING (claim_id) GROUP BY cl.study_id) x) AS most_claims_from_one_study;
\echo The plan for round two is about 30 Claims, with no more than two from any one study.
\echo
\echo == 2. Agreement by element ==
\echo Target: unweighted kappa of 0.70 on each element. Linear-weighted kappa is shown beside it and is not the target.
WITH w AS (
  SELECT a.element, a.lvl AS x, b.lvl AS y FROM _ev a JOIN _ev b ON b.claim_id = a.claim_id AND b.element = a.element AND a.slot = 1 AND b.slot = 2),
m AS (SELECT element, count(*)::numeric AS n, avg(1 - abs(x - y) / 2.0) AS po FROM w GROUP BY element),
pe AS (
  SELECT m.element, sum((SELECT count(*) FROM w WHERE w.element = m.element AND w.x = i) / m.n
                      * (SELECT count(*) FROM w WHERE w.element = m.element AND w.y = j) / m.n * (1 - abs(i - j) / 2.0)) AS pe
  FROM m, generate_series(0, 2) i, generate_series(0, 2) j GROUP BY m.element)
SELECT r.element, r.n_claims, round(100 * r.percent_agreement, 1) AS pct_agree, round(r.kappa, 2) AS kappa,
       round(greatest(r.kappa_ci_low, -1), 2) AS ci_low, round(least(r.kappa_ci_high, 1), 2) AS ci_high,
       CASE WHEN r.kappa >= 0.70 THEN 'meets' ELSE 'below' END AS target,
       round(CASE WHEN pe.pe < 1 THEN (m.po - pe.pe) / (1 - pe.pe) END, 2) AS weighted_kappa,
       round(r.gwet_ac2, 2) AS ac2, round(r.override_rate, 2) AS override_rate
  FROM tracker.reliability(:'pv') r LEFT JOIN m ON m.element = r.element::text::tracker.element LEFT JOIN pe ON pe.element = m.element
 ORDER BY r.element;
\echo
\echo '== V2. Use of each evaluation, by coder (percent of that coder''s Claims) =='
SELECT element, coder, count(*) AS claims,
       round(100.0 * avg((ev = 'Supported')::int), 0) AS supported,
       round(100.0 * avg((ev = 'Some concerns')::int), 0) AS some_concerns,
       round(100.0 * avg((ev = 'Not supported')::int), 0) AS not_supported
  FROM _ev GROUP BY element, slot, coder ORDER BY element, slot;
\echo
\echo == V3. Systematic difference between coders: the 3 x 3 table and the direction of differences ==
\echo Rows are coder 1, columns coder 2 (S = Supported, SC = Some concerns, NS = Not supported). The Stuart-Maxwell test is in agreement_stats_v04.py.
SELECT a.element,
       count(*) FILTER (WHERE a.lvl = 0 AND b.lvl = 0) AS "S/S",  count(*) FILTER (WHERE a.lvl = 0 AND b.lvl = 1) AS "S/SC",  count(*) FILTER (WHERE a.lvl = 0 AND b.lvl = 2) AS "S/NS",
       count(*) FILTER (WHERE a.lvl = 1 AND b.lvl = 0) AS "SC/S", count(*) FILTER (WHERE a.lvl = 1 AND b.lvl = 1) AS "SC/SC", count(*) FILTER (WHERE a.lvl = 1 AND b.lvl = 2) AS "SC/NS",
       count(*) FILTER (WHERE a.lvl = 2 AND b.lvl = 0) AS "NS/S", count(*) FILTER (WHERE a.lvl = 2 AND b.lvl = 1) AS "NS/SC", count(*) FILTER (WHERE a.lvl = 2 AND b.lvl = 2) AS "NS/NS",
       count(*) FILTER (WHERE a.lvl < b.lvl) AS coder_1_more_favorable, count(*) FILTER (WHERE a.lvl > b.lvl) AS coder_2_more_favorable
  FROM _ev a JOIN _ev b ON b.claim_id = a.claim_id AND b.element = a.element AND a.slot = 1 AND b.slot = 2
 GROUP BY a.element ORDER BY a.element;
\echo
\echo '== V5. Agreement on everything else coded (percent agreement and Cohen''s kappa) =='
CREATE TEMP VIEW _items AS
  SELECT 'Claim rating' AS item, a.claim_id, a.final_claim_rating::text AS x, b.final_claim_rating::text AS y FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
  UNION ALL SELECT 'Implications rating', a.claim_id, a.final_implications_rating::text, b.final_implications_rating::text FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
  UNION ALL SELECT 'S1 (favorable or not)', a.claim_id, (a.cer_summary IN ('Y','PY'))::text, (b.cer_summary IN ('Y','PY'))::text FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
  UNION ALL SELECT 'Evidence tier', a.claim_id, a.evidence_tier::text, b.evidence_tier::text FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
  UNION ALL SELECT 'Claim type', a.claim_id, a.coder_claim_type::text, b.coder_claim_type::text FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
  UNION ALL SELECT 'Qualitative-data screener', a.claim_id, a.has_qualitative_data::text, b.has_qualitative_data::text FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2;
WITH n AS (SELECT item, count(*)::numeric AS n, avg((x = y)::int) AS po FROM _items GROUP BY item),
cat AS (SELECT item, x AS g FROM _items UNION SELECT item, y FROM _items),
pe AS (SELECT c.item, sum((SELECT count(*) FROM _items i WHERE i.item = c.item AND i.x = c.g) / n.n * (SELECT count(*) FROM _items i WHERE i.item = c.item AND i.y = c.g) / n.n) AS pe
         FROM cat c JOIN n USING (item) GROUP BY c.item)
SELECT n.item, n.n::int AS claims, round(100 * n.po, 1) AS pct_agree,
       CASE WHEN pe.pe < 1 THEN round((n.po - pe.pe) / (1 - pe.pe), 2) END AS kappa,
       CASE WHEN pe.pe >= 1 THEN 'no variation: kappa undefined' ELSE '' END AS note
  FROM n JOIN pe USING (item) ORDER BY 1;
\echo 'Claim type: each coder''s reading against the type on the Claim record, which the rules use.'
SELECT count(*) AS codings, count(*) FILTER (WHERE k.coder_claim_type = cl.claim_type) AS same_as_record FROM _cod k JOIN tracker.claims cl USING (claim_id);
\echo
\echo == 4. Claim rating and Implications rating from each independent coding ==
SELECT a.claim_id, a.coder AS coder_1, a.final_claim_rating AS claim_1, b.final_claim_rating AS claim_2, a.final_implications_rating AS impl_1, b.final_implications_rating AS impl_2,
       CASE WHEN a.final_claim_rating = b.final_claim_rating THEN 'same' ELSE 'DIFFERENT' END AS claim_rating,
       CASE WHEN a.final_implications_rating = b.final_implications_rating THEN 'same' ELSE 'DIFFERENT' END AS implications_rating
  FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2 ORDER BY 1;
SELECT count(*) AS claims,
       round(100.0 * avg((a.final_claim_rating = b.final_claim_rating)::int), 1) AS claim_rating_pct_agree,
       round(100.0 * avg((a.final_implications_rating = b.final_implications_rating)::int), 1) AS implications_rating_pct_agree
  FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2;
\echo
\echo == 5. Screener: does the Evidence also include qualitative data? ==
SELECT count(*) AS claims, count(*) FILTER (WHERE a.has_qualitative_data = b.has_qualitative_data) AS same_answer,
       count(*) FILTER (WHERE a.has_qualitative_data AND b.has_qualitative_data) AS both_yes
  FROM _cod a JOIN _cod b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2;
\echo
\echo == 6. Element evaluations where the coders differ (these go to reconciliation) ==
SELECT a.claim_id, a.element, a.ev AS coder_1, b.ev AS coder_2, abs(a.lvl - b.lvl) AS steps_apart
  FROM _ev a JOIN _ev b ON b.claim_id = a.claim_id AND b.element = a.element AND a.slot = 1 AND b.slot = 2
 WHERE a.ev <> b.ev ORDER BY a.claim_id, a.element;
\echo
\echo == V4. Agreement on each signalling question ==
\echo 'Reading: favorable, unfavorable or neutral. AC1 is Gwet''s. Prevalence and bias indices use Claims where both readings are favorable or unfavorable.'
WITH r AS (
  SELECT k.claim_id, k.slot, a.question_code AS code, q.element, q.position, a.answer,
         CASE WHEN a.answer IN ('Y','PY') THEN 'f' WHEN tracker.is_unf(a.answer, q.ni_reading) THEN 'u' ELSE 'n' END AS rd
  FROM _cod k JOIN tracker.answers a USING (coding_id)
  JOIN tracker.questions q ON q.protocol_version = :'pv' AND q.code = a.question_code),
p AS (SELECT a.code, a.element, a.position, a.rd AS x, b.rd AS y, a.answer AS ax, b.answer AS ay FROM r a JOIN r b ON b.claim_id = a.claim_id AND b.code = a.code AND a.slot = 1 AND b.slot = 2),
m AS (
  SELECT code, element, position, count(*)::numeric AS n, avg((x = y)::int) AS po,
         (count(*) FILTER (WHERE x = 'f') + count(*) FILTER (WHERE y = 'f')) / (2.0 * count(*)) AS pf,
         (count(*) FILTER (WHERE x = 'u') + count(*) FILTER (WHERE y = 'u')) / (2.0 * count(*)) AS pu,
         (count(*) FILTER (WHERE x = 'n') + count(*) FILTER (WHERE y = 'n')) / (2.0 * count(*)) AS pn,
         count(*) FILTER (WHERE x = 'f' AND y = 'f') AS a, count(*) FILTER (WHERE x = 'f' AND y = 'u') AS b,
         count(*) FILTER (WHERE x = 'u' AND y = 'f') AS c, count(*) FILTER (WHERE x = 'u' AND y = 'u') AS d,
         (count(*) FILTER (WHERE ax = 'NI') + count(*) FILTER (WHERE ay = 'NI')) / (2.0 * count(*)) AS ni,
         (count(*) FILTER (WHERE ax = 'NA') + count(*) FILTER (WHERE ay = 'NA')) / (2.0 * count(*)) AS na,
         (SELECT count(DISTINCT z.answer) FROM r z WHERE z.code = p.code) AS distinct_answers
  FROM p GROUP BY code, element, position)
SELECT code, n::int AS claims, round(100 * po, 0) AS pct_agree,
       round((po - (pf * (1 - pf) + pu * (1 - pu) + pn * (1 - pn)) / 2) / nullif(1 - (pf * (1 - pf) + pu * (1 - pu) + pn * (1 - pn)) / 2, 0), 2) AS ac1,
       CASE WHEN a + b + c + d > 0 THEN round((a - d)::numeric / (a + b + c + d), 2) END AS prevalence_index,
       CASE WHEN a + b + c + d > 0 THEN round((b - c)::numeric / (a + b + c + d), 2) END AS bias_index,
       round(100 * ni, 0) AS no_information_pct, round(100 * na, 0) AS not_applicable_pct,
       CASE WHEN distinct_answers = 1 THEN 'NO VARIATION' ELSE '' END AS flag
  FROM m ORDER BY element, position;
\echo
\echo == 7. Questions that split the coders (3 or more Claims: consider rewording) ==
SELECT question_code, claims_split, CASE WHEN flag_for_rewording THEN 'REWORD?' ELSE '' END AS flag
  FROM tracker.question_splits WHERE protocol_version = :'pv' ORDER BY claims_split DESC, question_code;
\echo
\echo '== V6. The algorithm against the coder''s own evaluation; override rate; route to Not supported =='
\echo What made the algorithm propose Not supported:
SELECT element, coalesce(route, '(coder override, no route)') AS route, count(*) AS codings
  FROM _ev WHERE ev = 'Not supported' GROUP BY 1, 2 ORDER BY 1, 2;
\echo 'The algorithm against each coder''s own evaluation, recorded before the algorithm''s result was shown (kappa beside percent agreement).'
\echo     "critical" is the alternative rule: only a plain No on a critical question gives Not supported
\echo     (C6; E1, E2, E6, E8a, E8b; R1, R2). Implications and Context have no critical questions yet.
WITH x AS (
  SELECT e.element, e.own, tracker.proposed_evaluation(e.coding_id, e.element) AS algo,
         CASE WHEN EXISTS (SELECT 1 FROM tracker.answers a WHERE a.coding_id = e.coding_id AND a.answer = 'N'
                            AND a.question_code = ANY (ARRAY['C6','E1','E2','E6','E8a','E8b','R1','R2'])
                            AND left(a.question_code, 1) = left(e.element::text, 1) AND e.element IN ('Claim','Evidence','Reasoning'))
              THEN 'Not supported'
              WHEN EXISTS (SELECT 1 FROM tracker.answers a JOIN tracker.questions q ON q.protocol_version = :'pv' AND q.code = a.question_code
                            WHERE a.coding_id = e.coding_id AND q.element = e.element AND tracker.is_unf(a.answer, q.ni_reading))
              THEN 'Some concerns' ELSE 'Supported' END::tracker.evaluation AS critical
  FROM _ev e)
SELECT element, count(*) AS codings,
       round(100.0 * avg((algo = own)::int), 1) AS algorithm_matches_own_pct,
       round((avg((algo = own)::int) - (SELECT sum(pa * pb) FROM (SELECT g, avg((x2.algo = g)::int) AS pa, avg((x2.own = g)::int) AS pb
                                                               FROM x x2, unnest(enum_range(NULL::tracker.evaluation)) g WHERE x2.element = x.element GROUP BY g) t))
             / nullif(1 - (SELECT sum(pa * pb) FROM (SELECT g, avg((x2.algo = g)::int) AS pa, avg((x2.own = g)::int) AS pb
                                                     FROM x x2, unnest(enum_range(NULL::tracker.evaluation)) g WHERE x2.element = x.element GROUP BY g) t), 0), 2) AS algorithm_own_kappa,
       round(100.0 * avg((critical = own)::int), 1) AS critical_matches_own_pct,
       count(*) FILTER (WHERE algo = 'Not supported' AND own <> 'Not supported') AS algorithm_stricter,
       count(*) FILTER (WHERE own = 'Not supported' AND algo <> 'Not supported') AS coder_stricter
  FROM x GROUP BY element ORDER BY element;
\echo
\echo == V7. Results recomputed under the critical-questions alternative ==
\echo Claim, Evidence and Reasoning use the alternative; Implications and Context keep the present rule because they have no critical questions yet.
WITH x AS (
  SELECT k.coding_id, k.claim_id, k.cer_summary, e.element, tracker.proposed_evaluation(k.coding_id, e.element) AS algo,
         CASE WHEN e.element NOT IN ('Claim','Evidence','Reasoning') THEN tracker.proposed_evaluation(k.coding_id, e.element)
              WHEN EXISTS (SELECT 1 FROM tracker.answers a WHERE a.coding_id = k.coding_id AND a.answer = 'N'
                            AND a.question_code = ANY (ARRAY['C6','E1','E2','E6','E8a','E8b','R1','R2']) AND left(a.question_code, 1) = left(e.element::text, 1))
              THEN 'Not supported'
              WHEN EXISTS (SELECT 1 FROM tracker.answers a JOIN tracker.questions q ON q.protocol_version = :'pv' AND q.code = a.question_code
                            WHERE a.coding_id = k.coding_id AND q.element = e.element AND tracker.is_unf(a.answer, q.ni_reading))
              THEN 'Some concerns' ELSE 'Supported' END::tracker.evaluation AS alt
  FROM _cod k CROSS JOIN unnest(enum_range(NULL::tracker.element)) AS e(element)),
w AS (
  SELECT coding_id, claim_id, cer_summary,
         max(algo) FILTER (WHERE element = 'Claim') AS c1, max(algo) FILTER (WHERE element = 'Evidence') AS e1, max(algo) FILTER (WHERE element = 'Reasoning') AS r1, max(algo) FILTER (WHERE element = 'Context') AS x1,
         max(alt) FILTER (WHERE element = 'Claim') AS c2, max(alt) FILTER (WHERE element = 'Evidence') AS e2, max(alt) FILTER (WHERE element = 'Reasoning') AS r2,
         count(*) FILTER (WHERE algo <> alt) AS elements_changed
  FROM x GROUP BY 1, 2, 3),
z AS (
  SELECT *, tracker.derive_claim_rating(cer_summary, c1, e1, r1, x1, (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Evidence'), (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Reasoning')) AS rating_now,
            tracker.derive_claim_rating(cer_summary, c2, e2, r2, x1, (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Evidence'), (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Reasoning')) AS rating_alt
  FROM w AS COD)
SELECT count(*) AS codings, sum(elements_changed) AS element_evaluations_changed, count(*) FILTER (WHERE rating_now <> rating_alt) AS claim_ratings_changed,
       count(*) FILTER (WHERE rating_alt > rating_now) AS stricter_under_alternative, count(*) FILTER (WHERE rating_alt < rating_now) AS more_favorable_under_alternative
  FROM z;
\echo
\echo == V8. How often each rule and each trigger fired (zero means untested by this set) ==
WITH f AS (
  SELECT k.coding_id, k.claim_id, k.cer_summary,
         max(e.final_evaluation) FILTER (WHERE e.element = 'Claim') AS c, max(e.final_evaluation) FILTER (WHERE e.element = 'Evidence') AS e,
         max(e.final_evaluation) FILTER (WHERE e.element = 'Reasoning') AS r, max(e.final_evaluation) FILTER (WHERE e.element = 'Context') AS x
  FROM _cod k JOIN tracker.element_evaluations e USING (coding_id) GROUP BY 1, 2, 3),
g AS (
  SELECT CASE WHEN (e = 'Not supported' AND NOT (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Evidence')) OR (r = 'Not supported' AND NOT (SELECT n.ni_only FROM _ni n WHERE n.coding_id = COD.coding_id AND n.element = 'Reasoning')) THEN 1
              WHEN e = 'Not supported' OR r = 'Not supported' THEN 2
              WHEN c = 'Not supported' OR cer_summary IN ('PN','N') THEN 3
              WHEN x = 'Not supported' OR 'Some concerns' IN (c, e, r, x) THEN 4 ELSE 5 END AS rule FROM f AS COD)
SELECT v.rule, v.gives, count(g.rule) AS codings, CASE WHEN count(g.rule) = 0 THEN 'UNTESTED' ELSE '' END AS flag
  FROM (VALUES (1, 'Not supported (Evidence or Reasoning fails)'), (2, 'Cannot be evaluated'), (3, 'Not supported (Claim element or S1)'),
               (4, 'Supported with concerns'), (5, 'Supported')) v(rule, gives)
  LEFT JOIN g ON g.rule = v.rule GROUP BY v.rule, v.gives ORDER BY v.rule;
WITH a AS (SELECT k.coding_id, k.mark_r7_fallacy_carries_claim AS m7, k.mark_i7_no_limitations AS mi, cl.claim_type = 'Cause-effect' AS causal,
                  jsonb_object_agg(an.question_code, an.answer::text) AS j
             FROM _cod k JOIN tracker.claims cl USING (claim_id) JOIN tracker.answers an USING (coding_id) GROUP BY 1, 2, 3, 4)
SELECT t.trigger, count(*) FILTER (WHERE t.fired) AS codings, CASE WHEN count(*) FILTER (WHERE t.fired) = 0 THEN 'UNTESTED' ELSE '' END AS flag
  FROM a, LATERAL (VALUES
    ('C4 unfavorable with C5 or C6 unfavorable', (j->>'C4') IN ('PN','N','NI') AND ((j->>'C5') IN ('PN','N','NI') OR (j->>'C6') IN ('PN','N','NI'))),
    ('E1 No', j->>'E1' = 'N'), ('E1 No information', j->>'E1' = 'NI'), ('E2 No', j->>'E2' = 'N'), ('E2 No information', j->>'E2' = 'NI'),
    ('E6 No, Cause-effect Claim', j->>'E6' = 'N' AND causal), ('E7 No', j->>'E7' = 'N'), ('E9 No', j->>'E9' = 'N'),
    ('R6 No', j->>'R6' = 'N'), ('R7 No, fallacy carries the Claim', j->>'R7' = 'N' AND m7),
    ('I6 No with I3, I4 or I5 unfavorable', j->>'I6' = 'N' AND ((j->>'I3') IN ('PN','N','NI') OR (j->>'I4') IN ('PN','N','NI') OR (j->>'I5') IN ('PN','N','NI'))),
    ('I7a No, no limitations stated', j->>'I7a' = 'N' AND mi), ('Co1 No', j->>'Co1' = 'N'), ('Co3 No', j->>'Co3' = 'N')) t(trigger, fired)
 GROUP BY t.trigger ORDER BY t.trigger;
\echo
\echo == 9. Corrections to submitted codings ==
\echo A correction asked for after the other coding was submitted may not be independent of it.
SELECT status, other_coding_submitted, count(*) AS requests FROM tracker.corrections_list() k
 WHERE k.claim_id IN (SELECT claim_id FROM tracker.codings WHERE protocol_version = :'pv') GROUP BY 1, 2 ORDER BY 1, 2;
\echo
\echo == 10. Flags for a suspected reporting error ==
SELECT claim_id, coder, reporting_error_open_data AS open_data, left(reporting_error_note, 100) AS note FROM _cod WHERE reporting_error_note IS NOT NULL ORDER BY 1, 2;
