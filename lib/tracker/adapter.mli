(** The tracker adapter boundary: a portable read kernel for scheduling plus optional
    provider-native agent tools (SPEC §11).

    Adapters are plain records of functions built from the effective tracker settings —
    the registry that maps [tracker.kind] to a builder lives in the wiring layer so
    provider libraries can depend on this one. The orchestrator relies only on success
    versus failure of the fetch operations. *)

open! Core
open! Async

module Tool_result : sig
  (** Result of a provider-native dynamic tool call, translated verbatim onto the
      app-server protocol via [jsonaf_of_t]. [output] is a JSON-encoded string;
      [content_items] serializes to the protocol's [contentItems] list. Failures are
      values, not errors — the turn always continues (SPEC §10.5). *)
  type t =
    { success : bool
    ; output : string
    ; content_items : Jsonaf.t list [@key "contentItems"]
    }
  [@@deriving sexp_of, jsonaf_of]

  (** [of_error_message ?extra message] — the conventional failure envelope: output is
      [{"error":{"message":<message>, ...extra}}] pretty-printed, mirrored into one
      [inputText] content item. *)
  val of_error_message : ?extra:(string * Jsonaf.t) list -> string -> t
end

type t =
  { fetch_issues_by_states : string list -> Issue.t list Deferred.Or_error.t
  (** Candidate polling (active states) and startup cleanup (terminal states). Empty input
      returns empty without a provider call. Malformed provider records MAY be dropped
      (logged). *)
  ; fetch_issues_by_ids : string list -> Issue.t list Deferred.Or_error.t
  (** Reconciliation/refresh by opaque dispatch ids. Empty input returns empty without a
      provider call. Ids no longer visible are omitted; malformed requested records MUST
      fail the call instead. *)
  ; secret_environment_names : string list
  (** Environment names the codex launcher removes from the child process. *)
  ; agent_tool_specs : Jsonaf.t list
  (** Tool specs advertised verbatim in the app-server [thread/start] params. *)
  ; execute_agent_tool :
      name:string
      -> arguments:Jsonaf.t
      -> context_issue:Issue.t
      -> Tool_result.t Deferred.t
  (** Executes host-side with the adapter's own credential; the child never sees raw
      tokens. Unknown names return a failure result, never an exception. *)
  ; validate_config : unit -> unit Or_error.t
  (** Dispatch-preflight validation of the adapter's provider settings (SPEC §6.3). *)
  }
