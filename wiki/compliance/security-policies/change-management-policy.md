# Change Management Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Ensure changes to the Grobase platform are authorized, designed, tested, and deployed in a controlled
way that preserves security and the live baseline. (ISO/IEC 27001 Annex A A.8.32, A.8.31, A.5.8;
SOC 2 CC8.1.)

## Policy
- **Authorization & review.** Every change lands via pull request with review; direct pushes to the
  protected baseline are not permitted. Segregation between author and reviewer is the control
  (A.5.3).
- **Testing as acceptance.** New behaviour lands behind a **numbered milestone gate** that actually
  exercises it; a gate that passes vacuously is not a gate. The enterprise gate battery
  (`run-gate-battery.sh --enterprise`) and CI (SAST/SCA/secret/container scans) are blocking.
  Enforced: gate `m143` (matrix completeness/honesty), plus the per-feature gates.
- **Safe-by-default rollout.** Behaviour changes are **flag-gated OFF by default** so the live
  baseline stays byte-parity; risky changes follow **shadow → parity → cutover → delete**, and
  nothing is deleted until all three gates pass (m18 live-traffic discipline + shadow parity +
  CI-green-with-forward). UNKNOWN counts as FAIL.
- **Environment separation.** Dev/test/prod are separated via editions and compose overlays
  (A.8.31); production runs without dev ports and with resource limits.
- **Evidence.** The change-management trail is sealed continuously by the `m108` evidence collector
  — it is part of the SOC 2 sampled population.

## Review
At least annually; the harness itself is versioned with the code it gates.
