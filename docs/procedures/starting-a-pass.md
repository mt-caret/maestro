# Start a pass

Use this procedure at the start of every fresh or resumed pass.

## Orient

Determine the pass type from the workspace. Do not use the attempt counter because a reactivated
issue can arrive as a fresh dispatch.

```sh
git status && git branch --all
gh pr list --head <your-branch> --state all
```

- If no branch or pull request exists, create a branch named after the issue and implement it.
- If a branch or open pull request exists, resume it. Do not reclone, restart, or open another
  pull request. Follow [`addressing-review-feedback.md`](addressing-review-feedback.md).
- If the work is merged into `main`, confirm it in `git log origin/main` and the pull request
  state. Record that fact in the workpad and move the issue to In Review. Do not redo the work.

## Sync with main

Fetch and rebase before editing. Then validate the rebased baseline.

```sh
git fetch --prune origin
git rebase --autostash origin/main
opam exec -- dune build && opam exec -- dune runtest
```

Resolve conflicts after understanding both sides. If a conflict is genuinely ambiguous, run
`git rebase --abort`. Move the issue to In Review and record the conflicting files and ambiguity
in the workpad.

Always rerun the build and tests after rebasing. A newly merged change can break the branch.
After a rebase, push with `git push --force-with-lease`. Never use a bare `--force`.
