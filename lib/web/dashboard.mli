(** Bonsai dashboard components. The view is a projection of API data and owns no
    orchestrator state. *)

open! Core
open Bonsai_web

val view
  :  Maestro_snapshot.Http_api.State.t
  -> selected:string option
  -> detail:Maestro_snapshot.Http_api.Detail.t Or_error.t option
  -> select:(string -> unit Effect.t)
  -> Vdom.Node.t

val component
  :  Maestro_snapshot.Http_api.State.t Bonsai.t
  -> fetch_detail:(string -> Maestro_snapshot.Http_api.Detail.t Or_error.t Effect.t)
  -> local_ Bonsai.graph
  -> Vdom.Node.t Bonsai.t
