(** Symlink-resolving path canonicalization and workspace-containment checks (SPEC §9.5).

    Canonicalization resolves symlinks segment by segment and tolerates a nonexistent
    suffix (workspaces are validated before they are created), so it is usable on paths
    that do not exist yet. *)

open! Core
open! Async

(** [canonicalize path] requires an absolute [path]. Fails with [path_canonicalize_failed]
    on unreadable segments or symlink cycles. *)
val canonicalize : string -> string Deferred.Or_error.t

(** Checks that [workspace] stays strictly inside [root] after canonicalizing both,
    returning the canonical workspace path. Failures distinguish [workspace_equals_root],
    [workspace_symlink_escape] (lexically inside, escapes via a symlink), and
    [workspace_outside_root]. *)
val validate_workspace_path
  :  workspace:string
  -> root:string
  -> string Deferred.Or_error.t
