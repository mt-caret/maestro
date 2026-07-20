(** Claude Code stream-JSON backend. A session is resumed by id across one subprocess per
    turn. *)

open! Core
open! Async
open Maestro_tracker

module Session : sig
  type t
end

val start_session
  :  config:Maestro_workflow.Config.t
  -> workspace:string
  -> adapter:Adapter.t
  -> on_update:(Update.t -> unit)
  -> Session.t Deferred.Or_error.t

val run_turn : Session.t -> prompt:string -> issue:Issue.t -> unit Deferred.Or_error.t
val stop_session : Session.t -> unit Deferred.t
