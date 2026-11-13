# HiLL database

The database behind the Higher Learning Lab evidence trackers (Claim Check: AI in Education, and the meta-analysis audit) and HiLL's funding records.

This repository holds the structure only. It contains no study data, no coding results and no passwords.

## What it guarantees

The database enforces these rules itself, so they do not depend on any person or AI agent following instructions.

1. **Appraisal is human.** AI agents can prepare packets of quoted passages, pre-fill factual fields and raise flags. They cannot write a CERIC-T signalling answer, an element evaluation, a rationale, a rating, a severity, the CER summary answer or the Evidence tier.
2. **Blind double-coding.** Each coder sees only their own answers on a claim until both coders have submitted.
3. **Submitted codings are locked.** Later changes go through reconciliation, with a recorded reason. The one exception, under CERIC-T v0.4, is a correction of an entry mistake (see 18).
4. **Every departure from the rules is explained.** If a coder's evaluation of an element differs from the one the rules propose, an override note is required.
5. **No incomplete records.** A coding cannot be submitted without every answer, five evaluations and five rationales, the CER summary answer and the Evidence tier.
6. **"Not applicable" only where the protocol allows it.**
7. **Nothing is public without the lead's approval of a release.**
8. **Ratings stay held** until the rubric reaches version 1.0 and the lead turns them on.
9. **Full history.** Every change is recorded in an append-only log.
10. **Every coding records the protocol version it was coded under.** Questions are stored per version, so a coding stays tied to the questions it used.
11. **Agent pre-fills in synthesis audits must be confirmed by a human** before the audit can be submitted.
12. **No one settles a disagreement on their own coding.**
13. **Ratings are derived, not chosen.** From CERIC-T v0.3 on, the database derives each rating from the element evaluations, the CER summary and the answers. A coder cannot set or override it.
14. **A tie-breaker never codes the Claim.** No one assigned to code a Claim can be named its tie-breaker, and a Claim's tie-breaker cannot be assigned to code it.
15. **The Dependence item is confirmed by a person and never affects a rating.** An agent may pre-fill it with quoted passages. A coder or the lead confirms it, and a person who still has coding to submit on the study cannot see or confirm it. An agent cannot confirm it or change a confirmed record.
16. **Two ratings, kept apart (CERIC-T v0.4).** Each Claim has a Claim rating and an Implications rating, stored in separate fields with separate lists of allowed values. "Overstated" is an Implications rating only; the database rejects it as a Claim rating.
17. **The coder's own evaluation comes first (CERIC-T v0.4).** A coder records their own evaluation of each element before the rule's result is shown. Once recorded it cannot be changed, except through an approved correction.
18. **Corrections are decided by someone else (CERIC-T v0.4).** A coder may ask, with a reason, to correct an entry mistake in a submitted coding. Another person decides: the lead or a coder assigned to the same Claim, never the coder who asked. It is possible only before reconciliation has started. The coding as it stood is kept, and the request, the decision and the changes are logged. Agents cannot ask, decide or see.
19. **A finalized rating can be annotated, never altered (CERIC-T v0.4).** Either coder of a Claim may add a note to its finalized rating. Notes are added only: no sign-in, including the database owner, can edit or remove one, and a note never changes a rating.

## The ratings (CERIC-T v0.4, draft; current from 2026-11-12)

Every element is evaluated against the Claim as the authors state it.

| Claim rating | Rule (applied in order; the first that matches governs) |
|---|---|
| Not supported | Evidence or Reasoning is Not supported, with a question in that element answered No or Probably no |
| Cannot be evaluated | Evidence or Reasoning is Not supported only through No information answers |
| Not supported | The Claim element is Not supported, or the CER summary is answered Probably no or No |
| Supported with concerns | Context is Not supported, or Claim, Evidence, Reasoning or Context has Some concerns |
| Supported | Claim, Evidence, Reasoning and Context are all Supported |

| Implications rating | When |
|---|---|
| Not rated | The Claim rating is Not supported or Cannot be evaluated |
| Supported | The Implications element is Supported |
| Some concerns | The Implications element has Some concerns |
| Overstated | The Implications element is Not supported |

The Implications element is not an input to the Claim rating. Severity is not used under v0.4. When the Claim rating is Not supported, the coders record the claim the study can support, with its type; nothing is evaluated against it. A coder may flag a suspected reporting error, with whether the authors' data are openly available; the flag is agreed at finalizing and leaves the ratings as coded.

## The rating scale (CERIC-T v0.3, draft; calibration round one)

| Rating | Meaning |
|---|---|
| Supported | The Evidence and Reasoning support the Claim as stated, and the Implications stay within what the Claim supports. |
| Supported with concerns | The Evidence and Reasoning support the Claim as stated. Concerns in one or more elements weaken confidence but do not change that. |
| Overstated | The Evidence and Reasoning support a narrower Claim than the one stated. |
| Not supported | The Evidence or Reasoning fails, so neither the Claim as stated nor a narrower version of it is supported. |
| Cannot be evaluated | The article does not report enough about the Evidence or Reasoning to tell whether the Claim is supported. |

Applied in order; the first rule that matches governs:

1. Evidence or Reasoning is Not supported, with a question in that element answered No or Probably no: **Not supported**.
2. Evidence or Reasoning is Not supported only through No information answers: **Cannot be evaluated**.
3. The CER summary is answered Probably no or No, or the Claim is Not supported: **Overstated**.
4. Implications or Context is Not supported, or any element has Some concerns: **Supported with concerns**.
5. All five elements are Supported: **Supported**.

Every rating below Supported carries a derived line naming where the argument falls short. Cannot be evaluated carries no severity.

CERIC-T v0.3 is a draft. A first calibration round was coded under it in November 2026; those records stay under v0.3 and are not re-rated. Scripts are added here only after they are live in the database and their tests pass.

## The Dependence item

Reported beside the rating for any study of a student-facing learning support. It records whether the tool is designed to hand responsibility to the student over time (fades; fixed or on demand; not reported; not applicable), whether the study measured that transfer (measured: transferred; measured: not transferred; not measured; not applicable), and whether a teacher has a role (yes; no; not reported; not applicable), each with a quoted passage and page. It is not an input to any element evaluation or rating.

## Files

Apply the twelve scripts in this order.

| File | What it is |
|---|---|
| `hill-db-phase2.sql` | The first build: roles, tables, the CERIC-T v0.2 rule functions, safeguards and public views, plus reference data: the 36 v0.2 questions and 43 Synthesis Audit Checklist items by code, and the 22 vulnerable-student categories |
| `hill-db-v03.sql` | CERIC-T v0.3: 42 questions by code, stored per protocol version; the CER summary and the Evidence tier; the half rule; reconciliation of the CER summary and the tier; publication status |
| `hill-db-rating-scale.sql` | The five-rating scale and its rules; the derived "falls short at" line; the overall result is named a rating throughout |
| `hill-db-no-rating-override.sql` | Under v0.3 a coder cannot set or override the rating or severity |
| `hill-db-tiebreak-guard.sql` | A tie-breaker cannot be someone assigned to code the Claim |
| `hill-db-dependence-item.sql` | The Dependence item: agent pre-fill, human confirmation, visibility rule and public view |
| `hill-db-v04-ratings.sql` | CERIC-T v0.4: the two rating types and the functions that derive them |
| `hill-db-v04-questions-algorithms.sql` | The v0.4 question set (41 questions by code), the element rule, the route to Not supported, and the fields for the coder's own evaluation, the qualitative-data screener and the supplement |
| `hill-db-v04-submit.sql` | Submitting a v0.4 coding with two ratings; the checks a coding must pass; the reporting-error flag |
| `hill-db-v04-reconcile.sql` | Reconciling and finalizing a v0.4 Claim with two ratings; the public view |
| `hill-db-v04-corrections.sql` | Correcting an entry mistake in a submitted coding, decided by another person |
| `hill-db-v04-rating-notes.sql` | Notes appended to a finalized rating |
| `run_tests_v03.py` | 290 automated tests of the database as it is now: rule scenarios for v0.3 and v0.4, every combination of element evaluations for the two ratings, and a test of every safeguard above, run by signing in as each role |
| `test-results-2026-11-12.txt` | Results of those tests |
| `test-results-2026-11-11.txt` | Results of the 190 tests as they stood before the v0.4 scripts |
| `agreement-report-v04.sql`, `agreement-pairs-v04.sql`, `agreement-stats-v04.py` | The read-only agreement report for v0.4 codings: agreement and kappa per element and for both ratings, per-question statistics, the rule's result against each coder's own evaluation, and how often each rule fired; a script adds a bootstrap interval that resamples studies and a test of marginal homogeneity |
| `test-results-2026-11-10.txt` | Results of the 172 tests as they stood before the last two scripts |
| `agreement-report.sql` | A read-only report for the lead on agreement between two coders: percent agreement, Cohen's kappa with an interval, Gwet's AC2 and the override rate for each element, and agreement on the rating, the CER summary and the Evidence tier |
| `run_tests.py`, `test-results-2026-11-09.txt` | The 145 tests of the first build alone, and their results |

Question and checklist wording is held back until HiLL publishes the codebook. These scripts list questions and checklist items by code only.

The first two scripts are kept exactly as they were applied, so they carry the names in use at the time. `hill-db-rating-scale.sql` renames them.

## Running the tests

Run the tests in a scratch database only, never the live one. The scripts refuse to run in a database named `hill` or `defaultdb`.

```
createdb hilltest
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-phase2.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v03.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-rating-scale.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-no-rating-override.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-tiebreak-guard.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-dependence-item.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-ratings.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-questions-algorithms.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-submit.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-reconcile.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-corrections.sql
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-v04-rating-notes.sql
PGDATABASE=hilltest HILL_TEST_ADMIN=<admin user> python3 run_tests_v03.py
```

To test the first build alone, apply only `hill-db-phase2.sql` and run `run_tests.py`.

The tests create temporary sign-ins prefixed `test_`, with random one-time passwords, and remove them when they finish.

## Sources

- CERIC-T protocol and decision rules, versions 0.3 and 0.4 (drafts), Higher Learning Lab, November 2026.
- Bjorn, G., & Burgasser, A. J. *How to Critically Read the Scientific Research Literature.* Cambridge University Press.
- HiLL Synthesis Audit Checklist, version 0.1.
- Evidence tiers adapted from the tiers of evidence in the Every Student Succeeds Act (ESSA).
