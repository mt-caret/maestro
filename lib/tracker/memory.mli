(** In-memory tracker adapter ([tracker.kind: memory]) for deterministic tests and local
    experimentation.

    Serves whatever [issues] returns at call time (a closure so tests can update the
    backing list between polls), preserving its order. State matching is
    case/whitespace-insensitive; id matching is exact. No secrets, no tools. *)

open! Core

val create : issues:(unit -> Issue.t list) -> Adapter.t
