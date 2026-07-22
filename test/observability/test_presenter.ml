open! Core
open! Async
open Maestro_tracker
open Maestro_orchestrator
open Orchestrator
open Maestro_observability

(* Build a snapshot by driving the engine a little, reusing the orchestrator test's
   scriptable style inline. *)
let issue ~id ~identifier ~state =
  { Issue.id
  ; native_ref = None
  ; identifier
  ; title = "t"
  ; description = None
  ; priority = None
  ; state
  ; branch_name = None
  ; url = Some [%string "https://tracker/%{identifier}"]
  ; assignee_id = None
  ; labels = []
  ; blocked_by = []
  ; dispatchable = true
  ; created_at = None
  ; updated_at = None
  }
;;

let config =
  (Maestro_workflow.Workflow.parse_contents
     {|---
tracker:
  kind: memory
  active_states: [Todo]
  terminal_states: [Done]
agent:
  max_concurrent_agents: 5
---
p|}
     ~workflow_dir:"/unused"
     ~getenv:(fun (_ : string) -> None)
   |> ok_exn)
    .config
;;

let adapter issues = Memory.create ~issues:(fun () -> issues)
let now = Time_ns.epoch

let%expect_test "state_payload: generated_at, counts, rows, totals" =
  let issues = [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ] in
  let%bind state, _ =
    Orchestrator.handle
      (State.create ())
      ~config
      ~adapter:(adapter issues)
      ~now
      ~config_valid:true
      (Tick { token = None })
  in
  let snapshot = Orchestrator.to_snapshot state ~config ~now in
  print_string (Jsonaf.to_string_hum (Presenter.state_payload snapshot ~generated_at:now));
  [%expect
    {|
    {
      "generated_at": "1970-01-01T00:00:00.000000000Z",
      "counts": {
        "running": 1,
        "retrying": 0,
        "blocked": 0
      },
      "running": [
        {
          "issue_id": "a",
          "issue_identifier": "MT-1",
          "issue_url": "https://tracker/MT-1",
          "state": "Todo",
          "session_id": null,
          "turn_count": 0,
          "last_event": null,
          "last_message": null,
          "started_at": "1970-01-01T00:00:00.000000000Z",
          "last_event_at": null,
          "recent_events": [],
          "workspace_path": null,
          "tokens": {
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0
          },
          "runtime_seconds": 0
        }
      ],
      "retrying": [],
      "blocked": [],
      "codex_totals": {
        "input_tokens": 0,
        "output_tokens": 0,
        "total_tokens": 0,
        "seconds_running": 0
      },
      "rate_limits": null
    }
    |}];
  return ()
;;

let%expect_test "issue_payload: found running, and 404 (None) for unknown" =
  let issues = [ issue ~id:"a" ~identifier:"MT-1" ~state:"Todo" ] in
  let%bind state, _ =
    Orchestrator.handle
      (State.create ())
      ~config
      ~adapter:(adapter issues)
      ~now
      ~config_valid:true
      (Tick { token = None })
  in
  let snapshot = Orchestrator.to_snapshot state ~config ~now in
  (match
     Presenter.issue_payload snapshot ~issue_identifier:"MT-1" ~codex_session_logs:[]
   with
   | None -> print_string "unexpected None\n"
   | Some json ->
     let status =
       match json with
       | `Object fields ->
         List.Assoc.find_exn fields "status" ~equal:String.equal |> [%sexp_of: Jsonaf.t]
       | _ -> Sexp.Atom "?"
     in
     print_s [%sexp (status : Sexp.t)]);
  [%expect {| (String running) |}];
  print_s
    [%sexp
      (Presenter.issue_payload snapshot ~issue_identifier:"MT-404" ~codex_session_logs:[]
       : Jsonaf.t option)];
  [%expect {| () |}];
  return ()
;;

let%expect_test "refresh_response shape" =
  print_string
    (Jsonaf.to_string_hum
       (Presenter.refresh_response ~queued:true ~coalesced:false ~requested_at:now));
  [%expect
    {|
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "1970-01-01T00:00:00.000000000Z",
      "operations": [
        "poll",
        "reconcile"
      ]
    }
    |}];
  return ()
;;
