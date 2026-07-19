(** Linear GraphQL client: transport, scheduling reads, and normalization (adapter profile
    in README; SPEC §11).

    Scope is a Linear project selected by [project_slug]; candidate reads filter
    server-side by project + state names with cursor pagination (page size 50), and id
    refreshes are project-scoped batches of 50 re-sorted to request order. Assignee
    scoping is client-side via [Issue.dispatchable]. *)

open! Core
open! Async
open Maestro_tracker

module Settings : sig
  type t [@@deriving sexp_of]

  (** Reads [endpoint]/[api_key]/[project_slug]/[assignee] from the resolved provider map,
      plus the configured terminal states (needed to derive blocker-based
      dispatchability). Missing values surface at request/validation time, not here. *)
  val of_tracker_config : Maestro_workflow.Config.Tracker.t -> t

  val validate : t -> unit Or_error.t
end

module Client_error : sig
  type t =
    | Missing_api_token
    | Missing_project_slug
    | Missing_viewer_identity
    | Api_status of int
    | Api_request of string
    | Graphql_errors of Jsonaf.t
    | Unknown_payload
    | Missing_end_cursor
  [@@deriving sexp_of]

  (** Maps onto the reference's stable error atoms ([missing_linear_api_token], …). *)
  val to_error : t -> Error.t
end

module Request : sig
  type t =
    { endpoint : string
    ; headers : (string * string) list
    ; body : string
    }
  [@@deriving sexp_of]
end

(** Returns HTTP status and response body. The default implementation POSTs with
    cohttp-async under a 120 s overall deadline. *)
type request_fun = Request.t -> (int * string) Deferred.Or_error.t

val default_request_fun : request_fun

(** Raw GraphQL entry point (also the backing of the [linear_graphql] agent tool). An HTTP
    200 returns the decoded body as-is; GraphQL-level errors are the caller's to
    interpret. *)
val graphql
  :  ?operation_name:string
  -> ?request_fun:request_fun
  -> settings:Settings.t
  -> query:string
  -> variables:Jsonaf.t
  -> unit
  -> (Jsonaf.t, Client_error.t) Result.t Deferred.t

(** Candidate polling. Malformed provider records are dropped (logged); empty input
    short-circuits without a request. *)
val fetch_issues_by_states
  :  ?request_fun:request_fun
  -> settings:Settings.t
  -> string list
  -> (Issue.t list, Client_error.t) Result.t Deferred.t

(** Id refresh. Any malformed requested record fails the whole call ([Unknown_payload]);
    results are re-sorted to request order; empty input short-circuits. *)
val fetch_issues_by_ids
  :  ?request_fun:request_fun
  -> settings:Settings.t
  -> string list
  -> (Issue.t list, Client_error.t) Result.t Deferred.t
