(** Workspace lifecycle hook execution (SPEC §9.4).

    Hooks run as [sh -lc <script>] with the workspace as cwd and no injected environment
    variables — context arrives via cwd only, as in the reference. Failure semantics
    (fatal vs. logged-and-ignored) belong to callers: [run] reports failures as errors;
    [run_best_effort] logs and swallows them. *)

open! Core
open! Async

(** [run ~name ~script ~workspace ~timeout] fails with [workspace_hook_failed] (carrying
    the exit status and combined output) or [workspace_hook_timeout]. On timeout the hook
    process group receives SIGKILL — the wait is bounded and no orphan survives. *)
val run
  :  name:string
  -> script:string
  -> workspace:string
  -> timeout:Time_ns.Span.t
  -> unit Deferred.Or_error.t

(** [run] with failures and timeouts logged and ignored (for [after_run] and
    [before_remove]). *)
val run_best_effort
  :  name:string
  -> script:string
  -> workspace:string
  -> timeout:Time_ns.Span.t
  -> unit Deferred.t
