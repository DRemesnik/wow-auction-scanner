---
name: ah-score-refiner
description: Orchestrates the Challenge -> Arbitrate -> Refine -> Verify loop on AH signal and score logic until convergence.
---

# AH Score Refiner (Optimization Loop)

## Purpose
Execute an iterative, evidence-driven improvement loop for `_evaluate_trade_decision` and `_classify_liquidity` in `src/tracker/dashboard.py`.

## Loop Protocol
1. **Baseline**: Snapshot current signal counts (`КРАФТИТЬ`, `СКУПКА`, `ВЫГОДНО`, `ОСТОРОЖНО`, `НЕЛИКВИД`) and Top-20 `КРАФТИТЬ` / `СКУПКА` items from `data/ah_tracker.sqlite`.
2. **Step A — Challenge** (`ah-score-challenger`):
   - Inspect live DB outputs and generate concrete Challenges (`C1..Cn`) with item IDs and metrics.
3. **Step B — Arbitrate** (`ah-challenge-arbiter`):
   - Score each Challenge (`ACCEPT` vs `REJECT`) with Pros/Cons and Materiality.
   - If **no** Challenges are `ACCEPT`ed -> **STOP (`CONVERGED`)**.
4. **Step C — Refine**:
   - Implement accepted rules cleanly in `src/tracker/dashboard.py` (preserving integer copper math and existing unit test invariants).
   - Add/update tests in `tests/test_dashboard.py` for new guardrails.
5. **Step D — Verify & Measure**:
   - Run tests and compare Before vs After signal distribution & Top-20 quality.
   - If the delta is negligible (`< 2` Top-20 changes or no material precision gain) -> **STOP (`CONVERGED`)**.
   - Otherwise, proceed to the next iteration (max 4 rounds).
6. **Finalize**:
   - Regenerate `data/dashboard.html` and summarize each round's challenges, verdicts, refinements, and convergence reason.
