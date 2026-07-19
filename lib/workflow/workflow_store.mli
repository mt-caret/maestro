(** Serves the current workflow with change detection and last-known-good fallback (SPEC
    §6.2).

    Change detection is stamp-based ((mtime, size, content digest), so same-size
    same-mtime edits are still caught) and runs both on a 1 s poll and synchronously
    before every read, so reads are never staler than the file. A reload that fails to
    parse or validate keeps the previous good workflow and logs the error; only startup is
    strict. *)

open! Core
open! Async

type t

(** Strict initial load — an invalid WORKFLOW.md fails creation, refusing to boot. *)
val create : path:string -> getenv:(string -> string option) -> t Deferred.Or_error.t

(** The latest good workflow, after a change check. *)
val current : t -> Workflow.Loaded.t Deferred.t

(** Re-check now, surfacing the reload error if the file is currently invalid (the stored
    workflow still remains the last good one). *)
val force_reload : t -> Workflow.Loaded.t Deferred.Or_error.t

(** Stops the background poll. *)
val close : t -> unit
