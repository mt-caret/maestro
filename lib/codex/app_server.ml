open! Core
open! Async
open Maestro_workflow
open Maestro_tracker

module J = struct
  let member name = function
    | `Object fields -> List.Assoc.find fields name ~equal:String.equal
    | `Null | `True | `False | `String _ | `Number _ | `Array _ -> None
  ;;

  let string = function
    | `String s -> Some s
    | `Null | `True | `False | `Number _ | `Array _ | `Object _ -> None
  ;;

  let list = function
    | `Array elements -> Some elements
    | `Null | `True | `False | `String _ | `Number _ | `Object _ -> None
  ;;

  let bool = function
    | `True -> Some true
    | `False -> Some false
    | `Null | `String _ | `Number _ | `Array _ | `Object _ -> None
  ;;

  let member_string name value = Option.bind (member name value) ~f:string
end

module Session = struct
  type t =
    { process : Process.t
    ; config : Config.t
    ; adapter : Adapter.t
    ; workspace : string
    ; thread_id : string
    ; approval_policy : Jsonaf.t
    ; turn_sandbox_policy : Jsonaf.t
    ; on_update : Update.t -> unit
    ; mutable last_session_id : string option
    }

  let thread_id t = t.thread_id
  let pid t = Process.pid t.process
end

let non_interactive_tool_input_answer =
  "This is a non-interactive session. Operator input is unavailable."
;;

(* Fixed request ids (ref-exact): the client only ever sends these three requests. *)
let initialize_id = 1
let thread_start_id = 2
let turn_start_id = 3

let auto_approve (config : Config.t) =
  match config.codex.approval_policy with
  | `String "never" -> true
  | `String _ | `Null | `True | `False | `Number _ | `Array _ | `Object _ -> false
;;

let default_turn_sandbox_policy ~workspace : Jsonaf.t =
  `Object
    [ "type", `String "workspaceWrite"
    ; "writableRoots", `Array [ `String workspace ]
    ; "readOnlyAccess", `Object [ "type", `String "fullAccess" ]
    ; "networkAccess", `False
    ; "excludeTmpdirEnvVar", `False
    ; "excludeSlashTmp", `False
    ]
;;

let send_message process message =
  Writer.write_line (Process.stdin process) (Jsonaf.to_string message)
;;

let send_request process ~id ~method_ ~params =
  send_message
    process
    (`Object
      [ "method", `String method_; "id", `Number (Int.to_string id); "params", params ])
;;

let send_response process ~id ~result =
  send_message process (`Object [ "id", id; "result", result ])
;;

(* Reads one line within [timeout]. Distinguishes JSON, non-JSON noise, EOF, and timeout.
   The protocol reader never sees stderr — that has its own consumer. *)
let read_message process ~timeout =
  match%map Clock_ns.with_timeout timeout (Reader.read_line (Process.stdout process)) with
  | `Timeout -> `Timeout
  | `Result `Eof -> `Eof
  | `Result (`Ok line) ->
    (match Option.try_with (fun () -> Jsonaf.of_string line) with
     | Some json -> `Json json
     | None -> `Non_json line)
;;

let log_non_json_line ~context line =
  let text = String.prefix (String.strip line) 1_000 in
  let looks_like_error =
    List.exists
      [ "error"; "warn"; "warning"; "failed"; "fatal"; "panic"; "exception" ]
      ~f:(fun needle -> String.is_substring (String.lowercase text) ~substring:needle)
  in
  match looks_like_error with
  | true -> [%log.info "codex stream output" ~context ~_:text]
  | false -> [%log.debug "codex stream output" ~context ~_:text]
;;

(* Awaits the response to a specific request id, skipping unrelated messages (the
   reference does the same during startup). *)
let await_response process ~id ~timeout =
  let expected = Int.to_string id in
  let rec loop () =
    match%bind read_message process ~timeout with
    | `Timeout -> return (Or_error.error_s [%message "response_timeout" (id : int)])
    | `Eof -> return (Or_error.error_s [%message "port_exit"])
    | `Non_json line ->
      log_non_json_line ~context:"response" line;
      loop ()
    | `Json json ->
      (match J.member "id" json with
       | Some (`Number n) when String.equal n expected ->
         (match J.member "result" json, J.member "error" json with
          | Some result, _ -> return (Ok result)
          | None, Some error ->
            return (Or_error.error_s [%message "response_error" ~_:(error : Jsonaf.t)])
          | None, None ->
            return (Or_error.error_s [%message "response_error" ~_:(json : Jsonaf.t)]))
       | Some _ | None ->
         [%log.debug "skipping message while awaiting response" (id : int)];
         loop ())
  in
  loop ()
;;

(* Diagnostic stderr drains in the background for the life of the subprocess. *)
let drain_stderr process =
  don't_wait_for
    (Reader.lines (Process.stderr process)
     |> Pipe.iter_without_pushback ~f:(log_non_json_line ~context:"stderr"))
;;

let scrubbed_environment ~secret_names =
  let secret_names = String.Set.of_list secret_names in
  Core_unix.environment ()
  |> Array.to_list
  |> List.filter_map ~f:(fun binding ->
    match String.lsplit2 binding ~on:'=' with
    | None -> None
    | Some (name, value) ->
      (match Set.mem secret_names name with
       | true -> None
       | false -> Some (name, value)))
;;

let valid_env_name name =
  (not (String.is_empty name))
  && (Char.is_alpha (String.get name 0) || Char.equal (String.get name 0) '_')
  && String.for_all name ~f:(fun c -> Char.is_alphanum c || Char.equal c '_')
;;

let spawn_codex ~(config : Config.t) ~workspace ~secret_names =
  let secret_names = List.filter secret_names ~f:valid_env_name in
  let command =
    (* [unset] after [bash -l] profile loading, before exec: profiles may re-export the
       secrets that were scrubbed from the spawn environment. *)
    match secret_names with
    | [] -> [%string "exec %{config.codex.command}"]
    | _ ->
      let names = String.concat secret_names ~sep:" " in
      [%string "unset %{names} && exec %{config.codex.command}"]
  in
  Monitor.try_with ~run:`Schedule (fun () ->
    Process.create_exn
      ~prog:"bash"
      ~args:[ "-lc"; command ]
      ~working_dir:workspace
      ~env:(`Replace (scrubbed_environment ~secret_names))
      ())
  >>| Result.map_error ~f:(fun exn -> Error.of_exn (Monitor.extract_exn exn))
;;

let start_session ~config ~workspace ~adapter ~on_update =
  let emit ?session_id ?payload ?detail ~pid event =
    on_update
      { Update.event
      ; timestamp = Time_ns.now ()
      ; codex_app_server_pid = pid
      ; session_id
      ; payload
      ; detail
      }
  in
  let fail_startup ~pid error =
    emit ~pid ~detail:(Error.to_string_hum error) Startup_failed;
    Error error
  in
  match%bind
    spawn_codex ~config ~workspace ~secret_names:config.tracker.secret_environment_names
  with
  | Error error -> return (fail_startup ~pid:None error)
  | Ok process ->
    drain_stderr process;
    let pid = Some (Process.pid process) in
    let read_timeout = config.codex.read_timeout in
    send_request
      process
      ~id:initialize_id
      ~method_:"initialize"
      ~params:
        (`Object
          [ "capabilities", `Object [ "experimentalApi", `True ]
          ; ( "clientInfo"
            , `Object
                [ "name", `String "maestro"
                ; "title", `String "Maestro Orchestrator"
                ; "version", `String "0.1.0"
                ] )
          ]);
    (match%bind await_response process ~id:initialize_id ~timeout:read_timeout with
     | Error error ->
       let%map () = Process.send_signal process Signal.kill |> return in
       fail_startup ~pid error
     | Ok (_ : Jsonaf.t) ->
       send_message
         process
         (`Object [ "method", `String "initialized"; "params", `Object [] ]);
       let approval_policy = config.codex.approval_policy in
       let turn_sandbox_policy =
         Option.value
           config.codex.turn_sandbox_policy
           ~default:(default_turn_sandbox_policy ~workspace)
       in
       send_request
         process
         ~id:thread_start_id
         ~method_:"thread/start"
         ~params:
           (`Object
             [ "approvalPolicy", approval_policy
             ; "sandbox", `String config.codex.thread_sandbox
             ; "cwd", `String workspace
             ; "dynamicTools", `Array adapter.Adapter.agent_tool_specs
             ]);
       (match%bind await_response process ~id:thread_start_id ~timeout:read_timeout with
        | Error error ->
          let%map () = Process.send_signal process Signal.kill |> return in
          fail_startup ~pid error
        | Ok result ->
          (match J.member "thread" result |> Option.bind ~f:(J.member_string "id") with
           | None ->
             let%map () = Process.send_signal process Signal.kill |> return in
             fail_startup
               ~pid
               (Error.create_s [%message "invalid_thread_payload" ~_:(result : Jsonaf.t)])
           | Some thread_id ->
             return
               (Ok
                  { Session.process
                  ; config
                  ; adapter
                  ; workspace
                  ; thread_id
                  ; approval_policy
                  ; turn_sandbox_policy
                  ; on_update
                  ; last_session_id = None
                  }))))
;;

(* Server->client request handling during a turn. Returns [`Continue] (possibly after
   replying), or a terminal outcome. *)
module Turn_handler = struct
  let approval_decision method_ =
    match method_ with
    | "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" ->
      Some "acceptForSession"
    | "execCommandApproval" | "applyPatchApproval" ->
      (* Legacy method generation with its distinct decision spelling. *)
      Some "approved_for_session"
    | _ -> None
  ;;

  let needs_input method_ payload =
    String.equal method_ "mcpServer/elicitation/request"
    || (String.is_prefix method_ ~prefix:"turn/"
        && (List.mem
              [ "turn/input_required"
              ; "turn/needs_input"
              ; "turn/need_input"
              ; "turn/request_input"
              ; "turn/request_response"
              ; "turn/provide_input"
              ; "turn/approval_required"
              ]
              method_
              ~equal:String.equal
            ||
            let params = Option.value (J.member "params" payload) ~default:payload in
            let flag name = Option.bind (J.member name params) ~f:J.bool in
            let type_is value =
              match J.member_string "type" params with
              | Some t -> String.equal t value
              | None -> false
            in
            List.exists
              [ flag "requiresInput"
              ; flag "needsInput"
              ; flag "input_required"
              ; flag "inputRequired"
              ]
              ~f:(fun f -> Option.value f ~default:false)
            || type_is "input_required"
            || type_is "needs_input"))
  ;;

  (* Answer every question: pick an approve-ish option label when auto-approving, else the
     canned non-interactive string. A question without a string id makes the whole request
     unanswerable. *)
  let answer_user_input_questions ~auto payload =
    let params = Option.value (J.member "params" payload) ~default:payload in
    let questions =
      J.member "questions" params |> Option.bind ~f:J.list |> Option.value ~default:[]
    in
    match questions with
    | [] -> None
    | questions ->
      let answer_one question =
        let%bind.Option question_id = J.member_string "id" question in
        let labels =
          J.member "options" question
          |> Option.bind ~f:J.list
          |> Option.value ~default:[]
          |> List.filter_map ~f:(J.member_string "label")
        in
        let approve_label =
          match auto with
          | false -> None
          | true ->
            List.find labels ~f:(String.equal "Approve this Session")
            |> Option.first_some (List.find labels ~f:(String.equal "Approve Once"))
            |> Option.first_some
                 (List.find labels ~f:(fun label ->
                    let label = String.lowercase (String.strip label) in
                    String.is_prefix label ~prefix:"approve"
                    || String.is_prefix label ~prefix:"allow"))
        in
        let answer =
          Option.value approve_label ~default:non_interactive_tool_input_answer
        in
        Some (question_id, answer)
      in
      (match List.map questions ~f:answer_one |> Option.all with
       | None -> None
       | Some answers ->
         let auto_approved =
           auto
           && List.exists answers ~f:(fun (_, a) ->
             not (String.equal a non_interactive_tool_input_answer))
         in
         Some
           ( `Object
               (List.map answers ~f:(fun (question_id, answer) ->
                  question_id, `Object [ "answers", `Array [ `String answer ] ]))
           , auto_approved ))
  ;;
end

let run_turn (session : Session.t) ~prompt ~(issue : Issue.t) =
  let%tydi { Session.process
           ; config
           ; adapter
           ; workspace
           ; thread_id
           ; approval_policy
           ; turn_sandbox_policy
           ; on_update
           ; last_session_id = _
           }
    =
    session
  in
  let pid = Some (Process.pid process) in
  let emit ?payload ?detail event =
    on_update
      { Update.event
      ; timestamp = Time_ns.now ()
      ; codex_app_server_pid = pid
      ; session_id = session.last_session_id
      ; payload
      ; detail
      }
  in
  send_request
    process
    ~id:turn_start_id
    ~method_:"turn/start"
    ~params:
      (`Object
        [ "threadId", `String thread_id
        ; "input", `Array [ `Object [ "type", `String "text"; "text", `String prompt ] ]
        ; "cwd", `String workspace
        ; "title", `String [%string "%{issue.identifier}: %{issue.title}"]
        ; "approvalPolicy", approval_policy
        ; "sandboxPolicy", turn_sandbox_policy
        ]);
  match%bind
    await_response process ~id:turn_start_id ~timeout:config.codex.read_timeout
  with
  | Error error -> return (Error error)
  | Ok result ->
    (match J.member "turn" result |> Option.bind ~f:(J.member_string "id") with
     | None ->
       return (Or_error.error_s [%message "invalid_turn_payload" ~_:(result : Jsonaf.t)])
     | Some turn_id ->
       let session_id = [%string "%{thread_id}-%{turn_id}"] in
       session.last_session_id <- Some session_id;
       emit Session_started;
       let auto = auto_approve config in
       (* Wall-clock total per turn (SPEC §10.6); each read is bounded by what remains.
          Inactivity is the orchestrator's stall detector's job. *)
       let deadline = Time_ns.add (Time_ns.now ()) config.codex.turn_timeout in
       let rec loop () =
         let remaining = Time_ns.diff deadline (Time_ns.now ()) in
         match Time_ns.Span.is_positive remaining with
         | false -> return (Or_error.error_s [%message "turn_timeout"])
         | true ->
           (match%bind read_message process ~timeout:remaining with
            | `Timeout -> return (Or_error.error_s [%message "turn_timeout"])
            | `Eof -> return (Or_error.error_s [%message "port_exit"])
            | `Non_json line ->
              log_non_json_line ~context:"turn" line;
              (match String.is_prefix (String.strip line) ~prefix:"{" with
               | true -> emit Malformed ~detail:(String.prefix line 200)
               | false -> ());
              loop ()
            | `Json json ->
              (match J.member_string "method" json with
               | None ->
                 emit Other_message ~payload:json;
                 loop ()
               | Some method_ -> handle_method ~method_ ~json ~loop))
       and handle_method ~method_ ~json ~loop =
         let params = J.member "params" json in
         let request_id = J.member "id" json in
         match method_ with
         | "turn/completed" ->
           emit Turn_completed ~payload:json;
           return (Ok ())
         | "turn/failed" ->
           emit Turn_failed ~payload:json;
           return (Or_error.error_s [%message "turn_failed" ~_:(json : Jsonaf.t)])
         | "turn/cancelled" ->
           emit Turn_cancelled ~payload:json;
           return (Or_error.error_s [%message "turn_cancelled" ~_:(json : Jsonaf.t)])
         | "item/tool/call" ->
           let params_value = Option.value params ~default:json in
           let tool_name =
             Option.first_some
               (J.member_string "tool" params_value)
               (J.member_string "name" params_value)
             |> Option.map ~f:String.strip
             |> Option.filter ~f:(Fn.non String.is_empty)
           in
           let arguments =
             Option.value (J.member "arguments" params_value) ~default:(`Object [])
           in
           let%bind result =
             match tool_name with
             | Some name ->
               adapter.Adapter.execute_agent_tool ~name ~arguments ~context_issue:issue
             | None ->
               return
                 (Adapter.Tool_result.of_error_message
                    ~extra:[ "supportedTools", `Array [] ]
                    "Unsupported dynamic tool: missing tool name.")
           in
           (match request_id with
            | Some id ->
              send_response
                process
                ~id
                ~result:([%jsonaf_of: Adapter.Tool_result.t] result)
            | None -> ());
           let event : Update.Event.t =
             match tool_name, result.success with
             | None, _ -> Unsupported_tool_call
             | Some _, true -> Tool_call_completed
             | Some _, false -> Tool_call_failed
           in
           emit event ~payload:json;
           loop ()
         | "item/tool/requestUserInput" ->
           (match Turn_handler.answer_user_input_questions ~auto json with
            | Some (answers, auto_approved) ->
              (match request_id with
               | Some id ->
                 send_response process ~id ~result:(`Object [ "answers", answers ])
               | None -> ());
              (match auto_approved with
               | true ->
                 emit Approval_auto_approved ~payload:json ~detail:"Approve this Session"
               | false ->
                 emit
                   Tool_input_auto_answered
                   ~payload:json
                   ~detail:non_interactive_tool_input_answer);
              loop ()
            | None ->
              emit Turn_input_required ~payload:json;
              return
                (Or_error.error_s [%message "turn_input_required" ~_:(json : Jsonaf.t)]))
         | method_ ->
           (match Turn_handler.approval_decision method_ with
            | Some decision ->
              (match auto with
               | true ->
                 (match request_id with
                  | Some id ->
                    send_response
                      process
                      ~id
                      ~result:(`Object [ "decision", `String decision ])
                  | None -> ());
                 emit Approval_auto_approved ~payload:json ~detail:decision;
                 loop ()
               | false ->
                 emit Approval_required ~payload:json;
                 return
                   (Or_error.error_s [%message "approval_required" ~_:(json : Jsonaf.t)]))
            | None ->
              (match Turn_handler.needs_input method_ json with
               | true ->
                 emit Turn_input_required ~payload:json;
                 return
                   (Or_error.error_s
                      [%message "turn_input_required" ~_:(json : Jsonaf.t)])
               | false ->
                 emit Notification ~payload:json;
                 loop ()))
       in
       loop ())
;;

let stop_session (session : Session.t) =
  let process = session.Session.process in
  let%bind () =
    Monitor.try_with ~run:`Schedule (fun () -> Writer.close (Process.stdin process))
    >>| (ignore : (unit, exn) Result.t -> unit)
  in
  Process.send_signal process Signal.kill;
  (* Reap with a bounded wait; SIGKILL means this resolves promptly. *)
  match%map
    Clock_ns.with_timeout (Time_ns.Span.of_int_ms 5_000) (Process.wait process)
  with
  | `Timeout | `Result (_ : Core_unix.Exit_or_signal.t) -> ()
;;
