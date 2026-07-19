(** Prompt construction for agent turns (SPEC §12).

    The first turn renders the workflow's prompt template strictly with [issue] and
    [attempt]; a blank template falls back to the reference's built-in default.
    Continuation turns send only guidance — never the original task prompt, which is
    already in the thread (SPEC §7.1). *)

open! Core
open Maestro_tracker

(** [attempt] is always bound (null on first runs) so strict mode never trips on it.
    Timestamps render as RFC 3339 strings; labels and blockers stay iterable. *)
val issue_template_vars : issue:Issue.t -> attempt:int option -> Jsonaf.t

(** Render failures ([template_parse_error] / [template_render_error]) fail the run
    attempt (SPEC §12.4). *)
val first_turn_prompt
  :  workflow:Maestro_workflow.Workflow.Loaded.t
  -> issue:Issue.t
  -> attempt:int option
  -> string Or_error.t

val continuation_prompt : turn_number:int -> max_turns:int -> string
