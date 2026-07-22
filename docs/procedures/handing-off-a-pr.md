# Hand off a pull request

Use this procedure when implementation and feedback work are ready for review.

Run a correctness review, then run the separate style review in `AGENTS.md` § Before handoff. Run:

```sh
opam exec -- dune fmt
opam exec -- dune build
opam exec -- dune runtest
```

Inspect expect-test changes before `dune promote`. Confirm formatting leaves no diff. Keep the
change limited to the assigned issue and all blocking review feedback.

Commit on a branch named after the issue. Match the repository's commit style and end the message
with the required `Co-Authored-By: Claude ...` trailer. Push to `origin`; use
`--force-with-lease` after rebasing.

Open one pull request against `main`, or update the existing pull request. Fill every section of
`.github/pull_request_template.md`: Context, TL;DR, Summary, Alternatives, and Test Plan. Record
considered and rejected approaches in Alternatives.

Update the one workpad comment with the completed plan, validation, style review, notes, review
cursor, and pull request URL. Move the issue to In Review.
