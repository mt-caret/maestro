(** Shared wire types for the dashboard's read-only HTTP API. *)

open! Core

module Counts : sig
  type t =
    { running : int
    ; retrying : int
    ; blocked : int
    }
  [@@deriving sexp_of, jsonaf]
end

module State : sig
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

module Detail : sig
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

val decode_state : string -> State.t Or_error.t
val decode_detail : string -> Detail.t Or_error.t
