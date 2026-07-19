open! Core
open Maestro_workflow

module Blocker = struct
  type t =
    { id : string option
    ; identifier : string option
    ; state : string option
    }
  [@@deriving sexp_of]
end

type t =
  { id : string
  ; native_ref : Jsonaf.t option
  ; identifier : string
  ; title : string
  ; description : string option
  ; priority : int option
  ; state : string
  ; branch_name : string option
  ; url : string option
  ; assignee_id : string option
  ; labels : string list
  ; blocked_by : Blocker.t list
  ; dispatchable : bool
  ; created_at : Time_ns.t option
  ; updated_at : Time_ns.t option
  }
[@@deriving sexp_of]

let routable t ~required_labels =
  t.dispatchable
  &&
  let labels = List.map t.labels ~f:Config.normalize_state_name |> String.Set.of_list in
  List.for_all required_labels ~f:(fun label ->
    Set.mem labels (Config.normalize_state_name label))
;;
