open! Core
open! Jsonaf.Export

module Counts = struct
  type t =
    { running : int
    ; retrying : int
    ; blocked : int
    }
  [@@deriving sexp_of, jsonaf]
end

module State = struct
  type t =
    { generated_at : Snapshot.Time.t
    ; counts : Counts.t
    ; running : Snapshot.Running.t list
    ; retrying : Snapshot.Retrying.t list
    ; blocked : Snapshot.Blocked.t list
    ; codex_totals : Snapshot.Codex_totals.t
    ; rate_limits : Jsonaf.t option
    }
  [@@deriving sexp_of, jsonaf]
end

module Detail = struct
  type t =
    { issue_identifier : string
    ; issue_id : string
    ; status : string
    ; running : Snapshot.Running.t option
    ; retry : Snapshot.Retrying.t option
    ; blocked : Snapshot.Blocked.t option
    ; last_error : string option
    }
  [@@deriving sexp_of, jsonaf]
end

let decode converter body =
  Or_error.try_with (fun () -> converter (Jsonaf.of_string body))
  |> Or_error.tag ~tag:"invalid dashboard API response"
;;

let decode_state = decode State.t_of_jsonaf
let decode_detail = decode Detail.t_of_jsonaf
