(** The OPTIONAL HTTP observability API and dashboard (SPEC §13.7).

    Read-only except for the [/refresh] trigger; never required for orchestrator
    correctness. Binds loopback by default. All state comes through the injected callbacks
    so the server has no direct handle on orchestrator internals. *)

open! Core
open! Async
open Maestro_orchestrator

module Refresh_result : sig
  type t =
    | Queued of { coalesced : bool }
    | Unavailable
end

type t

(** Starts the server. [port] [0] requests an ephemeral port (see {!bound_port}).
    [snapshot] and [request_refresh] are called per request. *)
val start
  :  host:string
  -> port:int
  -> snapshot:(unit -> Snapshot.t Deferred.t)
  -> request_refresh:(unit -> Refresh_result.t Deferred.t)
  -> t Deferred.Or_error.t

(** The actual bound TCP port (meaningful when [port = 0]). *)
val bound_port : t -> int

val close : t -> unit Deferred.t
