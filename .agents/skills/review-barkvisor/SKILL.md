---
name: review-barkvisor
description: Review a BarkVisor candidate against its supplied base revision when Closeout requests independent review.
---

Review the supplied base and candidate commits without changing the implementation. Read CONTEXT.md for BarkVisor's Home, Device, and Workload concepts.

Trace changed behavior through its callers and tests. Check authentication and authorization, pairing and Home login boundaries, Device-specific workload placement, filesystem and process operations, database migrations, and platform-specific Swift paths when the change touches them. Check that frontend behavior agrees with the API and that tests exercise the affected behavior.

For user-facing changes, assess the evidence produced with the repository's verify-barkvisor skill against the requested behavior. Report a missing or contradicted observation when it leaves a concrete failure unverified.

Return findings with severity, location, explanation, and supporting evidence. Use P0 for critical failures, P1 for defects that must be fixed before acceptance, P2 for ordinary defects, and P3 for minor defects. Tie each finding to the candidate and a reachable failure. Return an empty findings array when there are no findings. The Closeout runner decides acceptance from the findings.
