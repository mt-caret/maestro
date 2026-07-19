(** The scheduling state machine core (SPEC §7, §8, §16).

    The orchestrator is a single authority over an immutable [State.t]. Each event folds
    the state forward, returning the new state and a list of [Effect.t]s for a driver to
    carry out (spawn a worker, arm a timer, remove a workspace, notify observers). Keeping
    the effects as data — rather than performing them inline — makes the whole machine
    deterministic and testable without real timers or subprocesses. The wiring layer
    supplies a driver that interprets the effects against Async (arming [Clock_ns] timers,
    spawning [Agent_runner] workers, cleaning workspaces). *)

open! Core
open! Async
open Maestro_workflow
open Maestro_tracker
open Maestro_codex

(** Unique, deterministically-minted token for staleness guards on timers and worker runs. *)
module Token : Unique_id.Id

module Worker_outcome : sig
  type t =
    | Completed
    | Failed of string
  [@@deriving sexp_of]
end

module State : sig
  type t [@@deriving sexp_of]

  val create : unit -> t

  (** Issues reserved to prevent duplicate dispatch (running, retry-queued, or blocked). *)
  val claimed : t -> String.Set.t

  (** Bookkeeping only; never gates dispatch (SPEC §7.4). *)
  val completed : t -> String.Set.t
end

module Event : sig
  type t =
    | Tick of { token : Token.t option (** [None] pokes an immediate cycle. *) }
    | Worker_runtime_info of
        { issue_id : string
        ; workspace_path : string
        }
    | Codex_update of
        { issue_id : string
        ; update : Update.t
        }
    | Worker_exited of
        { issue_id : string
        ; run_token : Token.t
        ; outcome : Worker_outcome.t
        }
    | Retry_due of
        { issue_id : string
        ; token : Token.t
        }
  [@@deriving sexp_of]
end

module Effect : sig
  type t =
    | Spawn_worker of
        { issue : Issue.t
        ; attempt : int option
        ; run_token : Token.t
        }
    | Stop_worker of { issue_id : string }
    | Schedule_retry of
        { issue_id : string
        ; delay : Time_ns.Span.t
        ; token : Token.t
        }
    | Remove_workspace of { identifier : string }
    | Schedule_tick of
        { delay : Time_ns.Span.t
        ; token : Token.t
        }
    | Notify
  [@@deriving sexp_of]
end

(** Fold one event into the state, using [config] (the current effective workflow config)
    and [adapter] for tracker reads and [now] for all time arithmetic. Tracker-read
    failures are tolerated per SPEC §11.4 (skip dispatch / keep workers). *)
val handle
  :  State.t
  -> config:Config.t
  -> adapter:Adapter.t
  -> now:Time_ns.t
  -> Event.t
  -> (State.t * Effect.t list) Deferred.t

(** Read-only projection for status surfaces (SPEC §13.3). *)
val to_snapshot : State.t -> config:Config.t -> now:Time_ns.t -> Snapshot.t
