open! Core
open! Async
open Maestro_codex
open Maestro_workflow
open Maestro_tracker

let issue labels : Issue.t =
  { id = "issue-1"
  ; native_ref = None
  ; identifier = "MTA-12"
  ; title = "Claude backend"
  ; description = None
  ; priority = None
  ; state = "In Progress"
  ; branch_name = None
  ; url = None
  ; assignee_id = None
  ; labels
  ; blocked_by = []
  ; dispatchable = true
  ; created_at = None
  ; updated_at = None
  }
;;

let config ~dir ~script =
  let yaml =
    [%string
      {|tracker:
  kind: memory
agent:
  backend: claude_code
claude_code:
  command: %{script}
  permission_mode: acceptEdits
  allowed_tools: [mcp__maestro__linear_graphql]
workspace:
  root: %{dir}/workspaces|}]
  in
  Workflow.parse_contents
    ("---\n" ^ yaml ^ "\n---\nprompt")
    ~workflow_dir:dir
    ~getenv:(fun _ -> None)
  |> Or_error.ok_exn
  |> fun (loaded : Workflow.Loaded.t) -> loaded.config
;;

let adapter = Memory.create ~issues:(fun () -> [])

let tool_adapter =
  { adapter with
    agent_tool_specs =
      [ `Object
          [ "name", `String "linear_graphql"
          ; "description", `String "test"
          ; "inputSchema", `Object [ "type", `String "object" ]
          ]
      ]
  ; execute_agent_tool =
      (fun ~name ~arguments ~context_issue ->
        return
          { Adapter.Tool_result.success = true
          ; output =
              Jsonaf.to_string
                (`Array [ `String name; arguments; `String context_issue.id ])
          ; content_items = []
          })
  }
;;

let%expect_test "workflow default and normalized label overrides select a backend" =
  let dir = "/tmp" in
  let config = config ~dir ~script:"claude" in
  let show labels =
    print_s
      [%sexp
        (Agent_runner.Backend.for_issue ~config (issue labels) : Agent_runner.Backend.t)]
  in
  show [];
  show [ "agent:codex" ];
  show [ "agent:claude" ];
  [%expect {|
    Claude_code
    Codex
    Claude_code |}];
  return ()
;;

let%expect_test "stream JSON captures session id, resume, and final usage" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let script = dir ^/ "fake-claude.sh" in
    let trace = dir ^/ "trace" in
    let contents =
      [%string
        {|#!/bin/sh
printf '%s\n' "$*" >> %{Filename.quote trace}
case "$*" in
  *--resume*) session=claude-session ;;
  *) session=claude-session ;;
esac
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\"}"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'
printf '%s\n' '{"type":"result","is_error":false,"total_cost_usd":0.012,"usage":{"input_tokens":7,"output_tokens":5}}'|}]
    in
    let%bind () = Writer.save script ~contents in
    let%bind () = Unix.chmod script ~perm:0o755 in
    let config = config ~dir ~script in
    let updates = Queue.create () in
    let%bind session =
      Claude_code.start_session
        ~config
        ~workspace:dir
        ~adapter
        ~on_update:(Queue.enqueue updates)
      >>| Or_error.ok_exn
    in
    let%bind () =
      Claude_code.run_turn session ~prompt:"first prompt" ~issue:(issue [])
      >>| Or_error.ok_exn
    in
    let%bind () =
      Claude_code.run_turn session ~prompt:"continue" ~issue:(issue [])
      >>| Or_error.ok_exn
    in
    let%bind trace = Reader.file_contents trace in
    print_endline trace;
    Queue.to_list updates
    |> List.filter ~f:(fun update -> Update.Event.equal update.event Turn_completed)
    |> List.iter ~f:(fun update ->
      print_s
        [%sexp
          (update.event : Update.Event.t)
          , (update.session_id : string option)
          , (update.payload : Jsonaf.t option)]);
    [%expect
      {|
      -p first prompt --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools mcp__maestro__linear_graphql
      -p continue --output-format stream-json --verbose --permission-mode acceptEdits --resume claude-session --allowedTools mcp__maestro__linear_graphql

      (Turn_completed (claude-session)
       ((Object
         ((method (String turn/completed))
          (usage
           (Object
            ((total_tokens (Number 12)) (input_tokens (Number 7))
             (output_tokens (Number 5)))))
          (claude_result
           (Object
            ((type (String result)) (is_error False)
             (total_cost_usd (Number 0.012))
             (usage
              (Object ((input_tokens (Number 7)) (output_tokens (Number 5))))))))))))
      (Turn_completed (claude-session)
       ((Object
         ((method (String turn/completed))
          (usage
           (Object
            ((total_tokens (Number 12)) (input_tokens (Number 7))
             (output_tokens (Number 5)))))
          (claude_result
           (Object
            ((type (String result)) (is_error False)
             (total_cost_usd (Number 0.012))
             (usage
              (Object ((input_tokens (Number 7)) (output_tokens (Number 5))))))))))))
      |}];
    return ())
;;

let%expect_test "login-shell profiles cannot restore tracker credentials" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let script = dir ^/ "fake-claude.sh" in
    let profile = dir ^/ ".bash_profile" in
    let result = dir ^/ "credential" in
    let contents =
      [%string
        {|#!/bin/sh
if [ -n "${LINEAR_API_KEY+x}" ]; then secret=present; else secret=absent; fi
printf '%s:%s' "$PROFILE_MARKER" "$secret" > %{Filename.quote result}
printf '%s\n' '{"type":"system","subtype":"init","session_id":"credential-session"}'
printf '%s\n' '{"type":"result","is_error":false,"usage":{}}'|}]
    in
    let%bind () = Writer.save script ~contents in
    let%bind () = Unix.chmod script ~perm:0o755 in
    let%bind () =
      Writer.save
        profile
        ~contents:"export LINEAR_API_KEY=restored\nexport PROFILE_MARKER=loaded\n"
    in
    let config = config ~dir ~script in
    let tracker =
      { config.tracker with secret_environment_names = [ "LINEAR_API_KEY" ] }
    in
    let config = { config with tracker } in
    let%bind session =
      Claude_code.start_session ~config ~workspace:dir ~adapter ~on_update:ignore
      >>| Or_error.ok_exn
    in
    let%bind () =
      Unix.putenv ~key:"HOME" ~data:dir;
      Unix.putenv ~key:"LINEAR_API_KEY" ~data:"parent-secret";
      Claude_code.run_turn session ~prompt:"credential test" ~issue:(issue [])
      >>| Or_error.ok_exn
    in
    let%bind contents = Reader.file_contents result in
    print_endline contents;
    [%expect {| loaded:absent |}];
    return ())
;;

let%expect_test "user-input requests terminate the turn immediately" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let script = dir ^/ "fake-claude.sh" in
    let contents =
      {|#!/bin/sh
printf '%s\n' '{"type":"system","subtype":"init","session_id":"input-session"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}]}}'
sleep 30|}
    in
    let%bind () = Writer.save script ~contents in
    let%bind () = Unix.chmod script ~perm:0o755 in
    let config = config ~dir ~script in
    let events = Queue.create () in
    let%bind session =
      Claude_code.start_session ~config ~workspace:dir ~adapter ~on_update:(fun update ->
        Queue.enqueue events update.event)
      >>| Or_error.ok_exn
    in
    let%bind result =
      Clock_ns.with_timeout
        (Time_ns.Span.of_sec 2.)
        (Claude_code.run_turn session ~prompt:"input test" ~issue:(issue []))
    in
    let outcome =
      match result with
      | `Timeout -> `Timeout
      | `Result result -> `Result (Result.is_error result)
    in
    print_s
      [%sexp
        (outcome : [ `Timeout | `Result of bool ])
        , (Queue.exists events ~f:(Update.Event.equal Turn_input_required) : bool)];
    [%expect {| ((Result true) true) |}];
    return ())
;;

let%expect_test "agent runner completes through the memory adapter and fake Claude" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let script = dir ^/ "fake-claude.sh" in
    let contents =
      {|#!/bin/sh
printf '%s\n' '{"type":"system","subtype":"init","session_id":"e2e-session"}'
printf '%s\n' '{"type":"result","is_error":false,"usage":{"input_tokens":1,"output_tokens":2}}'|}
    in
    let%bind () = Writer.save script ~contents in
    let%bind () = Unix.chmod script ~perm:0o755 in
    let config = config ~dir ~script in
    let workflow : Workflow.Loaded.t =
      { config
      ; prompt_template = "Work on {{ issue.identifier }}"
      ; front_matter = `Object []
      }
    in
    let workspace = ref None in
    let%bind result =
      Agent_runner.run
        ~config
        ~workflow
        ~adapter
        ~issue:(issue [])
        ~attempt:None
        ~on_update:ignore
        ~on_runtime_info:(fun ~workspace_path -> workspace := Some workspace_path)
        ()
    in
    print_s
      [%sexp
        (result : unit Or_error.t)
        , (Option.map !workspace ~f:Filename.basename : string option)];
    [%expect {| ((Ok ()) (MTA-12)) |}];
    return ())
;;

let%expect_test "MCP bridge executes the provider tool in the host process" =
  Expect_test_helpers_async.with_temp_dir (fun dir ->
    let%bind host =
      Mcp_host.create ~workspace:dir ~adapter:tool_adapter >>| Or_error.ok_exn
    in
    Mcp_host.set_context_issue host (issue []);
    let socket_path =
      match Mcp_host.config host with
      | `Object fields ->
        List.Assoc.find_exn fields "mcpServers" ~equal:String.equal
        |> (function
              | `Object servers ->
                List.Assoc.find_exn servers "maestro" ~equal:String.equal
              | _ -> assert false)
        |> (function
              | `Object fields -> List.Assoc.find_exn fields "args" ~equal:String.equal
              | _ -> assert false)
        |> (function
         | `Array (`String socket :: _) -> socket
         | _ -> assert false)
      | _ -> assert false
    in
    let%bind response =
      Tcp.with_connection
        (Tcp.Where_to_connect.of_file socket_path)
        (fun _ reader writer ->
           Writer.write_line
             writer
             {|{"name":"linear_graphql","arguments":{"query":"query { viewer { id } }"}}|};
           let%bind () = Writer.flushed writer in
           Reader.read_line reader)
    in
    let%bind () = Mcp_host.close host in
    (match response with
     | `Eof -> print_endline "eof"
     | `Ok response -> print_s [%sexp (Jsonaf.of_string response : Jsonaf.t)]);
    [%expect
      {|
      (Object
       ((success True)
        (output
         (String
          "[\"linear_graphql\",{\"query\":\"query { viewer { id } }\"},\"issue-1\"]"))
        (contentItems (Array ()))))
      |}];
    return ())
;;
