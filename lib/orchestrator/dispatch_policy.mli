(** Pure scheduling decisions: dispatch ordering, eligibility, concurrency slots, and
    retry backoff (SPEC §8.2, §8.3, §8.4). No effects, so these are tested directly. *)

open! Core
open Maestro_tracker

(** Dispatch order (SPEC §8.2): priority [1..4] ascending first (all other integers and
    null after), then oldest [created_at] (null last), then [identifier]
    lexicographically. Stable. *)
val sort_for_dispatch : Issue.t list -> Issue.t list

(** Candidate eligibility ignoring claims/slots: required non-blank fields, state in
    active ∖ terminal, and [routable]. *)
val is_candidate : Maestro_workflow.Config.t -> Issue.t -> bool

(** [available_global_slots ~config ~running_count] = [max(limit - running_count, 0)]. *)
val available_global_slots : config:Maestro_workflow.Config.t -> running_count:int -> int

(** Whether a new run in [state] fits the per-state limit, counting [running_states] (the
    live states of currently-running issues) normalized (SPEC §8.3). *)
val state_slot_available
  :  config:Maestro_workflow.Config.t
  -> state:string
  -> running_states:string list
  -> bool

(** Continuation delay after a clean worker exit: a fixed 1000 ms (SPEC §8.4). *)
val continuation_delay : Time_ns.Span.t

(** Failure backoff for [attempt] (1-based): [min(10s · 2^min(attempt-1, 10), cap)]. *)
val failure_backoff : attempt:int -> cap:Time_ns.Span.t -> Time_ns.Span.t
