(** A synchronous, read-only projection of orchestrator state for status surfaces (SPEC
    §13.3). Derived from state only; never required for correctness.

    Types derive [jsonaf_of] with protocol field names so the HTTP presenter serializes
    them directly; [sexp_of] backs expect tests. *)

open! Core

(** RFC 3339 timestamp carrying JSON and sexp converters (a transparent [Time_ns.t]). *)
module Time : sig
  type t = Time_ns.t

  val sexp_of_t : t -> Sexp.t
  val jsonaf_of_t : t -> Jsonaf.t
end

module Tokens : sig
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    }
  [@@deriving sexp_of, jsonaf_of]
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
  [@@deriving sexp_of, jsonaf_of]
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
  [@@deriving sexp_of, jsonaf_of]
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
  [@@deriving sexp_of, jsonaf_of]
end

module Codex_totals : sig
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    ; seconds_running : float
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Polling : sig
  type t =
    { checking : bool
    ; next_poll_in_ms : int option
    ; poll_interval_ms : int
    }
  [@@deriving sexp_of, jsonaf_of]
end

type t =
  { running : Running.t list
  ; retrying : Retrying.t list
  ; blocked : Blocked.t list
  ; codex_totals : Codex_totals.t
  ; rate_limits : Jsonaf.t option
  ; polling : Polling.t
  }
[@@deriving sexp_of, jsonaf_of]
