(** Glues the Linear client and agent tool into the generic tracker adapter record
    ([tracker.kind: linear]). *)

open! Core
open! Async

(** [request_fun] is a test seam for the HTTP transport. *)
val create
  :  ?request_fun:Client.request_fun
  -> Maestro_workflow.Config.Tracker.t
  -> Maestro_tracker.Adapter.t
