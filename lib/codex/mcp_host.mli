(** Host-side execution bridge for Claude Code MCP tools. The stdio proxy receives no
    tracker credential; it forwards calls over a workspace-local socket to this server. *)

open! Core
open! Async
open Maestro_tracker

type t

val create : workspace:string -> adapter:Adapter.t -> t Deferred.Or_error.t
val set_context_issue : t -> Issue.t -> unit
val config : t -> Jsonaf.t
val allowed_tools : t -> string list
val close : t -> unit Deferred.t
