(** The interactive bonsai_term dashboard (SPEC §13.4).

    Draws only from orchestrator snapshots pulled through the injected callbacks — never
    required for correctness. Keys: [↑]/[↓] (or [k]/[j]) select a running agent, [r]
    triggers a refresh, [q]/[Esc]/[Ctrl-C] quit. *)

open! Core
open! Async
open Maestro_orchestrator

(** [run] renders until the user quits (or the terminal input closes). [snapshot] is
    pulled on the [refresh] clock and after a manual refresh; [request_refresh] is invoked
    when the operator presses [r]. [dashboard_url] appears in the header when the HTTP
    server is up. Requires a tty. *)
val run
  :  snapshot:(unit -> Snapshot.t Deferred.t)
  -> request_refresh:(unit -> unit Deferred.t)
  -> dashboard_url:string option
  -> refresh:Time_ns.Span.t
  -> unit Deferred.Or_error.t
