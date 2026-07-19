(** The single provider-native dynamic tool [linear_graphql]: raw GraphQL passthrough
    executed host-side with Symphony's configured auth (SPEC §10.5, §11.5).

    Full mutation capability by design — scope guards, idempotency, and retries belong to
    the workflow prompt, not this tool. The coding-agent child never sees the API key; it
    sees tool results. *)

open! Core
open! Async
open Maestro_tracker

val name : string

(** Advertised verbatim in the app-server [thread/start] dynamicTools list. *)
val spec : Jsonaf.t

(** [arguments] is either a raw query string or an object with a non-blank [query] and
    optional object [variables]. All failures — bad arguments, missing auth, transport,
    GraphQL-level errors — come back as failure results with the reference's exact
    messages; this never raises and never stalls the session. *)
val execute
  :  ?request_fun:Client.request_fun
  -> settings:Client.Settings.t
  -> name:string
  -> arguments:Jsonaf.t
  -> unit
  -> Adapter.Tool_result.t Deferred.t
