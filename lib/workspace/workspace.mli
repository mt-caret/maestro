(** Per-issue workspace lifecycle: sanitized keys, containment-checked paths, creation
    with reuse, and cleanup (SPEC §9).

    Workspaces are deliberately preserved across runs; only terminal issues get cleaned up
    (by the orchestrator's startup sweep and reconciliation). *)

open! Core
open! Async

(** Derives the workspace directory name from an issue identifier: characters outside
    [A-Za-z0-9._-] are replaced with [_], and iff that changed anything, a [--]-joined
    16-hex-char SHA-256 prefix of the original identifier is appended, keeping distinct
    identifiers that sanitize alike collision-resistant (SPEC §4.2). *)
val key : identifier:string -> string

(** [path ~root ~identifier] is [<root>/<key identifier>], not yet validated. *)
val path : root:string -> identifier:string -> string

module Created : sig
  type t =
    { path : string (** Canonical workspace path. *)
    ; created_now : bool
    }
  [@@deriving sexp_of]
end

(** Ensures the workspace directory for [identifier] exists under [config.workspace.root],
    enforcing containment first. An existing directory is reused as-is; non-directory
    debris is replaced; a fresh directory runs the [after_create] hook, whose failure
    removes the just-created directory and fails the call (SPEC §9.3 allows removing a
    partially prepared new workspace). *)
val create_for_issue
  :  config:Maestro_workflow.Config.t
  -> identifier:string
  -> Created.t Deferred.Or_error.t

(** Removes the workspace for [identifier] if it exists, running the [before_remove] hook
    best-effort first (its failure never blocks removal). Containment is enforced before
    deleting anything. *)
val remove_for_issue
  :  config:Maestro_workflow.Config.t
  -> identifier:string
  -> unit Deferred.Or_error.t
