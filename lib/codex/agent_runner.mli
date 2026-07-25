(** One worker run for one issue: workspace, hooks, app-server session, and the in-process
    multi-turn loop (SPEC §10.7, §16.5).

    The run holds one live session for its whole lifetime. Turn 1 sends the rendered
    workflow prompt; later turns send continuation guidance only. After each successful
    turn the issue is re-fetched: the loop continues while it remains in an active state
    and routable, up to [agent.max_turns] (reaching the cap is a normal exit — the
    orchestrator's continuation retry re-checks the issue about a second later).

    Any failure — workspace, hook, startup, turn, render, or refresh — fails the attempt
    for the orchestrator to retry. [after_run] always executes best-effort, and the
    session is always stopped, with bounded waits throughout.

    Config and workflow are dispatch-time snapshots: a WORKFLOW.md reload applies to
    future runs, never mid-run (SPEC §6.2, §10.5). *)

open! Core
open! Async
open Maestro_tracker

module Backend : sig
  type t = Maestro_workflow.Config.Agent.Backend.t =
    | Codex
    | Claude_code
  [@@deriving sexp_of, equal]

  (** Backend labels override the workflow default. [agent:claude] takes precedence if
      both labels are present. *)
  val for_issue : config:Maestro_workflow.Config.t -> Issue.t -> t
end

(** [stop], when determined, stops the live session (killing the subprocess) and ends the
    run — used by the orchestrator to terminate a worker on reconciliation. *)
val run
  :  ?stop:unit Deferred.t
  -> config:Maestro_workflow.Config.t
  -> workflow:Maestro_workflow.Workflow.Loaded.t
  -> adapter:Adapter.t
  -> issue:Issue.t
  -> attempt:int option
  -> on_update:(Update.t -> unit)
  -> on_runtime_info:(workspace_path:string -> unit)
  -> unit
  -> unit Deferred.Or_error.t
