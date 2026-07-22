(** Codex app-server stdio client (SPEC §10; wire protocol per the reference
    implementation).

    Framing is newline-delimited JSON objects with no [jsonrpc] field. The client sends
    exactly three request shapes — [initialize] (id 1), [thread/start] (id 2), and
    [turn/start] (id 3, reused across turns of one session) — plus responses to
    server-initiated requests (approvals, dynamic tool calls, user-input questions).

    Trust posture (documented per SPEC §10.5): approvals are auto-granted only when
    [codex.approval_policy] is the literal string ["never"]; otherwise an approval request
    hard-fails the turn. [item/tool/requestUserInput] is always answered — with an
    approve-ish option label when auto-approving, else with a canned non-interactive
    notice. MCP elicitations and needs-input turn signals fail the turn so runs never
    stall (the orchestrator then parks the issue as blocked). Dynamic tool calls execute
    host-side through the adapter regardless of policy and always continue the turn.

    The child's stderr is consumed on its own reader as diagnostics and never enters the
    protocol parser (SPEC §10.3; the reference merges the streams — PLAN.md §7). Secret
    environment names are removed from the child environment at spawn and additionally
    [unset] after [bash -l] profile loading. *)

open! Core
open! Async
open Maestro_tracker

module Session : sig
  type t

  val thread_id : t -> string
  val pid : t -> Pid.t
end

(** Launches [codex.command] via [bash -lc] in [workspace] (already containment-validated
    by the caller), runs the initialize/thread-start handshake, and advertises the
    adapter's tool specs. Each awaited response is bounded by [codex.read_timeout]. When
    [session_log_dir] is present, the client records client/server protocol lines and
    stderr there. Capture and retention failures are ignored. *)
val start_session
  :  config:Maestro_workflow.Config.t
  -> workspace:string
  -> session_log_dir:string option
  -> adapter:Adapter.t
  -> on_update:(Update.t -> unit)
  -> Session.t Deferred.Or_error.t

(** Runs one turn to completion. [Ok ()] means the protocol reported [turn/completed];
    errors distinguish [turn_failed], [turn_cancelled], [turn_input_required],
    [approval_required], [turn_timeout] (wall-clock cap over the whole turn, SPEC §10.6),
    and [port_exit]. [issue] supplies the turn title and the context passed to dynamic
    tool execution. *)
val run_turn : Session.t -> prompt:string -> issue:Issue.t -> unit Deferred.Or_error.t

(** Closes stdio and kills the subprocess (SIGKILL floor); bounded wait. *)
val stop_session : Session.t -> unit Deferred.t
