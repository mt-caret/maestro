# Maintain the Linear workpad

Use this procedure when starting work, recording progress, or handing work to review. Use the
injected `linear_graphql` tool for every Linear read and write.

Keep exactly one unresolved issue comment with the header `## Maestro Workpad`. Search the issue
comments for that marker on every pass. Reuse the comment if it exists, or create it once with
`commentCreate`. Update it in place with `commentUpdate`; do not post progress comments or edit the
issue body.

Reconcile the workpad before editing. Tick completed work and update the plan to match the current
scope. Write Notes and Confusions for a reviewer: capture the approach, decisions and rejected
alternatives, surprises, and real ambiguities.

Use this exact structure:

````md
## Maestro Workpad

```text
<hostname>:<abs-workspace-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria

- [ ] Criterion
- [ ] Style self-review per `AGENTS.md` § Before handoff

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <timestamp> approach taken, design decisions and why, anything surprising

### Confusions

- <only when something was genuinely ambiguous or cost real time>

### Review log

- <timestamp> addressed feedback through <newest comment id/timestamp>; rebased onto <short-sha>
````

The Review log entry is the cursor for the next rework pass. Before handoff, tick the current plan,
acceptance criteria, and validation. Add the pull request URL and the latest rebase or feedback
cursor.

Team MTA state IDs are:

- Todo: `e9e6db66-9e98-4db4-a7d2-de2c497e5b4a`
- In Progress: `1a3b34c4-4789-49aa-808e-8ff8e2392176`
- In Review: `54744e70-d483-48e8-bd67-e163b04e89dc`
- Done: `0fe3e18b-2036-4c33-807d-9b777bf61c85`

Use these GraphQL forms, substituting the issue and comment IDs:

```graphql
mutation { issueUpdate(id: "<issue-id>", input: { stateId: "<state-id>" }) { success } }
mutation { commentCreate(input: { issueId: "<issue-id>", body: "<markdown>" }) { success comment { id } } }
mutation { commentUpdate(id: "<comment-id>", input: { body: "<markdown>" }) { success } }
```
