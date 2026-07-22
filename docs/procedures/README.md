# Agent procedures

These documents are the canonical instructions for situational agent work. `WORKFLOW.md`
links to them by trigger and keeps only policy in its prompt.

We use plain repository documents instead of Codex skills. Maestro is adding pluggable agent
backends, and each backend has a different skill system. Repository documents give Codex, Claude
Code, and future backends the same instructions through ordinary file tools. Trigger links in the
prompt preserve on-demand loading without duplicating the procedure text.

Thin backend-specific skill wrappers may point to these documents later. A wrapper must not copy
the procedure, because each instruction must have one canonical home.

Read the document that matches the current trigger:

- Start or resume a pass: [`starting-a-pass.md`](starting-a-pass.md).
- Record or reconcile progress: [`maintaining-the-workpad.md`](maintaining-the-workpad.md).
- Resume work after human review: [`addressing-review-feedback.md`](addressing-review-feedback.md).
- Hand completed work to a reviewer: [`handing-off-a-pr.md`](handing-off-a-pr.md).
