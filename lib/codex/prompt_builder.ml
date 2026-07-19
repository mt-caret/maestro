open! Core
open Maestro_tracker
open Maestro_template

(* The reference's built-in fallback when the workflow prompt body is blank. *)
let default_template =
  String.concat_lines
    [ "You are working on an issue from the configured tracker."
    ; ""
    ; "Identifier: {{ issue.identifier }}"
    ; "Title: {{ issue.title }}"
    ; ""
    ; "Body:"
    ; "{% if issue.description %}"
    ; "{{ issue.description }}"
    ; "{% else %}"
    ; "No description provided."
    ; "{% endif %}"
    ]
;;

let jsonaf_of_string_option = function
  | Some value -> `String value
  | None -> `Null
;;

let jsonaf_of_time = function
  | Some time -> `String (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc)
  | None -> `Null
;;

let issue_template_vars ~(issue : Issue.t) ~attempt : Jsonaf.t =
  let blocker (blocker : Issue.Blocker.t) =
    `Object
      [ "id", jsonaf_of_string_option blocker.id
      ; "identifier", jsonaf_of_string_option blocker.identifier
      ; "state", jsonaf_of_string_option blocker.state
      ]
  in
  `Object
    [ ( "issue"
      , `Object
          [ "id", `String issue.id
          ; "native_ref", Option.value issue.native_ref ~default:`Null
          ; "identifier", `String issue.identifier
          ; "title", `String issue.title
          ; "description", jsonaf_of_string_option issue.description
          ; ( "priority"
            , match issue.priority with
              | Some priority -> `Number (Int.to_string priority)
              | None -> `Null )
          ; "state", `String issue.state
          ; "branch_name", jsonaf_of_string_option issue.branch_name
          ; "url", jsonaf_of_string_option issue.url
          ; "assignee_id", jsonaf_of_string_option issue.assignee_id
          ; "labels", `Array (List.map issue.labels ~f:(fun label -> `String label))
          ; "blocked_by", `Array (List.map issue.blocked_by ~f:blocker)
          ; ("dispatchable", if issue.dispatchable then `True else `False)
          ; "created_at", jsonaf_of_time issue.created_at
          ; "updated_at", jsonaf_of_time issue.updated_at
          ] )
    ; ( "attempt"
      , match attempt with
        | Some attempt -> `Number (Int.to_string attempt)
        | None -> `Null )
    ]
;;

let first_turn_prompt ~(workflow : Maestro_workflow.Workflow.Loaded.t) ~issue ~attempt =
  let template_text =
    match String.is_empty (String.strip workflow.prompt_template) with
    | true -> default_template
    | false -> workflow.prompt_template
  in
  let%bind.Or_error template = Template.parse template_text in
  Template.render template ~vars:(issue_template_vars ~issue ~attempt)
;;

let continuation_prompt ~turn_number ~max_turns =
  String.concat_lines
    [ "Continuation guidance:"
    ; ""
    ; "- The previous Codex turn completed normally, but the tracker work item is still \
       in an active state."
    ; [%string
        "- This is continuation turn #%{turn_number#Int} of %{max_turns#Int} for the \
         current agent run."]
    ; "- Resume from the current workspace and workpad state instead of restarting from \
       scratch."
    ; "- The original task instructions and prior turn context are already present in \
       this thread, so do not restate them before acting."
    ; "- Focus on the remaining ticket work and do not end the turn while the issue \
       stays active unless you are truly blocked."
    ]
;;
