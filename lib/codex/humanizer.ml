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

let member_int name value =
  match member name value with
  | Some (`Number value) -> Int.of_string_opt value
  | _ -> None
;;

let path value names =
  List.fold names ~init:(Some value) ~f:(fun value name ->
    Option.bind value ~f:(member name))
;;

let humanize_wrapper payload suffix =
  let msg = Option.value (path payload [ "params"; "msg" ]) ~default:payload in
  match suffix with
  | "task_started" -> "task started"
  | "user_message" -> "user message received"
  | "agent_message_delta" | "agent_message_content_delta" -> "agent message streaming"
  | "agent_reasoning_delta" | "reasoning_content_delta" -> "reasoning streaming"
  | "exec_command_output_delta" -> "command output streaming"
  | "exec_command_begin" ->
    (match member_string "command" msg with
     | Some command -> command
     | None -> "command started")
  | "exec_command_end" ->
    (match
       member_int "exit_code" msg |> Option.first_some (member_int "exitCode" msg)
     with
     | Some code -> [%string "command completed (exit %{code#Int})"]
     | None -> "command completed")
  | "token_count" ->
    let usage = Option.value (member "usage" msg) ~default:msg in
    (match
       member_int "total_tokens" usage
       |> Option.first_some (member_int "totalTokens" usage)
     with
     | Some total -> [%string "token count update (%{total#Int} total)"]
     | None -> "token count update")
  | "turn_diff" -> "turn diff updated"
  | "mcp_tool_call_begin" -> "mcp tool call started"
  | "mcp_tool_call_end" -> "mcp tool call completed"
  | other -> other
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
  | "turn/diff/updated" -> "turn diff updated"
  | "item/agentMessage/delta" -> "agent message streaming"
  | "item/plan/delta" -> "plan streaming"
  | "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" ->
    "reasoning streaming"
  | "item/commandExecution/outputDelta" -> "command output streaming"
  | "item/fileChange/outputDelta" -> "file change output streaming"
  | "item/commandExecution/requestApproval" ->
    (match member_string "command" params with
     | Some command -> [%string "approval requested: %{command}"]
     | None -> "command approval requested")
  | "item/fileChange/requestApproval" -> "file-change approval requested"
  | "item/tool/requestUserInput" -> "operator input requested"
  | "mcpServer/elicitation/request" -> "MCP elicitation requested"
  | "thread/tokenUsage/updated" -> "token usage updated"
  | "account/rateLimits/updated" -> "rate limits updated"
  | method_ when String.is_prefix method_ ~prefix:"codex/event/" ->
    humanize_wrapper payload (String.chop_prefix_exn method_ ~prefix:"codex/event/")
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
