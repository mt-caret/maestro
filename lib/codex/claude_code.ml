open! Core
open! Async
open Maestro_workflow
open Maestro_tracker

module J = struct
  let member name = function
    | `Object fields -> List.Assoc.find fields name ~equal:String.equal
    | _ -> None
  ;;

  let string = function
    | `String value -> Some value
    | _ -> None
  ;;

  let bool = function
    | `True -> Some true
    | `False -> Some false
    | _ -> None
  ;;
end

let rec contains_user_input_request = function
  | `Object fields ->
    List.exists fields ~f:(fun (name, value) ->
      (String.equal name "name"
       &&
       match value with
       | `String "AskUserQuestion" -> true
       | _ -> false)
      || contains_user_input_request value)
  | `Array values -> List.exists values ~f:contains_user_input_request
  | `String value -> String.Caseless.is_substring value ~substring:"user input required"
  | `Null | `True | `False | `Number _ -> false
;;

module Session = struct
  type t =
    { config : Config.t
    ; workspace : string
    ; on_update : Update.t -> unit
    ; mutable session_id : string option
    ; mutable process : Process.t option
    ; mcp_host : Mcp_host.t option
    }
end

let emit session ?payload ?detail ?pid event =
  session.Session.on_update
    { Update.event
    ; timestamp = Time_ns.now ()
    ; codex_app_server_pid = pid
    ; session_id = session.session_id
    ; payload
    ; detail
    }
;;

let start_session ~config ~workspace ~adapter ~on_update =
  match%bind
    match adapter.Adapter.agent_tool_specs with
    | [] -> Deferred.Or_error.return None
    | _ -> Mcp_host.create ~workspace ~adapter >>| Or_error.map ~f:Option.some
  with
  | Error error ->
    on_update
      { Update.event = Startup_failed
      ; timestamp = Time_ns.now ()
      ; codex_app_server_pid = None
      ; session_id = None
      ; payload = None
      ; detail = Some (Error.to_string_hum error)
      };
    return (Error error)
  | Ok mcp_host ->
    let session =
      { Session.config
      ; workspace
      ; on_update
      ; session_id = None
      ; process = None
      ; mcp_host
      }
    in
    emit session Session_started;
    Deferred.Or_error.return session
;;

let scrubbed_environment secret_names =
  let names = String.Set.of_list secret_names in
  Unix.environment ()
  |> Array.to_list
  |> List.filter_map ~f:(fun binding ->
    match String.lsplit2 binding ~on:'=' with
    | None -> None
    | Some (name, value) -> Option.some_if (not (Set.mem names name)) (name, value))
;;

let merge_mcp_config configured hosted =
  match configured, hosted with
  | None, None -> None
  | Some config, None -> Some config
  | None, Some host -> Some (Mcp_host.config host)
  | Some (`Object configured), Some host ->
    let hosted_servers = J.member "mcpServers" (Mcp_host.config host) in
    let configured_servers =
      List.Assoc.find configured "mcpServers" ~equal:String.equal
    in
    let servers =
      match configured_servers, hosted_servers with
      | Some (`Object configured), Some (`Object hosted) ->
        let configured = List.Assoc.remove configured "maestro" ~equal:String.equal in
        `Object (hosted @ configured)
      | _, Some hosted -> hosted
      | _, None -> `Object []
    in
    Some (`Object (List.Assoc.add configured ~equal:String.equal "mcpServers" servers))
  | Some config, Some _ -> Some config
;;

let command session ~prompt =
  let config = session.Session.config.claude_code in
  let secret_names = session.config.tracker.secret_environment_names in
  let allowed_tools =
    config.allowed_tools
    @ Option.value_map session.mcp_host ~default:[] ~f:Mcp_host.allowed_tools
    |> List.dedup_and_sort ~compare:String.compare
  in
  let args =
    [ "-p"
    ; prompt
    ; "--output-format"
    ; "stream-json"
    ; "--verbose"
    ; "--permission-mode"
    ; config.permission_mode
    ]
    @ (match session.session_id with
       | None -> []
       | Some id -> [ "--resume"; id ])
    @ (match allowed_tools with
       | [] -> []
       | tools -> [ "--allowedTools"; String.concat tools ~sep:"," ])
    @
    match merge_mcp_config config.mcp_config session.mcp_host with
    | None -> []
    | Some json -> [ "--mcp-config"; Jsonaf.to_string json ]
  in
  let launch =
    String.concat (("exec " ^ config.command) :: List.map args ~f:Filename.quote) ~sep:" "
  in
  match secret_names with
  | [] -> launch
  | names ->
    (* A login shell may restore credentials from its profile after the child environment
       has been scrubbed. Unset them again immediately before launching Claude. *)
    let names = String.concat (List.map names ~f:Filename.quote) ~sep:" " in
    [%string "unset %{names} && %{launch}"]
;;

let event_of_type = function
  | "stream_event" | "assistant" | "tool_use" | "tool_result" -> Update.Event.Notification
  | _ -> Other_message
;;

let handle_line session ~pid line =
  match Or_error.try_with (fun () -> Jsonaf.of_string line) with
  | Error error ->
    emit
      session
      ~pid
      ~detail:(Error.to_string_hum error)
      ~payload:(`String line)
      Malformed;
    Ok `Continue
  | Ok json ->
    let type_ = J.member "type" json |> Option.bind ~f:J.string in
    (match contains_user_input_request json with
     | true ->
       emit session ~pid ~payload:json Turn_input_required;
       Or_error.error_s [%message "claude_code_user_input_required"]
     | false ->
       (match type_ with
        | Some "system" ->
          (match J.member "subtype" json |> Option.bind ~f:J.string with
           | Some "init" ->
             session.session_id <- J.member "session_id" json |> Option.bind ~f:J.string
           | _ -> ());
          emit session ~pid ~payload:json Notification;
          Ok `Continue
        | Some "result" ->
          let failed =
            J.member "is_error" json
            |> Option.bind ~f:J.bool
            |> Option.value ~default:false
          in
          let usage =
            match J.member "usage" json with
            | Some (`Object fields) ->
              let token name =
                List.Assoc.find fields name ~equal:String.equal
                |> Option.bind ~f:(function
                  | `Number value -> Option.try_with (fun () -> Int.of_string value)
                  | _ -> None)
                |> Option.value ~default:0
              in
              `Object
                (( "total_tokens"
                 , `Number (Int.to_string (token "input_tokens" + token "output_tokens"))
                 )
                 :: fields)
            | Some usage -> usage
            | None -> `Object []
          in
          let payload =
            `Object
              [ "method", `String "turn/completed"
              ; "usage", usage
              ; "claude_result", json
              ]
          in
          if failed
          then (
            emit session ~pid ~payload:json Turn_failed;
            Or_error.error_s [%message "claude_code_result_error" (json : Jsonaf.t)])
          else (
            emit session ~pid ~payload Turn_completed;
            Ok `Done)
        | Some type_ ->
          emit session ~pid ~payload:json (event_of_type type_);
          Ok `Continue
        | None ->
          emit session ~pid ~payload:json Other_message;
          Ok `Continue))
;;

let run_turn session ~prompt ~issue =
  let config = session.Session.config in
  Option.iter session.mcp_host ~f:(fun host -> Mcp_host.set_context_issue host issue);
  let command = command session ~prompt in
  match%bind
    Monitor.try_with (fun () ->
      Process.create_exn
        ~prog:"bash"
        ~args:[ "-lc"; command ]
        ~working_dir:session.workspace
        ~env:(`Replace (scrubbed_environment config.tracker.secret_environment_names))
        ())
  with
  | Error exn ->
    let error = Error.of_exn (Monitor.extract_exn exn) in
    emit session ~detail:(Error.to_string_hum error) Startup_failed;
    return (Error error)
  | Ok process ->
    session.process <- Some process;
    let pid = Process.pid process in
    don't_wait_for
      (Reader.lines (Process.stderr process)
       |> Pipe.iter ~f:(fun line ->
         [%log.debug "claude code stderr" ~_:(line : string)];
         return ()));
    let rec read () =
      match%bind Reader.read_line (Process.stdout process) with
      | `Eof -> return (Ok `Continue)
      | `Ok line ->
        (match handle_line session ~pid line with
         | Ok `Continue -> read ()
         | (Error _ | Ok `Done) as result -> return result)
    in
    let%bind timed = Clock_ns.with_timeout config.claude_code.turn_timeout (read ()) in
    let result =
      match timed with
      | `Timeout ->
        Process.send_signal process Signal.kill;
        Or_error.error_s [%message "claude_code_turn_timeout"]
      | `Result (Error _ as error) ->
        Process.send_signal process Signal.kill;
        error
      | `Result (Ok `Done) -> Ok ()
      | `Result (Ok `Continue) -> Or_error.error_s [%message "claude_code_missing_result"]
    in
    let%map status =
      Clock_ns.with_timeout (Time_ns.Span.of_sec 5.) (Process.wait process)
    in
    session.process <- None;
    let result =
      match result, status with
      | (Error _ as error), _ -> error
      | Ok (), `Result (Ok ()) -> Ok ()
      | Ok (), `Result (Error status) ->
        Or_error.error_s
          [%message
            "claude_code_process_failed"
              ~status:(Unix.Exit_or_signal.to_string_hum (Error status) : string)]
      | Ok (), `Timeout ->
        Process.send_signal process Signal.kill;
        Or_error.error_s [%message "claude_code_process_wait_timeout"]
    in
    (match result with
     | Ok () -> ()
     | Error error ->
       emit session ~pid ~detail:(Error.to_string_hum error) Turn_ended_with_error);
    result
;;

let stop_session session =
  Option.iter session.Session.process ~f:(fun process ->
    Process.send_signal process Signal.kill);
  session.process <- None;
  match session.mcp_host with
  | None -> return ()
  | Some host -> Mcp_host.close host
;;
