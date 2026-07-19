open! Core
open! Async

module Tool_result = struct
  type t =
    { success : bool
    ; output : string
    ; content_items : Jsonaf.t list
    }
  [@@deriving sexp_of]

  let to_jsonaf { success; output; content_items } =
    `Object
      [ ("success", if success then `True else `False)
      ; "output", `String output
      ; "contentItems", `Array content_items
      ]
  ;;

  let of_error_message ?(extra = []) message =
    let output =
      Jsonaf.to_string_hum
        (`Object [ "error", `Object (("message", `String message) :: extra) ])
    in
    { success = false
    ; output
    ; content_items = [ `Object [ "type", `String "inputText"; "text", `String output ] ]
    }
  ;;
end

type t =
  { fetch_issues_by_states : string list -> Issue.t list Deferred.Or_error.t
  ; fetch_issues_by_ids : string list -> Issue.t list Deferred.Or_error.t
  ; secret_environment_names : string list
  ; agent_tool_specs : Jsonaf.t list
  ; execute_agent_tool :
      name:string
      -> arguments:Jsonaf.t
      -> context_issue:Issue.t
      -> Tool_result.t Deferred.t
  ; validate_config : unit -> unit Or_error.t
  }
