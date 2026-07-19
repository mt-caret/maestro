(** The pure view of the terminal dashboard: an orchestrator snapshot plus UI state
    rendered to a {!Bonsai_term.View.t} (SPEC §13.4, driven from orchestrator state only).
    Separated from the Bonsai wiring so it is testable via [Bonsai_term_test.print_view]. *)

open! Core
open Bonsai_term
open Maestro_orchestrator

module Model : sig
  type t =
    { snapshot : Snapshot.t
    ; selected : int (** Index into the running rows; clamped when rendering. *)
    ; dashboard_url : string option (** Shown in the header when the HTTP server is up. *)
    }
end

(** The number of selectable running rows, for the driver's selection arithmetic. *)
val selectable_count : Model.t -> int

val view : Model.t -> dimensions:Dimensions.t -> View.t
