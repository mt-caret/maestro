(** Shared snapshot protocol types for native status surfaces and web clients. *)

open! Core

module Time : sig
  type t = Time_ns.t [@@deriving sexp_of]

  val jsonaf_of_t : t -> Jsonaf.t
  val t_of_jsonaf : Jsonaf.t -> t
end

module Tokens : sig
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    }
  [@@deriving sexp_of, jsonaf]
end

module Running : sig
  type t =
    { issue_id : string
    ; issue_identifier : string
    ; issue_url : string option
    ; state : string
    ; session_id : string option
    ; turn_count : int
    ; last_event : string option
    ; last_message : string option
    ; started_at : Time.t
    ; last_event_at : Time.t option
    ; workspace_path : string option
    ; tokens : Tokens.t
    ; runtime_seconds : float
    }
  [@@deriving sexp_of, jsonaf]
end

module Retrying : sig
  type t =
    { issue_id : string
    ; issue_identifier : string
    ; issue_url : string option
    ; attempt : int
    ; due_in_ms : int
    ; error : string option
    ; workspace_path : string option
    }
  [@@deriving sexp_of, jsonaf]
end

module Blocked : sig
  type t =
    { issue_id : string
    ; issue_identifier : string
    ; issue_url : string option
    ; state : string option
    ; session_id : string option
    ; error : string option
    ; blocked_at : Time.t
    ; last_event : string option
    ; last_message : string option
    }
  [@@deriving sexp_of, jsonaf]
end

module Codex_totals : sig
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    ; seconds_running : float
    }
  [@@deriving sexp_of, jsonaf]
end

module Polling : sig
  type t =
    { checking : bool
    ; next_poll_in_ms : int option
    ; poll_interval_ms : int
    }
  [@@deriving sexp_of, jsonaf]
end

type t =
  { running : Running.t list
  ; retrying : Retrying.t list
  ; blocked : Blocked.t list
  ; codex_totals : Codex_totals.t
  ; rate_limits : Jsonaf.t option
  ; polling : Polling.t
  }
[@@deriving sexp_of, jsonaf]
