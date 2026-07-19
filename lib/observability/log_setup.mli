(** Configures the global Async log to a rotating file, keeping the terminal free for the
    status surface (SPEC §13.1, §13.2).

    Required context conventions: issue logs carry [issue_id] and [issue_identifier];
    coding-agent session logs carry [session_id]. Those are supplied at the log sites via
    ppx_log; this module only owns sink configuration. *)

open! Core
open! Async

(** Points [Log.Global] at [<logs_root>/log/maestro.log] with size-based rotation (10 MB ×
    5), replacing any console output so the dashboard owns the screen. Creates the log
    directory if needed. *)
val configure : logs_root:string -> unit Deferred.t

(** Directs [Log.Global] to stderr — for headless runs without a dashboard. *)
val configure_stderr : unit -> unit
