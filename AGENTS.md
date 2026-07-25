# Development style

These instructions apply to the whole repository except `vendor/symphony`, which is vendored
upstream code. Follow the more specific conventions in a subdirectory if it has its own
`AGENTS.md`.

## OCaml

- Use Jane Street house style. Match nearby code when it gives a more specific example.
- Start modules with `open! Core`. Also use `open! Async` in modules that use Async.
- Add an `.mli` for every non-wrapper library module. Keep interfaces small.
- Prefer Jane Street libraries and the `ppx_jane` family to handwritten boilerplate. In
  particular, derive standard functions such as comparison, sexp conversion, and fields when
  the generated interface fits the module.
- Use `Time_ns` and `Clock_ns` for time. Thread expected failures through `Or_error`.
- Use `ppx_jsonaf_conv` for JSON conversion. Use `[%string]` for string interpolation and
  `print_s` for diagnostic output instead of `printf`.
- Preserve the layering in `PLAN.md`. Do not make a lower-level library depend on a higher-level
  one to save a small amount of code.

## Documentation

- Use short, direct sentences and common words. State the action or result before background
  details.
- Keep one idea in each sentence when practical. Avoid idioms, unnecessary abbreviations, and
  several names for the same concept.
- Explain unfamiliar terms on first use. Use active voice when the actor matters.
- Keep comments focused on intent, invariants, or a non-obvious constraint. Do not restate the
  code.
- Update nearby documentation when a behavior, interface, or operational requirement changes.

## Dependencies

- After changing dependencies in `maestro.opam`, regenerate `maestro.opam.locked` with
  `opam lock ./maestro.opam` and commit both files.

## Before handoff

Review the diff once for style, separate from the correctness review:

1. Check that new OCaml follows the rules above and uses an existing Jane Street abstraction or
   PPX where it makes the code smaller and clearer.
2. Check that public modules have a focused interface and remain in the correct layer.
3. Read new user-facing text once for simple and consistent language.
4. Run `opam exec -- dune fmt`, `opam exec -- dune build`, and
   `opam exec -- dune runtest`.
