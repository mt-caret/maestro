(** Projects an orchestrator {!Maestro_orchestrator.Snapshot.t} into the HTTP JSON API
    shapes (SPEC §13.7.2). Pure; shared by the HTTP server and any other consumer. *)

open! Core
open Maestro_orchestrator

(** [GET /api/v1/state]: [generated_at] + [counts] + the running/retrying/blocked rows +
    aggregate totals and latest rate limits. *)
val state_payload : Snapshot.t -> generated_at:Time_ns.t -> Jsonaf.t

(** [GET /api/v1/<issue_identifier>]: per-issue runtime detail, or [None] when the issue
    is unknown to the current in-memory state (→ 404). *)
val issue_payload : Snapshot.t -> issue_identifier:string -> Jsonaf.t option

(** [POST /api/v1/refresh] response body. *)
val refresh_response : queued:bool -> coalesced:bool -> requested_at:Time_ns.t -> Jsonaf.t
