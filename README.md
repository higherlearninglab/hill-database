# HiLL database

The database behind the Higher Learning Lab Evidence Tracker on AI, learning and attachment, and HiLL's funding records.

This repository holds the structure only. It contains no study data, no coding results and no passwords.

## What it guarantees

The database enforces these rules itself, so they do not depend on any person or AI agent following instructions.

1. **Appraisal is human.** AI agents can prepare packets of quoted passages, pre-fill factual fields and raise flags. They cannot write a CERIC-T signalling answer, an element evaluation, a rationale, a rating, a severity, the CER summary answer or the Evidence tier.
2. **Blind double-coding.** Each coder sees only their own answers on a claim until both coders have submitted.
3. **Submitted codings are locked.** Later changes go through reconciliation, with a recorded reason.
4. **Every departure from the rules is explained.** If a coder's evaluation of an element differs from the one the rules propose, an override note is required.
5. **No incomplete records.** A coding cannot be submitted without every answer, five evaluations and five rationales, the CER summary answer and the Evidence tier.
6. **"Not applicable" only where the protocol allows it.**
7. **Nothing is public without the lead's approval of a release.**
8. **Ratings stay held** until the rubric reaches version 1.0 and the lead turns them on.
9. **Full history.** Every change is recorded in an append-only log.
10. **Every coding records the protocol version it was coded under.** Questions are stored per version, so a coding stays tied to the questions it used.
11. **Agent pre-fills in synthesis audits must be confirmed by a human** before the audit can be submitted.
12. **No one settles a disagreement on their own coding.**
13. **Ratings are derived, not chosen.** Under CERIC-T v0.3 the database derives each rating and its severity from the element evaluations, the CER summary and the answers. A coder cannot set or override them.

## The rating scale (CERIC-T v0.3, draft)

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

CERIC-T v0.3 is a draft. It has not been piloted, and calibration may change these rules.

## Files

Apply the four scripts in this order.

| File | What it is |
|---|---|
| `hill-db-phase2.sql` | The first build: roles, tables, the CERIC-T v0.2 rule functions, safeguards and public views, plus reference data: the 36 v0.2 questions and 43 Synthesis Audit Checklist items by code, and the 22 vulnerable-student categories |
| `hill-db-v03.sql` | CERIC-T v0.3: 42 questions by code, stored per protocol version; the CER summary and the Evidence tier; the half rule; reconciliation of the CER summary and the tier; publication status |
| `hill-db-rating-scale.sql` | The five-rating scale and its rules; the derived "falls short at" line; the overall result is named a rating throughout |
| `hill-db-no-rating-override.sql` | Under v0.3 a coder cannot set or override the rating or severity |
| `run_tests_v03.py` | 172 automated tests of the database as it is now: 48 rule scenarios, and a test of every safeguard above, run by signing in as each role |
| `test-results-2026-11-10.txt` | Results of those tests |
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
PGDATABASE=hilltest HILL_TEST_ADMIN=<admin user> python3 run_tests_v03.py
```

To test the first build alone, apply only `hill-db-phase2.sql` and run `run_tests.py`.

The tests create temporary sign-ins prefixed `test_`, with random one-time passwords, and remove them when they finish.

## Sources

- CERIC-T protocol and decision rules, version 0.3 (draft), Higher Learning Lab, November 2026.
- Bjorn, G., & Burgasser, A. J. *How to Critically Read the Scientific Research Literature.* Cambridge University Press.
- HiLL Synthesis Audit Checklist, version 0.1.
- Evidence tiers adapted from the tiers of evidence in the Every Student Succeeds Act (ESSA).
