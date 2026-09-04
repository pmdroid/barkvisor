# Setup dialog redesign proposals

Three Kimi-k3 design directions for the first-run setup wizard. Open any file in a
browser — each is a self-contained, clickable prototype (welcome → admin → catalog →
ready, plus the join path). All three drop the removed network-bridge step and use
the Home/Device terminology.

| File | Direction | Signature |
|------|-----------|-----------|
| [setup-a.html](setup-a.html) | Refined classic | Centered card, labeled step dots, selectable path cards |
| [setup-b.html](setup-b.html) | Split hero | Brand pane with value props + form pane with step rail |
| [setup-c.html](setup-c.html) | Ops checklist | Commissioning checklist rail, monospace session strip |

Pick one and the chosen direction gets implemented against `SetupView.vue`
(`frontend/src/views/SetupView.vue`), replacing the current wizard including its
capability-gated bridge step.

This directory is a retained design archive; the implemented setup flow lives in
`frontend/src/views/SetupView.vue`, which follows the chosen direction here. The
prototypes are kept for reference and are not part of the build.
