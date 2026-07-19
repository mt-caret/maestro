(** One-line human-readable summaries of Codex update events (SPEC §13.6).

    Observability-only: orchestrator logic never depends on these strings. Output is
    stripped of control/ANSI bytes and capped at 140 characters. *)

open! Core

val summarize : Update.t -> string
