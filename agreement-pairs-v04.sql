-- One line per Claim and element for Claims both coders have submitted under CERIC-T v0.4: the input to agreement_stats_v04.py.
-- Run as gene_lead with: psql -At -F, -f agreement_pairs_v04.sql | python3 agreement_stats_v04.py
-- Levels: 0 Supported, 1 Some concerns, 2 Not supported. Read-only.
WITH pair AS (SELECT claim_id FROM tracker.codings WHERE status = 'submitted' AND protocol_version = 'CERIC-T v0.4' GROUP BY claim_id HAVING count(*) = 2),
k AS (SELECT c.coding_id, c.claim_id, row_number() OVER (PARTITION BY c.claim_id ORDER BY c.coder_id) AS slot FROM tracker.codings c JOIN pair USING (claim_id))
SELECT a.claim_id, cl.study_id, ea.element,
       array_position(enum_range(NULL::tracker.evaluation), ea.final_evaluation) - 1,
       array_position(enum_range(NULL::tracker.evaluation), eb.final_evaluation) - 1
FROM k a JOIN k b ON b.claim_id = a.claim_id AND a.slot = 1 AND b.slot = 2
JOIN tracker.claims cl ON cl.claim_id = a.claim_id
JOIN tracker.element_evaluations ea ON ea.coding_id = a.coding_id
JOIN tracker.element_evaluations eb ON eb.coding_id = b.coding_id AND eb.element = ea.element
ORDER BY 1, 3;
