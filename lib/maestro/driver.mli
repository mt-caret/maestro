(** Drives the orchestrator engine against Async: a single event-loop consumer folds
    {!Maestro_orchestrator.Orchestrator.handle} over an event pipe and interprets the
    resulting effects — spawning {!Maestro_codex.Agent_runner} workers, arming [Clock_ns]
    timers, cleaning workspaces, and poking snapshot observers.

    This is the "single authority" of SPEC §7.4: all state mutation happens in the one
    consumer, so there are no races on the orchestrator state. *)

open! Core
open! Async
open Maestro_orchestrator

type t

(** Starts the loop: runs startup terminal-workspace cleanup, then schedules the first
    tick. [config] and [workflow] are re-read from [workflow_store] each tick so reloads
    take effect. [make_adapter] builds the tracker adapter from the current tracker config
    (snapshotted per worker session). [logs_root] holds best-effort per-issue Codex
    session transcripts. *)
val start
  :  workflow_store:Maestro_workflow.Workflow_store.t
  -> make_adapter:
       (Maestro_workflow.Config.Tracker.t -> Maestro_tracker.Adapter.t Or_error.t)
  -> logs_root:string
  -> t Deferred.Or_error.t

(** A current snapshot for status surfaces. *)
val snapshot : t -> Snapshot.t Deferred.t

(** Queues an immediate poll+reconcile cycle (the HTTP [/refresh] and TUI [r] trigger). *)
val request_refresh : t -> Maestro_http.Http_server.Refresh_result.t Deferred.t

(** Fires [f] after each state change (for observers to re-pull a snapshot). *)
val on_change : t -> f:(unit -> unit) -> unit

(** Stops the loop and any pending timers. *)
val close : t -> unit Deferred.t
