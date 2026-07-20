(** Startup, lifecycle, and shutdown wiring (SPEC §16.1, §17.7).

    Startup order: configure logging → load and validate the workflow (strict) → start the
    orchestrator driver (terminal-workspace sweep, then the first tick) → start the HTTP
    server if enabled → run the TUI if the terminal is interactive. Shutdown (TUI quit or
    SIGINT/SIGTERM) stops the driver and the server with bounded waits. *)

open! Core
open! Async

(** [port] and [host] override [server.port] and [server.host], respectively;
    [memory_issues] backs a [memory] tracker (for tests and local runs). Returns an error
    on startup failure. *)
val run
  :  workflow_path:string
  -> logs_root:string
  -> port:int option
  -> host:string option
  -> reset_scheduler_state:bool
  -> ?memory_issues:(unit -> Maestro_tracker.Issue.t list)
  -> unit
  -> unit Deferred.Or_error.t
