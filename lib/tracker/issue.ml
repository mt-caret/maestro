open! Core
open Maestro_workflow

module Blocker = struct
  type t =
    { id : string option
    ; identifier : string option
    ; state : string option
    }
  [@@deriving sexp_of]

  module Stable = struct
    module V1 = struct
      type t =
        { id : string option
        ; identifier : string option
        ; state : string option
        }
      [@@deriving bin_io, sexp, stable_witness]
    end
  end
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

module Stable = struct
  module V1 = struct
    type t =
      { id : string
      ; native_ref : string option
      ; identifier : string
      ; title : string
      ; description : string option
      ; priority : int option
      ; state : string
      ; branch_name : string option
      ; url : string option
      ; assignee_id : string option
      ; labels : string list
      ; blocked_by : Blocker.Stable.V1.t list
      ; dispatchable : bool
      ; created_at : Time_ns.Stable.V1.t option
      ; updated_at : Time_ns.Stable.V1.t option
      }
    [@@deriving bin_io, sexp, stable_witness]
  end
end

let to_stable_v1 t : Stable.V1.t =
  { id = t.id
  ; native_ref = Option.map t.native_ref ~f:Jsonaf.to_string
  ; identifier = t.identifier
  ; title = t.title
  ; description = t.description
  ; priority = t.priority
  ; state = t.state
  ; branch_name = t.branch_name
  ; url = t.url
  ; assignee_id = t.assignee_id
  ; labels = t.labels
  ; blocked_by =
      List.map t.blocked_by ~f:(fun blocker ->
        { Blocker.Stable.V1.id = blocker.id
        ; identifier = blocker.identifier
        ; state = blocker.state
        })
  ; dispatchable = t.dispatchable
  ; created_at = t.created_at
  ; updated_at = t.updated_at
  }
;;

let of_stable_v1 (t : Stable.V1.t) =
  Or_error.try_with (fun () ->
    { id = t.id
    ; native_ref = Option.map t.native_ref ~f:Jsonaf.of_string
    ; identifier = t.identifier
    ; title = t.title
    ; description = t.description
    ; priority = t.priority
    ; state = t.state
    ; branch_name = t.branch_name
    ; url = t.url
    ; assignee_id = t.assignee_id
    ; labels = t.labels
    ; blocked_by =
        List.map t.blocked_by ~f:(fun blocker ->
          { Blocker.id = blocker.id
          ; identifier = blocker.identifier
          ; state = blocker.state
          })
    ; dispatchable = t.dispatchable
    ; created_at = t.created_at
    ; updated_at = t.updated_at
    })
;;

let routable t ~required_labels =
  t.dispatchable
  &&
  let labels = List.map t.labels ~f:Config.normalize_state_name |> String.Set.of_list in
  List.for_all required_labels ~f:(fun label ->
    Set.mem labels (Config.normalize_state_name label))
;;
