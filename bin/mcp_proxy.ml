open! Core
open! Async

module J = struct
  let member name = function
    | `Object fields -> List.Assoc.find fields name ~equal:String.equal
    | _ -> None
  ;;

  let string = function
    | `String value -> Some value
    | _ -> None
  ;;
end

let response ~id result = `Object [ "jsonrpc", `String "2.0"; "id", id; "result", result ]

let mcp_content = function
  | `Object fields ->
    let type_ = List.Assoc.find fields "type" ~equal:String.equal in
    (match type_ with
     | Some (`String "inputText") ->
       `Object
         (("type", `String "text") :: List.Assoc.remove fields "type" ~equal:String.equal)
     | _ -> `Object fields)
  | other -> other
;;

let call_host ~socket_path request =
  Tcp.with_connection (Tcp.Where_to_connect.of_file socket_path) (fun _ reader writer ->
    Writer.write_line writer (Jsonaf.to_string request);
    let%bind () = Writer.flushed writer in
    match%map Reader.read_line reader with
    | `Eof -> `Object [ "error", `String "MCP host closed without a response" ]
    | `Ok line -> Or_error.try_with (fun () -> Jsonaf.of_string line) |> Or_error.ok_exn)
;;

let handle ~socket_path ~tools json =
  let id = Option.value (J.member "id" json) ~default:`Null in
  match J.member "method" json |> Option.bind ~f:J.string with
  | Some "initialize" ->
    let requested_version =
      J.member "params" json
      |> Option.bind ~f:(J.member "protocolVersion")
      |> Option.bind ~f:J.string
      |> Option.value ~default:"2024-11-05"
    in
    return
      (Some
         (response
            ~id
            (`Object
              [ "protocolVersion", `String requested_version
              ; "capabilities", `Object [ "tools", `Object [] ]
              ; ( "serverInfo"
                , `Object [ "name", `String "maestro"; "version", `String "0.1.0" ] )
              ])))
  | Some "tools/list" -> return (Some (response ~id (`Object [ "tools", tools ])))
  | Some "tools/call" ->
    let params = Option.value (J.member "params" json) ~default:(`Object []) in
    let name = Option.value (J.member "name" params) ~default:(`String "") in
    let arguments = Option.value (J.member "arguments" params) ~default:(`Object []) in
    let%map host_result =
      call_host ~socket_path (`Object [ "name", name; "arguments", arguments ])
    in
    let success =
      match J.member "success" host_result with
      | Some `True -> true
      | _ -> false
    in
    let content =
      match J.member "contentItems" host_result with
      | Some (`Array items) -> `Array (List.map items ~f:mcp_content)
      | _ ->
        let text = Jsonaf.to_string_hum host_result in
        `Array [ `Object [ "type", `String "text"; "text", `String text ] ]
    in
    Some
      (response
         ~id
         (`Object [ "content", content; ("isError", if success then `False else `True) ]))
  | Some method_ when String.is_prefix method_ ~prefix:"notifications/" -> return None
  | Some _ | None ->
    return
      (Some
         (`Object
           [ "jsonrpc", `String "2.0"
           ; "id", id
           ; ( "error"
             , `Object [ "code", `Number "-32601"; "message", `String "Method not found" ]
             )
           ]))
;;

let run () =
  match Array.to_list (Sys.get_argv ()) with
  | [ _; socket_path; tools_json ] ->
    let tools = Jsonaf.of_string tools_json in
    Reader.lines (force Reader.stdin)
    |> Pipe.iter ~f:(fun line ->
      match Or_error.try_with (fun () -> Jsonaf.of_string line) with
      | Error _ -> return ()
      | Ok json ->
        let%bind answer = handle ~socket_path ~tools json in
        (match answer with
         | None -> return ()
         | Some answer ->
           Writer.write_line (force Writer.stdout) (Jsonaf.to_string answer);
           Writer.flushed (force Writer.stdout)))
  | _ -> failwith "usage: maestro-mcp-proxy SOCKET_PATH TOOLS_JSON"
;;

let main () =
  don't_wait_for
    (let%bind () = run () in
     Shutdown.exit 0)
;;

let () = never_returns (Scheduler.go_main ~main ())
