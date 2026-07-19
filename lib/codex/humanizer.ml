open! Core

let max_length = 140

let member name = function
  | `Object fields -> List.Assoc.find fields name ~equal:String.equal
  | `Null | `True | `False | `String _ | `Number _ | `Array _ -> None
;;

let member_string name value =
  match member name value with
  | Some (`String s) -> Some s
  | _ -> None
;;

let strip_control text =
  String.filter text ~f:(fun c ->
    Char.equal c ' ' || (Char.to_int c >= 0x20 && Char.to_int c <> 0x7f))
  |> String.strip
;;

let truncate text =
  (* Byte-exact cap; the ellipsis is 3 UTF-8 bytes. *)
  match String.length text > max_length with
  | true -> String.prefix text (max_length - 3) ^ "…"
  | false -> text
;;

(* Humanize a raw JSON-RPC method plus its params into a short phrase. *)
let humanize_method payload ~method_ =
  let params = Option.value (member "params" payload) ~default:payload in
  match method_ with
  | "thread/started" -> "thread started"
  | "turn/started" -> "turn started"
  | "turn/completed" -> "turn completed"
  | "turn/failed" ->
    (match member "error" params |> Option.bind ~f:(member_string "message") with
     | Some message -> [%string "turn failed: %{message}"]
     | None -> "turn failed")
  | "turn/cancelled" -> "turn cancelled"
  | "item/commandExecution/requestApproval" ->
    (match member_string "command" params with
     | Some command -> [%string "approval requested: %{command}"]
     | None -> "command approval requested")
  | "item/fileChange/requestApproval" -> "file-change approval requested"
  | "item/tool/requestUserInput" -> "operator input requested"
  | "mcpServer/elicitation/request" -> "MCP elicitation requested"
  | "thread/tokenUsage/updated" -> "token usage updated"
  | "account/rateLimits/updated" -> "rate limits updated"
  | other -> other
;;

let summarize (update : Update.t) =
  let with_detail label =
    match update.detail with
    | Some detail -> [%string "%{label}: %{detail}"]
    | None -> label
  in
  let base =
    match update.event with
    | Session_started ->
      (match update.session_id with
       | Some id -> [%string "session started (%{id})"]
       | None -> "session started")
    | Startup_failed -> with_detail "startup failed"
    | Turn_completed -> "turn completed"
    | Turn_failed -> "turn failed"
    | Turn_cancelled -> "turn cancelled"
    | Turn_input_required -> "turn blocked: waiting for operator input"
    | Approval_required -> "approval required"
    | Approval_auto_approved -> with_detail "auto-approved"
    | Tool_input_auto_answered -> "operator input auto-answered"
    | Tool_call_completed -> "dynamic tool call completed"
    | Tool_call_failed -> "dynamic tool call failed"
    | Unsupported_tool_call -> "unsupported dynamic tool call rejected"
    | Turn_ended_with_error -> with_detail "turn ended with error"
    | Malformed -> "malformed event from codex"
    | Notification | Other_message ->
      (match update.payload with
       | Some payload ->
         (match member_string "method" payload with
          | Some method_ -> humanize_method payload ~method_
          | None -> "notification")
       | None -> "notification")
  in
  truncate (strip_control base)
;;
