# Address review feedback

Use this procedure when an issue returns from human review.

Gather all feedback before editing:

- Read pull request conversation with `gh pr view --comments`.
- Read inline review comments with `gh api repos/mt-caret/maestro/pulls/<number>/comments`.
- Read review summaries with `gh pr view --json reviews`.
- Query Linear for issue comments newer than the cursor in the workpad Review log:

```graphql
query {
  issue(id: "<issue-id>") {
    comments { nodes { id body createdAt user { displayName } } }
  }
}
```

Treat every unresolved item as blocking. Fix it or reply with a concrete reason for pushing back.
Never silently skip feedback. Reply to each addressed pull request thread and resolve it where
possible.

Push the updated branch after all changes. Use `--force-with-lease` if the branch was rebased.
Update the workpad in place: tick the plan, explain what changed in Notes, and append a Review log
entry with the newest feedback handled and the commit rebased onto. Move the issue to In Review.

If there is no outstanding feedback, only rebase and verify. Record the result and cursor in the
workpad, then return the issue to In Review without changing code.
