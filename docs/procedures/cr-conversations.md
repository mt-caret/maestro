# Hold a CR conversation

Use this procedure when an author or reviewer opens, answers, or revisits a code review (CR)
comment embedded in source. The source comment is the conversation record. Do not copy its state
to a review database or a backend-specific skill.

## Forms and ownership

Use one of these forms inside the source file's normal comment syntax:

```text
CR <reporter> [for <target>]: <body>
XCR <reporter> [for <target>]: <body>
CR-soon <reporter> [for <target>]: <body>
XCR-soon <reporter> [for <target>]: <body>
CR-someday <reporter> [for <target>]: <body>
XCR-someday <reporter> [for <target>]: <body>
```

Replace the angle-bracket fields with agent or person names. The `for <target>` field is optional
when the target is clear from the work assignment. Only `soon` and `someday` are supported due
classes. Do not use dates or property-form CRs.

The prefix assigns the next action:

- `CR`, `CR-soon`, and `CR-someday` mean that the target or author must act.
- `XCR`, `XCR-soon`, and `XCR-someday` mean that the original reporter or reviewer must act.

Preserve the reporter's name throughout the conversation. Preserve the body when changing
ownership unless the response needs a short explanation beside it.

## Author steps

1. Discover every outstanding CR comment before editing. Read its surrounding source and identify
   the reporter, target, due class, and requested change.
2. Address each `CR*` owned by you. Make the requested change or explain concretely why the current
   code should remain.
3. Return the conversation to the reporter by changing `CR` to `XCR`. Preserve `-soon` or
   `-someday`. Do not delete the comment yourself.
4. Commit answered comments with the code. Squash merging makes intermediate answer commits
   acceptable.

## Reviewer steps

1. Open a conversation by adding `CR <reporter> for <target>: <body>` beside the relevant source.
   Use `CR-soon` or `CR-someday` only when the author may merge without answering first.
2. Defer an open request by changing `CR` to `CR-soon` or `CR-someday`. Choose `soon` for near-term
   follow-up and `someday` for work with no near-term commitment.
3. Review each `XCR*` returned to you. Delete the whole conversation when the response resolves it.
4. Reopen an unresolved response by changing `XCR` back to the matching `CR`. Preserve the due
   class and explain what remains.
5. Escalate deferred work that must block the current change by changing `XCR-soon` or
   `XCR-someday` to ordinary `CR`. Explain why it is now required.
6. Commit opened, resolved, reopened, or escalated comments normally. The pull request is expected
   to squash-merge.

Deleting an `XCR*` is the reporter's resolution action. An author must not treat an unanswered
`XCR*` as resolved.

## Discover conversations

No specialized review service is required. Search the working tree directly:

```sh
rg -n --pcre2 '\bX?CR(?:-(?:soon|someday))?\s+[^:]+:' \
  --glob '!docs/procedures/cr-conversations.md' \
  --glob '!test/fixtures/**'
```

Inspect every match. The exclusions above are narrow: this canonical document contains protocol
examples, and dedicated fixtures may contain intentional matches. Do not exclude broad source,
test, or documentation directories. Use `git grep -nE` with the equivalent pattern when `rg` is
not available.

## Decide whether a pull request can merge

The current owner and due class determine whether a comment blocks merging:

| Form | Next action | Blocks merge |
|---|---|---|
| `CR` | target or author | yes |
| `XCR` | reporter or reviewer | yes |
| `CR-soon` | target or author | no |
| `XCR-soon` | reporter or reviewer | yes |
| `CR-someday` | target or author | no |
| `XCR-someday` | reporter or reviewer | yes |

Configure a GitHub required check to run the source search and fail while any blocking form
remains. It must detect ordinary `CR` and every `XCR` due class. Exclude only the canonical
protocol examples and dedicated fixtures that intentionally exercise the syntax. Keep deferred
`CR-soon` and `CR-someday` visible in search results even though they do not fail the check.

For example, the check can fail on matches from this blocking-only search:

```sh
rg -n --pcre2 '\b(?:CR|XCR(?:-(?:soon|someday))?)\s+[^:]+:' \
  --glob '!docs/procedures/cr-conversations.md' \
  --glob '!test/fixtures/**'
```

Invert the command's normal success result in the check: a match must fail the job, while no match
must pass it.

## Examples

### Ordinary resolution

The reviewer opens a blocking conversation:

```text
CR Rowan for Ari: Reject an empty tracker identifier here.
```

After changing the code, Ari returns ownership without changing the due class:

```text
XCR Rowan for Ari: Reject an empty tracker identifier here.
```

Rowan verifies the change and deletes the comment.

### Reopening

The author returns a response:

```text
XCR Rowan for Ari: Keep this allocation; the value escapes into the Async job.
```

The reviewer disagrees and reopens it:

```text
CR Rowan for Ari: The job copies the identifier first. Remove the allocation here.
```

### Deferred response

The reviewer records nonblocking follow-up work:

```text
CR-soon Rowan for Ari: Share this parser with the second adapter.
```

The author implements it later and returns the same due class:

```text
XCR-soon Rowan for Ari: Share this parser with the second adapter.
```

The returned `XCR-soon` blocks until Rowan verifies and deletes it or reopens it.

### Escalation

A deferred response is waiting for review:

```text
XCR-someday Rowan for Ari: Add an integration test for cancellation during startup.
```

Rowan finds that the current change depends on that coverage and escalates it:

```text
CR Rowan for Ari: Add the integration test now; this change modifies startup cancellation.
```

The ordinary `CR` assigns the next action to Ari and blocks the merge.
