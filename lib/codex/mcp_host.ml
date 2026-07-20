open! Core
open! Async
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
end

type t =
  { socket_path : string
  ; adapter : Adapter.t
  ; server : Tcp.Server.unix
  ; mutable context_issue : Issue.t option
  }

let handle t reader writer =
  let respond result =
    Writer.write_line writer (Jsonaf.to_string result);
    Writer.flushed writer
  in
  match%bind Reader.read_line reader with
  | `Eof -> return ()
  | `Ok line ->
    (match Or_error.try_with (fun () -> Jsonaf.of_string line) with
     | Error error ->
       respond
         (`Object
           [ ( "error"
             , `String
                 [%string "invalid MCP bridge request: %{Error.to_string_hum error}"] )
           ])
     | Ok json ->
       let name = J.member "name" json |> Option.bind ~f:J.string in
       let arguments = Option.value (J.member "arguments" json) ~default:(`Object []) in
       (match name, t.context_issue with
        | Some name, Some context_issue ->
          let%bind result =
            t.adapter.execute_agent_tool ~name ~arguments ~context_issue
          in
          respond ([%jsonaf_of: Adapter.Tool_result.t] result)
        | None, _ -> respond (`Object [ "error", `String "missing tool name" ])
        | _, None -> respond (`Object [ "error", `String "missing issue context" ])))
;;

let create ~workspace ~adapter =
  let socket_path =
    workspace
    ^/ [%string ".maestro-mcp-%{Unix.getpid ()#Pid}-%{Random.int 1_000_000#Int}.sock"]
  in
  let t_ref = ref None in
  match%map
    Monitor.try_with (fun () ->
      Tcp.Server.create
        ~on_handler_error:`Ignore
        (Tcp.Where_to_listen.of_file socket_path)
        (fun (_ : Socket.Address.Unix.t) reader writer ->
           match !t_ref with
           | Some t -> handle t reader writer
           | None -> return ()))
  with
  | Error exn -> Error (Error.of_exn (Monitor.extract_exn exn))
  | Ok server ->
    let t = { socket_path; adapter; server; context_issue = None } in
    t_ref := Some t;
    Ok t
;;

let set_context_issue t issue = t.context_issue <- Some issue

let config t =
  `Object
    [ ( "mcpServers"
      , `Object
          [ ( "maestro"
            , `Object
                [ "command", `String "maestro-mcp-proxy"
                ; ( "args"
                  , `Array
                      [ `String t.socket_path
                      ; `String (Jsonaf.to_string (`Array t.adapter.agent_tool_specs))
                      ] )
                ] )
          ] )
    ]
;;

let allowed_tools t =
  List.filter_map t.adapter.agent_tool_specs ~f:(fun spec ->
    J.member "name" spec
    |> Option.bind ~f:J.string
    |> Option.map ~f:(fun name -> [%string "mcp__maestro__%{name}"]))
;;

let close t =
  let%bind () = Tcp.Server.close ~close_existing_connections:true t.server in
  Monitor.try_with (fun () -> Unix.unlink t.socket_path) >>| fun _ -> ()
;;
