open! Core
open! Jsonaf.Export

(* [Time_ns.t] has no JSON converter; render RFC 3339. ([float] comes from
   [Jsonaf.Export].) *)
module Time = struct
  type t = Time_ns.t

  let sexp_of_t = Time_ns.sexp_of_t

  let jsonaf_of_t time =
    `String (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc)
  ;;
end

module Tokens = struct
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Recent_event = struct
  type t =
    { at : Time.t
    ; event : string
    ; message : string
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Running = struct
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
    ; recent_events : Recent_event.t list
    ; workspace_path : string option
    ; tokens : Tokens.t
    ; runtime_seconds : float
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Retrying = struct
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

module Blocked = struct
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
    ; recent_events : Recent_event.t list
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Codex_totals = struct
  type t =
    { input_tokens : int
    ; output_tokens : int
    ; total_tokens : int
    ; seconds_running : float
    }
  [@@deriving sexp_of, jsonaf_of]
end

module Polling = struct
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
